import Foundation

enum ConfigurationOutcome: Sendable {
    case ready(GeneratedConfig)
    case failed(String)
}

/// Serializes writes and generation so an older edit cannot replace a newer one.
actor ConfigurationPipeline {
    private var newestRevision = 0

    func process(_ state: AppState, revision: Int, at stateURL: URL) -> ConfigurationOutcome? {
        guard revision > newestRevision else { return nil }
        newestRevision = revision
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            return .failed("保存失败：\(error.localizedDescription)")
        }
        do {
            return .ready(try MihomoConfigGenerator.generate(state))
        } catch {
            return .failed("配置生成失败：\(error.localizedDescription)")
        }
    }
}
