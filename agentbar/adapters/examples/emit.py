#!/usr/bin/env python3
"""Talk to AgentBar directly over its local socket (no agentbar command needed).

One JSON object per line; AgentBar replies one JSON line per event.
Run with: python3 emit.py
"""
import json, os, socket, uuid

SOCK = os.path.expanduser("~/Library/Application Support/AgentBar/agentbar.sock")

def send(event: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(2)
        try:
            s.connect(SOCK)
        except (FileNotFoundError, ConnectionRefusedError):
            return {"ok": False, "error": "AgentBar is not running"}
        s.sendall((json.dumps(event) + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        return json.loads(s.makefile().readline() or "{}")

def ask_permission(session: str, summary: str, detail: str, wait: int = 120) -> str:
    """Show Allow / Deny in AgentBar and wait. Returns "allow", "deny" or "defer"."""
    event = {"v": 1, "agent": "my-agent", "session_id": session, "event": "needs_permission",
             "request": {"id": str(uuid.uuid4()), "tool": "shell", "summary": summary, "detail": detail},
             "await_seconds": wait}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(wait + 5)
        try:
            s.connect(SOCK)
        except (FileNotFoundError, ConnectionRefusedError):
            return "defer"  # AgentBar isn't running: ask in your own UI instead
        s.sendall((json.dumps(event) + "\n").encode())  # keep the connection open while waiting
        reply = json.loads(s.makefile().readline() or "{}")
        return reply.get("decision", "defer")

if __name__ == "__main__":
    session = "py-" + uuid.uuid4().hex[:6]
    print(send({"v": 1, "agent": "my-agent", "session_id": session, "event": "started",
                "title": "python example", "activity": "Loaded the dataset"}))
    decision = ask_permission(session, "Run: delete the temp folder", "rm -rf ./tmp")
    print("decision:", decision)
    print(send({"v": 1, "agent": "my-agent", "session_id": session, "event": "finished",
                "message": f"Done (you chose {decision})"}))
