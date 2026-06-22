# agentic-ols

Knowledge base and skills for the [stolostron/agentic-ols](https://github.com/stolostron/agentic-ols) project.

## Contents

- **[KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md)** — Deep-dive reference: what agentic-ols is, Ollama/ngrok setup, LLM options, known issues, how to build new skills, and a roadmap for cluster-backup-operator skills

## What we built (hackathon Jun 22 2026)

- Added `search-operator-impact` skill to stolostron/agentic-ols (PR #1)
- Surfaced `Applied=False / RulesSkipped` CollectorConfig conditions from ACM-35522
- Documented full setup flow from scratch (ACM install → agentic operator → Ollama → ngrok → running analysis)

## Next: cluster-backup-operator-impact

See the KNOWLEDGE_BASE.md section "Applying This to cluster-backup-operator" for the full list of scripts to write.
Reference: `ai-tools/projects/acm-backup-triage/KNOWLEDGE_BASE.md`
