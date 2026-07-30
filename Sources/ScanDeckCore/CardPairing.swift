import Foundation

public enum OutputSide: String, Codable, Hashable, Sendable {
    case front = "F"
    case back = "B"
}

public enum DuplexDeliveryOrder: String, Codable, Hashable, Sendable {
    case frontFirst
    case backFirst
}

public struct CapturedPage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let arrivalIndex: Int

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        arrivalIndex: Int
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.arrivalIndex = arrivalIndex
    }
}

public struct CardPair: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let provisionalSheetNumber: UInt64
    public let front: CapturedPage
    public let back: CapturedPage

    public init(
        id: UUID = UUID(),
        provisionalSheetNumber: UInt64,
        front: CapturedPage,
        back: CapturedPage
    ) {
        self.id = id
        self.provisionalSheetNumber = provisionalSheetNumber
        self.front = front
        self.back = back
    }
}

public struct IncompleteCard: Equatable, Sendable {
    public let page: CapturedPage
    public let expectedSide: OutputSide
    public let provisionalSheetNumber: UInt64
}

public struct CardPairingAccumulator: Sendable {
    public let deliveryOrder: DuplexDeliveryOrder
    public private(set) var nextSheetNumber: UInt64
    public private(set) var nextArrivalIndex = 0

    private var pendingPage: CapturedPage?
    private var unresolvedIncompleteCard: IncompleteCard?
    private var isRetryingIncompleteCard = false
    private var retryPageCount = 0

    public init(
        deliveryOrder: DuplexDeliveryOrder,
        firstSheetNumber: UInt64
    ) {
        self.deliveryOrder = deliveryOrder
        nextSheetNumber = firstSheetNumber
    }

    public var incompleteCard: IncompleteCard? {
        if let unresolvedIncompleteCard {
            return unresolvedIncompleteCard
        }

        guard let pendingPage else {
            return nil
        }

        return makeIncompleteCard(from: pendingPage)
    }

    public mutating func append(sourceURL: URL) throws -> CardPair? {
        guard nextSheetNumber < UInt64.max else {
            throw PairingError.counterExhausted
        }
        if let unresolvedIncompleteCard, !isRetryingIncompleteCard {
            throw PairingError.incompleteCardMustBeResolved(
                provisionalSheetNumber:
                    unresolvedIncompleteCard.provisionalSheetNumber
            )
        }
        guard !isRetryingIncompleteCard || retryPageCount < 2 else {
            throw PairingError.retryPassAlreadyComplete
        }

        let page = CapturedPage(
            sourceURL: sourceURL,
            arrivalIndex: nextArrivalIndex
        )
        nextArrivalIndex += 1
        if isRetryingIncompleteCard {
            retryPageCount += 1
        }

        guard let firstPage = pendingPage else {
            pendingPage = page
            return nil
        }

        pendingPage = nil

        let pair: CardPair
        switch deliveryOrder {
        case .frontFirst:
            pair = CardPair(
                provisionalSheetNumber: nextSheetNumber,
                front: firstPage,
                back: page
            )
        case .backFirst:
            pair = CardPair(
                provisionalSheetNumber: nextSheetNumber,
                front: page,
                back: firstPage
            )
        }

        nextSheetNumber += 1
        if isRetryingIncompleteCard {
            unresolvedIncompleteCard = nil
        }
        return pair
    }

    /// Arms an isolated two-page retry pass for the unresolved card. The old
    /// capture remains reserved until two replacement pages arrive.
    public mutating func beginRetry() throws {
        guard pendingPage == nil else {
            throw PairingError.currentPassMustFinish
        }
        guard !isRetryingIncompleteCard else {
            throw PairingError.retryAlreadyInProgress
        }
        guard let unresolvedIncompleteCard else {
            throw PairingError.noIncompleteCard
        }
        guard unresolvedIncompleteCard.provisionalSheetNumber
            == nextSheetNumber
        else {
            throw PairingError.inconsistentReservation
        }

        isRetryingIncompleteCard = true
        retryPageCount = 0
    }

    /// Ends one `requestScan` feeder pass and resets page parity before the
    /// next pass. An odd tail is returned as an incomplete card; it is never
    /// paired with the first page from a later Continue Scanning or Retry pass.
    @discardableResult
    public mutating func finishPass() -> IncompleteCard? {
        let newIncomplete = pendingPage.map(makeIncompleteCard)
        pendingPage = nil

        if isRetryingIncompleteCard {
            isRetryingIncompleteCard = false
            retryPageCount = 0

            // A failed retry never destroys the previous capture. The caller
            // may clean up the new odd retry page returned here.
            return newIncomplete ?? unresolvedIncompleteCard
        }

        unresolvedIncompleteCard = newIncomplete
        return newIncomplete
    }

    /// Deletes the numbered incomplete card and advances past its reservation,
    /// intentionally leaving a stable counter gap.
    @discardableResult
    public mutating func deleteIncompleteCardLeavingGap() throws -> IncompleteCard? {
        guard !isRetryingIncompleteCard else {
            throw PairingError.retryAlreadyInProgress
        }

        let incomplete = unresolvedIncompleteCard
            ?? pendingPage.map(makeIncompleteCard)
        guard incomplete != nil else {
            return nil
        }
        guard nextSheetNumber < UInt64.max else {
            throw PairingError.counterExhausted
        }

        pendingPage = nil
        unresolvedIncompleteCard = nil
        nextSheetNumber += 1
        return incomplete
    }

    private func makeIncompleteCard(
        from page: CapturedPage
    ) -> IncompleteCard {
        let expectedSide: OutputSide = switch deliveryOrder {
        case .frontFirst:
            .back
        case .backFirst:
            .front
        }

        return IncompleteCard(
            page: page,
            expectedSide: expectedSide,
            provisionalSheetNumber: nextSheetNumber
        )
    }

    public enum PairingError: Error, Equatable, Sendable {
        case incompleteCardMustBeResolved(provisionalSheetNumber: UInt64)
        case currentPassMustFinish
        case retryAlreadyInProgress
        case retryPassAlreadyComplete
        case noIncompleteCard
        case inconsistentReservation
        case counterExhausted
    }
}
