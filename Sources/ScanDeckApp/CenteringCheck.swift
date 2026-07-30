import Foundation

struct CenteringCheckRequest: Equatable, Sendable {
    let publishedFolderURL: URL
    let imageCount: Int

    /// Passes `--swap-sides` to the tool.
    ///
    /// Set for a folder whose artwork is in `_B` — the operator's batches from
    /// before `deliveryOrder: .backFirst`. Without it those fronts are scored
    /// against back tolerances, which are 5× looser, and a ruinous card reports
    /// as flawless. The flag has existed in the tool since TICKET-034 and had no
    /// way to be set until batches published earlier became reachable.
    let swapSides: Bool

    init(
        publishedFolderURL: URL,
        imageCount: Int,
        swapSides: Bool = false
    ) {
        self.publishedFolderURL = publishedFolderURL
        self.imageCount = imageCount
        self.swapSides = swapSides
    }
}

struct CenteringCheckConsent: Equatable, Sendable {
    let imageCount: Int

    var title: String {
        "Send \(imageCount) images to centeringcheck.com?"
    }

    var actionTitle: String {
        "Send \(imageCount) Images"
    }

    var message: String {
        "This uploads the published fronts and backs for centering analysis "
            + "and saves only the returned border overlays under this batch’s "
            + "centering folder. Consent applies only to this run and will "
            + "not be remembered."
    }
}

struct CenteringCheckProgress: Equatable, Sendable {
    let completedImages: Int
    let imageCount: Int
    let uploadedImages: Int
    let cachedImages: Int
    let failedImages: Int

    static func starting(imageCount: Int) -> CenteringCheckProgress {
        CenteringCheckProgress(
            completedImages: 0,
            imageCount: imageCount,
            uploadedImages: 0,
            cachedImages: 0,
            failedImages: 0
        )
    }

    var operatorDescription: String {
        if completedImages >= imageCount, failedImages == 0 {
            return "Organizing returned overlays…"
        }
        var detail = "\(cachedImages) cached, \(uploadedImages) uploaded"
        if failedImages > 0 {
            detail += ", \(failedImages) failed"
        }
        return "Checking \(completedImages) of \(imageCount)… \(detail)"
    }
}

struct CenteringCheckReceipt: Equatable, Sendable {
    let outputFolderURL: URL
    let imageCount: Int
    let uploadedImages: Int
    let cachedImages: Int
}

enum CenteringCheckStatus: Equatable, Sendable {
    case running(CenteringCheckProgress)
    case completed(CenteringCheckReceipt)
    case failed(message: String)
}

struct CenteringCheckFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum CenteringToolEvent: Equatable, Sendable {
    case progress(CenteringCheckProgress)
    case completed(CenteringCheckReceipt)
    case failed(message: String)
}

/// Turns the tool's newline-delimited JSON into typed progress.
///
/// A pipe can split a JSON line anywhere, including in the middle of a UTF-8
/// scalar. Buffering bytes until the newline keeps the transport detail out of
/// the presentation model and makes malformed tool output a failure instead of
/// a frozen count.
struct CenteringToolOutputParser {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [CenteringToolEvent] {
        buffer.append(data)
        var events: [CenteringToolEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try parse(line) {
                events.append(event)
            }
        }
        return events
    }

    mutating func finish() throws -> [CenteringToolEvent] {
        guard !buffer.isEmpty else {
            return []
        }
        let line = buffer
        buffer.removeAll(keepingCapacity: false)
        return try parse(line).map { [$0] } ?? []
    }

    private func parse(_ data: Data) throws -> CenteringToolEvent? {
        guard !data.isEmpty else {
            return nil
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CenteringCheckFailure(
                message: "The centering tool returned unreadable progress."
            )
        }
        guard let object = value as? [String: Any],
              let event = object["event"] as? String
        else {
            throw CenteringCheckFailure(
                message: "The centering tool returned incomplete progress."
            )
        }
        switch event {
        case "progress":
            return .progress(
                CenteringCheckProgress(
                    completedImages: try integer(
                        "completedImages",
                        in: object
                    ),
                    imageCount: try integer("imageCount", in: object),
                    uploadedImages: try integer("uploadedImages", in: object),
                    cachedImages: try integer("cachedImages", in: object),
                    failedImages: try integer("failedImages", in: object)
                )
            )
        case "complete":
            guard let outputFolder = object["outputFolder"] as? String else {
                throw CenteringCheckFailure(
                    message: "The centering tool did not name its output folder."
                )
            }
            return .completed(
                CenteringCheckReceipt(
                    outputFolderURL: URL(
                        filePath: outputFolder,
                        directoryHint: .isDirectory
                    ),
                    imageCount: try integer("imageCount", in: object),
                    uploadedImages: try integer("uploadedImages", in: object),
                    cachedImages: try integer("cachedImages", in: object)
                )
            )
        case "error":
            guard let message = object["message"] as? String,
                  !message.isEmpty
            else {
                throw CenteringCheckFailure(
                    message: "The centering tool failed without an explanation."
                )
            }
            return .failed(message: message)
        default:
            return nil
        }
    }

    private func integer(
        _ key: String,
        in object: [String: Any]
    ) throws -> Int {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw CenteringCheckFailure(
                message: "The centering tool returned an invalid \(key) count."
            )
        }
        let rawValue = number.doubleValue
        guard rawValue.isFinite,
              rawValue.rounded() == rawValue,
              rawValue >= 0,
              rawValue <= Double(Int.max)
        else {
            throw CenteringCheckFailure(
                message: "The centering tool returned an invalid \(key) count."
            )
        }
        return Int(rawValue)
    }
}
