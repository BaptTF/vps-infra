# Perplexity — AI-Powered Research

## Description
Use Perplexity AI for complex research questions needing web-sourced answers.
Replaces the perplexity-ask MCP server.

## When to Use
- Complex research needing multiple sources
- Current events or recent developments
- Technical questions where training data may be outdated
- Fact-checking or verification

## How to Use

### Via Direct API
```bash
curl -s "https://api.perplexity.ai/chat/completions" \
  -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "sonar",
    "messages": [{"role": "user", "content": "YOUR QUESTION"}]
  }' | jq '.choices[0].message.content'
```

### Fallback: Brave Search + web_fetch
If Perplexity API is not available:
1. Search with Brave
2. Fetch top results
3. Synthesize the answer

## Notes
- Perplexity excels at synthesis from multiple web sources
- For simple lookups, Brave Search is faster and cheaper
- The `sonar` model includes citations
