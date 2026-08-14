# search-e2e-test — Technical Reference

**Repo:** https://github.com/stolostron/search-e2e-test
**Language:** Node.js (Jest 29 + Cypress 13) | **Entry:** `start-tests.sh`, `package.json` scripts
**Runs against:** A live ACM cluster with Search deployed

## Architecture

```
start-tests.sh (orchestrator)
 ├─ Wait for pod readiness (search-*, console)
 ├─ API tests (Jest) — tests/api/
 ├─ RBAC setup (build/rbac-setup.sh)
 ├─ UI tests (Cypress) — tests/cypress/
 └─ Cleanup (build/rbac-clean.sh)
```

**Important:** `npm run test` is Cypress-only. Use `./start-tests.sh` for the full suite.

## Two Test Suites

### API Tests (Jest) — `tests/api/`

Directly query the GraphQL endpoint. No browser.

| File | What it tests |
|------|--------------|
| `search.test.js` | Basic queries: kind, name, namespace, label filters |
| `rbac.test.js` | RBAC enforcement — users only see authorized resources |
| `access.test.js` | Access control across users/groups |
| `filter.test.js` | Filter operators: =, !, !=, >, wildcards (**mostly `test.todo`**) |
| `pagination.test.js` | limit + offset |
| `queries.test.js` | Related resources (edge traversal), index-vs-`oc` parity |
| `data-validation.test.js` | Properties match actual k8s resources |
| `managed.test.js` | Resources from managed clusters appear |
| `globalsearch.test.js` | Federated/global search |
| `subscription*.test.js` | WebSocket watch events |
| `common.test.js` | searchSchema and searchComplete |

### UI Tests (Cypress) — `tests/cypress/`

Browser tests against the ACM console. PF6 selectors.
Specs: search, overview, saved-searches, suggested-searches, resourceDetailsPage.
Tags: `@CANARY`, `@BVT` for CI tier selection.

## Running Tests

```bash
# Full suite (recommended)
./start-tests.sh

# API only
npm run test:api
npm run test:api -- queries.test.js   # single file

# UI only
SKIP_API_TEST=true ./start-tests.sh
npx cypress run --spec 'tests/cypress/tests/search.spec.js'

# Headed (debug)
npm run test:headed
```

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| OPTIONS_HUB_BASEDOMAIN | Hub cluster base domain |
| OPTIONS_HUB_USER | Login user (usually `kubeadmin`) |
| OPTIONS_HUB_PASSWORD | Login password |
| SKIP_API_TEST | Skip API tests if `true` |
| SKIP_UI_TEST | Skip UI tests if `true` |

Can also provide via `tests/config/options.yaml`.

## Key Helpers (`tests/common-lib/`)

| Helper | Purpose |
|--------|---------|
| `searchClient` | GraphQL client (route auto-discovery) |
| `getSearchApiRoute` | Finds search-api route in cluster |
| `resolveSearchItems` | Execute query, return items |
| `ValidateSearchData` | Compare search results against `oc` output |
| `searchQueryBuilder` | Build SearchInput objects |
| `getUserContext` | SA token for RBAC tests |
| `createWebSocket` | WS connection for subscription tests |
| `cliClient` / `execCliCmdString` | Run `oc` commands |

## RBAC Test Fixtures

- Located in `tests/config/rbac_yaml/`
- Apply with `build/rbac-setup.sh`; clean with `build/rbac-clean.sh`
- Creates ServiceAccounts + RoleBindings for scoped-access testing
- UI RBAC users need `OPTIONS_HUB_PASSWORD` + `htpasswd` provider

## CI Integration

- **Prow:** `Dockerfile.prow` → `start-tests.sh`
- **Jenkins:** `Jenkinsfile` pipeline
- **Docker:** `Dockerfile` (npm ci + chrome)
- Tags: `@CANARY` (fast sanity), `@BVT` (build verification)

## Non-obvious Gotchas

1. **RBAC cache / index lag** — tests have waits up to 60s+ for cache refresh and multi-minute waits for indexing in `queries.test.js`
2. **`subscription-scale.test.js` has `it.only`** — will skip other tests in same file if run together
3. **`filter.test.js` is mostly `test.todo`** — placeholder tests not yet implemented
4. **Managed-cluster data-validation is `skip: true`** — hardcoded in `getClusterList`
5. **API pattern uses SA tokens** — creates ServiceAccount, gets token, queries as that SA
6. **Route discovery** — `getSearchApiRoute` looks for route in `open-cluster-management` namespace

## Agent Playbooks

### Add a new API E2E test
1. Create or edit a test file in `tests/api/`
2. Import helpers from `tests/common-lib/` (`searchClient`, `resolveSearchItems`)
3. Pattern: create test resources → wait for indexing → query Search API → assert results → cleanup
4. For RBAC tests: create SA/RoleBinding, get token via `getUserContext`, verify filtered results
5. Add appropriate wait/retry for indexing lag (5-30s typical)

### Add a new UI E2E test
1. Create or edit spec in `tests/cypress/tests/`
2. Use `cy.visitAndLogin()` for auth
3. Use page objects from `tests/cypress/views/` (searchPage, searchBar)
4. Reference PF6 selectors from `tests/cypress/config/selectors.js`
5. Tag with `@CANARY` or `@BVT` for CI inclusion

### Debug a failing E2E test
1. Check if Search pods are healthy: `oc get pods -n open-cluster-management | grep search`
2. Check if resource exists: `oc get <kind> <name> -n <ns>`
3. Check if indexed: query Search API directly with curl/graphql
4. Timing: resources may not be indexed yet (collector interval 5s + indexer processing)
5. RBAC cache: wait up to 60s after RoleBinding creation before asserting
6. Environment-specific: check if managed clusters are connected (`oc get managedclusters`)
