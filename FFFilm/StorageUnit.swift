import Foundation

/// Display units only: catalog capacities and engine results remain decimal GB.
enum StorageUnit: String, CaseIterable, Identifiable {
    case decimal, binary
    static let preferenceKey = "fffilm.storage-unit"
    var id: String { rawValue }
    var symbol: String { self == .decimal ? "GB" : "GiB" }
    var largeSymbol: String { self == .decimal ? "TB" : "TiB" }
    var radix: Double { self == .decimal ? 1000 : 1024 }
    var title: LocalizedStringResource {
        self == .decimal ? "settings.decimalUnit" : "settings.binaryUnit"
    }
    func converted(decimalGB: Double) -> Double {
        self == .decimal ? decimalGB : decimalGB * 1_000_000_000 / 1_073_741_824
    }
}
