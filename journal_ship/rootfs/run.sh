#!/usr/bin/with-contenv bashio
# Journal shipper: hand everything to the Python process, which owns the journalctl child,
# the chunking, the uploads and the shutdown flush. exec so SIGTERM reaches it directly.
set -u
set +o errexit +o pipefail

if [[ -z "$(bashio::config 'bucket')" || -z "$(bashio::config 'key_id')" || -z "$(bashio::config 'key')" ]]; then
  bashio::log.error "bucket, key_id and key must be set in the add-on options; nothing shipped"
  exit 1
fi

JOURNAL=""
for d in /var/log/journal /run/log/journal; do
  if [[ -d "$d" ]] && find "$d" -name '*.journal*' -print -quit 2>/dev/null | grep -q .; then JOURNAL="$d"; break; fi
done
if [[ -z "$JOURNAL" ]]; then
  bashio::log.error "No host journal found at /var/log/journal or /run/log/journal; is 'journald: true' in config.yaml?"
  ls -la /var/log/journal /run/log/journal 2>&1 || true
  exit 1
fi

bashio::log.info "Journal shipper: image built $(cat /etc/local-build-date 2>/dev/null || echo unknown), $(journalctl --version | head -1), journal at ${JOURNAL}"
export JOURNAL_DIR="$JOURNAL"
exec python3 -u /usr/local/bin/journal_ship.py /data/options.json
