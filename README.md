# Local add-ons

Add-ons the Supervisor builds on the Yellow itself, from these sources. This directory is the source of truth; `tools/sync_addons.py` pushes it as a git subtree to the public repository github.com/nicwl/home-addons, which the Supervisor has as an add-on repository and clones itself. Nothing here is secret: these are derived from the official add-ons. `repository.yaml` is what makes the Supervisor accept it.

| Directory | Purpose |
|---|---|
| `nginx_proxy_local/` | The official NGINX proxy add-on, rebuilt nightly here so Alpine's security fixes land within a day. See `LOCAL.md` inside for the exact differences. |
| `nginx_proxy_local_b/` | Generated copy of the above (slug and name substituted) by `tools/sync_addons.py`: the second member of the blue/green pair. Never edit it. |
| `proxy_rebuild/` | Nightly maintenance job: Alpine end-of-life warning, upstream change check, index-keyed rebuild of the idle pair member, verified swap, fail-closed on error. Started at 02:10 by the `Nightly proxy rebuild` automation. |

The pristine copy of the official NGINX proxy add-on, for diffing, lives outside this directory at `upstream-addons/nginx_proxy/` (commit in `.upstream-commit`), so the Supervisor never sees it.
