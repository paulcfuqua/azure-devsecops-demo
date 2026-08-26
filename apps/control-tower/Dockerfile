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

# V7.1's content-hash marker, interpolated into /healthz by the same envsubst
# pass. A default is MANDATORY, not cosmetic: the nginx entrypoint substitutes
# only variables that are actually present in the environment, so an unset
# MLS_IMAGE_DIGEST would leave the literal ${MLS_IMAGE_DIGEST} in the config and
# nginx would refuse to start on an unknown variable. The L7 deploy overwrites
# it with the digest of the image it rolled.
ENV MLS_IMAGE_DIGEST=unset

# data-api and mcp-tools already drop to a non-root user (USER node); this
# frontend ran as root. nginx:1.27-alpine creates the `nginx` user/group in
# its base image (see docker-library/docker-nginx) but does not itself run as
# non-root, so USER nginx alone is not enough. Verified against the actual
# nginx.org Alpine package contents (nginx-1.28.0-r1.apk, same build recipe as
# the pinned 1.27 line) -- not assumed -- this needs three fixes:
#   - /etc/nginx/conf.d has to stay writable by `nginx`, or the entrypoint's
#     envsubst pass over *.template (this Dockerfile's whole reason for
#     existing) fails closed: 20-envsubst-on-templates.sh checks `[ -w
#     "$output_dir" ]` and silently skips rendering if it is not writable,
#     which would leave nginx serving the stock "Welcome to nginx!" page on
#     port 80 instead of this app on 8080 -- not a crash, a silent wrong-app
#     failure, which is worse.
#   - the stock nginx.conf's pid directive is `pid  /run/nginx.pid;` (NOT
#     /var/run -- that path is only a symlink to /run, and the text in the
#     file is what sed has to match); /run is root:root mode 755 in the base
#     alpine image, not writable by a non-root process, and not a tmpfs this
#     Dockerfile mounts, so the pid path is redirected to /tmp (mode 1777).
#   - /var/cache/nginx (used for proxy_temp while proxying /api/) does not
#     exist in this image at all -- it is created lazily by nginx at runtime
#     the first time a proxied response spills to disk, under a /var/cache
#     that is root:root 755. It is created and chowned here so nginx can still
#     create its proxy_temp/client_temp/etc. subdirectories under it.
# 8080 itself needs no fix: it is >1024, so no CAP_NET_BIND_SERVICE is needed
# to bind it as non-root.
RUN sed -i '/user  nginx;/d' /etc/nginx/nginx.conf \
    && sed -i 's,/run/nginx.pid,/tmp/nginx.pid,' /etc/nginx/nginx.conf \
    && mkdir -p /var/cache/nginx \
    && chown -R nginx:nginx /etc/nginx/conf.d /var/cache/nginx

USER nginx

EXPOSE 8080
# nginx:alpine's default entrypoint/cmd serve the static bundle.
