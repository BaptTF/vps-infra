"""Prometheus exporter for Hermes Leo token usage per user.

Reads Hermes' state.db (sessions table) read-only on every scrape. Sub-agent sessions are
attributed to the user of their root session. The user label is the latest sender name Hermes
recorded for that user (origin_json.user_name), else "<source>:<user_id>".
"""

import os
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("HERMES_DATA", "/data")
AGENT = os.environ.get("AGENT_NAME", "leo")
PORT = int(os.environ.get("PORT", "9464"))

TOKEN_COLUMNS = ("input", "output", "cache_read", "cache_write", "reasoning")

USAGE = f"""
WITH RECURSIVE root(id, root_id) AS (
  SELECT id, id FROM sessions WHERE parent_session_id IS NULL
  UNION ALL
  SELECT s.id, root.root_id FROM sessions s JOIN root ON s.parent_session_id = root.id
)
SELECT r.source, r.user_id, count(*),
       {", ".join(f"sum(coalesce(s.{c}_tokens, 0))" for c in TOKEN_COLUMNS)},
       sum(coalesce(s.actual_cost_usd, s.estimated_cost_usd, 0))
FROM sessions s
JOIN root ON root.id = s.id
JOIN sessions r ON r.id = root.root_id
GROUP BY r.source, r.user_id
"""

NAMES = """
SELECT source, user_id, json_extract(origin_json, '$.user_name')
FROM sessions
WHERE user_id IS NOT NULL AND json_valid(origin_json)
  AND coalesce(json_extract(origin_json, '$.user_name'), '') != ''
ORDER BY started_at
"""


def user_label(source, user_id, names):
    if not user_id:
        return "inconnu" if source == "telegram" else "aucun"
    return names.get((source, user_id), f"{source}:{user_id}")


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render():
    db = sqlite3.connect(f"file:{DATA}/state.db?mode=ro", uri=True, timeout=10)
    try:
        names = {(s, u): n.strip() for s, u, n in db.execute(NAMES)}
        rows = db.execute(USAGE).fetchall()
    finally:
        db.close()
    sessions, tokens, cost = {}, {}, {}
    for source, user_id, count, *rest in rows:
        key = (source or "unknown", user_label(source, user_id, names))
        sessions[key] = sessions.get(key, 0) + count
        for col, val in zip(TOKEN_COLUMNS, rest[:-1]):
            tokens[key + (col,)] = tokens.get(key + (col,), 0) + val
        cost[key] = cost.get(key, 0) + rest[-1]
    out = [
        "# HELP hermes_sessions_total Hermes sessions (sub-agents counted under their root session's user).",
        "# TYPE hermes_sessions_total counter",
    ]
    out += [f'hermes_sessions_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}"}} {v}' for (s, u), v in sorted(sessions.items())]
    out += [
        "# HELP hermes_tokens_total Tokens used by Hermes sessions, by root session user.",
        "# TYPE hermes_tokens_total counter",
    ]
    out += [f'hermes_tokens_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}",type="{t}"}} {v}' for (s, u, t), v in sorted(tokens.items())]
    out += [
        "# HELP hermes_cost_usd_total Hermes' own cost estimate (actual_cost_usd, else estimated_cost_usd).",
        "# TYPE hermes_cost_usd_total counter",
    ]
    out += [f'hermes_cost_usd_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}"}} {v:.6f}' for (s, u), v in sorted(cost.items())]
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/healthz"):
            self.send_error(404)
            return
        try:
            body = (render() if self.path == "/metrics" else "ok\n").encode()
            status = 200
        except Exception as e:  # keep the exporter up; Prometheus sees the scrape fail
            body, status = f"error: {e}\n".encode(), 500
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
