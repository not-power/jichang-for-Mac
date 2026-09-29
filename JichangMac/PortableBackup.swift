import Foundation
import ZIPFoundation

struct BackupManifest: Codable {
    let format: String
    let version: Int
}

struct PortableBackupContents {
    let stateData: Data
    let cacheFiles: [String: Data]
}

enum PortableBackup {
    static let fileExtension = "jichangbackup"
    private static let format = "jichang-backup"
    private static let version = 1
    private static let maximumUncompressedBytes = 256 * 1024 * 1024

    static func make(stateData: Data, cacheRoot: URL) throws -> Data {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("jichang-backup-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("jichang-\(UUID().uuidString).zip")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archiveURL)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(BackupManifest(format: format, version: version)).write(to: staging.appendingPathComponent("manifest.json"))
        try stateData.write(to: staging.appendingPathComponent("state.json"), options: .atomic)
        if fileManager.fileExists(atPath: cacheRoot.path) {
            let destination = staging.appendingPathComponent("rule-providers", isDirectory: true)
            try fileManager.copyItem(at: cacheRoot, to: destination)
        }

        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for file in fileManager.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [] {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let rootComponents = staging.standardizedFileURL.pathComponents
                let fileComponents = file.standardizedFileURL.pathComponents
                let path = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
                guard isSafePath(path) else { throw BackupError.invalidPath }
                try archive.addEntry(with: path, fileURL: file, compressionMethod: .deflate)
            }
        }
        return try Data(contentsOf: archiveURL)
    }

    static func read(_ archiveData: Data) throws -> PortableBackupContents {
        let fileManager = FileManager.default
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("jichang-import-\(UUID().uuidString).zip")
        try archiveData.write(to: archiveURL, options: .atomic)
        defer { try? fileManager.removeItem(at: archiveURL) }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var manifestData: Data?
        var stateData: Data?
        var caches: [String: Data] = [:]
        var totalBytes = 0
        for entry in archive {
            guard entry.type == .file, isSafePath(entry.path) else { throw BackupError.invalidPath }
            var data = Data()
            _ = try archive.extract(entry) { chunk in
                totalBytes += chunk.count
                guard totalBytes <= maximumUncompressedBytes else { throw BackupError.tooLarge }
                data.append(chunk)
            }
            if entry.path == "manifest.json" { manifestData = data }
            else if entry.path == "state.json" { stateData = data }
            else if entry.path.hasPrefix("rule-providers/") {
                let relative = String(entry.path.dropFirst("rule-providers/".count))
                guard isSafePath(relative) else { throw BackupError.invalidPath }
                caches[relative] = data
            }
        }
        guard let manifestData, let stateData else { throw BackupError.missingContent }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
        guard manifest.format == format else { throw BackupError.invalidFormat }
        guard manifest.version == version else { throw BackupError.unsupportedVersion(manifest.version) }
        _ = try JSONDecoder().decode(AppState.self, from: stateData)
        return PortableBackupContents(stateData: stateData, cacheFiles: caches)
    }

    static func restoreCaches(_ files: [String: Data], to cacheRoot: URL) throws {
        let fileManager = FileManager.default
        let parent = cacheRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent("rule-providers-import-\(UUID().uuidString)", isDirectory: true)
        let previous = parent.appendingPathComponent("rule-providers-old-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }
        for (path, data) in files {
            guard isSafePath(path) else { throw BackupError.invalidPath }
            let output = stage.appendingPathComponent(path)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
        }
        let hadOldCache = fileManager.fileExists(atPath: cacheRoot.path)
        if hadOldCache { try fileManager.moveItem(at: cacheRoot, to: previous) }
        do {
            try fileManager.moveItem(at: stage, to: cacheRoot)
            if hadOldCache { try fileManager.removeItem(at: previous) }
        } catch {
            if hadOldCache, !fileManager.fileExists(atPath: cacheRoot.path) {
                try? fileManager.moveItem(at: previous, to: cacheRoot)
            }
            throw error
        }
    }

    private static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum BackupError: LocalizedError {
    case invalidPath
    case tooLarge
    case missingContent
    case invalidFormat
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPath: "备份包含无效文件路径。"
        case .tooLarge: "备份解压后超过 256 MB。"
        case .missingContent: "备份缺少状态数据或清单。"
        case .invalidFormat: "这不是鸡场设备备份。"
        case .unsupportedVersion(let version): "不支持的鸡场备份版本：\(version)。"
        }
    }
}
