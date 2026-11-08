import Foundation

// MARK: - Safe scientific expression evaluator

enum SafeMathError: LocalizedError, Equatable {
    case emptyExpression
    case unexpectedToken(String)
    case unknownName(String)
    case badFunction(String)
    case divisionByZero
    case domain(String)

    var errorDescription: String? {
        switch self {
        case .emptyExpression: "Empty expression"
        case .unexpectedToken(let token): "Unexpected token: \(token)"
        case .unknownName(let name): "Unknown name: \(name)"
        case .badFunction(let name): "Unknown function: \(name)"
        case .divisionByZero: "Division by zero"
        case .domain(let message): message
        }
    }
}

private enum MathToken: Equatable {
    case number(Double)
    case name(String)
    case plus, minus, star, slash, percent, caret
    case lparen, rparen, comma
    case end
}

private struct MathLexer {
    let chars: [Character]
    var index: Int = 0

    init(_ text: String) {
        chars = Array(text.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/"))
    }

    /// SI metric-prefix multipliers (case-sensitive: m = milli, M = mega).
    static func metricPrefix(_ c: Character) -> Double? {
        switch c {
        case "f": return 1e-15
        case "p": return 1e-12
        case "n": return 1e-9
        case "u", "µ": return 1e-6
        case "m": return 1e-3
        case "k": return 1e3
        case "M": return 1e6
        case "G": return 1e9
        case "T": return 1e12
        default: return nil
        }
    }

    mutating func next() throws -> MathToken {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        guard index < chars.count else { return .end }
        let c = chars[index]
        index += 1
        switch c {
        case "+": return .plus
        case "-": return .minus
        case "*": return .star
        case "/": return .slash
        case "%": return .percent
        case "^": return .caret
        case "(": return .lparen
        case ")": return .rparen
        case ",": return .comma
        default:
            if c.isNumber || c == "." {
                var s = String(c)
                while index < chars.count {
                    let n = chars[index]
                    if n.isNumber || n == "." || n == "e" || n == "E" || ((n == "+" || n == "-") && (s.last == "e" || s.last == "E")) {
                        s.append(n); index += 1
                    } else { break }
                }
                guard let v = Double(s) else { throw SafeMathError.unexpectedToken(s) }
                // Metric prefix suffix (100k, 2.2n, 5M) — only when the prefix
                // letter stands alone (not the head of a function/identifier).
                if index < chars.count {
                    let p = chars[index]
                    let after = index + 1 < chars.count ? chars[index + 1] : " "
                    let identTail = after.isLetter || after.isNumber || after == "_"
                    if !identTail, let mult = Self.metricPrefix(p) {
                        index += 1
                        return .number(v * mult)
                    }
                }
                return .number(v)
            }
            if c.isLetter || c == "_" {
                var s = String(c)
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                    s.append(chars[index]); index += 1
                }
                return .name(s.lowercased())
            }
            throw SafeMathError.unexpectedToken(String(c))
        }
    }
}

struct SafeMathEvaluator: Sendable {
    /// `degrees == true` evaluates trig in degrees (what a ham calculator expects,
    /// matching CardSat). The default stays radians so Tiny BASIC and other
    /// callers that pre-convert are unaffected.
    func evaluate(_ expression: String, variables: [String: Double] = [:], degrees: Bool = false) throws -> Double {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SafeMathError.emptyExpression }
        var parser = try MathParser(text: trimmed, variables: variables, degrees: degrees)
        return try parser.parse()
    }
}

private struct MathParser {
    var lexer: MathLexer
    var look: MathToken
    let variables: [String: Double]
    let degrees: Bool

    init(text: String, variables: [String: Double], degrees: Bool = false) throws {
        var lex = MathLexer(text)
        let first = try lex.next()
        self.lexer = lex
        self.look = first
        self.degrees = degrees
        self.variables = Dictionary(uniqueKeysWithValues: variables.map { ($0.key.lowercased(), $0.value) })
    }

    mutating func advance() throws { look = try lexer.next() }

    mutating func parse() throws -> Double {
        let value = try expression()
        guard look == .end else { throw SafeMathError.unexpectedToken("trailing input") }
        guard value.isFinite else { throw SafeMathError.domain("Result is not finite") }
        return value
    }

    mutating func expression() throws -> Double {
        var value = try term()
        while true {
            if look == .plus { try advance(); value += try term() }
            else if look == .minus { try advance(); value -= try term() }
            else { return value }
        }
    }

    mutating func term() throws -> Double {
        var value = try power()
        while true {
            if look == .star { try advance(); value *= try power() }
            else if look == .slash {
                try advance(); let rhs = try power(); guard rhs != 0 else { throw SafeMathError.divisionByZero }; value /= rhs
            } else if look == .percent {
                try advance(); let rhs = try power(); guard rhs != 0 else { throw SafeMathError.divisionByZero }; value.formTruncatingRemainder(dividingBy: rhs)
            } else { return value }
        }
    }

    mutating func power() throws -> Double {
        var value = try unary()
        if look == .caret {
            try advance(); value = Foundation.pow(value, try power())
        }
        return value
    }

    mutating func unary() throws -> Double {
        if look == .plus { try advance(); return try unary() }
        if look == .minus { try advance(); return -(try unary()) }
        return try primary()
    }

    mutating func primary() throws -> Double {
        switch look {
        case .number(let value):
            try advance(); return value
        case .name(let name):
            try advance()
            if look == .lparen {
                try advance()
                var args: [Double] = []
                if look != .rparen {
                    while true {
                        args.append(try expression())
                        if look == .comma { try advance(); continue }
                        break
                    }
                }
                guard look == .rparen else { throw SafeMathError.unexpectedToken("expected )") }
                try advance()
                return try call(name, args)
            }
            if let value = variables[name] { return value }
            switch name {
            case "pi": return .pi
            case "e": return M_E
            case "tau": return 2 * .pi
            case "c": return 299_792_458            // speed of light, m/s
            case "kb": return 1.380649e-23           // Boltzmann, J/K
            case "re": return 6378.137               // Earth equatorial radius, km
            case "mu": return 398_600.4418           // Earth GM, km³/s²
            case "g0": return 9.80665                // standard gravity, m/s²
            default: break
            }
            throw SafeMathError.unknownName(name)
        case .lparen:
            try advance(); let value = try expression()
            guard look == .rparen else { throw SafeMathError.unexpectedToken("expected )") }
            try advance(); return value
        default:
            throw SafeMathError.unexpectedToken("expression")
        }
    }

    private func call(_ name: String, _ a: [Double]) throws -> Double {
        func one(_ fn: (Double) -> Double) throws -> Double {
            guard a.count == 1 else { throw SafeMathError.domain("\(name) expects one argument") }
            return fn(a[0])
        }
        func two(_ fn: (Double, Double) -> Double) throws -> Double {
            guard a.count == 2 else { throw SafeMathError.domain("\(name) expects two arguments") }
            return fn(a[0], a[1])
        }
        let d2r = Double.pi / 180, r2d = 180 / Double.pi
        let cLight = 299_792_458.0, muKm = 398_600.4418, reKm = 6378.137
        // Trig honors the degrees mode (matches CardSat's ham-oriented default).
        let toRad: (Double) -> Double = degrees ? { $0 * d2r } : { $0 }
        let fromRad: (Double) -> Double = degrees ? { $0 * r2d } : { $0 }
        switch name {
        case "sqrt": return try one { sqrt($0) }
        case "cbrt": return try one { Foundation.cbrt($0) }
        case "sin": return try one { sin(toRad($0)) }
        case "cos": return try one { cos(toRad($0)) }
        case "tan": return try one { tan(toRad($0)) }
        case "asin": return try one { fromRad(asin($0)) }
        case "acos": return try one { fromRad(acos($0)) }
        case "atan": return try one { fromRad(atan($0)) }
        case "sinh": return try one { sinh($0) }
        case "cosh": return try one { cosh($0) }
        case "tanh": return try one { tanh($0) }
        case "ln", "log": return try one { log($0) }
        case "log10": return try one { log10($0) }
        case "log2": return try one { log2($0) }
        case "exp": return try one { exp($0) }
        case "abs": return try one { abs($0) }
        case "floor": return try one { floor($0) }
        case "ceil": return try one { ceil($0) }
        case "round": return try one { $0.rounded() }
        case "sign": return try one { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        case "fact": return try one { tgamma($0 + 1) }
        case "deg", "degrees", "r2d": return try one { $0 * r2d }
        case "rad", "radians", "d2r": return try one { $0 * d2r }
        case "atan2": return try two { fromRad(atan2($0, $1)) }
        case "hypot": return try two { hypot($0, $1) }
        case "pow": return try two { Foundation.pow($0, $1) }
        case "mod": return try two { $1 == 0 ? .nan : fmod($0, $1) }
        case "ncr": return try two { exp(lgamma($0 + 1) - lgamma($1 + 1) - lgamma($0 - $1 + 1)).rounded() }
        case "npr": return try two { exp(lgamma($0 + 1) - lgamma($0 - $1 + 1)).rounded() }
        case "min": guard !a.isEmpty else { throw SafeMathError.domain("min expects arguments") }; return a.min()!
        case "max": guard !a.isEmpty else { throw SafeMathError.domain("max expects arguments") }; return a.max()!
        // RF / antenna helpers (matching CardSat's calculator functions).
        case "db": return try one { 10 * log10($0) }
        case "undb": return try one { Foundation.pow(10, $0 / 10) }
        case "dbm2w", "w": return try one { Foundation.pow(10, ($0 - 30) / 10) }
        case "w2dbm", "dbm": return try one { 10 * log10($0) + 30 }
        case "dbd": return try one { $0 - 2.15 }       // dBi → dBd
        case "dbi": return try one { $0 + 2.15 }       // dBd → dBi
        case "lam", "wl": return try one { $0 > 0 ? cLight / 1e6 / $0 : .nan }   // MHz → wavelength (m)
        case "fq": return try one { $0 > 0 ? cLight / 1e6 / $0 : .nan }          // wavelength (m) → MHz
        case "dipole": return try one { $0 > 0 ? 0.95 * (cLight / 1e6 / $0) / 2 : .nan }
        case "fspl": return try two { 32.44 + 20 * log10(max($1, 1e-9)) + 20 * log10(max($0, 1e-9)) } // (MHz, km)
        case "dop": return try two { -($1 * 1000 / cLight) * $0 * 1e6 }          // (MHz, km/s) → Hz
        case "swr2rl": return try one { let g = abs(($0 - 1) / ($0 + 1)); return g > 0 ? -20 * log10(g) : .infinity }
        case "rl2swr": return try one { let g = Foundation.pow(10, -$0 / 20); return (1 + g) / (1 - g) }
        case "mml": return try one { let g = ($0 - 1) / ($0 + 1); return -10 * log10(max(1e-15, 1 - g * g)) }
        case "nf2t": return try one { 290 * (Foundation.pow(10, $0 / 10) - 1) }
        case "t2nf": return try one { 10 * log10(1 + $0 / 290) }
        case "porb": return try one { let r = reKm + max(1, $0); return 2 * Double.pi * sqrt(r * r * r / muKm) / 60 } // alt km → min
        case "vorb": return try one { sqrt(muKm / (reKm + max(1, $0))) }         // alt km → km/s
        case "fpr": return try one { let r = reKm + max(1, $0); return reKm * acos(reKm / r) } // alt km → footprint km
        case "aorb": return try one { let n = $0 * 60 / (2 * Double.pi); return Foundation.cbrt(muKm * n * n) - reKm } // period min → alt km
        case "slant": return try two { let el = $0 * d2r, h = $1; return sqrt(reKm * reKm * sin(el) * sin(el) + 2 * reKm * h + h * h) - reKm * sin(el) }
        case "dgain": return try two { 10 * log10(0.55) + 20 * log10(Double.pi * $0 * $1 / (cLight / 1e6)) } // (dish m, MHz) → dBi
        default: throw SafeMathError.badFunction(name)
        }
    }
}

struct GraphPoint: Identifiable, Sendable {
    let id: Int
    let x: Double
    let y: Double?
}

struct GraphCalculatorEngine: Sendable {
    let evaluator = SafeMathEvaluator()

    func sample(_ expression: String, xmin: Double, xmax: Double, count: Int = 600) -> [GraphPoint] {
        guard xmax > xmin, count > 1 else { return [] }
        let step = (xmax - xmin) / Double(count - 1)
        return (0..<count).map { index in
            let x = xmin + Double(index) * step
            let y = try? evaluator.evaluate(expression, variables: ["x": x], degrees: true)
            let valid = y.flatMap { $0.isFinite && abs($0) < 1e12 ? $0 : nil }
            return GraphPoint(id: index, x: x, y: valid)
        }
    }
}

// MARK: - Bench tools

struct ToolField: Identifiable, Sendable {
    let id: String
    let label: String
    let defaultValue: Double
    let unit: String
    let choices: [String]?
    let isText: Bool
    let defaultText: String?

    init(id: String, label: String, defaultValue: Double, unit: String, choices: [String]? = nil, isText: Bool = false, defaultText: String? = nil) {
        self.id = id
        self.label = label
        self.defaultValue = defaultValue
        self.unit = unit
        self.choices = choices
        self.isText = isText
        self.defaultText = defaultText
    }
}

struct ToolResult: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let value: String
    let note: String
}

struct ToolDefinition: Identifiable, Sendable {
    let id: String
    let category: String
    let name: String
    let description: String
    let fields: [ToolField]
}

enum BenchTools {
    static let tools: [ToolDefinition] = [
        .init(id: "dipole", category: "Antennas & feedline", name: "Dipole length", description: "Half-wave dipole using the traditional 468/f end-effect starting point.", fields: [.init(id: "freq", label: "Frequency", defaultValue: 14.2, unit: "MHz")]),
        .init(id: "vertical", category: "Antennas & feedline", name: "Vertical / ground plane", description: "Quarter-wave radiator and radial starting lengths.", fields: [.init(id: "freq", label: "Frequency", defaultValue: 146, unit: "MHz")]),
        .init(id: "wavelength", category: "Antennas & feedline", name: "Wavelength / frequency", description: "Free-space wavelength and common fractional lengths.", fields: [.init(id: "freq", label: "Frequency", defaultValue: 146, unit: "MHz")]),
        .init(id: "fspl", category: "RF & measurement", name: "Free-space path loss", description: "Ideal free-space attenuation for a distance and frequency.", fields: [.init(id: "distance", label: "Distance", defaultValue: 1000, unit: "km"), .init(id: "freq", label: "Frequency", defaultValue: 145.8, unit: "MHz")]),
        .init(id: "swr", category: "RF & measurement", name: "SWR / return loss", description: "Reflection coefficient, return loss, and mismatch loss from SWR.", fields: [.init(id: "swr", label: "SWR", defaultValue: 2, unit: "")]),
        .init(id: "rfpower", category: "RF & measurement", name: "RF units (W / dBm / V)", description: "Convert RF power into dBm/dBW and RMS voltage in 50 ohms.", fields: [.init(id: "watts", label: "Power", defaultValue: 100, unit: "W")]),
        .init(id: "reactance", category: "Electronics & power", name: "Reactance & resonance", description: "Inductive/capacitive reactance and LC resonant frequency.", fields: [.init(id: "freq", label: "Frequency", defaultValue: 7, unit: "MHz"), .init(id: "l", label: "Inductance", defaultValue: 10, unit: "µH"), .init(id: "c", label: "Capacitance", defaultValue: 100, unit: "pF")]),
        .init(id: "battery", category: "Electronics & power", name: "Battery runtime", description: "Approximate station runtime under a TX/RX duty cycle.", fields: [.init(id: "ah", label: "Capacity", defaultValue: 20, unit: "Ah"), .init(id: "rx", label: "RX draw", defaultValue: 0.5, unit: "A"), .init(id: "tx", label: "TX draw", defaultValue: 8, unit: "A"), .init(id: "duty", label: "TX duty", defaultValue: 30, unit: "%"), .init(id: "usable", label: "Usable", defaultValue: 80, unit: "%")]),
        .init(id: "horizon", category: "Terrestrial VHF/UHF", name: "Radio horizon", description: "4/3-Earth line-of-sight horizon for two antennas.", fields: [.init(id: "h1", label: "My antenna", defaultValue: 10, unit: "m"), .init(id: "h2", label: "Their antenna", defaultValue: 10, unit: "m"), .init(id: "k", label: "k factor", defaultValue: 1.33, unit: "")]),
        .init(id: "fresnel", category: "Terrestrial VHF/UHF", name: "Fresnel zone clearance", description: "First Fresnel-zone radius at path midpoint and 60% clearance target.", fields: [.init(id: "distance", label: "Path length", defaultValue: 30, unit: "km"), .init(id: "freq", label: "Frequency", defaultValue: 144, unit: "MHz")]),
        .init(id: "doppler", category: "Satellite", name: "Doppler shift", description: "One-way Doppler shift from frequency and range rate.", fields: [.init(id: "freq", label: "Frequency", defaultValue: 145.8, unit: "MHz"), .init(id: "rr", label: "Range rate", defaultValue: -5, unit: "km/s")]),
        .init(id: "orbit", category: "Satellite", name: "Circular orbit from altitude", description: "Period, speed, and footprint radius for a circular orbit.", fields: [.init(id: "alt", label: "Altitude", defaultValue: 500, unit: "km")]),
        .init(id: "link", category: "Satellite", name: "Simple link budget", description: "Free-space received power and margin from EIRP, path, receive gain, and sensitivity.", fields: [.init(id: "freq", label: "Frequency", defaultValue: 145.8, unit: "MHz"), .init(id: "range", label: "Range", defaultValue: 1000, unit: "km"), .init(id: "eirp", label: "TX EIRP", defaultValue: 27, unit: "dBm"), .init(id: "rxgain", label: "RX gain", defaultValue: 6, unit: "dBi"), .init(id: "sens", label: "Sensitivity", defaultValue: -120, unit: "dBm")])
    ]

    static func results(for id: String, values: [String: Double]) -> [ToolResult] {
        func v(_ k: String, _ fallback: Double = 0) -> Double { values[k] ?? fallback }
        func row(_ label: String, _ value: String, _ note: String = "") -> ToolResult { .init(label: label, value: value, note: note) }
        switch id {
        case "dipole":
            let f = max(v("freq"), 0.001); let totalFt = 468 / f
            return [row("Overall", String(format: "%.2f ft", totalFt)), row("Each leg", String(format: "%.2f ft", totalFt/2)), row("Overall", String(format: "%.2f m", totalFt*0.3048))]
        case "vertical":
            let f = max(v("freq"), 0.001); let ft = 234 / f
            return [row("Radiator", String(format: "%.2f ft", ft)), row("Radial", String(format: "%.2f ft", ft)), row("Metric", String(format: "%.2f m", ft*0.3048))]
        case "wavelength":
            let f = max(v("freq"), 0.001); let m = 299.792458 / f
            return [row("Wavelength", String(format: "%.4f m", m)), row("Half wave", String(format: "%.4f m", m/2)), row("Quarter wave", String(format: "%.4f m", m/4))]
        case "fspl":
            let d = max(v("distance"), 1e-9); let f = max(v("freq"), 1e-9); let loss = 32.44 + 20*log10(d) + 20*log10(f)
            return [row("FSPL", String(format: "%.2f dB", loss)), row("Linear loss", String(format: "%.3e", pow(10, loss/10)))]
        case "swr":
            let swr = max(v("swr"), 1); let gamma = (swr-1)/(swr+1); let rl = gamma > 0 ? -20*log10(gamma) : .infinity; let ml = -10*log10(max(1e-15, 1-gamma*gamma))
            return [row("Reflection |Γ|", String(format: "%.4f", gamma)), row("Return loss", rl.isFinite ? String(format: "%.2f dB", rl) : "∞ dB"), row("Mismatch loss", String(format: "%.3f dB", ml))]
        case "rfpower":
            let w = max(v("watts"), 1e-15); let dbm = 10*log10(w*1000); let volts = sqrt(w*50)
            return [row("dBm", String(format: "%.2f dBm", dbm)), row("dBW", String(format: "%.2f dBW", dbm-30)), row("50 Ω Vrms", String(format: "%.2f V", volts))]
        case "reactance":
            let f = max(v("freq"), 1e-9)*1e6; let l = max(v("l"), 1e-12)*1e-6; let c = max(v("c"), 1e-12)*1e-12
            return [row("XL", String(format: "%.2f Ω", 2*Double.pi*f*l)), row("XC", String(format: "%.2f Ω", 1/(2*Double.pi*f*c))), row("Resonance", String(format: "%.4f MHz", 1/(2*Double.pi*sqrt(l*c))/1e6))]
        case "battery":
            let avg = max(1e-9, v("rx")*(1-v("duty")/100) + v("tx")*v("duty")/100); let usable = v("ah")*max(0,min(100,v("usable")))/100
            return [row("Average draw", String(format: "%.2f A", avg)), row("Usable capacity", String(format: "%.1f Ah", usable)), row("Runtime", String(format: "%.1f h", usable/avg))]
        case "horizon":
            let k = max(0.1, v("k")); let re = 6371*k
            func h(_ meters: Double) -> Double { sqrt(2*re*max(0,meters)/1000) }
            let a = h(v("h1")), b = h(v("h2")); return [row("My horizon", String(format: "%.1f km", a)), row("Their horizon", String(format: "%.1f km", b)), row("Max LOS", String(format: "%.1f km", a+b))]
        case "fresnel":
            let d = max(v("distance"), 0.001); let fGHz = max(v("freq")/1000, 1e-9); let r = 8.657 * sqrt(d/fGHz)
            return [row("F1 midpoint", String(format: "%.1f m", r)), row("60% clearance", String(format: "%.1f m", 0.6*r))]
        case "doppler":
            let c = 299792.458; let shift = -(v("rr")/c)*(v("freq")*1e6)
            return [row("Shift", String(format: "%+.0f Hz", shift)), row("Observed", String(format: "%.6f MHz", (v("freq")*1e6+shift)/1e6))]
        case "orbit":
            let re=6378.135, mu=398600.4418, r=re+max(1,v("alt")); let period=2*Double.pi*sqrt(pow(r,3)/mu); let speed=sqrt(mu/r); let psi=acos(re/r); let footprint=re*psi
            return [row("Period", String(format: "%.2f min", period/60)), row("Speed", String(format: "%.3f km/s", speed)), row("Footprint radius", String(format: "%.0f km", footprint)), row("Angular radius", String(format: "%.1f°", psi * 180 / Double.pi))]
        case "link":
            let loss=32.44+20*log10(max(v("range"),1e-9))+20*log10(max(v("freq"),1e-9)); let rx=v("eirp")-loss+v("rxgain"); let margin=rx-v("sens")
            return [row("FSPL", String(format: "%.1f dB", loss)), row("RX power", String(format: "%.1f dBm", rx)), row("Margin", String(format: "%+.1f dB", margin), margin >= 0 ? "workable by this simple model" : "below sensitivity")]
        default: return [row("Error", "Unknown tool")]
        }
    }
}

// MARK: - Static references

struct ReferenceRow: Identifiable, Sendable {
    let id = UUID(); let a: String; let b: String; let c: String
}
struct ReferenceTable: Identifiable, Sendable {
    let id: String; let name: String; let description: String; let headers: [String]; let rows: [ReferenceRow]
}

enum OrbitReferences {
    static let ctcss: [Double] = [67.0,69.3,71.9,74.4,77.0,79.7,82.5,85.4,88.5,91.5,94.8,97.4,100.0,103.5,107.2,110.9,114.8,118.8,123.0,127.3,131.8,136.5,141.3,146.2,151.4,156.7,159.8,162.2,165.5,167.9,171.3,173.8,177.3,179.9,183.5,186.2,189.9,192.8,196.6,199.5,203.5,206.5,210.7,218.1,225.7,229.1,233.6,241.8,250.3,254.1]
    static let qcodes = [("QRA","Station name"),("QRG","Exact frequency"),("QRL","Busy"),("QRM","Man-made interference"),("QRN","Natural noise"),("QRO","Increase power"),("QRP","Decrease power / low power"),("QRQ","Send faster"),("QRS","Send slower"),("QRT","Stop sending"),("QRV","Ready"),("QRX","Wait / stand by"),("QRZ","Who is calling me?"),("QSB","Signal fading"),("QSL","Acknowledge receipt"),("QSO","Contact / conversation"),("QSY","Change frequency"),("QTH","Location"),("QTR","Correct time")]
    static let phonetic = ["A Alfa","B Bravo","C Charlie","D Delta","E Echo","F Foxtrot","G Golf","H Hotel","I India","J Juliett","K Kilo","L Lima","M Mike","N November","O Oscar","P Papa","Q Quebec","R Romeo","S Sierra","T Tango","U Uniform","V Victor","W Whiskey","X X-ray","Y Yankee","Z Zulu"]

    static let tables: [ReferenceTable] = {
        let toneRows = ctcss.enumerated().map { ReferenceRow(a: String(format:"%02d",$0.offset+1), b: String(format:"%.1f Hz",$0.element), c: $0.offset < 38 ? "Motorola PL" : "extended EIA") }
        let qRows = qcodes.map { ReferenceRow(a:$0.0,b:"",c:$0.1) }
        let cq = [("1-5","North America"),("6-8","Mexico, Central America, Caribbean, northern South America"),("9-13","South America"),("14-16","Europe"),("17-19","Asiatic Russia / Siberia"),("20-21","Balkans / Middle East"),("22-23","South / Central Asia"),("24-27","East and Southeast Asia"),("28-32","Philippines, Indonesia, Australia, Oceania"),("33-38","Africa"),("39-40","Madagascar region / Arctic")].map { ReferenceRow(a:$0.0,b:$0.1,c:"") }
        let itu = [("1-9","North America & Greenland"),("10-16","South America"),("17-27","Western/Central Europe & North Africa"),("28-38","Eastern Europe, Middle East, Africa"),("39-52","Asia & Indian Ocean"),("53-64","Central/Southern Africa & western Oceania"),("65-75","Australia & Pacific"),("76-90","Asiatic Russia, Arctic, far NE Asia")].map { ReferenceRow(a:$0.0,b:$0.1,c:"") }
        let ascii = (32...126).map { ReferenceRow(a:"\($0)", b:$0 == 32 ? "space" : String(UnicodeScalar($0)!), c:String(format:"0x%02X",$0)) }
        let pho = phonetic.map { let p=$0.split(separator:" ",maxSplits:1); return ReferenceRow(a:String(p[0]),b:p.count>1 ? String(p[1]):"",c:"") }
        let rst = [ReferenceRow(a:"R",b:"1-5",c:"Readability: unreadable → perfectly readable"),ReferenceRow(a:"S",b:"1-9",c:"Strength: faint → extremely strong"),ReferenceRow(a:"T",b:"1-9",c:"CW tone: rough → pure tone"),ReferenceRow(a:"Satellite",b:"RS",c:"SSB/FM voice reports normally omit tone")]
        let math = [ReferenceRow(a:"dB",b:"10 log(P/P0)",c:"+3 dB ≈ ×2 power"),ReferenceRow(a:"Voltage dB",b:"20 log(V/V0)",c:"same impedance"),ReferenceRow(a:"Wavelength",b:"300 / f(MHz)",c:"meters"),ReferenceRow(a:"Quarter wave",b:"234 / f(MHz)",c:"feet, practical starting point"),ReferenceRow(a:"XC",b:"1 / (2πfC)",c:"ohms"),ReferenceRow(a:"XL",b:"2πfL",c:"ohms"),ReferenceRow(a:"Resonance",b:"1/(2π√LC)",c:"Hz"),ReferenceRow(a:"Ohm",b:"V=IR",c:"P=VI=I²R=V²/R")]
        let itaLetters = ["NUL","E","LF","A","SP","S","I","U","CR","D","R","J","N","F","C","K","T","Z","L","W","H","Y","P","Q","O","B","G","FIGS","M","X","V","LTRS"]
        let itaFigures = ["NUL","3","LF","-","SP","BEL","8","7","CR","$","4","'",",","!",":","(","5","\"",")","2","#","6","0","1","9","?","&","FIGS",".","/",";","LTRS"]
        let ita2 = (0..<32).map { ReferenceRow(a:String(format:"%02d / %05d",$0,Int(String($0,radix:2)) ?? 0),b:itaLetters[$0],c:itaFigures[$0]) }
        let morseMap:[String:String] = ["A":".-","B":"-...","C":"-.-.","D":"-..","E":".","F":"..-.","G":"--.","H":"....","I":"..","J":".---","K":"-.-","L":".-..","M":"--","N":"-.","O":"---","P":".--.","Q":"--.-","R":".-.","S":"...","T":"-","U":"..-","V":"...-","W":".--","X":"-..-","Y":"-.--","Z":"--..","0":"-----","1":".----","2":"..---","3":"...--","4":"....-","5":".....","6":"-....","7":"--...","8":"---..","9":"----."]
        let morse = morseMap.keys.sorted().map { ReferenceRow(a:$0,b:morseMap[$0] ?? "",c:"") }
        let orbitTypes = [("LEO","160–2000 km, 90–128 min","Most amateur satellites; short passes and high Doppler."),("Sun-synchronous","~600–800 km, i≈98°","Similar local-time crossings."),("MEO","2000–35786 km","Longer access and lower angular rates."),("Molniya","e≈0.74, i=63.4°, 12 h","Long dwell near high-latitude apogee."),("GEO","35786 km, i≈0°","Fixed in the sky; QO-100 is the amateur example."),("Polar","i≈90°","Reaches all latitudes."),("Retrograde","i>90°","Travels against Earth rotation.")].map { ReferenceRow(a:$0.0,b:ODFormat.units($0.1),c:$0.2) }
        let history = [("1961","OSCAR 1","First amateur satellite."),("1965","OSCAR 3","First amateur transponder."),("1974","AO-7","Mode A/B; returned to service after battery failure."),("1983","AO-10","Molniya-orbit Mode B satellite."),("1990","AO-16 / LO-19","Microsat digital store-and-forward era."),("1998","ISS","Amateur radio aboard the station."),("2013","FUNcube-1 / AO-73","Education payload and linear transponder."),("2019","QO-100","First amateur geostationary transponder."),("2022","IO-117 / GreenCube","MEO digipeater with long-range access.")].map { ReferenceRow(a:$0.0,b:$0.1,c:$0.2) }
        let bandPlan = [("2 m satellite","145.8–146.0 MHz","satellite subband"),("70 cm satellite","435–438 MHz","satellite subband"),("23 cm","1260–1270 MHz","common satellite uplink segment"),("13 cm","2400 MHz","S-band satellite use"),("3 cm","10.45 GHz","X-band satellite / microwave"),("Mode V/U (J)","145 up / 435 down","common LEO mode"),("Mode U/V (B)","435 up / 145 down","AO-7 Mode B etc."),("Mode L/U","1260 up / 435 down",""),("Mode U/S","435 up / 2400 down",""),("QO-100 NB","2400.25 up / 10489.75 down","geostationary")].map { ReferenceRow(a:$0.0,b:$0.1,c:$0.2) }
        // Worldwide amateur bands, LF to light. Ported from CardSat's band-plan screen
        // (the developer's own table) and expanded from the IARU Region 1, 2 and 3 band
        // plans and ITU Radio Regulations Article 5 (allocations). R1 = Europe/Africa/
        // Middle East, R2 = Americas, R3 = Asia-Pacific. A summary only: national
        // rules govern what you may use.
        let worldRaw: [(String, String, String)] = [
            ("2200 m", "135.7–137.8 kHz", "All regions, secondary; 1 W EIRP. CW/QRSS, WSPR 136.000 dial"),
            ("630 m", "472–479 kHz", "All regions, secondary; 1 W EIRP (5 W in places). WSPR 474.200 dial"),
            ("160 m", "1.810–2.000 MHz", "R1 1.810–2.000, R2 1.800–2.000, R3 1.800–2.000. CW 1.810–1.838; FT8 1.840"),
            ("80 m", "3.500–4.000 MHz", "R1 3.5–3.8, R2 3.5–4.0, R3 3.5–3.9. FT8 3.573; CW at the bottom"),
            ("60 m", "5.3515–5.3665 MHz", "WRC-15 band, 15 W EIRP; many countries use channels instead. FT8 5.357"),
            ("40 m", "7.000–7.300 MHz", "R1/R3 7.0–7.2, R2 7.0–7.3. FT8 7.074; CW QRP 7.030"),
            ("30 m", "10.100–10.150 MHz", "WARC, secondary; CW and narrow data only, no phone. FT8 10.136"),
            ("20 m", "14.000–14.350 MHz", "All regions. FT8 14.074; CW QRP 14.060; NCDXF beacons 14.100; SSTV 14.230"),
            ("17 m", "18.068–18.168 MHz", "WARC. FT8 18.100; beacons 18.110"),
            ("15 m", "21.000–21.450 MHz", "All regions. FT8 21.074; beacons 21.150; satellite H band"),
            ("12 m", "24.890–24.990 MHz", "WARC. FT8 24.915; beacons 24.930"),
            ("10 m", "28.000–29.700 MHz", "All regions. FT8 28.074; beacons 28.200; satellites 29.300–29.510; FM 29.520–29.700 (simplex 29.600)"),
            ("6 m", "50–54 MHz", "R2/R3 50–54; R1 50–52 (WRC-19), national rules vary"),
            ("6 m calling", "50.110 / 50.125 / 50.150", "50.110 intercontinental DX; 50.125 R2 SSB call; 50.150 R1 SSB; 50.090 CW; 50.313 FT8; 52.525 FM simplex (R2)"),
            ("4 m", "70.0–70.5 MHz", "R1 only, some countries; none in R2/R3. 70.200 SSB call"),
            ("2 m", "144–148 MHz", "R1 144–146, R2 144–148, R3 144–148 (144–146 in some countries)"),
            ("2 m weak signal", "144.050 / 144.200 / 144.300", "144.050 CW call; SSB call 144.200 (R2) or 144.300 (R1); FT8 144.174"),
            ("2 m EME", "144.100–144.160 MHz", "CW; JT65/Q65 around 144.115–144.140"),
            ("2 m satellite", "145.800–146.000 MHz", "Worldwide amateur-satellite subband (ISS voice down 145.800)"),
            ("2 m FM", "146.520 / 145.500 MHz", "National simplex calling: 146.520 (R2/US), 145.500 (R1)"),
            ("1.25 m", "222–225 MHz", "R2 only (US also 219–220 data). 222.100 SSB/CW call; 223.500 FM simplex"),
            ("70 cm", "430–440 MHz", "R1 430–440, R2 420–450 (US), R3 430–440"),
            ("70 cm calling", "432.100 / 446.000 / 433.500", "432.100 SSB/CW; 432.174 FT8; 446.000 FM simplex (US); 433.500 FM (R1)"),
            ("70 cm EME", "432.000–432.070 MHz", "CW; JT65/Q65 near 432.065"),
            ("70 cm satellite", "435.000–438.000 MHz", "Worldwide amateur-satellite subband"),
            ("33 cm", "902–928 MHz", "R2 only. Weak signal 902.100 / 903.100"),
            ("23 cm", "1240–1300 MHz", "All regions, secondary. 1296.100 SSB/CW call; satellite uplinks 1260–1270"),
            ("23 cm EME", "1296.000–1296.100 MHz", "CW from 1296.000; JT65/Q65 near 1296.065"),
            ("13 cm", "2300–2450 MHz", "Segments vary by country. Weak signal 2304.100 (R2) / 2320.200 (R1); satellite 2400–2450"),
            ("13 cm QO-100", "2400.050–2400.300 MHz", "QO-100 narrowband uplink (GEO, R1/R3 coverage); wideband 2401.5–2409.5"),
            ("9 cm", "3300–3500 MHz", "Regional; R1 mostly 3400–3410. Weak signal 3400.100 / 3456.100"),
            ("6 cm", "5650–5925 MHz", "Weak signal 5760.100; satellite uplink 5650–5670, downlink 5830–5850"),
            ("3 cm", "10.000–10.500 GHz", "Weak signal/EME 10368.100; satellite 10.45–10.50"),
            ("3 cm QO-100", "10489.550–10489.800 MHz", "QO-100 narrowband downlink; wideband 10491–10499"),
            ("1.2 cm", "24.00–24.25 GHz", "Weak signal/EME 24048.100 (24192.100 in R2); satellite 24.00–24.05"),
            ("6 mm", "47.0–47.2 GHz", "Weak signal 47088.100"),
            ("4 mm", "76–81 GHz", "Weak signal near 76032 / 77500"),
            ("2.5 mm", "122.25–123 GHz", "Secondary"),
            ("2 mm", "134–141 GHz", ""),
            ("1 mm", "241–250 GHz", ""),
            ("Above 275 GHz", "275 GHz to light", "Terahertz and optical (laser/LED) experimentation; national rules"),
            ("Sat band H", "21 MHz", "IARU satellite band letter"),
            ("Sat band A", "29 MHz", "10 m"),
            ("Sat band V", "145 MHz", "2 m"),
            ("Sat band U", "435 MHz", "70 cm"),
            ("Sat band L", "1.26 GHz", "23 cm (uplink)"),
            ("Sat band S", "2.4 GHz", "13 cm"),
            ("Sat band S2", "3.4 GHz", "9 cm"),
            ("Sat band C", "5.8 GHz", "6 cm"),
            ("Sat band X", "10.45 GHz", "3 cm"),
            ("Sat band K", "24 GHz", "1.2 cm"),
            ("Mode V/U (J)", "145 up / 435 down", "Most LEO linear and FM birds"),
            ("Mode U/V (B)", "435 up / 145 down", "AO-7 Mode B and others"),
            ("Mode L/U", "1260 up / 435 down", ""),
            ("Mode U/S", "435 up / 2400 down", ""),
            ("QO-100 NB", "2400.25 up / 10489.75 down", "Geostationary at 25.9° E; Europe, Africa, Middle East, South Asia")
        ]
        let world = worldRaw.map { ReferenceRow(a: $0.0, b: $0.1, c: $0.2) }
        // CubeSatSim command & control crib, ported from CardSat (the developer's own
        // table, verified against the CubeSatSim v2.x docs: cubesatsim.org Lite readme
        // and the config script, Jul 2026). Offline reference only.
        let cubesimRaw: [(String, String, String)] = [
            ("C2C uplink", "435.000 MHz FM", "Default command receive frequency"),
            ("DTMF", "<mode #> then #", "Dial the mode number, then #"),
            ("APRS", "MODE=<letter>", "Packet text containing the mode letter"),
            ("Carrier", "Key up briefly", "Mode steps +1 and the sim reboots; the green LED blinks the new mode number"),
            ("Mode 1 · a", "APRS / AFSK", ""),
            ("Mode 2 · f", "FSK / DUV", "Fox-style telemetry"),
            ("Mode 3 · b", "BPSK", ""),
            ("Mode 4 · s", "SSTV camera", ""),
            ("Mode 5 · m", "CW beacon", ""),
            ("Mode 6 · e", "X-band repeater", ""),
            ("Mode 7 · j", "FUNcube", ""),
            ("Console", "ssh pi@cubesatsim", "Then CubeSatSim/config -h for all options"),
            ("config -q N", "Squelch", "8 turns the C2C receiver off"),
            ("config -F", "TX/RX frequency", "420–450 MHz"),
            ("config -A", "Command another sim", "Over APRS"),
            ("config -o", "Telemetry beacon", "On/off"),
            ("Sim TX", "~434.9 MHz FM", "Telemetry downlink"),
            ("More", "github.com/alanbjohnston/CubeSatSim", "Wiki: Command and Control. Table per v2.x docs; check the wiki for your firmware version")
        ]
        let cubesim = cubesimRaw.map { ReferenceRow(a: $0.0, b: $0.1, c: $0.2) }
        let dxcc = DXCCData.entities.map { entity in
            let code = DXCCNumericData.codeByName[entity.name]
            let key = code.map { "\($0) · \(entity.prefix)" } ?? entity.prefix
            return ReferenceRow(a: key, b: entity.name, c: String(format:"%.1f°, %.1f°", entity.latitude, entity.longitude))
        }

        return [
            .init(id:"ctcss",name:"CTCSS tones",description:"Standard EIA/Motorola PL sub-audible tones.",headers:["#","Tone","Group"],rows:toneRows),
            .init(id:"qcodes",name:"Q-codes",description:"Common amateur Q-signals.",headers:["Code","","Meaning"],rows:qRows),
            .init(id:"cq",name:"CQ zones",description:"Compact summary of the 40 CQ zones.",headers:["Zones","Region",""],rows:cq),
            .init(id:"itu",name:"ITU zones",description:"Compact summary of the 90 ITU zones.",headers:["Zones","Region",""],rows:itu),
            .init(id:"ascii",name:"ASCII table",description:"Printable ASCII characters.",headers:["Dec","Char","Hex"],rows:ascii),
            .init(id:"phonetic",name:"Phonetic alphabet",description:"ITU/NATO phonetic alphabet.",headers:["Letter","Word",""],rows:pho),
            .init(id:"rst",name:"RST system",description:"Readability / Strength / Tone reporting.",headers:["Part","Scale","Meaning"],rows:rst),
            .init(id:"math",name:"Radio math",description:"Common station and RF formulas.",headers:["Topic","Expression","Note"],rows:math),
            .init(id:"ita2",name:"ITA2 / Baudot",description:"5-bit RTTY letters/figures shift table.",headers:["Code","Letters","Figures"],rows:ita2),
            .init(id:"morse",name:"Morse",description:"Morse patterns for letters and digits.",headers:["Character","Pattern",""],rows:morse),
            .init(id:"orbitTypes",name:"Orbit types",description:"Orbit classes and their operating implications.",headers:["Type","Typical","Meaning"],rows:orbitTypes),
            .init(id:"history",name:"Satellite history",description:"Selected amateur-satellite milestones.",headers:["Year","Satellite","Milestone"],rows:history),
            .init(id:"bandPlan",name:"Satellite band plan",description:"Common amateur-satellite subbands and mode designators.",headers:["Band / mode","Frequency","Note"],rows:bandPlan),
            .init(id:"worldBandPlan",name:"Worldwide band plan",description:"Amateur bands LF to light with ITU Region 1/2/3 differences, calling, EME and satellite frequencies. Summary of the IARU Region 1, 2 and 3 band plans and ITU Radio Regulations Art. 5 — your national rules govern.",headers:["Band","Range","Regions / notes"],rows:world),
            .init(id:"cubesatsim",name:"CubeSatSim C2C",description:"Command & control crib for AMSAT's CubeSat Simulator: DTMF, APRS and carrier mode commands plus the config script options. Reference only — OrbitDeck doesn't send these.",headers:["Command","Value","Note"],rows:cubesim),
            .init(id:"dxcc",name:"DXCC entities",description:"All 340 bundled DXCC entity reference points used by workable-footprint planning.",headers:["ARRL code / prefix","Entity","Reference point"],rows:dxcc)
        ]
    }()
}

// MARK: - Notes (plain-text files in Documents/Notes)

/// One note on disk. Notes are ordinary UTF-8 `.txt` files in Documents/Notes, so
/// they appear in the Files app (UIFileSharingEnabled) and can be edited there.
struct NoteFile: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let modified: Date
    let text: String
    var id: URL { url }
}

enum NotesStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All notes, newest first.
    static func list() -> [NoteFile] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.filter { ["txt", "md", "text"].contains($0.pathExtension.lowercased()) }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return NoteFile(url: url, title: url.deletingPathExtension().lastPathComponent, modified: modified, text: (try? read(url)) ?? "")
        }.sorted { $0.modified > $1.modified }
    }

    /// Reads a note as UTF-8, falling back to the encoding Foundation detects.
    /// Throws when the file can't be decoded so callers never mistake an
    /// unreadable note for an empty one (and overwrite it on save).
    static func read(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        var detected = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &detected)
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// File-system-safe title (no path separators or leading dots).
    static func sanitized(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var t = title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        return t.isEmpty ? "Untitled" : String(t.prefix(80))
    }

    private static func uniqueURL(for title: String, excluding: URL? = nil) -> URL {
        let base = sanitized(title)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("txt")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.standardizedFileURL != excluding?.standardizedFileURL {
            candidate = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension("txt"); n += 1
        }
        return candidate
    }

    @discardableResult
    static func create(title: String, text: String = "") throws -> URL {
        let url = uniqueURL(for: title)
        try write(text, to: url)
        return url
    }

    static func rename(_ url: URL, to title: String) throws -> URL {
        let target = uniqueURL(for: title, excluding: url)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - In-app help

struct HelpArticle: Identifiable, Sendable {
    let id: String
    let title: String
    let area: String
    let body: String
}

/// Short help articles per area. Wording adapted from the OrbitDeck website
/// (docs/) and CardSat's MANUAL.md (the One True Rule, working a pass).
enum HelpLibrary {
    static let articles: [HelpArticle] = [
        .init(id: "start", title: "Getting started", area: "Basics", body: """
        On first launch OrbitDeck downloads a satellite catalog and sets a default station. To get useful results:
        1. Set your station in Settings → Observer station (a fixed site, a grid square, or Always use current location).
        2. Enter your callsign in Settings → Operator identity.
        3. Star a few satellites in Satellites (for example the ISS and an active FM or linear bird). Favorites drive Home, Sky Radar and the schedules.
        4. Open Home for live look angles and your next pass.
        Settings → Station readiness shows a checklist of what is set up and what is missing, with a tap to fix each item.
        """),
        .init(id: "audio", title: "Where are the audio features? (recording, SSTV, FT4, packet, remote voice)", area: "Audio", body: """
        The audio cards on Home are hidden by default until an audio interface is connected — a USB audio interface or an Icom radio over the network. With nothing attached they don't appear at all, so the features can look missing.
        To show them anyway, open Settings → Audio features and set any of Pass recording, SSTV decode, FT4, Packet / APRS or Remote audio to Always. The card then appears on Home and, with no interface attached, uses the device's built-in microphone. Hidden turns a card off even with an interface.
        Try it: Settings → Audio features → Pass recording → Always, then go to Home and start a recording. Recording, SSTV and FT4 decoding keep running with the screen locked or while you switch apps, so a pass isn't lost partway through.
        """),
        .init(id: "home", title: "Home screen", area: "Home", body: """
        Home is the live dashboard for the selected satellite: azimuth, elevation, range and Doppler, the next qualifying pass and your favorites' upcoming passes. Cards for rig control, rotator, logging and the audio features appear as you configure them.
        The satellite switcher in the toolbar changes the selected satellite everywhere. Settings → Display → Keep screen awake on Home lets you leave Home up as a live display during a pass.
        """),
        .init(id: "passes", title: "Passes and tracking", area: "Passes", body: """
        Next Passes and Pass Detail list passes with polar plots and elevation profiles; Daily Schedule groups every favorite's passes by day; Sky Radar plots all favorites at once; Ground Track draws the sub-point path and true footprint.
        Set the minimum elevation in Settings → Pass prediction to filter marginal passes. Times are UTC by default; Settings → Display can switch to local time.
        Keep elements fresh: the ↻ button in the menu updates the catalog, and the element age shown in Orbital Analysis tells you how old the selected set is.
        """),
        .init(id: "pass", title: "Working a pass, step by step", area: "Passes", body: """
        FM bird: star it, find the pass, and at AOS open Home. With CAT on, OrbitDeck sets FM on both legs and Dopplers the single channel — just talk. Without CAT, tune the RX/TX frequencies shown on the Live Doppler card in small steps.
        Linear (SSB/CW) bird: pick a clear spot in the passband with the tuning slider (or the radio's knob with CAT), then work stations. Your downlink stays put and the uplink tracks — inverted if the transponder inverts. If your own signal isn't where you expect, trim the per-satellite calibration and save it.
        Always listen before you transmit, use the minimum power needed, and work full duplex so you can hear your own signal.
        """),
        .init(id: "doppler", title: "Doppler and the One True Rule", area: "Radio", body: """
        A satellite's motion shifts both the frequency you receive and the frequency the satellite receives from you. OrbitDeck follows AMSAT's "One True Rule" (Paul Williamson, KB5MU): tune both the transmitter and the receiver to keep a constant frequency at the satellite.
        RX = downlink × (1 − β) + calibration;  TX = uplink ÷ (1 − β);  β = range rate ÷ c.
        The result: you tune somebody in, let go, and nobody drifts through the passband. Calibration is one combined oscillator correction per satellite, measured from either leg.
        """),
        .init(id: "cat", title: "Rig control (CAT)", area: "CAT", body: """
        Settings → Rig control → CAT / rig control. OrbitDeck reaches a radio over a Bluetooth LE serial adapter wired to the CAT/CI-V port, an Icom network (Wi-Fi, RS-BA1) connection for the IC-705/IC-9700/IC-905, or a Hamlib rigctld server on your network. It drives one full-duplex radio, one half-duplex radio, or two radios.
        Rig control works only while OrbitDeck is in the foreground — iOS suspends Bluetooth and networking for backgrounded apps. Turn on Keep screen awake on Home to leave it running during a pass. Bluetooth Classic (SPP) adapters can't be used on iOS.
        Use the CAT monitor and self-test in the rig-control screen when something doesn't respond.
        """),
        .init(id: "rotator", title: "Rotator control", area: "Rotator", body: """
        Settings → Rotator control → Antenna rotator. Supported: GS-232, Easycomm I/II/III, SPID and SAEBRTrack over a Bluetooth LE serial adapter, or rotctld (Hamlib, TCP), PstRotator (UDP) and OZ9AAR URC over the network.
        OrbitDeck pre-positions before AOS, follows the pass, and can flip a 180° elevation rotator through the zenith on overhead passes. Like CAT, it runs only while the app is in the foreground. The rotator screen has a monitor and a self-test (including a null move) for checking the link.
        """),
        .init(id: "ft4", title: "FT4 on linear satellites", area: "FT4", body: """
        FT4 needs an audio interface (or set Settings → Audio features → FT4 → Always) and works full duplex on a linear transponder: OrbitDeck decodes the downlink while transmitting the uplink, with Doppler compensation so your signal stays put. Half-duplex single-radio FT4 isn't supported — on a satellite you must hear your own signal.
        Optional: Use data mode for FT4 (the radio's DATA sub-mode), Auto-calibrate transponder from FT4, and PSKReporter uploads, all in Settings → Audio features and PSKReporter.
        """),
        .init(id: "packet", title: "Packet and APRS", area: "Packet", body: """
        The Packet / APRS card decodes 1200 bd AFSK and 9600 bd G3RUH packet from the received audio and can transmit APRS messages and position beacons through digipeating satellites and the ISS. It appears on Home with an audio interface, or set Settings → Audio features → Packet / APRS → Always.
        """),
        .init(id: "sstv", title: "SSTV images", area: "SSTV", body: """
        The SSTV card decodes slow-scan TV (for example ISS ARISS events) from the received audio; images land in the SSTV Images gallery with Photos export. It can arm automatically for passes above a chosen elevation. Show the card without an interface via Settings → Audio features → SSTV decode → Always.
        """),
        .init(id: "logging", title: "Logging, LoTW and awards", area: "Logging", body: """
        The Home Log QSO card prefills the satellite, mode and your grid; the Log screen lists, edits and exports QSOs (ADIF, PDF). Log settings (gear icon on the Log screen) hold your LoTW station location and callsign certificate (.p12) — OrbitDeck signs and uploads to LoTW on the device — and your Cloudlog/Wavelog URL and API key.
        Awards totals (satellites, VUCC grids, WAS, DXCC) are computed from the log and can be shared as a PDF. Passwords and keys are kept in the iOS Keychain.
        """),
        .init(id: "auto", title: "Automatic satellite switching", area: "Auto switching", body: """
        Auto Switching selects the next satellite from your priority list as each pass begins, so Home, CAT and the rotator follow the sky without touching the phone. Set the list and minimum elevation on the Auto Switching screen; Pause after a manual selection keeps your own choice for a while.
        """),
        .init(id: "backup", title: "Backup, restore and reset", area: "Backup", body: """
        Settings → Backup & restore saves your station, favorites, calibrations, CAT, rotator, auto-switch, digital-mode and logging setup (optionally the QSO log) to one JSON file in Files, and restores it after a preview. Passwords and keys are never included.
        Settings → Reset clears settings, caches and stored data, with options to keep the QSO log and recordings, keep notes, and also remove saved passwords.
        Notes live in Documents/Notes and show in the Files app under On My iPhone → OrbitDeck.
        """),
        .init(id: "elements", title: "Element age and accuracy", area: "Passes", body: """
        GP (TLE) element sets are fitted to tracking data and propagated with SGP4. Errors grow mostly along the track as elements age: fine for pass planning after a week, but refresh before precision Doppler or antenna pointing. OrbitDeck refreshes daily when the loaded catalog is more than a day old and honors CelesTrak's request of no more than one download per dataset every two hours.
        """)
    ]

    static func search(_ query: String) -> [HelpArticle] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return articles }
        return articles.filter { ($0.title + " " + $0.area + " " + $0.body).lowercased().contains(q) }
    }
}

// MARK: - Tiny BASIC foundation

struct BasicGraphicOp: Identifiable, Sendable {
    enum Kind: Sendable { case cls, pset, line, circle, text, show }
    let id = UUID(); let kind: Kind; let values: [Double]; let color: Int; let text: String
}

struct BasicRunResult: Sendable {
    var output: [String] = []
    var graphics: [BasicGraphicOp] = []
    var steps: Int = 0
}

enum TinyBasicError: LocalizedError {
    case message(String, Int?)
    var errorDescription: String? {
        switch self { case .message(let s, let line): line.map { "\(s) (line \($0))" } ?? s }
    }
}

struct TinyBasicEngine: Sendable {
    static let width = 240
    static let height = 135
    static let palette: [String] = ["#000000","#ffffff","#ff4136","#2ecc40","#4a90d9","#ffdc00","#39cccc","#ff851b","#aaaaaa","#0b6623"]

    func run(_ source: String, maxSteps: Int = 200_000) throws -> BasicRunResult {
        let numbered: [(Int,String)] = source.split(whereSeparator: \.isNewline).compactMap { raw in
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            let parts=s.split(maxSplits:1,whereSeparator:\.isWhitespace)
            guard let n=Int(parts[0]) else { return nil }
            return (n, parts.count>1 ? String(parts[1]) : "")
        }.sorted{$0.0<$1.0}
        guard !numbered.isEmpty else { throw TinyBasicError.message("numbered program required", nil) }
        let indexByLine = Dictionary(uniqueKeysWithValues: numbered.enumerated().map{($0.element.0,$0.offset)})
        var vars = Dictionary(uniqueKeysWithValues: (0..<26).map{(String(UnicodeScalar(65+$0)!),0.0)})
        var fors: [(name:String,limit:Double,step:Double,line:Int,stmt:Int)] = []
        var gosubs: [Int] = []
        var out = BasicRunResult()
        var lineIndex=0, stmtIndex=0

        func splitStatements(_ text:String)->[String] {
            var result:[String]=[], current="", quoted=false; let chars=Array(text); var i=0
            while i<chars.count { let c=chars[i]; if c=="\"" { quoted.toggle(); current.append(c) }
                else if !quoted && i+2<chars.count && String(chars[i...i+2]).uppercased()=="REM" { current += String(chars[i...]); break }
                else if c==":" && !quoted { result.append(current); current="" } else { current.append(c) }; i+=1 }
            result.append(current); return result
        }
        func eval(_ text:String) throws -> Double {
            var normalized=text.uppercased()
            // BASIC trig functions are degree-oriented in the CardSat dialect.
            for fn in ["SIN","COS","TAN"] { normalized = normalized.replacingOccurrences(of: fn+"(", with: fn.lowercased()+"(rad(") }
            // close one extra rad( for simple function calls; repeatedly repair the common one-level form.
            normalized = normalized.replacingOccurrences(of: "))", with: "))")
            let evaluator=SafeMathEvaluator()
            // Rebuild degree trig in a small parser-friendly way by exposing rad conversion through textual replacements only for simple calls.
            var expr=text.lowercased()
            let env=Dictionary(uniqueKeysWithValues: vars.map{($0.key.lowercased(),$0.value)})
            // SafeMath trig is radians. Parse BASIC expressions separately enough to convert sin/cos/tan arguments expressed in degrees.
            expr = convertBasicTrig(expr)
            return try evaluator.evaluate(expr, variables: env)
        }
        func renderPrint(_ text:String) throws -> String {
            var pieces:[String]=[]; var current="", quoted=false
            for c in text { if c=="\"" { quoted.toggle(); current.append(c) } else if c=="," && !quoted { pieces.append(current); current="" } else { current.append(c) } }
            pieces.append(current)
            return try pieces.map { p in let t=p.trimmingCharacters(in:.whitespaces); if t.hasPrefix("\"") && t.hasSuffix("\"") { return String(t.dropFirst().dropLast()) }; let v=try eval(t); return abs(v.rounded()-v)<1e-10 ? String(Int(v.rounded())) : String(format:"%g",v) }.joined()
        }

        while lineIndex>=0 && lineIndex<numbered.count {
            let (lineNo, sourceLine)=numbered[lineIndex]; let statements=splitStatements(sourceLine)
            if stmtIndex>=statements.count { lineIndex+=1; stmtIndex=0; continue }
            out.steps+=1; if out.steps>maxSteps { throw TinyBasicError.message("too many statements", lineNo) }
            let raw=statements[stmtIndex].trimmingCharacters(in:.whitespaces); let upper=raw.uppercased()
            if raw.isEmpty || upper.hasPrefix("REM") || upper.hasPrefix("DATA") || upper=="SHOW" { stmtIndex+=1; continue }
            if upper=="END" || upper=="STOP" { break }
            if upper=="CLS" { out.graphics.append(.init(kind:.cls,values:[],color:0,text:"")); stmtIndex+=1; continue }
            if upper.hasPrefix("PRINT") || raw.hasPrefix("?") { let rest=raw.hasPrefix("?") ? String(raw.dropFirst()) : String(raw.dropFirst(5)); out.output.append(try renderPrint(rest)); stmtIndex+=1; continue }
            if upper.hasPrefix("PSET") { let a=try basicArgs(String(raw.dropFirst(4)),vars:vars); guard a.count>=2 else{throw TinyBasicError.message("PSET needs x,y",lineNo)}; out.graphics.append(.init(kind:.pset,values:Array(a.prefix(2)),color:a.count>2 ? Int(a[2]):1,text:"")); stmtIndex+=1; continue }
            if upper.hasPrefix("LINE") { let a=try basicArgs(String(raw.dropFirst(4)),vars:vars); guard a.count>=4 else{throw TinyBasicError.message("LINE needs x1,y1,x2,y2",lineNo)}; out.graphics.append(.init(kind:.line,values:Array(a.prefix(4)),color:a.count>4 ? Int(a[4]):1,text:"")); stmtIndex+=1; continue }
            if upper.hasPrefix("CIRCLE") { let a=try basicArgs(String(raw.dropFirst(6)),vars:vars); guard a.count>=3 else{throw TinyBasicError.message("CIRCLE needs x,y,r",lineNo)}; out.graphics.append(.init(kind:.circle,values:Array(a.prefix(3)),color:a.count>3 ? Int(a[3]):1,text:"")); stmtIndex+=1; continue }
            if upper.hasPrefix("TEXT") {
                let rest=String(raw.dropFirst(4)); let parts=rest.split(separator:",",maxSplits:2).map(String.init); guard parts.count==3 else{throw TinyBasicError.message("TEXT needs x,y,\"text\"",lineNo)}
                let x=try eval(parts[0]), y=try eval(parts[1]); let txt=parts[2].trimmingCharacters(in:.whitespaces).trimmingCharacters(in:CharacterSet(charactersIn:"\"")); out.graphics.append(.init(kind:.text,values:[x,y],color:1,text:txt)); stmtIndex+=1; continue
            }
            if upper.hasPrefix("GOTO") { guard let target=Int(raw.dropFirst(4).trimmingCharacters(in:.whitespaces)),let idx=indexByLine[target] else{throw TinyBasicError.message("bad GOTO",lineNo)}; lineIndex=idx; stmtIndex=0; continue }
            if upper.hasPrefix("GOSUB") { guard let target=Int(raw.dropFirst(5).trimmingCharacters(in:.whitespaces)),let idx=indexByLine[target] else{throw TinyBasicError.message("bad GOSUB",lineNo)}; gosubs.append(lineIndex+1); lineIndex=idx; stmtIndex=0; continue }
            if upper=="RETURN" { guard let idx=gosubs.popLast() else{throw TinyBasicError.message("RETURN without GOSUB",lineNo)}; lineIndex=idx; stmtIndex=0; continue }
            if upper.hasPrefix("FOR ") {
                let rest=String(raw.dropFirst(4)); guard let eq=rest.firstIndex(of:"=") else{throw TinyBasicError.message("bad FOR",lineNo)}; let name=rest[..<eq].trimmingCharacters(in:.whitespaces).uppercased(); let tail=String(rest[rest.index(after:eq)...]); guard let range=tail.range(of:" TO ",options:.caseInsensitive) else{throw TinyBasicError.message("bad FOR",lineNo)}
                let start=try eval(String(tail[..<range.lowerBound])); let after=String(tail[range.upperBound...]); let stepRange=after.range(of:" STEP ",options:.caseInsensitive); let limit=try eval(stepRange.map{String(after[..<$0.lowerBound])} ?? after); let step=try eval(stepRange.map{String(after[$0.upperBound...])} ?? "1"); vars[name]=start; fors.append((name,limit,step,lineIndex,stmtIndex)); stmtIndex+=1; continue
            }
            if upper.hasPrefix("NEXT") { guard var rec=fors.last else{throw TinyBasicError.message("NEXT without FOR",lineNo)}; rec = (rec.name,rec.limit,rec.step,rec.line,rec.stmt); vars[rec.name]=(vars[rec.name] ?? 0)+rec.step; let current=vars[rec.name] ?? 0; if (rec.step>=0 && current<=rec.limit)||(rec.step<0 && current>=rec.limit) { lineIndex=rec.line; stmtIndex=rec.stmt+1 } else { _=fors.popLast(); stmtIndex+=1 }; continue }
            if upper.hasPrefix("IF ") {
                let rest=String(raw.dropFirst(3)); guard let r=rest.range(of:" THEN ",options:.caseInsensitive) else{throw TinyBasicError.message("IF needs THEN",lineNo)}; let cond=try basicCondition(String(rest[..<r.lowerBound]),vars:vars); if cond { let action=String(rest[r.upperBound...]).trimmingCharacters(in:.whitespaces); if let target=Int(action),let idx=indexByLine[target] { lineIndex=idx; stmtIndex=0; continue } else if action.uppercased().hasPrefix("GOTO "),let target=Int(action.dropFirst(5).trimmingCharacters(in:.whitespaces)),let idx=indexByLine[target] { lineIndex=idx; stmtIndex=0; continue } else { throw TinyBasicError.message("THEN currently supports a line number/GOTO",lineNo) } }; stmtIndex+=1; continue
            }
            let assignment = upper.hasPrefix("LET ") ? String(raw.dropFirst(4)) : raw
            if let eq=assignment.firstIndex(of:"=") { let name=assignment[..<eq].trimmingCharacters(in:.whitespaces).uppercased(); guard name.count==1,name.first?.isLetter==true else{throw TinyBasicError.message("bad variable",lineNo)}; vars[name]=try eval(String(assignment[assignment.index(after:eq)...])); stmtIndex+=1; continue }
            throw TinyBasicError.message("unknown statement: \(raw)", lineNo)
        }
        return out
    }
}

private func convertBasicTrig(_ expr: String) -> String {
    // Translate simple BASIC degree trig calls into the safe evaluator's radian trig.
    var text = expr
    for name in ["sin","cos","tan"] {
        var searchStart = text.startIndex
        while let range = text.range(of: name + "(", range: searchStart..<text.endIndex) {
            var depth=1; var i=range.upperBound
            while i<text.endIndex && depth>0 { if text[i]=="("{depth+=1}else if text[i]==")"{depth-=1}; if depth==0{break}; i=text.index(after:i) }
            if depth==0 { let inner=String(text[range.upperBound..<i]); let replacement="\(name)(rad(\(inner)))"; text.replaceSubrange(range.lowerBound...i,with:replacement); searchStart=text.index(range.lowerBound,offsetBy:replacement.count,limitedBy:text.endIndex) ?? text.endIndex } else { break }
        }
    }
    return text
}

private func basicArgs(_ text:String, vars:[String:Double]) throws -> [Double] {
    var parts:[String]=[], current="", depth=0
    for c in text { if c=="("{depth+=1}; if c==")"{depth-=1}; if c=="," && depth==0 { parts.append(current);current="" } else {current.append(c)} }; parts.append(current)
    let eval=SafeMathEvaluator(); let env=Dictionary(uniqueKeysWithValues:vars.map{($0.key.lowercased(),$0.value)})
    return try parts.filter{!$0.trimmingCharacters(in:.whitespaces).isEmpty}.map{try eval.evaluate(convertBasicTrig($0),variables:env)}
}

private func basicCondition(_ text:String, vars:[String:Double]) throws -> Bool {
    for op in ["<=",">=","<>","=","<",">"] { if let r=text.range(of:op) { let lhs=try basicArgs(String(text[..<r.lowerBound]),vars:vars).first ?? 0; let rhs=try basicArgs(String(text[r.upperBound...]),vars:vars).first ?? 0; switch op{case"<=":return lhs<=rhs;case">=":return lhs>=rhs;case"<>":return lhs != rhs;case"=":return lhs==rhs;case"<":return lhs<rhs;default:return lhs>rhs} } }
    return (try basicArgs(text,vars:vars).first ?? 0) != 0
}

// MARK: - Learn helpers

enum LearnMath {
    static let earthRadiusKm = 6378.135
    static let mu = 398600.4418
    static let siderealDay = 86164.0905
    static func circularSpeed(altitudeKm: Double) -> Double { sqrt(mu/(earthRadiusKm+max(0,altitudeKm))) }
    static func circularPeriodMinutes(altitudeKm: Double) -> Double { 2*Double.pi*sqrt(pow(earthRadiusKm+max(0,altitudeKm),3)/mu)/60 }
    static func horizonRadiusKm(altitudeKm: Double) -> Double { earthRadiusKm*acos(earthRadiusKm/(earthRadiusKm+max(1,altitudeKm))) }
    static func trackDriftDegrees(altitudeKm: Double) -> Double { 360*(circularPeriodMinutes(altitudeKm: altitudeKm) * 60 / siderealDay) }
    static func slantRangeKm(altitudeKm: Double, elevationDeg: Double) -> Double {
        let e=elevationDeg*Double.pi/180, r=earthRadiusKm+max(0,altitudeKm)
        return -earthRadiusKm*sin(e)+sqrt(max(0,r*r-earthRadiusKm*earthRadiusKm*cos(e)*cos(e)))
    }
    static func fsplDb(rangeKm:Double,freqMHz:Double)->Double { 32.44+20*log10(max(rangeKm,1e-9))+20*log10(max(freqMHz,1e-9)) }
    static func dopplerHz(freqMHz:Double,rangeRateKmS:Double)->Double { -(rangeRateKmS/299792.458)*freqMHz*1e6 }
}
