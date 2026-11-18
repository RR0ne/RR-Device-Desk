import AppKit
import DeviceCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
    func loadAppLibrary() {
        perform("Чтение библиотеки приложений", work: { _ in try Self.makeLibrary().entries() }) {
            self.savedApps = $0
            if !self.installQueue.hasPendingWork { self.scanAppDevices() }
        }
    }

    func importIPA() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .archive]
        panel.message = "Выберите установочный пакет IPA."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        saveApp("Импорт IPA") { library, token in
            try library.importPackage(source, cancellation: token)
        }
    }

    func scanAppDevices() {
        guard !busy, !installQueue.hasPendingWork else { return }
        let previousSelection = appDeviceID
        appsOnDevice = []
        appListLoaded = false
        appDeviceID = nil
        appDevices = []
        perform("Поиск iPhone по USB", work: { token in try DeviceService().devices(transport: .usb, token: token) }) {
            self.appDevices = $0
            self.status = $0.isEmpty ? "Устройства не найдены. Подключите и разблокируйте iPhone." : "Найдено устройств: \($0.count)"
            if let previousSelection, $0.contains(where: { $0.id == previousSelection }) {
                self.selectAppDevice(previousSelection)
            } else if $0.count == 1 {
                self.selectAppDevice($0[0].id)
            }
        }
    }

    func selectAppDevice(_ id: String?) {
        guard !busy, !installQueue.hasPendingWork else { return }
        appDeviceID = id
        appsOnDevice = []
        appListLoaded = false
        readInstalledApps()
    }

    func readInstalledApps() {
        guard !busy, let device = appDevice else { return }
        appsOnDevice = []
        appListLoaded = false
        perform("Чтение списка приложений iPhone", work: { token in
            let service = DeviceService()
            guard try service.devices(transport: .usb, token: token).contains(device) else {
                throw DeskError.unavailable("Выбранный iPhone больше не подключён. Нажмите «Найти iPhone».")
            }
            try service.validate(device, token: token)
            return try service.installedApps(device, token: token)
        }) {
            guard self.appDevice == device else { return }
            self.appsOnDevice = $0
            self.appListLoaded = true
            self.status = "Приложений на выбранном iPhone: \($0.count)"
        }
    }

    func pairForApps() {
        guard let device = appDevice else { return }
        perform("Сопряжение — подтвердите доверие на iPhone", work: { token in
            try DeviceService().pair(device, confirmed: true, token: token)
            return true
        }) { _ in self.readInstalledApps() }
    }

    func copyInstalledApps(_ apps: [InstalledApp], success: @escaping ([SavedApp]) -> Void) {
        guard let device = appDevice, !apps.isEmpty, !busy else { return }
        appBatchFailures = []
        perform("Сохранение приложений на Mac", work: { [weak self] token in
            Self.makeLibrary().copyApps(apps, from: device, tool: StoreSessionModel.engine, cancellation: token) { index, name in
                Task { @MainActor [weak self] in
                    self?.updateOperationStatus("Сохраняем \(index) из \(apps.count) · \(name)", for: token)
                }
            }
        }) { result in
            let completed = Set(result.completed.map(\.id))
            self.savedApps = (self.savedApps.filter { !completed.contains($0.id) } + result.completed)
                .sorted { $0.savedAt > $1.savedAt }
            self.finishAppBatch(result, total: apps.count, label: "В библиотеке")
            success(result.completed)
        }
    }

    func exportAppData(_ apps: [InstalledApp], on device: Device, from source: AppDataSource, to directory: URL) {
        guard !busy else { return }
        exportedAppData = []
        appBatchFailures = []
        perform("Сохранение данных приложений", work: { [weak self] token in
            try AppDataExporter().export(apps, for: device, from: source, to: directory, cancellation: token) { message in
                Task { @MainActor [weak self] in self?.updateOperationStatus(message, for: token) }
            }
        }) { result in
            self.exportedAppData = result.archives
            self.appBatchFailures = result.failures
            var parts = ["Архивов данных сохранено: \(result.archives.count) из \(apps.count)"]
            if !result.failures.isEmpty { parts.append("Ошибок: \(result.failures.count)") }
            let remaining = apps.count - result.archives.count - result.failures.count
            if remaining > 0 { parts.append("Остановлено, осталось: \(remaining)") }
            self.status = parts.joined(separator: " · ")
        }
    }

    func searchStore(_ query: String, success: @escaping ([StoreApp]) -> Void) {
        perform("Поиск в App Store", work: { token in
            try Self.makeLibrary().searchStore(query, tool: StoreSessionModel.engine, cancellation: token)
        }) { results in
            self.status = results.isEmpty ? "Приложения не найдены." : "Найдено приложений: \(results.count)"
            success(results)
        }
    }

    func downloadOverviewApps(_ downloads: [AppDownload], forInstallationOn device: Device? = nil,
                              saved: [SavedApp] = []) {
        guard !busy, !downloads.isEmpty else { return }
        appBatchFailures = []
        perform("Загрузка приложений", work: { [weak self] token in
            let result = Self.makeLibrary().downloadApps(downloads, tool: StoreSessionModel.engine,
                                                         cancellation: token) { index, name in
                DispatchQueue.main.async { [weak self] in
                    self?.updateOperationStatus("Скачиваем \(index) из \(downloads.count) · \(name)", for: token)
                }
            }
            return (result, token.isCancelled)
        }) { outcome in
            let (result, cancelled) = outcome
            let newIDs = Set(result.completed.map(\.id))
            self.savedApps = (self.savedApps.filter { !newIDs.contains($0.id) } + result.completed)
                .sorted { $0.savedAt > $1.savedAt }
            self.finishAppBatch(result, total: downloads.count, label: "В библиотеке")
            if let device, !cancelled {
                self.installSavedApps(saved + result.completed, on: device)
            }
        }
    }

    func revealSavedApp(_ app: SavedApp) {
        let url = Self.makeLibrary().root.appendingPathComponent(app.id).appendingPathComponent("app.ipa")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func trashSavedApps(_ apps: [SavedApp]) {
        guard !apps.isEmpty, !busy else { return }
        let waitingIDs = Set(installQueue.waiting.map(\.id))
        guard apps.allSatisfy({ !waitingIDs.contains($0.id) }) else {
            errorMessage = "Сначала уберите выбранные IPA из очереди установки."
            return
        }
        appBatchFailures = []
        perform("Перемещение IPA в Корзину", work: { [weak self] token in
            Self.makeLibrary().trashPackages(apps, cancellation: token) { index, name in
                Task { @MainActor [weak self] in
                    self?.updateOperationStatus("Перемещаем в Корзину \(index) из \(apps.count) · \(name)", for: token)
                }
            }
        }) { result in
            let completed = Set(result.completed.map(\.id))
            self.savedApps.removeAll { completed.contains($0.id) }
            self.finishAppBatch(result, total: apps.count, label: "В Корзине Mac")
        }
    }

    private func finishAppBatch(_ result: AppBatchResult, total: Int, label: String) {
        appBatchFailures = result.failures
        let skipped = total - result.completed.count - result.failures.count
        var parts = ["\(label): \(result.completed.count) из \(total)"]
        if !result.failures.isEmpty { parts.append("Ошибок: \(result.failures.count)") }
        if skipped > 0 { parts.append("Остановлено, осталось: \(skipped)") }
        status = parts.joined(separator: " · ")
    }

    private func saveApp(_ action: String, success: ((SavedApp) -> Void)? = nil,
                         work: @escaping (AppLibrary, CancellationToken) throws -> SavedApp) {
        perform(action, work: { token in
            let library = Self.makeLibrary()
            let app = try work(library, token)
            return (app, try library.entries())
        }) { result in
            self.savedApps = result.1
            self.status = "«\(result.0.name)» · \(result.0.version) сохранено в библиотеке."
            success?(result.0)
        }
    }

    nonisolated static func makeLibrary() -> AppLibrary {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppLibrary(root: support.appendingPathComponent("RRDeviceDesk/AppLibrary", isDirectory: true))
    }
}

@MainActor
struct AppLibraryView: View {
    private enum Source { case library, device, store }

    private struct DataRequest: Identifiable {
        let id = UUID()
        let device: Device
        let apps: [InstalledApp]
    }

    @EnvironmentObject var model: AppModel
    @StateObject private var storeSession = StoreSessionModel()
    @State private var source: Source = .library
    @State private var query = ""
    @State private var selectedSavedAppIDs: Set<String> = []
    @State private var selectedInstalledAppIDs: Set<String> = []
    @State private var installRequest: (device: Device, apps: [SavedApp])?
    @State private var trashRequest: [SavedApp]?
    @State private var dataRequest: DataRequest?
    @State private var showPair = false
    @StateObject private var artwork = AppArtworkCache()

    private var visibleSavedApps: [SavedApp] { model.savedApps.filter { matches($0.name, $0.bundleID) } }
    private var visibleInstalledApps: [InstalledApp] { model.appsOnDevice.filter { matches($0.name, $0.bundleID) } }
    private var selectedSavedApps: [SavedApp] { visibleSavedApps.filter { selectedSavedAppIDs.contains($0.id) } }
    private var selectedInstalledApps: [InstalledApp] { visibleInstalledApps.filter { selectedInstalledAppIDs.contains($0.id) } }
    private var saved: SavedApp? {
        let apps = selectedSavedApps
        return apps.count == 1 ? apps.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Приложения").font(.largeTitle.bold())
                Spacer()
                Button { model.importIPA() } label: { Label("Импортировать IPA…", systemImage: "square.and.arrow.down") }
                    .disabled(model.busy)
            }
            HStack {
                Picker("Источник", selection: $source) {
                    Text("Библиотека Mac").tag(Source.library)
                    Text("На iPhone").tag(Source.device)
                    Text("Обзор").tag(Source.store)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 355)
                Spacer()
                if source != .store {
                    TextField("Поиск по названию или Bundle ID", text: $query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }
            }
            HStack {
                Button { model.scanAppDevices() } label: { Label("Найти iPhone", systemImage: "cable.connector") }
                    .disabled(model.busy || model.installQueue.hasPendingWork)
                Picker("iPhone по USB", selection: Binding(get: { model.appDeviceID }, set: { model.selectAppDevice($0) })) {
                    Text("Выберите устройство").tag(nil as String?)
                    ForEach(model.appDevices) { device in
                        Text("iPhone · …\(device.udid.suffix(6))").tag(Optional(device.id))
                    }
                }.disabled(model.appDevices.isEmpty || model.busy || model.installQueue.hasPendingWork)
                Button("Сопрячь…") { showPair = true }.disabled(model.appDevice == nil || model.busy)
            }
            switch source {
            case .library: library
            case .device: deviceApps.disabled(model.busy)
            case .store:
                AppOverviewView(session: storeSession, artwork: artwork, requestInstall: requestInstall)
                if !model.installQueue.entries.isEmpty { AppInstallQueueView(artwork: artwork) }
            }
            if !model.appBatchFailures.isEmpty {
                DisclosureGroup("Причины ошибок (\(model.appBatchFailures.count))") {
                    ScrollView {
                        Text(model.appBatchFailures.joined(separator: "\n"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }
            }
        }
        .padding(24)
        .disabled(model.busy && model.installQueue.attempt == nil)
        .onChange(of: model.appDeviceID) { _ in
            selectedInstalledAppIDs = []
        }
        .onAppear { model.loadAppLibrary() }
        .task { await storeSession.refresh() }
        .onReceive(storeSession.$purchases) { purchases in
            if let purchases {
                let ids = purchases.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id)
                artwork.prefetchStoreIcons(ids)
            } else {
                artwork.cancelStoreLoading()
            }
        }
        .onDisappear { artwork.cancelStoreLoading() }
        .task(id: model.savedApps.map(\.id)) { await loadSavedIcons() }
        .task(id: model.appListLoaded ? model.appDeviceID : nil) { await loadDeviceIcons() }
        .sheet(isPresented: $storeSession.showingLogin, onDismiss: storeSession.closeLogin) {
            StoreLoginView(session: storeSession)
        }
        .sheet(item: $dataRequest) { request in
            let matchingBackup = model.backupMetadata?.udid.caseInsensitiveCompare(request.device.udid) == .orderedSame
                ? model.openedBackup : nil
            AppDataExportSheet(apps: request.apps, openedBackup: matchingBackup) { source, destination in
                model.exportAppData(request.apps, on: request.device, from: source, to: destination)
            }
        }
        .confirmationDialog("Сопрячь Mac и iPhone?", isPresented: $showPair) {
            Button("Сопрячь") { model.pairForApps() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Если на iPhone появится запрос доверия, подтвердите его на телефоне.")
        }
        .confirmationDialog("Установить выбранные IPA на iPhone?", isPresented: Binding(
            get: { installRequest != nil }, set: { if !$0 { installRequest = nil } }
        ), presenting: installRequest) { request in
            Button("Установить") {
                model.installSavedApps(request.apps, on: request.device)
                installRequest = nil
            }
            Button("Отмена", role: .cancel) {}
        } message: { request in
            let entries = request.apps.prefix(5).map { "«\($0.name)» · \($0.version) (\($0.build))" }
            let additional = request.apps.count - entries.count
            let more = additional > 0 ? "\nЕщё пакетов: \(additional)" : ""
            Text("iPhone …\(request.device.udid.suffix(6)) · Выбрано IPA: \(request.apps.count)\n\(entries.joined(separator: "\n"))\(more)")
        }
        .confirmationDialog("Переместить IPA в Корзину Mac?", isPresented: Binding(
            get: { trashRequest != nil }, set: { if !$0 { trashRequest = nil } }
        ), presenting: trashRequest) { apps in
            Button("Переместить в Корзину", role: .destructive) { model.trashSavedApps(apps) }
            Button("Отмена", role: .cancel) {}
        } message: { apps in
            let entries = apps.prefix(5).map { app in
                "«\(app.name)» · \(app.version) (\(app.build)) · \(app.savedAt.formatted(date: .abbreviated, time: .shortened))"
            }
            let additional = apps.count > entries.count ? "\nЕщё пакетов: \(apps.count - entries.count)" : ""
            Text("Выбрано IPA: \(apps.count)\n\(entries.joined(separator: "\n"))\(additional)")
        }
    }

    private func requestTrash(_ apps: [SavedApp]) {
        guard !apps.isEmpty, !model.busy else { return }
        trashRequest = apps
    }

    private func requestInstall(_ apps: [SavedApp]) {
        guard let device = model.appDevice, model.canQueueInstallation(apps) else { return }
        if model.installQueue.hasPendingWork {
            model.installSavedApps(apps, on: device)
            return
        }
        installRequest = (device, apps)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.savedApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "archivebox").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("Библиотека пока пуста").font(.title2.bold())
                    Text("Импортируйте IPA или выберите приложение на iPhone. Сохранённый пакет останется на Mac.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Импортировать IPA…") { model.importIPA() }.buttonStyle(.borderedProminent).disabled(model.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visibleSavedApps, selection: $selectedSavedAppIDs) {
                    TableColumn("Название") { app in
                        AppArtworkRow(name: app.name, cache: artwork, savedID: app.id, deviceID: app.bundleID)
                    }
                    TableColumn("Версия", value: \.version).width(80)
                    TableColumn("Bundle ID", value: \.bundleID)
                    TableColumn("Добавлено") { app in
                        Text(app.savedAt.formatted(date: .abbreviated, time: .shortened))
                    }.width(155)
                    TableColumn("Размер") { app in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: app.digest.bytes), countStyle: .file))
                    }.width(100)
                }
                .environment(\.defaultMinListRowHeight, 50)
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty {
                        let apps = visibleSavedApps.filter { ids.contains($0.id) }
                        Button(installButtonTitle(apps.count)) { requestInstall(apps) }.disabled(!model.canQueueInstallation(apps))
                        Button("Удалить IPA…", role: .destructive) {
                            requestTrash(apps)
                        }.disabled(model.busy)
                    }
                }
                .onDeleteCommand { requestTrash(selectedSavedApps) }
                HStack {
                    Button("Показать IPA в Finder") { if let saved { model.revealSavedApp(saved) } }.disabled(saved == nil)
                    let count = selectedSavedApps.count
                    Button(count > 1 ? "Удалить IPA (\(count))…" : "Удалить IPA…") {
                        requestTrash(selectedSavedApps)
                    }.disabled(count == 0 || model.busy)
                    Spacer()
                    Button { requestInstall(selectedSavedApps) } label: {
                        Label(installButtonTitle(count), systemImage: model.installQueue.hasPendingWork ? "text.badge.plus" : "iphone.and.arrow.forward")
                    }.buttonStyle(.borderedProminent).disabled(!model.canQueueInstallation(selectedSavedApps))
                }
            }
            if !model.installQueue.entries.isEmpty { AppInstallQueueView(artwork: artwork) }
        }
    }

    private func installButtonTitle(_ count: Int) -> String {
        let quantity = count > 1 ? " (\(count))" : ""
        return model.installQueue.hasPendingWork ? "Добавить в очередь\(quantity)" : "Установить на iPhone\(quantity)…"
    }

    private var deviceApps: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Обновить список iPhone") {
                    selectedInstalledAppIDs = []
                    model.readInstalledApps()
                }.disabled(model.appDevice == nil)
                Spacer()
                if model.appListLoaded { Text("Приложений: \(model.appsOnDevice.count)").foregroundStyle(.secondary) }
            }
            if model.appListLoaded {
                Table(visibleInstalledApps, selection: $selectedInstalledAppIDs) {
                    TableColumn("Название") { app in
                        AppArtworkRow(name: app.name, cache: artwork, savedID: libraryIconID(for: app.bundleID), deviceID: app.id)
                    }
                    TableColumn("Версия", value: \.version).width(95)
                    TableColumn("Bundle ID", value: \.bundleID)
                }
                .environment(\.defaultMinListRowHeight, 50)
                HStack {
                    let count = selectedInstalledApps.count
                    Text(count == 0 ? "Выберите приложения, удерживая ⌘ или Shift." : "Выбрано: \(count)")
                        .foregroundStyle(.secondary)
                    if !model.exportedAppData.isEmpty {
                        Button("Показать архивы в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(model.exportedAppData)
                        }
                    }
                    Spacer()
                    Button(count > 1 ? "Сохранить данные (\(count))…" : "Сохранить данные…") {
                        if let device = model.appDevice {
                            dataRequest = DataRequest(device: device, apps: selectedInstalledApps)
                        }
                    }.disabled(count == 0 || model.appDevice == nil)
                    Button(count > 1 ? "Скачать на Mac (\(count))" : "Скачать на Mac") {
                        model.copyInstalledApps(selectedInstalledApps) { completed in
                            guard let app = completed.first else { return }
                            query = ""
                            selectedSavedAppIDs = completed.count == 1 ? [app.id] : []
                            source = .library
                        }
                    }.buttonStyle(.borderedProminent).disabled(count == 0 || model.appDevice == nil)
                }
            } else {
                Text("Выберите подключённый iPhone. Его приложения загрузятся автоматически.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func matches(_ name: String, _ identifier: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query) || identifier.localizedCaseInsensitiveContains(query)
    }

    private func libraryIconID(for bundleID: String) -> String? {
        model.savedApps.first(where: { $0.bundleID == bundleID })?.id
    }

    private func loadSavedIcons() async {
        let apps = model.savedApps
        let ids = Set(apps.map(\.id))
        artwork.saved = artwork.saved.filter { ids.contains($0.key) }
        let pending = apps.filter { artwork.saved[$0.id] == nil }
        let token = CancellationToken()
        await withTaskCancellationHandler {
            for app in pending {
                guard !Task.isCancelled else { break }
                let bytes = await Task.detached(priority: .utility) {
                    AppLibraryArtwork.readIPAIcon(app, in: AppModel.makeLibrary(), token: token)
                }.value
                guard !Task.isCancelled else { break }
                if let bytes { artwork.saved[app.id] = AppLibraryArtwork.thumbnail(bytes) }
            }
        } onCancel: { token.cancel() }
    }

    private func loadDeviceIcons() async {
        artwork.device = [:]
        guard model.appListLoaded, let device = model.appDevice else { return }
        let ids = model.appsOnDevice.map(\.id)
        let token = CancellationToken()
        await withTaskCancellationHandler {
            for start in stride(from: 0, to: ids.count, by: 20) {
                guard !Task.isCancelled else { break }
                let group = Array(ids[start..<min(start + 20, ids.count)])
                let icons = await Task.detached(priority: .utility) {
                    AppLibraryArtwork.readDeviceIcons(group, from: device, token: token)
                }.value
                guard !Task.isCancelled else { break }
                for (id, image) in icons { artwork.device[id] = AppLibraryArtwork.thumbnail(image) }
            }
        } onCancel: { token.cancel() }
    }
}
