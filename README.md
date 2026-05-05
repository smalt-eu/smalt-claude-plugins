# smalt Claude plugins

Internal Claude plugin marketplace for smalt. Lets people in the smalt
org install custom plugins (skills + MCP servers) into Cowork or Claude
Code from one centrally-managed source.

## Available plugins

| Plugin | What it does |
|--------|--------------|
| [`metabase`](./metabase) | Query and manage smalt's Metabase via its REST API. Reads credentials from `~/.config/smalt/metabase.key`. |

## Install a plugin (smalt employees)

The marketplace is already connected to smalt's Cowork org. To install a
plugin:

1. Open Cowork → plugin browser / marketplaces.
2. Find the `smalt` marketplace and pick the plugin you want.
3. Follow the per-plugin README's setup section (most plugins want a
   small one-off credentials file).
4. Fully quit Cowork (`Cmd+Q`) and relaunch.

For Claude Code CLI users:

```bash
claude plugin marketplace add smalt-eu/smalt-claude-plugins
claude plugin install <plugin-name>@smalt-eu/smalt-claude-plugins
```

## Add a new plugin (contributors)

Each plugin is a folder at the repo root with this layout:

```
<plugin-name>/
├── .claude-plugin/
│   └── plugin.json     # plugin manifest (name, version, description)
├── .mcp.json           # optional, MCP server declarations
├── README.md           # setup + usage for end users
├── servers/            # optional, MCP server implementations
└── skills/             # optional, skill markdown files
    └── <name>/SKILL.md
```

To add a plugin:

1. Create a new folder at the repo root.
2. Add the plugin's files using the layout above.
3. Add an entry to [`.claude-plugin/marketplace.json`](./.claude-plugin/marketplace.json):
   ```json
   {
     "name": "your-plugin",
     "source": "./your-plugin",
     "description": "What it does in one line",
     "version": "0.1.0",
     "keywords": ["..."]
   }
   ```
4. Open a PR. Once merged, Cowork resyncs and the plugin becomes
   available to install across the org.

### Plugin authoring conventions

- **Bash sandbox limits.** Cowork's bash sandbox is isolated; it doesn't
  inherit host env vars, has a read-only skill mount, and routes egress
  through an org-allowlist. Skills that talk to internal smalt services
  generally need to ship as MCP servers (host process), not as bash
  scripts. See `metabase/` for the pattern.
- **Credentials.** As of May 2026, Cowork's `userConfig` /
  `${user_config.X}` substitution path is broken end-to-end (open
  issues [#39125](https://github.com/anthropics/claude-code/issues/39125),
  [#39455](https://github.com/anthropics/claude-code/issues/39455),
  [#39827](https://github.com/anthropics/claude-code/issues/39827)).
  Read credentials from a sidecar file under `~/.config/smalt/<plugin>.env`
  in the MCP server itself instead — see `metabase/servers/metabase.py`
  for a worked example.
- **Network.** Internal smalt domains need to be added to the org's
  Cowork "Allow network egress" allowlist before MCP servers can reach
  them. Currently the allowlist is set to "All domains".
- **Versioning.** Plugins use semver in their own `plugin.json`; the
  marketplace `version` is the version of the marketplace as a whole.
  Bump plugin versions on each user-visible change.
- **No secrets in commits.** Plugins should never embed API keys,
  tokens, or any per-user credentials. Use the sidecar-file pattern.

## Repository layout

```
smalt-claude-plugins/
├── .claude-plugin/
│   └── marketplace.json     # marketplace manifest, lists plugins
├── .gitignore
├── README.md                # this file
└── <plugin-name>/           # one folder per plugin
    └── ...
```

## Org admin: how this marketplace is connected

For reference (most contributors won't need this):

1. The repo lives at `https://github.com/smalt-eu/smalt-claude-plugins`,
   private.
2. The Claude GitHub App is installed on the repo (GitHub org settings →
   GitHub Apps → Claude → repo access).
3. In Cowork org settings → Plugins → "Plugins hinzufügen" → "Von GitHub
   synchronisieren", the repo was registered as `smalt-eu/smalt-claude-plugins`.
4. Cowork auto-syncs on push.
