import Foundation
import Observation
import Security

// MARK: - Keychain

enum Keychain {
    private static let service = "MQTTClientForMac"
    /// Service name used before the app was renamed. Items stored under it are still found and moved over.
    private static let legacyService = "MQTTExplorer"

    private static func base(_ account: String, service: String = Keychain.service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func setData(_ data: Data?, for account: String) {
        SecItemDelete(base(account) as CFDictionary)
        SecItemDelete(base(account, service: legacyService) as CFDictionary)
        guard let data, !data.isEmpty else { return }
        var add = base(account)
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(_ account: String, service: String) -> Data? {
        var q = base(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func getData(_ account: String) -> Data? {
        if let data = read(account, service: service) { return data }
        if let data = read(account, service: legacyService) {
            setData(data, for: account)   // moves the item to the new service name
            return data
        }
        return nil
    }

    static func set(_ value: String, for account: String) {
        setData(Data(value.utf8), for: account)
    }

    static func get(_ account: String) -> String {
        getData(account).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - Connection profile

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "New connection"
    var host = ""
    var port = 1883
    var useTLS = false

    // TLS
    var serverVerification: ServerVerification = .full
    var minTLS: TLSVersion = .tls12
    var trustOnlyImportedCAs = true
    var serverName = ""
    var alpn = ""
    var hasClientIdentity = false
    var p12FileName = ""
    var hasCustomCA = false
    var caFileName = ""

    // Session
    var username = ""
    var clientID = ConnectionProfile.randomClientID()
    var keepAlive = 60
    var cleanSession = true
    var subscriptionFilters: [String] = ["#", "$SYS/#"]
    var subscriptionQoS = 2

    init() {}

    var p12DataKey: String { "p12-" + id.uuidString }
    var p12PasswordKey: String { "p12pw-" + id.uuidString }
    var caDataKey: String { "ca-" + id.uuidString }

    var subscriptionList: [String] {
        subscriptionFilters
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func randomClientID() -> String {
        "mqttclient-" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    func removeStoredSecrets() {
        Keychain.set("", for: id.uuidString)
        Keychain.setData(nil, for: p12DataKey)
        Keychain.set("", for: p12PasswordKey)
        Keychain.setData(nil, for: caDataKey)
    }

    /// Builds the TLS settings (loads the P12 identity and the CA certificates).
    func tlsSettings() throws -> TLSSettings? {
        guard useTLS else { return nil }
        var s = TLSSettings(host: host)
        s.verification = serverVerification
        s.minVersion = minTLS
        s.serverName = serverName.trimmingCharacters(in: .whitespaces)
        s.alpn = alpn.trimmingCharacters(in: .whitespaces)
        s.trustOnlyImportedCAs = trustOnlyImportedCAs

        if hasClientIdentity {
            guard let data = Keychain.getData(p12DataKey) else {
                throw P12Bundle.LoadError(message: "The P12 file is missing. Please import it again.")
            }
            let bundle = try P12Bundle.load(data: data, password: Keychain.get(p12PasswordKey))
            s.identity = bundle
            s.anchors += bundle.caCertificates
        }
        if hasCustomCA, let data = Keychain.getData(caDataKey) {
            s.anchors += CertificateFile.parse(data)
        }
        return s
    }

    // MARK: Codable (tolerant, with migration of older versions)

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, serverVerification, minTLS, trustOnlyImportedCAs
        case serverName, alpn, hasClientIdentity, p12FileName, hasCustomCA, caFileName
        case username, clientID, keepAlive, cleanSession, subscriptions, subscriptionFilters, subscriptionQoS
        case allowInvalidCertificate, verifyHostname   // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConnectionProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? d.useTLS
        minTLS = try c.decodeIfPresent(TLSVersion.self, forKey: .minTLS) ?? d.minTLS
        trustOnlyImportedCAs = try c.decodeIfPresent(Bool.self, forKey: .trustOnlyImportedCAs) ?? d.trustOnlyImportedCAs
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? d.serverName
        alpn = try c.decodeIfPresent(String.self, forKey: .alpn) ?? d.alpn
        hasClientIdentity = try c.decodeIfPresent(Bool.self, forKey: .hasClientIdentity) ?? d.hasClientIdentity
        p12FileName = try c.decodeIfPresent(String.self, forKey: .p12FileName) ?? d.p12FileName
        hasCustomCA = try c.decodeIfPresent(Bool.self, forKey: .hasCustomCA) ?? d.hasCustomCA
        caFileName = try c.decodeIfPresent(String.self, forKey: .caFileName) ?? d.caFileName
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? d.clientID
        keepAlive = try c.decodeIfPresent(Int.self, forKey: .keepAlive) ?? d.keepAlive
        cleanSession = try c.decodeIfPresent(Bool.self, forKey: .cleanSession) ?? d.cleanSession
        if let list = try c.decodeIfPresent([String].self, forKey: .subscriptionFilters) {
            subscriptionFilters = list
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .subscriptions) {
            // older versions stored a comma separated string (an empty string means "no subscriptions")
            subscriptionFilters = legacy.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            subscriptionFilters = d.subscriptionFilters
        }
        subscriptionQoS = try c.decodeIfPresent(Int.self, forKey: .subscriptionQoS) ?? d.subscriptionQoS

        if let v = try c.decodeIfPresent(ServerVerification.self, forKey: .serverVerification) {
            serverVerification = v
        } else {
            let allowInvalid = try c.decodeIfPresent(Bool.self, forKey: .allowInvalidCertificate) ?? false
            let verifyHost = try c.decodeIfPresent(Bool.self, forKey: .verifyHostname) ?? true
            serverVerification = allowInvalid ? .none : (verifyHost ? .full : .caOnly)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(useTLS, forKey: .useTLS)
        try c.encode(serverVerification, forKey: .serverVerification)
        try c.encode(minTLS, forKey: .minTLS)
        try c.encode(trustOnlyImportedCAs, forKey: .trustOnlyImportedCAs)
        try c.encode(serverName, forKey: .serverName)
        try c.encode(alpn, forKey: .alpn)
        try c.encode(hasClientIdentity, forKey: .hasClientIdentity)
        try c.encode(p12FileName, forKey: .p12FileName)
        try c.encode(hasCustomCA, forKey: .hasCustomCA)
        try c.encode(caFileName, forKey: .caFileName)
        try c.encode(username, forKey: .username)
        try c.encode(clientID, forKey: .clientID)
        try c.encode(keepAlive, forKey: .keepAlive)
        try c.encode(cleanSession, forKey: .cleanSession)
        try c.encode(subscriptionFilters, forKey: .subscriptionFilters)
        try c.encode(subscriptionQoS, forKey: .subscriptionQoS)
    }
}

// MARK: - Profile validation

struct ProfileIssue: Identifiable {
    let isError: Bool
    let message: String
    var id: String { message }
}

extension ConnectionProfile {
    /// Name shown in lists: the given name, otherwise the host.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let h = host.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? "Untitled connection" : h
    }

    var urlPreview: String {
        let h = host.trimmingCharacters(in: .whitespaces)
        return "\(useTLS ? "mqtts" : "mqtt")://\(h.isEmpty ? "…" : h):\(port)"
    }

    /// Checks an MQTT topic filter: `#` only as the last level, `+` only as a whole level.
    static func isValidFilter(_ filter: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, f.utf8.count <= 65_535, !f.contains("\0") else { return false }
        let levels = f.split(separator: "/", omittingEmptySubsequences: false)
        for (i, level) in levels.enumerated() {
            if level.contains("#") && (level != "#" || i != levels.count - 1) { return false }
            if level.contains("+") && level != "+" { return false }
        }
        return true
    }

    var issues: [ProfileIssue] {
        var list: [ProfileIssue] = []
        let h = host.trimmingCharacters(in: .whitespaces)

        if h.isEmpty {
            list.append(ProfileIssue(isError: true, message: "Enter the host name or IP address of the broker."))
        } else if h.contains(" ") || h.contains("/") {
            list.append(ProfileIssue(isError: true, message: "The host must not contain spaces or slashes."))
        }
        if !(1...65_535).contains(port) {
            list.append(ProfileIssue(isError: true, message: "The port must be between 1 and 65535."))
        }
        if clientID.trimmingCharacters(in: .whitespaces).isEmpty && !cleanSession {
            list.append(ProfileIssue(isError: true, message: "A client ID is required when Clean session is off."))
        }
        for f in subscriptionFilters where !ConnectionProfile.isValidFilter(f) {
            list.append(ProfileIssue(isError: true, message: "\"\(f)\" is not a valid topic filter."))
        }
        if subscriptionFilters.isEmpty {
            list.append(ProfileIssue(isError: false,
                                     message: "No subscriptions: you will not receive any messages until you add one."))
        }
        if !useTLS && !username.isEmpty {
            list.append(ProfileIssue(isError: false,
                                     message: "The user name and password are sent unencrypted. Use mqtts:// if the broker supports it."))
        }
        if useTLS && serverVerification == .none {
            list.append(ProfileIssue(isError: false,
                                     message: "The identity of the broker is not verified. Use this for testing only."))
        }
        return list
    }

    var hasErrors: Bool { issues.contains { $0.isError } }
}

// MARK: - Recently published messages

struct PublishedMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var topic: String
    var payload: String
    var qos: Int
    var retain: Bool
}

// MARK: - Payload formatting

enum PayloadFormat: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case text = "Text"
    case json = "JSON"
    case hex = "Hex"
    var id: String { rawValue }
}

extension MQTTMessage {
    var text: String? { String(data: payload, encoding: .utf8) }

    var prettyJSON: String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              t.hasPrefix("{") || t.hasPrefix("["),
              let obj = try? JSONSerialization.jsonObject(with: payload),
              let data = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    var hex: String {
        payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    var numericValue: Double? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return Double(t)
    }

    var preview: String {
        if payload.isEmpty { return "(empty)" }
        if let t = text {
            let flat = t.replacingOccurrences(of: "\n", with: " ")
            return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
        }
        return "<\(payload.count) bytes>"
    }

    func display(_ format: PayloadFormat) -> String {
        switch format {
        case .auto: return prettyJSON ?? text ?? hex
        case .text: return text ?? hex
        case .json: return prettyJSON ?? text ?? hex
        case .hex: return hex
        }
    }
}

// MARK: - Topic tree

@MainActor @Observable
final class TopicNode: Identifiable {
    nonisolated let id: String       // full topic path
    let name: String
    @ObservationIgnored weak var parent: TopicNode?
    var children: [String: TopicNode] = [:]
    var history: [MQTTMessage] = []
    var messageCount = 0
    var descendantMessages = 0
    var descendantTopics = 0

    init(name: String, id: String, parent: TopicNode?) {
        self.name = name
        self.id = id
        self.parent = parent
    }

    var lastMessage: MQTTMessage? { history.last }

    var topicCount: Int { descendantTopics + (history.isEmpty ? 0 : 1) }

    var sortedChildren: [TopicNode] {
        children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func record(_ message: MQTTMessage, maxHistory: Int = 200) {
        if history.isEmpty {
            var p = parent
            while let n = p { n.descendantTopics += 1; p = n.parent }
        }
        history.append(message)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        messageCount += 1
        var p = parent
        while let n = p { n.descendantMessages += 1; p = n.parent }
    }
}

struct TreeItem: Identifiable {
    let node: TopicNode
    let children: [TreeItem]?
    var id: String { node.id }
}

// MARK: - Thread-safe message buffer

final class MessageBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MQTTMessage] = []

    func append(_ m: MQTTMessage) {
        lock.lock()
        if items.count < 100_000 { items.append(m) }
        lock.unlock()
    }

    func drain() -> [MQTTMessage] {
        lock.lock()
        defer { lock.unlock() }
        let r = items
        items.removeAll(keepingCapacity: true)
        return r
    }
}

// MARK: - App state

@MainActor @Observable
final class AppModel {
    enum Status: Equatable {
        case disconnected, connecting, connected
        case failed(String)
        case reconnecting(String)
    }

    var profiles: [ConnectionProfile] = []
    var activeProfileID: UUID?
    var status: Status = .disconnected
    var root = TopicNode(name: "", id: "", parent: nil)
    var selectedTopic: String?
    var filter = ""
    var totalMessages = 0
    var paused = false
    var subscriptions: [String] = []
    var deniedSubscriptions: Set<String> = []
    var recentPublishes: [PublishedMessage] = []

    @ObservationIgnored private var nodes: [String: TopicNode] = [:]
    @ObservationIgnored private var client: MQTTClient?
    @ObservationIgnored private let buffer = MessageBuffer()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var subscriptionQoS = 2

    private static let defaultsKey = "connectionProfiles"

    init() {
        Self.migrateLegacyDefaults()
        loadProfiles()
        if let data = UserDefaults.standard.data(forKey: "recentPublishes"),
           let list = try? JSONDecoder().decode([PublishedMessage].self, from: data) {
            recentPublishes = list
        }
        activeProfileID = profiles.first?.id
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    // MARK: Profiles

    /// Copies profiles and recent messages saved before the rename (best effort).
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard let old = UserDefaults(suiteName: "MQTTExplorer") else { return }
        for key in [defaultsKey, "recentPublishes"] where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return }
        profiles = list
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    var activeProfile: ConnectionProfile? { profiles.first { $0.id == activeProfileID } }

    // MARK: State

    var isConnected: Bool { status == .connected }

    /// True while a connection attempt or an automatic reconnect is in progress.
    var isBusy: Bool {
        switch status {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }

    var statusText: String {
        switch status {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let e): return "Error: \(e)"
        case .reconnecting(let info): return info
        }
    }

    var selectedNode: TopicNode? {
        guard let t = selectedTopic else { return nil }
        return nodes[t]
    }

    var topicCount: Int { root.descendantTopics }

    // MARK: Connection

    func connect() {
        guard activeProfile != nil else { return }
        disconnect()
        clearTree()
        startConnection()
    }

    private func startConnection() {
        guard let p = activeProfile else { return }
        if let problem = p.issues.first(where: { $0.isError }) {
            status = .failed(problem.message)
            return
        }

        let tls: TLSSettings?
        do {
            tls = try p.tlsSettings()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let cfg = MQTTClient.Config(
            host: p.host,
            port: UInt16(clamping: p.port),
            clientID: p.clientID,
            username: p.username,
            password: Keychain.get(p.id.uuidString),
            tls: tls,
            keepAlive: UInt16(clamping: p.keepAlive),
            cleanSession: p.cleanSession
        )
        subscriptions = p.subscriptionList
        subscriptionQoS = min(max(p.subscriptionQoS, 0), 2)
        deniedSubscriptions = []

        let c = MQTTClient(config: cfg)
        let buf = buffer
        c.onMessage = { buf.append($0) }
        c.onSubscriptionResult = { [weak self, weak c] filter, granted in
            Task { @MainActor in
                guard let self, let c, self.client === c else { return }
                if granted { self.deniedSubscriptions.remove(filter) }
                else { self.deniedSubscriptions.insert(filter) }
            }
        }
        c.onState = { [weak self, weak c] state in
            Task { @MainActor in
                guard let self, let c, self.client === c else { return }
                self.apply(state)
            }
        }
        client = c
        status = .connecting
        c.start()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        let c = client
        client = nil
        c?.disconnect()
        if status != .disconnected { status = .disconnected }
    }

    private func apply(_ state: MQTTClient.State) {
        switch state {
        case .connecting:
            status = .connecting
        case .connected:
            status = .connected
            reconnectAttempt = 0
            for f in subscriptions { client?.subscribe(f, qos: subscriptionQoS) }
        case .disconnected(let reason):
            let wasConnected = (status == .connected)
            client = nil
            if wasConnected || reconnectAttempt > 0 {
                scheduleReconnect(reason: reason)
            } else {
                status = reason.map { .failed($0) } ?? .disconnected
            }
        }
    }

    /// Reconnects automatically (2, 4, 8, 16, 30 s ...) after a connection that was working got lost.
    /// The topic tree is kept. "Disconnect" cancels it.
    private func scheduleReconnect(reason: String?) {
        reconnectAttempt += 1
        let delay = min(30, 2 << min(reconnectAttempt - 1, 4))
        let why = reason.map { " (\($0))" } ?? ""
        status = .reconnecting("Connection lost\(why). Reconnecting in \(delay) s…")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.startConnection()
        }
    }

    private func rememberPublish(topic: String, payload: String, qos: Int, retain: Bool) {
        recentPublishes.removeAll {
            $0.topic == topic && $0.payload == payload && $0.qos == qos && $0.retain == retain
        }
        recentPublishes.insert(PublishedMessage(topic: topic, payload: payload, qos: qos, retain: retain), at: 0)
        if recentPublishes.count > 15 { recentPublishes.removeLast(recentPublishes.count - 15) }
        if let data = try? JSONEncoder().encode(recentPublishes) {
            UserDefaults.standard.set(data, forKey: "recentPublishes")
        }
    }

    /// The topic tree with the latest values as pretty printed JSON.
    func exportJSON() -> Data? {
        let iso = ISO8601DateFormatter()

        func build(_ node: TopicNode) -> [String: Any] {
            var out: [String: Any] = [:]
            for child in node.sortedChildren {
                var entry: [String: Any] = [:]
                if let m = child.lastMessage {
                    entry["value"] = m.text ?? m.payload.base64EncodedString()
                    if m.text == nil { entry["encoding"] = "base64" }
                    entry["qos"] = m.qos
                    entry["retained"] = m.retain
                    entry["updated"] = iso.string(from: m.date)
                }
                let sub = build(child)
                if !sub.isEmpty { entry["topics"] = sub }
                out[child.name.isEmpty ? "(empty)" : child.name] = entry
            }
            return out
        }

        return try? JSONSerialization.data(
            withJSONObject: build(root),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Subscriptions

    func addSubscription(_ raw: String) {
        let filter = raw.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty, !subscriptions.contains(filter) else { return }
        subscriptions.append(filter)
        if isConnected { client?.subscribe(filter, qos: subscriptionQoS) }
        persistSubscriptions()
    }

    func removeSubscription(_ filter: String) {
        subscriptions.removeAll { $0 == filter }
        deniedSubscriptions.remove(filter)
        if isConnected { client?.unsubscribe(filter) }
        persistSubscriptions()
    }

    private func persistSubscriptions() {
        if let i = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            profiles[i].subscriptionFilters = subscriptions
        }
    }

    // MARK: Messages

    private func flush() {
        let batch = buffer.drain()
        guard !batch.isEmpty, !paused else { return }
        for m in batch { ingest(m) }
        totalMessages += batch.count
    }

    private func ingest(_ m: MQTTMessage) {
        var node = root
        var path = ""
        let parts = m.topic.split(separator: "/", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            let name = String(part)
            path = i == 0 ? name : path + "/" + name
            if let existing = node.children[name] {
                node = existing
            } else {
                let child = TopicNode(name: name, id: path, parent: node)
                node.children[name] = child
                nodes[path] = child
                node = child
            }
        }
        node.record(m)
    }

    func clearTree() {
        root = TopicNode(name: "", id: "", parent: nil)
        nodes.removeAll()
        selectedTopic = nil
        totalMessages = 0
        _ = buffer.drain()
    }

    func publish(topic: String, payload: String, qos: Int, retain: Bool) -> String? {
        guard isConnected else { return "Not connected" }
        guard !topic.isEmpty else { return "Empty topic" }
        guard !topic.contains("#"), !topic.contains("+") else { return "Wildcards are not allowed in the topic" }
        client?.publish(topic: topic, payload: Data(payload.utf8), qos: qos, retain: retain)
        rememberPublish(topic: topic, payload: payload, qos: qos, retain: retain)
        return nil
    }

    /// Removes the retained messages of the node and all its descendants from the broker.
    func clearRetained(under node: TopicNode) {
        guard isConnected else { return }
        var stack = [node]
        while let n = stack.popLast() {
            if let m = n.lastMessage, m.retain, !m.payload.isEmpty {
                client?.publish(topic: m.topic, payload: Data(), qos: 1, retain: true)
            }
            stack.append(contentsOf: n.children.values)
        }
    }

    // MARK: Tree view (with filter)

    func treeItems() -> [TreeItem] {
        items(under: root, query: filter.trimmingCharacters(in: .whitespaces))
    }

    private func items(under node: TopicNode, query: String) -> [TreeItem] {
        node.sortedChildren.compactMap { child in
            let sub = items(under: child, query: query)
            let selfMatch = query.isEmpty
                || child.id.localizedCaseInsensitiveContains(query)
                || (child.lastMessage?.text?.localizedCaseInsensitiveContains(query) ?? false)
            if !selfMatch && sub.isEmpty { return nil }
            return TreeItem(node: child, children: sub.isEmpty ? nil : sub)
        }
    }
}
