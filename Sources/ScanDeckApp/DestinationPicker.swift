import AppKit

/// Seam that keeps `NSOpenPanel` out of the presentation model.
@MainActor
protocol DestinationPicking: AnyObject {
    func pickDestination(startingAt url: URL?) -> URL?
}

@MainActor
final class AppKitDestinationPicker: DestinationPicking {
    func pickDestination(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Destination"
        panel.message = "Choose the folder where ScanDeck will publish completed batches."
        panel.directoryURL = url

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }
}

@MainActor
enum FinderPresenter {
    static func show(_ url: URL?) {
        guard let url else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
