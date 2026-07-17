import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled reader UI under mdeasy-app:// so scripts load like a normal origin
/// (avoids file:// + ESM module issues).
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdeasy-app"

    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.badURL)
            return
        }

        // mdeasy-app://reader/index.html  or  mdeasy-app://reader/app.js
        var rel = url.path
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        if rel.isEmpty { rel = "index.html" }

        guard let fileURL = Self.resolve(root: root, relative: rel) else {
            urlSchemeTask.didFailWithError(SchemeError.notFound)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = Self.mimeType(for: fileURL)
            let response = URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    static func resolve(root: URL, relative: String) -> URL? {
        let base = root.standardizedFileURL
        let cleaned = relative
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\", with: "/")
        // reject .. escape
        if cleaned.split(separator: "/").contains("..") { return nil }
        let candidate = base.appendingPathComponent(cleaned).standardizedFileURL
        let basePath = base.path
        let candidatePath = candidate.path
        guard candidatePath == basePath || candidatePath.hasPrefix(basePath + "/") else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "map": return "application/json"
        default:
            if #available(macOS 11.0, *) {
                if let type = UTType(filenameExtension: url.pathExtension),
                   let mime = type.preferredMIMEType {
                    return mime
                }
            }
            return "application/octet-stream"
        }
    }

    private enum SchemeError: LocalizedError {
        case badURL
        case notFound
        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad app URL"
            case .notFound: return "App resource not found"
            }
        }
    }
}
