import DeviceCore
import OSLog
import SwiftUI

@MainActor
final class StoreSessionModel: ObservableObject {
    enum Step { case preparing, credentials, connecting, verification, failed }

    @Published private(set) var account: StoreAccount? {
        didSet { if oldValue?.email != account?.email { clearPurchases() } }
    }
    @Published private(set) var purchases: [StoreApp]?
    @Published private(set) var purchaseError: String?
    @Published private(set) var loadingPurchases = false
    @Published private(set) var checking = false
    @Published private(set) var step: Step = .preparing
    @Published private(set) var error: String?
    @Published private(set) var verificationStatus: Int?
    @Published var showingLogin = false
    private var attempt: LoginInput?
    private var purchaseRequest: CancellationToken?
    private let logger = Logger(subsystem: "local.rrdevicedesk.app", category: "AppleAccount")

    nonisolated static var engine: URL? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RRStoreEngine")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }

    func refresh() async {
        guard !checking, let engine = Self.engine else { return }
        checking = true
        defer { checking = false }
        do {
            account = try await Task.detached { try StoreAuthentication(executable: engine).account() }.value
            error = nil
            loadPurchases()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadPurchases(force: Bool = false) {
        guard account != nil, let engine = Self.engine, !loadingPurchases, force || purchases == nil else { return }
        loadingPurchases = true
        purchaseError = nil
        let token = CancellationToken()
        purchaseRequest = token
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AppModel.makeLibrary().purchasedApps(tool: engine, cancellation: token) }
            }.value
            guard let self, self.purchaseRequest === token else { return }
            self.loadingPurchases = false
            self.purchaseRequest = nil
            switch result {
            case .success(let apps): self.purchases = apps
            case .failure(let error): self.purchaseError = error.localizedDescription
            }
        }
    }

    private func clearPurchases() {
        purchaseRequest?.cancel()
        purchaseRequest = nil
        purchases = nil
        purchaseError = nil
        loadingPurchases = false
    }

    func presentLogin() {
        showingLogin = true
        startLogin()
    }

    func startLogin() {
        guard let engine = Self.engine, attempt == nil else { return }
        let input = LoginInput()
        attempt = input
        error = nil
        verificationStatus = nil
        step = .preparing
        Task { [self] in
            do {
                let account = try await Task.detached { [weak self] in
                    try StoreAuthentication(executable: engine).logIn(cancellation: input.cancellation, credentials: {
                        Task { @MainActor [weak self] in
                            guard self?.attempt === input else { return }
                            self?.step = .credentials
                        }
                        return try input.take(\.credentials)
                    }, verificationCode: { status in
                        Task { @MainActor [weak self] in
                            guard let self, self.attempt === input else { return }
                            self.verificationStatus = status
                            self.step = .verification
                            if let status {
                                self.logger.notice("Общий ответ App Store об ошибке входа (HTTP \(status, privacy: .public)). Отправка кода не подтверждена.")
                            }
                        }
                        return try input.take(\.code)
                    })
                }.value
                guard attempt === input else { return }
                attempt = nil
                self.account = account
                loadPurchases()
                showingLogin = false
            } catch {
                guard attempt === input else { return }
                attempt = nil
                let deskError = error as? DeskError
                let message = self.step == .verification && deskError == .timeout
                    ? self.missingCodeMessage
                    : deskError?.localizedDescription ?? "Не удалось запустить вход в Apple Account."
                self.step = .failed
                self.error = message
                logger.error("\(message, privacy: .public)")
            }
        }
    }

    func submit(appleID: String, password: String) {
        guard step == .credentials, let attempt else { return }
        step = .connecting
        attempt.submit((appleID, password), for: \.credentials)
    }

    func submit(code: String) {
        guard step == .verification, let attempt, StoreAuthentication.validVerificationCode(code) else { return }
        step = .connecting
        attempt.submit(code, for: \.code)
    }

    func codeDidNotArrive() {
        guard step == .verification, let attempt else { return }
        attempt.cancel()
        self.attempt = nil
        step = .failed
        error = missingCodeMessage
        logger.error("\(self.missingCodeMessage, privacy: .public)")
    }

    private var missingCodeMessage: String {
        if let verificationStatus {
            return "App Store вернул общий ответ об ошибке входа (HTTP \(verificationStatus)). Отправка кода не подтверждена."
        }
        return "Подтверждение входа прервано на этапе ввода кода."
    }

    func closeLogin() {
        if let attempt {
            attempt.cancel()
            self.attempt = nil
        }
        step = .preparing
        error = nil
        verificationStatus = nil
    }

    func signOut() async {
        guard !checking, let engine = Self.engine else { return }
        checking = true
        defer { checking = false }
        do {
            try await Task.detached { try StoreAuthentication(executable: engine).signOut() }.value
            account = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private final class LoginInput: @unchecked Sendable {
    let cancellation = CancellationToken()
    private let condition = NSCondition()
    fileprivate var credentials: (appleID: String, password: String)?
    fileprivate var code: String?

    func submit<Value>(_ value: Value, for key: ReferenceWritableKeyPath<LoginInput, Value?>) {
        condition.lock()
        self[keyPath: key] = value
        condition.signal()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancellation.cancel()
        credentials = nil
        code = nil
        condition.signal()
        condition.unlock()
    }

    func take<Value>(_ key: ReferenceWritableKeyPath<LoginInput, Value?>) throws -> Value {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(180)
        while self[keyPath: key] == nil {
            try cancellation.check()
            guard condition.wait(until: deadline) else { throw DeskError.timeout }
        }
        try cancellation.check()
        guard let result = self[keyPath: key] else { throw DeskError.cancelled }
        self[keyPath: key] = nil
        return result
    }
}

struct StoreLoginView: View {
    @ObservedObject var session: StoreSessionModel
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Вход в Apple Account").font(.title2.bold())
            switch session.step {
            case .preparing:
                HStack { ProgressView().controlSize(.small); Text("Проверяю готовность входа Apple…") }
            case .credentials:
                TextField("Apple Account: почта или телефон", text: $appleID)
                SecureField("Пароль Apple Account", text: $password).onSubmit(logIn)
            case .connecting:
                HStack { ProgressView().controlSize(.small); Text("Подключение к Apple…") }
            case .verification:
                if session.verificationStatus != nil {
                    Text("App Store не подтвердил отправку. Если на доверенном устройстве появился код, введите его.")
                } else {
                    Text("Введите шестизначный код с доверенного устройства Apple.")
                }
                SecureField("Код подтверждения", text: $code).onSubmit(verify)
            case .failed:
                EmptyView()
            }
            if let error = session.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { session.showingLogin = false }.keyboardShortcut(.cancelAction)
                if session.step == .credentials {
                    Button("Войти", action: logIn).keyboardShortcut(.defaultAction)
                        .disabled(appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                } else if session.step == .verification {
                    Button("Код не пришёл", action: session.codeDidNotArrive)
                    Button("Подтвердить", action: verify).keyboardShortcut(.defaultAction)
                        .disabled(!StoreAuthentication.validVerificationCode(code))
                } else if session.step == .failed {
                    Button("Повторить", action: session.startLogin).keyboardShortcut(.defaultAction)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 410, alignment: .leading)
        .padding(24)
    }

    private func logIn() {
        let identifier = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !password.isEmpty else { return }
        session.submit(appleID: identifier, password: password)
        password = ""
    }

    private func verify() {
        session.submit(code: code)
        code = ""
    }
}
