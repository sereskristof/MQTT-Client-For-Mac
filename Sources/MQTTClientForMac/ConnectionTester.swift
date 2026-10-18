import Foundation
import Observation

/// Performs a real connection attempt with a profile and reports every step
/// (client identity, TLS handshake, server certificate chain, trust evaluation, MQTT CONNACK).
@MainActor @Observable
final class ConnectionTester {
    enum Kind { case ok, warning, failure, info }

    struct Line: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String
    }

    struct UntrustedRoot {
        let subject: String
        let fingerprint: String
        let der: Data
    }

    var lines: [Line] = []
    var isRunning = false
    /// Names the server certificate is valid for (offered when the host name does not match).
    var suggestedNames: [String] = []
    /// The last certificate of the server chain (offered when the chain is not trusted).
    var untrustedRoot: UntrustedRoot?

    private func add(_ kind: Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
    }

    func run(profile: ConnectionProfile) async {
        guard !isRunning else { return }
        isRunning = true
        lines = []
        suggestedNames = []
        untrustedRoot = nil
        defer { isRunning = false }

        guard !profile.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            add(.failure, "Enter a host first.")
            return
        }

        let scheme = profile.useTLS ? "mqtts" : "mqtt"
        add(.info, "Connecting to \(scheme)://\(profile.host):\(profile.port)")

        let tls: TLSSettings?
        do {
            tls = try profile.tlsSettings()
        } catch {
            add(.failure, "Client certificate: \(error.localizedDescription)")
            return
        }

        if let tls {
            add(.info, "Minimum \(tls.minVersion.rawValue). Server verification: \(tls.verification.title)")
            if let id = tls.identity {
                add(.ok, "Client identity loaded: \(id.clientSubject)")
                if id.caSubjects.isEmpty {
                    add(.warning, "The P12 contains no additional certificates, so only the client certificate itself is sent. If the broker uses an intermediate CA, include the full chain in the P12.")
                } else {
                    add(.ok, "Certificate chain sent to the broker: \(id.caSubjects.joined(separator: " → "))")
                }
            } else {
                add(.info, "No client certificate configured")
            }
            if !tls.anchors.isEmpty {
                let subjects = tls.anchors.map(CertificateFile.subject).joined(separator: ", ")
                add(.ok, "Imported CA certificates: \(subjects)" + (tls.trustOnlyImportedCAs ? " (system CAs are ignored)" : " (system CAs are trusted as well)"))
            }
        }

        let config = MQTTClient.Config(
            host: profile.host,
            port: UInt16(clamping: profile.port),
            clientID: "mqx-test-" + String(UInt32.random(in: 0...0xFFFFFF), radix: 16),
            username: profile.username,
            password: Keychain.get(profile.id.uuidString),
            tls: tls,
            keepAlive: 30,
            cleanSession: true
        )
        let client = MQTTClient(config: config)

        let outcome: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = OnceFlag()
            client.onState = { state in
                switch state {
                case .connected:
                    once.run { cont.resume(returning: nil) }
                case .disconnected(let reason):
                    once.run { cont.resume(returning: reason ?? "The connection was closed.") }
                case .connecting:
                    break
                }
            }
            client.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                once.run { cont.resume(returning: "Timed out after 10 seconds.") }
            }
        }
        client.disconnect()

        let snap = client.diagnostics.snapshot()
        if !snap.chain.isEmpty {
            add(.info, "Server certificate chain:")
            for (i, c) in snap.chain.enumerated() {
                add(.info, "  \(i + 1). \(c.subject)\n      SHA-256 \(c.fingerprint)")
            }
        }
        if tls != nil {
            if snap.trustSkipped {
                add(.warning, "The server certificate was not verified (verification is disabled).")
            } else if snap.trustEvaluated {
                if let e = snap.trustError {
                    add(.failure, e)
                    if snap.failureKind == .hostName {
                        suggestedNames = snap.certificateNames.filter { !$0.contains("*") }
                    } else if let last = snap.chain.last {
                        untrustedRoot = UntrustedRoot(subject: last.subject, fingerprint: last.fingerprint, der: last.der)
                    }
                } else {
                    add(.ok, "The server certificate is trusted.")
                }
            } else {
                add(.info, "The TLS handshake ended before the server certificate was checked.")
            }
        }

        if let outcome {
            if snap.trustError == nil { add(.failure, outcome) }
        } else {
            add(.ok, "Connection accepted by the broker (MQTT CONNACK 0).")
        }
    }
}
