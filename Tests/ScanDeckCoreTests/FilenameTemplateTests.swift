import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Filename template")
struct FilenameTemplateTests {
    @Test("Renders the carduploader pair contract")
    func rendersCardUploaderNames() {
        let template = FilenameTemplate.cardDefault

        #expect(
            template.render(sheetNumber: 114, side: .front)
                == "scan_000114_F.jpg"
        )
        #expect(
            template.render(sheetNumber: 114, side: .back)
                == "scan_000114_B.jpg"
        )
    }

    @Test("Renders descriptive front and back names")
    func rendersDescriptiveSideNames() {
        let template = FilenameTemplate.descriptiveSides

        #expect(template.render(sheetNumber: 114, side: .front) == "scan_000114-front.jpg")
        #expect(template.render(sheetNumber: 114, side: .back) == "scan_000114-back.jpg")
    }

    @Test("Zero-pads to six digits and grows beyond them")
    func padsToSixDigits() {
        let template = FilenameTemplate.cardDefault

        #expect(
            template.render(sheetNumber: 1, side: .front) == "scan_000001_F.jpg"
        )
        #expect(
            template.render(sheetNumber: 999_999, side: .front)
                == "scan_999999_F.jpg"
        )
        // Padding is a minimum width, not a truncation.
        #expect(
            template.render(sheetNumber: 1_000_000, side: .front)
                == "scan_1000000_F.jpg"
        )
    }

    @Test("A template without a side token is refused")
    func requiresOutputSideToken() {
        // Without a side token both images of a card resolve to one name.
        #expect(throws: FilenameTemplate.ValidationError.missingOutputSide) {
            try FilenameTemplate("scan_<SheetCounter>.jpg")
        }
    }

    @Test("A template without a counter token is refused")
    func requiresSheetCounterToken() {
        #expect(throws: FilenameTemplate.ValidationError.missingSheetCounter) {
            try FilenameTemplate("scan_<OutputSide>.jpg")
        }
    }

    @Test("A template that would render a path separator is refused")
    func rejectsPathSeparators() {
        #expect(throws: FilenameTemplate.ValidationError.forbiddenCharacter) {
            try FilenameTemplate("cards/<SheetCounter>_<OutputSide>.jpg")
        }
    }

    @Test("Custom literal text is preserved")
    func preservesLiteralText() throws {
        let template = try FilenameTemplate(
            "aug01-<SheetCounter>-side<OutputSide>.jpeg"
        )

        #expect(
            template.render(sheetNumber: 7, side: .back)
                == "aug01-000007-sideB.jpeg"
        )
    }

    @Test("Round trips through JSON as a plain string")
    func roundTripsThroughJSON() throws {
        let template = try FilenameTemplate("x_<SheetCounter>_<OutputSide>.jpg")
        let data = try JSONEncoder().encode(template)

        #expect(String(decoding: data, as: UTF8.self).contains("SheetCounter"))
        #expect(try JSONDecoder().decode(FilenameTemplate.self, from: data) == template)
    }

    @Test("Decoding rejects a persisted template missing a token")
    func decodingValidates() {
        let data = Data("\"scan_<SheetCounter>.jpg\"".utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FilenameTemplate.self, from: data)
        }
    }
}
