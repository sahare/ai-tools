# ACM Search v2

Knowledge base for the ACM Search component in Red Hat Advanced Cluster Management.

## Repositories
- [search-v2-operator](https://github.com/stolostron/search-v2-operator) — Kubernetes operator that deploys all search pods
- [search-collector](https://github.com/stolostron/search-collector) — agent that collects resources from every cluster
- [search-indexer](https://github.com/stolostron/search-indexer) — receives from collectors, writes to PostgreSQL
- [search-v2-api](https://github.com/stolostron/search-v2-api) — GraphQL API with RBAC enforcement
- [search-e2e-test](https://github.com/stolostron/search-e2e-test) — end-to-end tests (Jest + Cypress)
- [search-mcp-server](https://github.com/stolostron/search-mcp-server) — MCP server for AI assistant access

## Contents

- [KNOWLEDGE_BASE.md](./KNOWLEDGE_BASE.md) — Complete deep-dive: architecture, data flow, SQL internals, RBAC pipeline, reconciler state machine, bug patterns, feature development guide
