# launch-ops — multi-stage: node build -> nginx static serve on 8080.
# Build from the REPO ROOT so the npm workspace (root lockfile + the
# @mls/spec-renderer workspace dependency) is inside the context:
#
#   docker build -f apps/launch-ops/Dockerfile -t mls-launch-ops .
#
# Built and Trivy-scanned by app-launch-ops-ci.yml (Track G / L7); not run locally.

FROM node:24-alpine AS build
WORKDIR /repo

# Manifests first for layer-cached installs.
COPY package.json package-lock.json ./
COPY apps/shared/spec-renderer/package.json apps/shared/spec-renderer/
COPY apps/launch-ops/package.json apps/launch-ops/
RUN npm ci --workspace apps/shared/spec-renderer --workspace apps/launch-ops

# Sources, then build the workspace dep before the app.
COPY apps/shared/spec-renderer apps/shared/spec-renderer
COPY apps/launch-ops apps/launch-ops
RUN npm run build --workspace apps/shared/spec-renderer \
    && npm run build --workspace apps/launch-ops

FROM nginx:1.27-alpine
COPY apps/launch-ops/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /repo/apps/launch-ops/dist /usr/share/nginx/html
EXPOSE 8080
# nginx:alpine's default entrypoint/cmd serve the static bundle.
