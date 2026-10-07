import { describe, expect, it } from "vitest";
import de from "../src/_gt/de.json";
import en from "../src/_gt/en.json";
import { localeOfPath, localizePath, stripLocale } from "../src/lib/locales";

/** English entries that read the same in German. */
const sameInGerman = new Set(["Dashboard", "Download", "Macs", "Offline", "Skills", "Tests", "Tool", "Tools"]);

type Entries = Record<string, unknown>;

/** The text of an entry, without General Translation's tag, index and variable fields. */
function texts(entry: unknown): string[] {
  if (typeof entry === "string") return [entry];
  if (Array.isArray(entry)) return entry.flatMap(texts);
  if (entry && typeof entry === "object") {
    return Object.entries(entry).flatMap(([key, value]) => (["t", "i", "k", "v"].includes(key) ? [] : texts(value)));
  }
  return [];
}

/** The elements and variables of an entry, which a translation must keep: "i3", "k:_gt_value_3". */
function slots(entry: unknown): string[] {
  if (Array.isArray(entry)) return entry.flatMap(slots);
  if (entry && typeof entry === "object") {
    return Object.entries(entry).flatMap(([key, value]) =>
      key === "i" ? [`i${value}`] : key === "k" ? [`k:${value}`] : slots(value),
    );
  }
  return [];
}

describe("German translations", () => {
  const source = en as Entries;
  const german = de as Entries;

  it("cover every entry of the English source", () => {
    expect(Object.keys(source).filter((hash) => !(hash in german))).toEqual([]);
  });

  // `bunx gt generate` adds new and changed entries to de.json in English.
  it("leave no English behind", () => {
    const untranslated = Object.entries(source)
      .map(([hash, entry]) => [texts(entry).join(" "), texts(german[hash]).join(" ")] as const)
      .filter(([english, translated]) => english === translated && !sameInGerman.has(english))
      .map(([english]) => english);
    expect(untranslated).toEqual([]);
  });

  it("keep every element and variable of the source", () => {
    const broken = Object.keys(source).filter(
      (hash) => slots(source[hash]).sort().join() !== slots(german[hash]).sort().join(),
    );
    expect(broken).toEqual([]);
  });
});

describe("locale paths", () => {
  it("prefix German pages and leave server routes alone", () => {
    expect(localizePath("/", "de")).toBe("/de");
    expect(localizePath("/docs", "de")).toBe("/de/docs");
    expect(localizePath("/docs", "en")).toBe("/docs");
    expect(localizePath("/download", "de")).toBe("/download");
  });

  it("map public paths back to routes", () => {
    expect(stripLocale("/de")).toBe("/");
    expect(stripLocale("/de/docs")).toBe("/docs");
    expect(stripLocale("/design")).toBe("/design");
    expect(localeOfPath("/de/privacy")).toBe("de");
    expect(localeOfPath("/docs")).toBe("en");
  });
});
