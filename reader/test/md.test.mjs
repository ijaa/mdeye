import test from "node:test";
import assert from "node:assert/strict";
import {
  renderMarkdown,
  extractOutlineFromHtml,
  documentHasMermaid,
} from "../src/md.js";

test("renderMarkdown: basic GFM produces headings and strong text", () => {
  const html = renderMarkdown("# Title\n\n**bold** and `code`");
  assert.match(html, /<h1[^>]*\bid="title"/i);
  assert.match(html, /<strong>bold<\/strong>/);
  assert.match(html, /<code>code<\/code>/);
});

test("slugify: ASCII headings get dashed lowercase ids", () => {
  const html = renderMarkdown("# Hello World Foo\n\n## Mixed Case Heading");
  assert.match(html, /<h1[^>]*\bid="hello-world-foo"/i);
  assert.match(html, /<h2[^>]*\bid="mixed-case-heading"/i);
});

test("slugify: CJK headings keep characters (no garbling)", () => {
  const html = renderMarkdown("# 中文 标题\n\n## 第二级");
  assert.match(html, /<h1[^>]*\bid="中文-标题"/i);
  assert.match(html, /<h2[^>]*\bid="第二级"/i);
});

test("rewriteImages: relative src is rewritten to mdeye-asset://local/", () => {
  const html = renderMarkdown("![alt](img/sub/pic.png)");
  assert.ok(
    html.includes('src="mdeye-asset://local/img/sub/pic.png"'),
    `expected rewritten asset src, got: ${html}`
  );
});

test("rewriteImages: http(s)/data/img-with-hash left untouched", () => {
  const html = renderMarkdown(
    "![a](https://x/y.png)\n![b](data:image/png;base64,QQ==)\n![c](#anchor)"
  );
  assert.ok(html.includes('src="https://x/y.png"'));
  assert.ok(html.includes('src="data:image/png;base64,QQ=="'));
  assert.ok(html.includes('src="#anchor"'));
  assert.ok(!html.includes("mdeye-asset://local/https"));
  assert.ok(!html.includes("mdeye-asset://local/data:"));
  assert.ok(!html.includes("mdeye-asset://local/#anchor"));
});

test("rewriteImages: leading ./ and duplicate slashes normalized", () => {
  const html = renderMarkdown("![x](./dir//a.png)");
  assert.ok(
    html.includes('src="mdeye-asset://local/dir//a.png"') ||
      html.includes('src="mdeye-asset://local/dir/a.png"'),
    `got: ${html}`
  );
});

test("mermaid fence detoured to .mermaid-block", () => {
  const src = "```mermaid\ngraph LR\n  A --> B\n```\n";
  const html = renderMarkdown(src);
  assert.match(html, /class="mermaid-block"/);
  assert.match(html, /<pre class="mermaid">/);
});

test("task list checkbox renders", () => {
  const html = renderMarkdown("- [x] done\n- [ ] todo");
  assert.match(html, /contains-task-list/);
  assert.match(html, /task-list-item-checkbox/);
  // checked item carries the checked attribute; unchecked does not
  assert.match(
    html,
    /<input[^>]*class="task-list-item-checkbox"[^>]*checked[^>]*>/
  );
});

test("code fence with known language gets hljs highlighting", () => {
  const html = renderMarkdown("```js\nconst x = 1;\n```");
  assert.match(html, /<pre class="hljs">/i);
  assert.match(html, /<code>[^<]*<span/); // some hljs span emitted
});

test("documentHasMermaid true for mermaid fence, false otherwise", () => {
  assert.equal(documentHasMermaid("```mermaid\ngraph\n```"), true);
  assert.equal(documentHasMermaid("  ```mermaid\nflowchart\n```"), true);
  assert.equal(documentHasMermaid("```\nlet x = 1;\n```"), false);
  assert.equal(documentHasMermaid("plain text"), false);
  assert.equal(documentHasMermaid(null), false);
  assert.equal(documentHasMermaid(undefined), false);
  assert.equal(documentHasMermaid(""), false);
});

test("extractOutlineFromHtml: collects h1-h3 with id and text, skips empty", () => {
  const html =
    `<h1 id="a">First</h1>` +
    `<h2 id="b">Second Level</h2>` +
    `<h3 id="c">Third</h3>` +
    `<h4 id="d">Deep (ignored)</h4>` +
    `<h2 id="e"></h2>` + // empty text → skipped
    `<h1 id="f">Has <em>inline</em></h1>`;
  const items = extractOutlineFromHtml(html);
  assert.deepEqual(
    items.map((i) => ({ level: i.level, id: i.id, text: i.text })),
    [
      { level: 1, id: "a", text: "First" },
      { level: 2, id: "b", text: "Second Level" },
      { level: 3, id: "c", text: "Third" },
      { level: 1, id: "f", text: "Has inline" },
    ]
  );
});

test("extractOutlineFromHtml: empty html returns []", () => {
  assert.deepEqual(extractOutlineFromHtml(""), []);
  assert.deepEqual(extractOutlineFromHtml("<p>no headings</p>"), []);
});
