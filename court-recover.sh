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

TOKENS="${COURT_RECOVER_TOKENS:-court|call|count|course}"

# Detect a malformed tool-call-as-text emission in the LAST assistant message.
# Fast path: if the Stop payload includes `last_assistant_message` and it has NO
# canary signature, exit clean WITHOUT reading the transcript (the common case).
# Only when the signature is present do we read the transcript -- to confirm there
# is no real tool_use block in that message.
#
# Tight signature (so a turn that merely DISCUSSES the bug is not flagged):
#   a canary token ALONE on a line, immediately followed by a line starting with
#   `<invoke name=`, the text ENDS with the call markup, AND no real tool_use block.
DET=$(INPUT_RAW="$INPUT" TRANSCRIPT="$TRANSCRIPT" TOKENS="$TOKENS" python3 <<'PY' 2>/dev/null
import os, json, re, sys
raw = os.environ.get("INPUT_RAW", "")
transcript = os.environ.get("TRANSCRIPT", "")
tokens = os.environ.get("TOKENS", "court|call|count|course")
canary = re.compile(r'(?m)^[ \t]*(' + tokens + r')[ \t]*\r?\n[ \t]*<invoke name=')

def malformed_text(t):
    return bool(canary.search(t)) and t.rstrip().endswith("</invoke>")

# Fast path via last_assistant_message (no file read when there is no signature).
lam = ""
try:
    lam = json.loads(raw).get("last_assistant_message") or ""
except Exception:
    lam = ""
if lam and not malformed_text(lam):
    print("0"); sys.exit()

# Need the transcript to confirm signature + absence of a real tool_use block.
if not transcript or not os.path.isfile(transcript):
    print("0"); sys.exit()
last = None
try:
    with open(transcript, encoding="utf-8") as fh:
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
    print("0"); sys.exit()
if not last:
    print("0"); sys.exit()
has_tool_use = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in last)
text = "\n".join(b.get("text", "") for b in last if isinstance(b, dict) and b.get("type") == "text")
print("1" if (malformed_text(text) and not has_tool_use) else "0")
PY
)

# Per-session state lives in a private, per-user dir; SID is sanitized to a safe
# filename (raw session_id must never reach the path -> no `/` or `..` injection).
SID_SAFE=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9._-')
STATE_DIR="${TMPDIR:-/tmp}/court-recover-$(id -u 2>/dev/null || echo 0)"

# Clean turn -> reset the per-session recovery counter and let it stop.
if [ "$DET" != "1" ]; then
  [ -n "$SID_SAFE" ] && rm -f "$STATE_DIR/$SID_SAFE" 2>/dev/null
  exit 0
fi

# No per-session blocking state without a usable SID (avoids cross-session collision).
[ -z "$SID_SAFE" ] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
CF="$STATE_DIR/$SID_SAFE"
N=$(cat "$CF" 2>/dev/null | tr -dc '0-9'); N=${N:-0}
CAP="${COURT_RECOVER_CAP:-2}"
case "$CAP" in ''|*[!0-9]*) CAP=2 ;; esac   # non-numeric -> default (stay fail-open)
LOG="${COURT_RECOVER_LOG:-${HOME:-/tmp}/.claude/logs/court-recover.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# Exhausted: after CAP forced re-issues, let the turn stop (the model can re-issue
# on its own). No context-degraded / /compact advice -- modern Claude Code auto-compacts.
if [ "$N" -ge "$CAP" ]; then
  printf '0' > "$CF" 2>/dev/null || true
  echo "[$(date '+%F %T' 2>/dev/null)] [court-recover] exhausted (>=${CAP}) -> let stop | SID=$SID_SAFE" >> "$LOG" 2>/dev/null || true
  exit 0
fi

# Force a clean re-issue.
printf '%s' "$((N + 1))" > "$CF" 2>/dev/null || true
echo "[$(date '+%F %T' 2>/dev/null)] [court-recover] tool-call-as-text -> forcing re-issue (#$((N + 1))/${CAP}) | SID=$SID_SAFE" >> "$LOG" 2>/dev/null || true
echo "TOOL-CALL RECOVERY: your previous turn emitted a tool call as LITERAL TEXT -- a stray token (court/count/call) followed by raw invoke markup written as prose -- so NOTHING executed and the turn stalled. Do NOT write tool-call markup as text. Re-issue the SAME tool call NOW as a real, structured tool call." >&2
exit 2
