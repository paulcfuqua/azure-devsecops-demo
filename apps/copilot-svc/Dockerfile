# copilot-svc (L8) container image.
#
# BUILD CONTEXT IS THE REPO ROOT (the service depends on the sibling package
# apps/shared/spec-renderer via a relative file: specifier):
#
#   docker build -f apps/copilot-svc/Dockerfile -t mls-copilot-svc:local .
#
# Runtime: Node 24, listens on 8080 (ACA ingress target port).
# ANTHROPIC_API_KEY is injected by the platform as a Key Vault reference — it is
# never baked into this image. With no key present the service runs in mock mode.

# ---------- build ----------
FROM node:24-bookworm-slim AS build
WORKDIR /repo

# The renderer package is the output contract (spec.schema.json) — copy it first
# so the file: dependency resolves during install.
COPY apps/shared/spec-renderer/package.json apps/shared/spec-renderer/package.json
COPY apps/shared/spec-renderer/spec.schema.json apps/shared/spec-renderer/spec.schema.json
COPY apps/shared/spec-renderer/dist apps/shared/spec-renderer/dist

WORKDIR /repo/apps/copilot-svc
COPY apps/copilot-svc/package.json apps/copilot-svc/package-lock.json ./
RUN npm ci --ignore-scripts

COPY apps/copilot-svc/tsconfig.json apps/copilot-svc/tsconfig.build.json ./
COPY apps/copilot-svc/src ./src
RUN npm run build

# Drop devDependencies (tsc/vitest/tsx) before they reach the runtime stage.
RUN npm prune --omit=dev --ignore-scripts

# ---------- runtime ----------
FROM node:24-bookworm-slim AS runtime
ENV NODE_ENV=production \
    PORT=8080
WORKDIR /repo/apps/copilot-svc

COPY --from=build /repo/apps/shared/spec-renderer /repo/apps/shared/spec-renderer
COPY --from=build /repo/apps/copilot-svc/node_modules ./node_modules
COPY --from=build /repo/apps/copilot-svc/dist ./dist
COPY apps/copilot-svc/package.json ./package.json
COPY apps/copilot-svc/config ./config
COPY apps/copilot-svc/fixtures ./fixtures

# Local lakehouse data (data/generated) is NOT baked in — it is gitignored
# generator output. Locally, mount it and set MLS_DATA_DIR; at L8 the lakehouse
# adapter points at the Fabric SQL analytics endpoint instead.
USER node
EXPOSE 8080
CMD ["node", "dist/index.js"]
