import Testing
@testable import ScanDeckCore

@Suite("PFU card-scanning vendor profile")
struct PFUCardScannerProfileTests {
    @Test("Resolves opaque values independently of localized labels")
    func localizedLabels() throws {
        let feature = VendorEnumerationFeatureSnapshot(
            internalName: "FEATURE_PREPICK",
            localizedName: "Pré-sélection",
            options: [
                VendorEnumerationOption(rawValue: 0, localizedLabel: "Désactivé"),
                VendorEnumerationOption(rawValue: 1, localizedLabel: "Activé")
            ],
            currentRawValue: 1
        )
        let selection = try #require(
            PFUCardScannerProfile.requiredSelections.first {
                $0.internalName == "prepick"
            }
        )

        let resolved = try PFUCardScannerProfile.resolve(selection, in: [feature])

        #expect(resolved.rawValue == 0)
        #expect(resolved.localizedLabel == "Désactivé")
    }

    @Test("Rejects a missing required value")
    func missingValue() throws {
        let feature = VendorEnumerationFeatureSnapshot(
            internalName: "FEATURE_CROPPING",
            localizedName: "Cropping",
            options: [
                VendorEnumerationOption(rawValue: 4, localizedLabel: "Overscan")
            ],
            currentRawValue: 4
        )
        let selection = try #require(
            PFUCardScannerProfile.requiredSelections.first {
                $0.internalName == "cropping"
            }
        )

        #expect(
            throws: PFUCardScannerProfile.ResolutionError.missingValue(
                feature: "cropping",
                value: 0
            )
        ) {
            try PFUCardScannerProfile.resolve(selection, in: [feature])
        }
    }

    @Test("Accepts identical duplicate runtime feature entries")
    func identicalDuplicates() throws {
        let feature = VendorEnumerationFeatureSnapshot(
            internalName: "cropping",
            localizedName: "Cropping",
            options: [
                VendorEnumerationOption(
                    rawValue: 0,
                    localizedLabel: "None (with black background)"
                )
            ],
            currentRawValue: 4
        )
        let selection = try #require(
            PFUCardScannerProfile.requiredSelections.first {
                $0.internalName == "cropping"
            }
        )

        let resolved = try PFUCardScannerProfile.resolve(
            selection,
            in: [feature, feature]
        )

        #expect(resolved.rawValue == 0)
    }

    @Test("Rejects conflicting duplicate runtime feature entries")
    func conflictingDuplicates() throws {
        let first = VendorEnumerationFeatureSnapshot(
            internalName: "FEATURE_CROPPING",
            localizedName: "Cropping",
            options: [
                VendorEnumerationOption(rawValue: 0, localizedLabel: "Black")
            ],
            currentRawValue: 0
        )
        let second = VendorEnumerationFeatureSnapshot(
            internalName: "cropping",
            localizedName: "Cropping",
            options: [
                VendorEnumerationOption(rawValue: 4, localizedLabel: "Overscan")
            ],
            currentRawValue: 4
        )
        let selection = try #require(
            PFUCardScannerProfile.requiredSelections.first {
                $0.internalName == "cropping"
            }
        )

        #expect(
            throws: PFUCardScannerProfile.ResolutionError.ambiguousFeature(
                "cropping"
            )
        ) {
            try PFUCardScannerProfile.resolve(selection, in: [first, second])
        }
    }

    @Test("Overscan profile selects the driver's opaque overscan value")
    func overscanSelection() throws {
        let feature = VendorEnumerationFeatureSnapshot(
            internalName: "cropping",
            localizedName: "Cropping",
            options: [
                VendorEnumerationOption(
                    rawValue: 0,
                    localizedLabel: "None (with black background)"
                ),
                VendorEnumerationOption(
                    rawValue: 4,
                    localizedLabel: "Overscan"
                )
            ],
            currentRawValue: 0
        )
        let selection = try #require(
            PFUCardScannerProfile.selections(croppingMode: .overscan).first {
                $0.internalName == "cropping"
            }
        )

        let resolved = try PFUCardScannerProfile.resolve(
            selection,
            in: [feature]
        )

        #expect(selection.rawValue == 4)
        #expect(resolved.localizedLabel == "Overscan")
    }
}
