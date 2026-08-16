import Foundation
import SatelliteKit

@main
@MainActor
struct TinyBasicRegression {
    static var passed = 0

    static func check(_ name: String, _ body: () throws -> Void) rethrows {
        try body()
        passed += 1
        print("PASS \(name)")
    }

    static func output(_ source: String, inputs: [Double] = [], stringInputs: [String] = [], host: TinyBasicHostContext? = nil, directory: URL? = nil, seed: UInt64? = 1234, maxSteps: Int = 100_000, maxSeconds: TimeInterval = 3) throws -> [String] {
        try CardSatTinyBasicEngine().run(source, inputs: inputs, stringInputs: stringInputs, host: host, fileDirectory: directory, seed: seed, maxSteps: maxSteps, maxSeconds: maxSeconds).output
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOfFile: "examples/CardSat-BASIC/\(name)", encoding: .utf8)
    }

    static func liveHost() throws -> TinyBasicHostContext {
        let epoch = Date(timeIntervalSince1970: 1_776_000_000)
        let now = Date(timeIntervalSince1970: 1_786_733_000)
        let elements = Elements(commonName: "BASIC LIVE", noradIndex: 99951, launchName: "TEST", t₀: epoch,
                                e₀: 0.001, i₀: 51.6, ω₀: 20, Ω₀: 30, M₀: 40, n₀: 15.2,
                                ephemType: 0, tleClass: "U", tleNumber: 1, revNumber: 1, dragCoeff: 0.0001)
        let tp = TransponderRecord(id: "lin", description: "Linear live fixture", downlinkLow: 145_950_000,
                                   downlinkHigh: 145_970_000, uplinkLow: 435_050_000, uplinkHigh: 435_070_000,
                                   mode: "SSB/CW", invert: true, type: "Transponder", baud: 0, service: "Amateur")
        let sat = SatelliteRecord(id: 99951, name: "BASIC LIVE", internationalDesignator: "TEST", epoch: epoch,
                                  meanMotionRevPerDay: 15.2, eccentricity: 0.001, inclinationDeg: 51.6, raanDeg: 30,
                                  argumentOfPerigeeDeg: 20, meanAnomalyDeg: 40, bstar: 0.0001, elements: elements,
                                  transponders: [tp], isManual: true)
        let sub = try OrbitPredictor.subpoint(sat, at: now)
        let home = ObserverSite(name: "Fixture QTH", latitude: sub.latitude, longitude: sub.longitude, altitudeMeters: 20)
        let wx = SpaceWeatherSnapshot(fetchedAt: now, flux: 135, kp: 2, aIndex: 7, sunspotNumber: 110, flux90Day: 125)
        return TinyBasicHostContext(observer: home, satellites: [sat], selectedNorad: sat.id, favorites: [sat.id],
                                    weather: wx, minimumElevation: 0, now: now)
    }

    static func main() throws {
        try check("degree trig + arithmetic") {
            let o = try output("10 PRINT ROUND(SIN(30)*1000)\n20 PRINT ROUND(COS(60)*1000)\n30 PRINT 2^8")
            precondition(o == ["500", "500", "256"], "unexpected \(o)")
        }
        try check("anonymous + named arrays") {
            let o = try output("10 DIM @(4),A(4)\n20 FOR I=0 TO 3:@(I)=I*2:A(I)=@(I)+1:NEXT\n30 PRINT @(3);\",\";A(3)")
            precondition(o == ["6,7"], "unexpected \(o)")
        }
        try check("array shared budget") {
            _ = try output("10 DIM A(1024),B(1024)\n20 PRINT 1")
            do {
                _ = try output("10 DIM A(1024),B(1024),C(1)")
                preconditionFailure("array budget not enforced")
            } catch { }
        }
        try check("DATA READ RESTORE") {
            let o = try output("10 DATA 2,3,5\n20 READ A,B,C\n30 PRINT A+B+C\n40 RESTORE\n50 READ A\n60 PRINT A")
            precondition(o == ["10", "2"], "unexpected \(o)")
        }
        try check("mixed INPUT prompts and values") {
            let src = "10 INPUT \"Count\"; A\n20 INPUT \"Callsign\"; C$\n30 PRINT A;\":\";UCASE$(TRIM$(C$))"
            let p = CardSatTinyBasicEngine.inputPrompts(in: src)
            precondition(p.map(\.variable) == ["A", "C$"]) 
            precondition(p.map(\.label) == ["Count", "Callsign"])
            let o = try output(src, inputs: [6], stringInputs: [" n8hm "])
            precondition(o == ["6:N8HM"], "unexpected \(o)")
        }
        try check("string functions + Microsoft indices") {
            let src = "10 A$=\" N8HM/P \"\n20 A$=UCASE$(TRIM$(A$))\n30 PRINT LEFT$(A$,4);\"|\";RIGHT$(A$,1);\"|\";MID$(A$,6);\"|\";INSTR(A$,\"/\");\"|\";VAL(\"42\")"
            let o = try output(src)
            precondition(o == ["N8HM|P|P|5|42"], "unexpected \(o)")
        }
        try check("string comparisons") {
            let o = try output("10 A$=\"7\"\n20 IF A$>=\"0\" THEN IF A$<=\"9\" THEN PRINT \"DIGIT\"\n30 IF A$<>\"7\" THEN PRINT \"BAD\"")
            precondition(o == ["DIGIT"], "unexpected \(o)")
        }
        try check("CardSat constants + geometry") {
            let o = try output("10 PRINT ROUND(TWOPI*1000)\n20 PRINT ROUND(GCDIST(0,0,0,1))\n30 PRINT ROUND(GCAZ(0,0,0,1))\n40 PRINT GRID$(39.93,-74.89)")
            precondition(o.count == 4 && o[0] == "6283" && o[1] == "111" && o[2] == "90" && o[3].hasPrefix("FM"), "unexpected \(o)")
        }
        try check("full ARRL numerical DXCC bridge") {
            let src = """
            10 PRINT DXCC$(1)
            20 PRINT DXCC$(5)
            30 PRINT DXCC$(94)
            40 PRINT DXCC$(291)
            50 PRINT DXCC$(339)
            60 PRINT ROUND(DXCCLAT(339));",";ROUND(DXCCLON(339))
            """
            let o = try output(src)
            precondition(o == ["Canada", "Aland Is.", "Antigua & Barbuda", "United States of America", "Japan", "36,138"], "unexpected \(o)")
        }
        try check("ON GOTO") {
            let o = try output("10 A=2\n20 ON A GOTO 100,200,300\n100 PRINT 1:END\n200 PRINT 2:END\n300 PRINT 3:END")
            precondition(o == ["2"], "unexpected \(o)")
        }
        try check("GOSUB RETURN") {
            let sameLine = try output("10 A=4:GOSUB 100:PRINT A:END\n100 A=A*5:RETURN")
            precondition(sameLine == ["20"], "same-line unexpected \(sameLine)")
            let nextLine = try output("10 A=2:GOSUB 100\n20 PRINT A:END\n100 A=A+3:RETURN")
            precondition(nextLine == ["5"], "next-line unexpected \(nextLine)")
            let nested = try output("10 A=0:GOSUB 100:PRINT A:END\n100 A=A+1:GOSUB 200:A=A+1:RETURN\n200 A=A+10:RETURN")
            precondition(nested == ["12"], "nested unexpected \(nested)")
        }
        try check("boolean logic") {
            let o = try output("10 A=5\n20 IF A>3 AND A<9 THEN 40\n30 PRINT 0:END\n40 PRINT NOT(0);\",\";A<>4")
            precondition(o == ["1,1"], "unexpected \(o)")
        }
        try check("MOD operator") {
            let o = try output("10 PRINT 17 MOD 5\n20 IF 20 MOD 10=0 THEN PRINT 1")
            precondition(o == ["2", "1"], "unexpected \(o)")
        }
        try check("graphics command stream") {
            let r = try CardSatTinyBasicEngine().run("10 CLS\n20 PSET 1,2,3\n30 LINE 0,0,10,10,4\n40 CIRCLE 20,20,5,5\n50 TEXT 3,4,\"TEST\"\n60 SHOW")
            precondition(r.graphics.count == 6, "graphics \(r.graphics.count)")
        }
        try check("PRINT separator continuation") {
            let o = try output("10 PRINT \"A\";\n20 PRINT \"B\";\"C\"\n30 PRINT \"D\",\"E\"")
            precondition(o == ["ABC", "D  E"], "unexpected \(o)")
        }
        try check("seeded RND reproducibility") {
            let src = "10 PRINT RND\n20 PRINT RND(10)"
            let a = try output(src, seed: 8675309)
            let b = try output(src, seed: 8675309)
            precondition(a == b && a.count == 2)
        }
        try check("system variables safely unavailable") {
            let o = try output("10 PRINT SATOK;\",\";SPWXOK;\",\";POSOK")
            precondition(o == ["0,0,0"], "unexpected \(o)")
        }
        try check("file sandbox") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitDeckBasicRegression-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let o = try output("10 A$=\"HELLO\"\n20 FOPEN \"log.txt\"\n30 FPRINT A$;123\n40 FCLOSE\n50 FILES", directory: dir)
            precondition(o.last?.contains("log.txt") == true)
            let data = try String(contentsOf: dir.appendingPathComponent("log.txt"), encoding: .utf8)
            precondition(data.contains("HELLO123"), "file contents \(data)")
            do {
                _ = try output("10 FOPEN \"../escape.txt\"", directory: dir)
                preconditionFailure("path escape accepted")
            } catch { }
        }
        check("bounded/error behavior") {
            do { _ = try output("10 GOTO 10", maxSteps: 100); preconditionFailure("runaway accepted") } catch { }
            do { _ = try output("GOTO 10"); preconditionFailure("immediate GOTO accepted") } catch { }
        }

        try check("CardSat CALLPARSE.BAS") {
            let o = try output(try fixture("CALLPARSE.BAS"), stringInputs: ["N8HM/P"], maxSteps: 100_000)
            let joined = o.joined(separator: "\n")
            precondition(joined.contains("callsign: N8HM/P") && joined.contains("portable") && joined.contains("call area 8"), "unexpected \(o)")
        }
        try check("CardSat DXPATH.BAS") {
            let host = TinyBasicHostContext(observer: .init(name: "Test", latitude: 39.93, longitude: -74.89, altitudeMeters: 20), satellites: [], selectedNorad: nil, favorites: [], weather: nil, minimumElevation: 5, now: Date(timeIntervalSince1970: 1_776_000_000))
            let o = try output(try fixture("DXPATH.BAS"), inputs: [339], stringInputs: ["JA test"], host: host, maxSteps: 100_000)
            let joined = o.joined(separator: "\n")
            precondition(joined.contains("Path to Japan") && joined.contains("note: JA test") && joined.contains("grid"), "unexpected \(o)")
        }
        try check("CardSat PASSTATS.BAS graceful no-pass") {
            let o = try output(try fixture("PASSTATS.BAS"))
            precondition(o.first?.contains("no pass list") == true, "unexpected \(o)")
        }
        try check("CardSat SIEVE.BAS") {
            let o = try output(try fixture("SIEVE.BAS"), maxSteps: 100_000)
            precondition(o.last == "Count: 30", "unexpected tail \(o.suffix(3))")
        }
        try check("CardSat HARMONO.BAS") {
            let r = try CardSatTinyBasicEngine().run(try fixture("HARMONO.BAS"), seed: 1, maxSteps: 100_000, maxSeconds: 5)
            precondition(r.graphics.count > 100 && r.graphics.last?.kind == .show, "graphics \(r.graphics.count)")
        }
        try check("CardSat STARFLD.BAS") {
            let r = try CardSatTinyBasicEngine().run(try fixture("STARFLD.BAS"), maxSteps: 100_000, maxSeconds: 5)
            precondition(r.graphics.count >= 10 && r.graphics.last?.kind == .show, "graphics \(r.graphics.count)")
        }
        try check("CardSat MANDEL.BAS") {
            let r = try CardSatTinyBasicEngine().run(try fixture("MANDEL.BAS"), maxSteps: 500_000, maxSeconds: 10)
            precondition(r.graphics.count > 100 && r.graphics.last?.kind == .show, "graphics \(r.graphics.count)")
        }

        let live = try liveHost()
        try check("CardSat PASSES.BAS live host") {
            let o = try output(try fixture("PASSES.BAS"), host: live, maxSteps: 200_000, maxSeconds: 5)
            let joined = o.joined(separator: "\n")
            precondition(joined.contains("Upcoming passes") && !joined.contains("No pass predicted"), "unexpected \(o)")
        }
        try check("CardSat GROUND.BAS live host") {
            let r = try CardSatTinyBasicEngine().run(try fixture("GROUND.BAS"), host: live, maxSteps: 200_000, maxSeconds: 5)
            precondition(r.graphics.count >= 12 && r.graphics.last?.kind == .show, "graphics \(r.graphics.count)")
        }
        try check("CardSat SUNMOON.BAS live host") {
            let r = try CardSatTinyBasicEngine().run(try fixture("SUNMOON.BAS"), host: live, maxSteps: 100_000, maxSeconds: 5)
            precondition(r.graphics.count >= 10 && r.graphics.last?.kind == .show, "graphics \(r.graphics.count)")
            let snap = live.snapshot()
            precondition(abs(snap["MAGDECL"] ?? 0) > 0.01 && (snap["LSTHR"] ?? -1) >= 0, "host compass/time")
        }
        try check("CardSat BELT.BAS planning host") {
            let o = try output(try fixture("BELT.BAS"), host: live, maxSteps: 100_000, maxSeconds: 5)
            let joined = o.joined(separator: "\n")
            precondition(joined.contains("BELT - shell geometry") && joined.contains("nT"), "unexpected \(o)")
        }
        try check("CardSat DECAY.BAS B-star host") {
            let o = try output(try fixture("DECAY.BAS"), host: live, maxSteps: 200_000, maxSeconds: 5)
            let joined = o.joined(separator: "\n")
            precondition(joined.contains("DECAY - soonest re-entry first") && joined.contains("of 1 have an estimate"), "unexpected \(o)")
        }
        try check("CardSat DOPPLER.BAS SATSEL/TXSEL host") {
            let r = try CardSatTinyBasicEngine().run(try fixture("DOPPLER.BAS"), host: live, maxSteps: 200_000, maxSeconds: 5)
            precondition(r.graphics.count >= 10 && r.graphics.last?.kind == .show, "graphics \(r.graphics.count)")
        }

        print("TINY_BASIC_REGRESSION_OK \(passed) cases")
    }
}
