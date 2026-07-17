import * as esbuild from "esbuild";
import { cpSync, mkdirSync, rmSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dist = join(__dirname, "dist");
const watch = process.argv.includes("--watch");

function copyStatic() {
  mkdirSync(dist, { recursive: true });
  // index.html is patched after build to use classic script (IIFE), not type=module
  cpSync(join(__dirname, "styles"), join(dist, "styles"), { recursive: true });
}

function writeIndex() {
  // Classic script: WKWebView file:// and custom schemes load IIFE reliably.
  // ESM type=module fails under file:// (cross-module CORS) → blank reader forever.
  const html = `<!DOCTYPE html>
<html lang="zh-CN" data-theme="light">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta
      http-equiv="Content-Security-Policy"
      content="default-src 'none'; script-src 'self' mdeasy-app:; style-src 'self' mdeasy-app: 'unsafe-inline'; img-src 'self' mdeasy-app: mdeasy-asset: data: blob:; font-src 'self' mdeasy-app: data:; connect-src 'none'; frame-src 'none'; base-uri 'none';"
    />
    <title>mdeasy</title>
    <link rel="stylesheet" href="styles/themes.css" />
    <link rel="stylesheet" href="styles/reader.css" />
    <link rel="stylesheet" href="styles/hljs.css" />
  </head>
  <body>
    <div id="app">
      <aside id="outline" class="outline" aria-label="Outline"></aside>
      <main id="main">
        <header id="toolbar" class="toolbar">
          <button type="button" id="btn-outline" title="Toggle outline (⌘B)">☰</button>
          <span id="doc-title" class="doc-title">mdeasy</span>
          <span class="spacer"></span>
          <select id="theme-select" title="Theme" aria-label="Theme">
            <option value="light">Light</option>
            <option value="dark">Dark</option>
            <option value="sepia">Sepia</option>
            <option value="green">Green</option>
          </select>
        </header>
        <article id="content" class="markdown-body empty">
          <div class="empty-state">
            <h1>mdeasy</h1>
            <p>Open a Markdown file to start reading.</p>
            <p class="hint">⌘O open · drag & drop · double-click .md</p>
          </div>
        </article>
      </main>
    </div>
    <script src="app.js"></script>
  </body>
</html>
`;
  writeFileSync(join(dist, "index.html"), html);
}

async function run() {
  if (existsSync(dist)) {
    rmSync(dist, { recursive: true, force: true });
  }
  copyStatic();
  writeIndex();

  // Single IIFE bundle — no dynamic import chunks (file:// cannot load ESM modules).
  // Mermaid is included in the main bundle so diagrams work offline without import().
  const options = {
    entryPoints: [join(__dirname, "src/app.js")],
    bundle: true,
    minify: !watch,
    sourcemap: watch,
    outfile: join(dist, "app.js"),
    format: "iife",
    globalName: "mdeasyReader",
    target: ["safari14"],
    logLevel: "info",
  };

  const ctx = await esbuild.context(options);

  if (watch) {
    await ctx.watch();
    console.log("watching reader (iife)…");
  } else {
    await ctx.rebuild();
    await ctx.dispose();
    const size = readFileSync(join(dist, "app.js")).byteLength;
    console.log(`reader build → dist/app.js (${(size / 1024).toFixed(0)} KB IIFE)`);
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
