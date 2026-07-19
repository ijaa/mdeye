# Repository Guidelines

## 项目结构与模块

- `App/Sources/`：Swift/AppKit 壳层，负责窗口、文件监听、自定义 URL scheme、WebView 桥接和 PDF 导出。
- `reader/src/`、`reader/styles/`：Markdown 阅读器源码与主题；`reader/dist/` 是构建产物。
- `reader/test/*.test.mjs`：Node 单元测试，覆盖 Markdown 渲染辅助逻辑和依赖解析。
- `App/Resources/reader/`：提交到仓库的 reader fallback，修改前端后必须重新同步。
- `scripts/`：构建、同步、CI 自检、图标和 DMG 脚本；`fixtures/` 保存测试文档。
- `.github/workflows/`：Universal macOS 构建、测试和发布流程。

## 构建、测试与开发命令

```bash
cd reader && npm ci && npm test  # 安装依赖并运行 Node 测试
cd reader && npm run build       # 生成单文件 IIFE reader/dist/app.js
./scripts/sync-reader-to-app.sh   # 同步 reader 到 App 资源
./scripts/ci-xcodebuild.sh        # 需要 Xcode；构建 arm64+x86_64 App
./scripts/ci-selftest.sh build/mdeye.app # 渲染及多页 PDF 自检
```

本机无 Xcode 时，通过 `CI` workflow 的 `workflow_dispatch` 构建，并下载 `mdeye-app` artifact。不要用本地不可用的 Xcode 命令代替 CI 验证。

### 通过 CI 打包并在本地人工验证

CI 只能构建远端已提交代码。先提交并 push 到目标分支，但不要为预览包创建 tag，然后执行：

```bash
gh workflow run CI --ref main
# 从命令输出的 Actions URL 取得 run ID，例如 29668349902
CI_RUN_ID=29668349902
gh run watch "$CI_RUN_ID" --exit-status
CI_PREVIEW_DIR="tmp/ci-preview-$CI_RUN_ID"
mkdir -p "$CI_PREVIEW_DIR"
gh run download "$CI_RUN_ID" --name mdeye-app --dir "$CI_PREVIEW_DIR"
open "$CI_PREVIEW_DIR/mdeye.app"
```

只有 `reader`、Universal App 编译、Bundle/IIFE/图标门禁及渲染/PDF 自检全部成功后才下载。artifact 应包含 `mdeye.app/` 和 `pdf-selftest.pdf`。所有预览包固定放在 `tmp/ci-preview-<run-id>/`；`tmp/` 已加入 `.gitignore`，不得强制提交其中内容。

## 编码风格与命名

Swift 使用 4 空格缩进、类型用 `UpperCamelCase`、成员用 `lowerCamelCase`。JavaScript 使用 2 空格、分号和双引号，并保持函数职责单一。仓库未配置统一 formatter；提交前遵循相邻代码风格并运行测试。reader 必须构建为单一 classic IIFE，禁止 `type="module"`、动态分包和 CDN。

## 测试要求

新增 Markdown 行为时，在 `reader/test/` 添加 `*.test.mjs`，使用 `node:test`。Swift、WebKit 或 PDF 改动必须让 CI 的 Universal 编译、`--selftest` 和 `--pdf-selftest` 全部通过。界面变更提供截图；PDF 变更检查 CI 产出的 `pdf-selftest.pdf`，并说明分页、Mermaid、图片和代码块结果。

## Commit 与 Pull Request

提交历史采用 Conventional Commit 形式，例如 `fix(export): ...`、`test(export): ...`、`docs: ...`。使用祈使语气，scope 对应受影响模块；不要提交 `tmp/`、本地构建产物或下载的 App。

PR 应说明问题、实现、风险和验证命令，关联相关 issue。涉及 UI/PDF 时附截图或 artifact 说明；涉及 Swift 时必须先通过普通 CI，再创建发布 tag。

## 本地敏感信息检查

提交前检查暂存区和未跟踪文件，禁止提交 API key、access token、密码、私钥、证书、签名文件、`.env` 内容、真实环境变量值、用户路径中的敏感信息或包含这些内容的日志/CI artifact。至少运行：

```bash
git diff --cached --check
git diff --cached
rg -n -i "(api[_-]?key|access[_-]?token|secret|password|private[_-]?key|BEGIN .* PRIVATE KEY)" --glob '!reader/dist/**' --glob '!tmp/**' .
```

示例值必须使用明显的占位符，如 `YOUR_API_KEY`，不要把真实值写进测试 fixture、截图或 PR 描述。发现疑似泄露时立即停止提交并通知维护者；已推送的凭据必须先撤销/轮换，再清理历史，不能只删除当前文件。

## 安全与架构约束

本地资源必须经过 `PathSandbox`，不得放宽 `..` 逃逸限制。PDF 导出必须保持独立 file-backed WebView、`prepare-print`/`print-ready` 和原生 `NSPrintOperation` 路径，不得回退到 `createPDF` 或修改阅读 WebView。

## 文档与发布

面向贡献者和用户的说明同步维护 `README.md`、`README.zh-CN.md`、`CLAUDE.md` 与 `docs/architecture.md`；实现、脚本或 CI 行为变化时，应同时更新对应文档。版本唯一来源是 `App/Info.plist`，发布前确认文档版本与其一致。
