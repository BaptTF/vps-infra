"""Prometheus exporter for Hermes Leo token usage per user.

Reads Hermes' state.db read-only on every scrape. Sub-agent sessions are
attributed to the user of their root session. The user label is the latest
sender name Hermes recorded (origin_json.user_name), else "<source>:<user_id>".

Tokens and cost come from session_model_usage (the route that served them).
A model stored as "<provider>/<model>" yields those two labels; otherwise the
billing provider is kept, except the Hermes profile name "custom". The same
metrics without provider and model are not emitted for tokens: one series per
route. hermes_sessions_total without those labels counts every session once;
with them, it counts sessions that used that route.
"""

import os
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("HERMES_DATA", "/data")
AGENT = os.environ.get("AGENT_NAME", "leo")
PORT = int(os.environ.get("PORT", "9464"))

TOKEN_COLUMNS = ("input", "output", "cache_read", "cache_write", "reasoning")

ROOT = """
WITH RECURSIVE root(id, root_id) AS (
  SELECT id, id FROM sessions WHERE parent_session_id IS NULL
  UNION ALL
  SELECT s.id, root.root_id FROM sessions s JOIN root ON s.parent_session_id = root.id
)
"""

# One row per model-usage record. actual and estimated are disjoint; a stored
# 0 must not hide the other column (coalesce would).
MODEL_ROWS = ROOT + """
SELECT r.source, r.user_id, s.id,
       coalesce(u.billing_provider, ''),
       coalesce(u.model, ''),
       coalesce(u.input_tokens, 0),
       coalesce(u.output_tokens, 0),
       coalesce(u.cache_read_tokens, 0),
       coalesce(u.cache_write_tokens, 0),
       coalesce(u.reasoning_tokens, 0),
       coalesce(u.actual_cost_usd, 0) + coalesce(u.estimated_cost_usd, 0)
FROM session_model_usage u
JOIN sessions s ON s.id = u.session_id
JOIN root ON root.id = s.id
JOIN sessions r ON r.id = root.root_id
"""

# Used when the per-model table is missing or still empty. The session row
# only knows the model it ended on.
SESSION_ROWS = ROOT + """
SELECT r.source, r.user_id, s.id,
       coalesce(s.billing_provider, ''),
       coalesce(s.model, ''),
       coalesce(s.input_tokens, 0),
       coalesce(s.output_tokens, 0),
       coalesce(s.cache_read_tokens, 0),
       coalesce(s.cache_write_tokens, 0),
       coalesce(s.reasoning_tokens, 0),
       coalesce(s.actual_cost_usd, 0) + coalesce(s.estimated_cost_usd, 0)
FROM sessions s
JOIN root ON root.id = s.id
JOIN sessions r ON r.id = root.root_id
WHERE coalesce(s.input_tokens, 0) + coalesce(s.output_tokens, 0)
    + coalesce(s.cache_read_tokens, 0) + coalesce(s.cache_write_tokens, 0)
    + coalesce(s.reasoning_tokens, 0)
    + coalesce(s.actual_cost_usd, 0) + coalesce(s.estimated_cost_usd, 0) > 0
"""

USER_SESSIONS = ROOT + """
SELECT r.source, r.user_id, count(*)
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


# Bedrock US inference profile, USD per token. Hermes stores 0 when the call
# goes through the custom Bifrost provider, so these rates replace that 0.
# Input, output, cache read, cache write. Opus 5.5 list is $4/$20; the us.
# profile is ten percent more, the same convention as the imported history.
_CATALOGUE = {
    "us.anthropic.claude-opus-5-5": (4.40e-6, 22e-6, 0.22e-6, 5.50e-6),
    # OpenCode Go list price, same as DeepSeek V4 Flash: $0.15 / $0.60 / $0.003.
    "deepseek-v4-flash-vision-exp": (1.5e-7, 6e-7, 3e-9, 0.0),
}


def catalogue_cost(model, input_tokens, output_tokens, cache_read, cache_write):
    """List price for a model Hermes left unpriced. None when we have no rate."""
    name = (model or "").strip()
    if "/" in name:
        name = name.split("/", 1)[1].strip()
    rates = _CATALOGUE.get(name)
    if rates is None:
        return None
    pin, pout, pcr, pcw = rates
    return input_tokens * pin + output_tokens * pout + cache_read * pcr + cache_write * pcw


def route(billing, model):
    """Provider and model labels. A slash in the model is the gateway route."""
    billing = (billing or "").strip()
    model = (model or "").strip()
    if "/" in model:
        provider, rest = model.split("/", 1)
        provider, rest = provider.strip(), rest.strip()
        if provider and rest:
            return provider, rest
    if billing and billing != "custom":
        return billing, model or "inconnu"
    return billing or "inconnu", model or "inconnu"


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render():
    db = sqlite3.connect(f"file:{DATA}/state.db?mode=ro", uri=True, timeout=10)
    try:
        names = {(s, u): n.strip() for s, u, n in db.execute(NAMES)}
        user_sessions = db.execute(USER_SESSIONS).fetchall()
        try:
            rows = db.execute(MODEL_ROWS).fetchall()
        except sqlite3.OperationalError:
            rows = []
        if not rows:
            rows = db.execute(SESSION_ROWS).fetchall()
    finally:
        db.close()

    tokens, cost, model_sessions = {}, {}, {}
    for source, user_id, sid, billing, model, *rest in rows:
        key = (source or "unknown", user_label(source, user_id, names), *route(billing, model))
        for col, val in zip(TOKEN_COLUMNS, rest[:-1]):
            tokens[key + (col,)] = tokens.get(key + (col,), 0) + val
        priced = catalogue_cost(model, *rest[:4])
        cost[key] = cost.get(key, 0) + (priced if priced is not None else rest[-1])
        model_sessions.setdefault(key, set()).add(sid)

    sessions = {}
    for source, user_id, count in user_sessions:
        key = (source or "unknown", user_label(source, user_id, names))
        sessions[key] = sessions.get(key, 0) + count

    out = [
        "# HELP hermes_sessions_total Hermes sessions. Without provider and model, every session once under its root user. With them, sessions that used that route.",
        "# TYPE hermes_sessions_total counter",
    ]
    out += [
        f'hermes_sessions_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}"}} {v}'
        for (s, u), v in sorted(sessions.items())
        if v
    ]
    out += [
        f'hermes_sessions_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}",provider="{esc(p)}",model="{esc(m)}"}} {len(ids)}'
        for (s, u, p, m), ids in sorted(model_sessions.items())
        if ids
    ]
    out += [
        "# HELP hermes_tokens_total Tokens used by Hermes sessions, by root user, provider and model.",
        "# TYPE hermes_tokens_total counter",
    ]
    out += [
        f'hermes_tokens_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}",provider="{esc(p)}",model="{esc(m)}",type="{t}"}} {v}'
        for (s, u, p, m, t), v in sorted(tokens.items())
        if v
    ]
    out += [
        "# HELP hermes_cost_usd_total Hermes cost (actual_cost_usd + estimated_cost_usd), by root user, provider and model.",
        "# TYPE hermes_cost_usd_total counter",
    ]
    out += [
        f'hermes_cost_usd_total{{agent="{AGENT}",source="{esc(s)}",user="{esc(u)}",provider="{esc(p)}",model="{esc(m)}"}} {v:.6f}'
        for (s, u, p, m), v in sorted(cost.items())
        if v
    ]
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
