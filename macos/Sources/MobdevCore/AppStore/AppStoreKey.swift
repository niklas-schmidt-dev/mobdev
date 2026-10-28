import CryptoKit
import Foundation

/// An App Store Connect API key: the issuer ID of the team, the key's ID and its private key, the
/// contents of the AuthKey_<key ID>.p8 file App Store Connect lets you download once.
public struct AppStoreCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var issuerID: String
    public var keyID: String
    /// The PEM text of the .p8 file. Never logged, shown or returned by a tool.
    public var privateKey: String

    public init(issuerID: String, keyID: String, privateKey: String) {
        self.issuerID = issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.privateKey = Self.pem(privateKey)
    }

    enum CodingKeys: String, CodingKey {
        case issuerID = "issuer_id"
        case keyID = "key_id"
        case privateKey = "private_key"
    }

    /// Names the key without its private part, so that interpolating it cannot leak the key.
    public var description: String { "App Store Connect key \(keyID)" }
    public var debugDescription: String { description }

    /// The signing key, after checking the IDs' shapes: an issuer ID is a UUID, a key ID letters
    /// and digits (ten of them today), and App Store Connect's keys are P-256 keys.
    public func signingKey() throws -> P256.Signing.PrivateKey {
        guard UUID(uuidString: issuerID) != nil else {
            throw AppStoreError.invalidKey(
                "The issuer ID looks like 57246542-96fe-1a63-e053-0824d011072a. It is above the list of keys in App Store Connect › Users and Access › Integrations.")
        }
        guard (1...32).contains(keyID.count), keyID.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else {
            throw AppStoreError.invalidKey("The key ID is letters and digits, such as 2X9R4HXF34, and part of the key's file name AuthKey_2X9R4HXF34.p8.")
        }
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: privateKey)
        } catch {
            throw AppStoreError.invalidKey(
                "This is not an App Store Connect private key. Choose the AuthKey_….p8 file you downloaded when you created the key.")
        }
    }

    /// The key ID in the file name App Store Connect gives a key, AuthKey_2X9R4HXF34.p8.
    public static func keyID(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasPrefix("AuthKey_") else { return nil }
        let id = String(stem.dropFirst("AuthKey_".count))
        return id.isEmpty ? nil : id
    }

    /// A key pasted without its BEGIN and END lines gets them back.
    private static func pem(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-----BEGIN") else { return trimmed }
        // PEM lines hold 64 characters; CryptoKit reads no longer ones.
        var body = Substring(trimmed.filter { !$0.isWhitespace })
        var lines: [Substring] = []
        while !body.isEmpty {
            lines.append(body.prefix(64))
            body = body.dropFirst(64)
        }
        return "-----BEGIN PRIVATE KEY-----\n\(lines.joined(separator: "\n"))\n-----END PRIVATE KEY-----"
    }
}

/// Where the App Store Connect key lives: app-store-connect.json in Mobdev's folder, readable only
/// by this user (mode 0600) like the API token. Only the user adds it, in the app's settings; no
/// tool or API returns it, and it never goes through a relay.
public final class AppStoreKeyStore: Sendable {
    private let folder: URL?
    private let lock = NSLock()

    /// `folder` nil is Mobdev's folder as it is when the key is used, so `MOBDEV_HOME` applies.
    public init(folder: URL? = nil) {
        self.folder = folder
    }

    public var file: URL { (folder ?? MobdevPaths.home).appendingPathComponent("app-store-connect.json") }

    public func load() -> AppStoreCredentials? {
        lock.withLock {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(AppStoreCredentials.self, from: data)
        }
    }

    public var hasKey: Bool { load() != nil }

    /// Checks the key and stores it, replacing an earlier one.
    public func save(_ credentials: AppStoreCredentials) throws {
        _ = try credentials.signingKey()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(credentials)
        try lock.withLock {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Written next to the file and moved over it, so it never exists with wider permissions.
            let temporary = folder.appendingPathComponent(".app-store-connect-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: file)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    public func remove() throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// The short-lived tokens App Store Connect takes instead of a password: JWTs signed with ES256
/// that name the key and expire within 20 minutes.
enum AppStoreToken {
    /// App Store Connect refuses tokens that live longer than 20 minutes. One minute less leaves
    /// room for a Mac clock that runs ahead.
    static let lifetime: TimeInterval = 19 * 60

    static func make(_ credentials: AppStoreCredentials, key: P256.Signing.PrivateKey, now: Date) throws -> (token: String, expires: Date) {
        let issued = Int(now.timeIntervalSince1970)
        let expires = issued + Int(lifetime)
        let header: JSONValue = ["alg": "ES256", "kid": .string(credentials.keyID), "typ": "JWT"]
        let claims: JSONValue = [
            "iss": .string(credentials.issuerID), "iat": JSONValue(issued), "exp": JSONValue(expires), "aud": "appstoreconnect-v1",
        ]
        let input = base64URL(header.encoded()) + "." + base64URL(claims.encoded())
        // CryptoKit's raw representation is r and s, 32 bytes each: what JWS calls an ES256 signature.
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return (input + "." + base64URL(signature), Date(timeIntervalSince1970: TimeInterval(expires)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
