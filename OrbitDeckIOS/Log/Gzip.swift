import Foundation
import Compression

// ===========================================================================
//  Gzip.swift — pure-Swift gzip (RFC 1952) for the LoTW .tq8
//
//  Apple's Compression framework produces raw DEFLATE (RFC 1951) with
//  COMPRESSION_ZLIB; wrapping it with the 10-byte gzip header and the CRC-32 +
//  ISIZE trailer yields a valid .gz. This keeps LoTW upload in pure Swift — no
//  libz, no bridging header (only ft8_lib needs C).
// ===========================================================================

enum Gzip {
    /// gzip-compress `data`, or nil if the DEFLATE stage fails.
    static func compress(_ data: Data) -> Data? {
        guard let deflated = rawDeflate(data) else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00,        // magic, CM=deflate, FLG=0
                        0x00, 0x00, 0x00, 0x00,        // MTIME=0
                        0x00, 0xff])                   // XFL=0, OS=255 (unknown)
        out.append(deflated)
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    /// Raw DEFLATE (headerless) via the Compression framework.
    private static func rawDeflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // Worst case for incompressible data is slightly larger than input.
            var cap = data.count + (data.count / 2) + 64
            var dst = Data(count: cap)
            let written = dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
                guard let dstBase = out.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, cap, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }
            guard written > 0 else { return nil }
            dst.removeSubrange(written..<dst.count)
            _ = cap   // silence unused-mutation warning on some toolchains
            cap = 0
            return dst
        }
    }

    // MARK: CRC-32 (IEEE 802.3, the gzip polynomial)

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
