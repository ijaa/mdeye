# MDEye

Local-first **Markdown reader for macOS** (not an editor / note vault).

> Small · Fast · No account · No network · No distraction · Focus on reading

Inspired by [MDView](https://www.mdview.cn/).

**Current version: v0.4.0** · [Releases](https://github.com/ijaa/mdeye/releases)

**Languages:** English | [中文](README.zh-CN.md)

---

## Features

- Open / drag-drop / **double-click** `.md` (can be set as default app)
- GFM: tables, task lists, autolinks, etc.
- **Mermaid** diagrams (bundled, offline)
- Auto-refresh when the file changes on disk
- Outline (H1–H3)
- Themes: Light / Dark / Sepia / Green
- Local relative images (sandboxed to the markdown folder tree)
- Export PDF
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

VERSION=0.4.0 ./scripts/package-dmg.sh
# → build/mdeye-0.4.0.dmg
```

### Without Xcode

`git push` / tag → Actions produces unsigned `.app` / `.dmg`.

```bash
git tag v0.2.x
git push origin v0.2.x
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
  · main.swift explicit NSApplication.run  (also: --selftest headless CI mode)
  · open urls / openFile / openFiles  (single-file: only the last path renders)
  · mdeye-app:// loads UI (AppSchemeHandler)
  · mdeye-asset:// serves local images (AssetSchemeHandler)
  · PathSandbox: shared safe relative-path join + ".." guard for both schemes
  · WKScriptMessageHandler bridge
  · PDF export via WKWebView.createPDF + injected print-mode CSS + bridge-measured full-height rect (no JS HTML assembly)
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
6. Export is **PDF only**, via native `WKWebView.createPDF` + injected print-mode CSS + bridge-measured full-doc `scrollHeight` rect — no JS-side HTML re-assembly

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
| `scripts/ci-selftest.sh` | Headless `--selftest` render self-check (no GUI; CI) |

---

## Version & release

- Version: `CFBundleShortVersionString` / `CFBundleVersion` in `App/Info.plist` (currently **0.4.0 / 12**)
- CI: push → build + structural gates (IIFE, universal binary, icon path)
- Release: tag `v*` → dmg + GitHub Release notes (includes Open Anyway steps)

Builds are **unsigned self-use** (no Apple Developer fee). Consider Developer ID + notarization only for public distribution.

---

## License

Apache License 2.0 (see [LICENSE](LICENSE))
