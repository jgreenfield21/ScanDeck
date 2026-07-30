import Foundation

public struct BatchName: Codable, Hashable, Sendable {
    public static let maximumLength = 128
    public static let maximumUTF8ByteCount = 255

    public let value: String

    public init(_ candidate: String) throws {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.precomposedStringWithCanonicalMapping

        guard !normalized.isEmpty else {
            throw ValidationError.empty
        }
        guard normalized != ".", normalized != ".." else {
            throw ValidationError.reserved
        }
        guard !normalized.hasSuffix(".") else {
            throw ValidationError.trailingPeriod
        }
        guard normalized.count <= Self.maximumLength else {
            throw ValidationError.tooLong(maximum: Self.maximumLength)
        }
        guard normalized.utf8.count <= Self.maximumUTF8ByteCount else {
            throw ValidationError.tooManyUTF8Bytes(
                maximum: Self.maximumUTF8ByteCount
            )
        }
        guard normalized.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ValidationError.controlCharacter
        }

        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|")
        guard normalized.unicodeScalars.allSatisfy({
            !forbidden.contains($0)
        }) else {
            throw ValidationError.forbiddenCharacter
        }

        value = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .value))
    }

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case empty
        case reserved
        case trailingPeriod
        case tooLong(maximum: Int)
        case tooManyUTF8Bytes(maximum: Int)
        case controlCharacter
        case forbiddenCharacter

        public var errorDescription: String? {
            switch self {
            case .empty:
                "Enter a batch name."
            case .reserved:
                "Choose a different batch name."
            case .trailingPeriod:
                "Batch names cannot end with a period."
            case let .tooLong(maximum):
                "Batch names can contain at most \(maximum) characters."
            case let .tooManyUTF8Bytes(maximum):
                "This batch name is too large for a folder name "
                    + "(\(maximum) UTF-8 bytes maximum)."
            case .controlCharacter:
                "Batch names cannot contain control characters."
            case .forbiddenCharacter:
                "Batch names cannot contain \\/:*?\"<>|."
            }
        }
    }
}
