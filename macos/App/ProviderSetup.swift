import Foundation

struct ProviderBackendStatus: Decodable, Sendable {
    let id: String
    let displayName: String
    let configured: Bool
    let healthy: Bool
    let status: String
    let disabled: Bool
    let mountPath: String
}

enum ProviderStatusError: Error, LocalizedError {
    case invalidResponse
    case bridge(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "本地 cloud-drive-fp bridge 返回了无法识别的响应。"
        case .bridge(let code, let message):
            return message.isEmpty ? "bridge 请求失败（HTTP \(code)）。" : message
        }
    }
}

/// Read-only client for the bridge's loopback provider-status API.
/// Cloud credentials and storage configuration belong entirely to AList.
actor ProviderStatusService {
    static let shared = ProviderStatusService()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func status(for provider: DriveProvider) async throws -> ProviderBackendStatus {
        let url = URL(string: "http://127.0.0.1:\(ProviderCatalog.bridgePort)/control/providers/\(provider.id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let authorization = Data("plinth:local".utf8).base64EncodedString()
        request.setValue("Basic \(authorization)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderStatusError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? String {
                message = error
            } else {
                message = String(data: data, encoding: .utf8) ?? ""
            }
            throw ProviderStatusError.bridge(http.statusCode, message)
        }

        return try JSONDecoder().decode(ProviderBackendStatus.self, from: data)
    }
}
