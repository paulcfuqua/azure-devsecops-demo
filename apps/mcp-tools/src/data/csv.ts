/**
 * Minimal RFC 4180 CSV parser — no dependencies (keeps the service's supply
 * chain small). Handles quoted fields, escaped quotes, CRLF/LF, and trailing
 * newlines. Track A's generated CSVs are currently quote-free, but the parser
 * does not rely on that.
 */

export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  let i = 0;
  const n = text.length;

  const pushField = () => {
    row.push(field);
    field = "";
  };
  const pushRow = () => {
    pushField();
    rows.push(row);
    row = [];
  };

  while (i < n) {
    const c = text[i]!;
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 2;
        } else {
          inQuotes = false;
          i += 1;
        }
      } else {
        field += c;
        i += 1;
      }
    } else if (c === '"' && field.length === 0) {
      inQuotes = true;
      i += 1;
    } else if (c === ",") {
      pushField();
      i += 1;
    } else if (c === "\r" && text[i + 1] === "\n") {
      pushRow();
      i += 2;
    } else if (c === "\n") {
      pushRow();
      i += 1;
    } else {
      field += c;
      i += 1;
    }
  }
  // Final field/row unless input ended with a newline.
  if (field.length > 0 || row.length > 0) pushRow();
  return rows;
}

export interface CsvTable {
  columns: string[];
  rows: string[][];
}

export function parseCsvTable(text: string): CsvTable {
  const all = parseCsv(text);
  if (all.length === 0) throw new Error("empty CSV");
  return { columns: all[0]!, rows: all.slice(1) };
}
