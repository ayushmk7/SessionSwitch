import Foundation

/// A saved model+effort shortcut the user can apply to a session.
struct Preset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var modelID: String
    var effort: String?
}

/// `UserDefaults`-backed store for `Preset`s, seeded with three defaults on
/// first run. Isolated per-suite for tests via `UserDefaults(suiteName:)`.
final class PresetStore {
    private static let key = "presets.v1"

    private static let seedDefaults: [Preset] = [
        Preset(id: "deep-work", name: "Deep Work", modelID: "claude-fable-5", effort: "high"),
        Preset(id: "balanced", name: "Balanced", modelID: "claude-sonnet-5", effort: "medium"),
        Preset(id: "cheap-fast", name: "Cheap & Fast", modelID: "claude-haiku-4-5", effort: nil),
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.data(forKey: Self.key) == nil {
            save(Self.seedDefaults)
        }
    }

    var presets: [Preset] {
        guard
            let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([Preset].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func save(_ presets: [Preset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func reset() {
        save(Self.seedDefaults)
    }
}
