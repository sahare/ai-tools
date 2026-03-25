# ai-tools

AI-powered automation for ACM development workflows. These tools eliminate manual toil by combining shell automation with AI agent integration, enabling developers to delegate repetitive tasks to their AI coding assistant.

## How It Works

Each project includes:
1. **Automation scripts** that handle the actual work
2. **AI agent skills** (`.cursorrules`) that teach AI assistants how to use the scripts
3. **Diagnostics** that collect state for AI-powered troubleshooting

Instead of reading docs and running commands manually, just tell your AI assistant what you need:

> "Install ACM 2.17 on my cluster"  
> "Cut a release branch for 2.18"  
> "My ACM installation is failing, can you diagnose it?"

## Projects

| Project | Description | Manual Effort Saved |
|---------|-------------|---------------------|
| [acm-cluster-setup](projects/acm-cluster-setup/) | Automated ACM dev build installation with AI-powered diagnostics | ~30 min per install |
| [acm-release-cut](projects/acm-release-cut/) | Automated CI config changes for new ACM release branches | ~2 hours per release cut |

## Getting Started

1. Clone this repo
2. Open it in any AI-enabled IDE or tool
3. The AI agent instructions are picked up automatically:

| AI Tool | Config File | Auto-loaded? |
|---------|-------------|--------------|
| Cursor | `.cursorrules` → `AGENT.md` | ✅ Yes |
| Claude Code | `CLAUDE.md` → `AGENT.md` | ✅ Yes |
| GitHub Copilot | `AGENT.md` | ✅ Yes |
| Windsurf / Cody / Other | `AGENT.md` | Read manually or reference it |
| ChatGPT / Claude web | N/A | Paste `diagnose.sh` output for analysis |

4. Start asking your AI assistant to do things

## AI Agent Skills

[`AGENT.md`](AGENT.md) defines these skills (works with any AI agent):

| Skill | Trigger | What It Does |
|-------|---------|--------------|
| Install ACM | "install ACM on my cluster" | Runs install script, monitors, verifies |
| Uninstall ACM | "remove ACM from cluster" | Clean uninstall of all ACM components |
| Diagnose Issues | "why is ACM failing?" | Collects cluster state, AI analyzes root cause |
| Health Check | "is my cluster healthy?" | Quick cluster health assessment |
| Cut Release | "cut release 2.18 for cluster-backup-operator" | Updates CI configs in openshift/release |
