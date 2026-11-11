"""Prometheus exporter for Hermes Leo token usage per user.

Reads Hermes' state.db read-only on every scrape. Sub-agent sessions are
attributed to the user of their root session. The user label is the latest
sender name Hermes recorded (origin_json.user_name), else "<source>:<user_id>".

Tokens and cost come from session_model_usage (the route that served them).
hermes_window_* sums the part of each session that falls in 1m, 3m, 6m or 1y
(from the 1st, Europe/Paris). A session crossing the boundary is split by time.
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
SELECT r.source, r.user_id, s.id, s.started_at, coalesce(s.ended_at, s.started_at)
FROM sessions s
JOIN root ON root.id = s.id
JOIN sessions r ON r.id = root.root_id
"""

TIMED_ROWS = ROOT + """
SELECT r.source, r.user_id, s.id,
       coalesce(u.billing_provider, ''),
       coalesce(u.model, ''),
       coalesce(u.input_tokens, 0),
       coalesce(u.output_tokens, 0),
       coalesce(u.cache_read_tokens, 0),
       coalesce(u.cache_write_tokens, 0),
       coalesce(u.reasoning_tokens, 0),
       coalesce(u.actual_cost_usd, 0) + coalesce(u.estimated_cost_usd, 0),
       coalesce(u.first_seen, s.started_at),
       coalesce(u.last_seen, s.ended_at, u.first_seen, s.started_at)
FROM session_model_usage u
JOIN sessions s ON s.id = u.session_id
JOIN root ON root.id = s.id
JOIN sessions r ON r.id = root.root_id
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


def _last_sunday(year, month):
    """Last Sunday of a month, as a naive UTC date at 00:00."""
    from datetime import datetime, timedelta
    if month == 12:
        day = datetime(year + 1, 1, 1) - timedelta(days=1)
    else:
        day = datetime(year, month + 1, 1) - timedelta(days=1)
    return day - timedelta(days=(day.weekday() + 1) % 7)


def _paris_offset(utc):
    """EU rule: CEST from the last Sunday of March 01:00 UTC, else CET."""
    from datetime import timedelta
    start = _last_sunday(utc.year, 3).replace(hour=1)
    end = _last_sunday(utc.year, 10).replace(hour=1)
    if start <= utc < end:
        return timedelta(hours=2)
    return timedelta(hours=1)


def window_starts(now_ts):
    """Unix start of each dashboard window: 1st 00:00 Europe/Paris, through now."""
    from datetime import datetime, timedelta, timezone
    now = datetime.fromtimestamp(now_ts, timezone.utc).replace(tzinfo=None)
    local = now + _paris_offset(now)
    starts = {}
    for wid, back in (("1m", 0), ("3m", 2), ("6m", 5), ("1y", 11)):
        year, month = local.year, local.month - back
        while month <= 0:
            month += 12
            year -= 1
        midnight = datetime(year, month, 1)
        guess = midnight - timedelta(hours=1)
        utc_start = midnight - _paris_offset(guess)
        starts[wid] = utc_start.replace(tzinfo=timezone.utc).timestamp()
    return starts, now_ts


def overlap_fraction(t0, t1, start, end):
    """Share of [t0, t1] that falls in [start, end). A point in the window counts whole."""
    if t0 is None:
        return 0.0
    t0 = float(t0)
    t1 = t0 if t1 is None else float(t1)
    if t1 < t0:
        t1 = t0
    if t1 - t0 < 1:
        return 1.0 if start <= t0 < end else 0.0
    lo, hi = max(t0, start), min(t1, end)
    if hi <= lo:
        return 0.0
    return (hi - lo) / (t1 - t0)


def render():
    db = sqlite3.connect(f"file:{DATA}/state.db?mode=ro", uri=True, timeout=10)
    try:
        names = {(s, u): n.strip() for s, u, n in db.execute(NAMES)}
        user_sessions = db.execute(USER_SESSIONS).fetchall()
        try:
            rows = db.execute(MODEL_ROWS).fetchall()
            timed = db.execute(TIMED_ROWS).fetchall()
        except sqlite3.OperationalError:
            rows, timed = [], []
        if not rows:
            rows = db.execute(SESSION_ROWS).fetchall()
            timed = [
                (*row, None, None) for row in rows
            ]
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
    for source, user_id, sid, started, ended in user_sessions:
        key = (source or "unknown", user_label(source, user_id, names))
        sessions[key] = sessions.get(key, 0) + 1

    import time as _time
    starts, now_ts = window_starts(_time.time())
    w_tokens, w_cost, w_model_sessions, w_sessions = {}, {}, {}, {}
    for source, user_id, sid, billing, model, *rest in timed:
        t0, t1 = rest[-2], rest[-1]
        inn, out, cr, cw, reasoning, stored = rest[:6]
        priced = catalogue_cost(model, inn, out, cr, cw)
        amount = priced if priced is not None else stored
        person = (source or "unknown", user_label(source, user_id, names), *route(billing, model))
        for wid, start in starts.items():
            part = overlap_fraction(t0, t1, start, now_ts)
            if part <= 0:
                continue
            w_cost[(wid, *person)] = w_cost.get((wid, *person), 0) + amount * part
            for col, val in zip(TOKEN_COLUMNS, (inn, out, cr, cw, reasoning)):
                if val:
                    key = (wid, *person, col)
                    w_tokens[key] = w_tokens.get(key, 0) + val * part
            w_model_sessions.setdefault((wid, *person), set()).add(sid)
    for source, user_id, sid, started, ended in user_sessions:
        person = (source or "unknown", user_label(source, user_id, names))
        for wid, start in starts.items():
            if overlap_fraction(started, ended, start, now_ts) > 0:
                w_sessions.setdefault((wid, *person), set()).add(sid)

    # Same windows, shaped like Bifrost: one series per virtual key. Input
    # includes cache reads, which Bifrost counts inside the prompt. These are
    # the history Bifrost never stored, from before virtual keys and monitoring.
    vk = f"hermes-{AGENT}"
    bf_cost, bf_tokens = {}, {}
    for (wid, _source, _user, provider, model), amount in w_cost.items():
        # GitHub Copilot is not Bifrost; keep it on the Hermes person tree only.
        if provider == "github-copilot":
            continue
        key = (wid, provider, model)
        bf_cost[key] = bf_cost.get(key, 0) + amount
    for (wid, _source, _user, provider, model, col), val in w_tokens.items():
        if provider == "github-copilot":
            continue
        if col not in ("input", "output", "cache_read"):
            continue
        key = (wid, provider, model, col)
        bf_tokens[key] = bf_tokens.get(key, 0) + val
        if col == "cache_read":
            included = (wid, provider, model, "input")
            bf_tokens[included] = bf_tokens.get(included, 0) + val

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
    out += [
        "# HELP hermes_window_cost_usd Cost of Hermes sessions whose time range falls in the window. A session crossing the boundary is split by time.",
        "# TYPE hermes_window_cost_usd gauge",
    ]
    out += [
        f'hermes_window_cost_usd{{agent="{AGENT}",window="{esc(w)}",source="{esc(s)}",user="{esc(u)}",provider="{esc(p)}",model="{esc(m)}"}} {v:.6f}'
        for (w, s, u, p, m), v in sorted(w_cost.items())
        if v
    ]
    out += [
        "# HELP hermes_window_tokens Tokens of Hermes sessions in the window, split by time when a session crosses the boundary.",
        "# TYPE hermes_window_tokens gauge",
    ]
    out += [
        f'hermes_window_tokens{{agent="{AGENT}",window="{esc(w)}",source="{esc(s)}",user="{esc(u)}",provider="{esc(p)}",model="{esc(m)}",type="{t}"}} {v:.4f}'
        for (w, s, u, p, m, t), v in sorted(w_tokens.items())
        if v
    ]
    out += [
        "# HELP hermes_window_sessions Sessions overlapping the window. Without provider and model, each session once. With them, sessions that used that route.",
        "# TYPE hermes_window_sessions gauge",
    ]
    out += [
        f'hermes_window_sessions{{agent="{AGENT}",window="{esc(w)}",source="{esc(s)}",user="{esc(u)}"}} {len(ids)}'
        for (w, s, u), ids in sorted(w_sessions.items())
        if ids
    ]
    out += [
        f'hermes_window_sessions{{agent="{AGENT}",window="{esc(w)}",source="{esc(s)}",user="{esc(u)}",provider="{esc(p)}",model="{esc(m)}"}} {len(ids)}'
        for (w, s, u, p, m), ids in sorted(w_model_sessions.items())
        if ids
    ]
    out += [
        "# HELP bifrost_window_cost_usd Hermes consumption for a Bifrost virtual key over a calendar window. Bifrost kept no history before virtual keys.",
        "# TYPE bifrost_window_cost_usd gauge",
    ]
    out += [
        f'bifrost_window_cost_usd{{virtual_key_name="{esc(vk)}",window="{esc(w)}",provider="{esc(p)}",model="{esc(m)}"}} {v:.6f}'
        for (w, p, m), v in sorted(bf_cost.items())
        if v
    ]
    out += [
        "# HELP bifrost_window_tokens Tokens for a Bifrost virtual key over a calendar window. type=input includes cache_read, as Bifrost counts it.",
        "# TYPE bifrost_window_tokens gauge",
    ]
    out += [
        f'bifrost_window_tokens{{virtual_key_name="{esc(vk)}",window="{esc(w)}",provider="{esc(p)}",model="{esc(m)}",type="{t}"}} {v:.4f}'
        for (w, p, m, t), v in sorted(bf_tokens.items())
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
