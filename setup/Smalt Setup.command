#!/bin/bash
#
# Smalt Setup.command — double-click this file.
#
# Asks for your Bitwarden master password in a normal macOS dialog, then writes
# the credential files this workstation needs. Nothing to type but the password.
#
# A launcher, not logic: the work is install-credentials.sh, which takes each
# secret from `bw` straight into its destination file. Your password goes from
# the dialog into one process's environment and nowhere else — never to disk,
# never echoed, never in argv (so it cannot be read out of `ps`).
#
set -uo pipefail
umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.homebrew/bin:$HOME/bin:$PATH"
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

SELF=${BASH_SOURCE[0]##*/}
# Ships with the plugin that uses it, not with this launcher.
LOGIN_SCRIPT=../smalt-documents/scripts/platform-login.py
TITLE="Smalt Workstation Setup"
EU_SERVER="https://vault.bitwarden.eu"
ESC=$(printf '\033')
UNLOCKED_BY_US=0

printf '%s\nFolder: %s\n\n' "$TITLE" "$(pwd)"
[ -f ./_dialogs.sh ] || { printf '\n_dialogs.sh is missing from this folder.\n\n' >&2; exit 1; }
. ./_dialogs.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/grids-setup.XXXXXX") || exit 1
cleanup() { [ "$UNLOCKED_BY_US" = 1 ] && bw lock >/dev/null 2>&1; unset BW_SESSION 2>/dev/null; UNLOCKED_BY_US=0; return 0; }
finish()  { cleanup; rm -rf "$WORK"; dialogs_cleanup; }
trap finish EXIT INT TERM
bail()    { cleanup; printf '\n%s\n\n' "$(printf '%b' "$1")"; stop "$1"; exit 1; }
quit()    { printf 'Cancelled.\n'; exit 0; }

dialogs_available || hard "Run the setup from Terminal instead:\n    cd $(pwd)\n    export BW_SESSION=\"\$(bw unlock --raw)\"\n    ./install-credentials.sh"

# ------------------------------------------------------------- which stages --
# The two credentials are independent and must stay that way: the Metabase key
# comes out of Bitwarden, the smalt platform token out of a login. Someone who
# only wants the `smalt-documents` plugin should never need `bw`, so a missing
# Bitwarden CLI skips that stage instead of ending the run.
BW_STAGE=1; bwskip=""
if ! command -v bw >/dev/null 2>&1; then
  BW_STAGE=0
  bwskip="Metabase key: skipped — the Bitwarden command-line tool is not installed on this Mac.\n\nOnly the metabase plugin needs it. To add it later:\n    brew install bitwarden-cli\nthen double-click $SELF again."
elif [ ! -f ./install-credentials.sh ]; then
  BW_STAGE=0
  bwskip="Metabase key: skipped — install-credentials.sh is missing from\n$(pwd)"
fi

if [ "$BW_STAGE" -eq 1 ]; then
  WHICH=$(choose \
"This sets up the credential files the smalt plugins need.\n\nEverything — the Metabase key from your Bitwarden vault (asks for your master password once), and a smalt platform login.\n\nSmalt login only — just the login for reading project documents. No Bitwarden password needed." \
"Everything" "Smalt login only")
  [ -n "$WHICH" ] || quit
  if [ "$WHICH" = "Smalt login only" ]; then
    BW_STAGE=0
    bwskip="Metabase key: not requested this time.\n\nDouble-click $SELF again and choose Everything if you want it."
  fi
fi

if [ "$BW_STAGE" -eq 1 ]; then
  MODE=$(choose \
"Check only — reports what would happen, changes nothing.\nSet up now — writes the files.\n\nYou will be asked for your Bitwarden master password once." \
"Check only" "Set up now")
else
  MODE=$(choose \
"Setting up the smalt platform login only.\n\nCheck only — reports whether a login is already installed, changes nothing.\nSet up now — asks for your smalt email and password." \
"Check only" "Set up now")
fi
[ -n "$MODE" ] || quit
DRY=""; [ "$MODE" = "Check only" ] && DRY="--dry-run"

if [ "$BW_STAGE" -eq 1 ]; then    # ── Bitwarden half ──
raw=$(bw status 2>/dev/null)
status=$(printf '%s' "$raw" | sed -n 's/.*"status":[[:space:]]*"\([a-z]*\)".*/\1/p')
server=$(printf '%s' "$raw" | sed -n 's/.*"serverUrl":[[:space:]]*"\([^"]*\)".*/\1/p')

if [ "$status" = "unauthenticated" ] || [ -z "$status" ]; then
  # Smalt's organisation is on the EU cloud. Against the US endpoint (the
  # default) login fails with an error that reads like a wrong password. Must be
  # set before logging in; it cannot be changed while logged in.
  bw config server "$EU_SERVER" >/dev/null 2>&1 || bail \
"Could not point the Bitwarden CLI at the EU server.\n\n$EU_SERVER\n\nIf this Mac is logged in to a different Bitwarden account, run 'bw logout' in Terminal first."

  email=$(ask "First time on this Mac.\n\nYour Bitwarden email address:") || true
  [ -n "$email" ] || quit
  pw=$(askpw "Bitwarden master password for $email:") || true
  [ -n "$pw" ] || quit

  out=$(BW_PASSWORD="$pw" bw login "$email" --passwordenv BW_PASSWORD --raw 2>&1)
  if printf '%s' "$out" | grep -qi 'two-step\|two factor\|2fa'; then
    m=$(choose "Your account uses two-step login.\n\nWhere does your code come from?" "Emailed to me" "Authenticator app")
    [ -n "$m" ] || { unset pw; quit; }
    method=0
    if [ "$m" = "Emailed to me" ]; then
      method=1
      BW_PASSWORD="$pw" bw login "$email" --passwordenv BW_PASSWORD --method 1 --raw >/dev/null 2>&1
    fi
    code=$(ask "Enter your two-step login code:") || true
    [ -n "$code" ] || { unset pw; quit; }
    out=$(BW_PASSWORD="$pw" bw login "$email" --passwordenv BW_PASSWORD --method "$method" --code "$code" --raw 2>&1)
  fi
  unset pw
  if printf '%s' "$out" | grep -q '^[A-Za-z0-9+/=]\{40,\}$'; then
    BW_SESSION=$out; UNLOCKED_BY_US=1
  else
    bail "Bitwarden could not log you in.\n\n$(printf '%s' "$out" | head -c 400)"
  fi

elif [ "$status" = "locked" ]; then
  case "$server" in
    "$EU_SERVER"|"$EU_SERVER"/|"") : ;;
    *) warn "Heads up: this Mac's Bitwarden CLI points at\n\n$server\n\nSmalt's organisation is on $EU_SERVER.\n\nIf the unlock fails, that is why — run 'bw logout' in Terminal and start again." ;;
  esac
  pw=$(askpw "Your Bitwarden master password:") || true
  [ -n "$pw" ] || quit
  BW_SESSION=$(BW_PASSWORD="$pw" bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null)
  unset pw
  [ -n "$BW_SESSION" ] || bail "That password did not unlock the vault.\n\nDouble-click $SELF to try again."
  UNLOCKED_BY_US=1

else
  [ -n "${BW_SESSION:-}" ] || bail \
"Your vault reports itself unlocked, but this window has no session key.\n\nRun 'bw lock' in Terminal once, then double-click this file again."
fi
export BW_SESSION

printf '\n'
LOG="$WORK/run.log"
bash ./install-credentials.sh $DRY 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Strip colour codes and drop progress chatter, or the results get pushed out.
digest() {
  sed "s/${ESC}\[[0-9;]*m//g" "$1" | grep -E '^(installed=|  [·✓✗!])' \
    | grep -vE 'syncing your vault|looking for items|looking for the credentials|credential\(s\) found|narrowing to' | tail -12
}
summary=$(digest "$LOG")

# ---------------------------------------------------------------- Bitwarden --
# Collect a result line rather than showing a dialog per stage; the platform
# login runs next and the person should get one summary, not three.
bwmsg=""; bwok=0
if [ "$rc" -eq 0 ]; then
  bwok=1; bwmsg="Vault credentials: OK\n\n$summary"
elif [ "$rc" -eq 5 ]; then
  # A local file differs from the vault. Never overwrite on a guess — the local
  # copy may be the newer one — so ask.
  again=$(choose "One or more credential files on this Mac differ from the vault.\n\nThat is normal if someone updated the vault. It is also what you would see if your local file is newer. Nothing has been changed.\n\n$summary" "Keep mine" "Use the vault's")
  if [ "$again" = "Use the vault's" ]; then
    L2="$WORK/force.log"
    bash ./install-credentials.sh --force 2>&1 | tee "$L2"
    rc2=${PIPESTATUS[0]}; s2=$(digest "$L2")
    if [ "$rc2" -eq 0 ]; then bwok=1; bwmsg="Vault credentials: replaced from the vault\n\n$s2"
    else bwmsg="Vault credentials: replacing FAILED (exit $rc2)\n\n$s2"; fi
  else
    bwok=1   # keeping your own files is a decision, not a failure
    bwmsg="Vault credentials: left as they were, nothing changed."
  fi
elif [ "$rc" -eq 4 ]; then
  bwmsg="Vault credentials: NOT FOUND.\n\nThe window behind this dialog says which one is missing and what name it looked for. Usually this means you do not yet have access to the Grids/Workstation Setup collection."
else
  bwmsg="Vault credentials: finished with problems (exit $rc).\n\n$summary"
fi

cleanup     # Bitwarden is done with; lock the vault before anything else
else
  bwmsg="$bwskip"; bwok=1   # skipped on purpose, not a failure
fi

# ----------------------------------------------------------- platform login --
# The smalt API refresh token. Deliberately NOT installed from Bitwarden: it
# rotates on every use, so a vault copy is dead after the first refresh and the
# conflict path above would offer to overwrite a live token with a dead one.
platmsg=""; platok=0
if [ ! -f "$LOGIN_SCRIPT" ]; then
  platmsg="Smalt platform login: skipped — cannot find\n$LOGIN_SCRIPT\n\nIt ships with the smalt-documents plugin; run this launcher from a full checkout of smalt-claude-plugins."
elif ! command -v python3 >/dev/null 2>&1; then
  platmsg="Smalt platform login: skipped — python3 not found."
else
  printf '\n\nSmalt platform login\n'
  chk=$(python3 "$LOGIN_SCRIPT" --check 2>&1); crc=$?
  printf '  %s\n' "$chk"

  if [ -n "$DRY" ]; then
    platok=1     # a check changes nothing, so it cannot fail
    [ "$crc" -eq 0 ] && platmsg="Smalt platform login: already set up.\n$chk" \
                     || platmsg="Smalt platform login: not set up yet.\n\nRun $SELF again and choose Set up now to log in."
  elif [ "$crc" -eq 0 ]; then
    relog=$(choose "You are already logged in to the smalt platform on this Mac.\n\n$chk\n\nNothing needs doing unless you want to sign in as someone else." "Leave it" "Log in again")
    if [ "$relog" = "Log in again" ]; then crc=4; else
      platok=1; platmsg="Smalt platform login: left as it is.\n$chk"
    fi
  fi

  if [ -z "$DRY" ] && [ "$crc" -ne 0 ]; then
    email=$(ask "Smalt platform login.\n\nThis lets Claude read the documents attached to a project — quotes, grid-registration forms, installer photos.\n\nYour smalt email address:") || true
    if [ -z "$email" ]; then
      platok=1   # declining is a choice; the message says it is not done
      platmsg="Smalt platform login: skipped. Double-click $SELF again when you want to set it up."
    else
      pw=$(askpw "Smalt password for $email:") || true
      if [ -z "$pw" ]; then
        platok=1
        platmsg="Smalt platform login: skipped, no password entered."
      else
        PLOG="$WORK/platform.log"
        # Password goes into the environment of this one process and nowhere
        # else — never argv, so it cannot be read out of `ps`.
        SMALT_PASSWORD="$pw" python3 "$LOGIN_SCRIPT" --email "$email" 2>&1 | tee "$PLOG"
        prc=${PIPESTATUS[0]}
        unset pw
        pout=$(cat "$PLOG")
        case $prc in
          0) platok=1; platmsg="Smalt platform login: OK\n\n$pout" ;;
          1) platmsg="Smalt platform login: refused.\n\n$pout\n\nDouble-click $SELF to try again." ;;
          3) platmsg="Smalt platform login: could not reach the server.\n\n$pout\n\nCheck your connection and try again." ;;
          *) platmsg="Smalt platform login: failed (exit $prc).\n\n$pout" ;;
        esac
      fi
    fi
  fi
fi

# ------------------------------------------------------------------ summary --
if [ -n "$DRY" ]; then
  say "Check complete — nothing was changed.\n\n$bwmsg\n\n$platmsg\n\nDouble-click $SELF again and choose Set up now to apply."
elif [ "$bwok" -ne 1 ] || [ "$platok" -ne 1 ]; then
  stop "Setup finished, but not everything worked.\n\n$bwmsg\n\n$platmsg\n\nThe window behind this dialog has the detail."
else
  # Only claim the vault was locked if we actually unlocked one.
  if [ "$BW_STAGE" -eq 1 ]; then
    say "Setup complete. Your Bitwarden vault has been locked again.\n\n$bwmsg\n\n$platmsg"
  else
    say "Setup complete.\n\n$bwmsg\n\n$platmsg"
  fi
fi
