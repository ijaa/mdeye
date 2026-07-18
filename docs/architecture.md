# mdeasy Architecture (implementation · v0.2.8)

> 中文说明：本文件为技术架构文档（原「技术方案」）。

> **产品**：本地优先的 Markdown **阅读器**（不是编辑器 / 笔记库）  
> **对标**：[MDView](https://www.mdview.cn/)  
> **平台**：仅 **macOS 12+**  
> **架构**：Swift 薄壳 + WKWebView + 静态 reader（IIFE）  
> **工程**：本地可不装 Xcode；**GitHub Actions** 编译打包  
> **分发**：无 Apple Developer 证书；unsigned + **系统设置 → 隐私与安全性 → 仍要打开**  
> **代码版本**：`CFBundleShortVersionString` **0.2.8** / `CFBundleVersion` **10**

本文档描述 **当前仓库真实实现**，并保留产品决策与踩坑结论。历史「拆包 Mermaid / Tauri / 5–10MB 目标」等过程选项已收敛为下列定案。

---

## 0. 决策一览（现状）

| 议题 | 决策（已实现） |
|------|----------------|
| 产品形态 | 阅读器 only；打开 md 即读 |
| 平台 | **仅 macOS**（不做 Win / Android） |
| 壳 | **Swift + AppKit + WKWebView** |
| 前端 | **esbuild 单文件 IIFE**（无 Svelte/React，**无 ESM module**） |
| Mermaid | **完整内置**（静态 import，打进 `app.js`） |
| UI 加载 | 自定义协议 **`mdeasy-app://`**（非裸 `file://` 主路径） |
| 本地图片 | **`mdeasy-asset://`** + baseDir 沙箱 |
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
| 小体积 | 相对 Electron 很小；完整包含 Mermaid 后 dmg 约 **~1.5–2 MB** 量级（压缩后），`.app` 内 JS 约 **2.8 MB** |
| 快启动 | 中等文档亚秒～秒级可读（首次加载 IIFE 略重） |
| 不登录 / 不联网 / 不打扰 | 无账号、无遥测、无 CDN |
| 专注阅读 | 大纲、主题；不提供编辑；**始终只渲染一个文件（多选后打开取最后一个）** |
| 实时预览 | 外部编辑器保存 → 自动重渲染 |
| Mermaid | 离线渲染（flowchart / sequence 等） |
| 多主题 | Light / Dark / Sepia / Green |
| PDF 导出 | 原生 `WKWebView.createPDF`（分页、保留主题） |

### 1.2 明确不做

- 多端、WYSIWYG 编辑器、知识库、插件市场、AI
- **多窗口 / 多标签**（始终单文件：多选打开只渲染最后一个）
- 当前阶段 Apple 签名公证
- 依赖本机 Xcode 才能参与 **reader** 开发

### 1.3 与 MDView

| 维度 | MDView | mdeasy |
|------|--------|--------|
| 平台 | Win + Android | **仅 macOS** |
| 结构 | 系统 WebView + 薄壳 | 同构 |
| 分发 | 安装包 | 自用 unsigned +「仍要打开」 |
| 图表 | Pro / 按需 | **完整包默认内置** |

---

## 2. 总体架构

```
┌──────────────────────────────────────────────────────────┐
│  mdeasy.app (Swift / AppKit)                             │
│  main.swift → NSApplication.run                          │
│  AppDelegate：open urls / openFile / openFiles            │
│  MainWindowController：菜单、默认应用、主题快捷键          │
│  ReaderViewController：WKWebView、桥接、latestDoc 重试     │
│  AppSchemeHandler：mdeasy-app://reader/...                │
│  AssetSchemeHandler：mdeasy-asset://local/...             │
│  FileService / FileWatcher / DefaultAppService            │
└───────────────────────────▲──────────────────────────────┘
                            │ WKScriptMessageHandler "mdeasy"
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
双击 xxx.md
  → Launch Services 启动 / 激活 mdeasy，传入 path
  → AppDelegate enqueue → ReaderViewController.openFile
  → FileService 读文本 → latestDoc
  → WKWebView 已 load mdeasy-app://reader/index.html
  → JS ready / didFinish / 重试 → 推送 doc
  → markdown-it 渲染；含 mermaid 则 mermaid.run
  → FileWatcher 监听；保存后再次 openFile
  → 可选：导出 PDF / 默认应用 / 主题
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
- 本地图片：相对路径 → `mdeasy-asset://`，禁止 `../` 逃逸
- 默认 **不渲染** markdown 原始 HTML（`html: false`）

### 3.2 系统集成

- 菜单：打开、重载、导出、Finder、编辑器、大纲、主题、设为默认
- 拖放打开
- 文档类型 `LSHandlerRank = Owner` + 导出 UTI `app.mdeasy.markdown`
- `DefaultAppService`：`LSSetDefaultRoleHandlerForContentType`
- Universal Binary 强制门禁
- 图标 `CFBundleIconFile = AppIcon`

### 3.3 可靠性（针对历史缺陷）

| 问题 | 修复 |
|------|------|
| 启动无窗口 | `main.swift` 显式 run；`makeKeyAndOrderFront`；reopen；屏外 frame 归位 |
| 双击有窗口无正文 | 去掉 ESM；IIFE + `mdeasy-app://`；`latestDoc` + ready/重试 |
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
| `main.swift` | `NSApplication` + `run()` |
| `AppDelegate.swift` | 生命周期、打开文件队列 |
| `MainWindowController.swift` | 窗口与菜单 |
| `ReaderViewController.swift` | WebView、桥接、推送文档 |
| `AppSchemeHandler.swift` | `mdeasy-app` |
| `AssetSchemeHandler.swift` | `mdeasy-asset` |
| `FileService.swift` | 读文件、路径沙箱 |
| `FileWatcher.swift` | 变更热更新 |
| `DefaultAppService.swift` | 默认打开方式 |
| `Preferences.swift` | 主题等偏好 |

### 4.2 前端（reader）

| 项 | 选择 |
|----|------|
| 构建 | **esbuild**，`format: "iife"`，**禁止 splitting/ESM** |
| Markdown | markdown-it + markdown-it-anchor + markdown-it-task-lists |
| 高亮 | highlight.js 按需语言 |
| 图表 | **mermaid** 静态 import |
| CSP | `default-src 'none'`；script/style 限 `self` 与 `mdeasy-app:`；img 允许 `mdeasy-asset:` / data |

入口：`reader/src/app.js`、`reader/src/md.js` → 产出 `reader/dist/app.js`（约 2.8 MB minify）。

### 4.3 桥接协议（摘要）

**Swift → JS**（`window.__mdeasy.handle`）：

- `{ type: "doc", path, baseDir, text, encoding, mtimeMs }`
- `{ type: "theme", name }`
- `{ type: "toggle-outline" }`

**JS → Swift**（`webkit.messageHandlers.mdeasy`）：

- `{ type: "ready", version? }`
- `{ type: "doc-shown", path, chars, hasMermaid }`（冒烟戳记 `/tmp/mdeasy-last-shown.json`）
- `{ type: "set-preference", key, value }`
- open-in-editor / reveal-in-finder / error

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
mdeasy/
├── App/
│   ├── Sources/*.swift
│   ├── Resources/reader/     # 提交用 fallback；CI 会重建同步
│   ├── AppIcon.icns          # 必须扁平参与 Resources 构建阶段
│   ├── Assets/
│   │   ├── mdeasy-logo.jpeg
│   │   └── mdeasy-icon-transparent.png
│   ├── Info.plist
│   ├── project.yml           # XcodeGen 可选源
│   └── mdeasy.xcodeproj/
├── reader/
│   ├── src/{app.js,md.js}
│   ├── styles/
│   ├── build.mjs             # IIFE 打包
│   └── package.json
├── scripts/
│   ├── build-reader.sh
│   ├── sync-reader-to-app.sh
│   ├── ci-xcodebuild.sh      # universal + 图标路径门禁
│   ├── package-dmg.sh
│   ├── build-icon.sh
│   ├── process-icon-alpha.py
│   ├── verify-open.sh
│   └── smoke-open.sh
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

1. Node 构建 reader + 单测  
2. 同步资源  
3. `ci-xcodebuild.sh`：`generic/platform=macOS`，`ARCHS="arm64 x86_64"`  
4. 门禁：
   - `index.html` **无** `type="module"`
   - `app.js` 非 ESM 开头、含 `__mdeasy`
   - 二进制含 **x86_64 与 arm64**
   - 存在 **`Contents/Resources/AppIcon.icns`**
5. 上传 artifact `mdeasy-app`

### 7.2 `release.yml`

- tag `v*` 或 workflow_dispatch  
- 构建 app + dmg  
- GitHub Release 正文含安装与「仍要打开」说明  

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
| 前端单测 | `reader` 依赖 / 渲染烟测 |
| CI 结构门禁 | IIFE、通用架构、图标路径 |
| `verify-open.sh` | 冷/热打开；断言 `/tmp/mdeasy-last-shown.json` |
| 真机清单 | 双击默认应用、中文路径、断网、Mermaid、主题、导出 |

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

---

## 12. 一句话决策

> **mdeasy = macOS 上的离线 Markdown 阅读壳：Swift 管文件与系统，WKWebView 用 `mdeasy-app://` 加载单文件 IIFE 阅读器；Mermaid 内置；通用二进制；未签名自用「仍要打开」。坚决不做第二 Obsidian，也不再走 ESM 分包与多端。**

---

## 附录 A. 关键缺陷时间线（备忘）

| 版本 | 问题 | 处理 |
|------|------|------|
| 0.2.0–0.2.2 | ESM / 竞态导致无正文 | IIFE + scheme + 重试 |
| 0.2.3 | 正文恢复 | 验证脚本 doc-shown |
| 0.2.4–0.2.5 | 图标路径错误 | 扁平 AppIcon.icns |
| 0.2.6 | 圆角素材 | 换源图 |
| 0.2.7–0.2.8 | 黑角 / CI 无 Pillow | 透明处理 + 提交透明资产 |

## 附录 B. 参考

- MDView：https://www.mdview.cn/  
- 产品哲学：https://www.mdview.cn/blog/20-yuan-tip-story.html  
- Apple：打开来自身份不明开发者的 App  
- WKWebView 自定义 URL Scheme、Universal Binary、icns  
