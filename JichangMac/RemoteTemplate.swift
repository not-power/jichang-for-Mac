import Foundation
import Yams

struct TemplateDownload: Sendable {
    let name: String
    let fileName: String
    let rawYaml: String
    let remoteURL: String
    let refreshedAt: Int64
    let existingTemplateID: String?
    let previousRawYaml: String?
    let changedKeys: [String]
    let previousRoot: [String: JSONValue]

    var changed: Bool { previousRawYaml != rawYaml }
}

enum RemoteTemplateError: LocalizedError {
    case invalidURL, tooLarge, empty, html, invalidEncoding, invalidRoot, notMihomo, duplicateName, stalePreview

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTP 或 HTTPS 模板地址。"
        case .tooLarge: "模板超过 25 MiB 限制。"
        case .empty: "远程模板内容为空。"
        case .html: "服务器返回的是网页，不是 YAML 模板。"
        case .invalidEncoding: "模板不是 UTF-8 文本。"
        case .invalidRoot: "模板根节点必须是 YAML 配置对象。"
        case .notMihomo: "没有识别到 Mihomo 配置字段。"
        case .duplicateName: "模板名称已存在，请换一个名称。"
        case .stalePreview: "模板在预览后已改变，请重新刷新。"
        }
    }
}

enum RemoteTemplateService {
    static let maximumBytes = 25 * 1024 * 1024
    private static let mihomoKeys: Set<String> = [
        "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "allow-lan", "mode",
        "log-level", "external-controller", "dns", "proxies", "proxy-groups", "proxy-providers",
        "rule-providers", "rules", "sub-rules", "tun", "sniffer", "profile"
    ]

    static func fetch(url input: String, name: String?, replacing existing: ConfigTemplate?) async throws -> TemplateDownload {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw RemoteTemplateError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("鸡场/0.11.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await BoundedTemplateDownload(limit: maximumBytes).start(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ServiceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard data.count <= maximumBytes else { throw RemoteTemplateError.tooLarge }
        guard !data.isEmpty else { throw RemoteTemplateError.empty }
        let mime = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard !mime.contains("text/html") else { throw RemoteTemplateError.html }
        guard var yaml = String(data: data, encoding: .utf8) else { throw RemoteTemplateError.invalidEncoding }
        if yaml.hasPrefix("\u{FEFF}") { yaml.removeFirst() }
        let leading = yaml.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !leading.isEmpty else { throw RemoteTemplateError.empty }
        guard !leading.hasPrefix("<!doctype html"), !leading.hasPrefix("<html") else { throw RemoteTemplateError.html }
        let suggestedFileName = response.suggestedFilename?.isEmpty == false ? response.suggestedFilename! : url.lastPathComponent
        let safeName = URL(fileURLWithPath: suggestedFileName).lastPathComponent
        let fileName = safeName.lowercased().hasSuffix(".yaml") || safeName.lowercased().hasSuffix(".yml")
            ? safeName : "template.yaml"
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = !cleanedName.isEmpty ? cleanedName : existing?.name ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let inspection = try await inspect(yaml, previous: existing?.rawYaml)
        return TemplateDownload(name: resolvedName, fileName: fileName, rawYaml: yaml,
                                remoteURL: url.absoluteString, refreshedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                existingTemplateID: existing?.id, previousRawYaml: existing?.rawYaml,
                                changedKeys: inspection.keys, previousRoot: inspection.previousRoot)
    }

    @concurrent
    private static func inspect(_ yaml: String, previous: String?) async throws -> (keys: [String], previousRoot: [String: JSONValue]) {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else { throw RemoteTemplateError.invalidRoot }
        guard !mihomoKeys.isDisjoint(with: root.keys) else { throw RemoteTemplateError.notMihomo }
        guard let previous, let old = try? Yams.load(yaml: previous) as? [String: Any] else { return (root.keys.sorted(), [:]) }
        let newValues = root.mapValues(JSONValue.init(foundationValue:))
        let oldValues = old.mapValues(JSONValue.init(foundationValue:))
        let changed = Set(root.keys).union(old.keys).filter { key in
            newValues[key] != oldValues[key]
        }.sorted()
        return (changed, oldValues)
    }
}

/// URLSession delegate enforces the limit while bytes arrive, even without Content-Length.
private final class BoundedTemplateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var buffer = Data()
    private var response: URLResponse?
    private var finished = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(limit: Int) { self.limit = limit }

    func start(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { cancel() }
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response
        lock.unlock()
        if response.expectedContentLength > Int64(limit) {
            finish(.failure(RemoteTemplateError.tooLarge))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceedsLimit = buffer.count > limit - data.count
        if !exceedsLimit { buffer.append(data) }
        lock.unlock()
        if exceedsLimit {
            dataTask.cancel()
            finish(.failure(RemoteTemplateError.tooLarge))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let output = buffer
        let response = self.response
        lock.unlock()
        if let response { finish(.success((output, response))) }
        else { finish(.failure(RemoteTemplateError.empty)) }
    }
}
