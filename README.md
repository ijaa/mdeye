# MDEye

Local-first **Markdown reader for macOS** (not an editor / note vault).

> Small · Fast · No account · No network · No distraction · Focus on reading

Inspired by [MDView](https://www.mdview.cn/).

**Current version: v0.6.0** · [Releases](https://github.com/ijaa/mdeye/releases)

**Languages:** English | [中文](README.zh-CN.md)

---

## Features

- Open / drag-drop / **double-click** `.md` (can be set as default app)
- GFM: tables, task lists, autolinks, etc.
- **Mermaid** diagrams (bundled, offline)
- Auto-refresh when the file changes on disk
- Outline (H1–H3)
- Themes: Light / Dark / Sepia / Green (Sepia by default)
- Local relative images (sandboxed to the markdown folder tree)
- Export PDF from the toolbar or the MDEye menu
- Fully offline, no telemetry
- **Universal Binary** (Apple Silicon `arm64` + Intel `x86_64`)
- Custom rounded app icon (transparent corners, no black frame)

---

## Install (self-use, unsigned)

1. Download `mdeye-x.y.z.dmg` from [Releases](https://github.com/ijaa/mdeye/releases)
2. Drag `mdeye.app` into **Applications**
3. First launch: if blocked → **System Settings → Privacy & Security → Open Anyway**
4. Set as default Markdown app (either):

### A. In-app (recommended)

Menu **MDEye → Set as Default Markdown App…**

### B. Finder (most reliable)

1. Select any `.md` file  
2. **Get Info** (`⌘I`)  
3. **Open with → MDEye → Change All…**

---

## Requirements

| Use case | Requirement |
|----------|-------------|
| Run | macOS 12+ |
| Develop reader UI | Node.js 18+ |
| Build `.app` | Xcode (default: GitHub Actions `macos-14`; laptop Xcode optional) |

---

## PDF export

PDF export uses a dedicated print WebView that renders the same Markdown pipeline as the reader, including code highlighting, local images, and Mermaid. It waits for fonts, images, diagrams, and layout to stabilize, then uses the native WebKit print pipeline to paginate onto A4 paper with 16 mm margins. Print-specific CSS removes reading controls and uses a paper-friendly light theme, so the document content and typography remain aligned with the app while navigation chrome and screen theme colors are intentionally excluded.

The reading WebView is not modified during export. CI runs the production export coordinator against a long fixture, validates a real multi-page PDF, and includes `pdf-selftest.pdf` in the `mdeye-app` artifact.

---

## Development

### Reader frontend only

```bash
cd reader
npm ci
npm run build      # esbuild → single IIFE app.js
npm run preview    # browser preview
npm test
```

Sync build output into the app bundle resources:

```bash
./scripts/build-reader.sh
./scripts/sync-reader-to-app.sh
# → App/Resources/reader/{index.html,app.js,styles/}
```

### Local app build (with Xcode)

```bash
./scripts/build-reader.sh
./scripts/sync-reader-to-app.sh
./scripts/ci-xcodebuild.sh
# → build/mdeye.app (forces arm64 + x86_64)

VERSION=0.6.0 ./scripts/package-dmg.sh
# → build/mdeye-0.6.0.dmg
```

### Without Xcode

Pushes and pull requests run the full app build and PDF self-test. To build without creating a tag, open **Actions → CI → Run workflow**; download the `mdeye-app` artifact after the `mac-app` job succeeds. Release tags produce the unsigned `.dmg`.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

### App icon

Prefer a **PNG with transparent outside corners**. JPEG rounded exports often fill the exterior with black.

```bash
# With Pillow installed, convert JPEG black exterior → transparent, then icns:
./scripts/build-icon.sh ~/Downloads/mdeye-icon.jpeg
# → App/AppIcon.icns and App/Assets/mdeye-icon-transparent.png
```

Icon must live at:

```text
mdeye.app/Contents/Resources/AppIcon.icns
```

(Not nested under `Contents/Resources/Resources/`.)

If Dock still shows an old icon after replacing:

```bash
rm -rf ~/Library/Caches/com.apple.iconservices.store
killall Dock Finder
```

### Smoke test (double-click actually renders body)

After installing the app:

```bash
./scripts/verify-open.sh /path/to/mdeye.app
# On success writes /tmp/mdeye-last-shown.json (doc-shown stamp)
```

---

## Repository layout

```text
App/
  Sources/           # Swift: window, WKWebView, bridge, file watch, default app, PathSandbox, SelfTest
  Resources/reader/  # synced static reader (index.html + IIFE app.js + css)
  AppIcon.icns       # flat resource → Contents/Resources/AppIcon.icns
  Assets/            # logo source + transparent PNG cache
  Info.plist
  mdeye.xcodeproj/
reader/              # frontend (markdown-it + mermaid + esbuild IIFE)
scripts/             # build / sync / icon / dmg / render self-tests
fixtures/            # sample markdown
.github/workflows/   # ci.yml + release.yml
docs/architecture.md
README.md            # English
README.zh-CN.md      # Chinese
```

### Architecture (matches implementation)

```text
Swift (AppKit)
  · main.swift explicit NSApplication.run  (also: --selftest / --pdf-selftest CI modes)
  · open urls / openFile / openFiles  (single-file: only the last path renders)
  · mdeye-app:// loads UI (AppSchemeHandler)
  · mdeye-asset:// serves local images (AssetSchemeHandler)
  · PathSandbox: shared safe relative-path join + ".." guard for both schemes
  · WKScriptMessageHandler bridge
  · PDF export via a dedicated file-backed WKWebView + A4 NSPrintOperation pagination
        ↕
Static reader (IIFE app.js — no type=module)
  · markdown-it GFM + outline + themes
  · mermaid statically bundled
```

**Hard constraints (lessons learned):**

1. Do **not** use ESM `type=module` + chunks under WKWebView (`file://` / chunk load fails → blank body)
2. Use a **single classic IIFE script** + **`mdeye-app://`**
3. Keep `latestDoc` across cold/warm open; push after JS ready / retries
4. Icon must be `Contents/Resources/AppIcon.icns` with **transparent** exterior
5. Single-file reader: render only the last-opened path; no multi-window/tabs
6. Export is **PDF only**, via a dedicated file-backed WKWebView + `@media print` + A4 `NSPrintOperation`; the reading webview is never mutated

More detail: [docs/architecture.md](docs/architecture.md)

---

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/build-reader.sh` | `npm ci` + build reader |
| `scripts/sync-reader-to-app.sh` | `reader/dist` → `App/Resources/reader` |
| `scripts/ci-xcodebuild.sh` | Release universal build + size/icon/arch gates |
| `scripts/package-dmg.sh` | Unsigned dmg |
| `scripts/build-icon.sh` | Generate `AppIcon.icns` |
| `scripts/process-icon-alpha.py` | JPEG black corners → transparent PNG (needs Pillow) |
| `scripts/verify-open.sh` | Cold/warm open render smoke test (local GUI; installs into /Applications) |
| `scripts/ci-selftest.sh` | Headless render + multi-page PDF export self-checks (CI) |

---

## Version & release

- Version: `CFBundleShortVersionString` / `CFBundleVersion` in `App/Info.plist` (currently **0.6.0 / 14**)
- CI: push / pull request / manual `workflow_dispatch` → app build, structural gates, render self-test, and production multi-page PDF export self-test
- Release: tag `v*` → dmg + GitHub Release notes (includes Open Anyway steps)

Builds are **unsigned self-use** (no Apple Developer fee). Consider Developer ID + notarization only for public distribution.

---

## License

Apache License 2.0 (see [LICENSE](LICENSE))
