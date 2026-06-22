#!/usr/bin/env bash
# court-recover.sh -- a Claude Code Stop hook that detects "tool-call-as-text"
# emissions and forces a clean, bounded re-issue. Fail-open: NEVER blocks on error.
#
# THE BUG -------------------------------------------------------------------
# In long or degraded sessions the model sometimes emits a tool call as LITERAL
# TEXT -- a stray canary token (court / call / count / course) alone on a line,
# immediately followed by raw `<invoke name=...>` markup written as prose -- instead
# of a real structured tool_use block. No tool runs, so the turn produces only text:
#   - autonomous / agentic loops stall silently
#   - interactive sessions "reply, then do nothing"
# It is intermittent, maddening, and there is no off-the-shelf fix. Claude Code has
# no output-stream rewrite hook, so we cannot strip the bad markup mid-stream; the
# feasible fix is DETECT it after the turn and force a bounded clean retry.
#
# CONTRACT (Stop hook) ------------------------------------------------------
#   reads the Stop-hook JSON on stdin.
#   exit 2 = block the stop + stderr guidance (the model re-issues the tool call)
#   exit 0 = let the turn stop (clean turn, OR recovery attempts exhausted)
#   ANY error -> exit 0 (fail-open: a bug in this hook must never freeze a session)
#
# CONFIG (env, all optional) ------------------------------------------------
#   COURT_RECOVER_CAP    max forced re-issues per session before giving up (default 2)
#   COURT_RECOVER_TOKENS regex alternation of canary tokens (default court|call|count|course)
#   COURT_RECOVER_LOG    log file path (default ~/.claude/logs/court-recover.log)
#
# INSTALL: register as a Stop hook in ~/.claude/settings.json -- see README.md.

set -u
INPUT=$(cat 2>/dev/null || echo '{}')

SID=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('session_id','') or '')
except Exception: print('')" 2>/dev/null)

TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('transcript_path','') or '')
except Exception: print('')" 2>/dev/null)
{ [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; } && exit 0

TOKENS="${COURT_RECOVER_TOKENS:-court|call|count|course}"

# Detect a malformed tool-call-as-text emission in the LAST assistant message.
# Tight signature (so a turn DISCUSSING the bug -- like this comment -- is NOT flagged):
#   the message's text has a canary token ALONE on a line, immediately followed by a
#   line starting with `<invoke name=`, the text ENDS with the emitted call markup,
#   AND the message has NO real tool_use block.
DET=$(TRANSCRIPT="$TRANSCRIPT" TOKENS="$TOKENS" python3 <<'PY' 2>/dev/null
import os, json, re
p = os.environ["TRANSCRIPT"]
tokens = os.environ.get("TOKENS", "court|call|count|course")
last = None
try:
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            m = o.get("message", o)
            if not isinstance(m, dict):
                continue
            if (m.get("role") or o.get("role")) != "assistant":
                continue
            c = m.get("content")
            if isinstance(c, list):
                last = c
            elif isinstance(c, str):
                last = [{"type": "text", "text": c}]
except Exception:
    print("0"); raise SystemExit
if not last:
    print("0"); raise SystemExit
has_tool_use = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in last)
text = "\n".join(b.get("text", "") for b in last if isinstance(b, dict) and b.get("type") == "text")
canary = re.compile(r'(?m)^[ \t]*(' + tokens + r')[ \t]*\r?\n[ \t]*<invoke name=')
# malformed = canary token + raw invoke markup, AND the text ENDS with the (text-emitted)
# call -> the turn terminated into it (a real stall). The endswith gate keeps a turn that
# merely DISCUSSES the bug in prose / code fences from ever being blocked.
malformed = bool(canary.search(text)) and text.rstrip().endswith("</invoke>")
print("1" if (malformed and not has_tool_use) else "0")
PY
)

# Clean turn -> reset the per-session recovery counter and let it stop.
[ "$DET" = "1" ] || { [ -n "$SID" ] && rm -f "/tmp/court-recover-$SID" 2>/dev/null; exit 0; }

# No per-session blocking state without a real SID (empty would collide cross-session).
[ -z "$SID" ] && exit 0

CF="/tmp/court-recover-$SID"
N=$(cat "$CF" 2>/dev/null | tr -dc '0-9'); N=${N:-0}
CAP="${COURT_RECOVER_CAP:-2}"
LOG="${COURT_RECOVER_LOG:-$HOME/.claude/logs/court-recover.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# Exhausted: after CAP forced re-issues, just let the turn stop (the model can re-issue
# on its own). No context-degraded / /compact advice -- modern Claude Code auto-compacts.
if [ "$N" -ge "$CAP" ]; then
  printf '0' > "$CF" 2>/dev/null || true
  echo "[$(date '+%F %T')] [court-recover] exhausted (>=${CAP}) -> let stop | SID=$SID" >> "$LOG" 2>/dev/null || true
  exit 0
fi

# Force a clean re-issue.
printf '%s' "$((N + 1))" > "$CF" 2>/dev/null || true
echo "[$(date '+%F %T')] [court-recover] tool-call-as-text -> forcing re-issue (#$((N + 1))/${CAP}) | SID=$SID" >> "$LOG" 2>/dev/null || true
echo "TOOL-CALL RECOVERY: your previous turn emitted a tool call as LITERAL TEXT -- a stray token (court/count/call) followed by raw invoke markup written as prose -- so NOTHING executed and the turn stalled. Do NOT write tool-call markup as text. Re-issue the SAME tool call NOW as a real, structured tool call." >&2
exit 2
