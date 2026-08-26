# macos-workstation-bootstrap

Minimal public entry point for provisioning a clean Apple Silicon Mac from the private `salavert/macos-workstation` configuration repository.

The public repository intentionally contains no workstation secrets, corporate configuration, credentials, private repository inventory, or personal Git configuration. Its job is only to establish the minimum trusted tooling, authenticate GitHub interactively, verify access to the private source of truth, obtain it, validate it, and hand control to its bootstrap.

## Install

On a clean Mac:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/salavert/macos-workstation-bootstrap/main/install.sh)"
```

The installer may open GitHub's browser authentication flow. Homebrew installation may also require normal macOS administrator interaction.

For a review-before-execution workflow:

```bash
curl -fsSLO https://raw.githubusercontent.com/salavert/macos-workstation-bootstrap/main/install.sh
less install.sh
bash install.sh
```

## Read-only modes

Plan without changing the machine:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/salavert/macos-workstation-bootstrap/main/install.sh)" -- --dry-run
```

Or from a local checkout:

```bash
./install.sh --dry-run
```

Health check without reconciliation:

```bash
./install.sh --check
```

Help:

```bash
./install.sh --help
```

## Contract

The installer is designed to be idempotent and reentrant.

Running it repeatedly is supported. It detects current state before acting and never deliberately overwrites ambiguous local state.

Key rules:

- existing Homebrew and GitHub CLI installations are reused;
- an existing authenticated GitHub session is reused only when it can access `salavert/macos-workstation`;
- private repository access is verified before configuring GitHub CLI as the HTTPS Git credential helper or cloning;
- the private repository is cloned only when absent;
- an existing private checkout must have the expected `origin`;
- a private checkout with local changes is never automatically updated;
- updates use `git pull --ff-only` only;
- an unexpected existing destination is an error, not something to delete or replace;
- no private SSH keys or Keychain secrets are copied by this public bootstrap.

If `gh` is authenticated to another GitHub account that cannot read the private workstation repository, the installer stops and asks for the personal account to be selected/authenticated rather than blindly changing account state.

### `--dry-run`

`--dry-run` is read-only. It must not intentionally perform:

- directory or file creation;
- Homebrew/package installation;
- Git authentication changes;
- Git clone/pull operations;
- Keychain writes;
- SSH key generation;
- workstation configuration application.

Read-only network/account checks are allowed. For example, when `gh` is already authenticated, dry-run verifies that the active account can access the private workstation repository.

When the private workstation checkout already exists, its own `bootstrap.sh --dry-run` is invoked so the read-only contract extends through both layers.

### `--check`

`--check` reads state and returns non-zero when required state is missing or unsafe. It does not reconcile the machine. When the private checkout exists, it delegates to `bootstrap.sh --check` as well.

## Provisioning flow

```text
public install.sh
    |
    +-- macOS / Apple Silicon / non-root preflight
    +-- Homebrew
    +-- GitHub CLI
    +-- interactive GitHub authentication
    +-- verify access to salavert/macos-workstation
    +-- HTTPS credential integration
    +-- ~/Developer/personal/macos-workstation
    +-- make test
    +-- private bootstrap.sh
```

The initial private checkout deliberately uses HTTPS because the workstation-specific SSH keys do not exist yet. After the private setup creates the managed SSH host aliases and the personal key is generated/registered, the private runbook switches this checkout's `origin` to `git@github.com-personal:salavert/macos-workstation.git`.

The private repository remains the source of truth for applications, dotfiles, Git/SSH policy, runtime managers, workstation diagnostics, repository inventory, and migration procedures.

## Security boundary

This repository is public by design, so it must stay generic.

Do not add:

- API tokens or credentials;
- corporate hostnames, internal service URLs, VPN/certificate material, or proprietary configuration;
- private repository inventories;
- user email addresses or Git identities;
- private SSH material.

The Homebrew installer is the only remote installer this bootstrap deliberately executes directly. Everything else is obtained through Homebrew/GitHub and then delegated to the versioned private repository.

## Tests

```bash
bash -n install.sh tests/install-test.sh
shellcheck install.sh tests/install-test.sh
shfmt -d -i 2 -ci install.sh tests/install-test.sh
bash tests/install-test.sh
```

CI runs these checks on macOS. The behavioral tests use fake `brew`, `gh`, `git`, and `make` commands and an isolated `HOME`; they verify read-only modes, authenticated private-repository access, destination safety, resumability, and repeated installation without unintended state drift.
