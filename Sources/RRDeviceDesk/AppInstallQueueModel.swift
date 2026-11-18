import DeviceCore
import Foundation

private enum InstallConnectionError: Error {
    case disconnected
    case checkFailed(String)
}

@MainActor
extension AppModel {
    func canQueueInstallation(_ apps: [SavedApp]) -> Bool {
        guard let appDevice, !busy || installQueue.attempt != nil else { return false }
        guard installQueue.hasPendingWork else { return !apps.isEmpty }
        let existing = Set(installQueue.entries.map { $0.app.bundleID })
        return installQueue.device == appDevice && apps.contains { !existing.contains($0.bundleID) }
    }

    func installSavedApps(_ apps: [SavedApp], on device: Device) {
        guard !apps.isEmpty, !busy || installQueue.attempt != nil else { return }
        guard Set(apps.map(\.bundleID)).count == apps.count else {
            errorMessage = "Выберите по одному IPA для каждого приложения."
            return
        }
        errorMessage = nil
        installQueue.enqueue(apps, on: device)
        runNextInstallation()
    }

    func pauseInstallation() {
        guard installQueue.hasPendingWork else { return }
        installQueue.pauseReason = "Очередь на паузе."
        status = installQueue.attempt == nil ? "Очередь на паузе." : "Очередь остановится после текущей установки."
    }

    func resumeInstallation() {
        installQueue.pauseReason = nil
        if installQueue.attempt != nil, let active = installQueue.running {
            status = "Устанавливаем «\(active.app.name)»"
        }
        runNextInstallation()
    }

    func retryInstallation(_ id: String) {
        guard !busy || installQueue.attempt != nil else { return }
        installQueue.retry(id)
        runNextInstallation()
    }

    func removeWaitingInstallation(_ id: String) {
        installQueue.removeWaiting(id)
        if !installQueue.hasPendingWork { advanceInstallation() }
    }

    private func runNextInstallation() {
        guard !busy, let device = installQueue.device, let job = installQueue.startNext() else { return }
        let attempt = job.attempt
        perform("Устанавливаем «\(job.app.name)»", work: { [weak self] token in
            let service = DeviceService()
            let devices: [Device]
            do {
                devices = try service.devices(transport: device.transport, token: token)
            } catch {
                throw InstallConnectionError.checkFailed(error.localizedDescription)
            }
            guard devices.contains(device) else { throw InstallConnectionError.disconnected }
            do {
                return try service.installApp(job.app, from: Self.makeLibrary(), on: device, confirmed: true,
                                              acceptMatchingInstalledApp: true, token: token) { [weak self] progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.installQueue.update(progress, attempt: attempt)
                    }
                }
            } catch {
                if (try? service.devices(transport: device.transport, token: token).contains(device)) == false {
                    throw InstallConnectionError.disconnected
                }
                throw error
            }
        }, failure: { error in
            switch error {
            case InstallConnectionError.disconnected:
                self.installQueue.pauseReason = "Подключите iPhone …\(device.udid.suffix(6)) и нажмите «Продолжить»."
                self.installQueue.finish(.waiting, attempt: attempt)
            case InstallConnectionError.checkFailed(let message):
                self.installQueue.pauseReason = "Не удалось проверить подключение iPhone. \(message)"
                self.installQueue.finish(.waiting, attempt: attempt)
            default:
                self.installQueue.finish(.failed(error.localizedDescription), attempt: attempt)
                if (error as? DeskError) == .timeout, self.installQueue.hasPendingWork {
                    self.installQueue.pauseReason = "iPhone не подтвердил завершение. Проверьте телефон перед продолжением."
                }
            }
            self.advanceInstallation()
        }) { result in
            if self.appListLoaded, self.appDevice == device {
                let app = job.app
                if result == .installed || !self.appsOnDevice.contains(where: { $0.bundleID == app.bundleID }) {
                    self.appsOnDevice.removeAll { $0.bundleID == app.bundleID }
                    self.appsOnDevice.append(InstalledApp(bundleID: app.bundleID, name: app.name, version: app.version, build: app.build))
                    self.appsOnDevice.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }
            self.installQueue.finish(.finished(result), attempt: attempt)
            self.advanceInstallation()
        }
    }

    private func advanceInstallation() {
        guard installQueue.hasPendingWork else {
            installQueue.pauseReason = nil
            let failed = installQueue.entries.contains { entry in
                if case .failed = entry.state { return true }
                return false
            }
            if installQueue.entries.isEmpty {
                status = "Очередь установки пуста."
            } else {
                status = failed ? "Очередь завершена с ошибками." : "Очередь установки завершена."
            }
            return
        }
        if let reason = installQueue.pauseReason { status = reason }
        runNextInstallation()
    }
}
