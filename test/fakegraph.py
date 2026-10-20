#!/usr/bin/env python3
"""A stand-in for Microsoft's sign-in and the Graph OneDrive API, so
onedrive.py and odfs.py can be tested without a tenant: a folder on disk
is the drive. Strict where the real service is strict (an upload fragment
not a multiple of 320 KiB, an Authorization header on an upload URL,
overlapping fragments, case-insensitive names) and able to misbehave on
request (POST /_fault): throttling, a fragment whose answer is lost,
download links running out, search results without a path, the device
code declined.

    fakegraph.py --root DIR [--port N]     prints the base URL, serves until killed
    import fakegraph; srv = fakegraph.start(DIR)   (srv.url, srv.state, srv.stop())
"""
import argparse
import json
import os
import re
import shutil
import sys
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLIENT = "00000000-0000-4000-8000-00000000c11e"   # an app ID is a GUID (onedrive.config checks)
FRAG = 320 * 1024
USER = {"displayName": "Bench Tester", "userPrincipalName": "tester@example.com", "id": "u1"}


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


class State:
    def __init__(self, root, quota=50 * 1024 ** 3):
        self.root, self.quota = os.path.abspath(root), quota
        self.lock = threading.RLock()
        self.codes, self.access, self.refresh = {}, {}, {}
        self.sessions = {}
        self.uploads = []                      # finished uploads, in order
        self.requests = 0
        self.dl_key = uuid.uuid4().hex
        self.faults = {"throttle_every": 0, "drop_fragment": 0, "page": 5, "search_path": False,
                       "decline": False, "pending_polls": 1, "expires_in": 3600, "ignore_range": False,
                       "interval": 1, "full": False}
        self.fragments = 0

    # ---------------------------------------------------------- the folder
    def resolve(self, rel):
        cur = self.root
        for part in [p for p in rel.split("/") if p]:
            try:
                names = os.listdir(cur)
            except (NotADirectoryError, FileNotFoundError):
                return None
            hit = next((n for n in names if n.lower() == part.lower()), None)
            if hit is None:
                return None
            cur = os.path.join(cur, hit)
        return cur

    def rel(self, real):
        r = os.path.relpath(real, self.root).replace(os.sep, "/")
        return "/" if r == "." else "/" + r

    @staticmethod
    def id_of(rel):
        return "root" if rel == "/" else "i" + rel.encode().hex()

    def from_id(self, ident):
        if ident == "root":
            return self.root
        try:
            return self.resolve(bytes.fromhex(ident[1:]).decode())
        except ValueError:
            return None

    def item(self, real, base, path=True):
        st, rel = os.stat(real), self.rel(real)
        d = {"id": self.id_of(rel), "name": "root" if rel == "/" else os.path.basename(real),
             "eTag": '"%s,%d"' % (self.id_of(rel), st.st_mtime_ns),
             "lastModifiedDateTime": iso(st.st_mtime), "createdDateTime": iso(st.st_mtime),
             "fileSystemInfo": {"lastModifiedDateTime": iso(st.st_mtime)}}
        if rel != "/":
            parent = os.path.dirname(rel)
            ref = {"driveId": "d1", "driveType": "business", "id": self.id_of(parent)}
            if path:
                ref["path"] = "/drive/root:" + ("" if parent == "/" else urllib.parse.quote(parent))
            d["parentReference"] = ref
        if os.path.isdir(real):
            d["folder"] = {"childCount": len(os.listdir(real))}
            d["size"] = 0
        else:
            d["file"] = {"mimeType": "application/octet-stream"}
            d["size"] = st.st_size
            d["@microsoft.graph.downloadUrl"] = "%s/download/%s?tempauth=%s" % (base, d["id"], self.dl_key)
        return d

    def used(self):
        return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(self.root) for f in fs)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"             # keep-alive, as Microsoft's servers
    st = None

    def log_message(self, fmt, *args):
        pass

    # ---------------------------------------------------------- plumbing
    def _send(self, status, body=b"", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            headers = dict(headers or {}, **{"Content-Type": "application/json"})
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _err(self, status, code, message=""):
        self._send(status, {"error": {"code": code, "message": message or code}})

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    @property
    def base(self):                            # as the client reached us (the VM: 10.0.2.2)
        return "http://" + (self.headers.get("Host") or "%s:%d" % self.server.server_address[:2])

    def _authed(self):
        tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
        with self.st.lock:
            exp = self.st.access.get(tok)
        if exp is None or exp < time.time():
            self._err(401, "InvalidAuthenticationToken", "Access token has expired or is not yet valid.")
            return False
        return True

    def _throttled(self):
        with self.st.lock:
            self.st.requests += 1
            every = self.st.faults["throttle_every"]
            hit = every and self.st.requests % every == 0
        if hit:
            self._send(429, {"error": {"code": "activityLimitReached", "message": "throttled"}},
                       {"Retry-After": "0"})
        return hit

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")

    def do_DELETE(self):
        self._route("DELETE")

    def _route(self, method):
        u = urllib.parse.urlsplit(self.path)
        path, query = u.path, urllib.parse.parse_qs(u.query)
        body = self._body() if method in ("POST", "PUT") else b""
        try:
            if path.startswith("/_"):
                return self._admin(method, path, body)
            m = re.match(r"^/[^/]+/oauth2/v2\.0/(devicecode|token)$", path)
            if m and method == "POST":
                return self._login(m.group(1), urllib.parse.parse_qs(body.decode()))
            if path.startswith("/download/"):
                return self._download(path.split("/")[2], query)
            if path.startswith("/upload/"):
                return self._fragment(method, path.split("/")[2], body)
            if path.startswith("/v1.0/"):
                if self._throttled() or not self._authed():
                    return
                return self._graph(method, path[len("/v1.0"):], query, body)
            self._err(404, "itemNotFound")
        except ConnectionError:
            pass

    # ---------------------------------------------------------- sign-in
    def _login(self, what, form):
        st, f = self.st, {k: v[0] for k, v in form.items()}
        if f.get("client_id") != CLIENT:
            return self._send(400, {"error": "unauthorized_client",
                                    "error_description": "AADSTS700016: Application not found."})
        if what == "devicecode":
            if "offline_access" not in f.get("scope", ""):
                return self._send(400, {"error": "invalid_scope"})
            dc = uuid.uuid4().hex
            with st.lock:
                st.codes[dc] = 0
            return self._send(200, {"device_code": dc, "user_code": "TESTCODE9", "interval": st.faults["interval"],
                                    "verification_uri": "https://microsoft.com/devicelogin",
                                    "expires_in": 900, "message": "To sign in, use a web browser..."})
        grant = f.get("grant_type", "")
        if grant.endswith("device_code"):
            with st.lock:
                polls = st.codes.get(f.get("device_code"))
                if polls is None:
                    return self._send(400, {"error": "expired_token"})
                st.codes[f["device_code"]] = polls + 1
            if st.faults["decline"]:
                return self._send(400, {"error": "authorization_declined"})
            if polls < st.faults["pending_polls"]:
                return self._send(400, {"error": "authorization_pending",
                                        "error_description": "AADSTS70016: OAuth 2.0 device flow error."})
            with st.lock:
                st.codes.pop(f["device_code"], None)
        elif grant == "refresh_token":
            with st.lock:
                if not st.refresh.pop(f.get("refresh_token"), False):
                    return self._send(400, {"error": "invalid_grant",
                                            "error_description": "AADSTS70008: The refresh token has expired."})
        else:
            return self._send(400, {"error": "unsupported_grant_type"})
        at, rt = "at-" + uuid.uuid4().hex, "rt-" + uuid.uuid4().hex
        with st.lock:
            st.access[at] = time.time() + st.faults["expires_in"]
            st.refresh[rt] = True
        self._send(200, {"token_type": "Bearer", "scope": f.get("scope", ""), "expires_in": st.faults["expires_in"],
                         "access_token": at, "refresh_token": rt})

    # ---------------------------------------------------------- the drive
    def _list(self, real, path, query):
        if real is None or not os.path.isdir(real):
            return self._err(404, "itemNotFound")
        names = sorted(os.listdir(real))
        top = min(int((query.get("$top") or ["200"])[0]), self.st.faults["page"] or 200)
        skip = int((query.get("$skiptoken") or ["0"])[0])
        out = {"value": [self.st.item(os.path.join(real, n), self.base) for n in names[skip:skip + top]]}
        if skip + top < len(names):                # path: as the request had it, still encoded
            out["@odata.nextLink"] = "%s/v1.0%s?$top=%d&$skiptoken=%d" % (self.base, path, top, skip + top)
        self._send(200, out)

    def _graph(self, method, path, query, body):
        st = self.st
        if path == "/me" and method == "GET":
            return self._send(200, USER)
        if path == "/me/drive" and method == "GET":
            used = st.used()
            return self._send(200, {"id": "d1", "driveType": "business",
                                    "quota": {"total": st.quota, "used": used, "remaining": st.quota - used}})
        m = re.match(r"^/me/drive/root/search\(q='(.*)'\)$", path)
        if m:
            text = urllib.parse.unquote(m.group(1)).replace("''", "'").lower()
            hits = []
            for dp, ds, fs in os.walk(st.root):
                for n in ds + fs:
                    if text in n.lower():
                        hits.append(st.item(os.path.join(dp, n), self.base, path=st.faults["search_path"]))
            return self._send(200, {"value": hits})
        m = re.match(r"^/me/drive/items/([^/]+)$", path)
        if m:
            real = st.from_id(m.group(1))
            if real is None:
                return self._err(404, "itemNotFound")
            if method == "GET":
                return self._send(200, st.item(real, self.base))
            if method == "DELETE":
                with st.lock:
                    shutil.rmtree(real) if os.path.isdir(real) else os.remove(real)
                return self._send(204)
        if path in ("/me/drive/root", "/me/drive/root/children"):
            rel, rest = "/", "/children" if path.endswith("/children") else ""
        else:
            m = re.match(r"^/me/drive/root:([^:]*):(/.*)?$", path)
            if not m:
                return self._err(400, "invalidRequest", path)
            rel, rest = urllib.parse.unquote(m.group(1)) or "/", m.group(2) or ""
        real = st.resolve(rel)
        if rest == "" and method == "GET":
            return self._send(200, st.item(real, self.base)) if real else self._err(404, "itemNotFound")
        if rest == "/children" and method == "GET":
            return self._list(real, path, query)
        if rest == "/children" and method == "POST":
            j = json.loads(body)
            if real is None:
                return self._err(404, "itemNotFound")
            name = j["name"]
            with st.lock:
                if st.resolve(rel.rstrip("/") + "/" + name) is not None:
                    return self._err(409, "nameAlreadyExists", "An item with the same name already exists.")
                os.mkdir(os.path.join(real, name))
            return self._send(201, st.item(os.path.join(real, name), self.base))
        if rest in ("/content", "/createUploadSession") and method in ("PUT", "POST"):
            if st.faults.get("full"):
                return self._err(507, "quotaLimitReached", "Insufficient Space Available")
            parent = st.resolve(os.path.dirname(rel))
            if parent is None or not os.path.isdir(parent):
                return self._err(404, "itemNotFound", "the folder is not there")
            name = os.path.basename(rel)
            have = st.resolve(rel)
            target = have or os.path.join(parent, name)    # same name, any case: replaced
            if rest == "/content":
                if len(body) > 4 * 1024 * 1024:
                    return self._err(413, "requestTooLarge")
                with open(target, "wb") as f:
                    f.write(body)
                with st.lock:
                    st.uploads.append(st.rel(target))
                return self._send(201, st.item(target, self.base))
            sid = uuid.uuid4().hex
            with st.lock:
                st.sessions[sid] = {"target": target, "got": 0, "data": bytearray()}
            return self._send(200, {"uploadUrl": "%s/upload/%s?tempauth=x" % (self.base, sid),
                                    "expirationDateTime": iso(time.time() + 3600), "nextExpectedRanges": ["0-"]})
        self._err(400, "invalidRequest", "%s %s" % (method, path))

    def _download(self, ident, query):
        st = self.st
        if (query.get("tempauth") or [""])[0] != st.dl_key:
            return self._err(401, "unauthenticated", "the link has run out")
        real = st.from_id(ident)
        if real is None or not os.path.isfile(real):
            return self._err(404, "itemNotFound")
        size = os.path.getsize(real)
        rng = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range") or "")
        with open(real, "rb") as f:
            if rng and not st.faults["ignore_range"]:
                a = int(rng.group(1))
                b = min(int(rng.group(2) or size - 1), size - 1)
                f.seek(a)
                return self._send(206, f.read(b - a + 1), {"Content-Range": "bytes %d-%d/%d" % (a, b, size)})
            return self._send(200, f.read())

    def _fragment(self, method, sid, body):
        st = self.st
        with st.lock:
            s = st.sessions.get(sid)
        if s is None:
            return self._err(404, "itemNotFound", "the upload session is gone")
        if method == "GET":
            return self._send(200, {"nextExpectedRanges": ["%d-" % s["got"]]})
        if self.headers.get("Authorization"):
            return self._err(401, "unauthenticated", "an upload URL takes no Authorization header")
        m = re.match(r"bytes (\d+)-(\d+)/(\d+)", self.headers.get("Content-Range") or "")
        if not m:
            return self._err(400, "invalidRange")
        a, b, total = map(int, m.groups())
        if b - a + 1 != len(body):
            return self._err(400, "invalidRange", "length does not match the range")
        if b + 1 < total and len(body) % FRAG:
            return self._err(400, "invalidRange", "a fragment must be a multiple of 320 KiB")
        with st.lock:
            if a != s["got"]:
                return self._err(416, "invalidRange", "fragment overlap")
            s["data"] += body
            s["got"] = b + 1
            st.fragments += 1
            drop = st.faults["drop_fragment"] and st.fragments == st.faults["drop_fragment"]
        if drop:                               # taken, but the answer is lost on the way back
            self.close_connection = True
            self.wfile.flush()
            self.connection.shutdown(2)
            return None
        if s["got"] < total:
            return self._send(202, {"nextExpectedRanges": ["%d-" % s["got"]]})
        with open(s["target"], "wb") as f:
            f.write(s["data"])
        with st.lock:
            st.sessions.pop(sid, None)
            st.uploads.append(st.rel(s["target"]))
        return self._send(201, st.item(s["target"], self.base))

    # ---------------------------------------------------------- for the tests
    def _admin(self, method, path, body):
        st = self.st
        with st.lock:
            if path == "/_fault":
                st.faults.update(json.loads(body or b"{}"))
            elif path == "/_revoke":
                st.refresh.clear()
                st.access.clear()
            elif path == "/_expire":
                st.access = {k: 0 for k in st.access}
            elif path == "/_rotate":                # every download link runs out
                st.dl_key = uuid.uuid4().hex
            log = {"uploads": list(st.uploads), "requests": st.requests, "fragments": st.fragments,
                   "faults": dict(st.faults)}
            if path == "/_reset":                   # answers what came before it
                st.uploads, st.fragments, st.requests = [], 0, 0
        self._send(200, log)


class Server:
    def __init__(self, root, port=0, host="127.0.0.1"):
        self.state = State(root)
        handler = type("H", (Handler,), {"st": self.state})
        self.httpd = ThreadingHTTPServer((host, port), handler)
        self.httpd.daemon_threads = True
        self.url = "http://%s:%d" % self.httpd.server_address[:2]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def start(root, port=0):
    srv = Server(root, port)
    srv.thread.start()
    return srv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    os.makedirs(a.root, exist_ok=True)
    srv = Server(a.root, a.port, a.host)
    print(srv.url, flush=True)
    srv.httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
