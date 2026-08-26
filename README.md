# macos-workstation-bootstrap

Minimal public loader for the private `salavert/macos-workstation` repository.

This repository is intentionally boring. It exists so a clean Apple Silicon Mac can reach the private source of truth without copying setup commands around.

## Install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/salavert/macos-workstation-bootstrap/main/install.sh)"
```

Inspect the plan first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/salavert/macos-workstation-bootstrap/main/install.sh)" \
  -- --dry-run
```

Or review the script itself before execution:

```bash
curl -fsSLO https://raw.githubusercontent.com/salavert/macos-workstation-bootstrap/main/install.sh
less install.sh
bash install.sh
```

## What it does

```text
macOS / Apple Silicon / non-root
        ↓
Command Line Tools
        ↓
>= 30 GiB free
        ↓
Homebrew
        ↓
GitHub CLI
        ↓
GitHub browser auth + private-repo access when HTTPS is needed
        ↓
clone/update ~/Developer/personal/macos-workstation
        ↓
private bootstrap.sh
```

That is all. Package selection, dotfiles, runtime policy, diagnostics and migration rules belong to the private repository.

The first checkout uses HTTPS because machine-specific SSH keys do not exist yet. After the personal SSH alias is configured, the private runbook changes `origin` to:

```text
git@github.com-personal:salavert/macos-workstation.git
```

On later runs with that SSH origin, the public loader no longer depends on which GitHub account is active in `gh`; Git authentication is owned by the explicit SSH alias.

## Safety

The loader:

- never runs with `sudo`/root;
- refuses an unexpected existing destination;
- refuses to update a dirty workstation checkout;
- updates only with `git pull --ff-only`;
- verifies private-repository access before an HTTPS clone;
- never copies SSH private keys, Keychain state or old-machine files;
- does not run the private repository's test suite as part of normal provisioning;
- delegates immediately to the private bootstrap once the checkout is ready.

`--dry-run` is read-only and may perform read-only account/network checks when the required tools already exist.

## Why there is no `--check`

The public repository is only a loader. Health/readiness belongs to the private source of truth:

```bash
~/Developer/personal/macos-workstation/bootstrap.sh --check
mac-doctor
```

Keeping one health model avoids duplicating policy between public and private repositories.

## Security boundary

Because this repository is public, never add:

- credentials/tokens;
- corporate hostnames, VPN, certificates or proprietary configuration;
- private repository inventories;
- personal/work email identities;
- SSH private material.

The Homebrew installer is the only remote installer executed directly. Everything workstation-specific is delegated to the private repository.

## Tests

```bash
bash -n install.sh tests/install-test.sh
shellcheck install.sh tests/install-test.sh
shfmt -d -i 2 -ci install.sh tests/install-test.sh
bash tests/install-test.sh
```

CI runs these checks on macOS with isolated fixtures and fake external commands.
