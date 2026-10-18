import Foundation
import Network

struct MQTTMessage: Identifiable, Sendable {
    let id = UUID()
    let topic: String
    let payload: Data
    let qos: Int
    let retain: Bool
    let date: Date
}

/// Minimal, dependency-free MQTT 3.1.1 client (TCP / TLS).
/// Supports CONNECT, SUBSCRIBE, UNSUBSCRIBE, PUBLISH (QoS 0/1/2), PING and DISCONNECT.
final class MQTTClient: @unchecked Sendable {
    struct Config {
        var host: String
        var port: UInt16
        var clientID: String
        var username: String
        var password: String
        var tls: TLSSettings?
        var keepAlive: UInt16
        var cleanSession: Bool
    }

    enum State {
        case connecting
        case connected
        case disconnected(String?)
    }

    var onMessage: (@Sendable (MQTTMessage) -> Void)?
    var onState: (@Sendable (State) -> Void)?
    /// Called for every subscription filter with `true` if the broker granted it, `false` if it refused it.
    var onSubscriptionResult: (@Sendable (String, Bool) -> Void)?
    let diagnostics = TLSDiagnostics()

    private let config: Config
    private let queue = DispatchQueue(label: "mqtt.client")
    private var connection: NWConnection?
    private var inbox: [UInt8] = []
    private var lastID: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?
    private var pendingQoS2: [UInt16: MQTTMessage] = [:]
    private var pendingSubscriptions: [UInt16: [String]] = [:]
    private var closed = false

    init(config: Config) {
        self.config = config
    }

    // MARK: - Public API

    func start() {
        queue.async { [self] in
            onState?(.connecting)

            guard let port = NWEndpoint.Port(rawValue: config.port) else {
                finish("Invalid port")
                return
            }

            let params: NWParameters
            if let tls = config.tls {
                params = TLSConfigurator.parameters(tls, queue: queue, diagnostics: diagnostics)
            } else {
                params = .tcp
            }

            let c = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: params)
            connection = c
            c.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionState(state)
            }
            c.start(queue: queue)
        }
    }

    func disconnect() {
        queue.async { [self] in
            guard !closed else { return }
            send([0xE0, 0x00])
            finish(nil)
        }
    }

    func subscribe(_ filter: String, qos: Int = 0) {
        queue.async { [self] in
            let id = newID()
            pendingSubscriptions[id] = [filter]
            let body: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)] + Self.string(filter) + [UInt8(qos)]
            send([0x82] + Self.length(body.count) + body)
        }
    }

    func unsubscribe(_ filter: String) {
        queue.async { [self] in
            let id = newID()
            let body: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)] + Self.string(filter)
            send([0xA2] + Self.length(body.count) + body)
        }
    }

    func publish(topic: String, payload: Data, qos: Int, retain: Bool) {
        queue.async { [self] in
            let header: UInt8 = 0x30 | UInt8(qos << 1) | (retain ? 1 : 0)
            var body = Self.string(topic)
            if qos > 0 {
                let id = newID()
                body += [UInt8(id >> 8), UInt8(id & 0xFF)]
            }
            body += [UInt8](payload)
            send([header] + Self.length(body.count) + body)
        }
    }

    // MARK: - Connection handling

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendConnect()
            receiveLoop()
        case .failed(let error), .waiting(let error):
            finish(describe(error))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func describe(_ error: NWError) -> String {
        if let reason = diagnostics.snapshot().trustError {
            return "The server certificate was rejected: \(reason)"
        }
        return NetworkErrorText.describe(error)
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        pingTimer = nil
        let c = connection
        connection = nil
        // short delay so that a DISCONNECT packet can still leave
        queue.asyncAfter(deadline: .now() + 0.1) { c?.cancel() }
        onState?(.disconnected(reason))
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(NetworkErrorText.describe(error)) }
        })
    }

    private func sendConnect() {
        var vh = Self.string("MQTT") + [4]
        var flags: UInt8 = 0
        if config.cleanSession { flags |= 0x02 }
        if !config.username.isEmpty {
            flags |= 0x80
            if !config.password.isEmpty { flags |= 0x40 }
        }
        vh += [flags, UInt8(config.keepAlive >> 8), UInt8(config.keepAlive & 0xFF)]

        var payload = Self.string(config.clientID)
        if !config.username.isEmpty {
            payload += Self.string(config.username)
            if !config.password.isEmpty { payload += Self.string(config.password) }
        }
        send([0x10] + Self.length(vh.count + payload.count) + vh + payload)
    }

    private func startPing() {
        guard config.keepAlive > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1.0, Double(config.keepAlive) / 2.0)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.send([0xC0, 0x00]) }
        t.resume()
        pingTimer = t
    }

    private func newID() -> UInt16 {
        lastID = lastID &+ 1
        if lastID == 0 { lastID = 1 }
        return lastID
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbox.append(contentsOf: data)
                self.parse()
            }
            if let error {
                self.finish(self.describe(error))
                return
            }
            if isComplete {
                self.finish("The broker closed the connection.")
                return
            }
            self.receiveLoop()
        }
    }

    private func parse() {
        while inbox.count >= 2 {
            let first = inbox[0]
            var multiplier = 1
            var value = 0
            var idx = 1
            var complete = false
            while idx < min(inbox.count, 5) {
                let b = Int(inbox[idx])
                idx += 1
                value += (b & 127) * multiplier
                multiplier *= 128
                if b & 128 == 0 { complete = true; break }
            }
            if !complete {
                if inbox.count >= 5 { finish("Malformed MQTT packet") }
                return
            }
            guard inbox.count >= idx + value else { return }
            let body = Array(inbox[idx..<(idx + value)])
            inbox.removeFirst(idx + value)
            handle(header: first, body: body)
        }
    }

    private func handle(header: UInt8, body: [UInt8]) {
        switch header >> 4 {
        case 2: // CONNACK
            guard body.count >= 2 else { return }
            let code = body[1]
            if code == 0 {
                startPing()
                onState?(.connected)
            } else {
                finish("The broker refused the connection: \(Self.connackReason(code))")
            }
        case 9: // SUBACK
            guard body.count >= 3 else { return }
            let id = UInt16(body[0]) << 8 | UInt16(body[1])
            let filters = pendingSubscriptions.removeValue(forKey: id) ?? []
            for (i, code) in body[2...].enumerated() where i < filters.count {
                onSubscriptionResult?(filters[i], code != 0x80)
            }
        case 3: // PUBLISH
            handlePublish(header: header, body: body)
        case 5: // PUBREC (outgoing QoS 2)
            guard body.count >= 2 else { return }
            send([0x62, 0x02, body[0], body[1]])
        case 6: // PUBREL (incoming QoS 2)
            guard body.count >= 2 else { return }
            let id = UInt16(body[0]) << 8 | UInt16(body[1])
            if let m = pendingQoS2.removeValue(forKey: id) { onMessage?(m) }
            send([0x70, 0x02, body[0], body[1]])
        default:
            break // SUBACK, UNSUBACK, PUBACK, PUBCOMP, PINGRESP
        }
    }

    private func handlePublish(header: UInt8, body: [UInt8]) {
        let qos = Int((header >> 1) & 0x03)
        let retain = (header & 0x01) == 1
        guard body.count >= 2 else { return }
        let topicLength = Int(body[0]) << 8 | Int(body[1])
        guard body.count >= 2 + topicLength else { return }
        let topic = String(decoding: body[2..<(2 + topicLength)], as: UTF8.self)
        var idx = 2 + topicLength
        var packetID: UInt16 = 0
        if qos > 0 {
            guard body.count >= idx + 2 else { return }
            packetID = UInt16(body[idx]) << 8 | UInt16(body[idx + 1])
            idx += 2
        }
        let msg = MQTTMessage(topic: topic, payload: Data(body[idx...]), qos: qos, retain: retain, date: Date())
        let idHi = UInt8(packetID >> 8)
        let idLo = UInt8(packetID & 0xFF)
        switch qos {
        case 0:
            onMessage?(msg)
        case 1:
            send([0x40, 0x02, idHi, idLo])
            onMessage?(msg)
        default:
            pendingQoS2[packetID] = msg
            send([0x50, 0x02, idHi, idLo])
        }
    }

    // MARK: - Encoding

    private static func string(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }

    private static func length(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var x = n
        repeat {
            var digit = UInt8(x % 128)
            x /= 128
            if x > 0 { digit |= 0x80 }
            out.append(digit)
        } while x > 0
        return out
    }

    private static func connackReason(_ code: UInt8) -> String {
        switch code {
        case 1: return "unacceptable protocol version"
        case 2: return "client identifier rejected"
        case 3: return "server unavailable"
        case 4: return "bad user name or password"
        case 5: return "not authorized"
        default: return "unknown error (\(code))"
        }
    }
}
