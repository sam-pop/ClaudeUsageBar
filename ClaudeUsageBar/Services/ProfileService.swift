import Foundation

/// The identifying facts about a Claude account, from the OAuth profile endpoint.
/// `uuid` is the stable account identity used for dedupe, default labeling, and the
/// re-auth guard (verifying the browser login signed into the account being re-authed).
struct AccountIdentity: Equatable {
    let uuid: String
    let email: String?
    let displayName: String?
}

/// Fetches account identity from `GET https://api.anthropic.com/api/oauth/profile`
/// (discovered and verified live during Phase 0). Mirrors `UsageAPIService`'s request
/// shape and reuses `UsageAPIError` for uniform error handling.
enum ProfileService {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// The subset of the profile payload we consume. The endpoint returns more
    /// (`organization`, plan flags, timestamps) which we intentionally ignore.
    private struct ProfileResponse: Decodable {
        struct Account: Decodable {
            let uuid: String
            let email: String?
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case uuid, email
                case displayName = "display_name"
            }
        }
        let account: Account
    }

    static func decodeIdentity(from data: Data) throws -> AccountIdentity {
        let decoded = try JSONDecoder().decode(ProfileResponse.self, from: data)
        return AccountIdentity(
            uuid: decoded.account.uuid,
            email: decoded.account.email,
            displayName: decoded.account.displayName
        )
    }

    static func fetchIdentity(token: String) async throws -> AccountIdentity {
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
            return try decodeIdentity(from: data)
        } catch {
            throw UsageAPIError.decodingFailed(error)
        }
    }
}
