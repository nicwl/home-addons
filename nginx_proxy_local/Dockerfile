ARG BUILD_FROM
FROM $BUILD_FROM

# Local nightly build (home repo, addons/nginx_proxy_local), identical to the official add-on
# except for the next three lines. The ADD is the cache key for the package layer: Docker
# downloads Alpine's package index on every build and re-runs the layer only when the index
# changed, i.e. exactly when Alpine 3.24 has published a package update. Every package in the
# image is then upgraded, not just nginx and openssl, so the image trails Alpine by a day at most.
ADD https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/DOES-NOT-EXIST.tar.gz /tmp/apkindex-main.tar.gz
RUN apk upgrade --no-cache && apk add --no-cache nginx openssl \
    && date -u +%Y-%m-%dT%H:%M:%SZ > /etc/local-build-date && rm -f /tmp/apkindex-main.tar.gz

# Copy data
COPY rootfs /

WORKDIR /
