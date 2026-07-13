import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { analyzeWxr } from "../src/analyze/index.js";
import { extractScfDefinitions } from "../src/core/scf.js";
import { parseWxr, sanitizeXml } from "../src/core/wxr.js";

const fixturePath = fileURLToPath(new URL("./fixtures/mini-wxr.xml", import.meta.url));

async function fixture(withCrLfChoices = false) {
  const xml = await readFile(fixturePath, "utf8");
  const input = withCrLfChoices
    ? xml.replace('s:25:"販売中\nご成約済み"', 's:26:"販売中\r\nご成約済み"')
    : xml;
  return parseWxr(input);
}

describe("WXR analysis", () => {
  it("removes invalid XML controls and reports them", () => {
    const sanitized = sanitizeXml("before\u0008after\tkeep");
    expect(sanitized.text).toBe("beforeafter\tkeep");
    expect(sanitized.removed).toEqual([{ codePoint: 8, count: 1 }]);
  });

  it("keeps duplicate postmeta entries in source order", async () => {
    const exp = await fixture();
    const car = exp.items.find((item) => item.wpId === 10);
    expect(car?.meta.filter((meta) => meta.key === "image").map((meta) => meta.value)).toEqual(["1", "2", "3"]);
    expect(exp.sanitizeReport).toEqual([{ codePoint: 8, count: 1 }]);
  });

  it("restores SCF definitions", async () => {
    const definitions = extractScfDefinitions((await fixture(true)).items);
    expect(definitions).toHaveLength(1);
    expect(definitions[0]).toMatchObject({
      title: "Car fields",
      conditions: { postTypes: ["car"], postIds: [10, 11] },
      groups: [{ name: "gallery", repeat: true, fields: [{ name: "image" }, { name: "caption" }] }],
    });
    expect(definitions[0]?.groups[0]?.fields[0]?.choices).toBe("販売中\r\nご成約済み");
  });

  it("classifies encoded URLs and emits repeater mapping", async () => {
    const result = analyzeWxr(await fixture());
    expect((result.urlPatterns.car ?? []).some((entry) => entry.pattern === "/cars/{encoded}/")).toBe(true);
    expect(result.customPermalinks).toEqual([{ wpId: 10, link: "https://example.test/cars/%e3%83%9f%e3%83%8b/", customPermalink: "/special-car" }]);
    expect(result.mappingScaffold).toContain('"gallery": ["image", "caption"]');
    expect(result.mappingScaffold).toContain("featuredImage: true");
  });
});
