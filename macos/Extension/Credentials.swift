import FileProvider
import Foundation

/// Connection details shared by the host app and File Provider extension.
///
/// Cloud-service authentication does NOT live here. Quark/Baidu/etc. authenticate
/// inside AList; the File Provider only talks to the loopback bridge. Keeping that
/// boundary is what lets one extension serve many providers without copying cloud
/// credentials into every File Provider domain.
enum Credentials {
    static let appGroup = "group.com.quarkpan.plinth"

    struct Pair: Sendable {
        let account: String
        let password: String
    }

    struct Configuration: Sendable {
        let providerID: String
        let baseURL: URL
        let credential: Pair
    }

    /// The bridge is loopback-only and currently checks only that Basic auth is
    /// present. These values are intentionally not cloud credentials or secrets.
    private static let bridgeCredential = Pair(account: "plinth", password: "local")

    static func configuration(for domainIdentifier: NSFileProviderDomainIdentifier) -> Configuration? {
        guard let provider = ProviderCatalog.provider(domainIdentifier: domainIdentifier) else {
            return nil
        }
        return Configuration(
            providerID: provider.id,
            baseURL: provider.bridgeBaseURL,
            credential: bridgeCredential
        )
    }
}
