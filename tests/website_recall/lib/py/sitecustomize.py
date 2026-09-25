"""Auto-imported by python (PYTHONPATH) inside the website-recall harness.

Routes python `requests` traffic (site_discovery.py's static crawl, and anything else the
website step fetches from python) through the replay store, like lib/bin/curl does for curl.
Only active when UW_STORE is set.
"""
import os
import sys

def _install():
    try:
        import warnings
        warnings.filterwarnings("ignore", message="urllib3 v2 only supports OpenSSL")
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
        from store import Store, polite_wait  # noqa: E402
        import requests  # noqa: E402
        from requests.structures import CaseInsensitiveDict  # noqa: E402

        _orig_request = requests.Session.request
        _API_HOSTS = {"script.google.com", "script.googleusercontent.com", "apps-script.invalid"}

        def _fake(url, meta, body):
            r = requests.Response()
            r.status_code = int(meta.get("status") or 0)
            r._content = body or b""
            r.url = meta.get("final_url") or url
            r.headers = CaseInsensitiveDict({"content-type": meta.get("ctype") or "text/html"})
            r.encoding = requests.utils.get_encoding_from_headers(r.headers) or None
            if r.encoding is None and "html" in (meta.get("ctype") or "html"):
                r.encoding = "utf-8"
            r.reason = "OK" if r.status_code < 400 else "Not Found"
            return r

        def _request(self, method, url, *args, **kwargs):
            from urllib.parse import urlsplit
            host = urlsplit(url).netloc.lower()
            if host in _API_HOSTS:
                return _fake(url, {"status": 200, "ctype": "application/json"}, b'{"status":"ok"}')
            if method.upper() not in ("GET", "HEAD"):
                raise requests.ConnectionError("website-recall harness: non-GET blocked")
            st = Store()
            meta = body = None
            approx = False
            if st.net != "live":
                meta, body, approx = st.get("req", url, fallback_kinds=("curl",))
            source = "store"
            if meta is None and st.net in ("record", "live"):
                polite_wait(url)
                source = "net"
                try:
                    kwargs.setdefault("timeout", 15)
                    r = _orig_request(self, method, url, *args, **kwargs)
                    st.put("req", url, r.url, r.status_code, r.headers.get("content-type", ""), r.content)
                    st.log(via="req", url=url, found=True, status=r.status_code, source="net", approx=False)
                    return r
                except requests.RequestException:
                    st.put("req", url, url, 0, "", b"")
                    st.log(via="req", url=url, found=True, status=0, source="net", approx=False)
                    raise
            st.log(via="req", url=url, found=meta is not None, status=(meta or {}).get("status", 404),
                   source=source if meta is not None else "missing", approx=approx)
            if meta is None:
                return _fake(url, {"status": 404, "ctype": "text/html"}, b"")
            if int(meta.get("status") or 0) == 0:
                raise requests.ConnectionError("recorded as unreachable")
            return _fake(url, meta, body)

        requests.Session.request = _request
    except Exception as e:  # never break the interpreter
        sys.stderr.write("website-recall sitecustomize disabled: %s\n" % e)


if os.environ.get("UW_STORE"):
    # Patch lazily, right after the first `import requests`, so the many small
    # python3 -c calls in pipeline.sh don't all pay for importing requests.
    import builtins
    _orig_import = builtins.__import__
    _state = {"done": False}

    def _import(name, *a, **k):
        mod = _orig_import(name, *a, **k)
        if not _state["done"] and "requests.sessions" in sys.modules and "requests" in sys.modules \
                and hasattr(sys.modules["requests"], "Session"):
            _state["done"] = True
            builtins.__import__ = _orig_import
            _install()
        return mod

    builtins.__import__ = _import
