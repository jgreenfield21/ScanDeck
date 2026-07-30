import Foundation

/// The v1 naming engine.
///
/// `SPEC.md` section 3 fixes the token set — literal text, `<SheetCounter>`
/// zero-padded to six digits, and `<OutputSide>` rendering `F` or `B` — and
/// requires that templates stay *data*, so later tokens (date, batch name, job
/// name) slot in without redesigning the engine.
///
/// The carduploader contract in section 2 depends on this exactly: it pairs
/// files by shared sheet number and `_F` / `_B` suffix.
public struct FilenameTemplate: Codable, Hashable, Sendable {
    public static let sheetCounterToken = "<SheetCounter>"
    public static let outputSideToken = "<OutputSide>"
    public static let sheetCounterWidth = 6

    /// `scan_<SheetCounter>_<OutputSide>.jpg`
    public static let cardDefault = FilenameTemplate(
        unchecked: "scan_\(sheetCounterToken)_\(outputSideToken).jpg"
    )

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.contains(Self.sheetCounterToken) else {
            throw ValidationError.missingSheetCounter
        }
        guard rawValue.contains(Self.outputSideToken) else {
            throw ValidationError.missingOutputSide
        }

        // Whatever the template renders must still be a legal, single-segment
        // filename, so the same character rules as a batch name apply.
        let rendered = Self.render(
            rawValue,
            sheetNumber: 0,
            side: .front
        )
        guard !rendered.isEmpty else {
            throw ValidationError.rendersEmptyName
        }
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|")
        guard rendered.unicodeScalars.allSatisfy({
            !forbidden.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ValidationError.forbiddenCharacter
        }

        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func render(sheetNumber: UInt64, side: OutputSide) -> String {
        Self.render(rawValue, sheetNumber: sheetNumber, side: side)
    }

    private static func render(
        _ template: String,
        sheetNumber: UInt64,
        side: OutputSide
    ) -> String {
        template
            .replacingOccurrences(
                of: sheetCounterToken,
                with: String(
                    format: "%0\(sheetCounterWidth)llu",
                    sheetNumber
                )
            )
            .replacingOccurrences(
                of: outputSideToken,
                with: side.rawValue
            )
    }

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case missingSheetCounter
        case missingOutputSide
        case rendersEmptyName
        case forbiddenCharacter

        public var errorDescription: String? {
            switch self {
            case .missingSheetCounter:
                "The filename template must include \(FilenameTemplate.sheetCounterToken)."
            case .missingOutputSide:
                "The filename template must include \(FilenameTemplate.outputSideToken) "
                    + "so front and back files do not collide."
            case .rendersEmptyName:
                "This filename template produces an empty name."
            case .forbiddenCharacter:
                "Filenames cannot contain \\/:*?\"<>| or control characters."
            }
        }
    }
}
