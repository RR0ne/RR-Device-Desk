import Foundation
import DeviceCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
let args = Array(CommandLine.arguments.dropFirst())
do {
    guard let command = args.first else {
        print("""
        RR Device Desk 0.1 - CLI (local; no telemetry)
        doctor
        devices [usb|network]
        inspect <backup-folder>
        files <backup-folder> [literal-search]
        baseline <backup-folder> <new-report.json>
        verify <backup-folder> <report.json>
        export <backup-folder> <fileID> <new-destination-file>
        restore: intentionally unavailable; see docs/COMPATIBILITY.md
        Pairing, encryption changes and backup creation require the macOS GUI confirmation.
        """)
        exit(0)
    }
    switch command {
    case "doctor": try emit(DeviceService().doctor())
    case "devices":
        guard args.count <= 2, let transport = Transport(rawValue: args.count > 1 ? args[1] : "usb") else { throw DeskError.invalid("devices [usb|network]") }
        try emit(DeviceService().devices(transport: transport))
    case "inspect":
        guard args.count == 2 else { throw DeskError.invalid("inspect <backup-folder>") }
        try emit(BackupStore(url: URL(fileURLWithPath: args[1])).metadata)
    case "files":
        guard (2...3).contains(args.count) else { throw DeskError.invalid("files <backup-folder> [search]") }
        try emit(BackupStore(url: URL(fileURLWithPath: args[1])).entries(search: args.count == 3 ? args[2] : ""))
    case "baseline":
        guard args.count == 3 else { throw DeskError.invalid("baseline <backup-folder> <new-report.json>") }
        let root = URL(fileURLWithPath: args[1]), dest = URL(fileURLWithPath: args[2])
        guard !Files.isInside(dest, root: root) else { throw DeskError.invalid("Отчёт должен быть вне исходной копии.") }
        let report = try BackupIntegrity.baseline(at: root)
        try Files.writeNewJSON(report, to: dest)
        print("SHA-256 baseline записан. Это не проверка восстановимости и не подтверждение полноты iPhone.")
    case "verify":
        guard args.count == 3 else { throw DeskError.invalid("verify <backup-folder> <report.json>") }
        let report = try Files.readJSON(IntegrityReport.self, at: URL(fileURLWithPath: args[2]))
        try BackupIntegrity.verify(report, at: URL(fileURLWithPath: args[1])); print("Все перечисленные в baseline файлы совпадают. Восстановимость не проверялась.")
    case "export":
        guard args.count == 4 else { throw DeskError.invalid("export <backup-folder> <fileID> <new-destination-file>") }
        try emit(BackupStore(url: URL(fileURLWithPath: args[1])).export(id: args[2], to: URL(fileURLWithPath: args[3])))
    case "restore": try SafetyPolicy.permitRestore()
    default: throw DeskError.invalid("Неизвестная команда.")
    }
} catch {
    FileHandle.standardError.write(Data(("ERROR: " + error.localizedDescription + "\n").utf8)); exit(1)
}
