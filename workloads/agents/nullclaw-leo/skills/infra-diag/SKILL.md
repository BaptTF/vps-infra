---
name: infra-diag
description: Diagnose infrastructure issues — Bifrost TCP errors, WhatsApp gateway disconnects, OpenClaw connectivity problems, LLM provider failures. Use when encountering network errors (read tcp, use of closed network connection, gateway disconnected, status 408/499), provider failures (Bedrock, Bifrost), or when asked to investigate infra/connectivity issues. Also use for proactive infra health checks.
---

# Infrastructure Diagnostics

## Quick Triage (run this first on ANY infra error)

1. Identify the error layer: OpenClaw → Bifrost → Provider (Bedrock/Chutes)
2. Check Bifrost health: `curl -s http://bifrost.openclaw.svc.cluster.local:8080/health`
3. Check recent errors: run `scripts/bifrost-scan.py --hours 1`
4. Check WhatsApp gateway: `openclaw status` (look for WhatsApp line)
5. Cross-reference with `references/known-issues.md`

## Bifrost Diagnostics

### API endpoint
```
http://bifrost.openclaw.svc.cluster.local:8080/api/logs
```

### Scan for errors
```bash
python3 <skill_dir>/scripts/bifrost-scan.py --hours 6
python3 <skill_dir>/scripts/bifrost-scan.py --date 2026-04-04
python3 <skill_dir>/scripts/bifrost-scan.py --hours 24 --errors-only
```

### Key fields in error logs
- `is_bifrost_error: true` → bug in Bifrost itself (not provider)
- `number_of_retries: 0` on TCP errors → retries don't cover TCP (known issue)
- `latency: 0ms` → connection failed instantly (dead pool connection)
- `token_usage: null` → request never reached provider

### Architecture
- **Bedrock** uses Go `net/http` (for AWS SigV4) — vulnerable to Go bug #39750 (dead HTTP/2 pool connections)
- **Other providers** (Chutes, etc.) use `fasthttp` with 30s idle timeout — not affected
- Config: `workloads/agents/bifrost/bifrost_config.json` in `BaptTF/vps-infra` repo

## WhatsApp Gateway

Common disconnects (status 408/499) — usually self-resolving within 30-60s. If persistent:
1. Check `openclaw status`
2. If status shows disconnected > 5 min: `whatsapp_login action=start`
3. Document in memory with timestamp

## Error Patterns — Decision Tree

```
"read tcp ... use of closed network connection"
  → Bifrost TCP error (Bedrock only, Go net/http pool)
  → Run bifrost-scan.py
  → Check references/known-issues.md for mitigations
  → NOT a token/context size issue (confirmed by investigation 2026-04-04)

"WhatsApp gateway disconnected (status 408/499)"
  → Usually self-healing, wait 60s
  → If persistent: whatsapp_login

"Error reading stream"
  → Same as TCP error above (OpenClaw surfaces it differently)

Provider timeout (latency > 60s then fail)
  → Check Bifrost timeout config (should be 600s)
  → Check if it's a streaming timeout vs request timeout
```

## Documenting Incidents

After diagnosis, always:
1. Update `references/known-issues.md` with new findings
2. Update `workspace/memory/infra/bifrost-tcp-errors.md` with timeline
3. Commit and push to repo
