import Foundation

/// Shared app metadata. Kept tiny and dependency-free so it can be compiled into the
/// unhosted test bundle, whose `Bundle.main` has no version keys (hence the fallback).
enum AppInfo {
    /// `CFBundleShortVersionString` (e.g. "1.1.0"), or "dev" when unavailable
    /// (unhosted test bundle, or a bundle without a version key).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// User-Agent header value derived from the bundle version.
    static var userAgent: String { "ClaudeUsageBar/\(version)" }
}
