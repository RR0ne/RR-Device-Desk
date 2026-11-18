// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "DeviceCore", targets: ["DeviceCore"]),
    .executable(name: "rrdevice", targets: ["DeviceCLI"])
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "DeviceCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "DeviceCLI", dependencies: ["DeviceCore"]),
    .testTarget(name: "DeviceCoreTests", dependencies: ["DeviceCore", "CSQLite"])
]
#if os(Linux)
targets.append(.systemLibrary(name: "COpenSSL", pkgConfig: "openssl", providers: [.apt(["libssl-dev"])]))
targets[1] = .target(name: "DeviceCore", dependencies: ["CSQLite", "COpenSSL"])
#endif
#if os(macOS)
products.append(.executable(name: "RRDeviceDesk", targets: ["RRDeviceDesk"]))
products.append(.executable(name: "rrdeviceicons", targets: ["RRDeviceIcons"]))
targets.append(.executableTarget(name: "RRDeviceIcons"))
targets.append(.executableTarget(name: "RRDeviceDesk", dependencies: ["DeviceCore"],
    linkerSettings: [.linkedFramework("Security")]))
#endif
let package = Package(name: "RRDeviceDesk", platforms: [.macOS(.v13)], products: products, targets: targets)
