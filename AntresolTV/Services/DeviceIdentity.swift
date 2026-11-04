import AntresolKit
import Foundation
import UIKit

/// The identity this installation registers with the server (`device` in `/api/auth/token`).
struct DeviceIdentity {
    private static let idKey = "device.id"

    let info: DeviceInfo

    init(defaults: UserDefaults = .standard) {
        let id: String
        if let stored = defaults.string(forKey: Self.idKey), DeviceInfo.isValidID(stored) {
            id = stored
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: Self.idKey)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        info = DeviceInfo(id: id, name: UIDevice.current.name, model: Self.modelIdentifier, version: version)
    }

    /// Hardware model such as "AppleTV14,1".
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
