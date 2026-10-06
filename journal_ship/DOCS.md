# Journal shipper (Backblaze B2)

Streams the host's whole systemd journal to an off-site Backblaze B2 bucket so the history survives a reboot (HAOS keeps the journal in memory) or a compromised host (the key can only add files, and the bucket's object lock refuses deletion).

## What it ships

Everything journald has: HAOS services, the Supervisor, Home Assistant Core, and every add-on's output, which includes the remote-access proxy's access log and rejected TLS handshakes. Each entry is one JSON line with `MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER`, `_SYSTEMD_UNIT`, `CONTAINER_NAME`, `_COMM`, `_PID`, `_HOSTNAME`, `_BOOT_ID`, `__REALTIME_TIMESTAMP` and `__CURSOR`.

## How

- `journald: true` mounts the host journal read-only; `journalctl -f` reads it from the last shipped cursor, or from the start of this boot after a reboot.
- Lines accumulate in a chunk; every `interval_minutes`, or at `max_chunk_mb`, the chunk is gzipped into `/data/spool` and uploaded as `<prefix><YYYY-MM-DD>/<HHMMSS>Z_<HHMMSS>Z_<boot id>.jsonl.gz` (UTC).
- The cursor file is advanced only after B2 acknowledges the upload. A crash re-sends at most one chunk.
- On stop (SIGTERM, which the Supervisor sends before a host reboot) the open chunk is flushed and uploaded; `timeout: 90` in the add-on config gives it time.
- Failed uploads stay in the spool and are retried in order; after three consecutive failures a persistent notification appears, and if the spool passes `spool_cap_mb` the oldest chunks are dropped with another notification.

## Options

| Option | Meaning |
|---|---|
| `bucket` | B2 bucket name. Should have object lock with a default compliance retention. |
| `key_id`, `key` | A B2 application key restricted to that bucket and to `prefix`, with the `writeFiles` capability only. |
| `prefix` | File name prefix, default `journal/`. Must match the key's prefix restriction. |
| `interval_minutes` | How often a chunk is closed and uploaded. Default 10. |
| `max_chunk_mb` | Close a chunk early at this uncompressed size. Default 8. |
| `spool_cap_mb` | Upper bound on chunks kept locally while B2 is unreachable. Default 512. |

The key never appears in the published add-on source; it lives in this add-on's options on the host. Reading the archive back needs a separate read key, kept on the admin workstation, with `tools/journal_fetch.py` in the home repo.
