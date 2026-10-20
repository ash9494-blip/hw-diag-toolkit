#!/usr/bin/env python3
"""Ash's work OneDrive as a place for disk images - Ash, 1.26: "for image
restore not only rely on usb, but also to search image on onedrive, and
back up from there".

Microsoft Graph through Python's own urllib - nothing more to install.
Sign-in is the device code flow: the screen shows a short code, Ash
approves it on his phone at microsoft.com/devicelogin, and no password is
ever typed on a bench laptop. The app is Ash's own registration in Data
Dynamics' Entra (onedrive.conf: its client and tenant IDs; delegated
Files.ReadWrite + offline_access, public client flows on).

The sign-in (a refresh token) lives in $RUN_DIR/onedrive/token.json and -
Ash's choice, told that anyone holding the stick can then reach his
OneDrive - on the boot stick too (imglib.sh od_keep); Disk imaging ->
Sign out of OneDrive deletes both. Microsoft hands out a new refresh token
with every renewal, so the stick's copy is rewritten after a session.

odfs.py mounts the drive as a folder: restore, browse, check and backup
then use it as they use a USB drive.

    onedrive.py signin        prints CODE|URL|MINUTES, then waits for approval
    onedrive.py whoami [--live]   "Name <user@company>" - exit 1 when not signed in;
                              --live asks Microsoft rather than the kept label
    onedrive.py signout       forget the sign-in kept on this laptop
    onedrive.py mount MNT     the drive as a folder (odfs.py, in the background)
    onedrive.py sync MNT      upload what odfs.py still holds (small files)
    onedrive.py umount MNT
    onedrive.py images MNT    the image picker's lines, images anywhere on it
    onedrive.py ready         exit 0 when an app ID is set up (build or stick)

Exit 1 is a failure with the reason on stderr; 3 is "Microsoft could not
be reached" - no internet - for which the screen offers Wi-Fi; 4 is "the
app IDs are wrong" (Microsoft knows no such app or tenant), for which it
asks for them again.
"""
import errno
import http.client
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

import imgfmt

HERE = os.path.dirname(os.path.abspath(__file__))


def _read_conf(path, keys=None):
    conf = {}
    try:
        with open(path) as f:
            for line in f:
                key, eq, value = line.strip().partition("=")
                key = key.strip()
                if eq and not key.startswith("#") and (keys is None or key in keys):
                    conf[key] = value.strip()
    except OSError:
        pass
    return conf


RUN_DIR = os.environ.get("RUN_DIR", "/run/diag")
STATE = os.path.join(RUN_DIR, "onedrive")
# onedrive.conf beside this: CLIENT_ID, TENANT_ID - the app Ash registered -
# and, for the VM harness only, LOGIN / GRAPH pointing at test/fakegraph.py.
# The IDs can also come from diag-onedrive.conf on the boot stick (imglib.sh
# copies it to STATE): no rebuild when the app is registered later. Only the
# IDs are taken from the stick - never where the sign-in goes - and only
# where the build has none: a stick with another tenant's app must not win
# over the build's and send customer images there (security review, 1.26).
# Environment variables OD_* win (the tests).
CONF = _read_conf(os.path.join(HERE, "onedrive.conf"))
for _k, _v in _read_conf(os.path.join(STATE, "onedrive.conf"), ("CLIENT_ID", "TENANT_ID")).items():
    CONF[_k] = CONF.get(_k) or _v
GUID = re.compile(r"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
TENANT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$")       # a GUID, or contoso.onmicrosoft.com
TOKEN = os.path.join(STATE, "token.json")
LOG = os.path.join(RUN_DIR, "onedrive.log")
LOGIN = os.environ.get("OD_LOGIN") or CONF.get("LOGIN") or "https://login.microsoftonline.com"
GRAPH = os.environ.get("OD_GRAPH") or CONF.get("GRAPH") or "https://graph.microsoft.com/v1.0"
SCOPE = "Files.ReadWrite offline_access User.Read"
UP_CHUNK = 32 * 320 * 1024       # 10 MiB: upload fragments are multiples of 320 KiB
UP_SMALL = 4 * 1024 * 1024       # up to this a file goes up in one PUT
RETRIES = 6
IMAGES_DIR = "/Disk images"      # where backups made here go
SYNC_NAME = ".diag-sync"         # odfs.py: writing it uploads everything held
FORM = {"Content-Type": "application/x-www-form-urlencoded"}


class GraphError(Exception):
    """A OneDrive / sign-in failure; the message is for the operator."""

    def __init__(self, message, status=0):
        super().__init__(message)
        self.status = status


class Offline(GraphError):
    """Microsoft could not be reached at all: exit 3, and the screen offers Wi-Fi."""


class AppRejected(GraphError):
    """Microsoft does not know the app or the tenant - the IDs are wrong
    (typed in once on a bench laptop): exit 4, and the screen asks again."""


# AADSTS700016 app not found in the directory, 90002 tenant not found,
# 900023 not a tenant ID, 50059 no tenant in the request
APP_UNKNOWN = re.compile(r"AADSTS(700016|90002|900023|50059)\b")


def log(text):
    try:
        os.makedirs(RUN_DIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), text))
    except OSError:
        pass


def config():
    """The app registration. An ID that is not one (a typo on the stick,
    anything that would change the sign-in URL) counts as none."""
    client = os.environ.get("OD_CLIENT") or CONF.get("CLIENT_ID", "")
    tenant = os.environ.get("OD_TENANT") or CONF.get("TENANT_ID", "")
    if not GUID.match(client):
        client = ""
    if tenant and not TENANT_NAME.match(tenant):
        tenant = ""
    return {"client": client, "tenant": tenant}


def _message(status, body):
    """Microsoft's own words for a failure, short."""
    try:
        j = json.loads(body or b"{}")
    except ValueError:
        j = {}
    err = j.get("error") if isinstance(j, dict) else None
    if isinstance(err, dict):
        text = err.get("message") or err.get("code")
    else:
        text = (j.get("error_description") or err or "").split("\r\n")[0] if isinstance(j, dict) else ""
    return "OneDrive said %s%s" % (status, ": " + text if text else "")


_local = threading.local()


def _conn(scheme, host, timeout, fresh=False):
    """This thread's open connection to host. urllib makes a new TLS
    connection per request - a restore makes thousands of them, and each
    handshake to Microsoft costs more than the 8 MB it then fetches."""
    pool = getattr(_local, "pool", None)
    if pool is None:
        pool = _local.pool = {}
    c = pool.get((scheme, host))
    if c is not None and fresh:
        c.close()
        c = None
    if c is None:
        cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        c = pool[(scheme, host)] = cls(host, timeout=timeout)
    return c


def _http(method, url, data=None, headers=None, timeout=60):
    """One request: (status, headers, body); an HTTP error is a status here.
    A connection the far end closed while idle is opened again, once."""
    u = urllib.parse.urlsplit(url)
    target = (u.path or "/") + ("?" + u.query if u.query else "")
    for attempt in (0, 1):
        c = _conn(u.scheme, u.netloc, timeout, fresh=attempt > 0)
        try:
            c.request(method, target, body=data, headers=headers or {})
            r = c.getresponse()
            body = r.read()
        except (http.client.RemoteDisconnected, http.client.CannotSendRequest, BrokenPipeError,
                ConnectionResetError):
            c.close()
            if attempt:
                raise
            continue
        except (OSError, http.client.HTTPException):
            c.close()                           # never reuse a connection left half way
            raise
        if (r.getheader("connection") or "").lower() == "close":
            c.close()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, body
    raise ConnectionError("no connection")


def call(method, url, data=None, headers=None, ok=(200, 201, 202, 204, 206), auth=None, timeout=60):
    """A request with retries - throttling (429/503 with Retry-After), a
    server hiccup, a dropped connection: a bench's Wi-Fi is not a data
    centre. Anything else is a GraphError with Microsoft's message."""
    delay, refreshed = 2.0, False
    for attempt in range(RETRIES):
        h = dict(headers or {})
        if auth is not None:
            h["Authorization"] = "Bearer " + auth.token()
        try:
            status, rh, body = _http(method, url, data, h, timeout)
        except ssl.SSLCertVerificationError as exc:
            # nearly always this laptop's clock (a flat CMOS battery), not the
            # network: trying again, or offering Wi-Fi, would not help
            log("%s %s: %s" % (method, url.split("?")[0][:120], exc))
            raise GraphError("Microsoft's certificate was not accepted - is this laptop's date and time right? (%s)"
                             % time.strftime("%Y-%m-%d"))
        except (OSError, http.client.HTTPException) as exc:     # socket.timeout and ssl errors are OSErrors
            log("%s %s: %s" % (method, url.split("?")[0][:120], exc))   # no query: download links carry a key
            # no network at all: say so now - six tries sat a minute on
            # "Asking Microsoft..." before the Wi-Fi page was offered (VM)
            if attempt == RETRIES - 1 or getattr(exc, "errno", None) in (errno.ENETUNREACH, errno.EHOSTUNREACH):
                raise Offline("cannot reach Microsoft (%s) - is this laptop on the internet?" % exc)
            time.sleep(delay)
            delay = min(delay * 2, 30)
            continue
        if status in ok:
            return status, rh, body
        if status == 401 and auth is not None and not refreshed:
            auth.refresh()
            refreshed = True
            continue
        if status in (429, 500, 502, 503, 504) and attempt < RETRIES - 1:
            try:
                wait = float(rh.get("retry-after", delay))
            except ValueError:
                wait = delay
            log("%s %s: %s, again in %.0fs" % (method, url.split("?")[0][:120], status, wait))
            time.sleep(min(wait, 60))
            delay = min(delay * 2, 30)
            continue
        raise GraphError(_message(status, body), status)
    raise GraphError("OneDrive did not answer")


# ---------------------------------------------------------------- sign-in
class Auth:
    """The device code sign-in and its tokens."""

    def __init__(self, path=None, conf=None):
        self.path, self.conf = path or TOKEN, conf or config()
        self.lock = threading.RLock()
        try:
            with open(self.path) as f:
                self.tok = json.load(f)
        except (OSError, ValueError):
            self.tok = {}

    @property
    def base(self):
        return "%s/%s/oauth2/v2.0" % (LOGIN, self.conf["tenant"] or "organizations")

    def signed_in(self):
        return bool(self.tok.get("refresh_token"))

    def _save(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        tmp = self.path + ".new"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(self.tok, f)
        os.replace(tmp, self.path)

    def _take(self, j):
        self.tok.update(access_token=j["access_token"], expires_at=time.time() + int(j.get("expires_in", 3600)),
                        refresh_token=j.get("refresh_token") or self.tok.get("refresh_token"))
        self._save()

    def start(self):
        """Ask for a code: {user_code, verification_uri, expires_in, interval, device_code}."""
        if not self.conf["client"]:
            raise GraphError("OneDrive is not set up in this toolkit (onedrive.conf has no app ID)")
        form = urllib.parse.urlencode({"client_id": self.conf["client"], "scope": SCOPE}).encode()
        try:
            _, _, body = call("POST", self.base + "/devicecode", form, FORM, ok=(200,))
        except GraphError as exc:
            if APP_UNKNOWN.search(str(exc)):
                raise AppRejected(str(exc), exc.status)
            raise
        return json.loads(body)

    def wait(self, dc):
        """Until the code is approved on the phone, declined, or runs out."""
        interval = int(dc.get("interval", 5))
        deadline = time.time() + int(dc.get("expires_in", 900))
        form = urllib.parse.urlencode({"client_id": self.conf["client"], "device_code": dc["device_code"],
                                       "grant_type": "urn:ietf:params:oauth:grant-type:device_code"}).encode()
        while time.time() < deadline:
            time.sleep(interval)
            try:
                status, _, body = _http("POST", self.base + "/token", form, FORM)
            except (OSError, http.client.HTTPException) as exc:
                log("sign-in poll: %s" % exc)
                continue
            try:
                j = json.loads(body or b"{}")
            except ValueError:
                j = {}
            if status == 200:
                self._take(j)
                return
            err = j.get("error")
            if err == "authorization_pending":
                continue
            if err == "slow_down":
                interval += 5
                continue
            if err in ("authorization_declined", "access_denied"):
                raise GraphError("the sign-in was declined")
            if err in ("expired_token", "code_expired"):
                break
            raise GraphError(_message(status, body), status)
        raise GraphError("the code ran out before it was used - start again")

    def refresh(self):
        with self.lock:
            self._refresh()

    def _refresh(self):
        if not self.signed_in():
            raise GraphError("not signed in to OneDrive")
        form =urllib.parse.urlencode({"client_id": self.conf["client"], "scope": SCOPE,
                                       "grant_type": "refresh_token",
                                       "refresh_token": self.tok["refresh_token"]}).encode()
        try:
            _, _, body = call("POST", self.base + "/token", form, FORM, ok=(200,))
        except GraphError as exc:
            if exc.status in (400, 401):
                # revoked, expired (90 days unused) or the password changed
                self.forget()
                raise GraphError("the OneDrive sign-in has run out or was withdrawn - sign in again", exc.status)
            raise
        self._take(json.loads(body))

    def token(self):
        # odfs.py reads with several threads: one renewal, not four
        with self.lock:
            if not self.tok.get("access_token") or self.tok.get("expires_at", 0) < time.time() + 120:
                self.refresh()
            return self.tok["access_token"]

    def forget(self):
        self.tok = {}
        try:
            os.remove(self.path)
        except OSError:
            pass


# ---------------------------------------------------------------- the drive
def _q(path):
    return urllib.parse.quote(path, safe="/")


class Drive:
    """The signed-in user's OneDrive, by path ("/Disk images/x")."""

    def __init__(self, auth):
        self.auth = auth

    def _url(self, path):
        return GRAPH + ("/me/drive/root" if path in ("", "/") else "/me/drive/root:%s:" % _q(path))

    def _get(self, url):
        if url.startswith("http"):
            # the sign-in goes with this request: only ever to Graph itself,
            # whatever a next-page link from the answer says
            if urllib.parse.urlsplit(url)[:2] != urllib.parse.urlsplit(GRAPH)[:2]:
                raise GraphError("OneDrive sent a link to somewhere else (%s)" % urllib.parse.urlsplit(url).netloc)
        else:
            url = GRAPH + url
        _, _, body = call("GET", url, auth=self.auth, ok=(200,))
        return json.loads(body)

    def me(self):
        return self._get("/me")

    def quota(self):
        """(total, remaining) in bytes; None for one the drive does not say."""
        q = self._get("/me/drive").get("quota") or {}
        return tuple(int(q[k]) if q.get(k) is not None else None for k in ("total", "remaining"))

    def item(self, path):
        try:
            return self._get(self._url(path))
        except GraphError as exc:
            if exc.status == 404:
                return None
            raise

    def _pages(self, url):
        out = []
        while url:
            j = self._get(url)
            out += j.get("value", [])
            url = j.get("@odata.nextLink")
        return out

    def children(self, path):
        base = GRAPH + "/me/drive/root/children" if path in ("", "/") else self._url(path) + "/children"
        return self._pages(base + "?$top=999")

    def search(self, text):
        return self._pages(GRAPH + "/me/drive/root/search(q='%s')?$top=200"
                           % urllib.parse.quote(text.replace("'", "''")))

    def read(self, item, off, n):
        """n bytes at off: a ranged GET on the file's own download link
        (good for about an hour - fetched again when it has run out)."""
        for attempt in (0, 1):
            url = item.get("@microsoft.graph.downloadUrl")
            if not url or attempt:
                fresh = self._get("/me/drive/items/" + item["id"])
                item["@microsoft.graph.downloadUrl"] = url = fresh.get("@microsoft.graph.downloadUrl")
            try:
                status, _, body = call("GET", url, headers={"Range": "bytes=%d-%d" % (off, off + n - 1)},
                                       ok=(200, 206))
            except GraphError as exc:
                if exc.status in (401, 403, 404) and not attempt:
                    continue
                raise
            if status == 200 and off:            # the range was ignored: never serve the wrong bytes
                body = body[off:off + n]
            return body[:n]
        raise GraphError("the file's download link would not open")

    def mkdir(self, path):
        parent, name = os.path.split(path.rstrip("/"))
        url = (GRAPH + "/me/drive/root/children") if parent in ("", "/") else self._url(parent) + "/children"
        data = json.dumps({"name": name, "folder": {}, "@microsoft.graph.conflictBehavior": "fail"}).encode()
        try:
            _, _, body = call("POST", url, data, {"Content-Type": "application/json"}, ok=(200, 201), auth=self.auth)
            return json.loads(body)
        except GraphError as exc:
            if exc.status == 409:                 # already there
                return self.item(path)
            raise

    def makedirs(self, path):
        at = ""
        for part in [p for p in path.split("/") if p]:
            at += "/" + part
            if self.item(at) is None:
                self.mkdir(at)

    def upload(self, path, f, size):
        """Up from file object f (size bytes, from where it stands), and
        OneDrive's word that it holds all of them: a piece that arrived short
        would restore as damage much later."""
        item = self._upload(path, f, size)
        if int(item.get("size", -1)) != size:
            raise GraphError("OneDrive holds %s bytes of %s, not %d" % (item.get("size"), path, size))
        return item

    def _upload(self, path, f, size):
        """One PUT when small, else an upload session in 10 MB fragments - a
        fragment the network dropped is sent again from where OneDrive says
        it is."""
        if size <= UP_SMALL:
            data = f.read(size)
            if len(data) != size:
                raise GraphError("%s: only %d of %d bytes could be read here" % (path, len(data), size))
            _, _, body = call("PUT", self._url(path) + "/content", data,
                              {"Content-Type": "application/octet-stream"}, ok=(200, 201), auth=self.auth)
            return json.loads(body)
        data = json.dumps({"item": {"@microsoft.graph.conflictBehavior": "replace"}}).encode()
        _, _, body = call("POST", self._url(path) + "/createUploadSession", data,
                          {"Content-Type": "application/json"}, ok=(200,), auth=self.auth)
        up = json.loads(body)["uploadUrl"]
        start, off = f.tell(), 0
        while off < size:
            f.seek(start + off)
            chunk = f.read(min(UP_CHUNK, size - off))
            if not chunk:
                raise GraphError("%s: only %d of %d bytes could be read here" % (path, off, size))
            try:
                # the upload URL carries its own permission: no Authorization header
                status, _, body = call("PUT", up, chunk, {"Content-Range": "bytes %d-%d/%d"
                                                          % (off, off + len(chunk) - 1, size)},
                                       ok=(200, 201, 202))
            except GraphError as exc:
                if exc.status != 416:
                    raise
                status, body = 202, b""                # already there: ask where to go on
            if status in (200, 201):
                return json.loads(body)
            nxt = json.loads(body).get("nextExpectedRanges") if body else None
            if not nxt:
                _, _, sb = call("GET", up, ok=(200,))
                nxt = json.loads(sb).get("nextExpectedRanges") or ["%d-" % (off + len(chunk))]
            off = int(nxt[0].split("-")[0])
        raise GraphError("OneDrive did not finish the upload of %s" % path)

    def delete(self, item):
        call("DELETE", GRAPH + "/me/drive/items/" + item["id"], ok=(204,), auth=self.auth)


# ---------------------------------------------------------------- finding images
def _parent_path(drive, item):
    """The folder an item is in, as a path. Search results from a work
    OneDrive often leave the path out of parentReference: ask for the item."""
    p = (item.get("parentReference") or {}).get("path")
    if p is None and item.get("id"):
        try:
            p = (drive._get("/me/drive/items/%s?$select=id,name,parentReference" % item["id"])
                 .get("parentReference") or {}).get("path")
        except GraphError as exc:
            log("where is %s: %s" % (item.get("name"), exc))
    if p is None or "root:" not in p:
        return None
    return urllib.parse.unquote(p.split("root:", 1)[1]).rstrip("/")


def _first_piece(name):
    """A Macrium file, and not a later piece of a split set (as imgfmt.find_images)."""
    m = imgfmt._MR_PIECE.search(name)
    return name.lower().endswith(".mrimg") and not (m and m.group(1) != "00")


def _is_image_folder(names):
    """imgfmt.is_image, on a listing."""
    return ("disk" in names or "parts" in names) and any(imgfmt._IMG_RE.match(n) for n in names)


def find_images(drive):
    """Paths of image folders and Macrium files on the drive. Microsoft's
    search finds them anywhere, by name - but its index can be minutes
    behind an upload and it does not split every name into words the same
    way - so the top of the drive, each folder in it (Clonezilla users keep
    images in partimag/) and every folder in "Disk images" are also read
    directly, as imgfmt.find_images reads a USB drive."""
    found = set()

    def consider(folder, kids):
        if folder != "/" and _is_image_folder([k["name"] for k in kids]):
            found.add(folder)
        for k in kids:
            if "file" in k and _first_piece(k["name"]):
                found.add(folder.rstrip("/") + "/" + k["name"])

    def listing(path):
        try:
            return drive.children(path)
        except GraphError as exc:
            log("list %s: %s" % (path, exc))
            return []

    for text in ("mrimg", "clonezilla-img"):
        try:
            hits = drive.search(text)
        except GraphError as exc:
            log("search %s: %s" % (text, exc))
            hits = []
        for it in hits:
            name = it.get("name", "")
            if "file" not in it or not (_first_piece(name) or name == "clonezilla-img"):
                continue
            parent = _parent_path(drive, it)
            if parent is None:
                continue
            found.add((parent or "/") if name == "clonezilla-img" else parent + "/" + name)
    top = listing("/")
    consider("/", top)
    folders = ["/" + k["name"] for k in top if "folder" in k]
    with ThreadPoolExecutor(8) as pool:
        lists = dict(zip(folders, pool.map(listing, folders)))
        for path, kids in lists.items():
            consider(path, kids)
        mine = [p for p in folders if p.lower() == IMAGES_DIR.lower()]
        subs = [m + "/" + k["name"] for m in mine for k in lists[m] if "folder" in k]
        for path, kids in zip(subs, pool.map(listing, subs)):
            consider(path, kids)
    return sorted(found)


# ---------------------------------------------------------------- the folder
def _clear_dead(mnt):
    """A mount left behind by an odfs.py that died answers every look with
    ENOTCONN: ismount() says no, and a new mount there fails until reboot."""
    try:
        os.stat(mnt)
    except OSError as exc:
        if exc.errno == errno.ENOTCONN:
            log("%s: the OneDrive folder had died - unmounted" % mnt)
            subprocess.run(["umount", "-l", mnt], capture_output=True)


def mount(mnt):
    _clear_dead(mnt)
    os.makedirs(mnt, exist_ok=True)
    if os.path.ismount(mnt):
        return
    auth = Auth()
    if not auth.signed_in():
        raise GraphError("not signed in to OneDrive")
    auth.token()                                   # offline or signed out: say so now
    with open(LOG, "a") as out:
        p = subprocess.Popen([sys.executable, os.path.join(HERE, "odfs.py"), mnt],
                             stdout=out, stderr=out, stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(200):
        if os.path.ismount(mnt):
            return
        if p.poll() is not None:
            raise GraphError("the OneDrive folder did not open (see onedrive.log)")
        time.sleep(0.1)
    p.kill()
    raise GraphError("the OneDrive folder did not open in time")


def sync(mnt):
    """Everything odfs.py still holds goes up now; an error is raised
    here, from the close - not lost the way a shell's ': >' loses it."""
    with open(os.path.join(mnt, SYNC_NAME), "wb"):
        pass


def umount(mnt):
    _clear_dead(mnt)
    if os.path.ismount(mnt):
        try:
            sync(mnt)
        except OSError as exc:
            log("sync before unmount: %s" % exc)
        subprocess.run(["umount", mnt], capture_output=True)
    for _ in range(100):
        if not os.path.ismount(mnt):
            return
        time.sleep(0.1)
    subprocess.run(["umount", "-l", mnt], capture_output=True)


def _remember_user(auth):
    me = Drive(auth).me()
    name = "%s <%s>" % (me.get("displayName", ""), me.get("userPrincipalName", ""))
    auth.tok["user"] = re.sub(r"[\x00-\x1f|]", " ", name)     # a screen line, a menu cell
    auth._save()


def main(argv):
    cmd, args = (argv[1] if len(argv) > 1 else ""), argv[2:]
    try:
        if cmd == "signin":
            auth = Auth()
            dc = auth.start()
            print("%s|%s|%d" % (dc["user_code"], dc["verification_uri"], int(dc.get("expires_in", 900)) // 60),
                  flush=True)
            auth.wait(dc)
            _remember_user(auth)
            print("ok")
        elif cmd == "whoami":
            # --live asks Microsoft: the name kept in the file is only a
            # label, and the screens that send an image somewhere show this
            auth = Auth()
            if not auth.signed_in():
                return 1
            if args[:1] == ["--live"]:
                _remember_user(auth)
            print(auth.tok.get("user") or "signed in")
        elif cmd == "signout":
            Auth().forget()
        elif cmd == "mount":
            mount(args[0])
        elif cmd == "sync":
            sync(args[0])
        elif cmd == "umount":
            umount(args[0])
        elif cmd == "images":
            sys.path.insert(0, HERE)
            import imgengine
            for path in find_images(Drive(Auth())):
                try:
                    print(imgengine.image_line(args[0].rstrip("/") + path))
                except (OSError, ValueError) as exc:
                    log("images %s: %s" % (path, exc))
        elif cmd == "ready":
            return 0 if config()["client"] else 1
        else:
            print(__doc__)
            return 2
    except GraphError as exc:
        log("%s: %s" % (cmd, exc))
        print(exc, file=sys.stderr)
        return 3 if isinstance(exc, Offline) else 4 if isinstance(exc, AppRejected) else 1
    except OSError as exc:
        print("OneDrive: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
