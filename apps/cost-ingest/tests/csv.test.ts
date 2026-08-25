// Run with `npm test` from apps/cost-ingest (the script uses a GLOB — a bare
// directory argument runs nothing). No dependencies and no build are required:
// the modules under test have none, and Node 22+/24 strips the types itself.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseCsv, splitCsvRows, toCsv } from "../src/csv.ts";

describe("splitCsvRows", () => {
  it("splits plain comma-separated rows on LF", () => {
    assert.deepEqual(splitCsvRows("a,b\n1,2\n"), [
      ["a", "b"],
      ["1", "2"],
    ]);
  });

  it("handles CRLF, and a missing final newline", () => {
    assert.deepEqual(splitCsvRows("a,b\r\n1,2\r\n3,4"), [
      ["a", "b"],
      ["1", "2"],
      ["3", "4"],
    ]);
  });

  it("keeps commas and newlines that live inside quotes", () => {
    const rows = splitCsvRows('a,b\n"x,y","line1\nline2"\n');
    assert.deepEqual(rows, [
      ["a", "b"],
      ["x,y", "line1\nline2"],
    ]);
  });

  it("unescapes doubled quotes, the shape the Tags column arrives in", () => {
    const rows = splitCsvRows('Tags\n"""costCenter"": ""Propulsion"""\n');
    assert.deepEqual(rows[1], ['"costCenter": "Propulsion"']);
  });

  it("preserves genuinely empty trailing fields", () => {
    assert.deepEqual(splitCsvRows("a,b,c\n1,,3\n"), [
      ["a", "b", "c"],
      ["1", "", "3"],
    ]);
  });
});

describe("parseCsv", () => {
  it("strips a UTF-8 BOM off the first header, which Cost Management writes", () => {
    const table = parseCsv("﻿UsageDate,Cost\n2026-08-01,1.5\n");
    assert.deepEqual([...table.headers], ["UsageDate", "Cost"]);
    assert.equal(table.records[0].UsageDate, "2026-08-01");
  });

  it("returns an empty table for empty or whitespace-only input", () => {
    for (const input of ["", "   ", "\n\n", "\r\n"]) {
      const table = parseCsv(input);
      assert.equal(table.headers.length, 0, `input ${JSON.stringify(input)}`);
      assert.equal(table.records.length, 0);
    }
  });

  it("returns headers but no records for a header-only file", () => {
    const table = parseCsv("UsageDate,Cost\n");
    assert.deepEqual([...table.headers], ["UsageDate", "Cost"]);
    assert.equal(table.records.length, 0);
  });

  it("reports ragged rows instead of shifting the columns under them", () => {
    const table = parseCsv("a,b,c\n1,2,3\n4,5\n6,7,8,9\n");
    assert.equal(table.records.length, 1);
    assert.equal(table.ragged.length, 2);
    assert.deepEqual([...table.ragged.map((entry) => entry.line)], [3, 4]);
  });

  it("drops blank lines rather than calling them ragged", () => {
    const table = parseCsv("a,b\n1,2\n\n3,4\n");
    assert.equal(table.records.length, 2);
    assert.equal(table.ragged.length, 0);
  });

  it("trims surrounding whitespace on headers and cells", () => {
    const table = parseCsv(" UsageDate , Cost \n 2026-08-01 , 1.50 \n");
    assert.deepEqual([...table.headers], ["UsageDate", "Cost"]);
    assert.equal(table.records[0].Cost, "1.50");
  });
});

describe("toCsv", () => {
  it("writes a fixed column order with LF newlines and a trailing newline", () => {
    const text = toCsv(["b", "a"], [{ a: 1, b: 2 }]);
    assert.equal(text, "b,a\n2,1\n");
  });

  it("renders null and undefined as empty, not as the strings", () => {
    assert.equal(toCsv(["a", "b"], [{ a: null, b: undefined }]), "a,b\n,\n");
  });

  it("quotes and escapes cells containing commas, quotes or newlines", () => {
    const text = toCsv(["a"], [{ a: 'x,"y"\nz' }]);
    assert.equal(text, 'a\n"x,""y""\nz"\n');
  });

  it("round-trips through parseCsv", () => {
    const rows = [{ a: "x,y", b: 'has "quotes"' }];
    const table = parseCsv(toCsv(["a", "b"], rows));
    assert.deepEqual({ ...table.records[0] }, rows[0]);
  });
});
