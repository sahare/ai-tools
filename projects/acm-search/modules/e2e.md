# search-e2e-test — Technical Reference

**Repo:** https://github.com/stolostron/search-e2e-test
**Language:** Node.js (Jest + Cypress) | **Entry:** `package.json` scripts, `start-tests.sh`
**Runs against:** A live ACM cluster with Search deployed

## Two Test Suites

### API Tests (Jest) — `tests/api/`

Directly query the GraphQL endpoint. No browser.

| File | What it tests |
|------|--------------|
| `search.test.js` | Basic queries: kind, name, namespace, label filters |
| `rbac.test.js` | RBAC enforcement — users only see authorized resources |
| `access.test.js` | Access control across users/groups |
| `filter.test.js` | Filter operators: =, !, !=, >, wildcards |
| `pagination.test.js` | limit + offset |
| `queries.test.js` | Related resources (edge traversal) |
| `data-validation.test.js` | Properties match actual k8s resources |
| `managed.test.js` | Resources from managed clusters appear |
| `globalsearch.test.js` | Federated/global search |
| `subscription*.test.js` | WebSocket watch events |
| `common.test.js` | searchSchema and searchComplete |

### UI Tests (Cypress) — `tests/cypress/`

Browser tests against the ACM console. Specs: search, overview, saved-searches, suggested-searches, resourceDetailsPage.

## Running Tests

```bash
npm run test:api         # Jest API tests only
npm run test             # Cypress UI tests
npm run test:headed      # Cypress with browser visible
SKIP_API_TEST=true npm run test   # UI only
SKIP_UI_TEST=true npm run test    # API only
```

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| OPTIONS_HUB_BASEDOMAIN | Hub cluster base domain |
| OPTIONS_HUB_USER | Login user (usually `kubeadmin`) |
| OPTIONS_HUB_PASSWORD | Login password |

## RBAC Test Fixtures

- Located in `tests/config/rbac_yaml/`
- Apply with `build/rbac-setup.sh`
- Clean with `build/rbac-clean.sh`

## How to: add a new API E2E test

1. Create or edit a test file in `tests/api/`
2. Use the shared GraphQL client from `tests/common-lib/`
3. Pattern: create test resources → query Search API → assert results → cleanup
4. For RBAC tests: create ServiceAccount/RoleBinding, impersonate, verify filtered results

## How to: debug a failing E2E test

1. Check if it's environment-specific (passes in Jenkins but fails in Prow, or vice versa)
2. Verify Search pods are healthy: `oc get pods -n open-cluster-management | grep search`
3. Check if the test resource actually exists: `oc get <kind> <name> -n <ns>`
4. Check if it's indexed: query Search API directly with curl
5. For timing issues: resources may not be indexed yet (collector send interval is 5s default)
