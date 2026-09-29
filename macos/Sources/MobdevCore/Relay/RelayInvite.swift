import Foundation

/// A relay connection offered by a `mobdev://connect?relay=<url>&token=<access token>` link from
/// the mobdev.sh dashboard. The app asks before applying it. The development build registers
/// `mobdev-dev://` instead, so dashboard links always open the installed app.
public struct RelayInvite: Equatable, Sendable {
    public let relay: URL
    public let token: String

    public init?(url: URL) {
        guard url.scheme == "mobdev" || url.scheme == "mobdev-dev", url.host == "connect",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let relayText = items.first(where: { $0.name == "relay" })?.value,
            let relay = try? RelayClient.validatedURL(relayText),
            let token = items.first(where: { $0.name == "token" })?.value,
            token.range(of: "^mda_[0-9a-f]{64}$", options: .regularExpression) != nil
        else { return nil }
        self.relay = relay
        self.token = token
    }
}
