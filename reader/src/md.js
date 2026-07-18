import MarkdownIt from "markdown-it";
import anchor from "markdown-it-anchor";
import taskLists from "markdown-it-task-lists";
import hljs from "highlight.js/lib/core";

import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import go from "highlight.js/lib/languages/go";
import json from "highlight.js/lib/languages/json";
import bash from "highlight.js/lib/languages/bash";
import yaml from "highlight.js/lib/languages/yaml";
import markdown from "highlight.js/lib/languages/markdown";
import java from "highlight.js/lib/languages/java";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import xml from "highlight.js/lib/languages/xml";
import css from "highlight.js/lib/languages/css";
import sql from "highlight.js/lib/languages/sql";

hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("js", javascript);
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("ts", typescript);
hljs.registerLanguage("python", python);
hljs.registerLanguage("py", python);
hljs.registerLanguage("rust", rust);
hljs.registerLanguage("rs", rust);
hljs.registerLanguage("go", go);
hljs.registerLanguage("json", json);
hljs.registerLanguage("bash", bash);
hljs.registerLanguage("sh", bash);
hljs.registerLanguage("shell", bash);
hljs.registerLanguage("yaml", yaml);
hljs.registerLanguage("yml", yaml);
hljs.registerLanguage("markdown", markdown);
hljs.registerLanguage("md", markdown);
hljs.registerLanguage("java", java);
hljs.registerLanguage("c", c);
hljs.registerLanguage("cpp", cpp);
hljs.registerLanguage("xml", xml);
hljs.registerLanguage("html", xml);
hljs.registerLanguage("css", css);
hljs.registerLanguage("sql", sql);

function slugify(text) {
  return String(text)
    .trim()
    .toLowerCase()
    .replace(/[^\w一-鿿\- ]+/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "section";
}

let mermaidBlockId = 0;

const md = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: true,
  highlight(str, lang) {
    const language = (lang || "").toLowerCase();
    if (language === "mermaid") {
      const id = `mermaid-${++mermaidBlockId}`;
      const escaped = md.utils.escapeHtml(str.trim());
      return `<div class="mermaid-block" data-mermaid-id="${id}"><pre class="mermaid">${escaped}</pre></div>`;
    }
    if (language && hljs.getLanguage(language)) {
      try {
        return `<pre class="hljs"><code>${hljs.highlight(str, { language, ignoreIllegals: true }).value}</code></pre>`;
      } catch {
        // fall through
      }
    }
    return `<pre class="hljs"><code>${md.utils.escapeHtml(str)}</code></pre>`;
  },
});

md.use(anchor, {
  level: [1, 2, 3],
  slugify,
  permalink: false,
});

md.use(taskLists, { enabled: true, label: true, labelAfter: true });

/**
 * Rewrite relative image src to mdeye-asset:// scheme.
 * Absolute http(s)/data/mdeye-asset left as-is (http blocked by CSP).
 */
function rewriteImages(html) {
  return html.replace(
    /<img\b([^>]*?)\bsrc=(["'])([^"']+)\2([^>]*)>/gi,
    (full, pre, quote, src, post) => {
      if (
        /^(https?:|data:|mdeye-asset:|blob:|file:)/i.test(src) ||
        src.startsWith("#")
      ) {
        return full;
      }
      const cleaned = src.replace(/^\.\//, "").replace(/^\/+/, "");
      const asset = `mdeye-asset://local/${cleaned}`;
      return `<img${pre}src=${quote}${asset}${quote}${post}>`;
    }
  );
}

export function renderMarkdown(text) {
  mermaidBlockId = 0;
  const raw = md.render(text ?? "");
  return rewriteImages(raw);
}

export function extractOutlineFromHtml(html) {
  const re = /<h([1-3])\b[^>]*\bid=(["'])([^"']+)\2[^>]*>([\s\S]*?)<\/h\1>/gi;
  const items = [];
  let m;
  while ((m = re.exec(html))) {
    const level = Number(m[1]);
    const id = m[3];
    const textContent = m[4].replace(/<[^>]+>/g, "").trim();
    if (textContent) items.push({ level, id, text: textContent });
  }
  return items;
}

export function documentHasMermaid(text) {
  return /```\s*mermaid\b/i.test(text ?? "");
}
