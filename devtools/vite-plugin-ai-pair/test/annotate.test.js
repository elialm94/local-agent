import { test } from "node:test";
import assert from "node:assert/strict";
import { annotateHostElements } from "../src/index.js";

test("annotates lowercase host elements with file and line", () => {
  const src = `export function SendOfferButton() {\n  return (\n    <button className="cta" onClick={send}>\n      Send offer\n    </button>\n  );\n}\n`;
  const out = annotateHostElements(src, "src/features/offers/SendOfferButton.tsx");
  assert.match(out, /<button data-ai-source="src\/features\/offers\/SendOfferButton.tsx" data-ai-line="3" className="cta"/);
  assert.ok(!out.includes('</button data-ai'), "closing tags untouched");
});

test("leaves components, fragments, comparisons and strings alone", () => {
  const src = [
    "const x = a < b && c > d;",
    "const s = \"<div>not jsx</div>\";",
    "return <><Card title=\"x\" /></>;",
    "// <span>comment</span>",
  ].join("\n");
  assert.equal(annotateHostElements(src, "f.tsx"), src);
});

test("does not double-annotate", () => {
  const src = '<div data-ai-source="a.tsx" data-ai-line="1">x</div>';
  assert.equal(annotateHostElements(src, "f.tsx"), src);
});
