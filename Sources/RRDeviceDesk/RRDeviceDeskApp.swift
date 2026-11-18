import SwiftUI
import AppKit
import DeviceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Операция ещё выполняется"
        if model?.installQueue.attempt != nil {
            alert.informativeText = "Поставьте очередь на паузу после текущего приложения и дождитесь завершения установки."
        } else {
            alert.informativeText = "Сначала нажмите «Остановить» в окне приложения и дождитесь остановки. Незавершённая копия останется в отдельной папке .partial."
        }
        alert.addButton(withTitle: "Вернуться")
        alert.runModal()
        return .terminateCancel
    }
}
@main
@MainActor
struct RRDeviceDeskApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("RR Device Desk") {
            MainView().environmentObject(model)
                .onAppear { delegate.model = model }
                .frame(minWidth: 1080, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть резервную копию…") { model.openBackup() }
                    .keyboardShortcut("o").disabled(model.busy)
            }
        }
    }
}
@MainActor
struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: "externaldrive.badge.person.crop").font(.largeTitle)
                    Text("RR Device Desk").font(.title2.bold())
                    Text("Ваши устройства. Ваши данные.").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal).padding(.top)
                List(selection: Binding<String?>(get: { model.section }, set: { if let value = $0 { model.section = value } })) {
                    Label("Устройства", systemImage: "iphone.and.ipad").tag("devices")
                    Label("Приложения", systemImage: "square.stack.3d.up").tag("apps")
                    Label("Просмотр копии", systemImage: "folder").tag("backups")
                    Label("История копий", systemImage: "clock.arrow.circlepath").tag("history")
                    Label("Диагностика", systemImage: "stethoscope").tag("diagnostics")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Локальное хранилище", systemImage: "lock.shield")
                    Text("Версия \(appVersion)")
                    Text("Восстановление на iPhone пока не реализовано.")
                }.font(.caption).foregroundStyle(.secondary).padding()
            }.navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch model.section {
                    case "apps": AppLibraryView()
                    case "backups": BackupBrowserView()
                    case "history": HistoryView()
                    case "diagnostics": DiagnosticsView()
                    default: DevicesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let warning = model.auditWarning { Text(warning).foregroundStyle(.orange) }
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(.callout).textSelection(.enabled)
                        Spacer()
                        if model.installQueue.attempt != nil, model.section != "apps" {
                            Button("К очереди установки") { model.section = "apps" }
                        } else if model.busy, model.installQueue.attempt == nil {
                            Button("Остановить", role: .destructive) { model.cancel() }
                        }
                    }
                    DisclosureGroup("Журнал текущего сеанса") {
                        ScrollView {
                            Text(model.recentEvents.joined(separator: "\n")).font(.caption.monospaced())
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 110)
                    }.font(.caption)
                }.padding()
            }
        }
    }
}
@MainActor
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showPair = false
    @State private var showEncryption = false
    @State private var showBackup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Устройства").font(.largeTitle.bold())
            Text("Сначала подключите iPhone или iPad кабелем и подтвердите доверие на его экране.").foregroundStyle(.secondary)
            HStack {
                Picker("Соединение", selection: $model.transport) {
                    Text("USB").tag(Transport.usb)
                    Text("Wi-Fi").tag(Transport.network)
                }.pickerStyle(.segmented).frame(width: 200).disabled(model.busy)
                Button { model.scan() } label: { Label("Найти устройства", systemImage: "arrow.clockwise") }.disabled(model.busy)
                Spacer()
            }
            if model.transport == .network {
                Text("Wi-Fi доступен для уже сопряжённых устройств с включённой синхронизацией по сети. Первичное доверие задайте через USB.").font(.callout).foregroundStyle(.secondary)
            }
            HSplitView {
                List(model.devices, selection: $model.selectedDeviceID) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Apple · \(device.transport.title)", systemImage: "iphone")
                        Text("…" + device.udid.suffix(8)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(device.id)
                }.frame(minWidth: 160, idealWidth: 190, maxWidth: 260).disabled(model.busy)
                    .onChange(of: model.selectedDeviceID) { _ in model.readDevice() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.selectedDevice != nil {
                            if let details = model.details {
                                GroupBox("Информация устройства") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(details.name).font(.title2.bold())
                                        row("Модель", details.product)
                                        row("iOS / iPadOS", details.version + " · " + details.build)
                                        row("Шифрование копий", details.encryption.map { $0 ? "Включено" : "Выключено" } ?? "Неизвестно")
                                        row("Занято на разделе данных", details.usedBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "Недоступно")
                                        ForEach(details.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }
                            } else {
                                Text("Выберите «Обновить сведения». Если доверие ещё не настроено - выполните сопряжение.").foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Обновить сведения") { model.readDevice() }
                                Button("Сопрячь…") { showPair = true }.disabled(model.selectedDevice?.transport != .usb)
                                Button("Аккумулятор") { model.battery() }
                            }.disabled(model.busy)
                            GroupBox("Новая резервная копия") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(model.backupRoot?.path ?? "Папка хранения ещё не выбрана").font(.caption).textSelection(.enabled)
                                    Button("Выбрать папку…") { model.chooseBackupRoot() }
                                    if model.details?.encryption == false {
                                        Button { showEncryption = true } label: { Label("Включить шифрование…", systemImage: "lock") }
                                    }
                                    Toggle("Я разрешаю незашифрованную копию, если шифрование выключено", isOn: $model.allowUnencrypted)
                                    Text("Каждый запуск создаёт новую полную копию в отдельной папке. Она может занять много места. Это не побитовый образ телефона.").font(.caption).foregroundStyle(.secondary)
                                    Button { showBackup = true } label: { Label("Создать копию…", systemImage: "externaldrive.badge.plus") }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(model.backupRoot == nil || model.details?.encryption == nil || (model.details?.encryption == false && !model.allowUnencrypted))
                                    Text("Содержимое зашифрованной копии в версии 0.1 не расшифровывается. Не удаляйте другие проверенные резервные копии.").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.disabled(model.busy)
                            if !model.batteryOutput.isEmpty {
                                GroupBox("Ответ диагностики аккумулятора - без вычисленных предположений") {
                                    Text(model.batteryOutput).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }
                            }
                        } else {
                            VStack(spacing: 16) {
                                Image(systemName: "cable.connector").font(.system(size: 48)).foregroundStyle(.secondary)
                                Text("Выберите подключённое устройство").font(.title3)
                                Text("Нет устройств в списке? Откройте «Диагностика» и проверьте libimobiledevice.")
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity, minHeight: 280)
                        }
                    }.padding(.leading, 16)
                }.frame(minWidth: 470)
            }
        }.padding(24)
        .confirmationDialog("Сопрячь этот iPhone с Mac?", isPresented: $showPair) {
            Button("Сопрячь") { model.pair() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Это создаёт доверенное подключение. Подтвердите «Доверять» на экране устройства. Обхода блокировки нет.") }
        .confirmationDialog("Создать новую полную резервную копию?", isPresented: $showBackup) {
            Button("Создать новую копию") { model.createBackup() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Будет записана отдельная копия в выбранную папку. Совместимость с вашим устройством ещё не сертифицирована. Другие копии не изменяются.") }
        .sheet(isPresented: $showEncryption) { EncryptionSheet { password, remember in model.enableEncryption(password: password, remember: remember) } }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).textSelection(.enabled) }
    }
}
@MainActor
struct EncryptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var repeated = ""
    @State private var remember = false
    let submit: (String, Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Включить шифрование копий").font(.title2.bold())
            Text("Настройка изменится на самом iPhone и повлияет также на будущие копии Finder. Без пароля старую зашифрованную копию восстановить нельзя.")
            SecureField("Новый пароль резервной копии", text: $password)
            SecureField("Повторите пароль", text: $repeated)
            Toggle("Сохранить пароль в локальной Связке ключей macOS", isOn: $remember)
            Text("По умолчанию пароль не сохраняется. Он не передаётся в аргументах команд и не пишется в журнал. Подтвердите действие кодом на iPhone.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Отмена", role: .cancel) { password = ""; repeated = ""; dismiss() }
                Spacer()
                Button("Подтверждаю включение") {
                    let value = password; let save = remember
                    password = ""; repeated = ""; dismiss(); submit(value, save)
                }.buttonStyle(.borderedProminent).disabled(password.isEmpty || password != repeated)
            }
        }.padding(28).frame(width: 520)
    }
}
@MainActor
struct BackupBrowserView: View {
    @EnvironmentObject var model: AppModel
    private let presets: [(String, String)] = [
        ("Все файлы", ""), ("Фото и видео в DCIM", "DCIM/"),
        ("Вложения сообщений", "Library/SMS/Attachments"), ("База сообщений", "Library/SMS/sms.db"),
        ("База контактов", "AddressBook.sqlitedb"), ("База звонков", "CallHistory"), ("База календаря", "Calendar.sqlitedb")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Просмотр копии").font(.largeTitle.bold()); Spacer()
                Button { model.openBackup() } label: { Label("Открыть папку копии…", systemImage: "folder") }.disabled(model.busy)
            }
            Text("Оригинал открывается только для чтения. Экспорт сохраняет исходные файлы; это не структурированный экспорт чатов, контактов или календаря.").foregroundStyle(.secondary)
            if let metadata = model.backupMetadata {
                Text("\(metadata.deviceName) · iOS/iPadOS \(metadata.version)").font(.headline)
                Text(model.openedBackup?.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if metadata.encrypted {
                    Label("Копия зашифрована. Просмотр содержимого пока не реализован; доступны метаданные и SHA-256 имеющихся файлов.", systemImage: "lock.fill")
                        .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    HStack {
                        TextField("Поиск по пути или области", text: $model.search).textFieldStyle(.roundedBorder)
                            .onSubmit { model.loadBackup(page: 0) }
                        Button("Найти") { model.loadBackup(page: 0) }
                        Menu("Раздел") {
                            ForEach(presets, id: \.0) { item in Button(item.0) { model.loadBackup(page: 0, search: item.1) } }
                        }
                    }.disabled(model.busy)
                    Table(model.entries, selection: $model.selectedFileID) {
                        TableColumn("Область", value: \.domain).width(min: 130, ideal: 180)
                        TableColumn("Путь", value: \.relativePath)
                        TableColumn("Тип") { Text($0.isFile ? "Файл" : ($0.flags == 2 ? "Папка" : "Ссылка")) }.width(65)
                    }.disabled(model.busy).frame(minHeight: 240)
                    HStack {
                        Button("Назад") { model.loadBackup(page: model.page - 1) }.disabled(model.page == 0)
                        Text("Страница \(model.page + 1) · записей \(model.entries.count)").font(.caption)
                        Button("Далее") { model.loadBackup(page: model.page + 1) }.disabled(model.entries.count < 200)
                        Spacer()
                        Button { model.exportFile() } label: { Label("Экспортировать файл…", systemImage: "square.and.arrow.up") }
                            .disabled(model.selectedEntry?.isFile != true)
                    }.disabled(model.busy)
                }
                HStack {
                    Button("Создать SHA-256 реестр…") { model.createBaseline() }
                    Button("Сверить с прежним реестром…") { model.verifyBaseline() }
                }.disabled(model.busy)
                Text("SHA-256 обнаруживает изменения относительно сохранённого реестра. Он не доказывает, что iOS включила все данные, и не заменяет тест восстановления.").font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Label("Выберите папку с Manifest.db", systemImage: "externaldrive").font(.title2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }.padding(24)
    }
}
@MainActor
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("История резервных копий").font(.largeTitle.bold())
            Text(model.backupRoot?.path ?? "Выберите папку хранения").font(.caption).textSelection(.enabled)
            HStack {
                Button("Выбрать папку…") { model.chooseBackupRoot() }
                Button("Обновить") { model.loadHistory() }.disabled(model.backupRoot == nil)
                if let root = model.backupRoot { Button("Показать в Finder") { NSWorkspace.shared.open(root) } }
            }.disabled(model.busy)
            Text("Частичные и неудачные операции не удаляются. Файлы .partial видны в Finder после ⌘⇧. (Command + Shift + точка).").font(.callout).foregroundStyle(.secondary)
            List(model.history) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(job.startedAt.formatted()).font(.headline); Spacer(); Text("iOS/iPadOS " + job.deviceVersion) }
                    Text(label(job.state))
                    Text(job.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            if model.history.isEmpty { Text("История не прочитана или в выбранной папке нет записей приложения.").foregroundStyle(.secondary) }
        }.padding(24)
    }
    private func label(_ state: String) -> String {
        switch state {
        case "completed-structure-checked": return "Записана; структура проверена. Восстановление не тестировалось."
        case "completed-opaque-unverified-content": return "Записана; содержимое зашифрованного манифеста не проверено."
        case "failed": return "Ошибка. Частичная копия не считается готовой."
        case "cancelled": return "Отменена. Частичная копия не считается готовой."
        case "promotion-not-confirmed": return "Фиксация завершения не подтверждена."
        default: return "Состояние не подтверждено: \(state)"
        }
    }
}
@MainActor
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Диагностика и границы версии").font(.largeTitle.bold())
                HStack {
                    Button("Проверить инструменты") { model.doctor() }
                    Button("Экспортировать отчёт…") { model.exportDiagnostics() }
                }.disabled(model.busy)
                Text("Поддерживаемый профиль операций записи: libimobiledevice 1.4.0. Неизвестная версия останавливает операцию, а не объявляется совместимой.").foregroundStyle(.secondary)
                ForEach(model.tools) { tool in
                    GroupBox(tool.name) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tool.version ?? "Недоступен").font(.headline)
                            if let path = tool.path { Text(path).font(.caption.monospaced()) }
                            if let error = tool.error { Text(error).foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                GroupBox("Чего здесь пока нет") {
                    Text("Восстановление на устройство, расшифровка старых копий, запись файлов на iPhone, управление медиатекой и форматированный экспорт чатов, контактов, звонков и календаря ещё не реализованы. Не считайте эту версию полной заменой iMazing.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("iOS / iPadOS 27") {
                    Text("Успешное обнаружение телефона не доказывает совместимость резервного копирования или восстановления. Здесь отображаются только ответы реальных инструментов. Полный аппаратный протокол приёмки находится в docs/ACCEPTANCE.md.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("Приложение ничего не отправляет на сервер и не устанавливает зависимости автоматически. Установите инструменты согласно README и повторите проверку.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}
