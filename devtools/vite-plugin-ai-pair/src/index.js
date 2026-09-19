// vite-plugin-ai-pair — optional dev-only instrumentation for the Pair Mac app.
//
//   import aiPair from "vite-plugin-ai-pair";
//   export default defineConfig({ plugins: [react(), aiPair()] });
//
// What it does (dev server only, nothing is emitted in production builds):
//   • injects src/runtime.js, which mirrors "file:line:component" for the
//     hovered element into its class list so the Mac app can read it through
//     Accessibility (see runtime.js for the why);
//   • tells the runtime the project root so file paths are project-relative;
//   • optionally adds data-ai-source / data-ai-line to JSX host elements in
//     .jsx/.tsx files so the mapping works even on React 19 (where fibers no
//     longer carry `_debugSource`). This transform is deliberately simple: it
//     annotates lowercase JSX tags (host elements) and skips anything it is not
//     sure about. Turn it off with `{ annotateJSX: false }`.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

export default function aiPair(options = {}) {
  const annotateJSX = options.annotateJSX !== false;
  let root = process.cwd();
  let isDev = false;

  return {
    name: "vite-plugin-ai-pair",
    apply: "serve",
    configResolved(config) {
      root = config.root;
      isDev = config.command === "serve";
    },
    transformIndexHtml() {
      if (!isDev) return [];
      const runtime = fs.readFileSync(path.join(here, "runtime.js"), "utf8");
      return [
        { tag: "script", injectTo: "head-prepend", children: `window.__PAIR_PROJECT_ROOT__=${JSON.stringify(root)};` },
        { tag: "script", injectTo: "head-prepend", children: runtime },
      ];
    },
    transform(code, id) {
      if (!isDev || !annotateJSX) return null;
      if (!/\.[jt]sx$/.test(id) || id.includes("/node_modules/")) return null;
      const rel = path.relative(root, id.split("?")[0]);
      const out = annotateHostElements(code, rel);
      return out === code ? null : { code: out, map: null };
    },
  };
}

/**
 * Add `data-ai-source="<file>" data-ai-line="<n>"` to opening tags of lowercase
 * (host) JSX elements. Skips tags that already carry data-ai-source and avoids
 * template literals / comments by only touching lines that look like JSX.
 *
 * This is intentionally a conservative line-based pass rather than a full
 * parser: it must never break a build. When in doubt, it leaves code alone.
 */
export function annotateHostElements(code, file) {
  if (!code.includes("<")) return code;
  const lines = code.split("\n");
  // <div, <button, <a ... but not <Component, <>, </x, <!--, or generics like <T,>
  const tag = /<([a-z][a-z0-9-]*)(?=[\s/>])/g;
  let changed = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.includes("<") || line.includes("data-ai-source")) continue;
    // Skip obvious non-JSX contexts.
    const trimmed = line.trimStart();
    if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("import ")) continue;
    if (/[<>]=|<<|>>/.test(line) && !/<[a-z]/.test(line)) continue;
    const replaced = line.replace(tag, (m, name, offset) => {
      // Do not annotate inside string literals on this line (cheap check).
      const before = line.slice(0, offset);
      const quotes = (before.match(/["'`]/g) || []).length;
      if (quotes % 2 === 1) return m;
      return `<${name} data-ai-source="${file}" data-ai-line="${i + 1}"`;
    });
    if (replaced !== line) { lines[i] = replaced; changed = true; }
  }
  return changed ? lines.join("\n") : code;
}
