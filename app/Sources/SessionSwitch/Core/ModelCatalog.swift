import Foundation

/// A Claude model as offered by the CLI's `/model` slash command.
struct ClaudeModel: Equatable, Identifiable {
    let id: String
    let alias: String
    let name: String
    let efforts: [String]
}

/// Static catalog of models supported for v1 (dynamic refresh deferred to v1.1
/// per Global Constraints).
enum ModelCatalog {
    static let defaults: [ClaudeModel] = [
        ClaudeModel(
            id: "claude-fable-5",
            alias: "fable",
            name: "Fable 5",
            efforts: ["low", "medium", "high", "max"]
        ),
        ClaudeModel(
            id: "claude-opus-4-8",
            alias: "opus",
            name: "Opus 4.8",
            efforts: ["low", "medium", "high"]
        ),
        ClaudeModel(
            id: "claude-sonnet-5",
            alias: "sonnet",
            name: "Sonnet 5",
            efforts: ["low", "medium", "high"]
        ),
        ClaudeModel(
            id: "claude-haiku-4-5",
            alias: "haiku",
            name: "Haiku 4.5",
            efforts: []
        ),
    ]

    /// Resolves a model by exact id, alias, or id-prefix (to tolerate dated
    /// ids such as `claude-haiku-4-5-20251001` seen in jsonl session logs).
    ///
    /// Prefix matching requires the catalog id to be followed by a `-` in the
    /// candidate string (or to match exactly), so `claude-opus-4` does not
    /// spuriously match `claude-opus-4-8`.
    static func model(idOrAlias: String) -> ClaudeModel? {
        if let exact = defaults.first(where: { $0.id == idOrAlias || $0.alias == idOrAlias }) {
            return exact
        }
        return defaults.first { model in
            guard idOrAlias.hasPrefix(model.id) else { return false }
            let suffixStart = idOrAlias.index(idOrAlias.startIndex, offsetBy: model.id.count)
            return idOrAlias[suffixStart...].hasPrefix("-")
        }
    }
}
