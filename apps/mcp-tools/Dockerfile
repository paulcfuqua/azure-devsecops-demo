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
# Runtime: Node 24, listens on 8080 (ACA ingress target port), serving
# POST /mcp (Streamable HTTP) and GET /healthz. There is no LLM in this image
# and no API key of any kind: all orchestration happens in Copilot Studio.

# ---------- build ----------
FROM node:24-bookworm-slim AS build
WORKDIR /repo/apps/mcp-tools

COPY apps/mcp-tools/package.json apps/mcp-tools/package-lock.json ./
RUN npm ci --ignore-scripts

COPY apps/mcp-tools/tsconfig.json apps/mcp-tools/tsconfig.build.json ./
COPY apps/mcp-tools/src ./src
RUN npm run build

# Drop devDependencies (tsc/vitest/tsx) before they reach the runtime stage.
RUN npm prune --omit=dev --ignore-scripts

# ---------- runtime ----------
FROM node:24-bookworm-slim AS runtime
ENV NODE_ENV=production \
    PORT=8080
WORKDIR /repo/apps/mcp-tools

COPY --from=build /repo/apps/mcp-tools/node_modules ./node_modules
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
