#!/usr/bin/env python3
"""Minimal stdio MCP server for Metabase REST API.

Implements the Model Context Protocol (JSON-RPC 2.0 over stdio) using
nothing but the Python standard library. Exposes a single generic `query`
tool that proxies HTTP calls to the configured Metabase instance.

Credentials are read in this order:
  1. Process environment variables METABASE_BASE_URL / METABASE_API_KEY
     (works when the MCP host propagates env, e.g. Claude Code CLI).
  2. ~/.config/smalt/metabase.env — a key=value file the user creates once.
     This is the recommended path on Cowork desktop, where userConfig /
     env-block substitution is currently broken (see Anthropic
     issues #39125 / #39455 / #39827).

The credentials file format is:

    METABASE_BASE_URL=https://metabase.smalt.eu
    METABASE_API_KEY=mb_...

Comment lines starting with `#` and blank lines are ignored. Surrounding
single or double quotes around values are stripped. The file should be
chmod 600.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "metabase"
SERVER_VERSION = "0.3.0"
HTTP_TIMEOUT_SECONDS = 60

CREDENTIALS_FILE = os.path.expanduser("~/.config/smalt/metabase.env")


def _log(msg: str) -> None:
    """Write to stderr; stdout is reserved for JSON-RPC."""
    sys.stderr.write(f"[metabase-mcp] {msg}\n")
    sys.stderr.flush()


def _send(message: dict) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def _parse_env_file(path: str) -> dict:
    """Parse a simple KEY=VALUE file. Returns {} if file missing or unreadable."""
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip()
                # Strip a single matching pair of surrounding quotes
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    v = v[1:-1]
                if k:
                    out[k] = v
    except FileNotFoundError:
        pass
    except OSError as e:
        _log(f"could not read {path}: {e}")
    return out


def _read_env() -> tuple[str, str] | tuple[None, str]:
    """Resolve (base_url, api_key) from process env or sidecar file."""
    base = os.environ.get("METABASE_BASE_URL", "").strip()
    key = os.environ.get("METABASE_API_KEY", "")

    if not base or not key:
        sidecar = _parse_env_file(CREDENTIALS_FILE)
        if not base:
            base = sidecar.get("METABASE_BASE_URL", "").strip()
        if not key:
            key = sidecar.get("METABASE_API_KEY", "")

    base = base.rstrip("/")

    missing = []
    if not base:
        missing.append("METABASE_BASE_URL")
    if not key:
        missing.append("METABASE_API_KEY")
    if missing:
        return None, (
            f"missing {' and '.join(missing)}. "
            f"Either export them in your shell, or create {CREDENTIALS_FILE} "
            f"with lines like:\n"
            f"    METABASE_BASE_URL=https://metabase.smalt.eu\n"
            f"    METABASE_API_KEY=mb_...\n"
            f"Then chmod 600 the file and fully relaunch your Claude client."
        )
    return (base, key)


def metabase_request(method: str, endpoint: str, body) -> str:
    env = _read_env()
    if env[0] is None:
        return f"error: {env[1]}"
    base, key = env

    if not endpoint.startswith("/"):
        endpoint = "/" + endpoint
    url = f"{base}/api{endpoint}"

    data = None
    if body is not None and body != "":
        if isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = json.dumps(body).encode("utf-8")

    try:
        req = urllib.request.Request(
            url,
            data=data,
            method=method.upper(),
            headers={
                "x-api-key": key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
    except ValueError as e:
        return (
            f"error: invalid URL '{url}' ({e}). "
            f"This usually means METABASE_BASE_URL was not substituted by the "
            f"host — check that your Cowork/Claude Code config actually sets "
            f"METABASE_BASE_URL where ${{...}} substitution can find it."
        )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except ValueError as e:
        return f"error: invalid URL '{url}' ({e})"
    except urllib.error.HTTPError as e:
        body_text = ""
        try:
            body_text = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        return f"HTTP {e.code} {e.reason}: {body_text}"
    except urllib.error.URLError as e:
        return f"network error: {e.reason}"
    except Exception as e:  # pragma: no cover
        return f"unexpected error: {type(e).__name__}: {e}"


TOOLS = [
    {
        "name": "query",
        "description": (
            "Call any Metabase REST API endpoint. The endpoint is relative to "
            "/api (e.g. '/user/current', '/card/153', '/dataset'). Returns the "
            "raw response body as text — usually JSON. Use this for everything: "
            "listing collections, reading/updating cards and dashboards, running "
            "ad-hoc SQL via POST /dataset, fetching schema metadata, etc. "
            "See https://www.metabase.com/docs/latest/api-documentation for the "
            "full endpoint catalog."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "method": {
                    "type": "string",
                    "enum": ["GET", "POST", "PUT", "DELETE", "PATCH"],
                    "description": "HTTP method.",
                },
                "endpoint": {
                    "type": "string",
                    "description": "Path relative to /api, e.g. '/card/153'.",
                },
                "body": {
                    "description": (
                        "Optional request body. Pass an object to be JSON-encoded, "
                        "or a string to be sent as-is."
                    ),
                },
            },
            "required": ["method", "endpoint"],
            "additionalProperties": False,
        },
    },
]


def _result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle(request: dict):
    method = request.get("method")
    rid = request.get("id")
    params = request.get("params") or {}

    if method == "initialize":
        return _result(
            rid,
            {
                "protocolVersion": PROTOCOL_VERSION,
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "capabilities": {"tools": {}},
            },
        )

    if method in ("notifications/initialized", "initialized"):
        return None  # notifications get no response

    if method == "tools/list":
        return _result(rid, {"tools": TOOLS})

    if method == "tools/call":
        tool_name = params.get("name")
        args = params.get("arguments") or {}
        if tool_name == "query":
            text = metabase_request(
                args.get("method", "GET"),
                args.get("endpoint", ""),
                args.get("body"),
            )
            return _result(
                rid,
                {"content": [{"type": "text", "text": text}], "isError": False},
            )
        return _error(rid, -32601, f"Unknown tool: {tool_name}")

    if method == "ping":
        return _result(rid, {})

    return _error(rid, -32601, f"Method not found: {method}")


def main() -> int:
    _log(f"starting {SERVER_NAME} v{SERVER_VERSION}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            _log(f"bad json: {e}")
            continue
        try:
            resp = handle(req)
        except Exception as e:  # pragma: no cover
            resp = _error(req.get("id"), -32603, f"internal error: {e}")
        if resp is not None:
            _send(resp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
