import Foundation

/// Shared path-joining guard for our two custom-scheme handlers (mdeye-app:// and
/// mdeye-asset://). Keeps a single, consistent rule: resolve `relative` against
/// `base`, reject traversal outside the base, return nil otherwise.
///
/// Existence / directory checks stay at call sites (they depend on the caller's
/// intent: app resources vs. local images).
enum PathSandbox {
    /// - returns: the standardized candidate URL *inside* base, or nil if it escapes.
    static func join(base: URL, relative: String) -> URL? {
        let b = base.standardizedFileURL
        let cleaned = relative
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
        // Reject any explicit `..` segment before letting the URL parser near it.
        if cleaned.split(separator: "/").contains("..") { return nil }
        let candidate = b.appendingPathComponent(cleaned).standardizedFileURL
        let bp = b.path
        let cp = candidate.path
        guard cp == bp || cp.hasPrefix(bp + "/") else { return nil }
        return candidate
    }
}
