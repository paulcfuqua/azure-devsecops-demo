/**
 * ONE shape function, used by every parity assertion.
 *
 * The response shapes are the contract between this service and the Copilot
 * Studio agent: the tool descriptions document them field by field, the agent
 * reasons over them, and the eval's fact walker walks them. So a cloud adapter
 * that returns a *differently shaped* answer to its local counterpart is a
 * breaking change dressed up as an implementation detail — and it would only be
 * discovered on the day the tenant is switched on, which is the worst possible
 * day to discover it.
 *
 * `describeShape` reduces a value to its structure: primitive type names, arrays
 * collapsed to the MERGE of their element shapes, objects to their key maps.
 * Values never survive, so two results with the same structure and different
 * data compare equal — which is what "same shape" has to mean when one side
 * reads CSVs and the other reads a subscription.
 *
 * Two deliberate rules:
 *   - Keys beginning with `$` are ignored. The committed fixtures carry a
 *     `$comment` explaining what real API response they imitate; that is
 *     provenance metadata for humans reading the repo, not part of the contract,
 *     and the live adapters have nothing to say there.
 *   - Arrays MERGE rather than sample. A GitHub code-scanning list where one
 *     alert carries `dismissed_reason` and another does not has one shape, and
 *     sampling element 0 would let a real difference hide behind an ordering.
 */

/**
 * A shape is a primitive type name, or a record. Two record keys are reserved
 * and act as tags: `"[]"` wraps an array's element shape, `"?"` wraps a shape
 * that was absent from some array members. Everything else is a real field name.
 */
export type Shape = string | ShapeRecord;
export interface ShapeRecord {
  [key: string]: Shape;
}

/**
 * Marker for "this key was absent from some members of an array". It never
 * survives a merge: it turns the other side into an explicit `{ "?": shape }`,
 * so "always present" and "sometimes present" stay distinguishable. A cloud
 * adapter that always emits a field the local one only sometimes emits is a
 * real difference, and collapsing optionality would hide it.
 */
export const ABSENT = "absent";

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRecord(value: Shape): value is ShapeRecord {
  return typeof value !== "string";
}

/** Read a tagged wrapper's payload, or undefined when the shape is not that tag. */
function untag(value: Shape, tag: "[]" | "?"): Shape | undefined {
  return isRecord(value) ? value[tag] : undefined;
}

/** Merge two shapes into the one shape that describes both. */
export function mergeShapes(a: Shape, b: Shape): Shape {
  // Peel optionality off both sides, merge the cores, then put it back if
  // either side had it.
  const optionalA = untag(a, "?");
  const optionalB = untag(b, "?");
  const optional = a === ABSENT || b === ABSENT || optionalA !== undefined || optionalB !== undefined;
  const coreA = a === ABSENT ? undefined : (optionalA ?? a);
  const coreB = b === ABSENT ? undefined : (optionalB ?? b);

  let merged: Shape;
  if (coreA === undefined && coreB === undefined) merged = ABSENT;
  else if (coreA === undefined) merged = coreB as Shape;
  else if (coreB === undefined) merged = coreA;
  else merged = mergeCore(coreA, coreB);

  return optional ? { "?": merged } : merged;
}

function mergeCore(a: Shape, b: Shape): Shape {
  if (a === b) return a;

  const elementA = untag(a, "[]");
  const elementB = untag(b, "[]");
  if (elementA !== undefined && elementB !== undefined) {
    return { "[]": mergeShapes(elementA, elementB) };
  }

  if (isRecord(a) && isRecord(b) && elementA === undefined && elementB === undefined) {
    const merged: ShapeRecord = {};
    for (const key of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) {
      merged[key] = mergeShapes(a[key] ?? ABSENT, b[key] ?? ABSENT);
    }
    return merged;
  }

  // Differing primitives (or a primitive against a container) become a stable
  // sorted union, so `null|string` reads the same whichever side produced which.
  return [JSON.stringify(a), JSON.stringify(b)].sort().join("|");
}

export function describeShape(value: unknown): Shape {
  if (value === null || value === undefined) return "null";
  if (Array.isArray(value)) {
    if (value.length === 0) return { "[]": ABSENT };
    return { "[]": value.map(describeShape).reduce(mergeShapes) };
  }
  if (isPlainObject(value)) {
    const shape: ShapeRecord = {};
    for (const key of Object.keys(value).sort()) {
      // Fixture provenance metadata, not contract.
      if (key.startsWith("$")) continue;
      shape[key] = describeShape(value[key]);
    }
    return shape;
  }
  return typeof value;
}
