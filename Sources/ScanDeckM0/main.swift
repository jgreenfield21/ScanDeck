import Darwin
import Foundation
import ScanDeckScanner

private struct CommandLineOptions {
    var operation: ScannerProbeOperation
    var deviceNameContains: String?
    var outputDirectory: URL?
    var timeout: TimeInterval
    var scanWindow: ScanWindowRequest?

    init(arguments: [String]) throws {
        var iterator = arguments.dropFirst().makeIterator()
        var requestedOperation: ScannerProbeOperation?
        var explicitTimeout: TimeInterval?

        while let argument = iterator.next() {
            switch argument {
            case "--list":
                try Self.select(
                    .list,
                    for: argument,
                    current: &requestedOperation
                )
            case "--inspect":
                try Self.select(
                    .inspect,
                    for: argument,
                    current: &requestedOperation
                )
            case "--scan":
                try Self.select(
                    .scan,
                    for: argument,
                    current: &requestedOperation
                )
            case "--device":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw ParseError.missingValue("--device")
                }
                deviceNameContains = value
            case "--output":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw ParseError.missingValue("--output")
                }
                outputDirectory = URL(
                    filePath: value,
                    directoryHint: .isDirectory,
                    relativeTo: URL(filePath: FileManager.default.currentDirectoryPath)
                ).standardizedFileURL
            case "--scan-window":
                guard let value = iterator.next() else {
                    throw ParseError.missingValue("--scan-window")
                }
                let parts = value.lowercased().split(separator: "x")
                guard parts.count == 2,
                      let width = Int(parts[0]),
                      let height = Int(parts[1]),
                      width > 0,
                      height > 0
                else {
                    throw ParseError.invalidScanWindow
                }
                scanWindow = ScanWindowRequest(
                    widthPixels: width,
                    heightPixels: height
                )
            case "--timeout":
                guard let value = iterator.next(),
                      let seconds = TimeInterval(value),
                      seconds.isFinite,
                      seconds > 0
                else {
                    throw ParseError.invalidTimeout
                }
                explicitTimeout = seconds
            case "--help", "-h":
                print(Self.usage)
                Darwin.exit(0)
            default:
                throw ParseError.unknownArgument(argument)
            }
        }

        operation = requestedOperation ?? .list
        let defaultTimeout: TimeInterval = switch operation {
        case .list:
            30
        case .inspect:
            60
        case .scan:
            180
        }
        timeout = explicitTimeout ?? defaultTimeout

        if operation == .scan, outputDirectory == nil {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let folderName = "m0-output-\(formatter.string(from: Date()))"
            outputDirectory = URL(
                filePath: folderName,
                directoryHint: .isDirectory,
                relativeTo: URL(filePath: FileManager.default.currentDirectoryPath)
            ).standardizedFileURL
        }
    }

    private static func select(
        _ operation: ScannerProbeOperation,
        for argument: String,
        current: inout ScannerProbeOperation?
    ) throws {
        if let current, current != operation {
            throw ParseError.conflictingOperations(argument)
        }
        current = operation
    }

    static let usage = """
    ScanDeck M0 — ImageCaptureCore scanner probe

    Usage:
      scandeck-m0 --list
      scandeck-m0 --inspect [--device fi-8170]
      scandeck-m0 --scan [--device fi-8170] [--output PATH]

    Options:
      --list             Discover local scanners without opening a session (default).
      --inspect          Open the scanner, dump capabilities, apply and verify the
                         required card settings, then close without scanning.
      --scan             Perform the inspection and one explicit duplex scan.
      --device TEXT      Select a scanner whose name contains TEXT.
      --output PATH      New or empty directory for --scan output.
      --scan-window WxH  Ask the driver for a custom scan window, in master
                         pixels at 600 dpi, instead of leaving it to the A6
                         document type, and report what it kept. Investigation
                         only (TICKET-025) — the app never sets this.
      --timeout SECONDS  Seconds the scanner may go silent before the pass is
                         abandoned. Each delivered page starts the clock again,
                         so a long feed does not time out (list 30; inspect 60;
                         scan 180).
      --help             Show this help.
    """

    enum ParseError: Error, LocalizedError {
        case missingValue(String)
        case invalidTimeout
        case invalidScanWindow
        case conflictingOperations(String)
        case unknownArgument(String)

        var errorDescription: String? {
            switch self {
            case let .missingValue(option):
                "Missing value after \(option)."
            case .invalidTimeout:
                "--timeout must be a positive number."
            case .invalidScanWindow:
                "--scan-window must look like 2100x2800, in master pixels."
            case let .conflictingOperations(argument):
                "Choose only one operation; \(argument) conflicts with an earlier option."
            case let .unknownArgument(argument):
                "Unknown argument: \(argument)"
            }
        }
    }
}

private let commandLineOptions: CommandLineOptions
do {
    commandLineOptions = try CommandLineOptions(
        arguments: CommandLine.arguments
    )
} catch {
    FileHandle.standardError.write(
        Data("error: \(error.localizedDescription)\n\n".utf8)
    )
    print(CommandLineOptions.usage)
    Darwin.exit(64)
}

private let configuration = ScannerProbeConfiguration(
    operation: commandLineOptions.operation,
    deviceNameContains: commandLineOptions.deviceNameContains,
    outputDirectory: commandLineOptions.outputDirectory,
    timeout: commandLineOptions.timeout,
    scanWindow: commandLineOptions.scanWindow
)

private let probe = ImageCaptureScannerProbe(
    configuration: configuration,
    eventHandler: { print($0) },
    completion: { result in
        switch result {
        case let .listed(scannerCount):
            print("Found \(scannerCount) local scanner(s).")
        case let .inspected(deviceName):
            print("M0 inspection passed for \(deviceName).")
        case let .scanned(deviceName, pageURLs):
            print("M0 scan passed for \(deviceName):")
            for url in pageURLs {
                print("  \(url.path)")
            }
        case let .failed(message, _):
            Darwin.fflush(stdout)
            FileHandle.standardError.write(Data("M0 probe failed: \(message)\n".utf8))
        }

        Darwin.fflush(nil)
        Darwin.exit(result.exitCode)
    }
)

probe.start()
RunLoop.main.run()
