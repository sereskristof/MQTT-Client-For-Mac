import Foundation
import Network
import Security
import CryptoKit

// MARK: - Settings types

enum ServerVerification: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case caOnly
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return "Verify certificate and host name"
        case .caOnly: return "Verify certificate only (ignore host name)"
        case .none: return "Do not verify (insecure)"
        }
    }
}

enum TLSVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case tls12 = "TLS 1.2"
    case tls13 = "TLS 1.3"
    var id: String { rawValue }
}

struct TLSSettings: @unchecked Sendable {
    var host: String
    var verification: ServerVerification = .full
    var minVersion: TLSVersion = .tls12
    var serverName = ""
    var alpn = ""
    var identity: P12Bundle?
    var anchors: [SecCertificate] = []
    var trustOnlyImportedCAs = true
}

/// Runs a closure only once (thread-safe).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }
}

// MARK: - PKCS#12

/// Contents of a PKCS#12 (.p12 / .pfx) file: the client identity (key + certificate)
/// and the other certificates of its chain (intermediates / CA).
struct P12Bundle: @unchecked Sendable {
    let identity: SecIdentity
    let caCertificates: [SecCertificate]
    let clientSubject: String
    let caSubjects: [String]

    struct LoadError: LocalizedError {
        let message: String
        var passwordProblem = false
        var errorDescription: String? { message }
    }

    static func load(data: Data, password: String) throws -> P12Bundle {
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        // From macOS 15 the identity can be imported into memory only (not into the login keychain).
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }

        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw LoadError(
                message: describe(status),
                passwordProblem: status == errSecAuthFailed || status == errSecPkcs12VerifyFailure
            )
        }
        guard let items = rawItems as? [[String: Any]],
              let item = items.first(where: { $0[kSecImportItemIdentity as String] != nil }) else {
            throw LoadError(message: "The P12 file does not contain a private key with a certificate.")
        }

        let identity = item[kSecImportItemIdentity as String] as! SecIdentity

        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)

        let chain = (item[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        let others = chain.filter { cert in
            guard let leaf else { return true }
            return !CFEqual(cert, leaf)
        }

        return P12Bundle(
            identity: identity,
            caCertificates: others,
            clientSubject: leaf.map(CertificateFile.subject) ?? "(unknown)",
            caSubjects: others.map(CertificateFile.subject)
        )
    }

    private static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            return "Wrong P12 password (or the file is corrupt)."
        case errSecDecode:
            return "The P12 file cannot be read (invalid format or unsupported encryption). "
                 + "If it was created with OpenSSL 3, re-export it with the `-legacy` option."
        default:
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "P12 import error: \(msg) (\(status))"
        }
    }
}

// MARK: - Certificate files (PEM / DER)

enum CertificateFile {
    static func subject(_ cert: SecCertificate) -> String {
        (SecCertificateCopySubjectSummary(cert) as String?) ?? "(unknown)"
    }

    /// Names a certificate is valid for (subject alternative names, falling back to the common name).
    static func names(_ cert: SecCertificate) -> [String] {
        var out: [String] = []
        if let values = SecCertificateCopyValues(cert, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
           let san = values[kSecOIDSubjectAltName as String] as? [String: Any],
           let list = san[kSecPropertyKeyValue as String] as? [[String: Any]] {
            for item in list {
                if let v = item[kSecPropertyKeyValue as String] as? String, !out.contains(v) { out.append(v) }
            }
        }
        if out.isEmpty {
            var cn: CFString?
            if SecCertificateCopyCommonName(cert, &cn) == errSecSuccess, let cn {
                out.append(cn as String)
            }
        }
        return out
    }

    /// PEM bundle of the given certificates.
    static func pem(_ certs: [SecCertificate]) -> Data {
        var out = ""
        for cert in certs {
            let b64 = (SecCertificateCopyData(cert) as Data)
                .base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            out += "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
        }
        return Data(out.utf8)
    }

    /// Reads one or more certificates from a PEM (possibly a bundle) or DER file.
    static func parse(_ data: Data) -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8),
           text.contains("-----BEGIN CERTIFICATE-----") {
            var certs: [SecCertificate] = []
            let parts = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
            for part in parts {
                guard let end = part.range(of: "-----END CERTIFICATE-----") else { continue }
                let b64 = part[..<end.lowerBound]
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined()
                if let der = Data(base64Encoded: b64),
                   let cert = SecCertificateCreateWithData(nil, der as CFData) {
                    certs.append(cert)
                }
            }
            return certs
        }
        if let cert = SecCertificateCreateWithData(nil, data as CFData) { return [cert] }
        return []
    }
}

// MARK: - Diagnostics collected during the handshake

final class TLSDiagnostics: @unchecked Sendable {
    enum FailureKind: Sendable { case hostName, chain }

    struct CertInfo: Sendable {
        let subject: String
        let fingerprint: String
        let der: Data
    }

    struct Snapshot: Sendable {
        var chain: [CertInfo] = []
        var trustEvaluated = false
        var trustSkipped = false
        var trustError: String?
        var failureKind: FailureKind?
        var certificateNames: [String] = []
    }

    private let lock = NSLock()
    private var state = Snapshot()

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func recordChain(_ trust: SecTrust) {
        let certs = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let infos = certs.map { cert -> CertInfo in
            let der = SecCertificateCopyData(cert) as Data
            let hex = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
            return CertInfo(subject: CertificateFile.subject(cert), fingerprint: hex, der: der)
        }
        lock.lock()
        state.chain = infos
        lock.unlock()
    }

    func recordTrust(error: String?, skipped: Bool, kind: FailureKind? = nil, names: [String] = []) {
        lock.lock()
        state.trustEvaluated = true
        state.trustSkipped = skipped
        state.trustError = error
        state.failureKind = kind
        state.certificateNames = names
        lock.unlock()
    }
}

// MARK: - NWParameters builder

enum TLSConfigurator {
    static func parameters(_ s: TLSSettings, queue: DispatchQueue, diagnostics: TLSDiagnostics?) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(sec, s.minVersion == .tls13 ? .TLSv13 : .TLSv12)

        if !s.serverName.isEmpty {
            sec_protocol_options_set_tls_server_name(sec, s.serverName)
        }
        if !s.alpn.isEmpty {
            sec_protocol_options_add_tls_application_protocol(sec, s.alpn)
        }

        // Client identity (mutual TLS). The rest of the chain is sent as well,
        // otherwise brokers that only know the root CA reject the client certificate.
        if let p12 = s.identity {
            let identity: sec_identity_t?
            if p12.caCertificates.isEmpty {
                identity = sec_identity_create(p12.identity)
            } else {
                identity = sec_identity_create_with_certificates(p12.identity, p12.caCertificates as CFArray)
            }
            if let identity { sec_protocol_options_set_local_identity(sec, identity) }
        }

        // Server verification
        let verification = s.verification
        let anchors = s.anchors
        let strict = s.trustOnlyImportedCAs
        let policyName = s.serverName.isEmpty ? s.host : s.serverName

        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            diagnostics?.recordChain(trust)

            if verification == .none {
                diagnostics?.recordTrust(error: nil, skipped: true)
                complete(true)
                return
            }
            if !anchors.isEmpty {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, strict)
            }
            let policy = SecPolicyCreateSSL(true, verification == .full ? policyName as CFString : nil)
            SecTrustSetPolicies(trust, policy)

            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                diagnostics?.recordTrust(error: nil, skipped: false)
                complete(true)
                return
            }

            // Failed. Find out whether only the host name is the problem or the chain itself.
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "unknown reason"
            let certs = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            let names = certs.first.map(CertificateFile.names) ?? []
            var kind = TLSDiagnostics.FailureKind.chain
            if verification == .full {
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
                var second: CFError?
                if SecTrustEvaluateWithError(trust, &second) { kind = .hostName }
            }

            let message: String
            if kind == .hostName {
                message = "Host name mismatch: the certificate is not valid for \u{201C}\(policyName)\u{201D}. "
                        + "It is valid for: \(names.isEmpty ? "(no names)" : names.joined(separator: ", "))."
            } else {
                let sent = certs.map(CertificateFile.subject).joined(separator: " → ")
                message = "The certificate chain could not be validated: \(reason). "
                        + "The server sent: \(sent.isEmpty ? "(nothing)" : sent). "
                        + "Make sure the CA that issued the broker's certificate is imported."
            }
            diagnostics?.recordTrust(error: message, skipped: false, kind: kind, names: names)
            complete(false)
        }, queue)

        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

// MARK: - Human readable network errors

enum NetworkErrorText {
    static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status):
            return tls(status)
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return "Connection refused. Is the broker running and listening on this port?"
            case .ETIMEDOUT:
                return "Connection timed out."
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN:
                return "The host is unreachable."
            case .ECONNRESET:
                return "Connection reset by the broker. If this port expects TLS (e.g. 8883) enable TLS, and the other way round."
            default:
                return error.localizedDescription
            }
        case .dns:
            return "The host name could not be resolved."
        default:
            return error.localizedDescription
        }
    }

    private static func tls(_ status: OSStatus) -> String {
        let system = (SecCopyErrorMessageString(status, nil) as String?) ?? "TLS error"
        let hint: String
        switch Int(status) {
        case -9806:
            hint = "The broker closed the connection during the TLS handshake. Typical causes: it requires a client certificate, or this port does not speak TLS."
        case -9807:
            hint = "The server certificate chain is not trusted. Import the CA certificate (or a P12 that contains it)."
        case -9808:
            hint = "A certificate in the handshake has an invalid format. Run \"Test connection\" in the profile for details."
        case -9825:
            hint = "The broker rejected our client certificate. Make sure the P12 contains the complete chain and that the broker trusts the issuing CA."
        case -9826:
            hint = "The broker does not support our client certificate (e.g. key type or signature algorithm)."
        case -9827:
            hint = "A certificate has been revoked."
        case -9828:
            hint = "A certificate has expired (client or server)."
        case -9829, -9831:
            hint = "The broker does not know the CA that issued our client certificate."
        case -9836:
            hint = "TLS protocol version mismatch. Try a different minimum TLS version."
        case -9841, -9842:
            hint = "The broker requires a client certificate. Import a P12 file in the profile."
        case -9843:
            hint = "The host name does not match the server certificate. Use the name from the certificate, set a Server name under Advanced, or ignore the host name."
        default:
            hint = ""
        }
        return hint.isEmpty ? "\(system) (\(status))" : "\(system) (\(status)). \(hint)"
    }
}
