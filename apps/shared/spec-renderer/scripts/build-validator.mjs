/**
 * Precompile the component-spec JSON Schema into a standalone validator.
 *
 * WHY THIS EXISTS (F111). `ajv.compile()` builds its validator by generating
 * JavaScript source and evaluating it — `new Function` under the hood. The
 * dashboards ship a deliberately strict Content Security Policy
 * (`script-src 'self'`, no `'unsafe-eval'`), so the browser refuses and the
 * renderer reports "validation failed unexpectedly" for a spec that is
 * perfectly valid. It surfaced the first time real data reached the renderer;
 * nothing before that had exercised the validator in a browser with the CSP
 * applied.
 *
 * The fix is NOT to allow 'unsafe-eval'. Weakening the CSP of a security demo
 * to satisfy a validation library trades the thing being demonstrated for the
 * thing demonstrating it. Ajv supports standalone code generation for exactly
 * this case: the schema is compiled HERE, at build time, into ordinary
 * JavaScript that runs under the strict policy unchanged.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import standaloneCode from "ajv/dist/standalone/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const schema = JSON.parse(readFileSync(resolve(root, "spec.schema.json"), "utf-8"));

// These options must match src/validate.ts's former runtime Ajv options exactly,
// or the precompiled validator accepts a different language than the tests exercise.
const ajv = new Ajv2020({
  allErrors: true,
  discriminator: true,
  strict: false,
  code: { source: true, esm: true },
});

const source = standaloneCode(ajv, ajv.compile(schema));

// ONE require SURVIVES ESM MODE, AND IT HAS TO GO.
//
// `code.esm: true` makes Ajv emit `export` statements, but its standalone output
// still pulls runtime helpers in with CommonJS `require(...)`. Bundled for the
// browser that becomes tsup's `__require` shim, which throws "Dynamic require of
// 'ajv/dist/runtime/ucs2length' is not supported" the moment the module loads —
// so the package fails to import at all, which is worse than the CSP problem it
// was written to fix.
//
// Hoisting that single helper to a real import is the whole transform. It is done
// here, visibly, rather than by a bundler plugin: a generated file that quietly
// differs from what Ajv produced is a thing nobody can reason about later.
const RUNTIME_REQUIRE = /require\("(ajv\/dist\/runtime\/[^"]+)"\)\.default;/g;
const imports = new Set();
let esm = source.replace(RUNTIME_REQUIRE, (_match, specifier) => {
  const alias = `__ajvRuntime${imports.size}`;
  // ".js" is required. Ajv's own require() resolves extensionless via CommonJS, but
  // Node's ESM resolver does not - it fails with "Did you mean to import
  // ucs2length.js?" at load time, which a bundler never surfaces because it resolves
  // extensionless happily. Adding it satisfies both.
  const withExtension = specifier.endsWith(".js") ? specifier : `${specifier}.js`;
  // INTEROP-SAFE, BECAUSE NODE AND VITE DISAGREE. The helper is CommonJS with its
  // function on `exports.default`, which is why Ajv wrote `require(...).default`.
  // A plain ESM default-import of that module gives `module.exports` under Node -
  // so `.default` is needed - but Vite interops it and hands back the function
  // itself, where `.default` is undefined. Getting it wrong either way produces a
  // validator that imports cleanly and then rejects every spec with "func is not a
  // function", which looks like a schema bug and is not one.
  imports.add(`import ${alias} from "${withExtension}";`);
  imports.add(`const ${alias}Fn = ${alias} && ${alias}.default ? ${alias}.default : ${alias};`);
  return `${alias}Fn;`;
});
if (imports.size > 0) {
  esm = [...imports].join("\n") + "\n" + esm;
}

// Fail the build rather than ship a module that cannot be imported. A survivor here
// is silent in the bundle and fatal at load time.
if (/\brequire\(/.test(esm)) {
  throw new Error(
    "build-validator: a require() survived the ESM transform. The package would fail " +
      "to import in a plain Node process and in the browser bundle. Widen RUNTIME_REQUIRE.",
  );
}

const out = resolve(root, "src", "validate.generated.js");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, esm, "utf-8");
console.log(
  `spec-renderer: precompiled validator -> src/validate.generated.js ` +
    `(${esm.length} bytes, ${imports.size} runtime import(s) hoisted)`,
);
