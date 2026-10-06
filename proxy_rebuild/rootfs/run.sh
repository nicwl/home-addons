#!/usr/bin/with-contenv bashio
# Nightly maintenance for the local NGINX proxy. One-shot: do the checks, act, report, exit.
set -u
TARGET="$(bashio::config 'target')"; FALLBACK="$(bashio::config 'fallback')"
BRANCH="$(bashio::config 'alpine_branch')"; UPSTREAM="$(bashio::config 'upstream_commit')"; FORCE="$(bashio::config 'force_rebuild')"
INDEX_URL="https://dl-cdn.alpinelinux.org/alpine/${BRANCH}/main/aarch64/APKINDEX.tar.gz"

api() { # METHOD PATH [TIMEOUT] [JSON]
  curl -s -m "${3:-60}" -X "$1" -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" ${4:+-d "$4"} "http://supervisor$2"; }
notify() { api POST /core/api/services/persistent_notification/create 30 "$(jq -cn --arg i "$1" --arg t "$2" --arg m "$3" '{notification_id:$i,title:$t,message:$m}')" >/dev/null || true; }
dismiss() { api POST /core/api/services/persistent_notification/dismiss 30 "$(jq -cn --arg i "$1" '{notification_id:$i}')" >/dev/null || true; }
state() { api GET "/addons/$1/info" | jq -r '.data.state // "unknown"'; }

# 1. Alpine branch end of life: warn from 90 days out
EOL=$(curl -s -m 30 https://alpinelinux.org/releases.json | jq -r --arg b "$BRANCH" '.release_branches[] | select(.rel_branch==$b) | .eol_date // empty')
if [[ -n "$EOL" ]]; then
  DAYS=$(jq -rn --arg e "$EOL" '(($e | strptime("%Y-%m-%d") | mktime) - now) / 86400 | floor')
  bashio::log.info "Alpine ${BRANCH} reaches end of life on ${EOL} (${DAYS} days)"
  if (( DAYS < 90 )); then
    notify proxy_alpine_eol "Alpine ${BRANCH} end of life ${EOL}" "The remote-access proxy is built on Alpine ${BRANCH}, which stops getting security fixes on ${EOL} (${DAYS} days). Move addons/nginx_proxy_local to a newer base and update this add-on's alpine_branch option. See docs/remote-access.md in the home repo."
  else dismiss proxy_alpine_eol; fi
else bashio::log.warning "Could not read Alpine's release feed; EOL check skipped"; fi

# 2. Official add-on changed upstream? (the template and scripts are carried over by hand)
LATEST=$(curl -s -m 30 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/home-assistant/addons/commits?path=nginx_proxy&per_page=1" | jq -r '.[0].sha // empty')
if [[ -n "$LATEST" && "$LATEST" != "$UPSTREAM" ]]; then
  bashio::log.warning "Upstream nginx_proxy changed: ${LATEST:0:10} (ours derives from ${UPSTREAM:0:10})"
  notify proxy_upstream_changed "Official NGINX add-on changed upstream" "home-assistant/addons nginx_proxy is now at commit ${LATEST:0:10}; the local build derives from ${UPSTREAM:0:10}. Review the diff and carry it over (upstream-addons/README.md in the home repo), then update this add-on's upstream_commit option."
elif [[ -n "$LATEST" ]]; then dismiss proxy_upstream_changed; bashio::log.info "Upstream nginx_proxy unchanged (${LATEST:0:10})"
else bashio::log.warning "Could not query GitHub; upstream check skipped"; fi

# 3. Rebuild only when Alpine has published something, when forced, or when the proxy is not running
NEW=$(curl -s -m 90 "$INDEX_URL" | sha256sum | cut -d' ' -f1)
if [[ ${#NEW} -ne 64 ]]; then bashio::log.warning "Could not fetch Alpine's package index; no rebuild tonight"; exit 0; fi
OLD=$(cat /data/last-index.sha256 2>/dev/null || echo none)
TSTATE=$(state "$TARGET")
if [[ "$NEW" == "$OLD" && "$FORCE" != "true" && "$TSTATE" == "started" ]]; then
  bashio::log.info "Alpine ${BRANCH} index unchanged since the last rebuild and ${TARGET} is running; nothing to do"
  exit 0
fi
bashio::log.info "Rebuilding ${TARGET} (index changed: $([[ "$NEW" != "$OLD" ]] && echo yes || echo no), forced: ${FORCE}, state: ${TSTATE})"
START=$(date +%s)
RESP=$(api POST "/addons/${TARGET}/rebuild" 1500); RC=$(echo "${RESP}" | jq -r '.result // "no-response"' 2>/dev/null || echo no-response)
SECS=$(( $(date +%s) - START ))
if [[ "$RC" == "ok" ]]; then
  [[ "$(state "$FALLBACK")" == "started" ]] && { api POST "/addons/${FALLBACK}/stop" 120 >/dev/null; bashio::log.info "Stopped fallback ${FALLBACK}"; }
  [[ "$(state "$TARGET")" != "started" ]] && api POST "/addons/${TARGET}/start" 120 >/dev/null
  sleep 12
  if [[ "$(state "$TARGET")" == "started" ]]; then
    echo "$NEW" > /data/last-index.sha256
    LINE=$(api GET "/addons/${TARGET}/logs" 60 | grep -a 'Local build:' | tail -1 | sed -e 's/.*Local build: //' -e 's/\x1b\[[0-9;]*m//g')
    bashio::log.info "Rebuilt ${TARGET} in ${SECS}s and it is running: ${LINE:-versions not read}"
    dismiss proxy_rebuild_failed
    notify proxy_rebuilt "Proxy rebuilt with new Alpine packages" "${LINE:-versions not read}. Rebuilt in ${SECS}s. Dismiss when read."
    exit 0
  fi
  bashio::log.error "Rebuilt ${TARGET} but it is not running (state $(state "$TARGET"))"
else
  bashio::log.error "Rebuild of ${TARGET} FAILED after ${SECS}s: $(echo "${RESP}" | jq -r '.message // .' 2>/dev/null | head -c 200)"
fi
# Failure path: the Supervisor removes the old container before building, so put the official proxy in its place
if [[ "$(state "$TARGET")" != "started" ]]; then
  api POST "/addons/${FALLBACK}/start" 120 >/dev/null; sleep 8
fi
FB=$(state "$FALLBACK")
notify proxy_rebuild_failed "Proxy nightly rebuild failed" "The local NGINX proxy (${TARGET}) could not be rebuilt tonight. The official NGINX add-on (${FALLBACK}) was started in its place and is ${FB}; remote access keeps working on it. The job retries tomorrow night. See the Proxy nightly maintenance add-on log."
exit 1
