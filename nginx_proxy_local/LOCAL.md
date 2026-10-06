# Local nightly build of the official NGINX proxy add-on

Copied from home-assistant/addons `nginx_proxy` at the commit in `../../upstream-addons/nginx_proxy/.upstream-commit`. Deliberate differences, and the only ones:

- `config.yaml`: slug `nginx_proxy_local`, name, description, version suffix `-local.N`, no `image:` (so the Supervisor builds it here), aarch64 only
- `Dockerfile`: `apk upgrade --no-cache` before the install, and a build-date stamp in `/etc/local-build-date`
- `rootfs/.../nginx/run`: logs the nginx and OpenSSL versions and the build date at startup
- `rootfs/etc/nginx/nginx.conf.gtpl`: `error_log stderr info` (rejected TLS handshakes are logged) and an `access_log /dev/stdout` in the `house` format: time, client address, SNI, client-certificate verification result and subject, status, method, URI with webhook ids masked, bytes, request time, user agent. Both end up in the host journal

When upstream changes, refresh `upstream-addons/nginx_proxy` from GitHub, diff it against this directory, carry the changes over, bump the version suffix, run `tools/sync_addons.py`. Rebuilt nightly by the `proxy_rebuild` add-on; see `docs/remote-access.md`.
