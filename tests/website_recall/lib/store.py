"""Replay store for the website-recall harness.

One store per venue: <root>/<venue_id>/ with
  entries/<sha1>.json   {"url","final_url","status","ctype","kind","fetched_at","body"}
  bodies/<sha1>.gz      gzipped response body
kind is the client that fetched it: "curl" (curl UA), "req" (python requests, Chrome UA),
"chrome" (headless Chrome, rendered DOM after scripts ran).

Network policy comes from UW_NET: replay (default, never touches the network),
record (serve what is stored, fetch + store what is missing), live (always refetch).
Every lookup is appended to UW_TRACE (jsonl) so the scorer can tell which pages each
path actually visited.
"""
import gzip
import hashlib
import json
import os
import time
from urllib.parse import urlsplit, urlunsplit

RAW_KINDS = ("curl", "req")


def norm_url(url):
    try:
        p = urlsplit(url.strip())
    except Exception:
        return url.strip()
    path = p.path or "/"
    if len(path) > 1:
        path = path.rstrip("/") or "/"
    return urlunsplit((p.scheme.lower(), p.netloc.lower(), path, p.query, ""))


def variants(url):
    """Exact first, then scheme / www / trailing-slash-insensitive variants."""
    n = norm_url(url)
    p = urlsplit(n)
    host = p.netloc
    bare = host[4:] if host.startswith("www.") else host
    out = [n]
    for scheme in ("https", "http"):
        for h in (host, bare, "www." + bare):
            v = urlunsplit((scheme, h, p.path, p.query, ""))
            if v not in out:
                out.append(v)
    return out


def key(kind, url):
    return hashlib.sha1((kind + "|" + norm_url(url)).encode("utf-8", "ignore")).hexdigest()


class Store:
    def __init__(self, root=None):
        self.root = root or os.environ.get("UW_STORE", "")
        self.net = os.environ.get("UW_NET", "replay")
        self.trace = os.environ.get("UW_TRACE", "")
        if self.root:
            os.makedirs(os.path.join(self.root, "entries"), exist_ok=True)
            os.makedirs(os.path.join(self.root, "bodies"), exist_ok=True)

    def _meta_path(self, k):
        return os.path.join(self.root, "entries", k + ".json")

    def get(self, kind, url, fallback_kinds=()):
        """-> (meta, body_bytes, approx) or (None, None, False)."""
        for i, u in enumerate(variants(url)):
            for j, kd in enumerate((kind,) + tuple(fallback_kinds)):
                k = key(kd, u)
                mp = self._meta_path(k)
                if os.path.exists(mp):
                    try:
                        meta = json.load(open(mp))
                        body = b""
                        if meta.get("body"):
                            with gzip.open(os.path.join(self.root, meta["body"]), "rb") as f:
                                body = f.read()
                        return meta, body, bool(i or j)
                    except Exception:
                        continue
        return None, None, False

    def put(self, kind, url, final_url, status, ctype, body, extra=None):
        k = key(kind, url)
        rel = ""
        if body is not None:
            # Content-addressed: curl and requests usually get byte-identical pages.
            rel = os.path.join("bodies", hashlib.sha1(body).hexdigest() + ".gz")
            if not os.path.exists(os.path.join(self.root, rel)):
                tmp = os.path.join(self.root, rel + ".tmp%d" % os.getpid())
                with gzip.open(tmp, "wb", compresslevel=6) as f:
                    f.write(body)
                os.replace(tmp, os.path.join(self.root, rel))
        meta = {"url": url, "final_url": final_url or url, "status": int(status or 0), "ctype": ctype or "",
                "kind": kind, "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "body": rel}
        if extra:
            meta.update(extra)
        tmp = self._meta_path(k) + ".tmp%d" % os.getpid()
        json.dump(meta, open(tmp, "w"))
        os.replace(tmp, self._meta_path(k))
        return meta

    def log(self, **rec):
        if not self.trace:
            return
        rec.setdefault("t", round(time.time(), 3))
        with open(self.trace, "a") as f:
            f.write(json.dumps(rec) + "\n")


def polite_wait(url, min_gap=None):
    """At most ~1 request/second per host across all harness processes (record/live only)."""
    gap = float(os.environ.get("UW_MIN_GAP", "1.0")) if min_gap is None else min_gap
    d = os.environ.get("UW_HOSTLOCK_DIR", "/tmp/uw_hostlock")
    os.makedirs(d, exist_ok=True)
    host = urlsplit(url).netloc.lower().replace("www.", "") or "x"
    p = os.path.join(d, host)
    try:
        last = float(open(p).read().strip() or 0)
    except Exception:
        last = 0.0
    wait = last + gap - time.time()
    if wait > 0:
        time.sleep(wait)
    try:
        open(p, "w").write(str(time.time()))
    except Exception:
        pass
