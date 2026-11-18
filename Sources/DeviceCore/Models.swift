import Foundation
import CoreFoundation

public enum DeskError: Error, LocalizedError, Equatable {
    case invalid(String), unavailable(String), io(String), command(String), cancelled, timeout, busy
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .io(let s), .command(let s): return s
        case .cancelled: return "Операция отменена. Незавершённые файлы сохранены отдельно."
        case .timeout: return "Время ожидания истекло. Успех операции не подтверждён."
        case .busy: return "Другая операция использует эту папку или устройство."
        }
    }
}

public enum Transport: String, Codable, CaseIterable, Sendable {
    case usb, network
    public var title: String { self == .usb ? "USB" : "Wi-Fi" }
}
public struct Device: Identifiable, Codable, Hashable, Sendable {
    public let udid: String
    public let transport: Transport
    public var id: String { "\(udid):\(transport.rawValue)" }
    public init(udid: String, transport: Transport) throws {
        guard Self.validUDID(udid) else { throw DeskError.invalid("Некорректный идентификатор устройства.") }
        self.udid = udid; self.transport = transport
    }
    private enum CodingKeys: String, CodingKey { case udid, transport }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(udid: values.decode(String.self, forKey: .udid),
                      transport: values.decode(Transport.self, forKey: .transport))
    }
    public static func validUDID(_ s: String) -> Bool {
        s.range(of: "^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})\\z", options: .regularExpression) != nil
    }
}
public struct DeviceDetails: Sendable {
    public let name: String
    public let product: String
    public let version: String
    public let build: String
    public let encryption: Bool?
    public let usedBytes: UInt64?
    public let warnings: [String]
    public init(name: String, product: String, version: String, build: String, encryption: Bool?, usedBytes: UInt64?, warnings: [String] = []) {
        self.name = name; self.product = product; self.version = version; self.build = build
        self.encryption = encryption; self.usedBytes = usedBytes; self.warnings = warnings
    }
}
public enum Plists {
    public static func object(_ data: Data) throws -> Any {
        guard data.count <= 32 * 1024 * 1024 else { throw DeskError.invalid("Слишком большой plist; обработка остановлена.") }
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    public static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let d = try object(data) as? [String: Any] else { throw DeskError.invalid("Ожидался словарь plist.") }
        return d
    }
    public static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    public static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
              number.doubleValue.isFinite, number.doubleValue < Double(UInt64.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.uint64Value
    }
}

public enum SafetyPolicy {
    public static func requiredSpace(usedBytes: UInt64?) throws -> UInt64 {
        guard let used = usedBytes else { throw DeskError.unavailable("Объём данных устройства неизвестен. Копирование не запущено.") }
        let (estimate, overflow) = used.addingReportingOverflow(used / 10)
        let (total, overflow2) = estimate.addingReportingOverflow(1024 * 1024 * 1024)
        guard !overflow && !overflow2 else { throw DeskError.invalid("Недопустимый объём данных.") }
        return total
    }
    public static func checkSpace(free: UInt64, usedBytes: UInt64?) throws {
        let required = try requiredSpace(usedBytes: usedBytes)
        guard free >= required else { throw DeskError.unavailable("Недостаточно места: нужно не менее \(required) байт, доступно \(free). Оценка консервативная, это не точный размер копии.") }
    }
    /// A deliberate release gate, not a claim that restore is impossible.
    public static func permitRestore() throws {
        throw DeskError.unavailable("Восстановление в версии 0.1 не реализовано и заблокировано до аппаратной проверки. Особенно опасно непроверенное восстановление на iOS 27.")
    }
}
