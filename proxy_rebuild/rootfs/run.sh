#!/usr/bin/with-contenv bashio
# One-shot: rebuild the target local add-on through the Supervisor, report, exit.
set -u
TARGET="$(bashio::config 'target')"
notify() {  # title, message: a persistent notification in Home Assistant
  curl -s -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" \
    -d "$(jq -cn --arg t "$1" --arg m "$2" '{notification_id:"proxy_rebuild",title:$t,message:$m}')" \
    http://supervisor/core/api/services/persistent_notification/create || true
}
bashio::log.info "Rebuilding ${TARGET} ..."
START=$(date +%s)
RESP=$(curl -s -m 1500 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "http://supervisor/addons/${TARGET}/rebuild")
RC=$(echo "${RESP}" | jq -r '.result // "no-response"')
SECS=$(( $(date +%s) - START ))
if [[ "${RC}" == "ok" ]]; then
  bashio::log.info "Rebuild of ${TARGET} finished in ${SECS}s"
  # clear any stale failure notice
  curl -s -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" \
    -d '{"notification_id":"proxy_rebuild"}' http://supervisor/core/api/services/persistent_notification/dismiss || true
  exit 0
fi
MSG="Supervisor answered: $(echo "${RESP}" | jq -r '.message // .' | head -c 300)"
bashio::log.error "Rebuild of ${TARGET} FAILED after ${SECS}s. ${MSG}"
notify "Proxy nightly rebuild failed" "The local NGINX proxy was not rebuilt tonight; the previous image keeps running. ${MSG}. See the Proxy nightly rebuild add-on log."
exit 1
