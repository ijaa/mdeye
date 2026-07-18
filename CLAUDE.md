# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 本仓库所有面向人类的文档（README、架构文档、CLAUDE.md、脚本注释、PR 描述、commit message 说明等）**必须使用中文**编写。代码标识符、技术专有名词、命令、API 名保持原样，但叙述性内容一律中文。新增或修改文档时遵循此规则。

MDEye 是一个本地优先的 **macOS Markdown 阅读器**（不是编辑器/笔记库）。技术形态为 Swift（AppKit）薄壳 + WKWebView，渲染一个静态的 IIFE 前端 bundle。目标平台 macOS 12+，Universal 二进制（`arm64` + `x86_64`），未签名（自用），完全离线、无遥测。

## 常用命令

### Reader 前端（`reader/`）
```bash
cd reader
npm ci
npm run build        # esbuild → 单文件 IIFE dist/app.js（约 2.8 MB，含 mermaid）
npm run dev         # build.mjs --watch（变更即重建，开启 sourcemap）
npm run preview      # 在 http://localhost:5179 预览 reader/dist
npm test             # node --test test/*.test.mjs
node --test test/md.test.mjs   # 只运行单个测试文件
```
`npm test` 跑的是 `src/md.js` 的纯函数单测（slugify/CJK、图片重写、大纲、mermaid、task-list、hljs）以及一个依赖解析测试。这部分不需要 Xcode。

### 同步 reader 进 app 并构建 app
```bash
./scripts/build-reader.sh          # npm ci + 构建 reader
./scripts/sync-reader-to-app.sh    # reader/dist → App/Resources/reader
./scripts/ci-xcodebuild.sh         # xcodebuild universal（arm64+x86_64）→ build/mdeye.app（需要 Xcode）
VERSION=0.4.0 ./scripts/package-dmg.sh   # → build/mdeye-0.4.0.dmg（未签名）
```

### 本机不装 Xcode 的情形
Reader 开发不依赖本机 Xcode。`git push` / `git tag v*` 会触发 `.github/workflows/{ci,release}.yml`，在 GitHub Actions（`macos-14`）上构建未签名的 `.app`/`.dmg`。

### 图标
```bash
./scripts/build-icon.sh ~/Downloads/mdeye-icon.jpeg   # 需 Pillow（build-icon.sh / process-icon-alpha.py）
```

### 渲染自检
```bash
./scripts/verify-open.sh /path/to/mdeye.app     # 本机 GUI 烟测：冷/热打开 → /tmp/mdeye-last-shown.json
./scripts/ci-selftest.sh build/mdeye.app         # 无头：执行 `mdeye --selftest`；CI 使用
```

## 架构

由名为 `mdeye` 的 `WKScriptMessageHandler` 桥接两半：

**Swift 薄壳（`App/Sources/`）**
- `main.swift` — 显式 `NSApplication.run`（不只是 `@main`）；同时处理 `--selftest` 无头 CI 模式。
- `AppDelegate.swift` — 生命周期 + 打开文件队列。**单文件语义：**多个文件同时到达时只渲染最后一个 path。绝不做多窗口/多标签。
- `MainWindowController.swift` — 窗口与菜单（打开/重载/导出 PDF/Finder/编辑器/大纲/主题/设为默认应用）。
- `ReaderViewController.swift` — 持有 WKWebView、桥接和 `latestDoc` 推送/重试逻辑。优先用 `callAsyncJavaScript` 推送，失败回退 base64 `evaluateJavaScript`；JS 发出 `ready` 之前保留 `latestDoc`（也在 `didFinish` / 重试时再推)，以跨越打开竞态。
- `AppSchemeHandler.swift` — `mdeye-app://` 提供 reader UI（不走裸 `file://`）。
- `AssetSchemeHandler.swift` — `mdeye-asset://` 提供本地相对图片，沙箱限制在 markdown 文件夹树内。
- `PathSandbox.swift` — **两个 handler 共用**的安全相对路径拼接 + `..` 逃逸防护。两个 handler 必须都经过它，不能各自实现导致行为不一致。
- `FileService.swift` / `FileWatcher.swift` — 读文本 + `DispatchSource` 变更监听带 debounce（外部保存后自动重渲染，保留滚动位置）。
- `DefaultAppService.swift` — `LSSetDefaultRoleHandlerForContentType`。
- `SelfTest.swift` — `--selftest`：以 `.accessory` 激活策略启动、不开窗、不抢前台，加载 `mdeye-app://reader/index.html` 并推 doc，等 JS 回传 `doc-shown` 后退出。只验证渲染管线到 `doc-shown`；系统打印面板/PDF 仍需 GUI 测试覆盖。
- `Preferences.swift` — 主题等偏好，经 `UserDefaults`。

**静态 reader（`reader/`）**
- `src/app.js` — 入口；markdown-it（GFM + anchor + task-lists）+ mermaid（静态打进 bundle，不走 CDN）+ 大纲 + 主题。默认 `html:false`（不渲染 markdown 原始 HTML）。
- `src/md.js` — 纯渲染辅助函数（单测覆盖）。
- `build.mjs` — esbuild `format:"iife"`、`globalName:"mdeyeReader"`、`target:["safari14"]`、**禁止 splitting**。把 `App/Info.plist` 的 `CFBundleShortVersionString` 注入为 `__MDEYE_VERSION__`（版本号的唯一真源），使 JS 的 `ready` 握手报出与 app 一致的版本。
- `index.html` — 以 **classic 非 module** script 发出，带适配 `mdeye-app://` 的 CSP。**不要加 `type="module"`** —— CI 会拒绝。
- `styles/` — 主题（Light/Dark/Sepia/Green）、reader、hljs。

**桥接协议**
- Swift → JS 通过 `window.__mdeye.handle`：`{type:"doc", path, baseDir, text, encoding, mtimeMs}`、`{type:"theme", name}`、`{type:"toggle-outline"}`。
- JS → Swift 通过 `webkit.messageHandlers.mdeye`：`{type:"ready", version?}`、`{type:"doc-shown", path, chars, hasMermaid}`（写烟测戳记 `/tmp/mdeye-last-shown.json`）、`{type:"set-preference", key, value}`、`{type:"open-md-link", href}`（正文点击同类 .md 相对链接，Swift 在当前文档 baseDir 树内复用 `FileService.resolveAsset` 解析 → `openFile` 单文件替换）、`{type:"export-pdf-measured", width, height}`（导出 PDF 时 JS 注入打印态 CSS + 实测整篇 `scrollHeight` 回传，Swift 据此设 `WKPDFConfiguration.rect`），以及 open-in-editor / reveal-in-finder / error。
- **PDF 导出。** Swift 用原生 `WKWebView.createPDF(configuration:)` 直出 PDF `Data` → `NSSavePanel` 写盘。导出前用 `evaluateJavaScript` 注入一段"打印态" `<style id="mdeye-print-mode">`（隐藏 `.outline/.toolbar`、`#app/#main` 改 `display:block`、`.markdown-body` 撑开成整篇高度，解除屏幕态 `html,body{height:100%}` 锁死），JS 经桥接 `export-pdf-measured` 回传整篇 `scrollHeight`，Swift 设 `WKPDFConfiguration.rect = (clientWidth, scrollHeight)` 让 `createPDF` 按整篇高切片多页；导出后无论成败移除注入样式恢复阅读态。**不走 `callAsyncJavaScript` 取尺寸**——实测它在 `mdeye-app://` 自定义协议 webview 上始终返回 nil；也不走系统打印面板「PDF ▾ → 另存为 PDF」——实测该路径对自定义协议 webview 输出**文件空白**（预览却有内容），故弃用。没有 JS 侧拼 HTML。

## 硬约束（不得回退）

这些是用踩坑换来的规则，其中数条由 CI 主动门禁。

1. **WKWebView 下不得用 ESM / `type=module` / 动态 import 分包。** `file://`/自定义协议下 chunk 加载会失败 → 白屏。必须保持**单一 classic IIFE**。CI 断言：`index.html` 无 `type="module"`、`app.js` 不以 `import` 开头、`app.js` 含 `__mdeye`。
2. **单文件 reader 语义。** 多选打开只渲染最后一个 path。不要加多窗口/标签。
3. **冷/热打开都要保留 `latestDoc`**，并在 JS ready 后推送 + 重试。这是修复"有窗口无正文"竞态的关键。
4. **图标必须是 `Contents/Resources/AppIcon.icns`**（扁平单文件，**不**嵌在 `.../Resources/Resources/` 下）。外侧**透明**（JPEG 会把圆角外填成黑色；用 `process-icon-alpha.py`）。`CFBundleIconFile = AppIcon`。
5. **导出仅 PDF**，走原生 `WKWebView.createPDF(configuration:)` 直出 PDF `Data` 写盘；导出前注入打印态 `<style>`（隐藏 `.outline/.toolbar`、撑开 `.markdown-body` 全高）+ 经桥接 `export-pdf-measured` 取整篇 `scrollHeight` 设 `rect` —— 不走 `callAsyncJavaScript`（自定义协议 webview 返回 nil）、不走系统打印面板「另存为 PDF」（自定义协议 webview 输出空白）、不在 JS 侧重组 HTML。
6. **强制 Universal 二进制**（`ARCHS="arm64 x86_64"`，Release `ONLY_ACTIVE_ARCH=NO`）。CI 断言二进制同时含 `x86_64` 与 `arm64`。
7. **版本号唯一真源是 `App/Info.plist`**（`CFBundleShortVersionString` + `CFBundleVersion`）。`build.mjs` 读取注入；不要在 JS 里硬编码版本。

## 布局坑

- `App/Resources/reader/` 是作为 fallback bundle 提交进 git 的（Xcode/CI 在重建前也总有资源）。优先用 `./scripts/build-reader.sh && ./scripts/sync-reader-to-app.sh` 重新生成。`reader/dist/` 被 gitignore。
- Xcode 的 `Resources/` **folder 引用**会把内容拷到 `Contents/Resources/Resources/...`（双层嵌套）。reader 代码内部按多候选路径查找以容忍这点。但 `AppIcon.icns` 必须作为**单独资源文件**配置 → `Contents/Resources/AppIcon.icns`，不要走 folder 引用。
- 换图标后 Dock 仍显示旧图时：`rm -rf ~/Library/Caches/com.apple.iconservices.store && killall Dock Finder`。

## CI 门禁（`.github/workflows/ci.yml`）
- `reader` job（ubuntu）：`npm ci && npm test && npm run build`，上传 `reader-dist`。
- `mac-app` job（macos-14）：构建 reader、同步、`ci-xcodebuild.sh`，随后断言 bundle 健全性：IIFE（无 module）、含 `__mdeye`、Universal 架构、图标在 `Contents/Resources/AppIcon.icns`，以及无头 `--selftest` 渲染（`ci-selftest.sh`）。
- app 体积门禁默认 20 MB（`MAX_APP_KB`）。
- 发布：打 `v*` tag 或 `workflow_dispatch` → `.github/workflows/release.yml` 构建 app + dmg 进入 GitHub Release。

## 版本发布
在 `App/Info.plist` 改 `CFBundleShortVersionString`（通常一并改 `CFBundleVersion`）。`build.mjs` 会自动读取，无需在 JS 硬编码。然后打 `v*` tag 触发发布工作流。

### 发版前必须本机/CI 编译验证（0.5.0 教训）
- **不要只靠记忆/猜测 AppKit/WebKit Swift API 签名。** 0.5.0 发布时 PDF 导出从原生 `createPDF` 切到系统打印管线，连续两次因 API 名错（误用 `guard let` 接非可选、把属于 `NSPrintPanel` 的 `runOperationModal(for:delegate:didRun:contextInfo:)` 当成 `NSPrintOperation` 的方法、`runOperation()` 已 rename 为 `run()`）导致 `release.yml` 编译失败、来回 force-update tag 重跑。最终正确入口只是 `printOp.run()`。
- **本机无 Xcode 时更要在 push 前用某种方式过编译。** 仓库已沉淀两条路：(1) 本机装 Xcode 跑 `./scripts/ci-xcodebuild.sh`；(2) push 到普通分支让 `ci.yml` 的 `mac-app` job 先跑通 Universal 编译（见下条建议），再打 tag 触发 `release.yml`。**严禁跳过编译直接打 tag 发布 Swift 改动**。
- **可加的安全网（建议）**：让 `ci.yml` 在 push 到 `main`（非 tag）也触发 `mac-app` 编译 job，使"push 后即可知编译错"而非"tag 后才发现"。当前 `release.yml` 仅 tag 触发，编译错会在发版末段才暴露。
- **覆盖盲区**：无头 `--selftest` 只验渲染到 `doc-shown`；打印面板、`NSSavePanel`、PDF 落盘等 GUI 交互**不在 CI 覆盖范围**，需本机 GUI 烟测。改这些路径时尤其要先本机编译+手测。
