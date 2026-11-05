import FileProvider
import Foundation

struct DriveProvider: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let domainIdentifier: String
    let legacyDomainIdentifiers: [String]
    let schemaVersion: Int
    let mountPath: String
    let driver: String
    let webdavPolicy: String

    var domainID: NSFileProviderDomainIdentifier {
        NSFileProviderDomainIdentifier(domainIdentifier)
    }

    var bridgeBaseURL: URL {
        URL(string: "http://127.0.0.1:\(ProviderCatalog.bridgePort)/dav/\(id)")!
    }
}

enum ProviderCatalog {
    private struct Catalog: Codable {
        let bridgePort: Int
        let providers: [DriveProvider]
    }

    private static let catalog: Catalog = {
        if let url = Bundle.main.url(forResource: "providers", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Catalog.self, from: data) {
            return decoded
        }

        return Catalog(
            bridgePort: 8081,
            providers: [
                DriveProvider(
                    id: "quark",
                    displayName: "夸克",
                    domainIdentifier: "plinth-drive",
                    legacyDomainIdentifiers: ["plinth-drive2"],
                    schemaVersion: 9,
                    mountPath: "/quark",
                    driver: "Quark",
                    webdavPolicy: "native_proxy"
                ),
                DriveProvider(
                    id: "baidu",
                    displayName: "百度网盘",
                    domainIdentifier: "plinth-baidu",
                    legacyDomainIdentifiers: [],
                    schemaVersion: 7,
                    mountPath: "/baidu",
                    driver: "BaiduNetdisk",
                    webdavPolicy: "native_proxy"
                )
            ]
        )
    }()

    static var bridgePort: Int { catalog.bridgePort }
    static var all: [DriveProvider] { catalog.providers }

    static func provider(id: String) -> DriveProvider? {
        catalog.providers.first { $0.id == id }
    }

    static func provider(domainIdentifier: NSFileProviderDomainIdentifier) -> DriveProvider? {
        catalog.providers.first { $0.domainIdentifier == domainIdentifier.rawValue }
    }

    static func provider(domainIdentifier: String) -> DriveProvider? {
        catalog.providers.first { $0.domainIdentifier == domainIdentifier }
    }
}
