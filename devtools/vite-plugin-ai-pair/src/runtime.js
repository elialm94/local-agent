// Pair dev runtime — runs only in the browser during local development.
//
// Job: make "runtime UI → source code" reliable for the Mac app without a
// network channel. On hover we work out where the element under the pointer
// comes from and mirror that as ONE synthetic class on the element:
//
//     pair-src--<base64url("file:line:component")>
//
// Chromium exposes class names through Accessibility (AXDOMClassList), which
// the Mac app already reads for the element under the pointer. The class is
// removed on pointer-out so it never affects styling or assistive tech.
//
// Source lookup, in order of trust:
//   1. data-ai-source / data-ai-line / data-ai-component on the element or an
//      ancestor (authored by hand, or by the plugin's JSX transform).
//   2. React dev fiber `_debugSource` (React ≤18 with the classic JSX transform
//      / babel-plugin-transform-react-jsx-source) → file:line, component name
//      from the nearest function-component owner.
//   3. React dev fiber owner name only (React 19 removed `_debugSource`).
(function pairDevRuntime() {
  if (typeof window === "undefined" || window.__PAIR_DEV_RUNTIME__) return;
  window.__PAIR_DEV_RUNTIME__ = true;

  const PREFIX = "pair-src--";
  let marked = null;

  function b64url(s) {
    const bytes = new TextEncoder().encode(s);
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function reactFiber(el) {
    for (const k in el) {
      if (k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$")) return el[k];
    }
    return null;
  }

  function componentName(fiber) {
    let f = fiber;
    while (f) {
      const t = f.type;
      if (typeof t === "function" && t.name) return t.displayName || t.name;
      if (t && typeof t === "object" && (t.displayName || (t.render && t.render.name))) return t.displayName || t.render.name;
      f = f._debugOwner || f.return;
    }
    return null;
  }

  function fromFiber(el) {
    const fiber = reactFiber(el);
    if (!fiber) return null;
    let f = fiber;
    while (f) {
      const src = f._debugSource;
      if (src && src.fileName) {
        return { file: relativize(src.fileName), line: src.lineNumber || null, component: componentName(f) };
      }
      f = f.return;
    }
    const name = componentName(fiber);
    return name ? { file: "", line: null, component: name } : null;
  }

  function relativize(file) {
    // Vite serves absolute paths; strip the workspace root if we know it.
    const root = window.__PAIR_PROJECT_ROOT__;
    if (root && file.startsWith(root)) return file.slice(root.length).replace(/^\/+/, "");
    return file;
  }

  function fromAttributes(el) {
    let node = el;
    while (node && node.nodeType === 1) {
      const src = node.getAttribute("data-ai-source");
      if (src) {
        const line = node.getAttribute("data-ai-line");
        return { file: src, line: line ? Number(line) : null, component: node.getAttribute("data-ai-component") || null };
      }
      node = node.parentElement;
    }
    return null;
  }

  function sourceFor(el) {
    return fromAttributes(el) || fromFiber(el);
  }

  function unmark() {
    if (!marked) return;
    for (const c of Array.from(marked.classList)) if (c.startsWith(PREFIX)) marked.classList.remove(c);
    marked = null;
  }

  function mark(el) {
    if (el === marked) return;
    unmark();
    const ref = sourceFor(el);
    if (!ref || (!ref.file && !ref.component)) return;
    const payload = [ref.file || "", ref.line == null ? "" : String(ref.line), ref.component || ""].join(":");
    el.classList.add(PREFIX + b64url(payload));
    marked = el;
  }

  document.addEventListener("pointerover", (e) => { if (e.target && e.target.nodeType === 1) mark(e.target); }, true);
  document.addEventListener("pointerleave", unmark, true);
  window.addEventListener("blur", unmark);

  // Expose for debugging: window.__pairSource(document.activeElement)
  window.__pairSource = sourceFor;
})();
