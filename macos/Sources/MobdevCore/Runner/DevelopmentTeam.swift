import Foundation
import Security

/// An Apple development team this Mac can sign Mobdev Runner with, read from the Apple Development
/// certificates in the keychain. The team ID is the organizational unit (OU) of the certificate's
/// subject. The ID in "Apple Development: Name (ABCDE12345)" is the certificate's own, not the team.
public struct DevelopmentTeam: Sendable, Equatable, Identifiable {
    public var id: String
    /// The organization (O) of the subject: a person's or company's name.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Teams with a current Apple Development certificate and its private key, the newest
    /// certificate's team first. Reads only the certificates, so the keychain asks nothing.
    public static func inKeychain(now: Date = Date()) -> [DevelopmentTeam] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let identities = result as? [SecIdentity]
        else { return [] }
        let certificates = identities.compactMap { identity -> SecCertificate? in
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate
        }
        return teams(in: certificates, now: now)
    }

    /// One entry per team, the newest certificate's first.
    static func teams(in certificates: [SecCertificate], now: Date) -> [DevelopmentTeam] {
        var teams: [DevelopmentTeam] = []
        for (team, _) in certificates.compactMap({ team(of: $0, now: now) }).sorted(by: { $0.issued > $1.issued })
        where !teams.contains(where: { $0.id == team.id }) {
            teams.append(team)
        }
        return teams
    }

    /// The team of an Apple Development certificate that is valid at `now`, and when it was issued.
    static func team(of certificate: SecCertificate, now: Date) -> (team: DevelopmentTeam, issued: Date)? {
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        guard summary.hasPrefix("Apple Development") || summary.hasPrefix("iPhone Developer") else { return nil }
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
        guard let values = SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [String: Any] else { return nil }
        func value(_ key: CFString) -> Any? { (values[key as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        func date(_ key: CFString) -> Date? {
            (value(key) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        let subject = value(kSecOIDX509V1SubjectName) as? [[String: Any]] ?? []
        func field(_ oid: CFString) -> String? {
            subject.first { $0[kSecPropertyKeyLabel as String] as? String == oid as String }?[kSecPropertyKeyValue as String]
                as? String
        }
        guard let id = field(kSecOIDOrganizationalUnitName), UIRunner.isTeamID(id),
            let issued = date(kSecOIDX509V1ValidityNotBefore), let expires = date(kSecOIDX509V1ValidityNotAfter),
            issued <= now, now < expires
        else { return nil }
        return (DevelopmentTeam(id: id, name: field(kSecOIDOrganizationName) ?? id), issued)
    }

    /// Certificates from PEM text, as `security find-certificate -p` prints them.
    static func certificates(fromPEM text: String) -> [SecCertificate] {
        text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block in
            guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first,
                let der = Data(base64Encoded: body.filter { !$0.isWhitespace })
            else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }
}
