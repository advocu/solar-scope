#!/usr/bin/env python3
"""Solar Scope ephemeris cache refresher (python3 stdlib only, the only Python piece the plugin runs).

usage: update_cache.py [--live [--force] | --extras] [--cache-dir DIR] [--bodies FILE] [--catalog FILE] [--years Y] [--ids a,b,...]
Full mode (default, weekly): +-Y years daily -> <dir>/<id>.json (+ status.json)
Live mode (every ~30 min):    now-1h..now+2h at 30 min -> <dir>/live.json (+ status.json)
Extras mode (weekly):         table-only bodies from catalog.json, now-8d..now+364d at 4 d -> <dir>/extras.json
                              (never writes status.json: the header describes the planets only)
Each body is fetched independently (2 tries). A body that still fails keeps its previous data and is
listed in status.json staleBodies. Prints exactly one short, sanitized status line:
  "OK <n> bodies <start>..<stop> <dir>"                     full, all bodies       exit 0
  "OK <k>/<n> bodies, <m> cached <start>..<stop> <dir>"     full, some failed      exit 0
  "OK live <n> bodies <fetchedAt> <dir>/live.json"          live, all bodies       exit 0
  "OK live <k>/<n> bodies, <m> cached <fetchedAt> <path>"   live, some failed      exit 0
  "OK skipped live.json age <m>m < 25m"                     live, fresh            exit 0
  "OK extras <n> bodies <fetchedAt> <path>"                 extras, all bodies     exit 0
  "OK extras <k>/<n> bodies, <m> cached <fetchedAt> <path>" extras, some failed    exit 0
  "ERROR horizons unavailable|horizons timeout|interrupted|bodies.json unreadable|catalog.json unreadable|update failed"  exit 1
Run-level deadline (--deadline / SOLAR_SCOPE_DEADLINE, default 45 s; --extras default 150 s); per request min(15 s, remaining).
A timeout or connection failure means the server is down: no retries, remaining bodies kept stale.
status.json is always written, also on deadline, SIGTERM and SIGINT. No .tmp files are left behind.
Full error details go only to <dir>/update.log (rotated to update.log.1 at ~200 KB).
"""
import argparse, datetime as dt, json, math, os, random, signal, socket, sys, time, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.environ.get("SOLAR_SCOPE_HORIZONS_API", "https://ssd.jpl.nasa.gov/api/horizons.api")
RETRIES = max(1, int(os.environ.get("SOLAR_SCOPE_RETRIES", "2")))  # attempts per body
LOG_MAX_BYTES = 200 * 1024
MIN_INTERVAL_S = 1.5
JITTER_S = float(os.environ.get("SOLAR_SCOPE_JITTER_S", "0.5"))
BACKOFF_S = float(os.environ.get("SOLAR_SCOPE_BACKOFF_S", "5"))
REQUEST_TIMEOUT_S = 15.0
DEFAULT_DEADLINE_S = float(os.environ.get("SOLAR_SCOPE_DEADLINE", "45"))
EXTRAS_DEADLINE_S = float(os.environ.get("SOLAR_SCOPE_DEADLINE", "150"))
EXTRAS_BEFORE_D, EXTRAS_AFTER_D, EXTRAS_STEP_D = 8, 364, 4
LIVE_MIN_AGE_S = 25 * 60
LIVE_STEP_MIN, LIVE_BEFORE_H, LIVE_AFTER_H = 30, 1, 2

def default_cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "solar-scope", "ephemeris")

class HorizonsError(Exception):
    """Horizons answered, but without usable vectors (error field, error text, no $$SOE)."""

class ServerDown(Exception):
    """Timeout or connection-level failure: treat Horizons as down for the rest of the run."""
    def __init__(self, reason, detail=""): super().__init__(detail or reason); self.reason = reason

class Interrupted(BaseException):
    """SIGTERM/SIGINT or the hard deadline alarm; BaseException so per-body handlers don't eat it."""
    def __init__(self, reason): super().__init__(reason); self.reason = reason

_deadline = [None]  # time.monotonic() value
def _remaining():
    return float("inf") if _deadline[0] is None else _deadline[0] - time.monotonic()

_last = [0.0]
_logdir = [None]

def _log(msg):
    """Append to <cache>/update.log; rotate to update.log.1 past LOG_MAX_BYTES. Never raises."""
    d = _logdir[0]
    if not d: return
    try:
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "update.log")
        if os.path.exists(p) and os.path.getsize(p) > LOG_MAX_BYTES: os.replace(p, p + ".1")
        with open(p, "a") as f: f.write(f"{_iso(_utcnow())} {msg}\n")
    except Exception:
        pass

def _query(params):
    q = {"format": "json", "EPHEM_TYPE": "VECTORS", "CENTER": "'500@10'", "REF_PLANE": "ECLIPTIC",
         "REF_SYSTEM": "ICRF", "OUT_UNITS": "AU-D", "VEC_TABLE": "2", "CSV_FORMAT": "YES",
         "VEC_LABELS": "NO", "OBJ_DATA": "NO", "MAKE_EPHEM": "YES"}
    q.update(params)
    wait = MIN_INTERVAL_S - (time.time() - _last[0]) + random.uniform(0, JITTER_S)
    if wait > 0:
        if wait >= _remaining() - 0.5: raise ServerDown("horizons timeout", "deadline reached")
        time.sleep(wait)
    _last[0] = time.time()
    timeout = min(REQUEST_TIMEOUT_S, _remaining())
    if timeout < 0.5: raise ServerDown("horizons timeout", "deadline reached")
    req = urllib.request.Request(API + "?" + urllib.parse.urlencode(q), headers={"User-Agent": "solar-scope-ephem/0.3"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as ex:  # server answered (e.g. 503): an error body, retryable
        raise HorizonsError(f"HTTP {ex.code}: " + ex.read().decode("utf-8", "replace")[:2000])
    except (socket.timeout, TimeoutError) as ex:
        raise ServerDown("horizons timeout", f"{type(ex).__name__}: {ex} (timeout {timeout:.1f}s)")
    except urllib.error.URLError as ex:
        r_ = ex.reason
        raise ServerDown("horizons timeout" if isinstance(r_, (socket.timeout, TimeoutError)) else "horizons unavailable",
                         f"URLError: {r_}")
    except (ConnectionError, OSError) as ex:  # reset / refused / dropped mid-body
        raise ServerDown("horizons unavailable", f"{type(ex).__name__}: {ex}")
    try:
        d = json.loads(raw)
    except ValueError:
        raise HorizonsError("non-JSON response: " + raw[:2000])
    if d.get("error"): raise HorizonsError("error field: " + str(d["error"]))
    if not isinstance(d.get("result"), str): raise HorizonsError("no result field")
    return d["result"]

def parse(result):
    """Vectors between $$SOE/$$EOE. Anything else (wldini/LTKERNL/VLRDC errors, notices) is a failure."""
    if "$$SOE" not in result or "$$EOE" not in result:
        raise HorizonsError("no $$SOE data: " + " ".join(result.split())[:2000])
    rows = []
    try:
        for line in result.split("$$SOE")[1].split("$$EOE")[0].strip().splitlines():
            f = [x.strip() for x in line.split(",")]
            rows.append([float(f[0])] + [float(x) for x in f[2:8]])
    except (ValueError, IndexError):
        raise HorizonsError("unparseable vectors: " + " ".join(result.split())[:2000])
    if len(rows) < 2: raise HorizonsError("Horizons returned <2 rows")
    return rows

def _fetch(params, label=""):
    """request + parse. Error bodies: RETRIES attempts with jittered backoff, within the deadline.
    ServerDown (timeout/connection): raised at once, no retry. Every failure is logged in full."""
    for k in range(RETRIES):
        try:
            return parse(_query(params))
        except ServerDown as ex:
            _log(f"{label} attempt {k + 1}/{RETRIES} failed, server down: {ex.reason}: {ex}")
            raise
        except Exception as ex:
            _log(f"{label} attempt {k + 1}/{RETRIES} failed: {type(ex).__name__}: {ex}")
            if k == RETRIES - 1: raise
            pause = BACKOFF_S * (k + 1) + random.uniform(0, BACKOFF_S)
            if pause >= _remaining() - 1: raise
            time.sleep(pause)

def fetch_range(hid, start, stop, step="1d", label=""):
    return _fetch({"COMMAND": f"'{hid}'", "START_TIME": f"'{start}'", "STOP_TIME": f"'{stop}'", "STEP_SIZE": f"'{step}'"}, label or hid)

def fetch_times(hid, jds, label=""):
    return _fetch({"COMMAND": f"'{hid}'", "TLIST_TYPE": "JD", "TIME_TYPE": "TDB",
                   "TLIST": " ".join(f"'{j:.6f}'" for j in jds)}, label or hid)

class BodiesError(Exception): pass

def _load_bodies(path, ids):
    try:
        with open(path) as f: bodies = json.load(f)["bodies"]
    except Exception as ex:
        raise BodiesError(f"{path}: {type(ex).__name__}: {ex}")
    sel = [b for b in bodies if b["id"] != "sun" and b.get("horizons_id") and (not ids or b["id"] in ids)]
    if not sel: raise BodiesError("no bodies to fetch")
    return sel

class AllFailed(Exception):
    def __init__(self, ids, reason="horizons unavailable"): super().__init__(ids); self.reason = reason

def run(cache_dir, bodies_path, years, ids):
    """Full mode. Per-body: good bodies are written atomically, failed ones keep their old file.
    Returns (ok_ids, failed_ids, start, stop, fetched_at). Raises AllFailed if nothing succeeded."""
    bodies = _load_bodies(bodies_path, ids)
    today = dt.date.today()
    s, e = today - dt.timedelta(days=int(365.25 * years)), today + dt.timedelta(days=int(365.25 * years))
    ok, failed, reason = [], [], "horizons unavailable"
    for i, b in enumerate(bodies):
        st = b.get("cache_step", "1d")
        try:
            rows = fetch_range(b["horizons_id"], s.isoformat(), e.isoformat(), st, label=b["id"])
        except (ServerDown, Interrupted) as ex:  # stop: this and every remaining body keep old files
            reason = ex.reason; failed += [x["id"] for x in bodies[i:]]
            _log(f"stopping after {b['id']}: {reason}; kept {len(bodies) - i} bodies stale"); break
        except Exception:
            failed.append(b["id"]); continue
        os.makedirs(cache_dir, exist_ok=True)
        _atomic_json(os.path.join(cache_dir, f"{b['id']}.json"), {"body": b["id"], "horizons_id": b["horizons_id"],
            "frame": "heliocentric ecliptic J2000", "units": "AU, AU/day", "time": "JD TDB", "step": st,
            "fetched_utc": _iso(_utcnow()), "columns": ["jd_tdb", "x", "y", "z", "vx", "vy", "vz"], "rows": rows})
        ok.append(b["id"])
    if not ok: raise AllFailed(",".join(failed), reason)
    return ok, failed, s, e, _utcnow()

def _utcnow(): return dt.datetime.now(dt.timezone.utc)
def _iso(t): return t.isoformat(timespec="seconds").replace("+00:00", "Z")
def _jd_tdb(t): return 2440587.5 + (t.timestamp() + 69.184) / 86400.0

def _atomic_json(path, obj):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f: json.dump(obj, f); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.remove(tmp)

def _read_json(path):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return None

def run_live(cache_dir, bodies_path, ids, force):
    """Returns status line. Raises on failure (live.json untouched)."""
    live_path = os.path.join(cache_dir, "live.json")
    now = _utcnow()
    old = _read_json(live_path)
    if old and not force:
        try:
            age = (now - dt.datetime.fromisoformat(old["fetched_utc"].replace("Z", "+00:00"))).total_seconds()
        except Exception: age = None
        if age is not None and 0 <= age < LIVE_MIN_AGE_S:
            return f"OK skipped live.json age {int(age // 60)}m < 25m", None, None
    bodies = _load_bodies(bodies_path, ids)
    jd0 = _jd_tdb(now)
    steps = int((LIVE_BEFORE_H + LIVE_AFTER_H) * 60 / LIVE_STEP_MIN)
    jds = [jd0 - LIVE_BEFORE_H / 24 + k * LIVE_STEP_MIN / 1440 for k in range(steps + 1)]
    old_bodies = (old or {}).get("bodies") or {}
    out, ok, failed, reason = {}, [], [], "horizons unavailable"
    def keep_old(x):
        failed.append(x["id"])
        if isinstance(old_bodies.get(x["id"]), dict): out[x["id"]] = old_bodies[x["id"]]  # keep last good values
    for i, b in enumerate(bodies):
        try:
            rows = fetch_times(b["horizons_id"], jds, label=b["id"])
        except (ServerDown, Interrupted) as ex:  # stop: this and every remaining body keep old values
            reason = ex.reason
            _log(f"stopping at {b['id']}: {reason}; kept {len(bodies) - i} bodies stale")
            for x in bodies[i:]: keep_old(x)
            break
        except Exception:
            keep_old(b); continue
        out[b["id"]] = {"horizons_id": b["horizons_id"], "rows": rows, "fetched_utc": _iso(_utcnow())}
        ok.append(b["id"])
    if not ok: raise AllFailed(",".join(failed), reason)  # live.json untouched
    fetched = _utcnow()
    os.makedirs(cache_dir, exist_ok=True)
    _atomic_json(live_path, {"kind": "live", "fetched_utc": _iso(fetched), "fetchedAt": _iso(fetched), "frame": "heliocentric ecliptic J2000",
        "units": "AU, AU/day", "time": "JD TDB", "step_min": LIVE_STEP_MIN, "jd_start": jds[0], "jd_stop": jds[-1],
        "staleBodies": failed, "columns": ["jd_tdb", "x", "y", "z", "vx", "vy", "vz"], "bodies": out})
    return f"OK live {_counts(ok, failed)} {_iso(fetched)} {live_path}", fetched, failed

def run_extras(cache_dir, catalog_path, ids):
    """Extras mode: table-only bodies (catalog.json). Per body: a failure keeps its previous rows. Returns the status
    line; raises AllFailed (extras.json untouched) when nothing succeeded."""
    path = os.path.join(cache_dir, "extras.json")
    bodies = _load_bodies(catalog_path, ids)
    now = _utcnow(); today = now.date()
    s, e = today - dt.timedelta(days=EXTRAS_BEFORE_D), today + dt.timedelta(days=EXTRAS_AFTER_D)
    old_bodies = (_read_json(path) or {}).get("bodies") or {}
    out, ok, failed, reason = {}, [], [], "horizons unavailable"
    def keep_old(x):
        failed.append(x["id"])
        if isinstance(old_bodies.get(x["id"]), dict): out[x["id"]] = old_bodies[x["id"]]
    for i, b in enumerate(bodies):
        start, stop = s.isoformat(), e.isoformat()
        span = b.get("span")
        if span:  # clamp to the trajectory's valid span (e.g. the Roadster: 2018-02-07 03:00 .. 2090-01-01)
            start, stop = max(start, span[0]), min(stop, span[1])
            if start >= stop: keep_old(b); continue
        try:
            rows = fetch_range(b["horizons_id"], start, stop, f"{EXTRAS_STEP_D}d", label=b["id"])
        except (ServerDown, Interrupted) as ex:  # stop: this and every remaining body keep old rows
            reason = ex.reason
            _log(f"extras: stopping at {b['id']}: {reason}; kept {len(bodies) - i} bodies stale")
            for x in bodies[i:]: keep_old(x)
            break
        except Exception:
            keep_old(b); continue
        out[b["id"]] = {"horizons_id": b["horizons_id"], "rows": rows, "fetched_utc": _iso(_utcnow())}
        ok.append(b["id"])
    if not ok: raise AllFailed(",".join(failed), reason)
    fetched = _utcnow()
    os.makedirs(cache_dir, exist_ok=True)
    _atomic_json(path, {"kind": "extras", "fetched_utc": _iso(fetched), "fetchedAt": _iso(fetched), "frame": "heliocentric ecliptic J2000",
        "units": "AU, AU/day", "time": "JD TDB", "step_days": EXTRAS_STEP_D, "window": [s.isoformat(), e.isoformat()],
        "staleBodies": failed, "columns": ["jd_tdb", "x", "y", "z", "vx", "vy", "vz"], "bodies": out})
    return f"OK extras {_counts(ok, failed)} {_iso(fetched)} {path}"

def _counts(ok, failed):
    n = len(ok) + len(failed)
    return f"{n} bodies" if not failed else f"{len(ok)}/{n} bodies, {len(failed)} cached"

def _write_status(cache_dir, attempt, ok, err, fetched=None, stale=None):
    """status.json, atomically. ok: status ok, fetchedAt = fetch time, staleBodies = bodies not freshly fetched this run (rebuilt every run;
    all on failure). Failure: status error, short sanitized lastError, previous fetchedAt kept. Never raises."""
    try:
        os.makedirs(cache_dir, exist_ok=True)
        p = os.path.join(cache_dir, "status.json")
        st = _read_json(p) or {}
        st.update({"last_attempt_utc": _iso(attempt), "last_error": None if ok else err})
        if ok: st["last_success_utc"] = _iso(fetched or _utcnow())
        st["staleBodies"] = list(stale or [])  # rebuilt every run: bodies not freshly fetched this run
        st.setdefault("last_success_utc", None)
        st.update({"fetchedAt": st["last_success_utc"], "status": "ok" if ok else "error",
                   "lastError": None if ok else err})
        _atomic_json(p, st)
    except Exception:
        pass

def _all_ids(bodies_path, ids):
    try: return [b["id"] for b in _load_bodies(bodies_path, ids)]
    except Exception: return []

def _sanitize(ex):
    if isinstance(ex, BodiesError): return "bodies.json unreadable"
    if isinstance(ex, AllFailed): return ex.reason
    if isinstance(ex, Interrupted): return ex.reason
    if isinstance(ex, KeyboardInterrupt): return "interrupted"
    return "update failed"

def _quiet_signals():
    """While writing the final status: no further signal may interrupt it."""
    signal.alarm(0)
    for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGALRM): signal.signal(sg, signal.SIG_IGN)

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache-dir", default=default_cache_dir())
    ap.add_argument("--bodies", default=os.path.join(HERE, "bodies.json"))
    ap.add_argument("--years", type=float, default=1.0)
    ap.add_argument("--ids", default="")
    ap.add_argument("--live", action="store_true", help="fetch the 3 h live window into live.json")
    ap.add_argument("--force", action="store_true", help="with --live: ignore the 25-minute freshness check")
    ap.add_argument("--extras", action="store_true", help="fetch the table-only bodies of catalog.json into extras.json")
    ap.add_argument("--catalog", default=os.path.join(HERE, "catalog.json"))
    ap.add_argument("--deadline", type=float, default=None, help="whole-run limit in seconds (default 45; --extras 150)")
    a = ap.parse_args(argv)
    if a.deadline is None: a.deadline = EXTRAS_DEADLINE_S if a.extras else DEFAULT_DEADLINE_S
    _logdir[0] = a.cache_dir
    _deadline[0] = time.monotonic() + max(1.0, a.deadline)
    def _on_signal(signum, _frame):
        for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGALRM): signal.signal(sg, signal.SIG_IGN)  # one shot
        raise Interrupted("horizons timeout" if signum == signal.SIGALRM else "interrupted")
    for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGALRM): signal.signal(sg, _on_signal)
    signal.alarm(int(math.ceil(max(1.0, a.deadline))) + 5)  # hard backstop (e.g. a DNS hang)
    ids = set(filter(None, a.ids.split(",")))
    attempt = _utcnow()
    if a.extras:  # own file, own line; status.json is never touched
        try:
            line = run_extras(a.cache_dir, a.catalog, ids)
        except BaseException as ex:
            _quiet_signals()
            msg = "catalog.json unreadable" if isinstance(ex, BodiesError) else _sanitize(ex)
            _log(f"extras pass failed: {msg} ({type(ex).__name__}: {ex})")
            print(f"ERROR {msg}", flush=True); return 1
        _quiet_signals(); _log(f"extras pass: {line}")
        print(line, flush=True); return 0
    try:
        if a.live:
            line, fetched, stale = run_live(a.cache_dir, a.bodies, ids, a.force)
        else:
            ok, stale, s, e, fetched = run(a.cache_dir, a.bodies, a.years, ids)
            line = f"OK {_counts(ok, stale)} {s}..{e} {a.cache_dir}"
    except BaseException as ex:  # includes KeyboardInterrupt / Interrupted
        _quiet_signals()
        msg = _sanitize(ex)
        _log(f"{'live' if a.live else 'full'} pass failed: {msg} ({type(ex).__name__}: {ex})")
        stale = str(ex.args[0]).split(",") if isinstance(ex, AllFailed) and ex.args[0] else _all_ids(a.bodies, ids)
        _write_status(a.cache_dir, attempt, False, msg, stale=stale)
        print(f"ERROR {msg}", flush=True); return 1
    _quiet_signals()
    if fetched is not None:
        _write_status(a.cache_dir, attempt, True, None, fetched, stale)
        _log(f"{'live' if a.live else 'full'} pass: {line}")
    print(line, flush=True); return 0

if __name__ == "__main__":
    sys.exit(main())
