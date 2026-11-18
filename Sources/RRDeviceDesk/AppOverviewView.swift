import DeviceCore
import SwiftUI

private struct AppOverviewItem: Identifiable {
    let id: String
    let bundleID: String
    var installed: InstalledApp?
    var saved: SavedApp?
    var purchase: StoreApp?
    var searchResult: StoreApp?

    var name: String {
        installed?.name ?? saved?.name ?? purchase?.name ?? searchResult?.name ?? bundleID
    }

    func matchesInstalled(_ package: SavedApp?) -> Bool {
        guard let package, let installed else { return false }
        return package.version == installed.version && (installed.build == nil || package.build == installed.build)
    }

    func download(device: Device?, signedIn: Bool) -> AppDownload? {
        if let installed, let device {
            guard !matchesInstalled(saved) else { return nil }
            return .installedVersion(installed, device)
        }
        guard saved == nil, signedIn, InstalledApp.validBundleID(bundleID), let app = purchase ?? searchResult else { return nil }
        return .fromStore(app)
    }

    func hasDownloadSource(device: Device?, signedIn: Bool) -> Bool {
        guard download(device: device, signedIn: signedIn) != nil else { return false }
        if installed?.installManifestURL != nil { return true }
        return signedIn && purchase != nil && InstalledApp.validBundleID(bundleID)
    }
}

@MainActor
struct AppOverviewView: View {
    private enum Installation: String, CaseIterable {
        case all = "Все"
        case installed = "Установлено"
        case notInstalled = "Не установлено"
    }

    private struct Filters: Equatable {
        var installation: Installation = .all
        var hasIPA = false
        var downloadable = false
    }

    private struct InstallRequest {
        let device: Device
        let saved: [SavedApp]
        let downloads: [AppDownload]
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: StoreSessionModel
    @ObservedObject var artwork: AppArtworkCache
    let requestInstall: ([SavedApp]) -> Void

    @State private var query = ""
    @State private var filters = Filters()
    @State private var selected: Set<String> = []
    @State private var searchResults: [StoreApp] = []
    @State private var searchedTerm = ""
    @State private var combinedRequest: InstallRequest?

    private var catalogue: [AppOverviewItem] {
        var items: [String: AppOverviewItem] = [:]
        for app in session.purchases ?? [] {
            let key = storeKey(app)
            items[key, default: AppOverviewItem(id: key, bundleID: app.bundleID)].purchase = app
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, term == searchedTerm {
            for app in searchResults {
                let key = storeKey(app)
                items[key, default: AppOverviewItem(id: key, bundleID: app.bundleID)].searchResult = app
            }
        }
        for app in model.appsOnDevice {
            items[app.bundleID, default: AppOverviewItem(id: app.bundleID, bundleID: app.bundleID)].installed = app
        }
        // The library is newest first. Prefer an exact match for an installed build when one is present.
        for app in model.savedApps {
            var item = items[app.bundleID] ?? AppOverviewItem(id: app.bundleID, bundleID: app.bundleID)
            if item.saved == nil || (!item.matchesInstalled(item.saved) && item.matchesInstalled(app)) {
                item.saved = app
            }
            items[item.id] = item
        }
        let device = model.appDevice
        let hasDeviceStatus = device != nil && model.appListLoaded
        let signedIn = session.account != nil && !session.checking
        return items.values.filter { app in
            guard term.isEmpty || app.name.localizedCaseInsensitiveContains(term) || app.bundleID.localizedCaseInsensitiveContains(term)
                    || app.purchase?.name.localizedCaseInsensitiveContains(term) == true || app.searchResult != nil else { return false }
            switch filters.installation {
            case .all: break
            case .installed: guard hasDeviceStatus, app.installed != nil else { return false }
            case .notInstalled: guard hasDeviceStatus, app.installed == nil else { return false }
            }
            return (!filters.hasIPA || app.saved != nil)
                && (!filters.downloadable || app.hasDownloadSource(device: device, signedIn: signedIn))
        }.sorted { a, b in
            let comparison = a.name.localizedStandardCompare(b.name)
            return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
        }
    }

    private func storeKey(_ app: StoreApp) -> String {
        InstalledApp.validBundleID(app.bundleID) ? app.bundleID : "store-\(app.id):"
    }

    var body: some View {
        let apps = catalogue
        VStack(alignment: .leading, spacing: 10) {
            accountBar
            if let error = session.error ?? session.purchaseError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                TextField("Фильтр по названию или Bundle ID", text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit(searchStore)
                if !query.isEmpty {
                    Button { query = "" } label: { Label("Очистить поиск", systemImage: "xmark.circle") }
                        .labelStyle(.iconOnly).help("Очистить текст поиска")
                }
                Button("Искать в App Store", action: searchStore)
                    .disabled(model.busy || StoreSessionModel.engine == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            filterBar
            Table(apps, selection: $selected) {
                TableColumn("Название") { app in
                    AppArtworkRow(name: app.name, cache: artwork, savedID: app.saved?.id,
                                  deviceID: app.installed?.id, storeID: app.purchase?.id)
                        .help(app.bundleID)
                }
                TableColumn("На iPhone") { app in
                    if let installed = app.installed {
                        Label("Установлено · \(installed.version)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).lineLimit(1)
                    } else {
                        Text(model.appListLoaded ? "Не установлено" : "—").foregroundStyle(.secondary)
                    }
                }.width(min: 117, ideal: 164)
                TableColumn("На Mac") { app in
                    if let saved = app.saved {
                        Label("IPA · \(saved.version)", systemImage: "archivebox").lineLimit(1)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }.width(min: 84, ideal: 116)
                TableColumn("Источник загрузки") { app in
                    Text(downloadStatus(app)).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 122, ideal: 159)
            }
            .environment(\.defaultMinListRowHeight, 50)
            .overlay {
                if apps.isEmpty {
                    if filters.installation != .all && (model.appDevice == nil || !model.appListLoaded) {
                        Text("Выберите iPhone и дождитесь загрузки его приложений.").foregroundStyle(.secondary)
                    } else if filters != Filters() || !query.isEmpty {
                        Text("Нет приложений по выбранным фильтрам.").foregroundStyle(.secondary)
                    }
                }
            }
            actions(apps: apps)
        }
        .onChange(of: query) { _ in selected = [] }
        .onChange(of: filters) { _ in selected = [] }
        .confirmationDialog("Скачать и установить выбранные приложения?", isPresented: Binding(
            get: { combinedRequest != nil }, set: { if !$0 { combinedRequest = nil } }
        ), presenting: combinedRequest) { request in
            Button("Скачать и установить") {
                model.downloadOverviewApps(request.downloads, forInstallationOn: request.device, saved: request.saved)
                combinedRequest = nil
            }
            Button("Отмена", role: .cancel) {}
        } message: { request in
            let names = (request.saved.map(\.name) + request.downloads.map(\.name)).prefix(5).joined(separator: ", ")
            Text("iPhone …\(request.device.udid.suffix(6)) · Скачать IPA: \(request.downloads.count) · В очередь: \(request.saved.count + request.downloads.count)\n\(names)")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Статус на iPhone", selection: $filters.installation) {
                ForEach(Installation.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Есть IPA на Mac", isOn: $filters.hasIPA).toggleStyle(.button)
            Toggle("Можно скачать", isOn: $filters.downloadable).toggleStyle(.button)
                .help("Приложения с источником загрузки, для которых в библиотеке нет нужного IPA")
            Spacer()
            if filters != Filters() {
                Button("Сбросить фильтры") { filters = Filters() }
            }
        }
    }

    private var accountBar: some View {
        HStack {
            if let count = session.purchases?.count {
                Label("Покупок App Store: \(count)", systemImage: "bag")
            }
            if session.loadingPurchases {
                ProgressView().controlSize(.small)
                Text("Загружаем покупки…").foregroundStyle(.secondary)
            }
            Spacer()
            if StoreSessionModel.engine == nil {
                Text("Движок App Store отсутствует").foregroundStyle(.secondary)
            } else if let account = session.account {
                Button { session.loadPurchases(force: true) } label: {
                    Label("Обновить покупки", systemImage: "arrow.clockwise")
                }.disabled(session.loadingPurchases || model.busy)
                Menu("Аккаунт") {
                    Text(account.email)
                    Button("Войти снова…", action: session.presentLogin)
                    Button("Выйти") { Task { await session.signOut() } }
                }.disabled(session.checking || model.busy)
            } else if session.checking {
                ProgressView().controlSize(.small)
            } else {
                Button("Войти в Apple Account…", action: session.presentLogin).disabled(model.busy)
            }
        }.font(.callout)
    }

    private func actions(apps: [AppOverviewItem]) -> some View {
        let chosen = apps.filter { selected.contains($0.id) }
        let signedIn = session.account != nil && !session.checking
        let target = model.appDevice
        let downloads = chosen.compactMap { $0.download(device: target, signedIn: signedIn) }
        let toInstall = model.appListLoaded ? chosen.filter { $0.installed == nil } : []
        let saved = toInstall.compactMap(\.saved)
        let toDownloadAndInstall = toInstall.compactMap { $0.download(device: target, signedIn: signedIn) }
        return HStack {
            Text(chosen.isEmpty ? "Приложений: \(apps.count)" : "Выбрано: \(chosen.count) из \(apps.count)")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Скачать на Mac") { model.downloadOverviewApps(downloads) }
                .disabled(downloads.isEmpty || model.busy)
            Button(model.installQueue.hasPendingWork ? "Добавить в очередь" : "Установить на iPhone…") {
                requestInstall(saved)
            }.disabled(!model.canQueueInstallation(saved))
            Button("Скачать и установить…") {
                if let target { combinedRequest = InstallRequest(device: target, saved: saved, downloads: toDownloadAndInstall) }
            }.buttonStyle(.borderedProminent)
                .disabled(target == nil || toDownloadAndInstall.isEmpty || model.busy)
        }
    }

    private func downloadStatus(_ app: AppOverviewItem) -> String {
        if app.purchase != nil, InstalledApp.validBundleID(app.bundleID) { return "В покупках" }
        if app.searchResult != nil { return "В App Store" }
        if app.installed != nil, !app.matchesInstalled(app.saved) { return "Проверить источник" }
        return "—"
    }

    private func searchStore() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.busy, StoreSessionModel.engine != nil, !term.isEmpty else { return }
        model.searchStore(term) { results in
            searchedTerm = term
            searchResults = results
        }
    }
}
