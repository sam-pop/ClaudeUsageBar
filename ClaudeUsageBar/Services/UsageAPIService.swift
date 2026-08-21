import Foundation

enum UsageAPIError: LocalizedError {
    case noToken
    case tokenExpired
    case requestFailed(Error)
    case invalidResponse(Int)
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Not signed in — click Log in"
        case .tokenExpired:
            return "Login expired — click Log in again"
        case .requestFailed(let error):
            return "Request failed: \(error.localizedDescription)"
        case .invalidResponse(let code):
            return "HTTP \(code)"
        case .decodingFailed(let error):
            return "Decode error: \(error.localizedDescription)"
        }
    }

    var isAuthError: Bool {
        if case .invalidResponse(let code) = self { return (401...403).contains(code) }
        return false
    }

    var needsKeychainRefresh: Bool {
        switch self {
        case .noToken, .tokenExpired: return true
        default: return false
        }
    }

    var isTransient: Bool {
        switch self {
        case .requestFailed: return true
        case .invalidResponse(let code): return code >= 500
        default: return false
        }
    }
}

enum UsageAPIService {
    private static let endpoint = URL(string: "https://api.anthropic.com/oauth/usage")!

    static func fetch(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "user-agent")

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
