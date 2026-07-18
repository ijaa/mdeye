import Foundation
import AppKit
import UniformTypeIdentifiers

enum DefaultAppService {
    /// Claim default handler for Markdown types / extensions.
    @discardableResult
    static func setAsDefaultMarkdownViewer() -> (ok: Bool, message: String) {
        let bundleId = Bundle.main.bundleIdentifier ?? "app.mdeye.mdeye"
        var claimed: [String] = []
        var failed: [String] = []

        // Prefer markdown-specific UTIs; avoid claiming all plain text globally.
        let primaryTypes = [
            "app.mdeye.markdown",
            "net.daringfireball.markdown",
            "net.ika.markdown",
            "com.unknown.md",
        ]

        for typeId in primaryTypes {
            let status = LSSetDefaultRoleHandlerForContentType(
                typeId as CFString,
                .all,
                bundleId as CFString
            )
            if status == noErr {
                claimed.append(typeId)
            } else {
                let status2 = LSSetDefaultRoleHandlerForContentType(
                    typeId as CFString,
                    .viewer,
                    bundleId as CFString
                )
                if status2 == noErr {
                    claimed.append("\(typeId) (viewer)")
                } else {
                    failed.append("\(typeId) (\(status)/\(status2))")
                }
            }
        }

        if #available(macOS 11.0, *) {
            let extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx"]
            for ext in extensions {
                if let type = UTType(filenameExtension: ext) {
                    let status = LSSetDefaultRoleHandlerForContentType(
                        type.identifier as CFString,
                        .all,
                        bundleId as CFString
                    )
                    if status == noErr {
                        claimed.append(".\(ext)")
                    } else {
                        let status2 = LSSetDefaultRoleHandlerForContentType(
                            type.identifier as CFString,
                            .viewer,
                            bundleId as CFString
                        )
                        if status2 == noErr {
                            claimed.append(".\(ext) (viewer)")
                        } else {
                            failed.append(".\(ext) (\(status)/\(status2))")
                        }
                    }
                }
            }
        }

        let uniqueClaimed = Array(Set(claimed)).sorted()
        if !uniqueClaimed.isEmpty {
            let message = """
            MDEye registered for Markdown types:
            \(uniqueClaimed.joined(separator: ", "))

            If double-click still opens another app:
            1. Select a .md file in Finder
            2. File → Get Info (⌘I)
            3. Open with → MDEye → Change All…

            Tip: keep mdeye.app in /Applications for reliable association.
            """
            return (true, message)
        }

        let message = """
        Automatic registration failed.

        Use Finder (always works):
        1. Select a .md file
        2. File → Get Info (⌘I)
        3. Open with → MDEye → Change All…
        """
        return (false, message)
    }
}
