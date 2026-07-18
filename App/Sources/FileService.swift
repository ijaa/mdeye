import Foundation

struct MarkdownFile {
    let path: String
    let baseDir: String
    let text: String
    let encoding: String
    let mtimeMs: Double
}

enum FileServiceError: LocalizedError {
    case notFound(String)
    case unreadable(String)
    case notFile(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "File not found:\n\(p)"
        case .unreadable(let p): return "Cannot read file:\n\(p)"
        case .notFile(let p): return "Not a file:\n\(p)"
        }
    }
}

enum FileService {
    static func readMarkdown(path: String) throws -> MarkdownFile {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileServiceError.notFound(url.path)
        }
        guard !isDir.boolValue else {
            throw FileServiceError.notFile(url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileServiceError.unreadable(url.path)
        }

        let (text, encodingName) = decode(data)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        return MarkdownFile(
            path: url.path,
            baseDir: url.deletingLastPathComponent().path,
            text: text,
            encoding: encodingName,
            mtimeMs: mtime * 1000
        )
    }

    /// Resolve a relative asset path against baseDir; reject path escape.
    static func resolveAsset(baseDir: String, relative: String) -> URL? {
        let base = URL(fileURLWithPath: baseDir, isDirectory: true)
        guard let candidate = PathSandbox.join(base: base, relative: relative) else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    private static func decode(_ data: Data) -> (String, String) {
        if let s = String(data: data, encoding: .utf8) {
            return (s, "utf-8")
        }
        if let s = String(data: data, encoding: .utf16) {
            return (s, "utf-16")
        }
        // Fallback: lossy ISO Latin-1 style
        let s = String(decoding: data, as: UTF8.self)
        return (s, "utf-8-lossy")
    }
}
