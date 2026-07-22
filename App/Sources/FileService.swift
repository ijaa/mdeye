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

    /// 去除 `#fragment` 与 `?query` 后的纯路径部分，用于把文档内 .md 链接
    /// （如 `intro.md?x=1`、`intro.md#section`）归一成可被 `resolveAsset` 解析的相对路径。
    static func stripQueryAndFragment(_ href: String) -> String {
        var path = href
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let f = path.firstIndex(of: "#") { path = String(path[..<f]) }
        return path
    }

    /// 统一的 Markdown 后缀集（drag&drop、导出去后缀名、md 链接校验共用，防漂移）。
    private static let markdownSuffixes: [String] = [
        ".md", ".markdown", ".mdx", ".mdown", ".mkd", ".mkdn", ".mdwn",
    ]

    /// 路径是否为受支持的 Markdown 文件名（大小写无关）。
    static func isMarkdownPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return markdownSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func decode(_ data: Data) -> (String, String) {
        if let s = String(data: data, encoding: .utf8) {
            return (s, "utf-8")
        }
        // GB18030（GBK 超集）：常见 Windows 中文 .md。.gb18030 便捷常量只在 Apple
        // Foundation 提供，corelibs-foundation（CI 的 swift-corelibs）无此成员；
        // 用 CFStringConvert 跨平台拿到 NSStringEncoding。
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        if let s = String(data: data, encoding: gb18030) {
            return (s, "gb18030")
        }
        if let s = String(data: data, encoding: .utf16) {
            return (s, "utf-16")
        }
        // Fallback: lossy ISO Latin-1 style
        let s = String(decoding: data, as: UTF8.self)
        return (s, "utf-8-lossy")
    }

    /// 富文本标记命中检测（纯函数，便于 CI 自检）。命中即提示用户在 TextEdit 里用
    /// 「格式→制作纯文本」清理，避免富文本保存破坏 Markdown 源。阈值保守：纯
    /// ASCII / UTF-8 / GB18030 文本的非预期控制符正常为 0，不会误报。
    static func looksLikeRichText(_ text: String) -> Bool {
        if text.hasPrefix("{\\rtf1") { return true }
        if text.range(of: "\\\\object\\\\objhtml", options: .regularExpression) != nil { return true }
        if text.range(of: "\\\\fonttbl", options: .regularExpression) != nil { return true }
        // 前 2KB 内非预期控制符密集出现（\x00-\x08 \x0B \x0C \x0E-\x1F；放行 \t \n \r）。
        let head = text.prefix(2048)
        var ctrl = 0
        for c in head {
            guard let s = c.asciiValue else { continue }
            if s < 9 || (s > 10 && s < 13) || (s > 13 && s < 32) {
                ctrl += 1
                if ctrl >= 4 { return true }
            }
        }
        return false
    }
}
