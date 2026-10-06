#!/usr/bin/env python3
"""Ship the host journal to Backblaze B2 in gzipped JSON-lines chunks.

Runs journalctl against the mounted host journal, follows it from the last shipped cursor,
and every `interval_minutes` (or `max_chunk_mb`, whichever first) closes the current chunk,
gzips it and uploads it under `prefix` with the add-on's write-only key. The cursor is only
advanced once B2 has acknowledged the upload, so a crash loses nothing that was not
re-sent. On SIGTERM (the Supervisor stopping the add-on, which precedes a host reboot) the
open chunk is flushed before exit.

A chunk that fails to upload stays in /data/spool and is retried every cycle, oldest first,
up to `spool_cap_mb`; beyond that the oldest spooled chunk is dropped and a persistent
notification says so. Standard library only.

Chunk names: <prefix><YYYY-MM-DD>/<HHMMSS>Z_<HHMMSS>Z_<boot id>.jsonl.gz, in UTC, so a listing
sorts into order and a boot change is visible in the name.
"""
from __future__ import annotations

import base64
import gzip
import hashlib
import json
import os
import select
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DATA = Path("/data")
SPOOL = DATA / "spool"
CURSOR_FILE = DATA / "cursor"
AUTH_URL = "https://api.backblazeb2.com/b2api/v4/b2_authorize_account"
SUPERVISOR = "http://supervisor"
FIELDS = "MESSAGE,PRIORITY,SYSLOG_IDENTIFIER,_SYSTEMD_UNIT,CONTAINER_NAME,_COMM,_PID,_HOSTNAME,_BOOT_ID"


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


# ------------------------------------------------------------------ Home Assistant notification

def notify(notification_id: str, title: str, message: str) -> None:
    token = os.environ.get("SUPERVISOR_TOKEN")
    if not token:
        return
    body = json.dumps({"notification_id": notification_id, "title": title, "message": message}).encode()
    req = urllib.request.Request(f"{SUPERVISOR}/core/api/services/persistent_notification/create", data=body,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:  # noqa: BLE001 - a notification failure must never stop shipping
        log(f"notification failed: {e}")


# ------------------------------------------------------------------ Backblaze B2 (native API, write-only key)

class B2:
    def __init__(self, key_id: str, key: str, bucket: str):
        self.key_id, self.key, self.bucket = key_id, key, bucket
        self.token = self.api_url = self.bucket_id = None
        self.upload_url = self.upload_token = None

    def _json(self, url: str, body: dict | None, headers: dict, data: bytes | None = None, timeout: int = 60) -> dict:
        payload = data if data is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST" if payload is not None else "GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)

    def authorize(self) -> None:
        basic = base64.b64encode(f"{self.key_id}:{self.key}".encode()).decode()
        info = self._json(AUTH_URL, None, {"Authorization": f"Basic {basic}"})
        storage = info["apiInfo"]["storageApi"]
        self.token, self.api_url = info["authorizationToken"], storage["apiUrl"]
        buckets = {b["name"]: b["id"] for b in (storage.get("allowed", {}).get("buckets") or [])}
        if self.bucket not in buckets:
            raise RuntimeError(f"key is not allowed on bucket {self.bucket!r}; it is restricted to {sorted(buckets) or 'nothing listed'}")
        self.bucket_id = buckets[self.bucket]
        self.upload_url = self.upload_token = None

    def _get_upload_url(self) -> None:
        r = self._json(f"{self.api_url}/b2api/v4/b2_get_upload_url", {"bucketId": self.bucket_id}, {"Authorization": self.token, "Content-Type": "application/json"})
        self.upload_url, self.upload_token = r["uploadUrl"], r["authorizationToken"]

    def upload(self, name: str, data: bytes) -> str:
        """Upload one file. Re-authorises on an expired token, fetches a fresh upload URL on
        the errors B2 documents for that, and raises after a few tries."""
        last: Exception | None = None
        for attempt in range(4):
            try:
                if self.token is None:
                    self.authorize()
                if self.upload_url is None:
                    self._get_upload_url()
                headers = {
                    "Authorization": self.upload_token,
                    "X-Bz-File-Name": urllib.parse.quote(name, safe="/"),
                    "Content-Type": "application/gzip",
                    "Content-Length": str(len(data)),
                    "X-Bz-Content-Sha1": hashlib.sha1(data).hexdigest(),
                    "X-Bz-Info-src_last_modified_millis": str(int(time.time() * 1000)),
                }
                r = self._json(self.upload_url, None, headers, data=data, timeout=300)
                return r.get("fileId", "?")
            except urllib.error.HTTPError as e:
                code, body = e.code, e.read().decode(errors="replace")[:200]
                last = RuntimeError(f"HTTP {code} {body}")
                if code == 401:
                    self.token = None          # expired or revoked: re-authorise
                elif code in (400, 408, 429, 500, 503):
                    self.upload_url = None     # B2: get a new upload URL and try again
                else:
                    raise last
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = e
                self.upload_url = None
            time.sleep(2 * (attempt + 1))
        raise RuntimeError(f"upload of {name} failed after retries: {last}")


# ------------------------------------------------------------------ the shipper

class Shipper:
    def __init__(self, opts: dict):
        self.b2 = B2(opts["key_id"], opts["key"], opts["bucket"])
        self.prefix = opts.get("prefix") or "journal/"
        if not self.prefix.endswith("/"):
            self.prefix += "/"
        self.interval = int(opts.get("interval_minutes", 10)) * 60
        self.max_bytes = int(opts.get("max_chunk_mb", 8)) * 1024 * 1024
        self.spool_cap = int(opts.get("spool_cap_mb", 512)) * 1024 * 1024
        self.journal_dir = os.environ.get("JOURNAL_DIR", "/var/log/journal")
        self.stop = False
        self.proc: subprocess.Popen | None = None
        self.chunk: list[bytes] = []
        self.chunk_bytes = 0
        self.chunk_start: datetime | None = None
        self.chunk_first_ts = self.chunk_last_ts = None
        self.chunk_boot = None
        self.last_cursor: str | None = None       # cursor of the last line read into the open chunk
        self.shipped_cursor: str | None = None    # cursor of the last line safely in B2
        self.failures = 0
        SPOOL.mkdir(parents=True, exist_ok=True)
        signal.signal(signal.SIGTERM, self._on_term)
        signal.signal(signal.SIGINT, self._on_term)

    def _on_term(self, *_):
        log("stop requested; flushing the open chunk")
        self.stop = True

    # ---- journalctl child
    def _start_journalctl(self) -> None:
        cmd = ["journalctl", "-D", self.journal_dir, "-o", "json", "--output-fields", FIELDS, "--no-pager", "-q", "-f"]
        cursor = None
        if CURSOR_FILE.exists():
            cursor = CURSOR_FILE.read_text().strip() or None
        if cursor and self._cursor_valid(cursor):
            cmd += ["--after-cursor", cursor]
            log(f"resuming after cursor …{cursor[-24:]}")
        else:
            cmd += ["-b"]  # this boot from its start: a new journal (volatile across reboots) or no cursor yet
            log("no usable cursor; shipping this boot from its start" + (" (stored cursor not found in this journal)" if cursor else ""))
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)

    def _cursor_valid(self, cursor: str) -> bool:
        r = subprocess.run(["journalctl", "-D", self.journal_dir, "-q", "--no-pager", "-n", "1", "-o", "cat", "--cursor", cursor],
                           capture_output=True, text=True, timeout=60)
        return r.returncode == 0 and "Failed to seek" not in r.stderr

    # ---- chunking
    def _add_line(self, line: bytes) -> None:
        try:
            entry = json.loads(line)
        except ValueError:
            return
        cursor = entry.get("__CURSOR")
        ts = entry.get("__REALTIME_TIMESTAMP")
        boot = entry.get("_BOOT_ID")
        if self.chunk_start is None:
            self.chunk_start = datetime.now(timezone.utc)
            self.chunk_first_ts = ts
            self.chunk_boot = boot
        self.chunk.append(line if line.endswith(b"\n") else line + b"\n")
        self.chunk_bytes += len(line) + 1
        self.chunk_last_ts = ts
        if cursor:
            self.last_cursor = cursor

    @staticmethod
    def _hms(us: str | None) -> str:
        try:
            return datetime.fromtimestamp(int(us) / 1e6, timezone.utc).strftime("%H%M%SZ")
        except (TypeError, ValueError):
            return "unknown"

    def _close_chunk(self) -> Path | None:
        """Gzip the open chunk into the spool and return its path."""
        if not self.chunk:
            return None
        day = datetime.fromtimestamp(int(self.chunk_first_ts) / 1e6, timezone.utc).strftime("%Y-%m-%d") if self.chunk_first_ts else datetime.now(timezone.utc).strftime("%Y-%m-%d")
        name = f"{day}/{self._hms(self.chunk_first_ts)}_{self._hms(self.chunk_last_ts)}_{(self.chunk_boot or 'noboot')[:8]}.jsonl.gz"
        path = SPOOL / name.replace("/", "__")
        tmp = path.with_suffix(".tmp")
        with gzip.open(tmp, "wb", compresslevel=6) as f:
            f.writelines(self.chunk)
        tmp.rename(path)
        # the cursor that this chunk, once uploaded, allows us to advance to
        (path.with_suffix(".cursor")).write_text(self.last_cursor or "")
        lines = len(self.chunk)
        self.chunk, self.chunk_bytes, self.chunk_start = [], 0, None
        self.chunk_first_ts = self.chunk_last_ts = self.chunk_boot = None
        log(f"chunk {name}: {lines} lines, {path.stat().st_size} bytes gzipped")
        return path

    # ---- spool and upload
    def _spooled(self) -> list[Path]:
        return sorted(p for p in SPOOL.glob("*.jsonl.gz"))

    def _enforce_cap(self) -> None:
        files = self._spooled()
        total = sum(p.stat().st_size for p in files)
        dropped = 0
        while total > self.spool_cap and files:
            victim = files.pop(0)
            total -= victim.stat().st_size
            victim.unlink(missing_ok=True); victim.with_suffix(".cursor").unlink(missing_ok=True)
            dropped += 1
        if dropped:
            log(f"spool over {self.spool_cap} bytes: dropped {dropped} oldest chunk(s); that history is lost")
            notify("journal_ship_dropped", "Journal shipper dropped chunks",
                   f"Uploads to B2 have been failing long enough that the spool passed its cap; {dropped} oldest chunk(s) were discarded. See the Journal shipper add-on log.")

    def _upload_spool(self) -> None:
        for path in self._spooled():
            name = self.prefix + path.name.replace("__", "/")
            data = path.read_bytes()
            try:
                self.b2.upload(name, data)
            except Exception as e:  # noqa: BLE001
                self.failures += 1
                log(f"upload failed ({self.failures} in a row): {e}")
                if self.failures == 3:
                    notify("journal_ship_failing", "Journal shipper cannot reach B2",
                           f"Three uploads in a row have failed; chunks are being kept in the spool and retried. Last error: {str(e)[:160]}")
                return  # keep order: do not skip past a failed chunk
            cursor = path.with_suffix(".cursor").read_text().strip()
            if cursor:
                CURSOR_FILE.write_text(cursor)
                self.shipped_cursor = cursor
            path.unlink(missing_ok=True); path.with_suffix(".cursor").unlink(missing_ok=True)
            if self.failures >= 3:
                notify("journal_ship_failing", "Journal shipper recovered", "Uploads to B2 are working again; the spool is draining.")
            self.failures = 0
            log(f"uploaded {name} ({len(data)} bytes)")

    # ---- main loop
    def run(self) -> int:
        try:
            self.b2.authorize()
            log(f"B2 ok: bucket {self.b2.bucket}, prefix {self.prefix}, every {self.interval // 60} min or {self.max_bytes >> 20} MB")
        except Exception as e:  # noqa: BLE001
            log(f"B2 authorisation failed: {e}")
            notify("journal_ship_failing", "Journal shipper cannot log in to B2", f"{str(e)[:200]}. Check the add-on options.")
            return 1
        self._upload_spool()  # anything left from a previous run goes first
        self._start_journalctl()
        assert self.proc and self.proc.stdout
        fd = self.proc.stdout.fileno()
        buf = b""
        last_flush = time.monotonic()
        while not self.stop:
            ready, _, _ = select.select([fd], [], [], 1.0)
            if ready:
                data = os.read(fd, 65536)
                if not data:
                    err = self.proc.stderr.read().decode(errors="replace")[-300:] if self.proc.stderr else ""
                    log(f"journalctl exited ({self.proc.poll()}): {err.strip()}; restarting in 10 s")
                    self._close_chunk(); self._upload_spool(); time.sleep(10); self._start_journalctl()
                    fd = self.proc.stdout.fileno(); buf = b""
                    continue
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line:
                        self._add_line(line)
            if self.chunk and (time.monotonic() - last_flush >= self.interval or self.chunk_bytes >= self.max_bytes):
                self._close_chunk(); self._enforce_cap(); self._upload_spool()
                last_flush = time.monotonic()
            elif not self.chunk:
                last_flush = time.monotonic()
        # shutdown: flush what is open, upload, stop journalctl
        if buf.strip():
            self._add_line(buf)
        self._close_chunk(); self._upload_spool()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
        left = len(self._spooled())
        log(f"stopped; {left} chunk(s) left in the spool" if left else "stopped; spool empty")
        return 0


def main() -> int:
    opts = json.loads(Path(sys.argv[1]).read_text()) if len(sys.argv) > 1 else {}
    return Shipper(opts).run()


if __name__ == "__main__":
    sys.exit(main())
