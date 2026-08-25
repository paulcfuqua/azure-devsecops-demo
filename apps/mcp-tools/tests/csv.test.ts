/** RFC 4180 CSV parser unit tests. */
import { describe, expect, it } from "vitest";
import { parseCsv, parseCsvTable } from "../src/data/csv.js";

describe("parseCsv", () => {
  it("parses simple rows with LF and trailing newline", () => {
    expect(parseCsv("a,b\n1,2\n")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("parses CRLF line endings", () => {
    expect(parseCsv("a,b\r\n1,2\r\n")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("handles quoted fields with commas, quotes, and newlines", () => {
    expect(parseCsv('a,b\n"x, y","she said ""hi"""\n')).toEqual([
      ["a", "b"],
      ["x, y", 'she said "hi"'],
    ]);
    expect(parseCsv('"line\nbreak",2\n')).toEqual([["line\nbreak", "2"]]);
  });

  it("preserves empty fields", () => {
    expect(parseCsv("a,,c\n,,\n")).toEqual([
      ["a", "", "c"],
      ["", "", ""],
    ]);
  });

  it("handles a final row without trailing newline", () => {
    expect(parseCsv("a,b\n1,2")).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("parseCsvTable splits header and rows", () => {
    const t = parseCsvTable("id,name\n1,alpha\n2,beta\n");
    expect(t.columns).toEqual(["id", "name"]);
    expect(t.rows).toEqual([
      ["1", "alpha"],
      ["2", "beta"],
    ]);
  });
});
