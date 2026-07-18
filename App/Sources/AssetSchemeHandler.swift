import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves local images/assets under the current markdown baseDir only.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdeye-asset"

    var baseDir: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.badURL)
            return
        }

        // mdeye-asset://local/relative/path.png
        let rel = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseDir,
              let fileURL = FileService.resolveAsset(baseDir: baseDir.path, relative: rel) else {
            urlSchemeTask.didFailWithError(SchemeError.forbidden)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = mimeType(for: fileURL)
            let response = URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for url: URL) -> String {
        if #available(macOS 11.0, *) {
            if let type = UTType(filenameExtension: url.pathExtension),
               let mime = type.preferredMIMEType {
                return mime
            }
        }
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private enum SchemeError: LocalizedError {
        case badURL
        case forbidden
        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad asset URL"
            case .forbidden: return "Asset path not allowed"
            }
        }
    }
}
