# control-tower — multi-stage: node build -> nginx static serve on 8080.
# Build from the REPO ROOT so the npm workspace (root lockfile + the
# @mls/spec-renderer workspace dependency) is inside the context:
#
#   docker build -f apps/control-tower/Dockerfile -t mls-control-tower .
#
# Built and Trivy-scanned by app-control-tower-ci.yml (Track G / L7); not run locally.

FROM node:24-alpine AS build
WORKDIR /repo

# Manifests first for layer-cached installs.
COPY package.json package-lock.json ./
COPY apps/shared/spec-renderer/package.json apps/shared/spec-renderer/
COPY apps/control-tower/package.json apps/control-tower/
RUN npm ci --workspace apps/shared/spec-renderer --workspace apps/control-tower

# Sources, then build the workspace dep before the app.
COPY apps/shared/spec-renderer apps/shared/spec-renderer
COPY apps/control-tower apps/control-tower
RUN npm run build --workspace apps/shared/spec-renderer \
    && npm run build --workspace apps/control-tower

FROM nginx:1.27-alpine
# Template, not a finished config: the nginx entrypoint runs envsubst over
# /etc/nginx/templates/*.template into /etc/nginx/conf.d/ at container start.
COPY apps/control-tower/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /repo/apps/control-tower/dist /usr/share/nginx/html

# Deliberately an unreachable ADDRESS, not a hostname. nginx resolves names in
# proxy_pass at startup and refuses to start if one does not resolve, so a
# hostname default would turn "API not configured yet" into "the app is down".
# With this, the SPA serves normally and only /api returns 502 until the L7
# deploy sets DATA_API_ORIGIN to the data-api container app's URL.
ENV DATA_API_ORIGIN=http://127.0.0.1:8081

EXPOSE 8080
# nginx:alpine's default entrypoint/cmd serve the static bundle.
