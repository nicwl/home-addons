ARG BUILD_FROM
FROM $BUILD_FROM

# Local nightly build (home repo, addons/nginx_proxy_local): identical to the official add-on
# except that every package in the image is upgraded to Alpine's current fixed versions at
# build time, not just nginx and openssl, so the image is only ever a day behind Alpine.
RUN apk upgrade --no-cache && apk add --no-cache nginx openssl

# Copy data
COPY rootfs /
RUN date -u +%Y-%m-%dT%H:%MZ > /etc/local-build-date

WORKDIR /
