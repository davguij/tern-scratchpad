#!/usr/bin/env bash
# Headless smoke run for the Scratchpad block. Starts `tern serve`, loads this
# repo as the plugin through a throwaway fixtures root, drives keys and clicks
# with `tern ctl`, and checks the visible tree text. Backs up and restores the
# plugin's kv.json so real notes are never touched.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
sock=/tmp/scratchpad-smoke.sock
root="$(mktemp -d)"
kv="$HOME/Library/Application Support/Tern/plugin-data/scratchpad/kv.json"
bak="$root/kv.json.bak"
ctl() { tern ctl --control "$sock" "$@"; }
typ() { ctl type "\"$1\"" >/dev/null; } # ctl joins its arguments, so quote the text itself
fail=0

mkdir -p "$root/crates/app/goldens" "$root/crates/plugins/fixtures"
ln -s "$repo" "$root/crates/plugins/fixtures/scratchpad"
if [ -f "$kv" ]; then mv "$kv" "$bak"; fi

cleanup() {
	ctl quit >/dev/null 2>&1 || true
	sleep 1 # let the session finish flushing before the store is restored
	rm -f "$kv"
	if [ -f "$bak" ]; then mv "$bak" "$kv"; fi
	rm -rf "$root"
}
trap cleanup EXIT

(cd "$root" && STENCIL_FIXTURE_ROOT="$root/crates/app" nohup tern serve --control "$sock" >"$root/serve.log" 2>&1 &)
for _ in $(seq 40); do [ -S "$sock" ] && break; sleep 0.25; done
sleep 2
ctl plugins fixtures >/dev/null
sleep 1
ctl plugins run plugin.scratchpad.open >/dev/null
sleep 1
ctl focus right >/dev/null

check() { # name, needle, [absent]
	local out
	sleep 0.5
	out="$(ctl tree)"
	if [ "${3:-}" = absent ]; then
		if grep -qF -- "$2" <<<"$out"; then echo "FAIL $1 (found '$2')"; fail=1; else echo "ok   $1"; fi
	elif grep -qF -- "$2" <<<"$out"; then echo "ok   $1"; else echo "FAIL $1 (missing '$2')"; fail=1; fi
}

# AE2: a fresh pane lands on an empty note and nothing is stored.
check "AE2 empty store shows placeholder" "No notes yet"

# AE1: type, finish, the note is listed and rendered.
typ "first note"
ctl key escape >/dev/null
sleep 0.5
check "AE1 note listed" "first note"
check "AE4 rendered after Escape (editor gone)" "Write a note" absent

# AE4: Enter returns to the editor with the same text.
ctl key enter >/dev/null
sleep 0.5
check "AE4 editor has text" "first note"

# AE3: unclosed bold stays plain text; the closed one keeps the text.
ctl key escape >/dev/null
ctl key n >/dev/null
typ "**done"
check "AE3 unclosed bold typed" "**done"
typ "**"
check "AE3 closed bold typed" "**done**"
ctl key escape >/dev/null

# R14: an emptied note is dropped on finish.
ctl key n >/dev/null
typ "gone"
ctl key meta+a >/dev/null
ctl key backspace >/dev/null
ctl key escape >/dev/null
sleep 0.5
check "R14 emptied note dropped" "gone" absent

# AE5: archive hides the note; the archived view lists it.
ctl key a >/dev/null
sleep 0.5
ctl key v >/dev/null
sleep 0.5
check "AE5 archived view lists it" "**done**"

# AE6: nothing was written under the repo.
if git -C "$repo" status --porcelain | grep -q 'kv.json'; then echo "FAIL AE6 kv.json in repo"; fail=1; else echo "ok   AE6 no note data in repo"; fi

# The starter hello command still loads.
ctl plugins run plugin.scratchpad.hello >/dev/null && echo "ok   hello command runs"

[ "$fail" = 0 ] && echo "smoke: all passed" || { echo "smoke: FAILED (serve log: $root/serve.log)"; trap - EXIT; ctl quit >/dev/null 2>&1 || true; exit 1; }
