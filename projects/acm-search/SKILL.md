---
name: acm-search
description: >-
  Develop, debug, and triage the ACM Search v2 stack: search-v2-operator,
  search-collector, search-indexer, search-v2-api, and search-mcp-server.
  Covers the 5-hub-pod architecture, CollectorConfig CRD reconciliation and
  RBAC propagation, the GraphQL query/RBAC pipeline, common bug patterns,
  debug commands, and E2E testing with custom images. Use when working in
  any search-v2-*/search-collector/search-indexer repo, diagnosing a search
  bug (missing/wrong resources, RBAC or filter issues, global search
  failures), adding a CRD status subresource, or setting up a custom-image
  E2E test for search.
---

# ACM Search v2

Companion knowledge base for the ACM Search stack — built from architecture deep-dives, real
production incidents, and specific feature investigations (with Jira IDs), not just documentation.
Full detail lives in [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md); plain-language onboarding is in
[README.md](README.md); practical dev/test workflows are in
[E2E-TESTING-GUIDE.md](E2E-TESTING-GUIDE.md). This file is the fast-path entry point.

## What it does

ACM Search indexes resources from the hub and all managed clusters into Postgres and exposes them
via a GraphQL API with per-user RBAC filtering, so users/UI/AI tools can query fleet-wide resources
without hitting every cluster's API server directly.

## The 5 hub pods

| Pod | Role |
|---|---|
| **search-v2-operator** | Reconciles the `Search` CR (singleton, must be named `search-v2-operator`) and `CollectorConfig` CRDs; deploys the other 4 components |
| **search-collector** | Runs on hub + each managed cluster (via OCM addon); informers watch resources, transform into nodes/edges, send to indexer |
| **search-indexer** | Receives collector payloads, writes to Postgres (`search.resources`, `search.edges`), rate-limits, batches |
| **search-v2-api** | GraphQL API; builds SQL from `SearchInput`, applies per-user RBAC WHERE clauses, resolves related-resource queries |
| **search-mcp-server** | Exposes the one `find_resources` MCP tool for AI assistants (e.g. Claude) to query search |

Full pipeline detail (informer → transformer → reconciler → sender → sync protocol → RBAC
pipeline) → [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#search-collector-deep-dive).

## CRITICAL RULES — production incidents happened from skipping these

1. **Adding a new CRD `status` subresource needs RBAC in 5 places across 2 repos** —
   `create_rolesbindings.go`, the `//+kubebuilder:rbac` marker, the addon Helm ClusterRole, and the
   CSV `clusterPermissions` in `search-v2-operator`, **plus** the MCH Helm template *and*
   `rbac_gen.go` in `multiclusterhub-operator` (step 5-6 is the one everyone forgets). Kubernetes
   RBAC won't let the operator grant a permission its own ServiceAccount doesn't already have —
   miss the MCH-side grant and the reconcile loop fails, which showed up as **MCH stuck in
   `Installing` status** in a real build (5.0.0-73). **Never manually edit `multiclusterhub-operator`
   templates for this** — fix the CSV in `search-v2-operator`, let the MCH repo's automated sync PR
   pick it up. Full mechanics → [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#rbac-for-new-status-subresources-search-v2-operator--production-lesson).
2. **CRD changes must be manually mirrored into 1 hand-maintained file.** `make manifests`/`make
   bundle` auto-update the operator's own CRD files, but
   `addon/manifests/chart/templates/collectorconfig_crd.yaml` (deployed to **managed clusters**) is
   hand-maintained and commonly drifts — always `git diff` the auto-generated CRD after `make
   manifests` and mirror new fields/markers into the chart template by hand.
3. **Any `[]metav1.Condition` field needs `+listType=map` / `+listMapKey=type` markers**, or the API
   server uses atomic list replacement and duplicate condition types appear.
4. **`merged-collector-config` must never get the backup label** — it's operator-computed and
   recreated every reconcile; only `user-collector-config` and integration-labeled configs need
   `cluster.open-cluster-management.io/backup`. (Cross-reference: this is also documented from the
   backup side in the `acm-backup-triage` skill.)

## Common bug patterns

| Symptom | Where to look first |
|---|---|
| Resource missing from results | Collector transform panic → reconciler skip conditions → RBAC WHERE clause → indexer `AddErrors` → query postgres directly |
| Search returns too many resources | `userHasAllAccess()` — SSAR for `* *` returning true unexpectedly; `buildRbacWhereClause()` being skipped |
| Related resources empty/wrong | Query `search.edges` directly; check `allEdges()` and `related.go:setDepth()` |
| Wildcard filter not working | `getPartialMatchFilter()` — `*` should become `%`; check `getPropertyType()` |
| Collector resyncs every cycle | Sender resets `lastSentTime=-1` on diff failure; check indexer health/cert, `AGGREGATOR_URL` |
| RBAC cache stale after permission change | `UserCacheTTL` (default 10 min); check `watchCache.go` events |
| Indexer returning 429 | `requestLimiter`/`largeRequestLimiter` threshold; too many concurrent collectors or a resync loop |
| Global search missing managed-hub results | `search-global-config` ConfigMap per hub; `ManagedServiceAccount search-global`; `managedserviceaccount`/`cluster-proxy-addon` add-ons; `GlobalSearchReady` condition |
| Cluster node has wrong properties | `ManagedCluster` + `ManagedClusterInfo` both write via `addAdditionalProperties()`; `ReadClustersCache()` merge order |

Full diagnosis steps for each → [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#common-bug-patterns).

## Debug commands (most-used subset)

```bash
oc get pods -n open-cluster-management | grep search
oc get search search-v2-operator -n open-cluster-management -o yaml
oc get search search-v2-operator -o jsonpath='{.status.conditions}' | jq
oc logs -n open-cluster-management-agent-addon -l component=search-collector -- --v=5
oc logs -n open-cluster-management -l name=search-indexer -- --v=5
# Direct postgres:
SELECT uid, cluster, data FROM search.resources WHERE data->>'name'='<name>' AND data->>'kind'='<kind>';
SELECT * FROM search.edges WHERE sourceid='<uid>' OR destid='<uid>';
# Pause reconciliation for manual testing:
oc annotate search search-v2-operator -n open-cluster-management search-pause=true
```
Full reference (postgres debug scripts, GraphQL queries, feature-flag annotations, custom-image
override) → [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#debug-commands-reference).

## Adding features — quick pointers

- New indexed property → `pkg/transforms/{kind}.go` `BuildNode()`, or no-code via `CollectorConfig`
  `spec.collectionRules[].fields` (JSONPath).
- New GraphQL filter operator → `schema.graphqls` + `getWhereClauseExpression()` +
  `matchOperatorToProperty()`.
- New operator feature flag → annotation constant in `controllers/common.go` + new
  `controllers/my_feature_setup.go`, called from `search_controller.go Reconcile()`.
- New MCP tool → `ToolDefinition` in `tools.go` + handler + query in `queries.go`.

Full steps → [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#adding-features).

## E2E testing with custom images

Standard workflow: build/push a custom image, override it on the `Search` CR (or pause the
operator and patch the deployment directly if `imageOverride` isn't respected), watch out for the
CollectorConfig admission webhook blocking test configs on fresh installs. Full step-by-step
(pull secrets, feature flags, `lastTransitionTime` test matrix, common pitfalls) →
[E2E-TESTING-GUIDE.md](E2E-TESTING-GUIDE.md).

## Specific feature investigations (with full history/rationale)

- **ACM-20052** — why `search.open-cluster-management.io` is excluded from automatic backup and
  how `CollectorConfig`s get the backup label anyway →
  [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#acm-backuprestore-and-collectorconfig-acm-20052)
- **ACM-35522** — Exclude Action in CollectorConfig, design decisions and bugs found during review →
  [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#exclude-action-in-collectorconfig-acm-35522)
- **ACM-37052** — Built-in Integration CollectorConfigs ("drop a YAML, no Go code needed"),
  including a real bug caught by live cluster testing →
  [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#built-in-integration-collectorconfigs-acm-37052-jul-2026)
- **Future opportunities** (testability, scalability, "guess what users want"-ility) per Spencer
  McAvey's team priorities → [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md#future-opportunities--search-team-priorities-spencer-mcavey-jul-2026)

## New to the project?

Start with [README.md](README.md) — plain-language walkthrough of the collection → indexing →
query → global-search flow, "what you'll hear in scrums" jargon decoder, and a glossary. Come back
here once you need to actually build or debug something.
