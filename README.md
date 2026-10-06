# Local add-ons

Add-ons the Supervisor builds on the Yellow itself, from these sources. This directory is the source of truth; `tools/sync_addons.py` pushes it as a git subtree to the public repository github.com/nicwl/home-addons, which the Supervisor has as an add-on repository and clones itself. Nothing here is secret: these are derived from the official add-ons. `repository.yaml` is what makes the Supervisor accept it.

| Directory | Purpose |
|---|---|
| `nginx_proxy_local/` | The official NGINX proxy add-on, rebuilt nightly here so Alpine's security fixes land within a day. See `LOCAL.md` inside for the exact differences. |
| `proxy_rebuild/` | One-shot helper that asks the Supervisor to rebuild the proxy, then exits. Started nightly by the `Nightly proxy rebuild` automation. |

The pristine copy of the official NGINX proxy add-on, for diffing, lives outside this directory at `upstream-addons/nginx_proxy/` (commit in `.upstream-commit`), so the Supervisor never sees it.
