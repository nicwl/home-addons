#!/usr/bin/with-contenv bashio
# Nightly maintenance for the blue/green local NGINX proxy pair. One-shot: check, act, report, exit.
# Rule: never start a proxy that was not just built and verified; a failure leaves the active one alone.
set -u
PA="$(bashio::config 'proxy_a')"; PB="$(bashio::config 'proxy_b')"
BRANCH="$(bashio::config 'alpine_branch')"; UPSTREAM="$(bashio::config 'upstream_commit')"; FORCE="$(bashio::config 'force_rebuild')"
INDEX_URL="https://dl-cdn.alpinelinux.org/alpine/${BRANCH}/main/aarch64/APKINDEX.tar.gz"

api() { curl -s -m "${3:-60}" -X "$1" -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" ${4:+-d "$4"} "http://supervisor$2"; }
notify() { api POST /core/api/services/persistent_notification/create 30 "$(jq -cn --arg i "$1" --arg t "$2" --arg m "$3" '{notification_id:$i,title:$t,message:$m}')" >/dev/null || true; }
dismiss() { api POST /core/api/services/persistent_notification/dismiss 30 "$(jq -cn --arg i "$1" '{notification_id:$i}')" >/dev/null || true; }
info() { api GET "/addons/$1/info" 60; }
state() { info "$1" | jq -r '.data.state // "unknown"'; }
probe() { # the proxy must answer the right SNI with nginx's certificate demand: proves it is up and gating
  local ip="$1" host="$2"; curl -sk -m 15 --resolve "${host}:443:${ip}" -o /dev/null -w '%{http_code}' "https://${host}/" 2>/dev/null; }

# 1. Alpine branch end of life: warn from 90 days out
EOL=$(curl -s -m 30 https://alpinelinux.org/releases.json | jq -r --arg b "$BRANCH" '.release_branches[] | select(.rel_branch==$b) | .eol_date // empty')
if [[ -n "$EOL" ]]; then
  DAYS=$(jq -rn --arg e "$EOL" '(($e | strptime("%Y-%m-%d") | mktime) - now) / 86400 | floor')
  bashio::log.info "Alpine ${BRANCH} reaches end of life on ${EOL} (${DAYS} days)"
  if (( DAYS < 90 )); then notify proxy_alpine_eol "Alpine ${BRANCH} end of life ${EOL}" "The remote-access proxy is built on Alpine ${BRANCH}, which stops getting security fixes on ${EOL} (${DAYS} days). Move addons/nginx_proxy_local to a newer base and update this add-on's alpine_branch option. See docs/remote-access.md in the home repo."
  else dismiss proxy_alpine_eol; fi
else bashio::log.warning "Could not read Alpine's release feed; EOL check skipped"; fi

# 2. Official add-on changed upstream?
LATEST=$(curl -s -m 30 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/home-assistant/addons/commits?path=nginx_proxy&per_page=1" | jq -r '.[0].sha // empty')
if [[ -n "$LATEST" && "$LATEST" != "$UPSTREAM" ]]; then
  bashio::log.warning "Upstream nginx_proxy changed: ${LATEST:0:10} (ours derives from ${UPSTREAM:0:10})"
  notify proxy_upstream_changed "Official NGINX add-on changed upstream" "home-assistant/addons nginx_proxy is now at commit ${LATEST:0:10}; the local build derives from ${UPSTREAM:0:10}. Review the diff and carry it over (upstream-addons/README.md in the home repo), then update this add-on's upstream_commit option."
elif [[ -n "$LATEST" ]]; then dismiss proxy_upstream_changed; bashio::log.info "Upstream nginx_proxy unchanged (${LATEST:0:10})"
else bashio::log.warning "Could not query GitHub; upstream check skipped"; fi

# 3. Which member is active? Exactly one should be running. If none is, that is for a human: fail closed.
SA=$(state "$PA"); SB=$(state "$PB")
if [[ "$SA" == "started" && "$SB" != "started" ]]; then ACTIVE="$PA"; IDLE="$PB"
elif [[ "$SB" == "started" && "$SA" != "started" ]]; then ACTIVE="$PB"; IDLE="$PA"
else
  bashio::log.error "Unexpected proxy states: ${PA}=${SA}, ${PB}=${SB}. Doing nothing."
  notify proxy_rebuild_failed "Proxy pair in an unexpected state" "${PA} is ${SA} and ${PB} is ${SB}; exactly one should be running. Nothing was changed. Fix by hand (docs/remote-access.md in the home repo)."
  exit 1
fi
bashio::log.info "Active proxy: ${ACTIVE}; idle: ${IDLE}"

# 4. Rebuild the idle member only when Alpine has published something (or when forced)
NEW=$(curl -s -m 90 "$INDEX_URL" | sha256sum | cut -d' ' -f1)
if [[ ${#NEW} -ne 64 ]]; then bashio::log.warning "Could not fetch Alpine's package index; no rebuild tonight"; exit 0; fi
OLD=$(cat /data/last-index.sha256 2>/dev/null || echo none)
if [[ "$NEW" == "$OLD" && "$FORCE" != "true" ]]; then bashio::log.info "Alpine ${BRANCH} index unchanged since the last successful build; nothing to do"; exit 0; fi
bashio::log.info "Building ${IDLE} (index changed: $([[ "$NEW" != "$OLD" ]] && echo yes || echo no), forced: ${FORCE})"
# options follow the active member so the two never diverge
OPTS=$(info "$ACTIVE" | jq -c '{options: .data.options, network: .data.network}')
api POST "/addons/${IDLE}/options" 60 "$OPTS" >/dev/null
START=$(date +%s)
if [[ "$(info "$IDLE" | jq -r '.data.version // empty')" == "" ]]; then RESP=$(api POST "/addons/${IDLE}/install" 1500); else RESP=$(api POST "/addons/${IDLE}/rebuild" 1500); fi
RC=$(echo "${RESP}" | jq -r '.result // "no-response"' 2>/dev/null || echo no-response); SECS=$(( $(date +%s) - START ))
if [[ "$RC" != "ok" ]]; then
  bashio::log.error "Build of ${IDLE} FAILED after ${SECS}s: $(echo "${RESP}" | jq -r '.message // .' 2>/dev/null | head -c 200). ${ACTIVE} keeps serving."
  notify proxy_rebuild_failed "Proxy nightly build failed" "Building ${IDLE} failed after ${SECS}s. Nothing was swapped: ${ACTIVE}, yesterday's build, keeps serving. The job retries tomorrow night. See the Proxy nightly maintenance add-on log."
  exit 1
fi
bashio::log.info "Built ${IDLE} in ${SECS}s; swapping"

# 5. Swap: stop active, start the new build, verify it gates; otherwise swap straight back
HOST=$(echo "$OPTS" | jq -r '.options.domain')
api POST "/addons/${ACTIVE}/stop" 120 >/dev/null; sleep 3
api POST "/addons/${IDLE}/start" 120 >/dev/null
for i in $(seq 1 40); do sleep 5; IP=$(info "$IDLE" | jq -r '.data.ip_address // empty'); CODE=$(probe "$IP" "$HOST"); [[ "$CODE" == "400" ]] && break; done
if [[ "$CODE" == "400" && "$(state "$IDLE")" == "started" ]]; then
  api POST "/addons/${IDLE}/options" 60 '{"boot":"auto"}' >/dev/null; api POST "/addons/${ACTIVE}/options" 60 '{"boot":"manual"}' >/dev/null
  echo "$NEW" > /data/last-index.sha256
  LINE=$(api GET "/addons/${IDLE}/logs" 60 | grep -a 'Local build:' | tail -1 | sed -e 's/.*Local build: //' -e 's/\x1b\[[0-9;]*m//g')
  bashio::log.info "${IDLE} is serving and gating (probe ${CODE}): ${LINE:-versions not read}"
  dismiss proxy_rebuild_failed
  notify proxy_rebuilt "Proxy rebuilt with new Alpine packages" "Now serving from ${IDLE}: ${LINE:-versions not read}. Built in ${SECS}s. Dismiss when read."
  exit 0
fi
bashio::log.error "New build ${IDLE} did not come up correctly (state $(state "$IDLE"), probe '${CODE}'); swapping back to ${ACTIVE}"
api POST "/addons/${IDLE}/stop" 120 >/dev/null; sleep 3; api POST "/addons/${ACTIVE}/start" 120 >/dev/null; sleep 8
notify proxy_rebuild_failed "Proxy nightly swap failed" "The new build (${IDLE}) started but did not pass the gate probe, so ${ACTIVE} was started again and is $(state "$ACTIVE"). See the Proxy nightly maintenance add-on log."
exit 1
