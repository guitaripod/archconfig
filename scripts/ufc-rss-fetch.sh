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
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

RSS_URL = os.environ.get("TD_RSS_URL")
TORRENT_PASS = os.environ.get("TD_TORRENT_PASS")
QB_API = "http://127.0.0.1:8090/api/v2"
SAVE_PATH = "/mnt/stuff2/Sports"
STATE_FILE = Path.home() / ".local/share/ufc-torrents/seen.json"
LOG_DIR = Path.home() / ".local/state/ufc-rss-fetch"
TARGET_MAX_AGE_HOURS = 120
GRACE_HOURS = {1: 3, 2: 3, 3: 6}
TRUSTED_GROUPS = ("FBB", "Fight-BB", "VERUM", "nVa", "BILLIE")
BANNED_GROUPS = ("MmA",)
REQUIRED_PARTS = ("", " Prelims")
STALE_EVENT_GAP = 3

if not RSS_URL or not TORRENT_PASS:
    print("error: TD_RSS_URL and TD_TORRENT_PASS must be set (see ~/.config/ufc-rss-fetch/secrets.env)", file=sys.stderr)
    sys.exit(2)

NON_FIGHT_SHOW = re.compile(
    r"\b(?:weigh[\s._-]*ins?|press[\s._-]+conferences?|embedded|countdown|face[\s._-]*offs?"
    r"|media[\s._-]+days?|open[\s._-]+workouts?|preview|post[\s._-]*fight|pre[\s._-]*fight"
    r"|pre[\s._-]*show|post[\s._-]*show)\b",
    re.IGNORECASE,
)
ALTERNATE_FEED = re.compile(r"\bUFP\b", re.IGNORECASE)
FIGHT_PASS_SHOW = re.compile(r"\bUFC[\s._-]+Fight[\s._-]+Pass\b", re.IGNORECASE)
UFC_BJJ = re.compile(r"\bUFC[\s._-]+BJJ\b", re.IGNORECASE)
NUMBERED_EVENT = re.compile(r"\bUFC[\s._-]+(?:(Fight[\s._-]+Night|PPV)[\s._-]*)?(\d+)\b", re.IGNORECASE)
EARLY_PRELIMS = re.compile(r"\bearly[\s._-]+prelim(?:s|inary|inaries)?\b", re.IGNORECASE)
PRELIMS = re.compile(r"\bprelim(?:s|inary|inaries)?\b", re.IGNORECASE)
RESOLUTION = re.compile(r"\b(?:480|576|720|1080|2160)[pi]\b", re.IGNORECASE)
PART_WORDS = re.compile(r"\b(?:early[\s._-]+)?prelim\w*\b|\bmain[\s._-]+card\b", re.IGNORECASE)


@dataclass
class Release:
    title: str
    link: str
    published: datetime | None

    @property
    def age_hours(self):
        if self.published is None:
            return float("inf")
        return (datetime.now(timezone.utc) - self.published).total_seconds() / 3600


@dataclass
class Outcome:
    added: int = 0
    targets: set = field(default_factory=set)
    missing: dict = field(default_factory=dict)


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
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(sorted(seen), indent=1))
    tmp.replace(STATE_FILE)


def is_ufc(title):
    return bool(re.search(r"\bUFC\b", title, re.IGNORECASE))


def is_non_fight_show(title):
    """Weigh-ins, press conferences and other shoulder content share the event number and would otherwise take the fight card's slot."""
    return bool(NON_FIGHT_SHOW.search(title))


def is_fight_card(title):
    """A UFC fight card release: not shoulder content, not Star's duplicate UFP feed, not UFC BJJ, and not another promotion streamed on UFC Fight Pass."""
    if not is_ufc(FIGHT_PASS_SHOW.sub(" ", title)):
        return False
    return not (is_non_fight_show(title) or ALTERNATE_FEED.search(title) or UFC_BJJ.search(title))


def event_base(title):
    m = NUMBERED_EVENT.search(title)
    if m:
        series = "UFC Fight Night" if m.group(1) and m.group(1)[0] in "fF" else "UFC"
        return f"{series} {m.group(2)}"
    head = RESOLUTION.split(title)[0]
    return re.sub(r"[\s._-]+", " ", PART_WORDS.sub(" ", head)).strip()


def event_key(title):
    base = event_base(title)
    if EARLY_PRELIMS.search(title):
        return f"{base} Early Prelims"
    if PRELIMS.search(title):
        return f"{base} Prelims"
    return base


def _has_group(title, groups):
    """Release groups are matched case-sensitively after the resolution, so "MmA" never catches "MMA" in a promotion's name."""
    tail = re.split(r"1080p", title, flags=re.IGNORECASE)[-1]
    return any(re.search(rf"(?<![A-Za-z0-9]){re.escape(group)}(?![A-Za-z0-9])", tail) for group in groups)


def is_banned(title):
    """Groups whose UFC encodes are cropped or zoomed to dodge copyright matching."""
    return _has_group(title, BANNED_GROUPS)


def release_rank(title):
    """0: a WEB-DL or WEB encode from a group whose UFC releases are known clean; 1: another group's WEB-DL or WEB; 2: WEBRip; 3: an HDTV satellite-feed capture."""
    if re.search(r"\bweb[\s._-]?rip\b", title, re.IGNORECASE):
        return 2
    if re.search(r"\bweb(?:[\s._-]?dl)?\b", title, re.IGNORECASE):
        return 0 if _has_group(title, TRUSTED_GROUPS) else 1
    return 3


def is_1080p(title):
    return bool(re.search(r"\b1080p\b", title, re.IGNORECASE))


def missing_parts(base, seen, pool):
    """Main card and prelims are always expected; early prelims only once a 1080p release of them exists."""
    released = {event_key(r.title) for r in pool if is_1080p(r.title)}
    wanted = [f"{base}{suffix}" for suffix in REQUIRED_PARTS]
    if f"{base} Early Prelims" in released:
        wanted.append(f"{base} Early Prelims")
    return [key for key in wanted if key not in seen]


def choose_releases(candidates, final):
    """Best 1080p release per event part; anything short of a trusted group's WEB-DL waits GRACE_HOURS for one unless this is the last attempt."""
    by_key = {}
    for release in candidates:
        if is_banned(release.title):
            log_debug(f"  skip-banned-group: {release.title}")
        elif is_1080p(release.title):
            by_key.setdefault(event_key(release.title), []).append(release)
    picks = []
    for key, releases in by_key.items():
        best = min(releases, key=lambda r: (release_rank(r.title), r.age_hours))
        rank = release_rank(best.title)
        if rank > 0 and best.age_hours < GRACE_HOURS[rank] and not final:
            log_debug(f"  defer ({key}, rank {rank}, {best.age_hours:.1f}h old, waiting for a trusted WEB-DL): {best.title}")
            continue
        picks.append(best)
    return picks


def torrent_download_url(page_url):
    torrent_id = page_url.rstrip("/").split("/")[-1]
    return f"https://www.torrentday.com/download.php/{torrent_id}/torrent.torrent?torrent_pass={TORRENT_PASS}"


def redact(text):
    return text.replace(TORRENT_PASS, "$TD_TORRENT_PASS")


def _published(pub):
    try:
        return parsedate_to_datetime(pub)
    except (TypeError, ValueError):
        return None


def fetch_releases(query=None):
    url = RSS_URL if query is None else f"{RSS_URL};q={urllib.parse.quote(query)}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Encoding": "gzip"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        status = resp.status
        data = resp.read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    items = list(ET.fromstring(data).iter("item"))
    log_debug(f"RSS{'' if query is None else f' q={query!r}'} http={status} bytes={len(data)} items={len(items)}")
    return [
        Release(item.findtext("title", "") or "", item.findtext("link", "") or "", _published(item.findtext("pubDate", "")))
        for item in items
    ]


def search_releases(query):
    """TorrentDay's RSS takes a ;q= search term, which reaches releases that already scrolled out of the 100-item feed."""
    try:
        return fetch_releases(query)
    except Exception as e:
        log_event(f"RSS search {query!r} failed: {redact(str(e))}", level="WARN")
        return []


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
        normalized = t.get("name", "").replace(".", " ").replace("_", " ")
        if is_fight_card(normalized):
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
    if not _qb_add_succeeded(result):
        raise RuntimeError(f"qBittorrent rejected torrent: {result}")


def _qb_add_succeeded(result):
    """qBittorrent before 5.2 answers "Ok."; 5.2 and later answer JSON with success, pending and failure counts."""
    text = result.strip()
    if text.lower() == "ok.":
        return True
    try:
        counts = json.loads(text)
    except ValueError:
        return False
    if not isinstance(counts, dict):
        return False
    accepted = counts.get("success_count", 0) + counts.get("pending_count", 0)
    return accepted > 0 and counts.get("failure_count", 0) == 0


def _numbered(base):
    m = re.fullmatch(r"(UFC Fight Night|UFC) (\d+)", base)
    return (m.group(1), int(m.group(2))) if m else None


def newest_numbers(seen):
    newest = {"UFC": 0, "UFC Fight Night": 0}
    for key in seen:
        numbered = _numbered(re.sub(r" (?:Early )?Prelims$", "", key))
        if numbered:
            newest[numbered[0]] = max(newest[numbered[0]], numbered[1])
    return newest


def next_event_queries(newest):
    """The event after the newest one in seen.json for each numbering series, so a week the machine was off is caught up."""
    return [f"{series} {number + 1}" for series, number in newest.items() if number]


def is_current(base, newest):
    """Re-uploads of events well behind the newest seen number in their series are archive content, not this week's card."""
    numbered = _numbered(base)
    return numbered is None or numbered[1] >= newest[numbered[0]] - STALE_EVENT_GAP


def _merge(pool, releases, keep=lambda r: True):
    known = {(r.title, r.link) for r in pool}
    for release in releases:
        if (release.title, release.link) not in known and is_fight_card(release.title) and keep(release):
            pool.append(release)
            known.add((release.title, release.link))


def run_once(dry_run, verbose, first=True, final=True):
    log_debug(f"run_once start (dry_run={dry_run} first={first} final={final})")
    seen = load_seen()
    log_debug(f"seen.json had {len(seen)} keys")
    seen.update(get_qb_ufc_event_keys())
    log_debug(f"effective seen set: {len(seen)} keys")

    try:
        feed = fetch_releases()
    except Exception as e:
        log_event(f"RSS fetch failed: {redact(str(e))}", level="ERROR")
        raise

    feed_ufc = [r for r in feed if is_ufc(r.title)]
    log_debug(f"feed UFC items: {len(feed_ufc)}")
    for r in feed_ufc:
        log_debug(f"  feed: [{r.published}] {r.title}{'' if is_fight_card(r.title) else '  (not a fight card)'}")

    searched = {}

    def search(query):
        if query not in searched:
            searched[query] = search_releases(query)
        return searched[query]

    newest = newest_numbers(seen)
    pool = []
    _merge(pool, feed_ufc)
    if first:
        for query in next_event_queries(newest):
            _merge(pool, search(query), lambda r, q=query: event_base(r.title) == q)
    for release in [r for r in pool if not is_current(event_base(r.title), newest)]:
        log_debug(f"  skip-archive ({event_base(release.title)}): {release.title}")
        pool.remove(release)

    targets = {event_base(r.title) for r in pool if r.age_hours <= TARGET_MAX_AGE_HOURS}
    for base in sorted(targets):
        if missing_parts(base, seen, pool):
            _merge(pool, search(base), lambda r, b=base: event_base(r.title) == b)
    log_debug(f"targets: {sorted(targets) or 'none'}; pool: {len(pool)} fight-card releases")

    candidates = []
    for release in pool:
        key = event_key(release.title)
        if key in seen:
            log_debug(f"  skip-seen ({key}): {release.title}")
            if verbose:
                print(f"SKIP (seen): {release.title}")
            continue
        candidates.append(release)
    log_debug(f"candidates after seen filter: {len(candidates)}")

    picks = choose_releases(candidates, final)
    log_debug(f"picks after 1080p+rank+dedup: {len(picks)}")

    outcome = Outcome(targets=targets)
    for release in picks:
        key = event_key(release.title)
        dl_url = torrent_download_url(release.link)
        if dry_run:
            print(f"WOULD ADD ({key}): {release.title}")
            print(f"  URL: {redact(dl_url)}")
            seen.add(key)
            outcome.added += 1
            continue
        try:
            add_to_qbittorrent(download_torrent_bytes(dl_url), release.title)
            log_event(f"ADDED ({key}): {release.title} -> {SAVE_PATH}")
            seen.add(key)
            save_seen(seen)
            outcome.added += 1
        except Exception as e:
            log_event(f"FAILED ({key}): {release.title} - {redact(str(e))}", level="ERROR")

    if not dry_run:
        save_seen(seen)

    outcome.missing = {base: parts for base in sorted(targets) if (parts := missing_parts(base, seen, pool))}
    status = "; ".join(f"{base}: {'missing ' + ', '.join(outcome.missing[base]) if base in outcome.missing else 'complete'}" for base in sorted(targets))
    log_debug(f"run_once end: added={outcome.added} {status or 'no UFC event in the last ' + str(TARGET_MAX_AGE_HOURS) + 'h'}")
    if verbose:
        print(f"Status: {status or 'no UFC event released in the last ' + str(TARGET_MAX_AGE_HOURS) + 'h'}")
    if outcome.added:
        log_event(f"{outcome.added} new UFC torrent(s) {'found' if dry_run else 'added to qBittorrent'}.")
    return outcome


def describe_missing(missing):
    """Reads as "UFC 334 main card" or "UFC 334 Prelims" instead of repeating the event key."""
    return "; ".join(
        f"{base} {', '.join(part[len(base):].strip() or 'main card' for part in parts)}" for base, parts in missing.items()
    )


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

    def attempt(first, final):
        try:
            return run_once(dry_run, verbose, first=first, final=final)
        except Exception as e:
            log_event(f"attempt failed: {redact(str(e))}", level="ERROR")
            return None

    if not retry_until or dry_run:
        return 0 if attempt(first=True, final=True) else 1

    hh, mm = map(int, retry_until.split(":"))
    deadline = datetime.now().replace(hour=hh, minute=mm, second=0, microsecond=0).timestamp()
    attempt_num = 0
    total = 0
    while True:
        attempt_num += 1
        final = time.time() + retry_interval >= deadline
        log_event(f"[attempt {attempt_num} @ {datetime.now().strftime('%H:%M:%S')}]")
        outcome = attempt(first=attempt_num == 1, final=final)
        if outcome:
            total += outcome.added
            if outcome.targets and not outcome.missing:
                log_event(f"Done. {', '.join(sorted(outcome.targets))} complete; {total} torrent(s) added across {attempt_num} attempt(s).")
                return 0
        if final:
            break
        waiting = describe_missing(outcome.missing) if outcome and outcome.missing else "the next event"
        log_event(f"Waiting for {waiting}; sleeping {retry_interval}s...")
        time.sleep(retry_interval)

    if outcome is None:
        log_event(f"Deadline {retry_until} reached and the last attempt failed.", level="ERROR")
        return 1
    if outcome.missing:
        log_event(f"Deadline {retry_until} reached with parts still missing: {describe_missing(outcome.missing)}.", level="ERROR")
        return 1
    log_event(f"Deadline {retry_until} reached; no UFC event released in the last {TARGET_MAX_AGE_HOURS}h. {total} torrent(s) added.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
