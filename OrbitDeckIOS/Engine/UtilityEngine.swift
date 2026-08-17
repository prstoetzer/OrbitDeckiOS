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
        // Trig honours the degrees mode (matches CardSat's ham-oriented default).
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
        let orbitTypes = [("LEO","160–2000 km, 90–128 min","Most amateur satellites; short passes and high Doppler."),("Sun-synchronous","~600–800 km, i≈98°","Similar local-time crossings."),("MEO","2000–35786 km","Longer access and lower angular rates."),("Molniya","e≈0.74, i=63.4°, 12 h","Long dwell near high-latitude apogee."),("GEO","35786 km, i≈0°","Fixed in the sky; QO-100 is the amateur example."),("Polar","i≈90°","Reaches all latitudes."),("Retrograde","i>90°","Travels against Earth rotation.")].map { ReferenceRow(a:$0.0,b:$0.1,c:$0.2) }
        let history = [("1961","OSCAR 1","First amateur satellite."),("1965","OSCAR 3","First amateur transponder."),("1974","AO-7","Mode A/B; returned to service after battery failure."),("1983","AO-10","Molniya-orbit Mode B satellite."),("1990","AO-16 / LO-19","Microsat digital store-and-forward era."),("1998","ISS","Amateur radio aboard the station."),("2013","FUNcube-1 / AO-73","Education payload and linear transponder."),("2019","QO-100","First amateur geostationary transponder."),("2022","IO-117 / GreenCube","MEO digipeater with long-range access.")].map { ReferenceRow(a:$0.0,b:$0.1,c:$0.2) }
        let bandPlan = [("2 m satellite","145.8–146.0 MHz","satellite subband"),("70 cm satellite","435–438 MHz","satellite subband"),("23 cm","1260–1270 MHz","common satellite uplink segment"),("13 cm","2400 MHz","S-band satellite use"),("3 cm","10.45 GHz","X-band satellite / microwave"),("Mode V/U (J)","145 up / 435 down","common LEO mode"),("Mode U/V (B)","435 up / 145 down","AO-7 Mode B etc."),("Mode L/U","1260 up / 435 down",""),("Mode U/S","435 up / 2400 down",""),("QO-100 NB","2400.25 up / 10489.75 down","geostationary")].map { ReferenceRow(a:$0.0,b:$0.1,c:$0.2) }
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
            .init(id:"dxcc",name:"DXCC entities",description:"All 340 bundled DXCC entity reference points used by workable-footprint planning.",headers:["ARRL code / prefix","Entity","Reference point"],rows:dxcc)
        ]
    }()
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
