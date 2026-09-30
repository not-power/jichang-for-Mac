import Foundation

@MainActor
final class EditorDraftStore {
    private let url: URL
    private var values: [String: [String: String]]
    init(url: URL) {
        self.url = url
        values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
    }
    func get(_ key: String) -> [String: String]? { values[key] }
    func put(_ key: String, _ value: [String: String]?) {
        values[key] = value
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
        } catch { NSLog("Editor draft could not be saved: %@", error.localizedDescription) }
    }
    func clear() { values = [:]; try? FileManager.default.removeItem(at: url) }
}
