# ACM Backup & Restore - Customer Issue Triage

AI-powered triage assistant for customer issues related to the ACM cluster-backup-operator (Business Continuity).

## How to Use

Copy a customer's question or issue description from Slack and ask your AI assistant:

> "Triage this customer issue: [paste the customer message]"

The AI will:
1. **Categorize** the issue (config mistake, known limitation, potential bug, OADP issue, informational)
2. **Identify root cause** using the knowledge base
3. **Draft a response** with resolution steps or workaround
4. **Link to docs** if relevant
5. **Suggest what info to collect** if it looks like a bug

## Example

```
You:   "Triage this: Customer says their Restore has been in Error phase for 2 days.
        They have syncRestoreWithNewBackups: true. They had a network outage that
        made BSL unavailable for a few hours but it's back now."

Agent: "CATEGORY: Known Limitation

        This is the BSL transient failure issue. When BSL goes down during passive
        sync, Velero restores fail with FailedValidation. The ACM controller only
        syncs when phase is Enabled, so it can't auto-recover.

        DRAFT RESPONSE:
        Hi, this is a known limitation with the current passive sync implementation.
        When BSL becomes temporarily unavailable, the Velero restores fail and the
        ACM Restore stays in Error phase.

        To recover, delete the failed Velero restore objects:
          oc -n open-cluster-management-backup get restores.velero.io
          oc -n open-cluster-management-backup delete restore.velero.io <failed-restore-name>

        The controller will then create new Velero restores on the next sync interval
        and transition back to Enabled. You can temporarily reduce restoreSyncInterval
        to speed up recovery."
```

## Knowledge Base

The [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) contains:
- 12 common issue categories with root causes and resolutions
- BackupSchedule and Restore phase reference
- Ownership boundaries (our team vs OADP vs MCH)
- What to collect for bug reports
- Links to official docs and blogs

## Adding Knowledge

When you encounter a new type of customer issue, add it to `KNOWLEDGE_BASE.md` so the AI learns it for next time.
