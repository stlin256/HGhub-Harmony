import { sanitizeHtml } from "../src/html";
import DOMPurify from "dompurify";

const fixture = document.querySelector<HTMLDivElement>("#fixture")!;
const results: { name: string; passed: boolean; error?: string }[] = [];
const assert = (value: unknown, message: string) => { if (!value) throw new Error(message); };
const marker = "window.__hghubAudit = 1;void(0)";

async function test(name: string, run: () => void | Promise<void>) {
  try { await run(); results.push({ name, passed: true }); }
  catch (e) { results.push({ name, passed: false, error: String(e) }); }
}

// 每个攻击样本同时检查清洗后的 DOM 和点击后的行为，不只匹配序列化字符串。
const attacks = [
  `<p>正文</p><svg><a xlink:href="javascript:${marker}"><text>click</text></a></svg>`,
  `<a href="java&#x09;script:${marker}">click</a>`,
  `<a href="javascript:${marker}">click</a>`,
  `<a href="data:text/html,<script>${marker}</script>">click</a>`,
  `<img src="broken" onerror="${marker}">`,
  `<svg><animate attributeName="href" values="javascript:${marker}"/></svg>`,
  `<math><mtext><table><mglyph><style><!--</style><img title="--><img src=broken onerror='${marker}'>">`,
  `<iframe srcdoc="<script>${marker}</script>"></iframe>`,
  `<form id="location"><input name="href" value="javascript:${marker}"></form>`,
  `<p style="position:fixed;inset:0" onclick="${marker}">click</p>`,
  `<img data-src="javascript:${marker}" src="data:image/gif;base64,AAAA">`,
];

for (const [i, attack] of attacks.entries()) {
  await test(`attack ${i + 1}`, async () => {
    (window as unknown as { __hghubAudit: number }).__hghubAudit = 0;
    fixture.innerHTML = sanitizeHtml(attack);
    assert(!fixture.querySelector("svg,math,script,style,iframe,object,embed,form,input"), "active tag survived");
    for (const el of fixture.querySelectorAll("*")) {
      for (const attr of el.attributes) {
        assert(!/^(on|xlink:|style$|id$|name$)/i.test(attr.name), `unsafe attribute: ${attr.name}`);
      }
    }
    for (const a of fixture.querySelectorAll("a")) {
      a.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    }
    await new Promise(resolve => setTimeout(resolve, 30));
    assert((window as unknown as { __hghubAudit: number }).__hghubAudit === 0, "script executed");
  });
}

await test("formatting and lazy image survive", () => {
  fixture.innerHTML = sanitizeHtml('<p><strong>正文</strong><img data-src="/cover.jpg" src="data:image/gif;base64,AAAA" alt="封面"></p>');
  assert(fixture.querySelector("strong")?.textContent === "正文", "formatting lost");
  const img = fixture.querySelector("img");
  assert(img?.getAttribute("src")?.includes("/img?u="), "image not proxied");
  assert(decodeURIComponent(img!.getAttribute("src")!).endsWith("https://example.invalid"), "wrong image URL");
  assert(img?.alt === "封面" && !img.hasAttribute("data-src"), "image attributes incorrect");
});

await test("safe links cannot retain opener", () => {
  fixture.innerHTML = sanitizeHtml('<a href="/video/123" target="_self" rel="opener">link</a>');
  const a = fixture.querySelector("a")!;
  assert(a.href === "https://example.invalid", "relative link broken");
  assert(a.target === "_blank" && a.rel === "noopener noreferrer", "unsafe link navigation");
});

await test("URL credentials are rejected", () => {
  fixture.innerHTML = sanitizeHtml('<a href="https://user:secret@example.com">link</a><img src="https://user:secret@example.com/image.jpg">');
  assert(!fixture.querySelector("a[href],img"), "URL credentials survived");
});

await test("unsupported WebViews fail closed", () => {
  const supported = DOMPurify.isSupported;
  try {
    DOMPurify.isSupported = false;
    assert(sanitizeHtml('<img src="broken" onerror="alert(1)">') === "", "unsupported sanitizer returned raw HTML");
  } finally { DOMPurify.isSupported = supported; }
});

fixture.replaceChildren();
const report = { passed: results.filter(r => r.passed).length, failed: results.filter(r => !r.passed).length, results };
document.querySelector("#results")!.textContent = JSON.stringify(report, null, 2);
(window as unknown as { securityResults: typeof report }).securityResults = report;
