import Foundation
import Network
import Observation
import Darwin

struct DiscoveredBroker: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        case bonjour = "Bonjour"
        case scan = "Network scan"
    }

    var id: String { "\(host):\(port)" }
    var name: String
    var host: String
    var port: Int
    var useTLS: Bool
    var confirmed: Bool      // true if the broker answered with a CONNACK or advertises itself via Bonjour
    var source: Source
}

// MARK: - Probe segédek

private enum ProbeResult: Sendable {
    case closed   // nem elérhető
    case open     // a port nyitva, de nem érkezett MQTT válasz
    case mqtt     // CONNACK érkezett: biztosan MQTT bróker
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var wasConnected = false

    var connected: Bool {
        lock.lock(); defer { lock.unlock() }
        return wasConnected
    }

    func markConnected() {
        lock.lock(); wasConnected = true; lock.unlock()
    }

    /// Igaz, ha ez az első lezárás.
    func finishOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Minimális, névtelen MQTT 3.1.1 CONNECT (clean session), csak a bróker azonosításához.
private func probeConnectPacket() -> Data {
    let cid = Array(("mqx-" + String(UInt32.random(in: 0...0xFFFFFF), radix: 16)).utf8)
    let remaining = 10 + 2 + cid.count
    var bytes: [UInt8] = [0x10, UInt8(remaining),
                          0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 0x3C,
                          0x00, UInt8(cid.count)]
    bytes += cid
    return Data(bytes)
}

// MARK: - Felderítés

@MainActor @Observable
final class BrokerDiscovery {
    var results: [DiscoveredBroker] = []
    var isScanning = false
    var progress = 0.0
    var message: String?

    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolvers: [NWConnection] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var seenServices: Set<String> = []

    func start() {
        stop()
        results = []
        message = nil
        progress = 0
        seenServices = []
        isScanning = true
        startBonjour()
        scanTask = Task { await scan() }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        browsers.forEach { $0.cancel() }
        browsers = []
        resolvers.forEach { $0.cancel() }
        resolvers = []
        isScanning = false
    }

    private func add(_ broker: DiscoveredBroker) {
        if let i = results.firstIndex(where: { $0.id == broker.id }) {
            // a megerősített / Bonjour-os adat felülírja a találgatást
            if broker.confirmed && !results[i].confirmed {
                var merged = broker
                if results[i].source == .bonjour { merged.name = results[i].name; merged.source = .bonjour }
                results[i] = merged
            }
        } else {
            results.append(broker)
            results.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        }
    }

    // MARK: Bonjour

    private func startBonjour() {
        let types: [(String, Bool)] = [("_mqtt._tcp", false), ("_secure-mqtt._tcp", true)]
        for (type, tls) in types {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] found, _ in
                let list = Array(found)
                Task { @MainActor in self?.handleBonjour(list, tls: tls) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e), .waiting(let e):
                    let text = e.localizedDescription
                    Task { @MainActor in
                        if self?.message == nil { self?.message = "Bonjour: \(text)" }
                    }
                default:
                    break
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    private func handleBonjour(_ found: [NWBrowser.Result], tls: Bool) {
        for r in found {
            guard case let .service(name, type, _, _) = r.endpoint else { continue }
            let key = type + "|" + name
            guard seenServices.insert(key).inserted else { continue }
            resolve(r.endpoint, name: name, tls: tls)
        }
    }

    /// A Bonjour szolgáltatás címének és portjának feloldása egy ideiglenes kapcsolattal.
    private func resolve(_ endpoint: NWEndpoint, name: String, tls: Bool) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .ready:
                if let conn, case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                    let hostText = Self.hostString(host)
                    let portValue = Int(port.rawValue)
                    let broker = DiscoveredBroker(name: name, host: hostText, port: portValue,
                                                  useTLS: tls, confirmed: true, source: .bonjour)
                    Task { @MainActor in self?.add(broker) }
                }
                conn?.cancel()
            case .failed, .waiting:
                conn?.cancel()
            default:
                break
            }
        }
        resolvers.append(conn)
        conn.start(queue: .global())
    }

    nonisolated private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }

    // MARK: Pásztázás

    private func scan() async {
        let subnets = Self.localSubnets()
        guard !subnets.isEmpty else {
            if message == nil { message = "No active local IPv4 network found." }
            isScanning = false
            return
        }

        var hosts = ["127.0.0.1"]
        for base in subnets {
            for i in 1...254 { hosts.append(Self.ipString(base | UInt32(i))) }
        }
        let total = Double(hosts.count)
        var done = 0

        await withTaskGroup(of: [DiscoveredBroker].self) { group in
            var iterator = hosts.makeIterator()
            for _ in 0..<64 {
                guard let h = iterator.next() else { break }
                group.addTask { await Self.checkHost(h) }
            }
            while let found = await group.next() {
                done += 1
                progress = Double(done) / total
                for b in found { add(b) }
                if Task.isCancelled { group.cancelAll(); break }
                if let h = iterator.next() {
                    group.addTask { await Self.checkHost(h) }
                }
            }
        }

        isScanning = false
        if results.isEmpty && message == nil {
            message = "No MQTT broker found. If macOS asked, allow Local Network access "
                    + "(System Settings ▸ Privacy & Security ▸ Local Network)."
        }
    }

    /// A gép aktív en* interfészeinek /24-es hálózatai.
    nonisolated private static func localSubnets() -> [UInt32] {
        var subnets = Set<UInt32>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next

            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(bitPattern: ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard String(cString: ifa.ifa_name).hasPrefix("en") else { continue }

            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if (ip >> 16) == 0xA9FE { continue }   // 169.254.x.x link-local
            subnets.insert(ip & 0xFFFF_FF00)
        }
        return subnets.sorted()
    }

    nonisolated private static func ipString(_ v: UInt32) -> String {
        "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }

    nonisolated private static func checkHost(_ host: String) async -> [DiscoveredBroker] {
        var found: [DiscoveredBroker] = []
        let ports: [(Int, Bool)] = [(1883, false), (8883, true)]
        for (port, tls) in ports {
            var r = await probe(host: host, port: UInt16(port), tls: false)
            if r == .closed { continue }
            if tls && r != .mqtt {
                if await probe(host: host, port: UInt16(port), tls: true) == .mqtt { r = .mqtt }
            }
            found.append(DiscoveredBroker(name: host, host: host, port: port, useTLS: tls,
                                          confirmed: r == .mqtt, source: .scan))
        }
        return found
    }

    nonisolated private static func probe(host: String, port: UInt16, tls: Bool,
                                          timeout: TimeInterval = 0.8) async -> ProbeResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProbeResult, Never>) in
            let queue = DispatchQueue(label: "mqtt.probe")
            guard let p = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: .closed)
                return
            }

            let params: NWParameters
            if tls {
                let options = NWProtocolTLS.Options()
                sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
                    complete(true)
                }, queue)
                params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
            } else {
                params = .tcp
            }

            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
            let box = ProbeBox()
            let finish: @Sendable (ProbeResult) -> Void = { result in
                if box.finishOnce() {
                    conn.cancel()
                    cont.resume(returning: result)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.markConnected()
                    conn.send(content: probeConnectPacket(), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                        finish(data?.first == 0x20 ? .mqtt : .open)
                    }
                case .failed, .waiting, .cancelled:
                    finish(box.connected ? .open : .closed)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(box.connected ? .open : .closed)
            }
            conn.start(queue: queue)
        }
    }
}
