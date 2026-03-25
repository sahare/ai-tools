# ACM Cluster Setup

Automated tools for provisioning OpenShift clusters and installing ACM (Advanced Cluster Management) dev builds.

## Scripts

### `scripts/install-acm.sh`

Fully automated ACM dev build installation from `quay.io/acm-d`. Handles pull secret patching, CatalogSource creation, operator installation, and MultiClusterHub creation with progress monitoring.

```bash
# Install ACM 2.17
./scripts/install-acm.sh \
  --server=https://api.mycluster.example.com:6443 \
  --token=sha256~xxxxx \
  --quay-user=myuser \
  --quay-password=mypassword \
  --version=2.17

# With kubeadmin credentials
./scripts/install-acm.sh \
  --server=https://api.mycluster.example.com:6443 \
  --kubeadmin-password=xxxxx-xxxxx-xxxxx-xxxxx \
  --quay-user=myuser \
  --quay-password=mypassword

# Uninstall ACM
./scripts/install-acm.sh --server=... --token=... --uninstall
```

Options:
- `--server` - OpenShift API server URL (required)
- `--token` - Login token (or use `--kubeadmin-password`)
- `--kubeadmin-password` - Kubeadmin password (alternative to `--token`)
- `--quay-user` - quay.io username for acm-d access (required for install)
- `--quay-password` - quay.io CLI password (required for install)
- `--version` - ACM version to install (default: 2.17)
- `--skip-pull-secret` - Skip pull secret patching if already configured
- `--uninstall` - Uninstall ACM from the cluster

## Documentation

- [install-acm-dev-build.md](install-acm-dev-build.md) - Detailed manual installation guide with troubleshooting

## Prerequisites

- `oc` CLI installed and configured
- `jq` installed
- Quay.io credentials with access to `acm-d` organization (get CLI password from quay.io Account Settings > Generate Encrypted Password)
