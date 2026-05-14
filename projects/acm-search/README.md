# ACM Search v2

Knowledge base for the ACM Search component in Red Hat Advanced Cluster Management.

## Repositories
- [search-v2-operator](https://github.com/stolostron/search-v2-operator) — Kubernetes operator that deploys all search pods
- [search-collector](https://github.com/stolostron/search-collector) — agent that collects resources from every cluster
- [search-indexer](https://github.com/stolostron/search-indexer) — receives from collectors, writes to PostgreSQL
- [search-v2-api](https://github.com/stolostron/search-v2-api) — GraphQL API with RBAC enforcement
- [search-e2e-test](https://github.com/stolostron/search-e2e-test) — end-to-end tests (Jest + Cypress)
- [search-mcp-server](https://github.com/stolostron/search-mcp-server) — MCP server for AI assistant access

## Files
- [README.md](./README.md) — This file. Plain-language overview for team meetings and onboarding.
- [KNOWLEDGE_BASE.md](./KNOWLEDGE_BASE.md) — Deep technical reference: SQL internals, RBAC pipeline, reconciler state machine, bug patterns, feature development guide.

---

## What ACM Search Does — The Plain-Language Overview

### The Problem It Solves

Imagine your company runs **50 OpenShift/Kubernetes clusters** — some in AWS, some on-prem, some for dev, some for production. Each cluster has hundreds of resources: pods, deployments, services, policies, virtual machines, and more.

Now a developer asks: *"Where is the pod named `payment-api` running?"* or an SRE asks *"Which clusters have a deployment with less than 2 replicas?"*

Without search, you'd have to `kubectl` into each cluster one by one. That's painful with 50 clusters and impossible with 200.

**ACM Search solves this by collecting all resources from all clusters into one central database, so you can search everything from one place.**

---

## The Flow — From Cluster to Query

Think of it like a **news aggregation system**. Reporters are on the ground (clusters), they send stories to a central newsroom (the hub), an editor stores them in an archive (database), and readers can search the archive from their browser.

---

### Step 1 — Collection: "The Reporter on the Ground"

**Component: `search-collector`**

There is one collector pod running on **every single cluster** — both the hub cluster and every managed cluster. Its job is simple: watch everything happening in the cluster and report it.

It uses Kubernetes **informers** (think of them as event listeners) — one per resource type. So it's watching Pods, Deployments, Services, Policies, VirtualMachines, etc., all at the same time. When something is **created, updated, or deleted**, the informer fires an event.

But it doesn't just forward raw Kubernetes objects. It first runs them through a **transformer** — which picks the most useful properties. For example, for a Pod it extracts: name, namespace, status, restart count, which node it's running on. It strips out the noise. This makes the data smaller and faster to query later.

It also computes **relationships (edges)**. For example:
- This Pod is **ownedBy** this ReplicaSet
- This ReplicaSet is **ownedBy** this Deployment
- This Pod **runsOn** this Node

The collector batches changes every **5 seconds** and sends them to the indexer over a secure mTLS connection. The first time it connects, it sends the **complete state** of the cluster. After that, it only sends **diffs** (what changed).

---

### Step 2 — Indexing: "The Central Newsroom"

**Component: `search-indexer`**

The indexer is the hub-side receiver. It sits and listens for incoming payloads from **all collectors across all clusters** — could be 50, could be 200 collectors sending changes simultaneously.

When a payload arrives, it writes to **PostgreSQL** in two tables:

- `search.resources` — every resource is one row: `uid`, `cluster`, and `data` (all properties as a JSON blob)
- `search.edges` — every relationship: source resource → destination resource, with a type like `ownedBy` or `runsOn`

The indexer also does something special: it **creates the Cluster node itself**. The collectors don't report "here's a cluster called my-cluster" — the indexer watches the `ManagedCluster` objects on the hub and creates a special row for each cluster. This is the `kind: Cluster` resource you see when searching.

---

### Step 3 — The Operator: "The Boss in the Background"

**Component: `search-v2-operator`**

Before any of the above works, someone has to deploy and manage all these components. That's the operator.

It's a **Kubernetes Operator** — a Go program that watches a custom resource called a `Search` CR. When you apply that CR, the operator creates everything: the Postgres deployment, the indexer, the API, the collector on the hub, TLS certificates, RBAC roles, Prometheus monitors — and it deploys the collector onto every managed cluster automatically via the OCM add-on framework.

If someone accidentally deletes the indexer deployment — the operator recreates it. If you update the Search CR to change memory limits — the operator propagates those changes. It is the **lifecycle manager** for all of search.

The operator also handles **feature flags** — turning on Global Search, Fine-Grained RBAC, or Virtual Machine actions — all controlled by annotations you add to the Search CR.

---

### Step 4 — The Query API: "The Search Engine"

**Component: `search-v2-api`**

Now users want to search. The ACM console sends **GraphQL queries** to the search API. A query looks like:

```graphql
search(input: [{ filters: [{ property: "kind", values: ["Pod"] }] }]) {
  count
  items
  related { kind count }
}
```

The API does three critical things:

**1. Authentication** — Validates the user's token via the Kubernetes `TokenReview` API. Who are you?

**2. RBAC enforcement** — This is the most complex part. The search index contains *all* resources from *all* clusters. But you shouldn't see resources you don't have permission to access. The API impersonates you and calls the Kubernetes authorization APIs to figure out exactly what you're allowed to see. It builds a SQL `WHERE` clause from your permissions and appends it to every query. So if you can only see Pods in `namespace-a` — your query only returns Pods in `namespace-a`, even though the database has Pods from every namespace on every cluster.

**3. PostgreSQL query** — Translates the GraphQL filters into SQL and queries the database. Results come back and are returned to the console.

It also supports **related resources** — if you search for a Deployment, you can ask "show me the related Pods." The API uses a recursive SQL query that traverses the edges table (up to 3 hops for applications).

There's also a **WebSocket subscription** (`watch` operation) — the console can subscribe to live changes. PostgreSQL sends a notification every time a row changes, and the API pushes the update to the browser in real-time.

---

### Step 5 — Global Search: "The Federation Layer"

**Optional feature — tech preview in ACM 2.11+**

In some enterprise setups, there are **multiple ACM hub clusters** (a "hub of hubs" via MulticlusterGlobalHub). Each hub has its own search database.

When Global Search is enabled, the ACM console sends one query and gets results **from all hubs**. The local search-api fans out the query to all managed hub search-apis in parallel, merges the responses, and returns the combined result to the user.

---

### Step 6 — The MCP Server: "The AI Interface"

**Component: `search-mcp-server`** (experimental)

The MCP server exposes the same search data to AI assistants via the **Model Context Protocol**. Instead of GraphQL, it provides a tool called `find_resources` that an AI can call. You can ask Claude: *"How many pods are in CrashLoopBackOff across all clusters?"* and it queries the search database directly.

---

## The Complete Picture

```
Every Managed Cluster                     Hub Cluster
─────────────────────                     ─────────────────────────────────────
                                          ┌─ search-v2-operator ─────────────┐
  [k8s API Server]                        │  (manages everything)             │
       │                                  └──────────────────────────────────┘
       │ watch events
       ▼
  [search-collector]  ──HTTPS/mTLS──►  [search-indexer]  ──►  [PostgreSQL]
  (transform + diff)    every 5s        (write to DB)               │
                                                                     │ SQL
                                                             [search-v2-api]
                                                             (GraphQL + RBAC)
                                                                     │
                                                   ┌─────────────────┴──────────────────┐
                                              [ACM Console]                      [MCP Server]
```

---

## What You'll Hear in Scrums — and What It Means

| Team says | What it means |
|-----------|--------------|
| "The collector isn't sending" | Collector pod on a cluster lost connection to the indexer |
| "The resync is happening too often" | Collector keeps falling back to sending full cluster state — something's failing in the diff cycle |
| "RBAC filtering is wrong" | Users seeing resources they shouldn't, or not seeing ones they should — problem in the API's WHERE clause logic |
| "The indexer is returning 429" | Too many collectors hitting the indexer at once, it's throttling them |
| "We need to update the transform for kind X" | A new property of a resource type needs to be indexed — code change in the collector's transformer |
| "The related resources query is slow" | The recursive SQL traversing edges is taking too long — usually happens with large clusters |
| "Global search isn't federating to hub X" | The ManagedServiceAccount or ManifestWork for that hub wasn't created properly by the operator |
| "The operator isn't reconciling" | Likely the `search-pause` annotation is set, or there's an error in the reconcile loop |
| "The watch subscription dropped" | The PostgreSQL LISTEN/NOTIFY connection broke and WebSocket updates stopped flowing |
| "We need a new CollectorConfig rule" | Someone wants to index a new property on a CRD without changing code — use the CollectorConfig CR |
| "The cluster node has wrong data" | ManagedCluster vs ManagedClusterInfo merge conflict in the indexer's clusterSync |
| "The RBAC cache is stale" | User's permission cache hasn't expired yet after a role change — 10 min TTL by default |
| "The batch is failing" | The indexer's pgx batch writer hit an error writing to PostgreSQL |

---

## The 5 Hub Pods at a Glance

| Pod | What It Does |
|-----|-------------|
| `search-v2-operator-controller-manager` | The operator — creates and manages all other search resources |
| `search-postgres` | The database — stores all indexed resources and relationships |
| `search-indexer` | Receives data from all collectors, writes it to PostgreSQL |
| `search-api` | Serves GraphQL queries with RBAC enforcement |
| `search-collector` | Hub-side collector — indexes the hub cluster itself |

Plus one `klusterlet-addon-search` pod on **every managed cluster**.

---

## Key Concepts Glossary

| Term | Meaning |
|------|---------|
| **Search CR** | The custom resource (`kind: Search`) that triggers the operator to deploy everything. Must be named `search-v2-operator`. |
| **CollectorConfig CR** | A custom resource to control which resource types and fields the collector indexes — no code change needed. |
| **Informer** | A Kubernetes watch mechanism. The collector uses one per resource type to detect changes in real-time. |
| **Transform** | The step where a raw Kubernetes resource is converted to a flat property map before sending to the indexer. |
| **Edge** | A directed relationship between two resources (e.g. Pod `ownedBy` Deployment). Stored in `search.edges`. |
| **Resync** | When the collector sends the complete current state of a cluster (vs a diff). Happens on first connect and after errors. |
| **RBAC WHERE clause** | The SQL condition appended to every query that limits results to what the requesting user is authorized to see. |
| **mTLS** | Mutual TLS — both sides (collector and indexer) authenticate each other with certificates. |
| **OCM add-on** | The mechanism used to automatically deploy the collector onto managed clusters. |
| **Global Search** | Feature that federates queries across multiple ACM hub clusters in parallel. |
| **_hubClusterResource** | A property set on resources that belong to the hub cluster itself (vs managed clusters). Used in RBAC filtering. |
