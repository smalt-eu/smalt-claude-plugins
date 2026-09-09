# platform plugin

Lets Claude (Cowork or Claude Code) **read the documents attached to a
smalt project** — quotes, grid-registration forms, installer photos and
schematics — instead of working from what a portal page happens to show.
Ships:

- An **MCP server** (`servers/platform.py`) exposing a single
  `fetch_document` tool: it downloads one document to a local file and
  returns the path, so Claude's `Read` can render the image or PDF.
- A **skill** (`skills/platform/SKILL.md`) that teaches Claude when to use
  it, how to find documents in the first place, and the rules for handling
  their contents.

## What it deliberately does not do

No `list_documents`, no `find_project`. The `metabase` plugin already
queries the `documents` and `projects` tables, and a second implementation
of "what is a document" would drift from the first. This plugin does the
one thing Metabase cannot: fetch the bytes.

So **install `metabase` too** — the two are meant to be used together, and
the skill tells Claude to reach for it.

## Why this plugin reads credentials from a file

Cowork's plugin `userConfig` mechanism (the documented way to wire secrets
into an MCP server's env) is currently broken end-to-end on Cowork desktop
— see open issues
[#39125](https://github.com/anthropics/claude-code/issues/39125),
[#39455](https://github.com/anthropics/claude-code/issues/39455),
[#39827](https://github.com/anthropics/claude-code/issues/39827). To
sidestep all of it, the MCP server reads its credential from a sidecar file
in your home directory. Same approach as the `metabase` plugin, and it Just
Works in both Cowork and Claude Code.

## Why a refresh token and not an API key

There is no personal-access-token mechanism in the platform, and this
plugin doesn't add one — it reuses the ordinary login credentials you
already have.

The file holds your **refresh token**, not an access token. That is the
better half of the pair to store:

- It is useless on its own — spending it requires a round-trip to our API.
- It **rotates**: every exchange returns a new one, which the server writes
  back to the file atomically. Use the plugin at least once every 30 days
  and it never expires.
- It is **revocable**. Bumping a person's `partner_users.version` in the
  database invalidates their access *and* refresh tokens immediately, on
  both the request path and the refresh path.

The access token is held in memory for the life of the server process and
never touches disk.

**The token is per person.** Not shared, not committed, not a shared
Bitwarden item. Note that the platform keeps no server-side record of which
documents were downloaded, so a shared token would be untraceable — one
more reason not to share one.

## Requirements

- Python 3.8+ (default on macOS — `python3 --version` to confirm)
- A smalt platform login, with the `SUPER_ADMIN` role
- Network access from your machine to `https://api2.smalt.eu`
- The `metabase` plugin, for finding the documents to fetch

## Setup

### 1. Install your credential

**This one does not come from Bitwarden.** The vault script
(`install-credentials.sh`) installs *static* secrets; this token rotates on
every use, so a vault copy would be dead the moment the plugin first
refreshed — and worse, the installer would offer to overwrite your live
token with the dead one. The workstation launcher asks for your Smalt email
and password once instead, and exchanges them for a token.

To do it by hand — one call, which returns the refresh token directly:

Save this as `get-token.py` somewhere temporary:

```python
import getpass, json, urllib.request

email = input("smalt email: ")
password = getpass.getpass("smalt password: ")
req = urllib.request.Request(
    "https://api2.smalt.eu/api/v1/auth/login",
    data=json.dumps({"email": email, "password": password}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
print(json.load(urllib.request.urlopen(req))["refresh_token"])
```

then:

```bash
mkdir -p ~/.config/smalt
python3 get-token.py > ~/.config/smalt/platform.token
chmod 600 ~/.config/smalt/platform.token
rm get-token.py
```

The password is never stored — it is exchanged once for the token and
discarded.

Or, if you already have a token from elsewhere, paste it on its own line:

```bash
mkdir -p ~/.config/smalt
pbpaste > ~/.config/smalt/platform.token     # or open the file and paste
chmod 600 ~/.config/smalt/platform.token
```

The whole file is treated as the token — no `KEY=value` syntax, no
comments, no quotes.

Verify it before involving Claude at all. The `--check` and `--purge`
commands below are run against `servers/platform.py` — from a clone of this
repo before installing, or from the installed plugin's directory
afterwards:

```bash
python3 servers/platform.py --check
```

```
OK    token valid at https://api2.smalt.eu
      user    arne@smalt.eu
      partner smalt
      roles   SUPER_ADMIN
      expires 2026-10-09T14:22:31+00:00
      cache   /Users/arne/.cache/smalt/documents
```

`--check` performs a real token exchange, so it also rotates and re-saves
your token. It never prints the token itself.

### 2. Install the plugin

**Cowork (recommended path).** Open Cowork → click the plugin browser /
marketplaces icon → find the smalt marketplace → install `platform`. After
installing, fully quit Cowork (`Cmd+Q`) and relaunch so the MCP server is
spawned with the new install.

**Claude Code CLI.** From a terminal:

```bash
claude plugin marketplace add smalt-eu/smalt-claude-plugins
claude plugin install platform@smalt-eu/smalt-claude-plugins
```

### 3. Sanity-check

Open a fresh Cowork conversation and ask Claude:

> Use the platform and metabase skills: list the documents on project 7842,
> then show me the quote.

You should get a document list from SQL, then Claude fetching the `offer`
PDF and reading the equipment out of it. If you see `missing
SMALT_API_TOKEN`, the sidecar file isn't being found at
`~/.config/smalt/platform.token` — check the path and permissions. If you
see `network error`, the file is read but the request can't reach the API —
typically a VPN, or Cowork's network egress allowlist.

## Cached documents are customer PII

Downloads land in `~/.cache/smalt/documents/<project_id>/`, file mode 600
inside a 700 directory. They contain customer names, addresses, meter
numbers and photos of people's homes, and **nothing deletes them
automatically**.

```bash
python3 servers/platform.py --purge            # delete older than 7 days
python3 servers/platform.py --purge --days 0   # delete everything
```

Worth putting on a weekly cron if you use this regularly.

## Environment overrides

| Variable | Effect |
|---|---|
| `SMALT_API_TOKEN` | Use this refresh token instead of the file. When set, the server will **not** write a rotated token back — you are managing the credential yourself. |
| `SMALT_API_BASE_URL` | Point at staging or a local dev server instead of `https://api2.smalt.eu`. |

## What it talks to

Existing endpoints, all unchanged by this plugin:

- `POST /api/v1/auth/login` — `{email, password}` returns the refresh token
  directly, in one call. Used only for the one-off setup above; the plugin
  itself never sees a password.
- `POST /api/v1/auth/refresh-token` — trades the refresh token for an
  access token, and returns a rotated refresh token.
- `GET /api/v1/file-upload/documents/{id}` and
  `GET /api/v1/file-upload/documents/{id}/signed-url` — metadata (which is
  also where the `project_id` check happens), then a one-hour signed GCS
  URL that the plugin downloads immediately.

The bytes go straight from Google Cloud Storage to your machine; they do
not pass through the API.
