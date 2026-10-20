import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Persisted batch session reducer")
struct BatchSessionTests {
    @Test("Automatic front orientation applies the duplex half-turn to the back")
    func automaticOrientationAccountsForDuplexBack() throws {
        var session = try makeSession(firstSheetNumber: 1)
        let pass = scanPassID(950)
        try reduce(.beginAppend(passID: pass), into: &session)
        try receive(
            pass: pass,
            master: 950,
            sequence: 0,
            newCard: 950,
            into: &session
        )
        try receive(
            pass: pass,
            master: 951,
            sequence: 1,
            into: &session
        )
        try reduce(.scanEnded(passID: pass, outcome: .completed), into: &session)

        let effects = try reduce(
            .automaticallyOrient(
                masterID: masterID(950),
                expectedRotation: .zero,
                rotation: .clockwise270
            ),
            into: &session
        )

        let sides = try #require(session.cards[0].activeSides)
        #expect(sides.front?.rotation == .clockwise270)
        #expect(sides.back?.rotation == .clockwise90)
        #expect(effects.count == 2)
    }

    @Test("Manual crop persists per side and requests fresh margin analysis")
    func manualCropPersistsAndReassesses() throws {
        var session = try makeSession(firstSheetNumber: 1)
        let pass = scanPassID(900)
        try reduce(.beginAppend(passID: pass), into: &session)
        try receive(
            pass: pass,
            master: 900,
            sequence: 0,
            newCard: 900,
            into: &session
        )
        try receive(
            pass: pass,
            master: 901,
            sequence: 1,
            into: &session
        )
        try reduce(.scanEnded(passID: pass, outcome: .completed), into: &session)

        let crop = ManualCropRect(x: 0.12, y: 0.18, width: 0.7, height: 0.6)
        let effects = try reduce(
            .setManualCrop(cardID: cardID(900), side: .front, crop: crop),
            into: &session
        )

        #expect(session.cards[0].activeSides?.front?.manualCrop == crop)
        #expect(session.cards[0].activeSides?.back?.manualCrop == nil)
        #expect(session.cards[0].activeSides?.front?.marginAssessment == .pending)
        #expect(
            effects == [
                .assessMargin(
                    masterID: masterID(900),
                    rotation: .zero,
                    manualCrop: crop,
                    requestedMargins: session.requestedMargins
                )
            ]
        )

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(BatchSession.self, from: data)
        #expect(restored.cards[0].activeSides?.front?.manualCrop == crop)
    }

    @Test("Append reserves stable numbers and an odd tail blocks Continue")
    func appendAndIncompleteGate() throws {
        var session = try makeSession(firstSheetNumber: 114)
        let firstPass = scanPassID(1)

        try reduce(.beginAppend(passID: firstPass), into: &session)
        try receive(
            pass: firstPass,
            master: 1,
            sequence: 0,
            newCard: 1,
            into: &session
        )
        #expect(session.cards[0].provisionalSheetNumber == 114)
        #expect(session.nextSheetNumber == 115)

        try receive(
            pass: firstPass,
            master: 2,
            sequence: 1,
            into: &session
        )
        try receive(
            pass: firstPass,
            master: 3,
            sequence: 2,
            newCard: 2,
            into: &session
        )
        try reduce(
            .scanEnded(passID: firstPass, outcome: .completed),
            into: &session
        )

        let firstSides = try #require(session.cards[0].activeSides)
        #expect(firstSides.front?.masterID == masterID(1))
        #expect(firstSides.back?.masterID == masterID(2))
        #expect(session.cards[1].provisionalSheetNumber == 115)
        #expect(session.cards[1].activeSides?.missingSides == [.back])
        #expect(!session.canContinueScanning)
        #expect(!session.canCompleteBatch)

        let unchanged = session
        #expect(throws: BatchSessionError.incompleteCardsBlockContinue) {
            try reduce(.beginAppend(passID: scanPassID(2)), into: &session)
        }
        #expect(session == unchanged)

        let deleteEffects = try reduce(
            .deleteCard(cardID: cardID(2)),
            into: &session
        )
        #expect(
            deleteEffects == [
                .mastersBecameUnreferenced([masterID(3)])
            ]
        )
        #expect(session.cards[1].isDeleted)
        #expect(session.canContinueScanning)

        let secondPass = scanPassID(3)
        try reduce(.beginAppend(passID: secondPass), into: &session)
        try receive(
            pass: secondPass,
            master: 4,
            sequence: 3,
            newCard: 3,
            into: &session
        )
        try receive(
            pass: secondPass,
            master: 5,
            sequence: 4,
            into: &session
        )
        try reduce(
            .scanEnded(passID: secondPass, outcome: .completed),
            into: &session
        )

        #expect(
            session.cards.map(\.provisionalSheetNumber) == [114, 115, 116]
        )
        #expect(session.nextSheetNumber == 117)
    }

    @Test("Retry keeps the old row until an exact duplex pass commits")
    func retryIsAtomic() throws {
        var session = try makeSession(firstSheetNumber: 8)
        let appendPass = scanPassID(10)
        try reduce(.beginAppend(passID: appendPass), into: &session)
        try receive(
            pass: appendPass,
            master: 10,
            sequence: 0,
            newCard: 10,
            into: &session
        )
        try reduce(
            .scanEnded(passID: appendPass, outcome: .completed),
            into: &session
        )

        let original = session.cards[0]
        let failedRetry = scanPassID(11)
        try reduce(
            .beginRetry(cardID: original.id, passID: failedRetry),
            into: &session
        )
        try receive(
            pass: failedRetry,
            master: 11,
            sequence: 1,
            into: &session
        )
        #expect(session.cards[0] == original)

        let failedEffects = try reduce(
            .scanEnded(passID: failedRetry, outcome: .completed),
            into: &session
        )
        #expect(session.cards[0] == original)
        #expect(
            failedEffects == [
                .mastersBecameUnreferenced([masterID(11)])
            ]
        )

        let successfulRetry = scanPassID(12)
        try reduce(
            .beginRetry(cardID: original.id, passID: successfulRetry),
            into: &session
        )
        try receive(
            pass: successfulRetry,
            master: 12,
            sequence: 2,
            into: &session
        )
        try receive(
            pass: successfulRetry,
            master: 13,
            sequence: 3,
            into: &session
        )
        #expect(session.cards[0] == original)

        let successEffects = try reduce(
            .scanEnded(passID: successfulRetry, outcome: .completed),
            into: &session
        )
        let retried = session.cards[0]
        let retriedSides = try #require(retried.activeSides)

        #expect(retried.id == original.id)
        #expect(
            retried.provisionalSheetNumber
                == original.provisionalSheetNumber
        )
        #expect(retriedSides.front?.masterID == masterID(12))
        #expect(retriedSides.back?.masterID == masterID(13))
        #expect(session.nextSheetNumber == 9)
        #expect(
            successEffects == [
                .mastersBecameUnreferenced([masterID(10)])
            ]
        )
    }

    @Test("Replace Card swaps both sides only after exact successful completion")
    func replacementIsAtomic() throws {
        var session = try makeSession(
            firstSheetNumber: 30,
            deliveryOrder: .backFirst
        )
        try appendCompleteCard(
            card: 30,
            masters: (30, 31),
            pass: 30,
            startingSequence: 0,
            into: &session
        )

        let original = session.cards[0]
        let excessPass = scanPassID(31)
        try reduce(
            .beginReplace(cardID: original.id, passID: excessPass),
            into: &session
        )
        for (offset, master) in [32, 33, 34].enumerated() {
            try receive(
                pass: excessPass,
                master: master,
                sequence: UInt64(offset + 2),
                into: &session
            )
        }
        let excessEffects = try reduce(
            .scanEnded(passID: excessPass, outcome: .completed),
            into: &session
        )
        #expect(session.cards[0] == original)
        #expect(
            excessEffects == [
                .mastersBecameUnreferenced([
                    masterID(32), masterID(33), masterID(34)
                ])
            ]
        )

        let replacementPass = scanPassID(32)
        try reduce(
            .beginReplace(cardID: original.id, passID: replacementPass),
            into: &session
        )
        try receive(
            pass: replacementPass,
            master: 35,
            sequence: 5,
            into: &session
        )
        try receive(
            pass: replacementPass,
            master: 36,
            sequence: 6,
            into: &session
        )
        #expect(session.cards[0] == original)

        let effects = try reduce(
            .scanEnded(passID: replacementPass, outcome: .completed),
            into: &session
        )
        let replacement = try #require(session.cards[0].activeSides)

        // The job is back-first, so callback order is B then F.
        #expect(replacement.back?.masterID == masterID(35))
        #expect(replacement.front?.masterID == masterID(36))
        #expect(replacement.front?.rotation == .zero)
        #expect(replacement.back?.rotation == .zero)
        #expect(
            effects == [
                .mastersBecameUnreferenced([
                    masterID(30), masterID(31)
                ])
            ]
        )
    }

    @Test("A failed two-page replacement still preserves both original sides")
    func failedDuplexReplacementPreservesOriginal() throws {
        var session = try makeSession()
        try appendCompleteCard(
            card: 35,
            masters: (35, 36),
            pass: 35,
            startingSequence: 0,
            into: &session
        )
        let original = session.cards[0]
        let pass = scanPassID(36)

        try reduce(
            .beginReplace(cardID: original.id, passID: pass),
            into: &session
        )
        try receive(
            pass: pass,
            master: 37,
            sequence: 2,
            into: &session
        )
        try receive(
            pass: pass,
            master: 38,
            sequence: 3,
            into: &session
        )
        let scanFailure = BatchIssue(
            kind: .scanFailed,
            message: "The feeder reported a transport error."
        )
        let effects = try reduce(
            .scanEnded(passID: pass, outcome: .failed(scanFailure)),
            into: &session
        )

        #expect(session.cards[0] == original)
        #expect(session.lastIssue == scanFailure)
        #expect(
            effects == [
                .mastersBecameUnreferenced([
                    masterID(37), masterID(38)
                ])
            ]
        )
    }

    @Test("Deleting sides can leave a zero-side row that only Retry can repair")
    func deleteSidesAndRetry() throws {
        var session = try makeSession()
        try appendCompleteCard(
            card: 40,
            masters: (40, 41),
            pass: 40,
            startingSequence: 0,
            into: &session
        )
        let id = session.cards[0].id

        _ = try reduce(.deleteSide(cardID: id, side: .front), into: &session)
        _ = try reduce(.deleteSide(cardID: id, side: .back), into: &session)

        #expect(session.cards[0].activeSides?.missingSides == [.front, .back])
        #expect(!session.canContinueScanning)

        let retryPass = scanPassID(41)
        try reduce(
            .beginRetry(cardID: id, passID: retryPass),
            into: &session
        )
        try receive(
            pass: retryPass,
            master: 42,
            sequence: 2,
            into: &session
        )
        try receive(
            pass: retryPass,
            master: 43,
            sequence: 3,
            into: &session
        )
        try reduce(
            .scanEnded(passID: retryPass, outcome: .completed),
            into: &session
        )

        #expect(session.cards[0].activeSides?.isComplete == true)
        #expect(session.canContinueScanning)
    }

    @Test("Retry can target an older card without changing the high-water mark")
    func retryOlderCard() throws {
        var session = try makeSession(firstSheetNumber: 100)
        try appendCompleteCard(
            card: 100,
            masters: (100, 101),
            pass: 100,
            startingSequence: 0,
            into: &session
        )
        try appendCompleteCard(
            card: 101,
            masters: (102, 103),
            pass: 101,
            startingSequence: 2,
            into: &session
        )
        let olderID = session.cards[0].id

        try reduce(
            .deleteSide(cardID: olderID, side: .back),
            into: &session
        )
        let retry = scanPassID(102)
        try reduce(
            .beginRetry(cardID: olderID, passID: retry),
            into: &session
        )
        try receive(
            pass: retry,
            master: 104,
            sequence: 4,
            into: &session
        )
        try receive(
            pass: retry,
            master: 105,
            sequence: 5,
            into: &session
        )
        try reduce(
            .scanEnded(passID: retry, outcome: .completed),
            into: &session
        )

        #expect(session.cards[0].id == olderID)
        #expect(session.cards[0].provisionalSheetNumber == 100)
        #expect(session.cards[1].provisionalSheetNumber == 101)
        #expect(session.nextSheetNumber == 102)
    }

    @Test("Margins gate completion but not Continue, and rotation reassesses")
    func marginsRotationAndCompletion() throws {
        var session = try makeSession(firstSheetNumber: 50)
        try appendCompleteCard(
            card: 50,
            masters: (50, 51),
            pass: 50,
            startingSequence: 0,
            into: &session
        )
        let id = session.cards[0].id

        #expect(session.canContinueScanning)
        #expect(!session.canCompleteBatch)

        try reduce(
            .marginAssessed(
                masterID: masterID(50),
                rotation: .zero,
                result: .sufficient(mediaSize: nil)
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(51),
                rotation: .zero,
                result: .insufficient(edges: [.left])
            ),
            into: &session
        )
        #expect(session.canContinueScanning)
        #expect(!session.canCompleteBatch)

        let rotationEffects = try reduce(
            .rotate(cardID: id, side: .front, direction: .clockwise),
            into: &session
        )
        #expect(
            rotationEffects == [
                .assessMargin(
                    masterID: masterID(50),
                    rotation: .clockwise90,
                    manualCrop: nil,
                    requestedMargins: .cardDefault
                )
            ]
        )
        #expect(
            session.cards[0].activeSides?.front?.marginAssessment
                == .pending
        )

        let rotatedSnapshot = session
        #expect(
            throws: BatchSessionError.staleMarginAssessment(
                masterID: masterID(50),
                assessedRotation: .zero,
                currentRotation: .clockwise90
            )
        ) {
            try reduce(
                .marginAssessed(
                    masterID: masterID(50),
                    rotation: .zero,
                    result: .sufficient(mediaSize: nil)
                ),
                into: &session
            )
        }
        #expect(session == rotatedSnapshot)

        try reduce(
            .marginAssessed(
                masterID: masterID(50),
                rotation: .clockwise90,
                result: .sufficient(mediaSize: nil)
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(51),
                rotation: .zero,
                result: .sufficient(mediaSize: nil)
            ),
            into: &session
        )
        #expect(session.canCompleteBatch)

        let attempt = releaseAttemptID(50)
        let completionEffects = try reduce(
            .requestCompletion(attemptID: attempt),
            into: &session
        )
        guard case let .prepareCompletion(candidate) = completionEffects.first
        else {
            Issue.record("Expected a completion candidate.")
            return
        }
        #expect(candidate.cards.count == 1)
        #expect(candidate.nextPersistentCounter == 51)
        #expect(candidate.cards[0].front.rotation == .clockwise90)

        let immutableReleaseState = session
        #expect(throws: BatchSessionError.self) {
            try reduce(
                .rotate(
                    cardID: id,
                    side: .front,
                    direction: .clockwise
                ),
                into: &session
            )
        }
        #expect(session == immutableReleaseState)

        let releaseFailure = BatchIssue(
            kind: .releaseFailed,
            message: "Destination disappeared."
        )
        try reduce(
            .completionFailed(attemptID: attempt, issue: releaseFailure),
            into: &session
        )
        #expect(session.lastIssue == releaseFailure)
        let failedReleaseState = session
        #expect(
            throws: BatchSessionError.staleReleaseAttempt(attempt)
        ) {
            try reduce(
                .resumeCompletion(attemptID: attempt),
                into: &session
            )
        }
        #expect(session == failedReleaseState)

        let secondAttempt = releaseAttemptID(51)
        try reduce(
            .requestCompletion(attemptID: secondAttempt),
            into: &session
        )
        try reduce(
            .completionSucceeded(
                attemptID: secondAttempt,
                destinationDescription: "Google Drive/aug01-sale"
            ),
            into: &session
        )

        guard case let .completed(summary) = session.phase else {
            Issue.record("Expected a completed batch.")
            return
        }
        #expect(summary.cardCount == 1)
        #expect(summary.destinationDescription == "Google Drive/aug01-sale")
    }

    @Test("Interrupted targeted scan preserves its original card")
    func interruptedReplacementRecovery() throws {
        var session = try makeSession()
        try appendCompleteCard(
            card: 60,
            masters: (60, 61),
            pass: 60,
            startingSequence: 0,
            into: &session
        )
        let original = session.cards[0]
        let replacementPass = scanPassID(61)

        try reduce(
            .beginReplace(cardID: original.id, passID: replacementPass),
            into: &session
        )
        try receive(
            pass: replacementPass,
            master: 62,
            sequence: 2,
            into: &session
        )
        let effects = try reduce(.recoverInterruptedScan, into: &session)

        #expect(session.cards[0] == original)
        #expect(
            effects == [
                .mastersBecameUnreferenced([masterID(62)])
            ]
        )
        #expect(session.lastIssue?.kind == .scanInterrupted)
        #expect(session.continuationBlockers.isEmpty)
    }

    @Test("Stale callbacks and counter exhaustion do not partially mutate")
    func invalidActionsAreTransactional() throws {
        var session = try makeSession(firstSheetNumber: UInt64.max)
        let pass = scanPassID(70)
        try reduce(.beginAppend(passID: pass), into: &session)

        var snapshot = session
        #expect(throws: BatchSessionError.staleScanPass(scanPassID(71))) {
            try receive(
                pass: scanPassID(71),
                master: 70,
                sequence: 0,
                newCard: 70,
                into: &session
            )
        }
        #expect(session == snapshot)

        #expect(throws: BatchSessionError.counterExhausted) {
            try receive(
                pass: pass,
                master: 70,
                sequence: 0,
                newCard: 70,
                into: &session
            )
        }
        #expect(session == snapshot)

        snapshot = session
        #expect(
            throws: BatchSessionError.unexpectedCaptureSequence(
                expected: 0,
                actual: 4
            )
        ) {
            try receive(
                pass: pass,
                master: 70,
                sequence: 4,
                newCard: 70,
                into: &session
            )
        }
        #expect(session == snapshot)
    }

    @Test("JSON round trips validated ready, scanning, review, and release states")
    func persistenceRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var ready = try makeSession()
        try expectRoundTrip(ready, encoder: encoder, decoder: decoder)

        let pass = scanPassID(80)
        try reduce(.beginAppend(passID: pass), into: &ready)
        try receive(
            pass: pass,
            master: 80,
            sequence: 0,
            newCard: 80,
            into: &ready
        )
        try expectRoundTrip(ready, encoder: encoder, decoder: decoder)

        try reduce(
            .scanEnded(passID: pass, outcome: .completed),
            into: &ready
        )
        try expectRoundTrip(ready, encoder: encoder, decoder: decoder)

        let retry = scanPassID(81)
        try reduce(
            .beginRetry(cardID: cardID(80), passID: retry),
            into: &ready
        )
        try receive(
            pass: retry,
            master: 81,
            sequence: 1,
            into: &ready
        )
        try expectRoundTrip(ready, encoder: encoder, decoder: decoder)

        try receive(
            pass: retry,
            master: 82,
            sequence: 2,
            into: &ready
        )
        try reduce(
            .scanEnded(passID: retry, outcome: .completed),
            into: &ready
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(81),
                rotation: .zero,
                result: .sufficient(mediaSize: nil)
            ),
            into: &ready
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(82),
                rotation: .zero,
                result: .sufficient(mediaSize: nil)
            ),
            into: &ready
        )
        try expectRoundTrip(ready, encoder: encoder, decoder: decoder)

        let attempt = releaseAttemptID(80)
        let initialCompletionEffects = try reduce(
            .requestCompletion(attemptID: attempt),
            into: &ready
        )
        let encodedRelease = try encoder.encode(ready)
        var recoveredRelease = try decoder.decode(
            BatchSession.self,
            from: encodedRelease
        )
        #expect(recoveredRelease == ready)

        let frozenRelease = recoveredRelease
        let firstResume = try reduce(
            .resumeCompletion(attemptID: attempt),
            into: &recoveredRelease
        )
        let secondResume = try reduce(
            .resumeCompletion(attemptID: attempt),
            into: &recoveredRelease
        )
        #expect(firstResume == initialCompletionEffects)
        #expect(secondResume == initialCompletionEffects)
        #expect(recoveredRelease == frozenRelease)

        #expect(
            throws: BatchSessionError.staleReleaseAttempt(
                releaseAttemptID(81)
            )
        ) {
            try reduce(
                .resumeCompletion(attemptID: releaseAttemptID(81)),
                into: &recoveredRelease
            )
        }
        #expect(recoveredRelease == frozenRelease)
        ready = recoveredRelease

        try reduce(
            .completionSucceeded(
                attemptID: attempt,
                destinationDescription: "Output/aug01-sale"
            ),
            into: &ready
        )
        try expectRoundTrip(ready, encoder: encoder, decoder: decoder)

        let completedSnapshot = ready
        #expect(
            throws: BatchSessionError.staleReleaseAttempt(attempt)
        ) {
            try reduce(
                .resumeCompletion(attemptID: attempt),
                into: &ready
            )
        }
        #expect(ready == completedSnapshot)
    }

    @Test("Decoding rejects an unknown persisted schema")
    func rejectsUnknownSchema() throws {
        let session = try makeSession()
        let encoded = try JSONEncoder().encode(session)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object["schemaVersion"] = 999
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(
            throws: BatchSessionError.unsupportedSchemaVersion(999)
        ) {
            try JSONDecoder().decode(BatchSession.self, from: corrupted)
        }
    }

    @Test("Decoding rejects operation history in a ready batch")
    func rejectsReadyBatchWithHistory() throws {
        let encoded = try JSONEncoder().encode(try makeSession())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        let encodedPassID = try JSONEncoder().encode(scanPassID(290))
        let passObject = try JSONSerialization.jsonObject(
            with: encodedPassID
        )
        object["usedScanPassIDs"] = [passObject]
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: BatchSessionError.self) {
            try JSONDecoder().decode(BatchSession.self, from: corrupted)
        }
    }

    @Test("Decoding rejects a corrupted provisional-counter high-water mark")
    func rejectsCorruptedCounter() throws {
        var session = try makeSession(firstSheetNumber: 200)
        try appendCompleteCard(
            card: 200,
            masters: (200, 201),
            pass: 200,
            startingSequence: 0,
            into: &session
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object["nextSheetNumber"] = 999
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: BatchSessionError.self) {
            try JSONDecoder().decode(BatchSession.self, from: corrupted)
        }
    }

    @Test("Decoding rejects reordered or gapped targeted-scan staging")
    func rejectsCorruptedStagedCaptureOrder() throws {
        var session = try makeSession()
        let append = scanPassID(300)
        try reduce(.beginAppend(passID: append), into: &session)
        try receive(
            pass: append,
            master: 300,
            sequence: 0,
            newCard: 300,
            into: &session
        )
        try reduce(
            .scanEnded(passID: append, outcome: .completed),
            into: &session
        )

        let failedRetry = scanPassID(301)
        try reduce(
            .beginRetry(cardID: cardID(300), passID: failedRetry),
            into: &session
        )
        try receive(
            pass: failedRetry,
            master: 301,
            sequence: 1,
            into: &session
        )
        try reduce(
            .scanEnded(passID: failedRetry, outcome: .completed),
            into: &session
        )

        let activeRetry = scanPassID(302)
        try reduce(
            .beginRetry(cardID: cardID(300), passID: activeRetry),
            into: &session
        )
        try receive(
            pass: activeRetry,
            master: 302,
            sequence: 2,
            into: &session
        )
        try receive(
            pass: activeRetry,
            master: 303,
            sequence: 3,
            into: &session
        )

        let encoded = try JSONEncoder().encode(session)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )

        var reversed = false
        let reversedObject = reverseFirstArray(
            named: "staged",
            in: object,
            didMutate: &reversed
        )
        #expect(reversed)
        let reversedData = try JSONSerialization.data(
            withJSONObject: reversedObject
        )
        #expect(throws: BatchSessionError.self) {
            try JSONDecoder().decode(
                BatchSession.self,
                from: reversedData
            )
        }

        var madeGap = false
        let gappedObject = replaceFirstCaptureSequence(
            inArrayNamed: "staged",
            in: object,
            with: 1,
            didMutate: &madeGap
        )
        #expect(madeGap)
        let gappedData = try JSONSerialization.data(
            withJSONObject: gappedObject
        )
        #expect(throws: BatchSessionError.self) {
            try JSONDecoder().decode(BatchSession.self, from: gappedData)
        }
    }

    @Test("Decoding rejects a non-latest append tail")
    func rejectsCorruptedAppendTail() throws {
        var session = try makeSession()
        try appendCompleteCard(
            card: 310,
            masters: (310, 311),
            pass: 310,
            startingSequence: 0,
            into: &session
        )
        try reduce(
            .deleteCard(cardID: cardID(310)),
            into: &session
        )

        let append = scanPassID(311)
        try reduce(.beginAppend(passID: append), into: &session)
        try receive(
            pass: append,
            master: 312,
            sequence: 2,
            newCard: 311,
            into: &session
        )

        let encoded = try JSONEncoder().encode(session)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        var changed = false
        let corruptedObject = replaceFirstNumber(
            named: "captureSequence",
            in: object,
            with: 0,
            didMutate: &changed
        )
        #expect(changed)
        let corrupted = try JSONSerialization.data(
            withJSONObject: corruptedObject
        )

        #expect(throws: BatchSessionError.self) {
            try JSONDecoder().decode(BatchSession.self, from: corrupted)
        }
    }

    @Test("Decoding rejects a persisted front/back capture swap")
    func rejectsCorruptedCompleteCardSides() throws {
        var session = try makeSession()
        try appendCompleteCard(
            card: 320,
            masters: (320, 321),
            pass: 320,
            startingSequence: 0,
            into: &session
        )

        let encoded = try JSONEncoder().encode(session)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        var swapped = false
        let corruptedObject = swapFirstFrontAndBack(
            in: object,
            didMutate: &swapped
        )
        #expect(swapped)
        let corrupted = try JSONSerialization.data(
            withJSONObject: corruptedObject
        )

        #expect(throws: BatchSessionError.self) {
            try JSONDecoder().decode(BatchSession.self, from: corrupted)
        }
    }

    private func makeSession(
        firstSheetNumber: UInt64 = 1,
        deliveryOrder: DuplexDeliveryOrder = .frontFirst
    ) throws -> BatchSession {
        BatchSession(
            id: batchID(1),
            jobID: jobID(1),
            batchName: try BatchName("aug01-sale"),
            firstSheetNumber: firstSheetNumber,
            deliveryOrder: deliveryOrder
        )
    }

    @Test("A pair whose sides measure different item sizes blocks completion")
    func mismatchedPairMediaSizeBlocksCompletion() throws {
        var session = try makeSession(firstSheetNumber: 60)
        try appendCompleteCard(
            card: 60,
            masters: (60, 61),
            pass: 60,
            startingSequence: 0,
            into: &session
        )

        // The defect this guards: rear-side streaks stretched a real back's
        // detected bounds 679 px past its own front while both sides still
        // read sufficient on their own terms.
        try reduce(
            .marginAssessed(
                masterID: masterID(60),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_819, height: 2_415)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(61),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_822, height: 3_094)
                )
            ),
            into: &session
        )

        #expect(!session.canCompleteBatch)
        #expect(
            session.completionBlockers == [
                .mismatchedPairMediaSize(
                    cardID: session.cards[0].id,
                    provisionalSheetNumber: 60,
                    front: MediaPixelSize(width: 1_819, height: 2_415),
                    back: MediaPixelSize(width: 1_822, height: 3_094)
                )
            ]
        )

        let unchanged = session
        #expect(
            throws: BatchSessionError.completionBlocked(
                unchanged.completionBlockers
            )
        ) {
            try reduce(
                .requestCompletion(attemptID: releaseAttemptID(60)),
                into: &session
            )
        }
        #expect(session == unchanged)
    }

    @Test("A pair between the two thresholds warns instead of blocking")
    func pairSizeWarningDoesNotBlockCompletion() throws {
        var session = try makeSession(firstSheetNumber: 64)
        try appendCompleteCard(
            card: 64,
            masters: (64, 65),
            pass: 64,
            startingSequence: 0,
            into: &session
        )

        // Card 000064 of the operator's `carlsoboxone` batch, to the pixel:
        // the back reads 95 px taller because a wide faint artefact above the
        // media survives the permissive threshold. The image still contains
        // the whole card, and TICKET-033 releases it with the row saying so.
        try reduce(
            .marginAssessed(
                masterID: masterID(64),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_814, height: 2_407)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(65),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_830, height: 2_502)
                )
            ),
            into: &session
        )

        #expect(session.completionBlockers.isEmpty)
        #expect(session.canCompleteBatch)
        #expect(
            session.pairSizeWarnings == [
                PairSizeWarning(
                    cardID: session.cards[0].id,
                    provisionalSheetNumber: 64,
                    front: MediaPixelSize(width: 1_814, height: 2_407),
                    back: MediaPixelSize(width: 1_830, height: 2_502)
                )
            ]
        )
        #expect(session.pairSizeWarnings[0].disagreementPixels == 95)

        // Releasing it is allowed, and the batch says afterwards that it did.
        let attempt = releaseAttemptID(64)
        _ = try reduce(.requestCompletion(attemptID: attempt), into: &session)
        _ = try reduce(
            .completionSucceeded(
                attemptID: attempt,
                destinationDescription: "Pokemon Scans"
            ),
            into: &session
        )
        guard case let .completed(summary) = session.phase else {
            Issue.record("expected a completed batch")
            return
        }
        #expect(summary.releasedWithSizeWarnings == [64])
    }

    @Test("A manual crop bypasses the automatic pair-size check")
    func manualCropBypassesPairSizeCheck() throws {
        var session = try makeBlockingPairSession()
        let cardID = session.cards[0].id
        let originalFrontSize = try #require(
            session.cards[0].assessedPairSizes?.front
        )
        #expect(session.completionBlockers.count == 1)

        let crop = ManualCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try reduce(
            .setManualCrop(cardID: cardID, side: .front, crop: crop),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: try #require(
                    session.cards[0].activeSides?.front?.masterID
                ),
                rotation: .zero,
                result: .sufficient(mediaSize: originalFrontSize)
            ),
            into: &session
        )

        #expect(session.cards[0].hasManualCrop)
        #expect(session.completionBlockers.isEmpty)
        #expect(session.pairSizeWarnings.isEmpty)

        try reduce(
            .setManualCrop(cardID: cardID, side: .front, crop: nil),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: try #require(
                    session.cards[0].activeSides?.front?.masterID
                ),
                rotation: .zero,
                result: .sufficient(mediaSize: originalFrontSize)
            ),
            into: &session
        )

        #expect(!session.cards[0].hasManualCrop)
        #expect(session.completionBlockers.count == 1)
    }

    @Test("The blocking threshold is the wide one, and it is exclusive")
    func pairSizeBlockingThresholdBoundary() throws {
        func session(backHeight: Int) throws -> BatchSession {
            var session = try makeSession(firstSheetNumber: 90)
            try appendCompleteCard(
                card: 90,
                masters: (90, 91),
                pass: 90,
                startingSequence: 0,
                into: &session
            )
            try reduce(
                .marginAssessed(
                    masterID: masterID(90),
                    rotation: .zero,
                    result: .sufficient(
                        mediaSize: MediaPixelSize(width: 1_820, height: 2_420)
                    )
                ),
                into: &session
            )
            try reduce(
                .marginAssessed(
                    masterID: masterID(91),
                    rotation: .zero,
                    result: .sufficient(
                        mediaSize: MediaPixelSize(
                            width: 1_820,
                            height: backHeight
                        )
                    )
                ),
                into: &session
            )
            return session
        }

        let atTheLine = try session(backHeight: 2_420 + 140)
        #expect(atTheLine.completionBlockers.isEmpty)
        #expect(atTheLine.pairSizeWarnings.count == 1)

        let pastIt = try session(backHeight: 2_420 + 141)
        #expect(pastIt.completionBlockers.count == 1)
        // A blocked pair is reported once, as a blocker — never as both.
        #expect(pastIt.pairSizeWarnings.isEmpty)

        let inside = try session(backHeight: 2_420 + 24)
        #expect(inside.completionBlockers.isEmpty)
        #expect(inside.pairSizeWarnings.isEmpty)
    }

    @Test("Pair sizes within tolerance and legacy nil sizes do not block")
    func pairAgreementToleranceAndLegacySizes() throws {
        var session = try makeSession(firstSheetNumber: 70)
        try appendCompleteCard(
            card: 70,
            masters: (70, 71),
            pass: 70,
            startingSequence: 0,
            into: &session
        )
        // Genuine fi-8170 pairs agree within 3 px; a millimetre of drift
        // stays publishable.
        try reduce(
            .marginAssessed(
                masterID: masterID(70),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_819, height: 2_415)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(71),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_821, height: 2_417)
                )
            ),
            into: &session
        )
        #expect(session.canCompleteBatch)

        var legacy = try makeSession(firstSheetNumber: 80)
        try appendCompleteCard(
            card: 80,
            masters: (80, 81),
            pass: 80,
            startingSequence: 0,
            into: &legacy
        )
        // An assessment recorded before sizes existed forgoes the pair check
        // rather than failing it.
        try reduce(
            .marginAssessed(
                masterID: masterID(80),
                rotation: .zero,
                result: .sufficient(mediaSize: nil)
            ),
            into: &legacy
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(81),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 9_999, height: 9_999)
                )
            ),
            into: &legacy
        )
        #expect(legacy.canCompleteBatch)
    }

    @Test("Replace clears a mismatched pair")
    func replaceClearsMismatchedPair() throws {
        var session = try makeSession(firstSheetNumber: 90)
        try appendCompleteCard(
            card: 90,
            masters: (90, 91),
            pass: 90,
            startingSequence: 0,
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(90),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_819, height: 2_415)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(91),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_822, height: 3_094)
                )
            ),
            into: &session
        )
        #expect(!session.canCompleteBatch)

        let target = session.cards[0].id
        let replacePass = scanPassID(91)
        try reduce(
            .beginReplace(cardID: target, passID: replacePass),
            into: &session
        )
        try receive(pass: replacePass, master: 92, sequence: 2, into: &session)
        try receive(pass: replacePass, master: 93, sequence: 3, into: &session)
        try reduce(
            .scanEnded(passID: replacePass, outcome: .completed),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(92),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_820, height: 2_416)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(93),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_821, height: 2_417)
                )
            ),
            into: &session
        )
        #expect(session.canCompleteBatch)
    }

    // MARK: - Accepting a blocking disagreement (TICKET-037)

    @Test("An accepted pair completes the batch and stays on the record")
    func acceptedPairMismatchReleasesCompletion() throws {
        var session = try makeBlockingPairSession()
        let card = session.cards[0].id
        #expect(!session.canCompleteBatch)

        try reduce(.acceptPairSizeMismatch(cardID: card), into: &session)

        #expect(session.canCompleteBatch)
        #expect(session.completionBlockers.isEmpty)
        // The refusal is gone; the check is not. A pair that vanished from the
        // warnings on acceptance would be the one gate in the app that goes
        // quiet when it fires.
        #expect(session.pairSizeWarnings.count == 1)
        #expect(session.pairSizeWarnings[0].isOperatorAccepted)
        #expect(session.acceptedPairSizeMismatches.count == 1)
        #expect(session.pairSizeWarnings[0].disagreementPixels == 679)
    }

    @Test("Accepting a pair the reducer is not refusing is rejected")
    func acceptingAnUnblockedPairIsRejected() throws {
        var session = try makeSession(firstSheetNumber: 70)
        try appendCompleteCard(
            card: 70,
            masters: (70, 71),
            pass: 70,
            startingSequence: 0,
            into: &session
        )
        for master in [70, 71] {
            try reduce(
                .marginAssessed(
                    masterID: masterID(master),
                    rotation: .zero,
                    result: .sufficient(
                        mediaSize: MediaPixelSize(width: 1_820, height: 2_408)
                    )
                ),
                into: &session
            )
        }
        let card = session.cards[0].id
        #expect(session.canCompleteBatch)

        let unchanged = session
        #expect(throws: BatchSessionError.cardHasNoBlockingPairMismatch(card)) {
            try reduce(.acceptPairSizeMismatch(cardID: card), into: &session)
        }
        #expect(session == unchanged)
    }

    @Test("Withdrawing an acceptance brings the refusal back")
    func withdrawnAcceptanceRestoresTheBlocker() throws {
        var session = try makeBlockingPairSession()
        let card = session.cards[0].id
        try reduce(.acceptPairSizeMismatch(cardID: card), into: &session)
        #expect(session.canCompleteBatch)

        try reduce(
            .withdrawPairSizeMismatchAcceptance(cardID: card),
            into: &session
        )

        #expect(!session.canCompleteBatch)
        #expect(session.completionBlockers.count == 1)
        #expect(session.acceptedPairSizeMismatches.isEmpty)

        let unchanged = session
        #expect(throws: BatchSessionError.pairMismatchNotAccepted(card)) {
            try reduce(
                .withdrawPairSizeMismatchAcceptance(cardID: card),
                into: &session
            )
        }
        #expect(session == unchanged)
    }

    /// The reason the acceptance stores two footprints instead of a flag.
    ///
    /// The operator accepts a 679 px disagreement, then replaces the card and
    /// the fresh pass lands a *different* wide disagreement. A boolean would
    /// carry the old consent onto numbers nobody has been shown and publish it
    /// silently, which is the exact failure the override exists to avoid being.
    @Test("A replacement that re-measures the pair invalidates the acceptance")
    func replacementInvalidatesAcceptance() throws {
        var session = try makeBlockingPairSession()
        let card = session.cards[0].id
        try reduce(.acceptPairSizeMismatch(cardID: card), into: &session)
        #expect(session.canCompleteBatch)

        let replacePass = scanPassID(81)
        try reduce(
            .beginReplace(cardID: card, passID: replacePass),
            into: &session
        )
        try receive(pass: replacePass, master: 82, sequence: 2, into: &session)
        try receive(pass: replacePass, master: 83, sequence: 3, into: &session)
        try reduce(
            .scanEnded(passID: replacePass, outcome: .completed),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(82),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_602, height: 2_188)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(83),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_820, height: 2_408)
                )
            ),
            into: &session
        )

        // Still refusing, on the new numbers. The stale acceptance no longer
        // describes the card, so it grants nothing.
        #expect(!session.canCompleteBatch)
        #expect(
            session.completionBlockers == [
                .mismatchedPairMediaSize(
                    cardID: card,
                    provisionalSheetNumber: 60,
                    front: MediaPixelSize(width: 1_602, height: 2_188),
                    back: MediaPixelSize(width: 1_820, height: 2_408)
                )
            ]
        )
        #expect(session.acceptedPairSizeMismatches.isEmpty)

        // And it can be accepted again, against what it measures now.
        try reduce(.acceptPairSizeMismatch(cardID: card), into: &session)
        #expect(session.canCompleteBatch)
        #expect(
            session.cards[0].acceptedPairSizeMismatch
                == AcceptedPairSizeMismatch(
                    front: MediaPixelSize(width: 1_602, height: 2_188),
                    back: MediaPixelSize(width: 1_820, height: 2_408)
                )
        )
    }

    @Test("The completion summary records which cards were overruled")
    func completionSummaryRecordsAcceptedMismatches() throws {
        var session = try makeBlockingPairSession()
        let card = session.cards[0].id
        try reduce(.acceptPairSizeMismatch(cardID: card), into: &session)

        let attempt = releaseAttemptID(60)
        try reduce(.requestCompletion(attemptID: attempt), into: &session)
        try reduce(
            .completionSucceeded(
                attemptID: attempt,
                destinationDescription: "Pokemon Scans"
            ),
            into: &session
        )

        guard case let .completed(summary) = session.phase else {
            Issue.record("The batch did not complete.")
            return
        }
        #expect(summary.releasedWithSizeWarnings == [60])
        #expect(summary.releasedWithAcceptedMismatches == [60])
    }

    @Test("An acceptance survives a session round trip")
    func acceptanceSurvivesRoundTrip() throws {
        var session = try makeBlockingPairSession()
        try reduce(
            .acceptPairSizeMismatch(cardID: session.cards[0].id),
            into: &session
        )
        try expectRoundTrip(
            session,
            encoder: JSONEncoder(),
            decoder: JSONDecoder()
        )
    }

    /// A batch armed before the override existed must still open.
    ///
    /// The operator had a live 186-card batch on disk while this was built, so
    /// this is not a hypothetical: the acceptance is optional precisely so that
    /// a record written without the key decodes as "nothing accepted".
    @Test("A session record written before the override still decodes")
    func recordWithoutAcceptanceKeyDecodes() throws {
        let session = try makeBlockingPairSession()
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(session)
        ) as? [String: Any]
        var cards = try #require(object?["cards"] as? [[String: Any]])
        for index in cards.indices {
            cards[index].removeValue(forKey: "acceptedPairSizeMismatch")
        }
        object?["cards"] = cards
        let stripped = try JSONSerialization.data(
            withJSONObject: try #require(object)
        )

        let decoded = try JSONDecoder().decode(
            BatchSession.self,
            from: stripped
        )
        #expect(decoded.cards[0].acceptedPairSizeMismatch == nil)
        #expect(!decoded.canCompleteBatch)
        #expect(decoded.completionBlockers.count == 1)
    }

    /// One card whose two sides disagree by 679 px — the real streak defect,
    /// well past `pairBlockingDisagreementPixels`.
    private func makeBlockingPairSession() throws -> BatchSession {
        var session = try makeSession(firstSheetNumber: 60)
        try appendCompleteCard(
            card: 60,
            masters: (60, 61),
            pass: 60,
            startingSequence: 0,
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(60),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_819, height: 2_415)
                )
            ),
            into: &session
        )
        try reduce(
            .marginAssessed(
                masterID: masterID(61),
                rotation: .zero,
                result: .sufficient(
                    mediaSize: MediaPixelSize(width: 1_822, height: 3_094)
                )
            ),
            into: &session
        )
        return session
    }

    private func appendCompleteCard(
        card: Int,
        masters: (Int, Int),
        pass: Int,
        startingSequence: UInt64,
        into session: inout BatchSession
    ) throws {
        let passID = scanPassID(pass)
        try reduce(.beginAppend(passID: passID), into: &session)
        try receive(
            pass: passID,
            master: masters.0,
            sequence: startingSequence,
            newCard: card,
            into: &session
        )
        try receive(
            pass: passID,
            master: masters.1,
            sequence: startingSequence + 1,
            into: &session
        )
        try reduce(
            .scanEnded(passID: passID, outcome: .completed),
            into: &session
        )
    }

    @discardableResult
    private func receive(
        pass: ScanPassID,
        master: Int,
        sequence: UInt64,
        newCard: Int? = nil,
        into session: inout BatchSession
    ) throws -> [BatchEffect] {
        try reduce(
            .pageReceived(
                passID: pass,
                masterID: masterID(master),
                captureSequence: sequence,
                newCardID: newCard.map(cardID)
            ),
            into: &session
        )
    }

    @discardableResult
    private func reduce(
        _ action: BatchAction,
        into session: inout BatchSession
    ) throws -> [BatchEffect] {
        try BatchSessionReducer.reduce(action, into: &session)
    }

    private func expectRoundTrip(
        _ session: BatchSession,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) throws {
        let encoded = try encoder.encode(session)
        let decoded = try decoder.decode(BatchSession.self, from: encoded)
        #expect(decoded == session)
    }

    private func reverseFirstArray(
        named targetName: String,
        in value: Any,
        didMutate: inout Bool
    ) -> Any {
        guard !didMutate else {
            return value
        }
        if var dictionary = value as? [String: Any] {
            if let array = dictionary[targetName] as? [Any],
               array.count >= 2
            {
                dictionary[targetName] = Array(array.reversed())
                didMutate = true
                return dictionary
            }
            for key in dictionary.keys.sorted() {
                dictionary[key] = reverseFirstArray(
                    named: targetName,
                    in: dictionary[key]!,
                    didMutate: &didMutate
                )
            }
            return dictionary
        }
        if var array = value as? [Any] {
            for index in array.indices {
                array[index] = reverseFirstArray(
                    named: targetName,
                    in: array[index],
                    didMutate: &didMutate
                )
            }
            return array
        }
        return value
    }

    private func replaceFirstCaptureSequence(
        inArrayNamed targetName: String,
        in value: Any,
        with replacement: Int,
        didMutate: inout Bool
    ) -> Any {
        guard !didMutate else {
            return value
        }
        if var dictionary = value as? [String: Any] {
            if var array = dictionary[targetName] as? [Any],
               !array.isEmpty,
               var first = array[0] as? [String: Any],
               first["captureSequence"] != nil
            {
                first["captureSequence"] = replacement
                array[0] = first
                dictionary[targetName] = array
                didMutate = true
                return dictionary
            }
            for key in dictionary.keys.sorted() {
                dictionary[key] = replaceFirstCaptureSequence(
                    inArrayNamed: targetName,
                    in: dictionary[key]!,
                    with: replacement,
                    didMutate: &didMutate
                )
            }
            return dictionary
        }
        if var array = value as? [Any] {
            for index in array.indices {
                array[index] = replaceFirstCaptureSequence(
                    inArrayNamed: targetName,
                    in: array[index],
                    with: replacement,
                    didMutate: &didMutate
                )
            }
            return array
        }
        return value
    }

    private func replaceFirstNumber(
        named targetName: String,
        in value: Any,
        with replacement: Int,
        didMutate: inout Bool
    ) -> Any {
        guard !didMutate else {
            return value
        }
        if var dictionary = value as? [String: Any] {
            if dictionary[targetName] != nil {
                dictionary[targetName] = replacement
                didMutate = true
                return dictionary
            }
            for key in dictionary.keys.sorted() {
                dictionary[key] = replaceFirstNumber(
                    named: targetName,
                    in: dictionary[key]!,
                    with: replacement,
                    didMutate: &didMutate
                )
            }
            return dictionary
        }
        if var array = value as? [Any] {
            for index in array.indices {
                array[index] = replaceFirstNumber(
                    named: targetName,
                    in: array[index],
                    with: replacement,
                    didMutate: &didMutate
                )
            }
            return array
        }
        return value
    }

    private func swapFirstFrontAndBack(
        in value: Any,
        didMutate: inout Bool
    ) -> Any {
        guard !didMutate else {
            return value
        }
        if var dictionary = value as? [String: Any] {
            if let front = dictionary["front"],
               let back = dictionary["back"]
            {
                dictionary["front"] = back
                dictionary["back"] = front
                didMutate = true
                return dictionary
            }
            for key in dictionary.keys.sorted() {
                dictionary[key] = swapFirstFrontAndBack(
                    in: dictionary[key]!,
                    didMutate: &didMutate
                )
            }
            return dictionary
        }
        if var array = value as? [Any] {
            for index in array.indices {
                array[index] = swapFirstFrontAndBack(
                    in: array[index],
                    didMutate: &didMutate
                )
            }
            return array
        }
        return value
    }

    @Test("Capture rotation seeds every side and travels with its assessment")
    func captureRotationSeedsCapturedSides() throws {
        // The fi-8170 hands back both duplex faces upside down. The turn is a
        // property of the scanner, so it is applied on capture rather than left
        // for the operator to repeat on every side of every card.
        var session = BatchSession(
            id: batchID(1),
            jobID: jobID(1),
            batchName: try BatchName("aug01-sale"),
            firstSheetNumber: 114,
            deliveryOrder: .frontFirst,
            captureRotation: .clockwise180
        )

        let passID = scanPassID(1)
        try reduce(.beginAppend(passID: passID), into: &session)
        let effects = try reduce(
            .pageReceived(
                passID: passID,
                masterID: masterID(1),
                captureSequence: 0,
                newCardID: cardID(1)
            ),
            into: &session
        )

        let sides = try #require(session.cards[0].activeSides)
        #expect(sides.front?.rotation == .clockwise180)

        // The assessment must be requested at the rotation the side actually
        // has. Asking at `.zero` gets the answer refused as stale, which leaves
        // the side pending forever and blocks completion with "still checking".
        #expect(
            effects == [
                .assessMargin(
                    masterID: masterID(1),
                    rotation: .clockwise180,
                    manualCrop: nil,
                    requestedMargins: session.requestedMargins
                )
            ]
        )

        try reduce(
            .marginAssessed(
                masterID: masterID(1),
                rotation: .clockwise180,
                result: .sufficient(mediaSize: nil)
            ),
            into: &session
        )
        #expect(
            session.cards[0].activeSides?.front?.marginAssessment == .sufficient(mediaSize: nil)
        )
    }

    @Test("A batch saved before capture rotation existed still decodes")
    func captureRotationDefaultsForOlderBatches() throws {
        let session = BatchSession(
            id: batchID(1),
            jobID: jobID(1),
            batchName: try BatchName("aug01-sale"),
            firstSheetNumber: 114,
            deliveryOrder: .frontFirst
        )
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(session)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "captureRotation")

        let decoded = try JSONDecoder().decode(
            BatchSession.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        // An unfinished batch from an older build must still come back rather
        // than becoming an unreadable record the operator cannot recover.
        #expect(decoded.captureRotation == .zero)
        #expect(decoded == session)
    }

    private func batchID(_ value: Int) -> BatchID {
        BatchID(rawValue: uuid(value))
    }

    private func jobID(_ value: Int) -> JobID {
        JobID(rawValue: uuid(1_000 + value))
    }

    private func cardID(_ value: Int) -> CardID {
        CardID(rawValue: uuid(2_000 + value))
    }

    private func masterID(_ value: Int) -> MasterID {
        MasterID(rawValue: uuid(3_000 + value))
    }

    private func scanPassID(_ value: Int) -> ScanPassID {
        ScanPassID(rawValue: uuid(4_000 + value))
    }

    private func releaseAttemptID(_ value: Int) -> ReleaseAttemptID {
        ReleaseAttemptID(rawValue: uuid(5_000 + value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012x",
                value
            )
        )!
    }
}
