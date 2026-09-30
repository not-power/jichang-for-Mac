import Foundation

struct SettingField: Sendable {
    enum Kind: Sendable { case text, secret, integer(Int, Int), choice([String]), boolean, lines, yaml, ports }
    let path: String
    let title: String
    let kind: Kind
    init(_ path: String, _ title: String, _ kind: Kind = .text) { self.path = path; self.title = title; self.kind = kind }
    func validate(_ value: JSONValue) -> String? {
        switch kind {
        case .text, .secret: return value.stringValue == nil ? "需要文本。" : nil
        case .integer(let min, let max):
            guard case .integer(let integer) = value, integer >= Int64(min), integer <= Int64(max) else { return "需要 \(min)…\(max) 的整数。" }
        case .boolean: if value.boolValue == nil { return "需要 true 或 false。" }
        case .choice(let options): if !options.contains(value.stringValue ?? "") { return "可选值：\(options.joined(separator: "、"))。" }
        case .lines:
            guard let values = value.arrayValue, values.allSatisfy({ $0.stringValue != nil }) else { return "需要文本列表。" }
        case .yaml: if value.objectValue == nil { return "需要 YAML 对象。" }
        case .ports:
            guard let values = value.arrayValue else { return "需要端口列表。" }
            for port in values {
                if case .integer(let number) = port, (1...65535).contains(number) { continue }
                if let range = port.stringValue {
                    let parts = range.split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start > 0, end <= 65535, start <= end { continue }
                }
                return "端口应为 1…65535，或起止端口范围。"
            }
        }
        return nil
    }
}

enum SettingsCatalog {
    static let sections = ["基础", "DNS", "TUN", "域名嗅探"]
    static let basic: [SettingField] = [
        .init("mixed-port", "混合端口 · 0 表示关闭", .integer(0, 65535)),
        .init("port", "HTTP 端口", .integer(0, 65535)), .init("socks-port", "SOCKS 端口", .integer(0, 65535)),
        .init("allow-lan", "允许局域网连接", .boolean), .init("bind-address", "绑定地址"),
        .init("mode", "运行模式", .choice(["rule", "global", "direct"])),
        .init("log-level", "日志等级", .choice(["silent", "error", "warning", "info", "debug"])),
        .init("ipv6", "IPv6", .boolean), .init("find-process-mode", "进程匹配", .choice(["strict", "always", "off"])),
        .init("tcp-concurrent", "TCP 并发", .boolean), .init("unified-delay", "统一延迟", .boolean),
        .init("external-controller", "控制器地址"), .init("secret", "控制器密钥", .secret), .init("interface-name", "出站接口")
    ]
    static let dns: [SettingField] = [
        .init("dns.enable", "启用 DNS", .boolean), .init("dns.listen", "监听地址"), .init("dns.ipv6", "DNS IPv6", .boolean),
        .init("dns.enhanced-mode", "解析模式", .choice(["fake-ip", "redir-host"])),
        .init("dns.use-hosts", "使用 hosts", .boolean), .init("dns.use-system-hosts", "使用系统 hosts", .boolean),
        .init("dns.default-nameserver", "默认解析服务器", .lines), .init("dns.nameserver", "解析服务器", .lines),
        .init("dns.fallback", "备用解析服务器", .lines), .init("dns.proxy-server-nameserver", "节点域名解析服务器", .lines),
        .init("dns.direct-nameserver", "直连解析服务器", .lines), .init("dns.direct-nameserver-follow-policy", "直连遵循解析策略", .boolean),
        .init("dns.fake-ip-range", "Fake IP IPv4 范围"), .init("dns.fake-ip-range6", "Fake IP IPv6 范围"),
        .init("dns.fake-ip-filter-mode", "Fake IP 过滤模式", .choice(["blacklist", "whitelist", "rule"])),
        .init("dns.fake-ip-filter", "Fake IP 过滤列表", .lines), .init("dns.respect-rules", "DNS 连接遵循分流规则", .boolean),
        .init("dns.nameserver-policy", "域名解析策略 · YAML", .yaml), .init("dns.fallback-filter", "备用解析过滤 · YAML", .yaml),
        .init("dns.proxy-server-nameserver-policy", "节点域名解析策略 · YAML", .yaml)
    ]
    static let tun: [SettingField] = [
        .init("tun.enable", "启用 TUN", .boolean), .init("tun.stack", "协议栈", .choice(["system", "gvisor", "mixed", "mips"])),
        .init("tun.device", "设备 · macOS 使用 utun 名称"), .init("tun.mtu", "MTU", .integer(576, 65535)),
        .init("tun.auto-route", "自动路由", .boolean), .init("tun.auto-detect-interface", "自动检测接口", .boolean),
        .init("tun.dns-hijack", "DNS 劫持", .lines), .init("tun.udp-timeout", "UDP 超时 · 秒", .integer(0, 86400)),
        .init("tun.route-address", "包含的路由地址", .lines), .init("tun.route-exclude-address", "排除的路由地址", .lines)
    ]
    static let sniffer: [SettingField] = [
        .init("sniffer.enable", "启用域名嗅探", .boolean), .init("sniffer.force-dns-mapping", "强制嗅探 DNS 映射", .boolean),
        .init("sniffer.parse-pure-ip", "嗅探纯 IP 流量", .boolean), .init("sniffer.override-destination", "覆盖目标地址", .boolean),
        .init("sniffer.sniff.HTTP.ports", "HTTP 端口 · 每行一个端口或范围", .ports),
        .init("sniffer.sniff.HTTP.override-destination", "HTTP 覆盖目标地址", .boolean),
        .init("sniffer.sniff.TLS.ports", "TLS 端口", .ports), .init("sniffer.sniff.TLS.override-destination", "TLS 覆盖目标地址", .boolean),
        .init("sniffer.sniff.QUIC.ports", "QUIC 端口", .ports), .init("sniffer.sniff.QUIC.override-destination", "QUIC 覆盖目标地址", .boolean),
        .init("sniffer.force-domain", "强制嗅探域名", .lines), .init("sniffer.skip-domain", "跳过嗅探域名", .lines),
        .init("sniffer.skip-src-address", "跳过源地址", .lines), .init("sniffer.skip-dst-address", "跳过目标地址", .lines)
    ]
    static var all: [SettingField] { basic + dns + tun + sniffer }
    static func fields(_ index: Int) -> [SettingField] { [basic, dns, tun, sniffer][index] }
    static func section(_ root: [String: JSONValue], _ index: Int) -> [String: JSONValue] {
        if index == 0 { return root.filter { !ConfigDocument.managed.contains($0.key) && !["dns", "tun", "sniffer"].contains($0.key) } }
        return root[["", "dns", "tun", "sniffer"][index]]?.objectValue ?? [:]
    }
    static func replacingSection(_ overrides: [String: JSONValue], index: Int, values: [String: JSONValue]) -> [String: JSONValue] {
        if index == 0 { return overrides.filter { ["dns", "tun", "sniffer"].contains($0.key) }.merging(values) { _, new in new } }
        var result = overrides
        let key = ["", "dns", "tun", "sniffer"][index]
        result[key] = values.isEmpty ? nil : .object(values)
        return result
    }
}
