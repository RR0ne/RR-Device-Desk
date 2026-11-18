import DeviceCore
import SwiftUI

@MainActor
struct AppInstallQueueView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var artwork: AppArtworkCache

    private var queue: AppInstallQueue { model.installQueue }
    private var processed: [AppInstallQueue.Entry] {
        queue.entries.filter { entry in
            switch entry.state {
            case .finished, .failed: return true
            case .waiting, .running: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let reason = queue.pauseReason, queue.hasPendingWork {
                        let message = queue.attempt == nil ? reason : "Пауза после текущей установки."
                        Label(message, systemImage: "pause.circle").foregroundStyle(.orange).font(.callout)
                    }
                    if let active = queue.running {
                        AppInstallQueueRow(entry: active, artwork: artwork) { EmptyView() }
                        if queue.entries.count > 1 { Divider() }
                    }
                    let waiting = queue.waiting
                    let completed = processed
                    let count = waiting.count + completed.count
                    if count > 0 {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(waiting.enumerated()), id: \.element.id) { index, entry in
                                    AppInstallQueueRow(entry: entry, artwork: artwork) {
                                        waitingActions(entry.id, index: index, count: waiting.count)
                                    }
                                }
                                ForEach(completed) { entry in
                                    AppInstallQueueRow(entry: entry, artwork: artwork) {
                                        if case .failed = entry.state {
                                            Button("Повторить") { model.retryInstallation(entry.id) }
                                        }
                                    }
                                }
                            }.padding(.trailing, 8)
                        }.frame(height: CGFloat(min(count, 3)) * 42)
                    }
                }.padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Очередь установки", systemImage: "list.bullet.rectangle").font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let device = queue.device {
                Text("iPhone …\(device.udid.suffix(6))").foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(processed.count), total: Double(max(1, queue.entries.count)))
                .frame(width: 64).accessibilityHidden(true)
            Text("Обработано \(processed.count) из \(queue.entries.count)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            if queue.hasPendingWork {
                if queue.pauseReason == nil {
                    Button("Пауза после текущего", action: model.pauseInstallation)
                } else {
                    Button("Продолжить", action: model.resumeInstallation)
                }
            } else {
                Button("Очистить") { model.installQueue = AppInstallQueue() }
            }
        }
    }

    private func waitingActions(_ id: String, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Button { model.installQueue.moveWaiting(id, to: 0) } label: {
                Label("Установить следующим", systemImage: "arrow.up.to.line")
            }.disabled(index == 0).help("Установить следующим")
            Button { model.installQueue.moveWaiting(id, to: index - 1) } label: {
                Label("Выше в очереди", systemImage: "chevron.up")
            }.disabled(index == 0).help("Выше в очереди")
            Button { model.installQueue.moveWaiting(id, to: index + 1) } label: {
                Label("Ниже в очереди", systemImage: "chevron.down")
            }.disabled(index == count - 1).help("Ниже в очереди")
            Button { model.removeWaitingInstallation(id) } label: {
                Label("Убрать из очереди", systemImage: "xmark.circle")
            }.help("Убрать из очереди")
        }.labelStyle(.iconOnly).buttonStyle(.borderless)
    }
}

private struct AppInstallQueueRow<Actions: View>: View {
    let entry: AppInstallQueue.Entry
    let artwork: AppArtworkCache
    @ViewBuilder let actions: () -> Actions
    @State private var showError = false

    var body: some View {
        HStack(spacing: 12) {
            AppArtworkRow(name: entry.app.name, cache: artwork, savedID: entry.id, size: 32)
            Text(entry.app.version).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            switch entry.state {
            case .waiting:
                Label("В очереди", systemImage: "clock").foregroundStyle(.secondary)
            case .running(let phase):
                progress(phase)
            case .finished(let result):
                Label(result == .installed ? "Установлено" : "Уже на iPhone", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let reason):
                Button { showError.toggle() } label: {
                    Label("Причина ошибки", systemImage: "exclamationmark.circle")
                }.foregroundStyle(.red).popover(isPresented: $showError) {
                    ScrollView {
                        Text(reason).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 380, height: 125).padding()
                }
            }
            actions()
        }.font(.callout).frame(height: 42)
    }

    @ViewBuilder
    private func progress(_ phase: AppInstallProgress) -> some View {
        switch phase {
        case .checkingPackage: working("Проверяем IPA и iPhone")
        case .sendingPackage: working("Передаём IPA на iPhone")
        case .installing(nil): working("iPhone устанавливает")
        case .installing(let percent?):
            Text("Установка · \(percent)%").monospacedDigit()
            ProgressView(value: Double(percent), total: 100).frame(width: 72)
                .accessibilityLabel("Прогресс установки")
        case .verifyingOnDevice: working("Проверяем установку на iPhone")
        }
    }

    private func working(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
            ProgressView().controlSize(.small)
        }
    }
}
