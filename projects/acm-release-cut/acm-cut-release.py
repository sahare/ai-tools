#!/usr/bin/env python3
"""
ACM Release Branch Cut Script

Automates the CI configuration changes needed when cutting a new ACM release
branch for stolostron repos in the openshift/release repository.

For each repo, this script:
  1. Updates the main CI config (promotion version + fastforward destination)
  2. Enables promotion on the previous release config (removes disabled: true)
  3. Creates the new release config (copy of previous, with disabled promotion + updated versions)
  4. Adds branch protection rules in the prow config

After running this script, you must run `make update` in the release repo to
regenerate job files.

Usage:
    python3 scripts/acm-cut-release.py --new-version 2.18 \
        --repos cluster-backup-operator volsync-addon-controller \
        --release-repo ~/workspace/src/github.com/sahare/release

    python3 scripts/acm-cut-release.py --new-version 2.18 \
        --repos cluster-backup-operator --dry-run \
        --release-repo ~/workspace/src/github.com/sahare/release
"""

import argparse
import re
import sys
from pathlib import Path


def parse_version(version_str):
    """Parse '2.17' into (2, 17)."""
    parts = version_str.split(".")
    if len(parts) != 2:
        raise ValueError(f"Version must be in MAJOR.MINOR format (e.g., 2.18), got: {version_str}")
    return int(parts[0]), int(parts[1])


def prev_version(version_str):
    """Given '2.18', return '2.17'."""
    major, minor = parse_version(version_str)
    return f"{major}.{minor - 1}"


def version_nodot(version_str):
    """Given '2.18', return '218'."""
    return version_str.replace(".", "")


def read_file(path):
    with open(path, "r") as f:
        return f.read()


def write_file(path, content, dry_run=False):
    if dry_run:
        print(f"  [DRY RUN] Would write {path}")
        return
    with open(path, "w") as f:
        f.write(content)
    print(f"  Written: {path}")


def update_main_config(ci_config_dir, org, repo, new_ver, prev_ver, dry_run=False):
    """Update main config: bump promotion version and fastforward destination."""
    config_dir = ci_config_dir / org / repo
    main_file = config_dir / f"{org}-{repo}-main.yaml"

    if not main_file.exists():
        print(f"  WARNING: Main config not found: {main_file}", file=sys.stderr)
        return False

    content = read_file(main_file)
    original = content

    content = re.sub(
        r'(promotion:\s*\n\s*to:\s*\n\s*- name: ")' + re.escape(prev_ver) + r'"',
        r'\g<1>' + new_ver + '"',
        content,
    )

    content = content.replace(
        f"DESTINATION_BRANCH: release-{prev_ver}",
        f"DESTINATION_BRANCH: release-{new_ver}",
    )

    if content == original:
        print(f"  WARNING: No changes detected in main config. Is {prev_ver} the current version?", file=sys.stderr)
        return False

    write_file(main_file, content, dry_run)
    return True


def enable_prev_release_promotion(ci_config_dir, org, repo, prev_ver, dry_run=False):
    """Remove 'disabled: true' from the previous release config's promotion."""
    config_dir = ci_config_dir / org / repo
    prev_file = config_dir / f"{org}-{repo}-release-{prev_ver}.yaml"

    if not prev_file.exists():
        print(f"  WARNING: Previous release config not found: {prev_file}", file=sys.stderr)
        return False

    content = read_file(prev_file)
    original = content

    content = re.sub(
        r'(promotion:\s*\n\s*to:\s*\n)\s*- disabled: true\n\s*(name:)',
        r'\1  - \2',
        content,
    )

    if content == original:
        print(f"  INFO: No 'disabled: true' found in {prev_file} (may already be enabled)")
        return True

    write_file(prev_file, content, dry_run)
    return True


def create_new_release_config(ci_config_dir, org, repo, new_ver, prev_ver, dry_run=False):
    """Create the new release config by copying previous release and updating versions."""
    config_dir = ci_config_dir / org / repo
    prev_file = config_dir / f"{org}-{repo}-release-{prev_ver}.yaml"
    new_file = config_dir / f"{org}-{repo}-release-{new_ver}.yaml"

    if new_file.exists():
        print(f"  WARNING: New release config already exists: {new_file}", file=sys.stderr)
        return False

    if not prev_file.exists():
        print(f"  WARNING: Previous release config not found: {prev_file}", file=sys.stderr)
        return False

    content = read_file(prev_file)

    content = re.sub(
        r'(promotion:\s*\n\s*to:\s*\n\s*- )(name: "' + re.escape(prev_ver) + r'")',
        r'\1disabled: true\n    \2',
        content,
    )

    content = content.replace(
        f'name: "{prev_ver}"',
        f'name: "{new_ver}"',
    )

    content = re.sub(
        r'OSCI_COMPONENT_VERSION="' + re.escape(prev_ver) + r'\.\d+"',
        f'OSCI_COMPONENT_VERSION="{new_ver}.0"',
        content,
    )

    content = content.replace(
        f"branch: release-{prev_ver}",
        f"branch: release-{new_ver}",
    )

    write_file(new_file, content, dry_run)
    return True


def update_prowconfig(prow_config_dir, org, repo, new_ver, prev_ver, dry_run=False):
    """Add branch protection for the previous release branch in prowconfig."""
    prowconfig_file = prow_config_dir / org / repo / "_prowconfig.yaml"

    if not prowconfig_file.exists():
        print(f"  WARNING: Prow config not found: {prowconfig_file}", file=sys.stderr)
        return False

    content = read_file(prowconfig_file)

    if f"release-{prev_ver}:" in content:
        print(f"  INFO: Branch protection for release-{prev_ver} already exists in prowconfig")
        return True

    existing_branches = re.findall(r"release-(\d+\.\d+):", content)
    if not existing_branches:
        print(f"  WARNING: No existing release branches found in prowconfig", file=sys.stderr)
        return False

    existing_branches.sort(key=lambda v: tuple(int(x) for x in v.split(".")))
    template_ver = existing_branches[-1]
    template_ver_nodot = version_nodot(template_ver)
    prev_ver_nodot = version_nodot(prev_ver)

    pattern = re.compile(
        r"(            release-" + re.escape(template_ver) + r":.*?)(?=\n            release-|\ntide:)",
        re.DOTALL,
    )
    match = pattern.search(content)
    if not match:
        print(f"  WARNING: Could not extract template branch block for release-{template_ver}", file=sys.stderr)
        return False

    template_block = match.group(1)

    new_block = template_block.replace(f"release-{template_ver}", f"release-{prev_ver}")
    new_block = new_block.replace(f"acm-{template_ver_nodot}", f"acm-{prev_ver_nodot}")

    # Guard against missing required_pull_request_reviews (see openshift/release#76040)
    if "required_pull_request_reviews:" not in new_block:
        new_block = new_block.replace(
            "              required_status_checks:",
            "              required_pull_request_reviews:\n"
            "                dismiss_stale_reviews: true\n"
            "                required_approving_review_count: 1\n"
            "              required_status_checks:",
        )

    content = content.replace("\ntide:", f"\n{new_block}\ntide:")

    write_file(prowconfig_file, content, dry_run)
    return True


def process_repo(release_repo, org, repo, new_ver, prev_ver, dry_run=False):
    """Run all steps for a single repo."""
    ci_config_dir = release_repo / "ci-operator" / "config"
    prow_config_dir = release_repo / "core-services" / "prow" / "02_config"

    print(f"\n{'='*60}")
    print(f"Processing: {org}/{repo}")
    print(f"  Previous version: {prev_ver} -> New version: {new_ver}")
    print(f"{'='*60}")

    steps = [
        ("Step 1: Update main config",
         lambda: update_main_config(ci_config_dir, org, repo, new_ver, prev_ver, dry_run)),
        ("Step 2: Enable previous release promotion",
         lambda: enable_prev_release_promotion(ci_config_dir, org, repo, prev_ver, dry_run)),
        ("Step 3: Create new release config",
         lambda: create_new_release_config(ci_config_dir, org, repo, new_ver, prev_ver, dry_run)),
        ("Step 4: Update prow branch protection",
         lambda: update_prowconfig(prow_config_dir, org, repo, new_ver, prev_ver, dry_run)),
    ]

    success = True
    for desc, func in steps:
        print(f"\n{desc}")
        if not func():
            print(f"  FAILED: {desc}")
            success = False

    return success


def main():
    parser = argparse.ArgumentParser(
        description="Automate ACM release branch CI configuration changes",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Cut release-2.18 for two repos:
  python3 scripts/acm-cut-release.py --new-version 2.18 \\
      --repos cluster-backup-operator volsync-addon-controller \\
      --release-repo ~/workspace/src/github.com/sahare/release

  # Dry run to preview changes:
  python3 scripts/acm-cut-release.py --new-version 2.18 \\
      --repos cluster-backup-operator --dry-run \\
      --release-repo ~/workspace/src/github.com/sahare/release

After running, execute `make update` in the release repo.
""",
    )
    parser.add_argument(
        "--new-version", required=True,
        help="New release version (e.g., 2.18)",
    )
    parser.add_argument(
        "--repos", required=True, nargs="+",
        help="Repository names under the org (e.g., cluster-backup-operator)",
    )
    parser.add_argument(
        "--release-repo", required=True,
        help="Path to local openshift/release repo checkout",
    )
    parser.add_argument(
        "--org", default="stolostron",
        help="GitHub organization (default: stolostron)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Preview changes without writing files",
    )

    args = parser.parse_args()

    release_repo = Path(args.release_repo).expanduser().resolve()
    if not (release_repo / "ci-operator").is_dir():
        print(f"ERROR: {release_repo} does not look like an openshift/release checkout", file=sys.stderr)
        sys.exit(1)

    new_ver = args.new_version
    prev_ver_str = prev_version(new_ver)
    parse_version(new_ver)

    if args.dry_run:
        print("*** DRY RUN MODE - no files will be modified ***\n")

    all_success = True
    for repo in args.repos:
        if not process_repo(release_repo, args.org, repo, new_ver, prev_ver_str, args.dry_run):
            all_success = False

    print(f"\n{'='*60}")
    if all_success:
        print("All repos processed successfully!")
        if not args.dry_run:
            print("\nNext steps:")
            print(f"  1. cd {release_repo}")
            print("  2. Run: make update")
            print("  3. Run: make checkconfig")
            print("  4. Review changes with: git diff")
            print("  5. Commit and create PR")
    else:
        print("Some steps had warnings/failures. Review output above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
