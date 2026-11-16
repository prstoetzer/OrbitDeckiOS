"""Convert the DeepCW ONNX model (e04/deepcw-engine, MIT) to the Core ML package OrbitDeck bundles.

Usage (in a venv with: numpy<2.1 onnx onnxruntime onnx2torch torch==2.7.0 coremltools):
    python convert_deepcw.py model.onnx DeepCW.mlpackage

The ONNX graph is first rewritten into plain float ops that onnx2torch understands, with
outputs checked against the original in ONNX Runtime at every step:
  1. weight DequantizeLinear nodes are folded into float initializers, and activation
     QuantizeLinear -> DequantizeLinear pairs become the same fake-quant arithmetic;
  2. Reshape allowzero=1 becomes 0 (no shape in this model contains a literal 0);
  3. the ScatterND-built sinusoidal positional encoding becomes interleave-by-reshape;
  4. Split(num_outputs=2) gets explicit sizes.
Then ONNX -> PyTorch -> traced -> Core ML (mlprogram, float32, iOS 17). The trace fixes
the time axis at 801 frames (12 s at 3200 Hz, hop 48), which is the window OrbitDeck runs.
"""
import sys

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnx import TensorProto, helper, numpy_helper
from onnx2torch import convert
from onnx2torch.node_converters.registry import add_converter
from onnx2torch.utils.common import OperationConverterResult, onnx_mapping_from_node
from torch import nn

FRAMES = 801
BINS = 65


def fold_qdq(m):
    g = m.graph
    init = {i.name: i for i in g.initializer}
    arr = lambda n: numpy_helper.to_array(init[n])
    qout = {n.output[0]: n for n in g.node if n.op_type == 'QuantizeLinear'}
    out = []
    for n in g.node:
        if n.op_type == 'DequantizeLinear' and n.input[0] in init:
            q, s, zp = (arr(n.input[i]).astype(np.float32) for i in range(3))
            axis = next((a.i for a in n.attribute if a.name == 'axis'), 1)
            if s.ndim == 1 and q.ndim > 1:
                shape = [1] * q.ndim
                shape[axis] = -1
                s, zp = s.reshape(shape), zp.reshape(shape)
            g.initializer.append(numpy_helper.from_array(((q - zp) * s).astype(np.float32), n.output[0]))
        elif n.op_type == 'QuantizeLinear':
            continue
        elif n.op_type == 'DequantizeLinear' and n.input[0] in qout:
            q = qout[n.input[0]]
            s, zp = float(arr(q.input[1])), float(arr(q.input[2]))
            lo, hi = (-128.0, 127.0) if init[q.input[2]].data_type == TensorProto.INT8 else (0.0, 255.0)
            p = n.output[0] + '_fq'
            for name, v in ((p + '_s', s), (p + '_zp', zp), (p + '_lo', lo), (p + '_hi', hi)):
                g.initializer.append(numpy_helper.from_array(np.array(v, np.float32), name))
            out += [helper.make_node('Div', [q.input[0], p + '_s'], [p + '_a']),
                    helper.make_node('Round', [p + '_a'], [p + '_b']),
                    helper.make_node('Add', [p + '_b', p + '_zp'], [p + '_c']),
                    helper.make_node('Clip', [p + '_c', p + '_lo', p + '_hi'], [p + '_d']),
                    helper.make_node('Sub', [p + '_d', p + '_zp'], [p + '_e']),
                    helper.make_node('Mul', [p + '_e', p + '_s'], [n.output[0]])]
        else:
            out.append(n)
    del g.node[:]
    g.node.extend(out)


def plain_reshape_and_split(m):
    g = m.graph
    g.initializer.append(numpy_helper.from_array(np.array([192, 192], np.int64), 'split_192_192'))
    out = []
    for n in g.node:
        if n.op_type == 'Reshape':
            for a in n.attribute:
                if a.name == 'allowzero':
                    a.i = 0
            out.append(n)
        elif n.op_type == 'Split':
            out.append(helper.make_node('Split', [n.input[0], 'split_192_192'], list(n.output), axis=1))
        else:
            out.append(n)
    del g.node[:]
    g.node.extend(out)


def interleave_positional_encoding(m):
    g = m.graph
    consumers = {}
    for n in g.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)
    final = next(c for c in consumers['val_174'] if c.op_type == 'Transpose')
    g.initializer.extend([numpy_helper.from_array(np.array([-1], np.int64), 'pe_axis'),
                          numpy_helper.from_array(np.array([-1, 192], np.int64), 'pe_shape')])
    nodes = [n for n in g.node if n is not final]
    at = max(i for i, n in enumerate(nodes) if 'copy_1' in n.output) + 1
    nodes[at:at] = [helper.make_node('Unsqueeze', ['copy', 'pe_axis'], ['pe_sin']),
                    helper.make_node('Unsqueeze', ['copy_1', 'pe_axis'], ['pe_cos']),
                    helper.make_node('Concat', ['pe_sin', 'pe_cos'], ['pe_pair'], axis=-1),
                    helper.make_node('Reshape', ['pe_pair', 'pe_shape'], [final.output[0]])]
    needed = {o.name for o in g.output}
    live = []
    for n in reversed(nodes):
        if any(o in needed for o in n.output):
            live.append(n)
            needed.update(n.input)
    del g.node[:]
    g.node.extend(reversed(live))


class SplitSizes(nn.Module):
    def __init__(self, sizes, axis):
        super().__init__()
        self.sizes, self.axis = sizes, axis

    def forward(self, x, *_):
        return tuple(torch.split(x, self.sizes, dim=self.axis))


@add_converter(operation_type='Split', version=18)
def _split18(node, graph):
    sizes = graph.initializers[node.input_values[1]].to_torch().tolist()
    return OperationConverterResult(torch_module=SplitSizes(sizes, node.attributes.get('axis', 0)),
                                    onnx_mapping=onnx_mapping_from_node(node))


def check(reference, candidate, label):
    rng = np.random.default_rng(0)
    x = np.log1p(np.abs(rng.normal(size=(1, 1, FRAMES, BINS))).astype(np.float32) * 3)
    a = reference({'spectrogram': x})
    b = candidate({'spectrogram': x})
    agree = (a.argmax(-1) == b.argmax(-1)).mean()
    print(f'{label}: max |diff| {np.abs(a - b).max():.2e}, argmax agreement {agree:.4f}')
    assert agree == 1.0, label


def main():
    src, dst = sys.argv[1], sys.argv[2]
    ref = ort.InferenceSession(src)
    run_ref = lambda feed: ref.run(None, feed)[0]

    m = onnx.load(src)
    fold_qdq(m)
    plain_reshape_and_split(m)
    interleave_positional_encoding(m)
    onnx.checker.check_model(m)
    rewritten = ort.InferenceSession(m.SerializeToString())
    check(run_ref, lambda feed: rewritten.run(None, feed)[0], 'rewritten ONNX')

    torch_model = convert(m).eval()
    with torch.no_grad():
        check(run_ref, lambda feed: torch_model(torch.from_numpy(feed['spectrogram'])).numpy(), 'PyTorch')
        traced = torch.jit.trace(torch_model, torch.zeros(1, 1, FRAMES, BINS), check_trace=False)

    ml = ct.convert(traced,
                    inputs=[ct.TensorType(name='spectrogram', shape=(1, 1, FRAMES, BINS), dtype=np.float32)],
                    outputs=[ct.TensorType(name='log_probs', dtype=np.float32)],
                    minimum_deployment_target=ct.target.iOS17,
                    compute_precision=ct.precision.FLOAT32, convert_to='mlprogram')
    ml.short_description = ('DeepCW neural Morse decoder by e04 (MIT License). Input: noise-normalized log1p '
                            'magnitude spectrogram, 400-1200 Hz at 3200 Hz, FFT 256, hop 48, 801 frames. '
                            'Output: CTC log-probabilities, 401 frames x 42 classes.')
    ml.author = 'e04 (DeepCW, MIT License). Converted to Core ML for OrbitDeck.'
    ml.license = 'MIT'
    ml.save(dst)
    saved = ct.models.MLModel(dst, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    check(run_ref, lambda feed: saved.predict(feed)['log_probs'], 'Core ML')
    print('saved', dst)


if __name__ == '__main__':
    main()
