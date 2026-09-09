#!/usr/bin/env bash
#
# install-credentials.sh — write this workstation's credential files from the
#                          Bitwarden vault, so a new team member can set
#                          themselves up without being handed a secret.
#
# WHAT GETS INSTALLED — hard-coded, see the CREDENTIALS table below
#   ~/.config/smalt/metabase.key             the Metabase API key
#   ~/.config/smalt/bitwarden-grids.token    the read-only Secrets Manager token
#
# HOW EACH ONE IS FOUND — two shapes, no configuration either way
#   1. A CUSTOM FIELD whose name matches, on any login item. This is the
#      one-item shape: a single "Workstation Setup" item carrying both secrets
#      as named (ideally hidden) fields.
#   2. Failing that, a LOGIN ITEM whose own name matches, using its password.
#      This is the item-per-secret shape.
#   Matching ignores case, spaces, dots, slashes and hyphens, so "Metabase API
#   Key", "metabase.key" and "METABASE-KEY" are all the same thing.
#
#   To add a credential, add one row to the table. That is a deliberate trade:
#   an earlier version let each vault item declare its own destination path in
#   its notes, which needed no code change but meant a mistyped notes line
#   silently installed nothing. Two known files are not worth that failure mode.
#
# WHY THE SECRET NEVER PASSES THROUGH CLAUDE
#   The value goes from `bw` straight into the destination file. It is never
#   printed, never placed in argv, and never returned on stdout. Claude can run
#   this and read the output without learning a secret: the output is names,
#   paths, byte counts and OK/FAIL.
#
# USAGE
#   export BW_SESSION="$(bw unlock --raw)"    # you type YOUR master password
#   ./install-credentials.sh [--dry-run] [--force] [--list] [--inventory]
#
#   --list       what this script installs and the names it looks for
#   --inventory  what your vault holds: item names, types, custom field NAMES.
#                Never values, never notes — safe to paste to a colleague.
#
# WHAT IT WILL NOT DO
#   * Overwrite a file whose content already matches — reported as "unchanged".
#   * Overwrite a differing file without --force. That exits 5, so a caller can
#     tell it apart from success.
#   * Guess, when two things match. It lists them and stops.
#
# EXIT CODES — the launcher's contract
#   0 all good   1 a write failed   3 preconditions   4 credential not found
#   5 a local file differs and --force was not given
#
set -euo pipefail
set +x
umask 077          # every file this script creates is 0600 from birth

PROG=${0##*/}
DRY=0; FORCE=0; LIST=0; INVENTORY=0

die()  { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  · %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)   DRY=1; shift ;;
    --force)     FORCE=1; shift ;;
    --list)      LIST=1; shift ;;
    --inventory) INVENTORY=1; shift ;;
    -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//; $d'; exit 0 ;;
    *) die "unknown option $1" 2 ;;
  esac
done

# ---------------------------------------------------------------- the table --
# Which credentials to install, and how to recognise them in the vault. Kept in
# `credentials.conf` beside this script rather than in it, so that different
# checkouts can install different sets while running byte-identical code — one
# fewer thing to drift.
#
#   <destination> | <mode> | <name needles, most specific first, ';' separated>
#
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
CONF="$HERE/credentials.conf"
if [[ -f $CONF ]]; then
  # `|| true`: grep exits 1 when a file is all comments, and `set -e` would
  # kill the script there with no message instead of the explanation below.
  CREDENTIALS=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" || true)
  CRED_SOURCE="credentials.conf"
else
  CREDENTIALS='~/.config/smalt/metabase.key|600|metabase api key;metabase key;metabase'
  CRED_SOURCE="built-in default (no credentials.conf found)"
fi
[[ -n ${CREDENTIALS//[[:space:]]/} ]] || die "credentials.conf is empty — nothing to install" 2

TOTAL=$(printf '%s\n' "$CREDENTIALS" | wc -l | tr -d ' ')

if [[ $LIST == 1 ]]; then
  printf '\nCredentials this script installs (from %s):\n\n' "$CRED_SOURCE"
  printf '%s\n' "$CREDENTIALS" | while IFS='|' read -r path mode needles; do
    printf '  %-42s mode %s\n      found by a custom field or item named: %s\n' \
      "$path" "$mode" "${needles//;/, }"
  done
  printf '\n'
  exit 0
fi

command -v bw >/dev/null      || die "bw is not installed. See the onboarding doc." 3
command -v python3 >/dev/null || die "python3 not on PATH" 3
[[ -n ${BW_SESSION:-} ]] || die \
  "BW_SESSION is not set. Unlock your vault first:
    export BW_SESSION=\"\$(bw unlock --raw)\"
  You type your own master password; it is not stored anywhere." 3

# Item names, types and custom field NAMES. Never values, never notes.
inventory() {
  bw list items 2>/dev/null | python3 -c '
import json, sys
try: items = json.load(sys.stdin)
except Exception: sys.exit(0)
KIND = {1:"login", 2:"note", 3:"card", 4:"identity"}
HINT = ("workstation","token","key","api","metabase","secret","setup","bws","bitwarden")
c = [i for i in items if any(h in (i.get("name") or "").lower() for h in HINT)]
if not c:
    print("      Nothing in your vault has a name suggesting a workstation credential.")
else:
    print("      %-40s %-8s %-4s %s" % ("ITEM","TYPE","PW","CUSTOM FIELD NAMES"))
    for i in c[:40]:
        f = [(x.get("name") or "?") for x in (i.get("fields") or [])]
        print("      %-40s %-8s %-4s %s" % ((i.get("name") or "?")[:40],
              KIND.get(i.get("type"),"?"),
              "yes" if ((i.get("login") or {}).get("password")) else "no",
              ", ".join(f) if f else "-"))
    if len(c) > 40: print("      ... and %d more" % (len(c)-40))
print()
print("      %d items visible. No secret and no note text is shown above." % len(items))
' || printf '      (could not read the vault)\n'
}

if [[ $INVENTORY == 1 ]]; then
  printf '\nWhat your Bitwarden vault holds\n\n'; inventory; printf '\n'; exit 0
fi

status=$(bw status 2>/dev/null | sed -n 's/.*"status":[[:space:]]*"\([a-z]*\)".*/\1/p') || true
[[ $status == unlocked ]] || die "vault status is '${status:-unknown}', expected 'unlocked'" 3

printf '\nInstalling workstation credentials from Bitwarden\n'
info "syncing your vault"
bw sync >/dev/null 2>&1 || info "sync failed; using the local cache"
info "looking for the credentials"

PLAN=$(mktemp "${TMPDIR:-/tmp}/smalt-install.XXXXXX")
trap 'rm -f "$PLAN"' EXIT INT TERM

# The vault JSON (which contains secrets) goes straight into python and never
# lands in a shell variable. Python emits one plan line per resolved credential:
#   id <TAB> path <TAB> mode <TAB> where-it-came-from <TAB> field-name-or-empty
set +e
bw list items 2>/dev/null | CREDS="$CREDENTIALS" python3 -c '
import json, os, re, sys

# Compare on letters and digits only, so punctuation and spacing never matter.
def key(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())

try:
    items = json.load(sys.stdin)
except Exception:
    sys.stderr.write("  could not read the vault\n"); sys.exit(4)

logins = [i for i in items if i.get("type") == 1]
missing = 0

for row in os.environ["CREDS"].strip().split("\n"):
    path, mode, needles = row.split("|")
    path  = os.path.expanduser(path)
    label = os.path.basename(path)
    found = clash = None

    for nd in [n for n in needles.split(";") if n]:
        k = key(nd)
        # 1. a custom field whose NAME matches, on any login item
        hits = [(i, f) for i in logins for f in (i.get("fields") or [])
                if k in key(f.get("name")) and (f.get("value") or "").strip()]
        # 2. otherwise a login item whose OWN name matches, using its password
        if not hits:
            hits = [(i, None) for i in logins
                    if k in key(i.get("name"))
                    and ((i.get("login") or {}).get("password") or "").strip()]
        if len(hits) == 1: found = hits[0]; break
        if len(hits) >  1: clash = (nd, hits); break

    if found:
        item, field = found
        where = ("%s -> field \"%s\"" % (item.get("name","?"), field.get("name"))) if field \
                else ("%s -> password" % item.get("name","?"))
        print("\t".join([item["id"], path, mode, where, (field.get("name") if field else "")]))
        continue

    missing += 1
    if clash:
        sys.stderr.write("  ! %s: %d things match \"%s\" — refusing to guess:\n"
                         % (label, len(clash[1]), clash[0]))
        for i, f in clash[1]:
            sys.stderr.write("      %s%s\n" % (i.get("name","?"),
                             (" -> field \"%s\"" % f.get("name")) if f else " -> password"))
    else:
        sys.stderr.write("  ! %s: not found.\n"
                         "      Looked for a custom field, or an item, named: %s\n"
                         % (label, ", ".join(needles.split(";"))))
sys.exit(4 if missing else 0)
' > "$PLAN"
resolve_rc=$?
set -e

count=$(wc -l < "$PLAN" | tr -d ' ')
if [[ ${count:-0} -eq 0 ]]; then
  bad "none of the credentials could be found."
  printf '\n  Each one needs either a CUSTOM FIELD named after it (on any login\n'
  printf '  item — one "Workstation Setup" item with two fields is ideal), or its\n'
  printf '  own login item with the secret in the password field.\n\n'
  printf '  Suggested custom field names on a single item:\n'
  printf '      metabase.key\n'
  printf '      bitwarden-grids.token\n\n'
  printf '  This is what your vault actually holds:\n\n'
  inventory
  printf '\n  If nothing above looks right, you may not have access to the\n'
  printf '  Grids/Workstation Setup collection yet.\n\n'
  exit 4
fi
info "$count of $TOTAL credential(s) found"
printf '\n'

installed=0; unchanged=0; skipped=0; failed=0

while IFS=$'\t' read -r id path mode where field; do
  [[ -n $id ]] || continue

  if [[ $DRY == 1 ]]; then
    info "would install $where -> $path (mode $mode)"
    continue
  fi

  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  chmod 700 "$(dirname "$path")" 2>/dev/null || true

  tmp="${path}.new.$$"
  # bw -> python -> file. The secret is never printed and never in argv.
  if ! bw get item "$id" 2>/dev/null | FIELD="$field" python3 -c '
import json, os, re, sys
def key(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())
d = json.load(sys.stdin)
want = os.environ.get("FIELD", "")
if want:
    v = ""
    for f in (d.get("fields") or []):
        if key(f.get("name")) == key(want):
            v = f.get("value") or ""; break
else:
    v = (d.get("login") or {}).get("password") or ""
if not v.strip():
    sys.exit(1)
sys.stdout.write(v.rstrip("\r\n") + "\n")
' > "$tmp" 2>/dev/null; then
    bad "$where: could not read the secret"
    rm -f "$tmp"; failed=$((failed+1)); continue
  fi

  if [[ ! -s $tmp ]]; then
    bad "$where: empty secret, not written"
    rm -f "$tmp"; failed=$((failed+1)); continue
  fi

  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; ok "$path (unchanged)"; unchanged=$((unchanged+1)); continue
  fi

  if [[ -f $path && $FORCE == 0 ]]; then
    rm -f "$tmp"
    bad "$path already exists with different content. Use --force to replace."
    skipped=$((skipped+1)); continue
  fi

  mv "$tmp" "$path"; chmod "$mode" "$path"
  ok "$path ($(wc -c < "$path" | tr -d ' ') bytes, mode $mode) — from $where"
  installed=$((installed+1))
done < "$PLAN"

if [[ $DRY == 1 ]]; then
  printf '\n  --dry-run: nothing written.\n\n'
  [[ $resolve_rc -eq 0 ]] || exit 4
  exit 0
fi

printf '\ninstalled=%d unchanged=%d skipped=%d failed=%d\n' \
  "$installed" "$unchanged" "$skipped" "$failed"
printf '\nThese files are yours alone: mode 600, in your home directory, and not\n'
printf 'synced anywhere. If this machine is lost, tell an admin so the tokens\n'
printf 'can be rotated.\n\n'

[[ $failed  -eq 0 ]]    || exit 1
[[ $skipped -eq 0 ]]    || exit 5
[[ $resolve_rc -eq 0 ]] || exit 4
exit 0
