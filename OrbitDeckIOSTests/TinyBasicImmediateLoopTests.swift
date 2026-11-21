import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Tiny BASIC immediate mode (no line numbers): FOR/NEXT loops must not index the
//         empty numbered-line list.

struct TinyBasicImmediateLoopTests {

    @Test func singleLineImmediateLoopRuns() throws {
        let result = try CardSatTinyBasicEngine().run("FOR I=1 TO 3: PRINT I: NEXT I")
        let text = result.output.joined(separator: "\n")
        #expect(text.contains("1"))
        #expect(text.contains("3"))
    }

    @Test func crossLineImmediateLoopThrowsInsteadOfCrashing() {
        #expect(throws: (any Error).self) {
            _ = try CardSatTinyBasicEngine().run("FOR I=1 TO 3\nNEXT I")
        }
    }
}
