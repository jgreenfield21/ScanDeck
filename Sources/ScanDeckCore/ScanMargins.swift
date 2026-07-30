import Foundation

public struct ScanMargins: Codable, Hashable, Sendable {
    public static let cardDefault = ScanMargins(uncheckedAll: 3)

    public let topMillimeters: Double
    public let rightMillimeters: Double
    public let bottomMillimeters: Double
    public let leftMillimeters: Double

    public init(
        topMillimeters: Double,
        rightMillimeters: Double,
        bottomMillimeters: Double,
        leftMillimeters: Double
    ) throws {
        let values = [
            topMillimeters,
            rightMillimeters,
            bottomMillimeters,
            leftMillimeters
        ]

        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ValidationError.invalidValue
        }

        self.topMillimeters = topMillimeters
        self.rightMillimeters = rightMillimeters
        self.bottomMillimeters = bottomMillimeters
        self.leftMillimeters = leftMillimeters
    }

    public init(all millimeters: Double) throws {
        try self.init(
            topMillimeters: millimeters,
            rightMillimeters: millimeters,
            bottomMillimeters: millimeters,
            leftMillimeters: millimeters
        )
    }

    public func pixels(atDPI dpi: Int) throws -> PixelInsets {
        guard dpi > 0 else {
            throw ValidationError.invalidDPI
        }

        func pixels(for millimeters: Double) throws -> Int {
            let rounded = (millimeters / 25.4 * Double(dpi)).rounded()
            guard rounded.isFinite,
                  rounded >= 0,
                  rounded < Double(Int.max)
            else {
                throw ValidationError.pixelOverflow
            }
            return Int(rounded)
        }

        return PixelInsets(
            top: try pixels(for: topMillimeters),
            right: try pixels(for: rightMillimeters),
            bottom: try pixels(for: bottomMillimeters),
            left: try pixels(for: leftMillimeters)
        )
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidValue
        case invalidDPI
        case pixelOverflow
    }

    private init(uncheckedAll millimeters: Double) {
        topMillimeters = millimeters
        rightMillimeters = millimeters
        bottomMillimeters = millimeters
        leftMillimeters = millimeters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            topMillimeters: container.decode(
                Double.self,
                forKey: .topMillimeters
            ),
            rightMillimeters: container.decode(
                Double.self,
                forKey: .rightMillimeters
            ),
            bottomMillimeters: container.decode(
                Double.self,
                forKey: .bottomMillimeters
            ),
            leftMillimeters: container.decode(
                Double.self,
                forKey: .leftMillimeters
            )
        )
    }
}

public struct PixelInsets: Codable, Equatable, Sendable {
    public let top: Int
    public let right: Int
    public let bottom: Int
    public let left: Int

    public init(top: Int, right: Int, bottom: Int, left: Int) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}
