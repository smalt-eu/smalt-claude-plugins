# Metabase plugin

Lets Claude (Cowork or Claude Code) query and manage a Metabase instance via
its REST API. Ships:

- An **MCP server** (`servers/metabase.py`) that exposes a single generic
  `query` tool — pick any HTTP method + endpoint, get the response body.
- A **skill** (`skills/metabase/`) that teaches Claude when and how to use
  the tool, including card/dashboard schema, ad-hoc SQL via `/dataset`, and
  smalt-specific database IDs.

## Why this plugin reads credentials from a file

Cowork's plugin `userConfig` mechanism (the documented way to wire
secrets into an MCP server's env) is currently broken end-to-end on Cowork
desktop — see open issues
[#39125](https://github.com/anthropics/claude-code/issues/39125),
[#39455](https://github.com/anthropics/claude-code/issues/39455),
[#39827](https://github.com/anthropics/claude-code/issues/39827). To
sidestep all of it, the MCP server reads credentials from a sidecar file
in your home directory. Same approach pi developers use, and it Just
Works in both Cowork and Claude Code.

## Requirements

- Python 3.8+ (default on macOS — `python3 --version` to confirm)
- A Metabase API key (Admin → Authentication → API Keys)
- Network access from your machine to your Metabase instance

## Setup

### 1. Create your credentials file

Open Terminal and run:

```bash
mkdir -p ~/.config/smalt
chmod 700 ~/.config/smalt
nano ~/.config/smalt/metabase.env
```

In the editor, paste these two lines (replace the key with your own):

```
METABASE_BASE_URL=https://metabase.smalt.eu
METABASE_API_KEY=mb_your_key_here
```

Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`. Lock the file down:

```bash
chmod 600 ~/.config/smalt/metabase.env
```

To verify:

```bash
ls -la ~/.config/smalt/metabase.env   # should show -rw-------
```

### 2. Install the plugin

**Cowork (recommended path).** Open Cowork → click the plugin browser /
marketplaces icon → find the smalt marketplace → install `metabase`.
After installing, fully quit Cowork (`Cmd+Q`) and relaunch so the MCP
server is spawned with the new install.

**Claude Code CLI.** From a terminal:

```bash
claude plugin marketplace add smalt-eu/smalt-claude-plugins
claude plugin install metabase@smalt-eu/smalt-claude-plugins
```

### 3. Sanity-check

Open a fresh Cowork conversation and ask Claude:

> Use the metabase skill to call `GET /user/current` and tell me which
> Metabase user the API key is bound to.

You should get a small JSON blob with your user's email and group
memberships. If you see `missing METABASE_BASE_URL and METABASE_API_KEY
...`, the sidecar file isn't being found at `~/.config/smalt/metabase.env`
— check the file path and permissions. If you see `network error: ...`,
the file is read but the request can't reach Metabase — typically a VPN,
DNS, or firewall thing on your end.

### Alternative: process environment variables

If you'd rather not put the key in a file (e.g., on a shared machine
where you set creds via a secrets manager), the server also reads
`METABASE_BASE_URL` and `METABASE_API_KEY` from its process environment.
Process env takes precedence over the sidecar file on a per-variable
basis — useful for overriding `METABASE_BASE_URL` while keeping the key
in the file, etc. Note that Cowork (currently) does not propagate user
shell env to MCP server processes; this path mainly helps Claude Code
CLI users.

## What's in the box

```
metabase/
├── .claude-plugin/
│   └── plugin.json     # plugin manifest
├── .mcp.json           # MCP server declaration (no env block — server reads its own)
├── servers/
│   └── metabase.py     # stdio MCP server, stdlib only, ~190 lines
├── skills/
│   └── metabase/
│       └── SKILL.md    # skill body
└── README.md
```

The MCP server itself has zero dependencies — it implements the
JSON-RPC 2.0 / MCP handshake against `python3` stdlib (`urllib.request`
for HTTP).

## Security notes

- `~/.config/smalt/metabase.env` stores the API key in plain text. `chmod
  600` keeps other users on your machine out, but anyone with shell
  access as you can read it. For higher-security setups, switch to the
  process-env path and inject the key from a secrets manager (1Password
  CLI, vault, etc.).
- The sidecar file location is fixed to `~/.config/smalt/metabase.env`.
  If you want it elsewhere, edit the `CREDENTIALS_FILE` constant near
  the top of `servers/metabase.py` and reinstall.
