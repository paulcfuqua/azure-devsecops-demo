import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import type { ComplianceCatalog, ComplianceState } from "./types";

// Static SPA, state baked in at build time -- no backend, no API, no
// managed identity (design spec section 5.1; Task 13 configures Container
// Apps Easy Auth in front of this and grants it nothing). These two
// imports resolve through Vite/Rollup's normal module graph at build time
// and end up as literal JS objects in the bundle -- the same "the artifact
// you can prove is the one rendered" property V7.1 already gives every
// other app via its image digest. Because they are resolved as JS module
// imports (not served as raw files over the dev-server's HTTP boundary),
// no `server.fs.allow` configuration is needed for `vite build`, and `vite
// dev`/`vite preview` are covered by Vite's own workspace-root detection
// (it walks up from this file looking for a lockfile or a package.json
// with a "workspaces" field, and finds the repo root's).
//
// JSON-import type inference produces a structural type narrower than (and
// not always assignable to) the hand-written ComplianceState/ComplianceCatalog
// interfaces in ./types -- e.g. a field that happens to be non-null in this
// one artifact infers as non-nullable. The double cast below is the
// standard way around that: it asserts the data contract's shape rather
// than trusting whatever TypeScript inferred from one snapshot's contents.
import catalogJson from "../../../compliance/catalog/nist-800-171r2.json";
import latestStateJson from "../../../compliance/state/state-latest.json";

const catalog = catalogJson as unknown as ComplianceCatalog;
const latestState = latestStateJson as unknown as ComplianceState;

// Every dated snapshot compliance.yml has ever committed, oldest first, for
// Task 12's trend view. state-latest.json (imported above as the current
// snapshot) is a byte-identical copy of the most recent dated file --
// compliance/README.md: "a real file copy, never a symlink" -- so it is
// excluded here by name to avoid counting the same day twice.
const historyModules = import.meta.glob<ComplianceState>(
  "../../../compliance/state/state-*.json",
  { eager: true, import: "default" },
);
const history: ComplianceState[] = Object.entries(historyModules)
  .filter(([path]) => !path.endsWith("state-latest.json"))
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([, snapshot]) => snapshot);

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root element");

createRoot(root).render(
  <StrictMode>
    <App state={latestState} catalog={catalog} history={history} />
  </StrictMode>,
);
