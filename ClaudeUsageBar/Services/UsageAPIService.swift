import Foundation

enum UsageAPIError: LocalizedError {
    case noToken
    case requestFailed(Error)
    case invalidResponse(Int)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No OAuth token found in Keychain"
        case .requestFailed(let error):
            return "Request failed: \(error.localizedDescription)"
        case .invalidResponse(let code):
            return "HTTP \(code)"
        case .decodingFailed(let error):
            return "Decode error: \(error.localizedDescription)"
        }
    }
}

enum UsageAPIService {
    private static let endpoint = URL(string: "https://api.anthropic.com/oauth/usage")!

    static func fetch() async throws -> UsageResponse {
        guard let token = KeychainService.getOAuthToken() else {
            throw UsageAPIError.noToken
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("ClaudeUsageBar/1.0", forHTTPHeaderField: "user-agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageAPIError.requestFailed(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageAPIError.requestFailed(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UsageAPIError.invalidResponse(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decodingFailed(error)
        }
    }
}
