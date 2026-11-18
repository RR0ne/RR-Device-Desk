import Foundation

public enum AppInstallProgress: Equatable, Sendable {
    case checkingPackage, sendingPackage, installing(percent: Int?), verifyingOnDevice
}

public enum AppInstallOutcome: Equatable, Sendable {
    case installed, alreadyInstalled
}

public struct AppInstallQueue {
    public struct Entry: Identifiable {
        public enum State: Equatable {
            case waiting, running(AppInstallProgress), finished(AppInstallOutcome), failed(String)
        }

        public let app: SavedApp
        public fileprivate(set) var state: State = .waiting
        public var id: String { app.id }
    }

    public private(set) var device: Device?
    public private(set) var entries: [Entry] = []
    public private(set) var attempt: UUID?
    public var pauseReason: String?

    public init() {}

    public var waiting: [Entry] { entries.filter { $0.state == .waiting } }
    private var runningIndex: Int? {
        entries.firstIndex { entry in
            if case .running = entry.state { return true }
            return false
        }
    }
    public var running: Entry? { runningIndex.map { entries[$0] } }
    public var hasPendingWork: Bool { attempt != nil || entries.contains { $0.state == .waiting } }

    public mutating func enqueue(_ apps: [SavedApp], on device: Device) {
        guard !hasPendingWork || self.device == device else { return }
        if !hasPendingWork {
            self = AppInstallQueue()
            self.device = device
        }
        var bundleIDs = Set(entries.map { $0.app.bundleID })
        entries.append(contentsOf: apps.filter { bundleIDs.insert($0.bundleID).inserted }.map { Entry(app: $0) })
    }

    public mutating func startNext() -> (app: SavedApp, attempt: UUID)? {
        guard attempt == nil, pauseReason == nil, let index = entries.firstIndex(where: { $0.state == .waiting }) else { return nil }
        let id = UUID()
        attempt = id
        entries[index].state = .running(.checkingPackage)
        return (entries[index].app, id)
    }

    public mutating func update(_ progress: AppInstallProgress, attempt: UUID) {
        guard self.attempt == attempt, let index = runningIndex else { return }
        entries[index].state = .running(progress)
    }

    public mutating func finish(_ state: Entry.State, attempt: UUID) {
        guard self.attempt == attempt, let index = runningIndex else { return }
        entries[index].state = state
        self.attempt = nil
    }

    public mutating func moveWaiting(_ id: String, to position: Int) {
        let order = entries.indices.filter { entries[$0].state == .waiting }
        guard order.indices.contains(position), let index = order.first(where: { entries[$0].id == id }) else { return }
        entries.insert(entries.remove(at: index), at: order[position])
    }

    public mutating func removeWaiting(_ id: String) {
        entries.removeAll { $0.id == id && $0.state == .waiting }
    }

    public mutating func retry(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .failed = entries[index].state else { return }
        var entry = entries.remove(at: index)
        entry.state = .waiting
        entries.append(entry)
    }
}

// Only the process's stdout reader calls append. The tool separates status updates with CR or LF.
final class InstallerProgressReader: @unchecked Sendable {
    private let emit: @Sendable (AppInstallProgress) -> Void
    private var pending = Data()
    private var previous: AppInstallProgress?

    init(_ emit: @escaping @Sendable (AppInstallProgress) -> Void) { self.emit = emit }

    func append(_ data: Data) {
        for byte in data {
            if byte == 10 || byte == 13 {
                report(complete: true)
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < 4096 {
                pending.append(byte)
            }
        }
        report(complete: false)
    }

    private func report(complete: Bool) {
        let line = String(decoding: pending, as: UTF8.self)
        let phase: AppInstallProgress
        if line.hasPrefix("Copying '") {
            phase = .sendingPackage
        } else if line.hasPrefix("Installing '") {
            phase = .installing(percent: nil)
        } else if line.hasPrefix("Install: ") {
            if line.hasSuffix("%)"), let start = line.lastIndex(of: "("),
               let percent = Int(line[line.index(after: start)...].dropLast(2)), (0...100).contains(percent) {
                phase = .installing(percent: percent)
            } else if complete {
                phase = .installing(percent: nil)
            } else {
                return
            }
        } else {
            return
        }
        guard phase != previous else { return }
        previous = phase
        emit(phase)
    }
}
