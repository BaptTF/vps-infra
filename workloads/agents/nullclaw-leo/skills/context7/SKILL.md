# Context7 — Technical Documentation Search

## Description
Search up-to-date technical documentation for libraries, frameworks, and tools.
Replaces the context7 MCP server with direct API calls.

## When to Use
- User asks about a specific library's API or usage
- Need current docs for a framework (not training data)
- Debugging with latest library version

## How to Use

### Search for a library
```bash
curl -s "https://context7.com/api/v1/search?query=LIBRARY_NAME" | jq '.results[:5] | .[] | {name, description, url}'
```

### Get documentation for a specific library
```bash
curl -s "https://context7.com/api/v1/docs?library=LIBRARY_ID&topic=TOPIC" | jq '.content'
```

### Alternative: Use web_fetch on official docs
If Context7 API is unavailable, fetch docs directly:
```bash
curl -s "https://raw.githubusercontent.com/OWNER/REPO/main/README.md"
```

## Notes
- Context7 provides LLM-optimized documentation snippets
- If the API requires authentication, use web_fetch on the library's official docs instead
- For GitHub-hosted projects, raw.githubusercontent.com is a reliable fallback
