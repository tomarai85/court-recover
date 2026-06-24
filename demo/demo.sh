#!/usr/bin/env bash
# demo.sh -- a self-contained, reproducible demonstration of court-recover.sh.
# Builds two fake Stop-hook payloads (a stalled turn and a clean turn) and runs the
# real hook against each, so the GIF shows the actual exit codes, not a mock-up.
#
#   Run it yourself:  bash demo/demo.sh
#   Regenerate GIF:   vhs demo/demo.tape   (writes assets/demo.gif)
set -u
cd "$(dirname "$0")/.." || exit 1

HOOK="./court-recover.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The exact malformed emission: a canary token alone on a line, then raw <invoke>
# markup written as TEXT. Because it is text, nothing executes -- the turn stalls.
MAL='running the tests now…
count
<invoke name="Bash">
<parameter name="command">npm test</parameter>
</invoke>'

# A transcript whose last assistant message is that stalled (text-only) turn.
printf '%s\n' '{"role":"user","content":"run the tests"}' > "$TMP/stalled.jsonl"
python3 - "$TMP/stalled.jsonl" "$MAL" <<'PY'
import json,sys
path,mal=sys.argv[1],sys.argv[2]
open(path,"a").write(json.dumps({"message":{"role":"assistant","content":[{"type":"text","text":mal}]}})+"\n")
PY
python3 - "$TMP/stall-payload.json" "$TMP/stalled.jsonl" "$MAL" <<'PY'
import json,sys
out,tp,mal=sys.argv[1],sys.argv[2],sys.argv[3]
json.dump({"session_id":"demo-session","last_assistant_message":mal,"transcript_path":tp},open(out,"w"))
PY

# A clean turn (a normal text reply, no leaked markup).
printf '%s\n' '{"role":"user","content":"thanks"}' > "$TMP/clean.jsonl"
printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"All tests passed."}]}}' >> "$TMP/clean.jsonl"
python3 - "$TMP/clean-payload.json" "$TMP/clean.jsonl" <<'PY'
import json,sys
out,tp=sys.argv[1],sys.argv[2]
json.dump({"session_id":"demo-session","last_assistant_message":"All tests passed.","transcript_path":tp},open(out,"w"))
PY

# Pacing is opt-in (DEMO_PACED=1, used by demo.tape) so a real run stays instant.
pause(){ [ "${DEMO_PACED:-0}" = "1" ] && sleep "${1:-1}" || true; }
say(){ printf '\033[2m# %s\033[0m\n' "$1"; }
hr(){ printf '\033[2m%s\033[0m\n' "----------------------------------------------------------"; pause 0.6; }

say "A long Claude Code session. The model just 'finished' a turn."
say "But look at what it actually emitted:"
pause 0.8
printf '\033[33m'; cat "$TMP/stalled.jsonl" | python3 -c 'import sys,json;print(json.loads(sys.stdin.readlines()[-1])["message"]["content"][0]["text"])'; printf '\033[0m'
pause 1
say "That <invoke> block is TEXT, not a tool call -- so npm test never ran."
hr
say "The Stop hook checks the turn before it ends:"
printf '\033[36m$ court-recover.sh  < stalled-turn\033[0m\n'; pause 0.8
"$HOOK" < "$TMP/stall-payload.json"; code=$?
printf '\033[31mexit %s\033[0m  ' "$code"; say "blocked -> the model is forced to re-issue the call for real"
hr
say "Next turn it emits a real tool call. Clean turn:"
printf '\033[36m$ court-recover.sh  < clean-turn\033[0m\n'; pause 0.8
"$HOOK" < "$TMP/clean-payload.json"; code=$?
printf '\033[32mexit %s\033[0m  ' "$code"; say "clean -> the hook does nothing and lets it stop"
hr
say "~100 lines of bash. Fail-open. github.com/tomarai85/court-recover"
