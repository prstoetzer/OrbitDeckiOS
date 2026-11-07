import Testing
import Foundation
@testable import OrbitDeck

// MARK: - FT4 message parsing, pounce matching and callsign-hash tests
//
// `FT4Engine.parse` drives the auto-sequencer, `work()`, PSKReporter spots and the decode
// highlighting, so it must tell callsigns from grids/reports/CQ modifiers — including
// compound calls and a bare `CALL GRID` with no CQ. All helpers are pure (no audio).

struct FT4ParseTests {

    @Test func plainCQ() throws {
        let f = try #require(FT4Engine.parse("CQ K1ABC FN42"))
        #expect(f.isCQ && f.de == "K1ABC" && f.extra == "FN42" && f.cqModifier.isEmpty)
    }

    @Test func cqWithoutGrid() throws {
        let f = try #require(FT4Engine.parse("CQ K1ABC"))
        #expect(f.isCQ && f.de == "K1ABC" && f.extra.isEmpty)
    }

    @Test func cqModifiersAreNotCalls() throws {
        for (text, mod) in [("CQ POTA K1ABC FN42", "POTA"), ("CQ TEST K1ABC FN42", "TEST"),
                            ("CQ DX K1ABC FN42", "DX"), ("CQ NA K1ABC FN42", "NA"),
                            ("CQ EU K1ABC FN42", "EU"), ("CQ 123 K1ABC FN42", "123")] {
            let f = try #require(FT4Engine.parse(text))
            #expect(f.isCQ, "\(text)")
            #expect(f.de == "K1ABC", "\(text)")
            #expect(f.extra == "FN42", "\(text)")
            #expect(f.cqModifier == mod, "\(text)")
        }
    }

    @Test func shortCallAfterCQIsNotAModifier() throws {
        // A real (short) call carries a digit, so it's never taken for a modifier.
        let f = try #require(FT4Engine.parse("CQ K1A FN42"))
        #expect(f.de == "K1A" && f.cqModifier.isEmpty)
        let g = try #require(FT4Engine.parse("CQ 9A1A JN75"))
        #expect(g.de == "9A1A" && g.extra == "JN75")
    }

    @Test func cqCompoundCall() throws {
        let f = try #require(FT4Engine.parse("CQ PJ4/K1ABC"))
        #expect(f.isCQ && f.de == "PJ4/K1ABC")
        let g = try #require(FT4Engine.parse("CQ K1ABC/P FN42"))
        #expect(g.de == "K1ABC/P" && g.extra == "FN42")
    }

    @Test func callGridWithoutCQ() throws {
        // The verified bug: `SM/R1CR KP04` put the grid in `de`.
        let f = try #require(FT4Engine.parse("SM/R1CR KP04"))
        #expect(!f.isCQ && f.isGeneralCall)
        #expect(f.to.isEmpty && f.de == "SM/R1CR" && f.extra == "KP04")
        let g = try #require(FT4Engine.parse("K1ABC FN42ab"))
        #expect(g.de == "K1ABC" && g.extra == "FN42AB")
    }

    @Test func directedMessages() throws {
        let a = try #require(FT4Engine.parse("N8HM K1ABC FN42"))
        #expect(a.to == "N8HM" && a.de == "K1ABC" && a.extra == "FN42" && !a.isGeneralCall)
        let b = try #require(FT4Engine.parse("N8HM K1ABC -10"))
        #expect(b.extra == "-10")
        let c = try #require(FT4Engine.parse("N8HM K1ABC R+05"))
        #expect(c.extra == "R+05")
        for token in ["RR73", "RRR", "73"] {
            let d = try #require(FT4Engine.parse("N8HM K1ABC \(token)"))
            #expect(d.de == "K1ABC" && d.extra == token)
        }
        let e = try #require(FT4Engine.parse("N8HM K1ABC"))
        #expect(e.to == "N8HM" && e.de == "K1ABC" && e.extra.isEmpty)
    }

    @Test func rogerGrid() throws {
        let f = try #require(FT4Engine.parse("N8HM K1ABC R FN42"))
        #expect(f.de == "K1ABC" && f.extra == "FN42")
    }

    @Test func hashedCalls() throws {
        let a = try #require(FT4Engine.parse("<PJ4/K1ABC> N8HM -10"))
        #expect(a.to == "PJ4/K1ABC" && a.de == "N8HM")
        let b = try #require(FT4Engine.parse("<...> K1ABC RR73"))
        #expect(b.to == "<...>" && b.de == "K1ABC")
        let c = try #require(FT4Engine.parse("N8HM <...> 73"))
        #expect(c.de == "<...>")
    }

    @Test func freeTextIsNotParsed() {
        #expect(FT4Engine.parse("TNX 73 GL") == nil)
        #expect(FT4Engine.parse("") == nil)
    }

    @Test func gridRecognition() {
        #expect(FT4Engine.isGrid("FN42"))
        #expect(FT4Engine.isGrid("fn42ab"))
        #expect(FT4Engine.isGrid("KP04"))
        #expect(!FT4Engine.isGrid("RR73"))
        #expect(!FT4Engine.isGrid("ZZ42"))        // fields only go to R
        #expect(!FT4Engine.isGrid("FN42ZZ"))      // subsquares only go to X
        #expect(!FT4Engine.isGrid("K1ABC"))
        #expect(!FT4Engine.isGrid("FN4"))
    }

    @Test func reportRecognition() {
        for s in ["-10", "+05", "R-10", "R+05", "-24"] { #expect(FT4Engine.isReportToken(s), "\(s)") }
        for s in ["10", "R", "RR73", "R-", "-1A"] { #expect(!FT4Engine.isReportToken(s), "\(s)") }
        #expect(FT4Engine.parseReport("R+05") == 5)
        #expect(FT4Engine.parseReport("-10") == -10)
    }

    @Test func callsignRecognition() {
        for s in ["K1ABC", "SM/R1CR", "K1ABC/P", "PJ4/K1ABC", "3DA0XYZ", "9A1A", "<...>"] {
            #expect(FT4Engine.isCallToken(s), "\(s)")
        }
        for s in ["FN42", "RR73", "73", "-10", "POTA", "CQ", "K1ABC/", "/K1ABC"] {
            #expect(!FT4Engine.isCallToken(s), "\(s)")
        }
    }

    // MARK: Pounce / block-list matching

    @Test func pounceOnCallOrGrid() throws {
        let cq = try #require(FT4Engine.parse("CQ POTA K1ABC FN42"))
        #expect(FT4Engine.pounceMatches(cq, targets: ["K1ABC"], myCall: "N8HM"))
        #expect(FT4Engine.pounceMatches(cq, targets: ["FN42"], myCall: "N8HM"))
        #expect(FT4Engine.pounceMatches(cq, targets: ["FN42AB"], myCall: "N8HM"))
        #expect(!FT4Engine.pounceMatches(cq, targets: ["W9XYZ", "EN37"], myCall: "N8HM"))

        let bare = try #require(FT4Engine.parse("SM/R1CR KP04"))
        #expect(FT4Engine.pounceMatches(bare, targets: ["SM/R1CR"], myCall: "N8HM"))
        #expect(FT4Engine.pounceMatches(bare, targets: ["R1CR"], myCall: "N8HM"))

        let toMe = try #require(FT4Engine.parse("N8HM K1ABC -10"))
        #expect(FT4Engine.pounceMatches(toMe, targets: ["K1ABC"], myCall: "N8HM"))
        let toOther = try #require(FT4Engine.parse("W9XYZ K1ABC -10"))
        #expect(!FT4Engine.pounceMatches(toOther, targets: ["K1ABC"], myCall: "N8HM"))
    }

    @Test func targetListTokens() {
        #expect(FT4Engine.listTokens("k1abc, fn42  w9xyz") == ["K1ABC", "FN42", "W9XYZ"])
        #expect(FT4Engine.listTokens("  ").isEmpty)
    }

    @Test func compoundCallMatching() {
        #expect(FT4Engine.callMatches("K1ABC/P", "K1ABC"))
        #expect(FT4Engine.callMatches("PJ4/K1ABC", "K1ABC"))
        #expect(FT4Engine.callMatches("k1abc", "K1ABC"))
        #expect(!FT4Engine.callMatches("K1ABCD", "K1ABC"))
        #expect(!FT4Engine.callMatches("<...>", "K1ABC"))
    }

    // MARK: Callsign hashes

    @Test func standardCallClassification() {
        for s in ["K1ABC", "N8HM", "9A1A", "2E0ABC", "K1ABC/P", "W9XYZ/R"] {
            #expect(FT4CallsignHashes.isStandard(s), "\(s)")
        }
        for s in ["PJ4/K1ABC", "SM/R1CR", "VE3/N8HM", "K1ABC/QRP"] {
            #expect(!FT4CallsignHashes.isStandard(s), "\(s)")
        }
    }

    @Test func swiftHashMatchesFt8Lib() {
        // Encoding a message makes ft8_lib hash the calls and hand each to `save_hash`
        // with ITS n22, so a 22-bit lookup by the Swift-computed hash must find the call.
        _ = FT4Engine.encodeTones("PJ4/K1ABC N8HM RR73")
        let h = FT4CallsignHashes.hash22("PJ4/K1ABC")
        #expect(h != nil)
        if let h {
            #expect(FT4CallsignHashes.shared.lookup(type: FTX_CALLSIGN_HASH_22_BITS, hash: h) == "PJ4/K1ABC")
            #expect(FT4CallsignHashes.shared.lookup(type: FTX_CALLSIGN_HASH_12_BITS, hash: h >> 10) == "PJ4/K1ABC")
        }
    }

    @Test func bracketedCallsEncode() {
        // A call resolved from a hash is sent as a plain call; an unresolved one can't be.
        #expect(FT4Engine.encodeTones("<PJ4/K1ABC> N8HM -10") != nil)
        #expect(FT4Engine.encodeTones("<...> N8HM -10") == nil)
    }
}
