#!/usr/bin/env python3
"""
platform-login.py — exchange a smalt login for a refresh token.

WHAT IT DOES
    POSTs email + password to the smalt API, keeps only the refresh token, and
    writes it to ~/.config/smalt/platform.token at mode 600. That file is what
    the `smalt-documents` Claude plugin reads; the plugin refreshes and rewrites it
    from then on, so this runs once per machine.

WHAT IT DELIBERATELY DOES NOT DO
    * Print, log or store the password. It arrives in the environment (never
      argv, so it cannot be read out of `ps`) and is dropped immediately.
    * Keep the access token. The plugin mints its own and holds it in memory.
    * Print the refresh token. Output is status, a path and a byte count — so
      Claude can run this and read the result without learning a secret.

USAGE
    SMALT_PASSWORD='…' python3 platform-login.py --email you@smalt.eu
    python3 platform-login.py --check          # is a token installed? no network

    SMALT_API_BASE     override the API root (testing)
    SMALT_TOKEN_FILE   override the destination (testing)

EXIT CODES
    0 ok   1 bad credentials   2 usage   3 network/server   4 no token (--check)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API_BASE = os.environ.get("SMALT_API_BASE", "https://api2.smalt.eu").rstrip("/")
TOKEN_FILE = os.path.expanduser(
    os.environ.get("SMALT_TOKEN_FILE", "~/.config/smalt/platform.token"))
TIMEOUT = 30


def post_json(path: str, payload: dict):
    """Returns (status, parsed_body_or_None). Never raises on HTTP status."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        API_BASE + path, data=data,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
            status = r.getcode()
    except urllib.error.HTTPError as e:
        raw = e.read()
        status = e.code
    except Exception as e:                       # DNS, TLS, refused, timeout
        return None, str(e)
    try:
        return status, json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return status, None


def explain(status, body) -> str:
    """Both error shapes. 401 is the domain handler; 422 is Pydantic rejecting
    the request before it ever reaches one, so the payloads look nothing alike
    and a reader that only knows one of them reports the wrong thing."""
    if isinstance(body, dict):
        err = body.get("error")
        if isinstance(err, dict) and err.get("message"):
            return str(err["message"])
        detail = body.get("detail")
        if isinstance(detail, list) and detail:
            parts = []
            for d in detail[:3]:
                if not isinstance(d, dict):
                    continue
                loc = d.get("loc") or []
                field = str(loc[-1]) if loc else "request"
                parts.append("%s: %s" % (field, d.get("msg", "invalid")))
            if parts:
                return "; ".join(parts)
        if isinstance(detail, str):
            return detail
    return "HTTP %s" % status


def looks_like_jwt(tok: str) -> bool:
    return tok.count(".") == 2 and all(p for p in tok.split("."))


def write_token(tok: str) -> int:
    """Atomic: temp file in the same directory, then rename. A crash mid-write
    must not leave an empty or half-written credential in place."""
    d = os.path.dirname(TOKEN_FILE)
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    tmp = "%s.new.%d" % (TOKEN_FILE, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(tok.strip() + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, TOKEN_FILE)
        os.chmod(TOKEN_FILE, 0o600)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return os.path.getsize(TOKEN_FILE)


def do_check() -> int:
    if not os.path.exists(TOKEN_FILE):
        print("no token installed at %s" % TOKEN_FILE)
        return 4
    st = os.stat(TOKEN_FILE)
    if st.st_size == 0:
        print("token file is EMPTY: %s" % TOKEN_FILE)
        return 4
    age = (time.time() - st.st_mtime) / 86400.0
    print("token installed: %s (%d bytes, mode %o, last written %.1f days ago)"
          % (TOKEN_FILE, st.st_size, st.st_mode & 0o777, age))
    # Both TTLs are 30 days and refresh slides the window, so the only hard
    # deadline is 30 days of no use at all.
    if age >= 30:
        print("WARNING: older than 30 days — it has probably expired. Log in again.")
        return 4
    if age >= 25:
        print("NOTE: %.0f days old. Use it soon or it will expire at 30." % age)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--email")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if args.check:
        return do_check()
    if not args.email:
        print("usage: SMALT_PASSWORD=… python3 platform-login.py --email you@smalt.eu",
              file=sys.stderr)
        return 2

    password = os.environ.get("SMALT_PASSWORD", "")
    if not password:
        print("SMALT_PASSWORD is not set. Pass the password in the environment, "
              "never on the command line.", file=sys.stderr)
        return 2

    status, body = post_json("/api/v1/auth/login",
                             {"email": args.email, "password": password})
    del password
    os.environ.pop("SMALT_PASSWORD", None)

    if status is None:
        print("could not reach %s — %s" % (API_BASE, body), file=sys.stderr)
        return 3

    if status != 200:
        msg = explain(status, body)
        if status in (400, 401, 403):
            print("login refused: %s" % msg, file=sys.stderr)
            return 1
        if status == 422:
            # A typo'd domain lands here, not on 401 — email is a validated
            # EmailStr, so it is rejected before any credential check.
            print("the server rejected the request: %s" % msg, file=sys.stderr)
            return 1
        print("login failed (HTTP %s): %s" % (status, msg), file=sys.stderr)
        return 3

    if not isinstance(body, dict):
        print("login returned 200 but the body was not JSON", file=sys.stderr)
        return 3

    tok = (body.get("refresh_token") or "").strip()
    if not tok:
        print("login succeeded but no refresh_token was returned", file=sys.stderr)
        return 3
    if not looks_like_jwt(tok):
        print("WARNING: the refresh token does not look like a JWT; storing anyway.",
              file=sys.stderr)

    n = write_token(tok)

    roles = [r.get("name") for r in (body.get("roles") or []) if isinstance(r, dict)]
    user = (body.get("user") or {})
    who = user.get("email") or args.email

    print("logged in as %s" % who)
    print("token written: %s (%d bytes, mode 600)" % (TOKEN_FILE, n))
    if roles:
        print("roles: %s" % ", ".join(str(r) for r in roles if r))
    if "SUPER_ADMIN" not in roles:
        print("NOTE: your account does not carry the elevated platform role, so "
              "some documents will return 403. That is your permissions, not a "
              "broken setup.")
    if body.get("expires_at"):
        print("session expires: %s (refreshing slides the window)" % body["expires_at"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
