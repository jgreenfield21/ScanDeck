import Foundation

public struct VendorEnumerationOption: Equatable, Sendable {
    public let rawValue: Int
    public let localizedLabel: String

    public init(rawValue: Int, localizedLabel: String) {
        self.rawValue = rawValue
        self.localizedLabel = localizedLabel
    }
}

public struct VendorEnumerationFeatureSnapshot: Equatable, Sendable {
    public let internalName: String
    public let localizedName: String?
    public let options: [VendorEnumerationOption]
    public let currentRawValue: Int?

    public init(
        internalName: String,
        localizedName: String?,
        options: [VendorEnumerationOption],
        currentRawValue: Int?
    ) {
        self.internalName = internalName
        self.localizedName = localizedName
        self.options = options
        self.currentRawValue = currentRawValue
    }
}

public struct VendorFeatureSelection: Equatable, Sendable {
    public let internalName: String
    public let rawValue: Int
    public let purpose: String

    public init(internalName: String, rawValue: Int, purpose: String) {
        self.internalName = internalName
        self.rawValue = rawValue
        self.purpose = purpose
    }
}

public enum PFUCroppingMode: Int, Codable, Sendable {
    /// Preserve the driver's full configured scan frame with black background.
    case fullFrameBlack = 0
    /// Ask the PFU driver for capture beyond the detected media boundary.
    case overscan = 4
}

public enum PFUCardScannerProfile {
    // PFU exposes localized labels, so selections use the stable feature key and
    // the opaque values published by the driver rather than English UI strings.
    public static let requiredSelections = selections(
        croppingMode: .fullFrameBlack
    )

    public static func selections(
        croppingMode: PFUCroppingMode
    ) -> [VendorFeatureSelection] {
        let croppingPurpose = switch croppingMode {
        case .fullFrameBlack:
            "None with black background"
        case .overscan:
            "Overscan for real background around the media"
        }

        return [
            VendorFeatureSelection(
                internalName: "cropping",
                rawValue: croppingMode.rawValue,
                purpose: croppingPurpose
            ),
            VendorFeatureSelection(
                internalName: "multifeed_detection",
                rawValue: 0,
                purpose: "Multifeed detection off"
            ),
            VendorFeatureSelection(
                internalName: "blank_page_skip",
                rawValue: 0,
                purpose: "Blank-page skip off"
            ),
            VendorFeatureSelection(
                internalName: "prepick",
                rawValue: 0,
                purpose: "Pre-pick off"
            )
        ]
    }

    public static func canonicalInternalName(_ name: String) -> String {
        let lowercase = name.lowercased()
        return lowercase.hasPrefix("feature_")
            ? String(lowercase.dropFirst("feature_".count))
            : lowercase
    }

    public static func resolve(
        _ selection: VendorFeatureSelection,
        in features: [VendorEnumerationFeatureSnapshot]
    ) throws -> VendorEnumerationOption {
        let matchingFeatures = features.filter {
            canonicalInternalName($0.internalName)
                == canonicalInternalName(selection.internalName)
        }

        guard let feature = matchingFeatures.first else {
            throw ResolutionError.missingFeature(selection.internalName)
        }

        guard matchingFeatures.dropFirst().allSatisfy({
            $0.options == feature.options
        }) else {
            throw ResolutionError.ambiguousFeature(selection.internalName)
        }

        let matchingOptions = feature.options.filter {
            $0.rawValue == selection.rawValue
        }

        guard matchingOptions.count == 1, let option = matchingOptions.first else {
            if matchingOptions.isEmpty {
                throw ResolutionError.missingValue(
                    feature: selection.internalName,
                    value: selection.rawValue
                )
            }
            throw ResolutionError.ambiguousValue(
                feature: selection.internalName,
                value: selection.rawValue
            )
        }

        return option
    }

    public enum ResolutionError: Error, Equatable, LocalizedError, Sendable {
        case missingFeature(String)
        case ambiguousFeature(String)
        case missingValue(feature: String, value: Int)
        case ambiguousValue(feature: String, value: Int)

        public var errorDescription: String? {
            switch self {
            case let .missingFeature(feature):
                "Required vendor feature \(feature) is missing."
            case let .ambiguousFeature(feature):
                "Vendor feature \(feature) has conflicting definitions."
            case let .missingValue(feature, value):
                "Vendor feature \(feature) does not offer value \(value)."
            case let .ambiguousValue(feature, value):
                "Vendor feature \(feature) offers value \(value) more than once."
            }
        }
    }
}
