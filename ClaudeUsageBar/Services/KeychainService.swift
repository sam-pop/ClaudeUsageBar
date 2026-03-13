import Foundation
import Security

enum KeychainService {
    static func getOAuthToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        // Try direct UTF-8 extraction first
        if let str = String(data: data, encoding: .utf8),
           let token = extractToken(from: str) {
            return token
        }

        // Fall back to hex-decode (keychain may store as hex-encoded bytes)
        let hexString = data.map { String(format: "%02x", $0) }.joined()
        if let hexData = hexDecode(hexString),
           let str = String(data: hexData, encoding: .utf8),
           let token = extractToken(from: str) {
            return token
        }

        // Try treating the raw data as hex directly
        if let hexData = hexDecode(String(data: data, encoding: .ascii) ?? ""),
           let str = String(data: hexData, encoding: .utf8),
           let token = extractToken(from: str) {
            return token
        }

        return nil
    }

    private static func extractToken(from text: String) -> String? {
        guard let range = text.range(of: #"sk-ant-oat01-[A-Za-z0-9_-]+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let cleaned = hex.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
