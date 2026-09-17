# mcp-tools (L8) container image — the MCP server the Copilot Studio agent
# attaches to as a tool source.
#
# BUILD CONTEXT IS THE REPO ROOT, by convention with the other app images:
#
#   docker build -f apps/mcp-tools/Dockerfile -t mls-mcp-tools:local .
#
# (This package no longer depends on the sibling apps/shared/spec-renderer, so
# nothing has to be pre-built into the context first — the old copilot-svc
# requirement to run `npm run build:renderer` before `docker build`, open item
# P-7, is gone with it. An app-directory context would work too if CI prefers.)
#
# SINGLE LOCKFILE (F201, 2026-09-16). This used to `COPY` a standalone
# apps/mcp-tools/package-lock.json and `npm ci` against it, because this was
# the only app image that installed in isolation. That made mcp-tools a
# workspace member with a SECOND, independently-drifting lockfile: npm and
# Dependabot both resolve a workspace member's manifest against the ROOT
# lockfile, so any bump to apps/mcp-tools/package.json from the root
# dependabot.yml entry updated the root lockfile and left the standalone one
# behind, silently, until this container build failed. It happened twice
# (commit 2b426ed, then PR #273). There is now exactly one lockfile — the
# root's — and this stage installs from it the same way
# apps/control-tower/Dockerfile and apps/data-api/Dockerfile already do.
# verification/tests/lockfile-sync.Tests.ps1 documents the class.
#
# Runtime: Node 24, listens on 8080 (ACA ingress target port), serving
# POST /mcp (Streamable HTTP) and GET /healthz. There is no LLM in this image
# and no API key of any kind: all orchestration happens in Copilot Studio.

# ---------- build ----------
FROM node:24-bookworm-slim AS build
WORKDIR /repo

# Manifests first for layer-cached installs. --workspace installs only this
# package (plus its deps) against the ROOT lockfile; it does not need every
# other workspace member's package.json present in the build context, only
# its own.
COPY package.json package-lock.json ./
COPY apps/mcp-tools/package.json apps/mcp-tools/
RUN npm ci --workspace apps/mcp-tools --ignore-scripts

COPY apps/mcp-tools/tsconfig.json apps/mcp-tools/tsconfig.build.json apps/mcp-tools/
COPY apps/mcp-tools/src apps/mcp-tools/src
RUN npm run build --workspace apps/mcp-tools

# Drop devDependencies (tsc/vitest/tsx) before they reach the runtime stage.
RUN npm prune --omit=dev --ignore-scripts

# ---------- runtime ----------
FROM node:24-bookworm-slim AS runtime
ENV NODE_ENV=production \
    PORT=8080
WORKDIR /repo/apps/mcp-tools

# node_modules is hoisted to the workspace ROOT by `npm ci --workspace`
# above, not into apps/mcp-tools/. Node's module resolution walks up parent
# directories looking for node_modules, so copying it to the matching
# ancestor path here (rather than into this WORKDIR) resolves exactly the
# way it does everywhere else this monorepo runs from its root.
COPY --from=build /repo/node_modules /repo/node_modules
COPY --from=build /repo/apps/mcp-tools/dist ./dist
COPY apps/mcp-tools/package.json ./package.json
COPY apps/mcp-tools/fixtures ./fixtures

# Task 8's committed compliance state artifact — query_compliance's whole data
# source, read-only and offline in every mode (config.ts's complianceStatePath
# resolves to repoRoot/compliance/state/state-latest.json, and repoRoot is
# this WORKDIR's grandparent, /repo, in this image).
COPY compliance/state/state-latest.json /repo/compliance/state/state-latest.json

# Local lakehouse data (data/generated) is NOT baked in — it is gitignored
# generator output. Locally, mount it and set MLS_DATA_DIR; at L5-L8 the
# lakehouse adapter points at the Fabric SQL analytics endpoint instead.
USER node
EXPOSE 8080
CMD ["node", "dist/index.js"]
