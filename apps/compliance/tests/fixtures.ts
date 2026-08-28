// Fixtures for apps/compliance's own tests. Deliberately the REAL committed
// artifacts, not hand-rolled equivalents: compliance/state/state-latest.json
// is what this app renders, and a hand-authored stand-in could drift from
// its actual shape (which is exactly the kind of thing this platform exists
// to catch). Importing it directly means "renders from the real artifact
// shape" is not an assertion, it's structural.
//
// See the double-cast note in src/main.tsx for why these need `as unknown
// as`: JSON-import type inference narrows to this one snapshot's literal
// values, not to the hand-written data-contract interfaces in src/types.

import type { ComplianceCatalog, ComplianceState } from "../src/types";
import catalogJson from "../../../compliance/catalog/nist-800-171r2.json";
import realStateJson from "../../../compliance/state/state-latest.json";

export const fixtureCatalog = catalogJson as unknown as ComplianceCatalog;
export const fixtureState = realStateJson as unknown as ComplianceState;

/** A structurally-identical clone, safe to mutate per test without one
 * test's edits leaking into another (fixtureState is a module-level
 * singleton import). */
export function cloneState(): ComplianceState {
  return JSON.parse(JSON.stringify(fixtureState)) as ComplianceState;
}
