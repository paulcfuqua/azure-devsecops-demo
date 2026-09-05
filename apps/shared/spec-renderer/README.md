# @mls/spec-renderer

Fixed JSON-spec-to-UI renderer for the Meridian Launch Systems demo apps
(`launch-ops`, `control-tower`) and the copilot showpiece.

**The design rule this library enforces:** the copilot service (L8) returns a
**JSON component spec — never React code, never HTML**. That JSON is validated
against [`spec.schema.json`](./spec.schema.json) and rendered by this fixed,
human-authored component set. The copilot may only emit what this schema
allows; anything else renders as a validation-error MessageBar, not UI. This is
the safety boundary that lets LLM output drive the screen without the LLM ever
authoring executable UI.

## Schema overview

`spec.schema.json` is a JSON Schema (draft 2020-12). The top-level document is:

```json
{
  "version": "1",
  "layout": "stack",
  "components": [ { "type": "statCard", "title": "Launch Success Rate", "value": 98.3, "unit": "%" } ]
}
```

- `version` — always the string `"1"`.
- `layout` — `"stack"` (vertical flow) or `"grid"` (responsive auto-fit grid).
- `components` — 1–24 component specs, discriminated by `type` (Ajv
  `discriminator` on the `oneOf` union, so errors point at the right branch).

Shared shapes: `xyPoint` `{ x: string|number, y: number }` for cartesian
charts, `labelValuePoint` `{ label, value }` for the donut, and formatting
hints `unit` (display suffix) and `decimals` (0–6 fraction digits). Every
object is `additionalProperties: false` — unknown fields are rejected, which
keeps the LLM contract tight.

## Component gallery

| `type`          | Renders                                                       | Required props                | Optional props                                    |
| --------------- | ------------------------------------------------------------- | ----------------------------- | ------------------------------------------------- |
| `barChart`      | Fluent `VerticalBarChart`                                     | `title`, `data` (xyPoint[])   | `description`, `unit`, `decimals`                 |
| `lineChart`     | Fluent `LineChart` (single series)                            | `title`, `data` (xyPoint[])   | `description`, `unit`, `decimals`                 |
| `areaChart`     | Fluent `AreaChart` (single series)                            | `title`, `data` (xyPoint[])   | `description`, `unit`, `decimals`                 |
| `statCard`      | Fluent `Card` with big formatted value + trend arrow          | `title`, `value`              | `description`, `unit`, `decimals`, `trend`, `delta` |
| `kpiRow`        | Wrapping row of stat tiles                                    | `title`, `items` (1–8)        | `description`; per item `unit`/`decimals`/`trend` |
| `dataTable`     | Fluent `Table` with per-column alignment                      | `title`, `columns`, `rows`    | `description`, column `align`                     |
| `timeline`      | Vertical milestone rail (dot + date + label)                  | `title`, `events` (1–50)      | `description`; per event `description`, `kind`    |
| `donutChart`    | Fluent `DonutChart` with total in the hole                    | `title`, `data` (label/value) | `description`, `unit`, `decimals`                 |
| `markdownBlock` | Safe markdown subset rendered as React elements               | `markdown`                    | `title`                                           |

Notes:

- **Line/area x-axis coercion.** Fluent `LineChart`/`AreaChart` accept only
  `number | Date` x values. The schema also allows strings: all-numeric data
  stays numeric, ISO-date strings become `Date`s, and anything else falls back
  to evenly spaced index positions. Prefer numbers or ISO dates.
- **Markdown is never injected as HTML.** `markdownBlock` supports headings
  (`#`–`####`, rendered as `h3`–`h6` so specs never fight the host page),
  paragraphs, bold/italic/inline code, fenced code blocks, lists, and
  `http(s)` links. Raw HTML in the string renders as literal text — LLM output
  cannot XSS the host app.
- **Per-component error isolation.** Each component renders inside an error
  boundary; a component that throws degrades to a warning MessageBar instead
  of taking down the whole response.

## Chart library decision

Charts use **`@fluentui/react-charts`** (the Fluent UI v9 charting package),
not recharts. It was the preferred option and it installs cleanly on
React 18 / Node 24: its peer range is `react >=16.14 <20`, it shares Griffel
and design tokens with `@fluentui/react-components`, and it needed no styling
shims. The recharts-styled-with-Fluent-tokens fallback was therefore not used.
jsdom tests need three small polyfills (`ResizeObserver`, canvas
`measureText`, SVG `getBBox`/`getComputedTextLength`) — see
[`tests/setup.ts`](./tests/setup.ts); real browsers need nothing.

## Usage

```tsx
import { SpecRenderer, validateSpec } from "@mls/spec-renderer";

// Render untrusted copilot output — validates first, never throws:
<FluentProvider theme={webLightTheme}>
  <SpecRenderer spec={jsonFromCopilot} />
</FluentProvider>;

// Or validate server-side before returning a spec to the client (L8 does this):
const { ok, errors } = validateSpec(candidate); // errors: [{ path, message, keyword }]
```

Invalid input (wrong enum, missing field, wrong data shape, or not JSON at
all) renders a Fluent `MessageBar` listing JSON-Pointer error paths — the
component never throws. `isSpec(json)` is exported as a TypeScript type guard,
and the full `Spec`/`ComponentSpec` types plus the raw `specSchema` object are
exported too (`@mls/spec-renderer/spec.schema.json` resolves to the schema
file itself, e.g. for the copilot's system prompt).

## Entry points: `.` for UI, `./validate` for servers

The package ships **two** entries. Pick by whether you have a DOM.

| Import                          | Use it from                                          | Exports                                                                                     | Pulls in            |
| ------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------- |
| `@mls/spec-renderer`            | Browser / React apps (`launch-ops`, `control-tower`) | `SpecRenderer`, `formatValue`, plus everything below                                          | React + Fluent UI   |
| `@mls/spec-renderer/validate`   | Node servers (`copilot-svc`), CLIs, CI checks        | `validateSpec`, `isSpec`, `specSchema`, `SpecValidationResult`/`SpecValidationError`, all types | `ajv` only          |
| `@mls/spec-renderer/spec.schema.json` | Anything that needs the raw schema document    | the JSON Schema file itself                                                                   | nothing             |

```ts
// Server-side: validate copilot output before it ever reaches a client.
import { validateSpec } from "@mls/spec-renderer/validate";

const { ok, errors } = validateSpec(candidate);
```

**Why the subpath exists.** The root entry imports React and Fluent UI at
module scope, so `import("@mls/spec-renderer")` in a plain Node process dies
with `'tabster' does not provide an export named 'createTabster'`. Before this
entry existed, `copilot-svc` had to re-implement validation against
`spec.schema.json` — two copies of the copilot's output contract, free to
drift. `./validate` is built from `src/validate-entry.ts`, whose entire import
graph is `src/validate.ts` -> `ajv` + `spec.schema.json` (plus the type-only
`src/types.ts`), so the server runs the *same* `validateSpec` the renderer
runs. Both entries are emitted as ESM + CJS + `.d.ts` with no shared chunks,
so nothing can leak the renderer into a server bundle.

That invariant is enforced, not just documented:
[`tests/node/import-graph.test.ts`](./tests/node/import-graph.test.ts) walks
the `validate-entry` import graph and fails on any `react`/`@fluentui`/
`tabster`/`keyborg` specifier or any `src/components/` file, and
[`tests/node/validate-node.test.ts`](./tests/node/validate-node.test.ts) runs
in a vitest project with `environment: "node"` (no jsdom, no DOM setup file)
and additionally spawns a real `node` process that imports the built
`@mls/spec-renderer/validate` subpath.

If you add an import to `src/validate.ts`, `src/types.ts`, or
`src/validate-entry.ts`, keep it DOM-free — otherwise the copilot's validation
gate stops loading and the safety boundary goes with it.

## How the apps consume it

The package is `private` and consumed as an **npm workspace dependency** from
the monorepo root — it is never published. In each app:

```json
{ "dependencies": { "@mls/spec-renderer": "*" } }
```

`react`/`react-dom` 18 are peer dependencies (the app provides them, along
with a `FluentProvider`); `@fluentui/react-components`, `@fluentui/react-charts`
and `ajv` are regular dependencies of this package. Until the root workspace
manifest lands (Track F/G wiring), the package builds and tests standalone
from this directory.

## Develop

```sh
npm install
npm test        # vitest, 59 tests across two projects:
                #   renderer — jsdom + @testing-library/react (46)
                #   node     — no jsdom, guards the ./validate entry (13)
npm run build   # tsc typecheck, then tsup -> dist/ (ESM + CJS + .d.ts,
                # entries: index + validate)
```

Golden fixtures live in [`fixtures/`](./fixtures): one valid spec per
component type (9) plus three invalid specs (bad `layout` enum, missing
required `title`, x/y points where label/value is required). The test suite
asserts every valid fixture validates, every invalid one fails with the
expected error paths, and every component type renders with its title visible.

## Who else reads these fixtures

The golden fixtures are not only this package's test data. **L7's V7.2 —
"renderer schema validation passes on golden specs" — runs the validator in
`./validate` against every file in `fixtures/` from the Verifier's own
workflow**, as an independent check that the deployed renderer contract still
accepts what the copilot is expected to emit (L8 V8.4 pins the same schema for
Adaptive Card payloads).

Two consequences worth knowing before editing this directory:

- **Adding a valid fixture widens what V7.2 asserts.** That is usually the
  point — a new component type should arrive with one.
- **Renaming or deleting one narrows it silently.** The suite still passes,
  because it iterates whatever is present; V7.2 does too. Neither will tell you
  the coverage shrank, so treat a deletion here as a deliberate scope change
  rather than a tidy-up.

Because this package sits under `apps/shared/**`, a change to it triggers
**both** the launch-ops and control-tower pipelines — they each declare
`apps/shared/**` alongside their own app path. That fan-out is deliberate:
both frontends consume this renderer, so neither may be built against an
unvalidated version of it.
