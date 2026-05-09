---
name: publish-niko
description: Publish a document from amadeus-genai-docs to the shared repo genai-engineering-strategy (Niko Samberger). Use when asked to publish, share, or push a doc to the Niko repo, or to sync a document to genai-engineering-strategy. Handles review gate, merge if multiple files, clean internal tags, fix internal links, copy, tag source, commit both repos, and generate a message for Niko.
---

# Publish to Niko's Shared Repo

Publish a document from the working repo (`amadeus-genai-docs`) to the shared repo (`genai-engineering-strategy`) that Niko has access to.

## Repos

| Repo | Path | Push method |
|------|------|-------------|
| **Source** (working) | `/home/node/projects/amadeus-genai-docs` | `GIT_SSH_COMMAND="ssh -i /home/node/.ssh/genai_deploy -o StrictHostKeyChecking=no" git push origin main` |
| **Target** (shared) | `/home/node/projects/genai-engineering-strategy` | `git push origin main` (HTTPS via gh auth PAT) |

## Structure target repo

```
genai-engineering-strategy/
├── README.md
├── genai4engineers/    ← core docs (create only when doc is finalized)
└── explorations/       ← analyses, research, adjacent topics
```

## Publish workflow

### Step 0 — Review gate 🚨 MANDATORY
**NEVER publish without René's explicit "go".**
- Check source files for `✅ Reviewed by René` tag
- If no review tag → STOP and ask René to review first
- If René says "go" in conversation → proceed, but tag the source files first
- **No cowboy mode. No shortcuts. No "he seemed ok with it."**

### Step 1 — Merge if multiple source files
If the topic has multiple source files (e.g. proposal + orchestrators + plan), **merge them into a single file** for publication in the target repo.
- Concatenate in logical order with section separators (`---`)
- Keep all content, don't summarize
- Target = 1 topic = 1 file (clean for Niko to read)

### Step 1b — Clean for publication 🧹 MANDATORY
Before copying to target, clean the merged file:
- **Remove internal management tags:** Strip all lines containing `📤 Publié dans repo`, `✅ Reviewed by René`, `✅ Updated`, `Status: Proposal`, or any internal tracking metadata that Niko shouldn't see
- **Remove "For/Author/Date" blockquote** if it contains internal tags — replace with a clean header if needed
- **Fix internal links:** If `See also` or other links point to sibling files (e.g. `developer-studio-orchestrators.md`), remove or convert them to section anchors within the single merged file
- **Convert .md cross-references to plain text:** Links like `[Appendix A2](A2-token-economics-detailed.md)` must be converted to plain text (`Appendix A2`) or internal anchors if the target file is in the same PDF. Markdown `.md` links break in PDF generation (Typst/Pandoc) and are meaningless on GitHub when files are in the same directory.
- **Remove "See also" sections** that reference now-merged files (the content is already inline)
- **Remove internal appendix references:** Strip or rephrase references to annexes (B1, B2, etc.) that are NOT published in the target repo. Replace with generic text (e.g., "see internal analysis" → rephrase inline)

### Step 1c — Verify content integrity 🔍 MANDATORY
After cleaning, verify the published file matches the source:
- **Chapter numbers:** Ensure `## N.` headings in published files match the source files EXACTLY. Do NOT renumber during publication.
- **Cross-references:** Check all `[Appendix X](filename.md)` links point to files that exist in the target repo
- **No truncated text:** Diff the published file against the source. Every paragraph must be complete. Search for sentences ending with `(` or open quotes.
- **Frontmatter consistency:** If source has `date:` or `author:`, keep it in the published version

### Step 2 — Copy to target
Determine destination: `genai4engineers/` (finalized core doc) or `explorations/` (research/adjacent)
```bash
cp cleaned-merged-file.md /home/node/projects/genai-engineering-strategy/<dest-path>
```

### Step 3 — Tag ALL source files
Add this line in the frontmatter/header area of EACH source file:
```
> **📤 Publié dans repo partagé avec Niko** (`genai-engineering-strategy/<dest-path>`)
> **✅ Reviewed by René** (YYYY-MM-DD)
```

### Step 4 — Push both repos
Target:
```bash
cd /home/node/projects/genai-engineering-strategy
git add -A && git commit -m "feat: publish <doc-name>" && git push origin main
```
Source (tags only):
```bash
cd /home/node/projects/amadeus-genai-docs
git add -A && git commit -m "tag: <doc-name> published to genai-engineering-strategy" && GIT_SSH_COMMAND="ssh -i /home/node/.ssh/genai_deploy -o StrictHostKeyChecking=no" git push origin main
```

### Step 5 — Generate message for Niko
Compose a ready-to-copy message for René to send to Niko:

```
Hey Niko,

I just published [DOC TITLE] to our shared repo:
👉 https://github.com/rjullien/genai-engineering-strategy/blob/main/<dest-path>

**TL;DR:** [2-3 sentences — genuine exec summary, not fluff]

[Optional: key highlights as bullet points]

Let me know what you think!
```

The message must be:
- In English (Niko context)
- Concise, professional but not stiff
- Include the direct GitHub link
- Include a genuine executive summary
- Ready to copy-paste — no placeholders

## Re-publish (update)

Same workflow. Merge again from source files, clean again, overwrite in target. Commit message: `feat: update <doc-name>`.

## Git config

```bash
git config user.name "Léa 🌙"
git config user.email "lea@jullien.dev"
```
