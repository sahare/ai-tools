# OLMv1 hub reproduction: OADP ClusterExtension fails to install (namespace/install-mode issue)

**Date:** 2026-07-27
**Goal:** Verify PR [#4323](https://github.com/stolostron/multiclusterhub-operator/pull/4323) ("Add OLM v1 support for OADP operator installation") works correctly on a hub, before testing the corresponding managed-cluster changes in a feature branch.
**Result:** **Reproduced the namespace issue. PR #4323 does not work as intended — kept live on this cluster for the installer/OLMv1 team.**

## Cluster access (left in the failed state intentionally — do not tear down)

- API: `https://api.app-prow-small-aws-421-west2-7zjzq.dev11.red-chesterfield.com:6443`
- Console: `https://console-openshift-console.apps.app-prow-small-aws-421-west2-7zjzq.dev11.red-chesterfield.com`
- OCP version: 4.21.0 (server), Kubernetes v1.34.2
- Auth: `kubeadmin` (credential shared out-of-band with the requester; not repeated here — rotate before long-term sharing)
- Local artifacts: `/tmp/olmv1-hub3-test/` (install script, logs, registry creds file)

## What was installed

- ACM via OLMv1 `ClusterExtension`: `advanced-cluster-management.v5.1.0-17`, `Installed: True`
- MCE via OLMv1 `ClusterExtension`: `multicluster-engine.v5.0.0-185`, `Installed: True`, fully `Available`
- Catalogs used: `acm-dev-catalog` / `mce-dev-catalog`, tag `latest-5.0` (as of 2026-07-27) — **note:** the `spec.networkPolicies: Required value` version-skew bug seen in a previous session (2026-07-23) is now fixed in this build; MCE installed cleanly with no manual workaround needed.
- `cluster-backup` component enabled on the `MultiClusterHub` CR to trigger the OADP install path added by PR #4323.

## The failure

```
$ oc get clusterextension redhat-oadp-operator -o yaml
...
status:
  conditions:
  - type: Installed
    status: "False"
    reason: Failed
    message: "No bundle installed"
  - type: Progressing
    status: "True"
    reason: Retrying
    message: >-
      error for resolved bundle "oadp-operator.v1.5.7" with version "1.5.7":
      unsupported bundle: bundle does not support AllNamespaces install mode
```

The rendered `ClusterExtension` (from `pkg/templates/charts/toggle/cluster-backup/templates/odap-operator-pre-install-hook.yaml`, OLMv1 branch):

```yaml
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: redhat-oadp-operator
spec:
  namespace: open-cluster-management-backup
  serviceAccount:
    name: oadp-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: redhat-oadp-operator
      version: ">=1.4.0"
  config:
    configType: Inline
    inline:
      watchNamespace: open-cluster-management-backup
```

## Root cause (verified against the live CRD schema + catalog data, not speculative)

1. **`spec.config.inline` is not an install-mode selector.** The `ClusterExtension` v1 CRD schema on this cluster documents it as: *"config is an optional field used to specify bundle specific configuration used to configure the bundle... validated against a configuration schema provided by the resolved bundle."* It's a generic passthrough for whatever config schema the *bundle itself* defines (analogous to a Helm values override) — it has no effect on which CSV install mode OLMv1 resolves against.
2. **The `ClusterExtension` v1 spec has no field for explicitly requesting an install mode at all.** Full top-level `spec` keys on this cluster's CRD: `config`, `install`, `namespace`, `serviceAccount`, `source`. There's no `installModes`/`watchNamespaces` selector.
3. **`oadp-operator.v1.5.7`'s CSV only supports `OwnNamespace`.** Confirmed by querying the `openshift-redhat-operators` catalog directly via `catalogd`'s HTTP API:
   ```json
   [
     {"type": "OwnNamespace", "supported": true},
     {"type": "SingleNamespace", "supported": false},
     {"type": "MultiNamespace", "supported": false},
     {"type": "AllNamespaces", "supported": false}
   ]
   ```
4. **OLMv1's bundle resolution on this cluster still requires `AllNamespaces` support**, regardless of `spec.namespace` being set to a single namespace. So a bundle that is deliberately `OwnNamespace`-only (like OADP, which needs single-tenant per-namespace install) can never resolve, no matter what `config.inline.watchNamespace` is set to.

**Conclusion:** PR #4323 assumed that setting `spec.namespace` + `config.inline.watchNamespace` on the `ClusterExtension` would make OLMv1 resolve the bundle in `OwnNamespace` mode. That assumption does not hold on this OLMv1/OCP 4.21 build — namespace-scoped (non-`AllNamespaces`) bundle resolution does not appear to be functional yet in the way the PR needs. This is not a bug in `cluster-backup-operator`/MCH's rendering logic — the template renders exactly what the PR describes; the gap is at the OLMv1 platform level (or this specific OCP/OLMv1 version doesn't yet support it).

Notably, the PR's own source file carries an open `FIXME` referencing an unresolved review thread ([`#4323#pullrequestreview-4593866717`](https://github.com/stolostron/multiclusterhub-operator/pull/4323#pullrequestreview-4593866717)), suggesting this gap may have been a known open question at review time.

## Cross-reference for MCE (which *did* install successfully)

MCE's `ClusterExtension` (`pkg/multiclusterengine/olm/v1/clusterextension.go`) also uses `spec.namespace` scoping but its resolved bundle presumably supports `AllNamespaces` (or MCE's CSV declares broader install-mode support) — that's the likely reason it installed fine while OADP's `OwnNamespace`-only bundle failed. Worth double-checking MCE's bundle CSV install modes for a clean side-by-side comparison if filing a formal bug.

## Related existing docs

- `~/Downloads/ACM & MCE OLMv1 Compatibility Analysis.pdf` (and a `(1)` copy from 2026-07-22) — check these for whether this exact `OwnNamespace`/`AllNamespaces` gap was already flagged there.

## Next steps

- [ ] Hand off this cluster (kept in the failed state) to the installer/OLMv1 team for direct inspection
- [ ] File a Jira against PR #4323 / the OLMv1 OADP install path, referencing this reproduction
- [ ] Ask the OLMv1/OCP platform team whether namespace-scoped (`OwnNamespace`) bundle resolution is supported/planned on OCP 4.21's OLMv1, and if not, what the supported path is for single-tenant-only operators like OADP
- [ ] Once resolved, re-test to confirm before proceeding to the managed-cluster feature-branch changes (blocked on this)
- [ ] **Test on OCP 4.22 with `TechPreviewNoUpgrade` enabled** (see finding below) — high-confidence candidate fix, not yet verified live

## Follow-up finding (2026-07-27, same day): OCP 4.22 likely resolves this, but only as Technology Preview

Checked OCP/OKD 4.22 Extensions docs directly (`docs.redhat.com`/`docs.okd.io`, Extensions → Cluster extensions → Extension configuration). Confirmed:

- OCP 4.22 documents `spec.config.inline.watchNamespace` on `ClusterExtension` as an explicit, supported mechanism for `OwnNamespace`/`SingleNamespace` bundle installs — **exactly** the config PR #4323 already renders, with a compatibility table matching what we found empirically for the OADP bundle (`OwnNamespace`-only → `watchNamespace` required, must equal `spec.namespace`).
- OCP 4.21 (what we tested on) does not document or ship this capability — consistent with what we observed live (the field was accepted by the CRD schema as generic bundle config, but had zero effect on install-mode resolution).
- Traced to upstream `operator-controller`'s `SingleOwnNamespaceInstallSupport` feature gate: briefly promoted to GA (default-on), then **reverted back to Alpha (default-off)** in March 2026 (PR [#2568](https://github.com/operator-framework/operator-controller/pull/2568)) due to concerns raised after GA promotion (PR [#2428](https://github.com/operator-framework/operator-controller/pull/2428)). OCP 4.22 shipping this as Technology Preview is consistent with that upstream alpha status.
- **Caveat:** using it on 4.22 requires enabling the cluster-wide **`TechPreviewNoUpgrade`** FeatureGate/featureSet — an explicit prerequisite in the 4.22 docs. This is a one-way, unsupported-for-production, blocks-further-upgrades setting for the entire cluster. Fine for test purposes; **not viable as a supported customer path** until the upstream feature reaches GA again.

**Not yet verified live** — we don't currently have a 4.22 cluster. Next step if picking this back up: provision an OCP 4.22 cluster, enable `TechPreviewNoUpgrade`, and re-run this exact same install/enable-cluster-backup sequence to confirm the OADP `ClusterExtension` resolves successfully in `OwnNamespace` mode.
