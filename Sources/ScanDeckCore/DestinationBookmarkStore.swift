import Foundation

/// Persistence seam for the destination root.
///
/// A protocol so tests and previews can substitute in-memory storage instead of
/// writing to the real defaults database.
public protocol DestinationBookmarkStorage: AnyObject {
    var destinationBookmark: Data? { get set }
}

/// Persists the destination outside the app model so the same bookmark can be
/// resolved at every launch.
public final class UserDefaultsDestinationBookmarkStorage: DestinationBookmarkStorage {
    public static let defaultKey = "me.eliseorobles.ScanDeck.destinationBookmark"

    private let userDefaults: UserDefaults
    private let key: String

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = UserDefaultsDestinationBookmarkStorage.defaultKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    /// `UserDefaults` is documented as thread-safe, so this needs no additional
    /// locking of its own.
    public var destinationBookmark: Data? {
        get {
            userDefaults.data(forKey: key)
        }
        set {
            if let newValue {
                userDefaults.set(newValue, forKey: key)
            } else {
                userDefaults.removeObject(forKey: key)
            }
        }
    }
}

/// In-memory storage for tests and SwiftUI previews.
public final class InMemoryDestinationBookmarkStorage: DestinationBookmarkStorage {
    public var destinationBookmark: Data?

    public init(destinationBookmark: Data? = nil) {
        self.destinationBookmark = destinationBookmark
    }
}

/// Owns bookmark creation and resolution for both the current non-sandboxed app
/// and a possible future sandboxed distribution.
public struct DestinationBookmarkStore {
    private let storage: any DestinationBookmarkStorage

    public init(
        storage: any DestinationBookmarkStorage =
            UserDefaultsDestinationBookmarkStorage()
    ) {
        self.storage = storage
    }

    /// Makes a bookmark without storing it.
    ///
    /// An unfinished batch persists its *own* destination (TICKET-005), because
    /// the remembered one is wherever the operator last pointed the app — which
    /// may be somewhere else entirely by the time a recovered batch is
    /// completed.
    public static func bookmark(for url: URL) throws -> Data {
        try withAccess(url) { accessibleURL in
            do {
                return try accessibleURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                // V1 deliberately has no App Sandbox entitlement, where creating
                // a security-scoped bookmark can fail. A plain bookmark retains
                // the destination and can still be upgraded after sandboxing.
                return try accessibleURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        }
    }

    /// Resolves a bookmark to a folder that exists right now.
    ///
    /// Returns `nil` rather than a plausible-looking URL when the folder is
    /// gone: a destination that cannot be reached must surface as a decision for
    /// the operator, never as a publish that fails halfway.
    public static func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        let resolutionOptions: [URL.BookmarkResolutionOptions] = [
            .withSecurityScope,
            [],
        ]

        for options in resolutionOptions {
            var isStale = false

            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: options,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard directoryExists(at: url) else {
                    return nil
                }
                return (url, isStale)
            } catch {
                continue
            }
        }

        return nil
    }

    public func save(_ url: URL) throws {
        storage.destinationBookmark = try Self.bookmark(for: url)
    }

    public func resolveDestination() -> URL? {
        guard let bookmark = storage.destinationBookmark,
              let resolved = Self.resolve(bookmark)
        else {
            return nil
        }
        if resolved.isStale {
            try? save(resolved.url)
        }
        return resolved.url
    }

    public func clear() {
        storage.destinationBookmark = nil
    }

    /// Balances security-scope access only when Foundation actually starts it.
    /// Returning `false` is expected for the non-sandboxed v1 app and does not
    /// prevent the operation from using the URL.
    public static func withAccess<Result>(
        _ url: URL,
        perform operation: (URL) throws -> Result
    ) rethrows -> Result {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(url)
    }

    public func withAccess<Result>(
        _ url: URL,
        perform operation: (URL) throws -> Result
    ) rethrows -> Result {
        try Self.withAccess(url, perform: operation)
    }

    public static func displayName(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let leaf = standardizedURL.lastPathComponent
        let parent = standardizedURL
            .deletingLastPathComponent()
            .lastPathComponent

        guard !parent.isEmpty, parent != "/", parent != leaf else {
            return leaf
        }
        return "\(parent) / \(leaf)"
    }

    private static func directoryExists(at url: URL) -> Bool {
        withAccess(url) { accessibleURL in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: accessibleURL.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    }
}
