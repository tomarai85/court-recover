#!/usr/bin/env python3
"""Behavior + safety tests for court-recover.sh.

Run: python3 test/court-recover.test.py
Exit 0 = all pass. Needs only python3 + bash (same as the hook).

Verifies the two claims the hook makes:
  1. It detects a tool-call-as-text emission and blocks (exit 2) to force a retry,
     WITHOUT false-positiving on real tool calls or prose that merely discusses the bug.
  2. It is fail-open (any bad input -> exit 0) and bounded (at most CAP forced
     re-issues per episode, then it lets the turn stop -- it can never freeze a session).
"""
import json, os, subprocess, tempfile, time, sys

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "court-recover.sh")
MAL = 'count\n<invoke name="Bash">\n<parameter name="command">npm test</parameter>\n</invoke>'

def transcript(blocks):
    p = tempfile.mktemp(suffix=".jsonl", prefix="cr-")
    with open(p, "w") as f:
        f.write(json.dumps({"role": "user", "content": "hi"}) + "\n")
        f.write(json.dumps({"message": {"role": "assistant", "content": blocks}}) + "\n")
    return p

def run(payload):
    r = subprocess.run(["bash", HOOK], input=json.dumps(payload).encode(), capture_output=True)
    return r.returncode

def sid():
    return "test-" + str(time.time_ns())

passed = total = 0
def check(name, got, exp):
    global passed, total
    total += 1
    ok = got == exp
    passed += ok
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: exit={got} (expected {exp})")

# --- behavior ---
check("clean turn -> no block",
      run({"session_id": sid(), "last_assistant_message": "All done.",
           "transcript_path": transcript([{"type": "text", "text": "All done."}])}), 0)
check("tool-call-as-text -> block",
      run({"session_id": sid(), "last_assistant_message": MAL,
           "transcript_path": transcript([{"type": "text", "text": MAL}])}), 2)
check("real tool_use present -> no block",
      run({"session_id": sid(), "last_assistant_message": MAL,
           "transcript_path": transcript([{"type": "text", "text": MAL},
                                           {"type": "tool_use", "name": "Bash", "input": {}}])}), 0)
disc = 'The bug looks like:\ncount\n<invoke name="Bash"> ... then nothing runs. Anyway, fixed it.'
check("prose discussing the bug -> no block",
      run({"session_id": sid(), "last_assistant_message": disc,
           "transcript_path": transcript([{"type": "text", "text": disc}])}), 0)

# --- fail-open ---
check("missing transcript -> fail-open",
      run({"session_id": sid(), "last_assistant_message": MAL,
           "transcript_path": "/tmp/court-recover-nope.jsonl"}), 0)
check("garbage stdin -> fail-open",
      subprocess.run(["bash", HOOK], input=b"not json", capture_output=True).returncode, 0)
check("empty stdin -> fail-open",
      subprocess.run(["bash", HOOK], input=b"", capture_output=True).returncode, 0)

# --- bounded (cannot freeze a session): 4 consecutive malformed turns, same session ---
s, t = sid(), transcript([{"type": "text", "text": MAL}])
payload = {"session_id": s, "last_assistant_message": MAL, "transcript_path": t}
seq = [run(payload) for _ in range(4)]
check("bounded: block,block,then let stop (CAP=2)", seq, [2, 2, 0, 0])

# --- failure-injection (Codex-found infinite-block paths) must FAIL-OPEN / stay bounded ---
def run_env(payload, extra):
    e = dict(os.environ); e.update(extra)
    r = subprocess.run(["bash", HOOK], input=json.dumps(payload).encode(), capture_output=True, env=e)
    return r.returncode

_notdir = tempfile.mktemp(prefix="cr-notadir-")
open(_notdir, "w").write("x")  # a FILE where a state dir would go
check("TMPDIR is a file -> fail-open (no infinite block)",
      run_env({"session_id": sid(), "last_assistant_message": MAL,
               "transcript_path": transcript([{"type": "text", "text": MAL}])}, {"TMPDIR": _notdir}), 0)

# A user-supplied COURT_RECOVER_TOKENS that is not a valid regex must not break the
# hook: detection simply can't compile, so the turn is allowed to stop (fail-open).
check("pathological COURT_RECOVER_TOKENS regex -> fail-open (never blocks)",
      run_env({"session_id": sid(), "last_assistant_message": MAL,
               "transcript_path": transcript([{"type": "text", "text": MAL}])},
              {"COURT_RECOVER_TOKENS": "("}), 0)

# Unique-per-run ids so the suite is idempotent (the hashed counter file persists in TMPDIR).
p2 = {"session_id": "../../../tmp/evil-" + str(time.time_ns()), "last_assistant_message": MAL,
      "transcript_path": transcript([{"type": "text", "text": MAL}])}
check("path-traversal session_id -> hashed, bounded (no path injection / no infinite block)",
      [run(p2) for _ in range(4)], [2, 2, 0, 0])

p3 = {"session_id": "x" * 6000 + "-" + str(time.time_ns()), "last_assistant_message": MAL,
      "transcript_path": transcript([{"type": "text", "text": MAL}])}
check("overlong session_id -> hashed to fixed length, bounded",
      [run(p3) for _ in range(4)], [2, 2, 0, 0])

print(f"\n{passed}/{total} passed")
sys.exit(0 if passed == total else 1)
