import Foundation

/// Battery levels of connected Bluetooth devices. macOS has no public API for this, but `system_profiler`
/// (part of macOS) reports it, in about 0.15 s, so it is read in the background when the menu opens.
enum BluetoothBattery {
    /// Maps a Bluetooth address such as "54:10:4F:CB:9D:DF" to a battery percentage, for connected devices only.
    static func fetch(completion: @escaping ([String: Int]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let levels = read()
            DispatchQueue.main.async { completion(levels) }
        }
    }

    private static func read() -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }

        var levels: [String: Int] = [:]
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for case let info as [String: Any] in entry.values {
                    guard let address = info["device_address"] as? String else { continue }
                    // Single-battery devices report "Main"; earbuds report left and right. Show the lower one.
                    let keys = ["device_batteryLevelMain", "device_batteryLevelLeft", "device_batteryLevelRight"]
                    if let level = keys.compactMap({ percent(info[$0]) }).min() {
                        levels[address.uppercased()] = level
                    }
                }
            }
        }
        return levels
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        return Int(text.filter(\.isNumber))
    }
}
