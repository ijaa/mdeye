# MDEye Architecture (implementation · v0.7.0)

> 中文说明：本文件为技术架构文档（原「技术方案」）。

> **产品**：本地优先的 Markdown **阅读器**（不是编辑器 / 笔记库）  
> **对标**：[MDView](https://www.mdview.cn/)  
> **平台**：仅 **macOS 12+**  
> **架构**：Swift 薄壳 + WKWebView + 静态 reader（IIFE）  
> **工程**：本地可不装 Xcode；**GitHub Actions** 编译打包  
> **分发**：无 Apple Developer 证书；unsigned + **系统设置 → 隐私与安全性 → 仍要打开**  
> **代码版本**：`CFBundleShortVersionString` **0.7.0** / `CFBundleVersion` **15**

本文档描述 **当前仓库真实实现**，并保留产品决策与踩坑结论。历史「拆包 Mermaid / Tauri / 5–10MB 目标」等过程选项已收敛为下列定案。

---

## 0. 决策一览（现状）

| 议题 | 决策（已实现） |
|------|----------------|
| 产品形态 | 阅读器 only；打开 md 即读 |
| 单文件 | **始终渲染一个文件**；多选打开只取最后一个，不做多窗口/标签 |
| 导出 | **仅 PDF**（独立 file-backed `WKWebView` + `NSPrintOperation` A4 分页 + 打印专用浅色样式）；不做 HTML 导出 |
| 平台 | **仅 macOS**（不做 Win / Android） |
| 壳 | **Swift + AppKit + WKWebView** |
| 前端 | **esbuild 单文件 IIFE**（无 Svelte/React，**无 ESM module**） |
| Mermaid | **完整内置**（静态 import，打进 `app.js`） |
| UI 加载 | 自定义协议 **`mdeye-app://`**（非裸 `file://` 主路径） |
| 本地图片 | **`mdeye-asset://`** + baseDir 沙箱 |
| 架构 | **Universal**：`arm64` + `x86_64` |
| 图标 | `Contents/Resources/AppIcon.icns`；圆角外 **透明** |
| 编译 | GitHub Actions `macos-14`；本机可无 Xcode |
| 证书 | 当前不要；方式 B「仍要打开」 |
| 默认应用 | `LSHandlerRank=Owner` + 菜单「Set as Default Markdown App…」 |

---

## 1. 产品目标与边界

### 1.1 目标

| 目标 | 含义 |
|------|------|
| 小体积 | 相对 Electron 很小；完整包含 Mermaid + KaTeX 后 dmg 约 **~1.5–2 MB** 量级（压缩后），`.app` 内 JS 约 **3.1 MB** |
| 快启动 | 中等文档亚秒～秒级可读（首次加载 IIFE 略重） |
| 不登录 / 不联网 / 不打扰 | 无账号、无遥测、无 CDN |
| 专注阅读 | 大纲、主题、字号/栏宽缩放、文内查找；不提供编辑；**始终只渲染一个文件（多选后打开取最后一个）** |
| 实时预览 | 外部编辑器保存 → 自动重渲染 |
| Mermaid | 离线渲染（flowchart / sequence 等） |
| 数学公式 | KaTeX 离线渲染（$inline$ 与 $$display$$） |
| 多主题 | Light / Dark / Sepia / Green；默认 Sepia |
| 字号/栏宽 | ⌘+/⌘-/⌘0 缩放字号（85%–200%），⌥+/⌥- 调整栏宽（600–1100px），持久化偏好 |
| 文内查找 | ⌘F/⌘G/⇧⌘G TreeWalker 高亮匹配 |
| 中文编码 | GB18030 探测支持（跨平台 CFStringConvert） |
| 编辑器集成 | Open in Editor 快速跳转 TextEdit；富文本格式检测与轻提示 |
| 冷启动恢复 | 自动恢复上次打开的文件 |
| PDF 导出 | 独立 file-backed `WKWebView` 渲染同一 reader，收到 `print-ready` 后由 `NSPrintOperation` 按 A4 + 16mm 边距分页并直接保存 |

### 1.2 明确不做

- 多端、WYSIWYG 编辑器、知识库、插件市场、AI
- **多窗口 / 多标签**（始终单文件：多选打开只渲染最后一个）
- 当前阶段 Apple 签名公证
- 依赖本机 Xcode 才能参与 **reader** 开发

### 1.3 与 MDView

| 维度 | MDView | MDEye |
|------|--------|--------|
| 平台 | Win + Android | **仅 macOS** |
| 结构 | 系统 WebView + 薄壳 | 同构 |
| 分发 | 安装包 | 自用 unsigned +「仍要打开」 |
| 图表 | Pro / 按需 | **完整包默认内置** |

---

## 2. 总体架构

```
┌──────────────────────────────────────────────────────────┐
│  mdeye.app (Swift / AppKit)                             │
│  main.swift → NSApplication.run                          │
│  AppDelegate：open urls / openFile / openFiles            │
│  MainWindowController：菜单、默认应用、主题快捷键          │
│  ReaderViewController：WKWebView、桥接、latestDoc 重试     │
│  AppSchemeHandler：mdeye-app://reader/...                │
│  AssetSchemeHandler：mdeye-asset://local/...             │
│  PathSandbox：两 handler 共用相对路径拼接 + .. 防护          │
│  FileService / FileWatcher / DefaultAppService            │
│  PDFExportCoordinator：独立打印 WebView + NSPrintOperation │
│  SelfTest：--selftest / --pdf-selftest（CI 用）             │
└───────────────────────────▲──────────────────────────────┘
                            │ WKScriptMessageHandler "mdeye"
┌───────────────────────────┴──────────────────────────────┐
│  静态 reader（Contents/Resources/Resources/reader/）       │
│  index.html  →  <script src="app.js">  （classic，非 module）│
│  app.js      →  IIFE：markdown-it + mermaid + UI          │
│  styles/     →  themes / reader / hljs                    │
└──────────────────────────────────────────────────────────┘
```

**原则**：系统 WebView 负责渲染；原生只做窗口 / 文件 / 安全 / 系统集成；前端是静态页，不是重型 SPA。

### 2.1 为何坚持 Swift 薄壳

| 方案 | 结论 |
|------|------|
| Swift + WKWebView | **采用**（体积与系统集成最优） |
| Tauri / Electron | 已否（体积或复杂度不符） |

### 2.2 核心用户流程

```
双击 xxx.md（多选时只取最后一个 path）
  → Launch Services 启动 / 激活 mdeye，传入 path
  → AppDelegate enqueue → ReaderViewController.openFile
  → FileService 读文本 → latestDoc
  → WKWebView 已 load mdeye-app://reader/index.html
  → JS ready / didFinish / 重试 → 推送 doc
  → markdown-it 渲染；含 mermaid 则 mermaid.run
  → FileWatcher 监听；保存后再次 openFile（保留滚动位置）
  → 可选：导出 PDF（独立 file-backed WKWebView + NSPrintOperation）/ 默认应用 / 主题
```

---

## 3. 功能规格（已实现）

### 3.1 阅读与渲染

- 扩展名：`.md` / `.markdown` / `.mdown` / `.mkd` / `.mkdn` / `.mdwn` / `.mdx`
- GFM（markdown-it + task-lists + anchor）
- 代码高亮：highlight.js 语言子集
- Mermaid：静态打入 bundle；主题随 Light/Dark 切换
- 大纲 H1–H3 + 滚动高亮
- 四套主题；偏好 `UserDefaults`
- 本地图片：相对路径 → `mdeye-asset://`，禁止 `../` 逃逸
- 默认 **不渲染** markdown 原始 HTML（`html: false`）

### 3.2 系统集成

- 菜单与工具栏：打开、重载、导出（PDF）、Finder、编辑器、大纲、主题、设为默认；工具栏 PDF 按钮复用原生导出协调器
- 拖放打开
- **单文件语义**：`AppDelegate` 对同时到达的多个文件只渲染最后一个（始终一个文档），不做多窗口/标签
- 文档类型 `LSHandlerRank = Owner` + 导出 UTI `app.mdeye.markdown`
- `DefaultAppService`：`LSSetDefaultRoleHandlerForContentType`
- **PDF 导出**：`NSSavePanel` 选路径后创建独立 `PDFExportCoordinator`。协调器用 `file://` 加载同一 reader bundle，注册 `mdeye-asset://` 读取当前文档图片，推送当前 Markdown 与主题；JS 完成 Mermaid、字体、图片和两帧布局后回传 `print-ready`。Swift 随后用 `NSPrintOperation` 按 A4、16mm 边距、WebKit 打印分页直接写入目标 URL，并用 PDFKit 验证至少一页。阅读 WebView 始终保持原样。打印 CSS 默认使用纸张友好的浅色主题，不走 JS HTML 重组，也不再测量 `scrollHeight` 或调用 `createPDF`。
- Universal Binary 强制门禁
- 图标 `CFBundleIconFile = AppIcon`

### 3.3 可靠性（针对历史缺陷）

| 问题 | 修复 |
|------|------|
| 启动无窗口 | `main.swift` 显式 run；`makeKeyAndOrderFront`；reopen；屏外 frame 归位 |
| 双击有窗口无正文 | 去掉 ESM；IIFE + `mdeye-app://`；`latestDoc` + ready/重试 |
| 图标不显示 | icns 扁平拷到 `Contents/Resources/AppIcon.icns` |
| 圆角黑边 | JPEG 黑角 → 透明 alpha 再生成 icns |

---

## 4. 技术栈明细

### 4.1 原生

| 项 | 选择 |
|----|------|
| 语言 | Swift 5 |
| UI | AppKit |
| Web | WKWebView |
| 入口 | `main.swift`（非仅 `@main` AppDelegate） |
| 监听 | `DispatchSource` 文件监视 + debounce |
| 最低系统 | macOS 12.0 |
| 架构 | `ARCHS = arm64 x86_64`，Release `ONLY_ACTIVE_ARCH = NO` |

主要源文件：

| 文件 | 职责 |
|------|------|
| `main.swift` | `NSApplication` + `run()`；分派 `--selftest` / `--pdf-selftest` |
| `AppDelegate.swift` | 生命周期、打开文件队列 |
| `MainWindowController.swift` | 窗口与菜单 |
| `ReaderViewController.swift` | 阅读 WebView、桥接、推送文档；内含独立 `PDFExportCoordinator` |
| `AppSchemeHandler.swift` | `mdeye-app` |
| `AssetSchemeHandler.swift` | `mdeye-asset` |
| `FileService.swift` | 读文件、路径沙箱（经 `PathSandbox`） |
| `FileWatcher.swift` | 变更热更新 |
| `PathSandbox.swift` | `mdeye-app`/`mdeye-asset` 共用相对路径拼接 + `..` 逃逸防护 |
| `SelfTest.swift` | `--selftest` 无头渲染自检；PDF 自检由 `main.swift` 调用生产协调器 |
| `DefaultAppService.swift` | 默认打开方式 |
| `Preferences.swift` | 主题等偏好 |

### 4.2 前端（reader）

| 项 | 选择 |
|----|------|
| 构建 | **esbuild**，`format: "iife"`，**禁止 splitting/ESM** |
| Markdown | markdown-it + markdown-it-anchor + markdown-it-task-lists |
| 高亮 | highlight.js 按需语言 |
| 图表 | **mermaid** 静态 import |
| CSP | `default-src 'none'`；阅读路径允许 `self` / `mdeye-app:`；打印路径额外允许 `file:` 读取随包脚本、样式和字体；图片允许 `mdeye-asset:` / data |

入口：`reader/src/app.js`、`reader/src/md.js` → 产出 `reader/dist/app.js`（约 2.8 MB minify）。

### 4.3 桥接协议（摘要）

**Swift → JS**（`window.__mdeye.handle`）：

- `{ type: "doc", path, baseDir, text, encoding, mtimeMs }`
- `{ type: "theme", name }`
- `{ type: "toggle-outline" }`
- `{ type: "prepare-print" }`（仅打印 WebView）

**JS → Swift**（`webkit.messageHandlers.mdeye`）：

- `{ type: "ready", version? }`（`version` 由 `build.mjs` 从 `App/Info.plist` 的 `CFBundleShortVersionString` 注入 `__MDEYE_VERSION__`）
- `{ type: "doc-shown", path, chars, hasMermaid }`（冒烟戳记 `/tmp/mdeye-last-shown.json`）
- `{ type: "set-preference", key, value }`
- `{ type: "open-md-link", href }`（正文点击同类 .md 相对链接；Swift 在当前文档 baseDir 树内复用 `FileService.resolveAsset` 解析 → `openFile` 单文件替换，跳树/不存在则 `NSAlert`）
- `{ type: "print-ready" }`（仅打印 WebView：字体、图片、Mermaid 与布局稳定，可以启动打印）
- open-in-editor / reveal-in-finder / error

> **PDF 导出桥接**：Swift 向独立打印 WebView 发送 `{type:"prepare-print"}`；JS 等待 `document.fonts.ready`、全部图片、Mermaid 以及两帧布局后回传 `{type:"print-ready"}`。离屏环境的 `requestAnimationFrame` 可能暂停，因此实现还保留定时器唤醒。分页与落盘由 `NSPrintOperation` 完成，纸张参数不由 DOM 尺寸推断。

推送实现优先 `callAsyncJavaScript`，失败则 base64 `evaluateJavaScript` 回退；未 ready 时保留 `latestDoc` 并重试。

---

## 5. 体积与产物

| 产物 | 量级（0.2.x 实测量级） |
|------|------------------------|
| `reader/dist/app.js` | ~2.8 MB（含 mermaid） |
| `AppIcon.icns` | ~0.3–0.5 MB |
| Swift 二进制（universal） | 约数百 KB～1 MB 级 |
| Release **dmg** | 约 **1.5–2 MB** 压缩后 |

CI 体积门禁默认 **20 MB**（`MAX_APP_KB`，完整包余量）。

---

## 6. 工程结构

```text
mdeye/
├── App/
│   ├── Sources/*.swift
│   ├── Resources/reader/     # 提交用 fallback；CI 会重建同步
│   ├── AppIcon.icns          # 必须扁平参与 Resources 构建阶段
│   ├── Assets/
│   │   ├── mdeye-logo.jpeg
│   │   └── mdeye-icon-transparent.png
│   ├── Info.plist
│   ├── project.yml           # XcodeGen 可选源
│   └── mdeye.xcodeproj/
├── reader/
│   ├── src/{app.js,md.js}
│   ├── styles/
│   ├── test/md.test.mjs      # md.js 纯函数单测（node --test）
│   ├── build.mjs             # IIFE 打包 + 版本注入
│   └── package.json
├── scripts/
│   ├── build-reader.sh
│   ├── sync-reader-to-app.sh
│   ├── ci-xcodebuild.sh      # universal + 图标路径门禁
│   ├── package-dmg.sh
│   ├── build-icon.sh
│   ├── process-icon-alpha.py
│   ├── verify-open.sh        # 本机 GUI 烟测
│   └── ci-selftest.sh        # 无头渲染 + 多页 PDF 自检（CI 用）
├── fixtures/sample.md
├── .github/workflows/{ci,release}.yml
├── docs/architecture.md
└── README.md
```

注意：Xcode **folder 引用** `Resources/` 会把内容拷到  
`Contents/Resources/Resources/...`。  
**reader** 接受该嵌套路径（代码内多候选查找）；**AppIcon.icns** 必须作为 **单独资源文件** 拷到 `Contents/Resources/AppIcon.icns`。

---

## 7. CI / 发布

### 7.1 `ci.yml`

1. Node 构建 reader + 单测（`md.js` 纯函数）  
2. 同步资源  
3. `ci-xcodebuild.sh`：`generic/platform=macOS`，`ARCHS="arm64 x86_64"`  
4. 门禁：
   - `index.html` **无** `type="module"`
   - `app.js` 非 ESM 开头、含 `__mdeye`
   - 二进制含 **x86_64 与 arm64**
   - 存在 **`Contents/Resources/AppIcon.icns`**
5. **Headless 自检**：`ci-selftest.sh` 先跑 `mdeye --selftest`，断言 `/tmp/mdeye-last-shown.json` 匹配 fixture；再跑 `mdeye --pdf-selftest <md> <pdf>`，复用生产打印协调器生成并用 PDFKit 校验至少两页的真实 PDF
6. 上传 artifact `mdeye-app`，其中包含 `build/mdeye.app` 与 `build/pdf-selftest.pdf`

### 7.1.1 无 Xcode 时的预览包人工验证

CI 构建来源是远端 commit，而不是本地工作区。待验证改动应先提交并 push 到目标分支，但无需创建 tag。使用 GitHub CLI 手动打包并下载：

```bash
gh workflow run CI --ref main
# 从返回的 Actions URL 获取 run ID，例如 29668349902
CI_RUN_ID=29668349902
gh run watch "$CI_RUN_ID" --exit-status

CI_PREVIEW_DIR="tmp/ci-preview-$CI_RUN_ID"
mkdir -p "$CI_PREVIEW_DIR"
gh run download "$CI_RUN_ID" --name mdeye-app --dir "$CI_PREVIEW_DIR"
open "$CI_PREVIEW_DIR/mdeye.app"
```

人工验证前必须确认 `reader`、Universal 编译、Bundle/IIFE/图标门禁以及渲染/多页 PDF 自检均成功。下载目录统一使用 `tmp/ci-preview-<run-id>/`，例如 `tmp/ci-preview-29668349902/`；artifact 内应有 `mdeye.app/` 与 `pdf-selftest.pdf`。`tmp/` 已在 `.gitignore` 中，预览 App 和 PDF 仅供本地验证，不得提交。

### 7.2 `release.yml`

- tag `v*` 或 workflow_dispatch  
- 构建 app + dmg  
- GitHub Release 正文含安装与「仍要打开」说明  

### 7.2.1 发版前编译验证（0.5.0 教训）

> **Swift 改动严禁跳过编译直接打 tag 发布。**

0.5.0 首次把 PDF 导出从原生 `createPDF` 切到系统打印管线时，本机无 Xcode 无法预编译，靠记忆猜 AppKit/WebKit API，连续两次编译失败 → 反复 force-update tag 重跑 `release.yml`。以下仅为**历史失败记录**：

1. 误用 `guard let printOp = webView.printOperation(with:)` —— 返回值非可选，不允许条件绑定。
2. 误用了与实际 SDK 不匹配的 modal API 名称，且 `runOperation()` 在 macOS 12 SDK 已 rename 为 `run()`。
3. 当时临时改用同步 `printOp.run()`，后续现行实现已切为验证可编译的异步 `runModal(for:delegate:didRun:contextInfo:)`。

守则：

- 不靠记忆/猜测 Swift API 签名；以 CI 当前 SDK 编译结果为准。`webView.printOperation(with:)` 返回非可选 `NSPrintOperation`；现行路径使用 `runModal(for:delegate:didRun:contextInfo:)`，并关闭打印/进度面板。
- `canSpawnSeparateThread = true` 时打印完成回调可能位于工作线程；PDFKit 验证、原子写入、完成回调和隐藏窗口清理必须回到主线程。
- 本机有 Xcode 跑 `./scripts/ci-xcodebuild.sh` 出 Universal 二进制再打 tag；本机无 Xcode 时改 Swift 也应先 push 到普通分支让 `ci.yml` 的 `mac-app` job 编译通过后再 tag。
- `ci.yml` 已在 push 到 `main`、pull request 与 `workflow_dispatch` 时运行 `mac-app` 编译和 PDF 自检，使 Swift API 错误在发版前暴露。
- 覆盖边界：CI 已覆盖生产 PDF 渲染、资源等待、分页与有效多页落盘；仅 `NSSavePanel` 的用户交互仍需本机 GUI 烟测。

### 7.3 自用打开（方式 B）

1. 打开 app（若拦截则关闭提示）  
2. **系统设置 → 隐私与安全性**  
3. **仍要打开** → 确认  

---

## 8. 图标管线

| 步骤 | 说明 |
|------|------|
| 源图 | 优先 **透明 PNG**；JPEG 圆角外常为纯黑 |
| `process-icon-alpha.py` | 黑键抠透明 + squircle 收边（需本地 Pillow） |
| `build-icon.sh` | 生成 iconset → `App/AppIcon.icns` |
| CI | 优先使用仓库内已提交的 **透明 PNG / icns**（无 Pillow 也能过） |

圆角黑边根因：**JPEG 无法存 alpha**，不是 Finder 单独加的框。

---

## 9. 测试与质量

| 类型 | 内容 |
|------|------|
| 前端单测 | `reader/test/*.test.mjs`：依赖解析 + `md.js` 纯函数（slugify/CJK、rewriteImages、outline、mermaid、task-list、hljs） |
| CI 结构门禁 | IIFE、通用架构、图标路径 |
| CI headless 自检 | `--selftest` 验证阅读渲染；`--pdf-selftest <path.md> <out.pdf>` 走生产打印协调器并断言有效多页 PDF |
| `verify-open.sh` | 本机 GUI 烟测：冷/热打开；断言 `/tmp/mdeye-last-shown.json` |
| 真机清单 | 双击默认应用、中文路径、断网、Mermaid、主题、**PDF 导出** |

> `--selftest` 验证 `mdeye-app://` 阅读链路到 `doc-shown`；`--pdf-selftest` 使用 file-backed 打印 WebView、`print-ready` 和 `NSPrintOperation` 生成至少两页 PDF。`NSSavePanel` 用户交互仍由真机烟测覆盖。

离线验收：断网冷启动可用；无 CDN；CSP 拒绝远程脚本。

---

## 10. 风险与对策（现行）

| 风险 | 对策 |
|------|------|
| 再引入 ESM 分包 | CI 拒绝 `type=module`；构建固定 IIFE |
| 打开竞态空白 | `latestDoc` + ready/didFinish/重试 + `doc-shown` |
| 图标缓存旧图 | 刷新 iconservices；正确扁平路径 |
| JPEG 黑角 | 透明处理脚本；提交透明 PNG |
| 未签名劝退 | 文档写清方式 B；定位自用 |
| Mermaid 体积 | 接受完整包体积；不走 CDN |

---

## 11. 成功指标（对照现状）

- [x] macOS 双击 md 可阅读（冷/热）  
- [x] Mermaid 离线可用  
- [x] 无账号、无业务联网  
- [x] Universal dmg 单一文件分发  
- [x] 图标可见且无黑框（0.2.8）  
- [x] 无本机 Xcode 可开发 reader + CI 出包  
- [x] 导出 PDF（WebKit 系统打印管线 + `@media print`，排除大纲/工具条、整篇分页）（0.4.0）
- [x] CI headless 渲染自检（`--selftest`）（0.3.0）  
- [x] CI 多页 PDF 导出自检（`--pdf-selftest`）

---

## 12. 一句话决策

> **mdeye = macOS 上的离线 Markdown 阅读壳：Swift 管文件与系统，WKWebView 用 `mdeye-app://` 加载单文件 IIFE 阅读器；Mermaid 内置；通用二进制；未签名自用「仍要打开」。坚决不做第二 Obsidian，也不再走 ESM 分包与多端。**

---

## 附录 A. 关键缺陷时间线（备忘）

| 版本 | 问题 | 处理 |
|------|------|------|
| 0.2.0–0.2.2 | ESM / 竞态导致无正文 | IIFE + scheme + 重试 |
| 0.2.3 | 正文恢复 | 验证脚本 doc-shown |
| 0.2.4–0.2.5 | 图标路径错误 | 扁平 AppIcon.icns |
| 0.2.6 | 圆角素材 | 换源图 |
| 0.2.7–0.2.8 | 黑角 / CI 无 Pillow | 透明处理 + 提交透明资产 |
| 0.3.0（历史） | HTML→PDF 导出 / 多文件静默覆盖 / 版本漂移 / 沙箱不一致 / CI 无渲染验证 | 当时改为原生 `createPDF` + 单文件语义 + 版本单源注入 + PathSandbox + headless `--selftest` |
| 0.4.0 | 原 `createPDF` 空构造只截一屏 + 大纲/工具条被写入 PDF + 机械切片分页差 | 改走 WebKit 系统打印管线（`NSPrintOperation`）+ reader.css `@media print`（排除大纲/工具条、`break-*` 控分页） |
| 0.5.0 | 文档内 .md 链接点击无反应（裸跳自定义协议必败）；协议 MIT→Apache-2.0 | 正文 click 委托 + 桥接 `open-md-link`，复用 `FileService.resolveAsset` 同树沙箱解析 → `openFile` 单文件替换 |
| 0.5.0（教训） | 切 PDF 到打印管线时本机无 Xcode，靠记忆猜 `NSPrintOperation` API → 连续两次 `release.yml` 编译失败、来回 force-update tag | 守则：Swift 改动 push 前必须过编译（本机 `ci-xcodebuild.sh` 或让 `ci.yml` push-to-main 跑 `mac-app`），打印/PDF 等 GUI 路径需手测；不靠记忆猜 API |
| 后续迭代（历史尝试） | PDF 导出空白 + 只截一屏：系统打印面板「另存为 PDF」对自定义协议 WebView 输出空白（预览却有内容）；`callAsyncJavaScript` 在自定义协议 WebView 返回 nil | 当时回到 `createPDF` + `export-pdf-measured`；该方案现已废弃，不得作为当前实现参考 |
| 当前实现 | `createPDF` 的连续画布、屏幕布局污染、离屏帧暂停以及打印回调线程问题 | 独立 file-backed WebView + 隐藏 `NSWindow` + `prepare-print`/`print-ready` + A4 `NSPrintOperation.runModal`；主线程完成 PDFKit 验证与原子写入；CI 保留真实多页 PDF artifact |

## 附录 B. 参考

- MDView：https://www.mdview.cn/  
- 产品哲学：https://www.mdview.cn/blog/20-yuan-tip-story.html  
- Apple：打开来自身份不明开发者的 App  
- WKWebView 自定义 URL Scheme、Universal Binary、icns  
