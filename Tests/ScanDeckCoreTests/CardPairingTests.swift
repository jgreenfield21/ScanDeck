import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Duplex card pairing")
struct CardPairingTests {
    @Test("Pairs front-first delivery and retains an incomplete tail")
    func frontFirst() throws {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .frontFirst,
            firstSheetNumber: 114
        )

        #expect(try accumulator.append(sourceURL: URL(filePath: "/tmp/1.jpg")) == nil)
        let firstPair = try accumulator.append(sourceURL: URL(filePath: "/tmp/2.jpg"))
        #expect(firstPair?.provisionalSheetNumber == 114)
        #expect(firstPair?.front.arrivalIndex == 0)
        #expect(firstPair?.back.arrivalIndex == 1)

        #expect(try accumulator.append(sourceURL: URL(filePath: "/tmp/3.jpg")) == nil)
        #expect(accumulator.incompleteCard?.provisionalSheetNumber == 115)
        #expect(accumulator.incompleteCard?.expectedSide == .back)
    }

    @Test("Maps back-first delivery without changing arrival order")
    func backFirst() throws {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .backFirst,
            firstSheetNumber: 9
        )

        _ = try accumulator.append(sourceURL: URL(filePath: "/tmp/back.jpg"))
        let pair = try accumulator.append(sourceURL: URL(filePath: "/tmp/front.jpg"))

        #expect(pair?.front.sourceURL.lastPathComponent == "front.jpg")
        #expect(pair?.back.sourceURL.lastPathComponent == "back.jpg")
        #expect(pair?.provisionalSheetNumber == 9)
    }

    @Test("An incomplete page never pairs across feeder passes")
    func passBoundaryResetsParity() throws {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .frontFirst,
            firstSheetNumber: 42
        )

        _ = try accumulator.append(
            sourceURL: URL(filePath: "/tmp/incomplete-front.jpg")
        )
        let incomplete = accumulator.finishPass()

        #expect(incomplete?.provisionalSheetNumber == 42)
        #expect(incomplete?.expectedSide == .back)
        #expect(accumulator.incompleteCard == incomplete)

        #expect(
            throws: CardPairingAccumulator.PairingError
                .incompleteCardMustBeResolved(provisionalSheetNumber: 42)
        ) {
            try accumulator.append(sourceURL: URL(filePath: "/tmp/next-front.jpg"))
        }

        try accumulator.beginRetry()
        #expect(
            try accumulator.append(sourceURL: URL(filePath: "/tmp/retry-front.jpg"))
                == nil
        )
        let replacement = try accumulator.append(
            sourceURL: URL(filePath: "/tmp/retry-back.jpg")
        )
        #expect(accumulator.finishPass() == nil)

        #expect(replacement?.provisionalSheetNumber == 42)
        #expect(replacement?.front.sourceURL.lastPathComponent == "retry-front.jpg")
        #expect(replacement?.back.sourceURL.lastPathComponent == "retry-back.jpg")
    }

    @Test("Complete feeder passes continue the stable counter")
    func completePassesContinueCounter() throws {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .frontFirst,
            firstSheetNumber: 114
        )

        _ = try accumulator.append(sourceURL: URL(filePath: "/tmp/114-front.jpg"))
        let first = try accumulator.append(
            sourceURL: URL(filePath: "/tmp/114-back.jpg")
        )
        #expect(accumulator.finishPass() == nil)

        _ = try accumulator.append(sourceURL: URL(filePath: "/tmp/115-front.jpg"))
        let second = try accumulator.append(
            sourceURL: URL(filePath: "/tmp/115-back.jpg")
        )
        #expect(accumulator.finishPass() == nil)

        #expect(first?.provisionalSheetNumber == 114)
        #expect(second?.provisionalSheetNumber == 115)
        #expect(accumulator.nextSheetNumber == 116)
    }

    @Test("A failed retry retains the original incomplete capture")
    func failedRetryRetainsOriginal() throws {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .frontFirst,
            firstSheetNumber: 8
        )

        _ = try accumulator.append(sourceURL: URL(filePath: "/tmp/original.jpg"))
        let finishedPass = accumulator.finishPass()
        let original = try #require(finishedPass)

        try accumulator.beginRetry()
        _ = try accumulator.append(sourceURL: URL(filePath: "/tmp/failed-retry.jpg"))
        let retryTail = accumulator.finishPass()

        #expect(retryTail?.page.sourceURL.lastPathComponent == "failed-retry.jpg")
        #expect(accumulator.incompleteCard == original)
        #expect(accumulator.nextSheetNumber == 8)
    }

    @Test("Deleting an incomplete card leaves a stable number gap")
    func deleteIncompleteLeavesGap() throws {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .frontFirst,
            firstSheetNumber: 20
        )

        _ = try accumulator.append(sourceURL: URL(filePath: "/tmp/20-front.jpg"))
        _ = accumulator.finishPass()
        let deleted = try accumulator.deleteIncompleteCardLeavingGap()

        #expect(deleted?.provisionalSheetNumber == 20)
        #expect(accumulator.incompleteCard == nil)
        #expect(accumulator.nextSheetNumber == 21)
    }

    @Test("Counter exhaustion rejects a page without partial mutation")
    func counterExhaustionIsTransactional() {
        var accumulator = CardPairingAccumulator(
            deliveryOrder: .frontFirst,
            firstSheetNumber: UInt64.max
        )

        #expect(throws: CardPairingAccumulator.PairingError.counterExhausted) {
            try accumulator.append(sourceURL: URL(filePath: "/tmp/never-added.jpg"))
        }
        #expect(accumulator.nextArrivalIndex == 0)
        #expect(accumulator.incompleteCard == nil)
    }
}
