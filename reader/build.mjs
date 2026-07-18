import * as esbuild from "esbuild";
import { cpSync, mkdirSync, rmSync, existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dist = join(__dirname, "dist");
const watch = process.argv.includes("--watch");

// Single source of truth for the app version is App/Info.plist (CFBundleShortVersionString).
// Inject it into the bundle so the JS "ready" handshake reports the same version as the app.
function readAppVersion() {
  const plist = join(__dirname, "..", "App", "Info.plist");
  if (!existsSync(plist)) return "0.0.0";
  const m = readFileSync(plist, "utf8").match(
    /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/
  );
  return m ? m[1] : "0.0.0";
}
const APP_VERSION = readAppVersion();

function copyStatic() {
  mkdirSync(dist, { recursive: true });
  // index.html is patched (see writeIndex) to use a classic IIFE script.
  cpSync(join(__dirname, "styles"), join(dist, "styles"), { recursive: true });
}

function writeIndex() {
  // Reuse the committed source index.html directly. It already ships as a classic
  // (non-module) script with the correct CSP for mdeye-app:// — no build-time rewrite
  // needed. Keeping a single copy avoids the source/produced-HTML divergence trap.
  cpSync(join(__dirname, "index.html"), join(dist, "index.html"));
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
    globalName: "mdeyeReader",
    target: ["safari14"],
    logLevel: "info",
    define: {
      __MDEYE_VERSION__: JSON.stringify(APP_VERSION),
    },
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
