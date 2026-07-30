import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Physical scan margins")
struct ScanMarginsTests {
    @Test("Three millimeters is 71 pixels at 600 DPI")
    func threeMillimetersAt600DPI() throws {
        let pixels = try ScanMargins.cardDefault.pixels(atDPI: 600)

        #expect(pixels == PixelInsets(top: 71, right: 71, bottom: 71, left: 71))
    }

    @Test("Rejects negative and non-finite values")
    func invalidMargins() {
        #expect(throws: ScanMargins.ValidationError.invalidValue) {
            try ScanMargins(all: -1)
        }
        #expect(throws: ScanMargins.ValidationError.invalidValue) {
            try ScanMargins(all: .infinity)
        }
    }

    @Test("Rejects pixel conversions that exceed the integer range")
    func pixelOverflow() throws {
        let margins = try ScanMargins(all: Double.greatestFiniteMagnitude)

        #expect(throws: ScanMargins.ValidationError.pixelOverflow) {
            try margins.pixels(atDPI: 600)
        }
    }

    @Test("Decoding preserves the validated-margin invariant")
    func invalidDecodedMargins() {
        let encoded = Data(
            """
            {
              "topMillimeters": -1,
              "rightMillimeters": 3,
              "bottomMillimeters": 3,
              "leftMillimeters": 3
            }
            """.utf8
        )

        #expect(throws: ScanMargins.ValidationError.invalidValue) {
            try JSONDecoder().decode(ScanMargins.self, from: encoded)
        }
    }
}
