#!/bin/bash
#
# _dialogs.sh — native macOS dialogs for the smalt setup launchers. Source it; do not
#               run it. Requires TITLE to be set beforehand.
#
# THE RULE THIS FILE EXISTS TO ENFORCE
#   Dialog text is passed to AppleScript as ARGUMENTS, never spliced into
#   AppleScript source. Building `display dialog "..."` by string interpolation
#   breaks the moment a message contains a quoted word: the string closes early,
#   osascript dies on a syntax error, and — with stderr suppressed — the caller
#   sees an empty answer and exits silently with no dialog and no output. That
#   is a real bug this code shipped with once. Everything here goes through one
#   AppleScript file reading `on run argv`, so a message can never be parsed as
#   code.
#
# PROVIDES
#   ask "<msg>"                 one-line text field    -> answer on stdout
#   askpw "<msg>"               hidden text field      -> answer on stdout
#   choose "<msg>" "<a>" "<b>"  Cancel/a/b             -> button pressed
#   say "<msg>" / warn "<msg>" / stop "<msg>"          OK-only notice
#   hard "<msg>"                terminal-only fatal (dialogs unavailable)
#   dialogs_available           non-zero if osascript cannot show a dialog
#
#   \n in a message becomes a real newline. Callers must NOT escape quotes.
#
: "${TITLE:?_dialogs.sh: set TITLE before sourcing}"

DLG_WORK=$(mktemp -d "${TMPDIR:-/tmp}/grids-dlg.XXXXXX") || exit 1
DLG_AS="$DLG_WORK/dialogs.applescript"
DLG_ERR="$DLG_WORK/osascript.err"

cat > "$DLG_AS" <<'APPLESCRIPT'
on run argv
    set verb to item 1 of argv
    set t to item 2 of argv
    set msg to item 3 of argv
    if verb is "probe" then
        return "ok"
    else if verb is "ask" then
        set r to display dialog msg default answer "" with title t with icon note
        return text returned of r
    else if verb is "askhidden" then
        set r to display dialog msg default answer "" with hidden answer with title t with icon note
        return text returned of r
    else if verb is "choose" then
        set r to display dialog msg buttons {"Cancel", item 4 of argv, item 5 of argv} default button (item 5 of argv) with title t with icon note
        return button returned of r
    else if verb is "say" then
        display dialog msg buttons {"OK"} default button "OK" with title t with icon note
        return ""
    else if verb is "saystop" then
        display dialog msg buttons {"OK"} default button "OK" with title t with icon stop
        return ""
    else if verb is "saycaution" then
        display dialog msg buttons {"OK"} default button "OK" with title t with icon caution
        return ""
    end if
    return ""
end run
APPLESCRIPT

dlg() {
  local verb=$1 msg; msg=$(printf '%b' "$2"); shift 2
  osascript "$DLG_AS" "$verb" "$TITLE" "$msg" "$@" 2>>"$DLG_ERR"
}
ask()    { dlg ask        "$1"; }
askpw()  { dlg askhidden  "$1"; }
choose() { dlg choose     "$1" "$2" "$3"; }
say()    { dlg say        "$1" >/dev/null; }
warn()   { dlg saycaution "$1" >/dev/null; }
stop()   { dlg saystop    "$1" >/dev/null; }

dialogs_cleanup() { rm -rf "$DLG_WORK"; }

# Fatal, terminal only — for when dialogs themselves are the thing that failed.
hard() { printf '\n%s\n\n' "$(printf '%b' "$1")" >&2; exit 1; }

# A launcher must call this before its first dialog. Without it, a broken
# osascript makes every prompt return empty and the script exits silently.
dialogs_available() {
  [ "$(dlg probe x)" = "ok" ] && return 0
  printf '\n%s\n' "Cannot show dialogs on this Mac. osascript reported:" >&2
  head -5 "$DLG_ERR" >&2 2>/dev/null
  return 1
}
