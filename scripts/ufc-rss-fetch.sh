#!/usr/bin/env python3

import gzip
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

RSS_URL = os.environ.get("TD_RSS_URL")
TORRENT_PASS = os.environ.get("TD_TORRENT_PASS")
QB_API = "http://127.0.0.1:8090/api/v2"
SAVE_PATH = "/mnt/stuff2/Sports"
STATE_FILE = Path.home() / ".local/share/ufc-torrents/seen.json"
LOG_DIR = Path.home() / ".local/state/ufc-rss-fetch"

if not RSS_URL or not TORRENT_PASS:
    print("error: TD_RSS_URL and TD_TORRENT_PASS must be set (see ~/.config/ufc-rss-fetch/secrets.env)", file=sys.stderr)
    sys.exit(2)


def _log_file_path():
    return LOG_DIR / f"run-{datetime.now().strftime('%Y-%m-%d')}.log"


def _stamp(level, msg):
    return f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{level}] {msg}"


def _append_log_file(line):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with _log_file_path().open("a") as f:
        f.write(line + "\n")


def log_event(msg, *, level="INFO"):
    line = _stamp(level, msg)
    stream = sys.stderr if level in ("ERROR", "WARN") else sys.stdout
    print(line, file=stream, flush=True)
    _append_log_file(line)


def log_debug(msg):
    _append_log_file(_stamp("DEBUG", msg))


def load_seen():
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    if STATE_FILE.exists():
        return set(json.loads(STATE_FILE.read_text()))
    return set()


def save_seen(seen):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(list(seen)))


def is_ufc(title):
    return bool(re.search(r"\bUFC\b", title, re.IGNORECASE))


def event_key(title):
    m = re.search(r"(UFC[\s._-]+(?:Fight[\s._-]+Night|PPV)?[\s._-]*\d+)", title, re.IGNORECASE)
    base = m.group(1).strip() if m else title.split("1080p")[0].strip()
    base = re.sub(r"[\s._-]+", " ", base)
    is_prelims = bool(re.search(r"\bprelims?\b", title, re.IGNORECASE))
    return f"{base} Prelims" if is_prelims else base


def pick_first_1080p(items):
    seen_events = set()
    picks = []
    for title, link in items:
        if not re.search(r"\b1080p\b", title, re.IGNORECASE):
            continue
        key = event_key(title)
        if key in seen_events:
            continue
        seen_events.add(key)
        picks.append((title, link))
    return picks


def torrent_download_url(page_url):
    torrent_id = page_url.rstrip("/").split("/")[-1]
    return f"https://www.torrentday.com/download.php/{torrent_id}/torrent.torrent?torrent_pass={TORRENT_PASS}"


def fetch_rss():
    req = urllib.request.Request(RSS_URL, headers={
        "User-Agent": "Mozilla/5.0",
        "Accept-Encoding": "gzip",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        status = resp.status
        data = resp.read()
        if data[:2] == b"\x1f\x8b":
            data = gzip.decompress(data)
        return status, data


def download_torrent_bytes(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = resp.read()
    if not data.startswith(b"d"):
        raise ValueError("Response is not a valid torrent file")
    return data


def get_qb_ufc_event_keys():
    try:
        req = urllib.request.Request(f"{QB_API}/torrents/info", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            torrents = json.loads(resp.read())
    except Exception as e:
        log_event(f"qB API unreachable; seeding from seen.json only ({e})", level="WARN")
        return set()
    keys = set()
    for t in torrents:
        name = t.get("name", "")
        normalized = name.replace(".", " ").replace("_", " ")
        if re.search(r"\bUFC\b", normalized, re.IGNORECASE):
            keys.add(event_key(normalized))
    log_debug(f"qB seed: {len(torrents)} torrents total, {len(keys)} UFC event keys")
    return keys


def add_to_qbittorrent(torrent_data, name):
    boundary = "----PythonBoundary7MA4YWxkTrZu0gW"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="savepath"\r\n\r\n'
        f"{SAVE_PATH}\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="stopped"\r\n\r\n'
        f"false\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="torrents"; filename="{name}.torrent"\r\n'
        f"Content-Type: application/x-bittorrent\r\n\r\n"
    ).encode() + torrent_data + f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        f"{QB_API}/torrents/add",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = resp.read().decode()
        if result.strip().lower() != "ok.":
            raise RuntimeError(f"qBittorrent rejected torrent: {result}")


def run_once(dry_run, verbose):
    log_debug(f"run_once start (dry_run={dry_run})")
    seen = load_seen()
    log_debug(f"seen.json had {len(seen)} keys")
    seen.update(get_qb_ufc_event_keys())
    log_debug(f"effective seen set: {len(seen)} keys")

    try:
        status, xml_data = fetch_rss()
    except Exception as e:
        log_event(f"RSS fetch failed: {e}", level="ERROR")
        raise

    root = ET.fromstring(xml_data)
    items = list(root.iter("item"))
    log_debug(f"RSS http={status} bytes={len(xml_data)} items={len(items)}")

    feed_ufc = []
    for item in items:
        title = item.findtext("title", "") or ""
        link = item.findtext("link", "") or ""
        pub = item.findtext("pubDate", "") or ""
        if is_ufc(title):
            feed_ufc.append((title, link, pub))
    log_debug(f"feed UFC items: {len(feed_ufc)}")
    for title, _, pub in feed_ufc:
        log_debug(f"  feed: [{pub}] {title}")

    candidates = []
    for title, link, _ in feed_ufc:
        key = event_key(title)
        if key in seen:
            log_debug(f"  skip-seen ({key}): {title}")
            if verbose:
                print(f"SKIP (seen): {title}")
            continue
        candidates.append((title, link))
    log_debug(f"candidates after seen filter: {len(candidates)}")

    picks = pick_first_1080p(candidates)
    log_debug(f"picks after 1080p+dedup: {len(picks)}")
    for title, _ in picks:
        log_debug(f"  pick: {title}")

    new_count = 0
    for title, link in picks:
        dl_url = torrent_download_url(link)

        if dry_run:
            print(f"WOULD ADD: {title}")
            print(f"  URL: {dl_url}")
            new_count += 1
            continue

        try:
            torrent_data = download_torrent_bytes(dl_url)
            add_to_qbittorrent(torrent_data, title)
            log_event(f"ADDED: {title} -> {SAVE_PATH}")
            seen.add(event_key(title))
            new_count += 1
        except Exception as e:
            log_event(f"FAILED: {title} - {e}", level="ERROR")

    save_seen(seen)

    if new_count == 0:
        if verbose:
            print("No new UFC torrents found.")
        log_debug("run_once end: no new torrents")
    else:
        log_event(f"{new_count} new UFC torrent(s) {'found' if dry_run else 'added to qBittorrent'}.")

    return new_count


def parse_flag_value(argv, flag):
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(flag + "="):
            return a.split("=", 1)[1]
    return None


def main():
    dry_run = "--dry-run" in sys.argv
    verbose = "--verbose" in sys.argv or "-v" in sys.argv or dry_run

    retry_until = parse_flag_value(sys.argv, "--retry-until")
    retry_interval = int(parse_flag_value(sys.argv, "--retry-interval") or 1200)

    log_debug(f"invoked argv={sys.argv[1:]} dry_run={dry_run} retry_until={retry_until} retry_interval={retry_interval}")
    log_debug(f"log file: {_log_file_path()}")

    def attempt():
        try:
            return run_once(dry_run, verbose)
        except Exception as e:
            log_event(f"attempt failed: {e}", level="ERROR")
            return 0

    if retry_until and not dry_run:
        hh, mm = map(int, retry_until.split(":"))
        now = datetime.now()
        deadline = now.replace(hour=hh, minute=mm, second=0, microsecond=0).timestamp()
        attempt_num = 0
        total = 0
        while True:
            attempt_num += 1
            log_event(f"[attempt {attempt_num} @ {datetime.now().strftime('%H:%M:%S')}]")
            total += attempt()
            if time.time() + retry_interval >= deadline:
                break
            msg = "Checking for more" if total > 0 else "No event yet"
            log_event(f"{msg}; sleeping {retry_interval}s...")
            time.sleep(retry_interval)
        if total > 0:
            log_event(f"Done. {total} torrent(s) added across {attempt_num} attempts.")
            return 0
        log_event(f"Deadline {retry_until} reached without finding any events.", level="ERROR")
        return 1

    return 0 if (attempt() > 0 or dry_run) else 1


if __name__ == "__main__":
    sys.exit(main())
