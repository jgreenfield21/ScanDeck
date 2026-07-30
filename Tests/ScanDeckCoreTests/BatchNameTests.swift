import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Batch name validation")
struct BatchNameTests {
    @Test("Trims surrounding whitespace")
    func trimsWhitespace() throws {
        #expect(try BatchName("  aug01-sale  ").value == "aug01-sale")
    }

    @Test("Normalizes canonically equivalent Unicode")
    func normalizesUnicode() throws {
        let decomposed = "cafe\u{301}"
        #expect(try BatchName(decomposed).value == "café")
    }

    @Test(
        "Rejects unsafe values",
        arguments: ["", " ", ".", "..", "a/b", "a:b", "a\u{0}b", "batch."]
    )
    func rejectsUnsafeValues(candidate: String) {
        #expect(throws: BatchName.ValidationError.self) {
            try BatchName(candidate)
        }
    }

    @Test("Rejects a multibyte name that exceeds a filesystem component")
    func rejectsOversizedUTF8Name() {
        let emojis = String(repeating: "📇", count: 64)

        #expect(
            throws: BatchName.ValidationError.tooManyUTF8Bytes(maximum: 255)
        ) {
            try BatchName(emojis)
        }
    }

    @Test("Decoding preserves the validated-name invariant")
    func validatesDecodedName() {
        let encoded = Data(#"{"value":"../escape"}"#.utf8)

        #expect(throws: BatchName.ValidationError.forbiddenCharacter) {
            try JSONDecoder().decode(BatchName.self, from: encoded)
        }
    }
}
