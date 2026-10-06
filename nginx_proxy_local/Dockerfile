ARG BUILD_FROM
FROM $BUILD_FROM

# Local nightly build (home repo, addons/nginx_proxy_local). The ADD below is the cache key for
# the package layer: Docker re-downloads the file on every build and re-runs the layer only when
# its content changed. EXPERIMENT: a URL that changes on every request, to prove the mechanism.
ADD https://httpbin.org/uuid /tmp/cache-key
RUN apk upgrade --no-cache && apk add --no-cache nginx openssl \
    && date -u +%Y-%m-%dT%H:%M:%SZ > /etc/local-build-date && rm -f /tmp/cache-key

# Copy data
COPY rootfs /

WORKDIR /
