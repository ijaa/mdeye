# mdeasy

本地优先的 **macOS Markdown 阅读器**（不是编辑器 / 笔记库）。

> 小体积 · 快启动 · 不登录 · 不联网 · 不打扰 · 专注阅读

灵感来自 [MDView](https://www.mdview.cn/)。

**当前版本：v0.2.8** · [Releases](https://github.com/ijaa/mdeasy/releases)

**语言：** [English](README.md) | 中文

---

## 功能

- 打开 / 拖放 / **双击** `.md`（可设为默认应用）
- GFM：表格、任务列表、自动链接等
- **Mermaid** 图表（完整打包、离线）
- 磁盘文件变更后自动刷新
- 大纲（H1–H3）
- 主题：Light / Dark / Sepia / Green
- 本地相对路径图片（限制在 md 所在目录树）
- 导出 PDF
- 全离线、无遥测
- **Universal Binary**（Apple Silicon `arm64` + Intel `x86_64`）
- 自定义圆角图标（透明角，无黑边）

---

## 安装（自用 · 未签名）

1. 从 [Releases](https://github.com/ijaa/mdeasy/releases) 下载 `mdeasy-x.y.z.dmg`
2. 将 `mdeasy.app` 拖到 **应用程序**
3. 首次打开：若被拦截 → **系统设置 → 隐私与安全性 → 仍要打开**
4. 设为默认 Markdown 应用（任选其一）：

### A. 应用内（推荐）

菜单 **mdeasy → Set as Default Markdown App…**

### B. Finder（最稳妥）

1. 选中任意 `.md`
2. **显示简介**（`⌘I`）
3. **打开方式 → mdeasy → 全部更改…**

---

## 环境要求

| 用途 | 要求 |
|------|------|
| 运行 | macOS 12+ |
| 开发 reader UI | Node.js 18+ |
| 编译 `.app` | Xcode（本仓库默认用 GitHub Actions `macos-14`；笔记本可不装 Xcode） |

---

## 开发

### 只改阅读器前端

```bash
cd reader
npm ci
npm run build      # esbuild → 单文件 IIFE app.js
npm run preview    # 浏览器预览
npm test
```

产物同步进 App 包资源：

```bash
./scripts/build-reader.sh
./scripts/sync-reader-to-app.sh
# → App/Resources/reader/{index.html,app.js,styles/}
```

### 有 Xcode 时本地打 app

```bash
./scripts/build-reader.sh
./scripts/sync-reader-to-app.sh
./scripts/ci-xcodebuild.sh
# → build/mdeasy.app（强制 arm64 + x86_64）

VERSION=0.2.8 ./scripts/package-dmg.sh
# → build/mdeasy-0.2.8.dmg
```

### 无 Xcode

`git push` / 打 tag → Actions 产出 unsigned `.app` / `.dmg`。

```bash
git tag v0.2.x
git push origin v0.2.x
```

### 图标

源图建议：圆角外 **透明** 的 PNG 最佳；JPEG 圆角外常被填黑。

```bash
# 本地有 Pillow 时，可从 JPEG 自动抠黑边为透明再生成 icns：
./scripts/build-icon.sh ~/Downloads/mdeasy-icon.jpeg
# → App/AppIcon.icns 与 App/Assets/mdeasy-icon-transparent.png
```

图标必须落在包内：

```text
mdeasy.app/Contents/Resources/AppIcon.icns
```

（不能嵌套在 `Contents/Resources/Resources/` 下。）

换图标后若 Dock 仍显示旧图：

```bash
rm -rf ~/Library/Caches/com.apple.iconservices.store
killall Dock Finder
```

### 冒烟验证（确认双击能渲染正文）

安装 app 后：

```bash
./scripts/verify-open.sh /path/to/mdeasy.app
# 成功时会写 /tmp/mdeasy-last-shown.json（doc-shown 戳记）
```

---

## 仓库结构

```text
App/
  Sources/           # Swift：窗口、WKWebView、桥接、文件监听、默认应用
  Resources/reader/  # 同步后的静态阅读器（index.html + IIFE app.js + css）
  AppIcon.icns       # 扁平资源 → Contents/Resources/AppIcon.icns
  Assets/            # logo 源图、透明 PNG 缓存
  Info.plist
  mdeasy.xcodeproj/
reader/              # 前端源码（markdown-it + mermaid + esbuild IIFE）
scripts/             # 构建 / 同步 / 图标 / dmg / 冒烟
fixtures/            # 样例 md
.github/workflows/   # ci.yml + release.yml
docs/architecture.md
README.md            # 英文
README.zh-CN.md      # 中文
```

### 关键架构（与实现对齐）

```text
Swift (AppKit)
  · main.swift 显式 NSApplication.run
  · 打开文件：open urls / openFile / openFiles
  · mdeasy-app:// 加载 UI（AppSchemeHandler）
  · mdeasy-asset:// 提供本地图片（AssetSchemeHandler）
  · WKScriptMessageHandler 桥接
        ↕
Static reader (IIFE app.js，禁止 type=module)
  · markdown-it GFM + 大纲 + 主题
  · mermaid 静态打入同一 bundle
```

**重要实现约束（踩坑结论）：**

1. WKWebView 下 **不要用 ESM `type=module` + chunks**（`file://` / 分片加载会失败 → 正文空白）
2. 使用 **单文件 classic script（IIFE）** + **`mdeasy-app://`**
3. 冷/热打开要保留 `latestDoc` 并在 JS ready / 重试后推送
4. 图标必须在 `Contents/Resources/AppIcon.icns`，且圆角外需 **透明**

更多细节见：[docs/architecture.md](docs/architecture.md)

---

## 脚本一览

| 脚本 | 作用 |
|------|------|
| `scripts/build-reader.sh` | `npm ci` + 构建 reader |
| `scripts/sync-reader-to-app.sh` | `reader/dist` → `App/Resources/reader` |
| `scripts/ci-xcodebuild.sh` | Release 通用架构编译 + 体积/图标/架构门禁 |
| `scripts/package-dmg.sh` | 未签名 dmg |
| `scripts/build-icon.sh` | 生成 `AppIcon.icns` |
| `scripts/process-icon-alpha.py` | JPEG 黑角 → 透明 PNG（需本地 Pillow） |
| `scripts/verify-open.sh` | 冷/热打开渲染冒烟（本机 GUI；会装入 /Applications） |
| `scripts/ci-selftest.sh` | 无头 `--selftest` 渲染自检（无需 GUI；CI 用） |

---

## 版本与发布

- 版本号：`App/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`（当前 **0.2.8 / 10**）
- CI：push → 构建 + 结构门禁（IIFE、通用二进制、图标路径）
- Release：tag `v*` → dmg + GitHub Release 说明（含「仍要打开」）

当前为 **未签名自用构建**（无需 Apple Developer 年费）。公开分发再考虑 Developer ID + 公证。

---

## License

MIT（见 [LICENSE](LICENSE)）
