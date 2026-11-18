import AppKit
import DeviceCore
import ImageIO
import SwiftUI

enum AppLibraryArtwork {
    static func readIPAIcon(_ app: SavedApp, in library: AppLibrary, token: CancellationToken) -> Data? {
        let folder = library.root.appendingPathComponent(app.id, isDirectory: true)
        guard let safeFolder = try? SafeFolder(folder), let archive = try? safeFolder.read("app.ipa") else { return nil }
        defer { try? archive.close() }
        let path = folder.appendingPathComponent("app.ipa").path
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let runner = ProcessRunner()
        let artwork = CommandRequest(executable: unzip, arguments: ["-p", path, "iTunesArtwork"], timeout: 8)
        if let result = try? runner.run(artwork, cancellation: token), result.exitCode == 0,
           !result.stdout.isEmpty, result.stdout.count <= 4 * 1024 * 1024 {
            return result.stdout
        }

        let list = CommandRequest(executable: unzip, arguments: ["-Z", "-1", path], timeout: 8)
        guard let names = try? runner.run(list, cancellation: token), names.exitCode == 0 else { return nil }
        let resources = names.output.split(whereSeparator: \.isNewline).map(String.init).filter {
            let parts = $0.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") &&
                !$0.contains(where: { "*?[]\\".contains($0) })
        }
        var iconNames: [String] = []
        if let manifest = resources.first(where: { $0.hasSuffix("/Info.plist") }) {
            let request = CommandRequest(executable: unzip, arguments: ["-p", path, manifest], timeout: 8)
            if let result = try? runner.run(request, cancellation: token), result.exitCode == 0,
               result.stdout.count <= 512 * 1024, let info = try? Plists.dictionary(result.stdout) {
                let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
                var names = (primary?["CFBundleIconFiles"] as? [String]) ?? (info["CFBundleIconFiles"] as? [String]) ?? []
                if let legacy = info["CFBundleIconFile"] as? String { names.append(legacy) }
                for name in names.reversed() {
                    let base = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
                    iconNames += [base + "@3x.png", base + "@2x.png", base + ".png"]
                }
            }
        }
        iconNames += ["AppIcon60x60@3x.png", "AppIcon60x60@2x.png", "Icon@2x.png", "Icon.png"]
        for name in iconNames {
            guard let resource = resources.first(where: { $0.hasSuffix("/" + name) }) else { continue }
            let request = CommandRequest(executable: unzip, arguments: ["-p", path, resource], timeout: 8)
            if let result = try? runner.run(request, cancellation: token), result.exitCode == 0,
               !result.stdout.isEmpty, result.stdout.count <= 512 * 1024 { return result.stdout }
        }
        return nil
    }

    static func readDeviceIcons(_ ids: [String], from device: Device, token: CancellationToken) -> [String: Data] {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rrdeviceicons")
        guard device.transport == .usb, FileManager.default.isExecutableFile(atPath: executable.path) else { return [:] }
        let request = CommandRequest(executable: executable, arguments: [device.udid] + ids, timeout: 10)
        guard let response = try? ProcessRunner().run(request, cancellation: token), response.exitCode == 0 else { return [:] }
        let bytes = response.stdout
        var offset = bytes.startIndex
        var images: [String: Data] = [:]
        let requested = Set(ids)
        while offset < bytes.endIndex {
            guard let lineEnd = bytes[offset..<min(offset + 272, bytes.endIndex)].firstIndex(of: 0x0A),
                  let header = String(data: bytes[offset..<lineEnd], encoding: .utf8) else { return images }
            let fields = header.split(separator: " ")
            guard fields.count == 2, let size = Int(fields[1]), (1...(512 * 1024)).contains(size),
                  lineEnd + 1 + size <= bytes.endIndex else { return images }
            let id = String(fields[0])
            if requested.contains(id) { images[id] = bytes[(lineEnd + 1)..<(lineEnd + 1 + size)] }
            offset = lineEnd + 1 + size
        }
        return images
    }

    static func thumbnail(_ bytes: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

@MainActor
final class AppArtworkCache: ObservableObject {
    @Published var saved: [String: NSImage] = [:]
    @Published var device: [String: NSImage] = [:]
    @Published private(set) var store: [Int64: NSImage] = [:]

    private var requestedStoreIDs: Set<Int64> = []
    private var pendingStoreIDs: [Int64] = []
    private var storeLoad: Task<Void, Never>?

    func prefetchStoreIcons(_ ids: [Int64]) {
        pendingStoreIDs.append(contentsOf: ids.filter { $0 > 0 && requestedStoreIDs.insert($0).inserted })
        startStoreLoading()
    }

    func requestStoreIcon(_ id: Int64) {
        guard id > 0 else { return }
        if let index = pendingStoreIDs.firstIndex(of: id) {
            pendingStoreIDs.remove(at: index)
        } else if !requestedStoreIDs.insert(id).inserted {
            return
        }
        pendingStoreIDs.insert(id, at: 0)
        startStoreLoading()
    }

    func cancelStoreLoading() {
        storeLoad?.cancel()
        pendingStoreIDs.removeAll()
        requestedStoreIDs = Set(store.keys)
    }

    private func startStoreLoading() {
        guard storeLoad == nil, !pendingStoreIDs.isEmpty else { return }
        storeLoad = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await self?.loadStoreIcons()
        }
    }

    private func loadStoreIcons() async {
        defer {
            storeLoad = nil
            startStoreLoading()
        }
        let clock = ContinuousClock()
        while !Task.isCancelled, !pendingStoreIDs.isEmpty {
            let batch = Array(pendingStoreIDs.prefix(AppStoreArtwork.batchSize))
            pendingStoreIDs.removeFirst(batch.count)
            // A batch can query up to three storefronts, so space out catalogue requests during prefetch.
            let nextBatch = clock.now.advanced(by: .seconds(10))
            let images = await AppStoreArtwork.images(for: batch)
            guard !Task.isCancelled else { return }
            if let images {
                let thumbnails = images.compactMapValues(AppLibraryArtwork.thumbnail)
                if !thumbnails.isEmpty { store.merge(thumbnails) { current, _ in current } }
            } else {
                requestedStoreIDs.subtract(batch)
            }
            if !pendingStoreIDs.isEmpty { try? await clock.sleep(until: nextBatch) }
        }
    }
}

struct AppArtworkRow: View {
    let name: String
    @ObservedObject var cache: AppArtworkCache
    var savedID: String? = nil
    var deviceID: String? = nil
    var storeID: Int64? = nil
    var size: CGFloat = 44

    private var image: NSImage? {
        deviceID.flatMap { cache.device[$0] } ?? savedID.flatMap { cache.saved[$0] } ?? storeID.flatMap { cache.store[$0] }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if let storeID {
                    purchasePlaceholder(storeID: storeID)
                } else {
                    Image(systemName: "app.fill").font(.system(size: size * 0.55)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
            Text(name).lineLimit(1)
        }
        .padding(.vertical, 3)
        .task(id: storeID) {
            if !Task.isCancelled, image == nil, let storeID { cache.requestStoreIcon(storeID) }
        }
    }

    private func purchasePlaceholder(storeID: Int64) -> some View {
        let initials = name.filter { $0.isLetter || $0.isNumber }.prefix(2).uppercased()
        let hue = Double((UInt64(truncatingIfNeeded: storeID) &* 137) % 360) / 360
        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hue: hue, saturation: 0.58, brightness: 0.44))
    }
}
