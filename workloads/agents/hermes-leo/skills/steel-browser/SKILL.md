---
name: steel-browser
description: >-
  Use this skill for any web task where WebFetch or curl would fail or be
  insufficient — pages that require JavaScript to render, forms to fill and
  submit, screenshots or PDFs of live pages, CAPTCHA/bot-protection bypass,
  login flows, and multi-step browser navigation with persistent session state.
  WebFetch returns empty HTML for JS-rendered pages; this skill runs a real
  cloud browser that executes JavaScript, maintains cookies, clicks buttons,
  and handles anti-bot measures. Trigger when the user wants you to actually
  perform a web task (visit, interact, extract, capture) rather than just write
  code for it. Skip only for: static pages a simple GET can fetch, localhost or
  private-network targets, writing browser automation code the user will run
  themselves, or conceptual questions about browser tools.
---

# Steel (self-hosted)

> Cloud browser infrastructure for AI agents. Steel gives your agent a real browser that can navigate pages, fill forms, solve CAPTCHAs, and extract content.
>
> **Self-hosted instance:** `http://steel-api:3000`
>
> **Two ways to use:**
>
> **Option 1 — CLI (recommended):**
> ```bash
> export PATH="$HOME/.steel/bin:$PATH"
> steel --local scrape https://example.com
> steel --local browser start --session my-task
> ```
> Config at `~/.config/steel/config.json` provides the URL:
> ```json
> {"browser":{"apiUrl":"http://steel-api:3000/v1"}}
> ```
> Always use `--local` flag. No API key needed. Do NOT set `STEEL_API_KEY`.
>
> **Option 2 — Direct curl:**
> ```bash
> curl http://steel-api:3000/v1/scrape -H "Content-Type: application/json" -d '{"url":"https://example.com"}'
> ```

---

## Choose the right tool

| Task | Tool |
|------|------|
| Extract text/HTML from a page | `steel scrape <url>` |
| Take a screenshot | `steel screenshot <url>` |
| Generate a PDF | `steel pdf <url>` |
| Multi-step interaction, login, forms, JS-heavy pages | `steel browser` session |
| Anti-bot / CAPTCHA sites | `steel browser --stealth` session |

**Start with `steel scrape` when you only need page content.** Escalate to `steel browser` when the page requires interaction or JavaScript rendering.

## API tools (one-shot, no session needed)

```bash
# Scrape — returns Markdown by default (use --json flag for structured output)
steel scrape https://example.com
steel scrape https://example.com --format html

# Screenshot
steel screenshot https://example.com
steel screenshot https://example.com --full-page

# PDF
steel pdf https://example.com
```

## Interactive browser session

### ⚠️ KNOWN ISSUE: CDP WebSocket

Browser sessions require the Steel API pod to have `DOMAIN=steel-api:3000` and `CDP_DOMAIN=steel-api:9223` env vars set correctly. Without this, the server returns `ws://0.0.0.0:3000/` which is unreachable from other pods.

If browser sessions fail with "CDP WebSocket connect failed", use curl directly against the API instead:
```bash
# Create session
SESSION=$(curl -s -X POST http://steel-api:3000/v1/sessions -H "Content-Type: application/json" -d '{}' | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
# Use session for actions via API...
# Release session
curl -s -X POST "http://steel-api:3000/v1/sessions/${SESSION}/release"
```

### Core workflow

1. **Start** a named session
2. **Navigate** to the target URL
3. **Snapshot** to get page state and element refs
4. **Interact** using `@eN` refs from the snapshot
5. **Re-snapshot** after every navigation or DOM change (refs expire)
6. **Stop** the session when done

```bash
steel browser start --session my-task --session-timeout 3600000
steel browser navigate https://example.com --session my-task
steel browser snapshot -i --session my-task
steel browser fill @e3 "search term" --session my-task
steel browser click @e7 --session my-task
steel browser wait --load networkidle --session my-task
steel browser snapshot -i --session my-task
steel browser stop --session my-task
```

**Rules:**
- Always use the same `--session <name>` on every command.
- Never use an `@eN` ref without a fresh snapshot — refs expire after navigation or DOM changes.
- Prefer element refs from `snapshot -i` over CSS selectors.
- Use `batch` to combine multiple commands into a single invocation for efficiency.

### Batch execution

```bash
steel browser batch "navigate https://example.com" "snapshot -i" --session my-task
steel browser batch "click @e3" "snapshot -i" --session my-task
steel browser batch "fill @e1 Seoul" "fill @e2 Tokyo" "click @e5" --session my-task
```

### Session lifecycle

```bash
steel browser start --session <name> --session-timeout 3600000
steel browser start --session <name> --stealth
steel browser sessions
steel browser stop --session <name>
steel browser stop --all
```

### Navigation and inspection

```bash
steel browser navigate <url> --session <name>
steel browser snapshot -i                      # interactive elements + refs
steel browser snapshot -i -c -d 3             # compact, limited depth
steel browser get url --session <name>
steel browser get title --session <name>
steel browser get text @e1 --session <name>
```

### Interaction

```bash
steel browser click @e1 --session <name>
steel browser fill @e2 "value" --session <name>
steel browser type @e2 "value" --delay 50 --session <name>
steel browser press Enter --session <name>
steel browser hover @e1 --session <name>
steel browser select @e1 "option" --session <name>
steel browser scroll down 500 --session <name>
steel browser eval "document.querySelectorAll('a').length" --session <name>
```

### Synchronization

```bash
steel browser wait --load networkidle --session <name>
steel browser wait --selector ".loaded" --state visible --session <name>
steel browser wait -t "Success" --session <name>
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `steel: command not found` | `export PATH="$HOME/.steel/bin:$PATH"` |
| `Missing Steel API key` | Unset `STEEL_API_KEY`. Self-hosted doesn't need one. |
| `401 Authentication failed` | You have `STEEL_API_KEY` set — unset it! |
| `404 Not Found` | URL missing `/v1` → use `STEEL_BROWSER_API_URL=http://steel-api:3000/v1` |
| `CDP WebSocket connect failed` | Pod steel-api needs `DOMAIN=steel-api:3000` env var |
| Stale element refs | Re-run `steel browser snapshot -i` before interacting |
