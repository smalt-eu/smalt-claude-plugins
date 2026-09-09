# Workstation setup

One double-click that puts the credential files the smalt plugins need onto
your Mac. **No Terminal, no copy-paste, nothing to hand-edit.**

## What you do

Double-click **`Smalt Setup.command`** and answer the dialogs:

1. **Check only** or **Set up now** — "Check only" changes nothing, so it is
   always safe to run first.
2. Your **Bitwarden master password**, once, to read the shared credentials.
3. Your **smalt email and password**, once, to log in to the platform.

It writes the files, locks your Bitwarden vault again, and shows a summary.
Then **quit Cowork completely (`Cmd+Q`) and reopen it** so the plugins pick the
credentials up.

Run it again any time — it reports "unchanged" for anything already correct,
and never overwrites a file that differs without asking you first.

## What it installs

| File | For |
|---|---|
| `~/.config/smalt/metabase.key` | the `metabase` plugin |
| `~/.config/smalt/platform.token` | the `smalt-documents` plugin |

All at mode 600, in a 700 directory, on your machine only. Nothing is synced
anywhere.

Which Bitwarden-held credentials get installed is listed in
[`credentials.conf`](./credentials.conf), not hard-coded in the script — so a
different checkout can install a different set while running identical code.
`platform.token` is not in there because it is a rotating refresh token; the
launcher logs you in for that one.

## Order matters

Install the plugins **first**, then run this. The launcher sets up credentials
for plugins you already have.

## If something goes wrong

The Terminal window behind the dialog has the detail — it prints paths, byte
counts and OK/FAIL, never a secret, so it is safe to paste to a colleague.

| Message | Means |
|---|---|
| "The Bitwarden command-line tool is not installed" | ask an admin to run `brew install bitwarden-cli` |
| "Could not find the credentials in your vault" | you probably don't have access to the shared collection yet — ask an admin |
| "That password did not unlock the vault" | wrong master password, or your account is on the wrong Bitwarden region (smalt is on the **EU** cloud) |
| "login refused" | wrong smalt email or password |
| "Cannot show dialogs on this Mac" | rare; the window tells you the Terminal commands to run instead |

## Reading documents in Cowork

The `smalt-documents` plugin downloads documents to `~/.cache/smalt/documents/`.
**Cowork can only read folders you have attached in the Claude desktop app**, so
attach `~/.cache/smalt` once — otherwise a download reports success and then
Claude cannot open the file. Claude Code running natively on your Mac does not
need this.

## Where your passwords go

Each password goes from its dialog into the environment of a single process and
nowhere else. Never written to disk, never printed, never passed as a
command-line argument (so it cannot be read out of `ps`), and discarded as soon
as it has been exchanged for a token. Claude cannot type into these dialogs —
that is the point of them.

## Notes

* `platform.token` is a **refresh token that rotates on every use**, so it is
  deliberately *not* installed from Bitwarden — a stored copy would be stale
  after the first refresh. That is why the launcher asks you to log in.
* `install-credentials.sh`, `platform-login.py` and `_dialogs.sh` do the actual
  work; the `.command` file only asks the questions. Fix behaviour in the
  scripts, wording in the launcher.
* Run `./install-credentials.sh --list` to see exactly what this checkout will
  install and where it reads that from.
