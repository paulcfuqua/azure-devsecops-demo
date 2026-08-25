# Briefs

Two presentation documents about the reference environment, and the script that
exports them to print-ready PDF.

| File | Audience | Length |
|---|---|---|
| `readiness-brief.html` → `Meridian-Readiness-Brief.pdf` | Engineering, security and operations leadership | 7 pages |
| `board-one-pager.html` → `Meridian-Board-One-Pager.pdf` | Board / executive committee | **1 page** |
| `kickoff-prompt.html` → `Meridian-Kickoff-Prompt.pdf` | Document of record | 5 pages |

`kickoff-prompt.html` reproduces the founding prompt as issued on 2026-08-22. It is
the fuller record: `docs/BRIEF.md` carries the same brief sections but omits the
opening session instruction and the closing first task. Neither file is edited when
a decision changes — the LLM-provider line still reads as originally written, and
its supersession lives in `docs/superpowers/specs/` instead.

Both are self-contained HTML — no build step, no framework. Open either file in a
browser to read it, or use the PDFs.

## Regenerating the PDFs

```sh
cd docs/briefs
npm install      # playwright-core drives the Chrome already on the machine
npm run pdf
```

This folder is deliberately **not** part of the root npm workspace: it is
documentation tooling, and nothing under `apps/` should carry a browser driver in
its dependency graph.

Headless Chrome's `--print-to-pdf` is **not** sufficient here, for two reasons found
the hard way:

1. **It races the web fonts.** The PDF came out with only one of the three families
   embedded and the rest silently substituted. `make-pdfs.mjs` awaits
   `document.fonts.ready` before printing.
2. **It omits backgrounds by default**, which flattens every panel, rule and the
   figures band. The script passes `printBackground: true`.

It also pins `colorScheme: "light"` so the export is unaffected by the operating
system's theme — a dark-mode PDF of a document meant for paper is the classic
export bug.

## Page geometry lives in the CSS

Each document owns its own `@page { size: A4; margin: … }` rule, and the export runs
with `preferCSSPageSize` so it defers to that rather than adding margins of its own.
That keeps browser printing (Ctrl-P) and the generated PDF identical — worth
preserving if you edit either file.

## The one-pager is one page on purpose

It is trimmed to fit A4 with the margin it declares, and it is easy to push it over.
After any edit:

```sh
npm run pdf && npm run pages     # must report "1 page(s)" for the one-pager
```

Chrome paginates more conservatively than the raw content height suggests. This
document measured 901px against a 1029px printable area and still exported to two
pages; the closing line and footer were the overflow. So **"it measured shorter than
the page" is not evidence that it fits** — check the page count, every time.
