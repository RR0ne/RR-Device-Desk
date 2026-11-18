import DeviceCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AppDataExportSheet: View {
    private enum Mode { case fresh, existing }
    private enum FolderPurpose { case backup, destination }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var backup: URL?
    @State private var destination: URL?
    @State private var folderPurpose: FolderPurpose = .destination
    @State private var choosingFolder = false
    @State private var folderError: String?
    let apps: [InstalledApp]
    let start: (AppDataSource, URL) -> Void

    init(apps: [InstalledApp], openedBackup: URL?, start: @escaping (AppDataSource, URL) -> Void) {
        self.apps = apps
        self.start = start
        _mode = State(initialValue: openedBackup == nil ? .fresh : .existing)
        _backup = State(initialValue: openedBackup)
    }

    private var source: AppDataSource? {
        mode == .fresh ? .newTemporaryBackup : backup.map(AppDataSource.existingBackup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Сохранить данные приложений").font(.title2.bold())
            Text(apps.count == 1 ? apps[0].name : "Выбрано приложений: \(apps.count)")
            Picker("Источник данных", selection: $mode) {
                Text("Новая копия").tag(Mode.fresh)
                Text("Готовая копия").tag(Mode.existing)
            }.pickerStyle(.segmented).labelsHidden()

            if mode == .fresh {
                Text("RR Device Desk создаст в выбранной папке временную полную незашифрованную копию iPhone и удалит её после экспорта. Если iPhone запросит код, введите его на телефоне.")
                    .foregroundStyle(.secondary)
            } else {
                folderRow("Папка резервной копии", url: backup) {
                    chooseFolder(.backup)
                }
            }

            folderRow("Сохранить архивы в", url: destination) {
                chooseFolder(.destination)
            }
            if let folderError { Text(folderError).font(.callout).foregroundStyle(.red) }
            Text("На каждое приложение создаётся отдельный ZIP с данными из копии. Для установки приложения нужен IPA.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .fresh ? "Создать копию и сохранить" : "Сохранить данные") {
                    guard let source, let destination else { return }
                    dismiss()
                    start(source, destination)
                }.keyboardShortcut(.defaultAction)
                    .disabled(source == nil || destination == nil)
            }
        }
        .padding(22)
        .frame(width: 510)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                if folderPurpose == .backup { backup = url } else { destination = url }
            case .failure(let error):
                folderError = error.localizedDescription
            }
        }
    }

    private func folderRow(_ label: String, url: URL?, select: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                Text(url?.path ?? "Папка не выбрана").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Выбрать…", action: select)
                .accessibilityLabel("Выбрать папку: \(label)")
        }
    }

    private func chooseFolder(_ purpose: FolderPurpose) {
        folderPurpose = purpose
        folderError = nil
        choosingFolder = true
    }
}
