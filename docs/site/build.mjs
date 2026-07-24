// Builds the Tessera user guide: docs/site/pages/*.md → dist/ static HTML.
//
// Front matter contract (per page):
//   title: Human page title            (required)
//   nav:   integer, sidebar position   (required)
//   group: sidebar section label       (optional; header shown when it changes)
//   description: meta description      (optional)
//
// Inter-page links in Markdown point at source files (`keys.md`, or
// `keys.md#anchor`); the build rewrites them to clean URLs (`/docs/keys/`)
// and fails on dead targets — including missing heading anchors.
// Absolute `/docs/...` links are validated the same way.

import { Marked } from "marked";
import matter from "gray-matter";
import {
  readdirSync, readFileSync, writeFileSync, mkdirSync, rmSync, cpSync, existsSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const pagesDir = join(root, "pages");

const outIdx = process.argv.indexOf("--out");
const distDir = outIdx !== -1 && process.argv[outIdx + 1]
  ? join(root, process.argv[outIdx + 1])
  : join(root, "dist");

const escapeHtml = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const slugToUrl = (slug) => (slug === "index" ? "/docs/" : `/docs/${slug}/`);

// GitHub-style heading anchors: lowercase, strip punctuation, spaces → hyphens.
const slugify = (text) =>
  text
    .replace(/[`*]/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N} _-]/gu, "")
    .replace(/\s+/g, "-");

// ─── Load pages ─────────────────────────────────────────────────────────────
const files = readdirSync(pagesDir).filter((f) => f.endsWith(".md")).sort();
if (files.length === 0) {
  console.error(`no pages found in ${pagesDir}`);
  process.exit(1);
}

const pages = files.map((file) => {
  const slug = file.replace(/\.md$/, "");
  const raw = readFileSync(join(pagesDir, file), "utf8");
  const { data, content } = matter(raw);
  if (!data.title) throw new Error(`${file}: missing front-matter "title"`);
  if (typeof data.nav !== "number") throw new Error(`${file}: missing front-matter "nav" (integer)`);
  return {
    slug,
    file,
    title: data.title,
    nav: data.nav,
    group: data.group || null,
    description: data.description || `Tessera user guide — ${data.title}.`,
    body: content,
    anchorIds: new Set(),
  };
});

const bySlug = new Map(pages.map((p) => [p.slug, p]));
const urls = new Map(pages.map((p) => [slugToUrl(p.slug), p]));
const ordered = [...pages].sort((a, b) => a.nav - b.nav);

// Pre-compute each page's heading anchors so links can be validated.
for (const page of pages) {
  const seen = new Map();
  for (const line of page.body.split("\n")) {
    const m = line.match(/^(#{1,6})\s+(.*)$/);
    if (!m) continue;
    const base = slugify(m[2]);
    const n = seen.get(base) || 0;
    seen.set(base, n + 1);
    page.anchorIds.add(n > 0 ? `${base}-${n}` : base);
  }
}

// ─── Render Markdown, rewriting + validating links ──────────────────────────
const errors = [];
const MD_LINK = /^([a-z0-9-]+)\.md(?:#(\S+))?$/i;

const checkAnchor = (page, target, anchor, href) => {
  if (anchor && !target.anchorIds.has(anchor.toLowerCase())) {
    errors.push(`${page.file}: dead anchor in "${href}"`);
  }
};

for (const page of pages) {
  const walkTokens = (token) => {
    if (token.type !== "link" || !token.href) return;
    const href = token.href;
    if (/^(https?:|mailto:|tel:)/i.test(href)) return; // external

    if (href.startsWith("#")) { // in-page anchor
      checkAnchor(page, page, href.slice(1), href);
      return;
    }

    const m = href.match(MD_LINK);
    if (m) {
      const targetSlug = m[1].toLowerCase();
      const target = bySlug.get(targetSlug);
      if (!target) {
        errors.push(`${page.file}: dead link "${href}" (no ${targetSlug}.md)`);
        return;
      }
      checkAnchor(page, target, m[2], href);
      token.href = slugToUrl(targetSlug) + (m[2] ? `#${m[2]}` : "");
      return;
    }

    if (href.startsWith("/docs/")) {
      const [path, anchor] = href.split("#");
      const target = urls.get(path);
      if (!target) {
        errors.push(`${page.file}: dead absolute link "${href}"`);
        return;
      }
      checkAnchor(page, target, anchor, href);
      return;
    }

    errors.push(`${page.file}: unresolved link "${href}" (use <slug>.md or /docs/<slug>/)`);
  };

  const headingSeen = new Map();
  const renderer = {
    heading({ tokens, depth, text }) {
      const base = slugify(text);
      const n = headingSeen.get(base) || 0;
      headingSeen.set(base, n + 1);
      const id = n > 0 ? `${base}-${n}` : base;
      return `<h${depth} id="${id}">${this.parser.parseInline(tokens)}</h${depth}>\n`;
    },
  };

  const m = new Marked({ gfm: true, breaks: false, walkTokens });
  m.use({ renderer });
  page.html = m.parse(page.body);
}

// ─── Sidebar nav ────────────────────────────────────────────────────────────
const renderNav = (current) => {
  const items = [];
  let lastGroup = null;
  for (const p of ordered) {
    if (p.group && p.group !== lastGroup) {
      items.push(`      <div class="nav-group">${escapeHtml(p.group)}</div>`);
      lastGroup = p.group;
    }
    const cls = p.slug === current ? ` class="current" aria-current="page"` : "";
    items.push(`      <li><a href="${slugToUrl(p.slug)}"${cls}>${escapeHtml(p.title)}</a></li>`);
  }
  return `    <ul>\n${items.join("\n")}\n    </ul>`;
};

// ─── Emit ───────────────────────────────────────────────────────────────────
const template = readFileSync(join(root, "template.html"), "utf8");

rmSync(distDir, { recursive: true, force: true });
mkdirSync(distDir, { recursive: true });

for (const page of pages) {
  const breadcrumb = page.slug === "index"
    ? ""
    : `\n    <span class="sep">/</span>\n    <span class="current">${escapeHtml(page.title)}</span>`;
  const html = template
    .replaceAll("{{title}}", escapeHtml(page.title))
    .replaceAll("{{description}}", escapeHtml(page.description))
    .replaceAll("{{breadcrumb_current}}", breadcrumb)
    .replace("{{nav}}", renderNav(page.slug))
    .replace("{{content}}", page.html.trimEnd());

  const dir = page.slug === "index" ? distDir : join(distDir, page.slug);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "index.html"), html);
}

if (existsSync(join(root, "assets"))) {
  cpSync(join(root, "assets"), join(distDir, "assets"), { recursive: true });
}

if (errors.length) {
  console.error("build failed — dead links:");
  for (const e of errors) console.error(`  ${e}`);
  process.exit(1);
}

console.log(`built ${pages.length} pages → ${distDir}`);
