# data-api (L7) container image — the serving layer both frontends fetch from.
#
# BUILD CONTEXT IS THE REPO ROOT, by convention with the other app images, and
# here it is a hard requirement rather than a convention: this package is a
# member of the root npm workspace and has no lockfile of its own, so a
# reproducible `npm ci` needs the root `package-lock.json`.
#
#   docker build -f apps/data-api/Dockerfile -t mls-data-api:local .
#
# Runtime: Node 24, listens on 8080 (ACA ingress target port), serving
# GET /tables/:table, GET /feeds/:name and GET /healthz. It holds no stored
# credential: Azure SQL, the Fabric SQL analytics endpoint, Defender and Log
# Analytics all authenticate with the container app's managed identity via
# @azure/identity (hard rule 5). The one credential-shaped value it can read,
# MLS_GITHUB_TOKEN, arrives as a Container Apps secret reference resolved from
# Key Vault at start — never baked into this image and never in the repo.

# ---------- dependencies (with dev deps, to compile) ----------
FROM node:26-bookworm-slim AS deps
WORKDIR /repo

# Manifests only, so a source edit does not invalidate the install layer.
#
# Every workspace member's package.json must be listed: `npm ci` validates the
# whole lockfile even when installing one workspace. Adding a workspace without
# adding it here fails loudly ("package.json and package-lock.json are not in
# sync"), which is the failure mode you want.
COPY package.json package-lock.json ./
COPY apps/data-api/package.json ./apps/data-api/
COPY apps/launch-ops/package.json ./apps/launch-ops/
COPY apps/control-tower/package.json ./apps/control-tower/
COPY apps/mcp-tools/package.json ./apps/mcp-tools/
COPY apps/directline-token/package.json ./apps/directline-token/
COPY apps/cost-ingest/package.json ./apps/cost-ingest/
COPY apps/shared/spec-renderer/package.json ./apps/shared/spec-renderer/

# Only this workspace's dependency set — not the whole monorepo's. The
# frontends' Fluent UI graph has no business in a backend image.
RUN npm ci --workspace apps/data-api --include-workspace-root --ignore-scripts

# ---------- build ----------
FROM deps AS build
WORKDIR /repo
COPY apps/data-api/tsconfig.json apps/data-api/tsconfig.build.json ./apps/data-api/
COPY apps/data-api/src ./apps/data-api/src
RUN npm run build --workspace apps/data-api

# ---------- production dependencies ----------
# A separate clean install rather than `npm prune`: pruning a hoisted workspace
# tree is fiddly to get right, and a second `npm ci` from the same lockfile is
# both simpler and provably the same resolution.
FROM deps AS prod-deps
WORKDIR /repo
# The mkdir is not redundant, and since the F37 dedupe it is load-bearing: with
# nothing nested, npm creates no apps/data-api/node_modules at all, and a Docker
# COPY whose source is missing fails the build. This makes the runtime stage's
# COPY of that path valid in both states -- empty today, populated the next time
# a version conflict forces npm to nest something.
RUN npm ci --workspace apps/data-api --include-workspace-root --omit=dev --ignore-scripts \
    && mkdir -p /repo/apps/data-api/node_modules

# ---------- runtime ----------
FROM node:26-bookworm-slim AS runtime
ENV NODE_ENV=production \
    PORT=8080
WORKDIR /repo/apps/data-api

# TWO dependency trees have to come across, not one. npm hoists what it can to
# /repo/node_modules, but a workspace whose pin conflicts with the hoisted
# version gets a NESTED copy under apps/data-api/node_modules instead, and
# copying only the root tree silently drops it.
#
# TODAY THIS DIRECTORY IS EMPTY, and the COPY below is still correct and still
# required. Whether npm nests anything is a property of the lockfile on any
# given day, not of this Dockerfile; the state that shipped as finding F37 is
# one `npm install` away from returning. What F37 actually was: an exact pin of
# @azure/monitor-opentelemetry-exporter@1.0.0-beta.32 conflicted with the
# beta.44 the root tree hoists, so the exporter and four @opentelemetry packages
# resolved under apps/data-api/node_modules -- five non-dev packages the runtime
# stage left behind, on the assumption, written here as a comment, that
# "workspace dependencies hoist to the repo root". The image built, pushed and
# passed its Trivy scan, then died on the first line of real work:
#
#   Error [ERR_MODULE_NOT_FOUND]: Cannot find package
#   '@azure/monitor-opentelemetry-exporter' imported from
#   /repo/apps/data-api/dist/telemetry/otel.js
#
# The pin has since moved to beta.44, which dedupes the subtree to nothing --
# and closed CVE-2026-54285 in the bargain, because the nested tree was also the
# only place @opentelemetry/core@2.0.0 survived. Both fixes are kept: one makes
# the tree clean now, the other makes the image correct whatever the tree does
# next. Node resolves upward from WORKDIR, so the nested tree wins and the
# hoisted one is the fallthrough -- the order npm builds the two trees for.
#
# No test in the repository could have caught F37, because nothing ran the
# image -- which is precisely why F22's smoke test now boots it in CI and calls
# its own /healthz before the merge.
COPY --from=prod-deps /repo/node_modules /repo/node_modules
COPY --from=prod-deps /repo/apps/data-api/node_modules ./node_modules
COPY --from=build /repo/apps/data-api/dist ./dist
COPY apps/data-api/package.json ./package.json
COPY apps/data-api/fixtures ./fixtures

# data/generated is NOT baked in: it is gitignored generator output, and it is
# only read in LOCAL mode, which is a test harness rather than a deliverable
# (sponsor directive 2026-08-24 — the demo runs on the tenant). To run this
# image locally against it, mount it and set MLS_DATA_DIR.
USER node
EXPOSE 8080

# Probes hit GET /healthz, which also reports which backend set is live and
# whether tracing is exporting.
CMD ["node", "dist/index.js"]
