#!/bin/bash
set -euo pipefail

MODE="install"
GITHUB_HOST="github.com"
WORKSTATION_REPOSITORY="${WORKSTATION_REPOSITORY:-salavert/macos-workstation}"
WORKSTATION_DIR="${WORKSTATION_DIR:-${HOME}/Developer/personal/macos-workstation}"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
MINIMUM_FREE_GIB=30
failures=0
repository_ready=false
repository_needs_https_auth=false

usage() {
  cat <<'EOF'
Usage: install.sh [--dry-run | --help]

Minimal loader for the private macos-workstation repository.

  (default)   Prepare bootstrap prerequisites, clone/update the private repo,
              and run its bootstrap.
  --dry-run   Read-only plan. Makes no filesystem, Git, auth or package changes.
  --help      Show this help.

Environment overrides:
  WORKSTATION_REPOSITORY  Default: salavert/macos-workstation
  WORKSTATION_DIR         Default: ~/Developer/personal/macos-workstation
EOF
}

pass() {
  printf 'PASS  %s\n' "$1"
}

skip() {
  printf 'SKIP  %s\n' "$1"
}

would() {
  printf 'WOULD %s\n' "$1"
}

action() {
  printf 'DO    %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

finish() {
  printf '\nResult: %d failure(s)\n' "${failures}"
  [[ "${failures}" -eq 0 ]]
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      [[ "${MODE}" == "install" ]] || {
        echo "Error: choose only one mode." >&2
        exit 2
      }
      MODE="dry-run"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

printf 'macos-workstation bootstrap (%s)\n\n' "${MODE}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  pass "macOS"
else
  fail "macOS is required"
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  pass "Apple Silicon"
else
  fail "Apple Silicon (arm64) is required"
fi

if [[ "${EUID}" -ne 0 ]]; then
  pass "running as a standard user"
else
  fail "do not run this installer as root or with sudo"
fi

if xcode-select -p >/dev/null 2>&1; then
  pass "Xcode/Command Line Tools selected"
elif [[ "${MODE}" == "dry-run" ]]; then
  would "request Apple's Command Line Tools installer before Homebrew"
else
  action "request Apple's Command Line Tools installer"
  xcode-select --install >/dev/null 2>&1 || true
  fail "Command Line Tools installation is pending; complete Apple's installer and rerun"
fi

available_kb="$(df -Pk /System/Volumes/Data 2>/dev/null | awk 'NR == 2 {print $4}')"
minimum_kb=$((MINIMUM_FREE_GIB * 1024 * 1024))
if [[ "${available_kb}" =~ ^[0-9]+$ ]] && [[ "${available_kb}" -ge "${minimum_kb}" ]]; then
  pass "at least ${MINIMUM_FREE_GIB} GiB free"
else
  fail "at least ${MINIMUM_FREE_GIB} GiB free is required before provisioning"
fi

if [[ "${MODE}" == "install" && "${failures}" -ne 0 ]]; then
  finish
  exit 1
fi

configure_brew_path() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
}

configure_brew_path
if command -v brew >/dev/null 2>&1; then
  pass "Homebrew available"
elif [[ "${MODE}" == "dry-run" ]]; then
  would "install Homebrew using the official installer"
else
  action "install Homebrew using the official installer"
  /bin/bash -c "$(curl -fsSL "${HOMEBREW_INSTALL_URL}")"
  configure_brew_path
  if command -v brew >/dev/null 2>&1; then
    pass "Homebrew installed"
  else
    fail "Homebrew installation completed but brew is unavailable"
  fi
fi

origin_matches() {
  local origin="${1%.git}"
  case "${origin}" in
    "https://github.com/${WORKSTATION_REPOSITORY}" | \
      "git@github.com:${WORKSTATION_REPOSITORY}" | \
      "ssh://git@github.com/${WORKSTATION_REPOSITORY}")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if [[ ! -e "${WORKSTATION_DIR}" ]]; then
  repository_needs_https_auth=true
elif [[ ! -d "${WORKSTATION_DIR}/.git" ]]; then
  fail "destination exists but is not a Git checkout: ${WORKSTATION_DIR}"
else
  origin="$(git -C "${WORKSTATION_DIR}" remote get-url origin 2>/dev/null || true)"
  if ! origin_matches "${origin}"; then
    fail "unexpected workstation origin: ${origin:-missing}"
  else
    pass "workstation repository origin"
    case "${origin}" in
      https://github.com/*)
        repository_needs_https_auth=true
        ;;
      git@github.com:* | ssh://git@github.com/*)
        skip "GitHub HTTPS credentials not required for SSH origin"
        ;;
    esac
  fi

  status="$(git -C "${WORKSTATION_DIR}" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  if [[ -n "${status}" ]]; then
    fail "workstation repository has local changes; refusing automatic update"
  elif [[ "${failures}" -eq 0 ]]; then
    pass "workstation repository is clean"
    repository_ready=true
  fi
fi

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    pass "GitHub CLI available"
    return 0
  fi

  if [[ "${MODE}" == "dry-run" ]]; then
    would "install GitHub CLI with Homebrew"
    return 0
  fi

  action "install GitHub CLI with Homebrew"
  brew install gh
  if command -v gh >/dev/null 2>&1; then
    pass "GitHub CLI installed"
  else
    fail "GitHub CLI installation completed but gh is unavailable"
  fi
}

if [[ "${repository_needs_https_auth}" == true ]]; then
  ensure_gh

  if ! command -v gh >/dev/null 2>&1; then
    if [[ "${MODE}" == "dry-run" ]]; then
      would "authenticate GitHub after gh is installed"
      would "verify access to ${WORKSTATION_REPOSITORY}"
    else
      fail "GitHub CLI unavailable"
    fi
  elif gh auth status --hostname "${GITHUB_HOST}" >/dev/null 2>&1; then
    pass "GitHub authentication available"
    if gh repo view "${WORKSTATION_REPOSITORY}" --json nameWithOwner --jq '.nameWithOwner' >/dev/null 2>&1; then
      pass "GitHub access to ${WORKSTATION_REPOSITORY}"
      if [[ "${MODE}" == "install" ]]; then
        action "configure GitHub CLI credentials for HTTPS"
        gh auth setup-git --hostname "${GITHUB_HOST}"
      fi
    else
      fail "authenticated GitHub account cannot access ${WORKSTATION_REPOSITORY}; authenticate the account that owns this repository and rerun"
    fi
  elif [[ "${MODE}" == "dry-run" ]]; then
    would "authenticate the GitHub account in the browser"
    would "verify access to ${WORKSTATION_REPOSITORY}"
  else
    action "authenticate the GitHub account in the browser"
    gh auth login --hostname "${GITHUB_HOST}" --git-protocol https --web
    if gh repo view "${WORKSTATION_REPOSITORY}" --json nameWithOwner --jq '.nameWithOwner' >/dev/null 2>&1; then
      pass "GitHub access to ${WORKSTATION_REPOSITORY}"
      action "configure GitHub CLI credentials for HTTPS"
      gh auth setup-git --hostname "${GITHUB_HOST}"
    else
      fail "authenticated GitHub account cannot access ${WORKSTATION_REPOSITORY}"
    fi
  fi
else
  skip "GitHub CLI bootstrap authentication not required"
fi

if [[ "${MODE}" == "install" && "${failures}" -ne 0 ]]; then
  finish
  exit 1
fi

if [[ ! -e "${WORKSTATION_DIR}" ]]; then
  expected_https="https://github.com/${WORKSTATION_REPOSITORY}.git"
  if [[ "${MODE}" == "dry-run" ]]; then
    would "clone ${expected_https} -> ${WORKSTATION_DIR}"
  else
    action "clone ${expected_https} -> ${WORKSTATION_DIR}"
    mkdir -p "$(dirname "${WORKSTATION_DIR}")"
    git clone -- "${expected_https}" "${WORKSTATION_DIR}"
    repository_ready=true
    pass "workstation repository cloned"
  fi
elif [[ "${repository_ready}" == true ]]; then
  if [[ "${MODE}" == "dry-run" ]]; then
    would "git -C ${WORKSTATION_DIR} pull --ff-only"
  else
    action "update workstation repository with fast-forward only"
    git -C "${WORKSTATION_DIR}" pull --ff-only
  fi
fi

if [[ "${MODE}" == "dry-run" ]]; then
  if [[ -x "${WORKSTATION_DIR}/bootstrap.sh" ]]; then
    "${WORKSTATION_DIR}/bootstrap.sh" --dry-run
  else
    would "run the private workstation bootstrap after clone"
  fi
  finish
  exit $?
fi

if [[ ! -x "${WORKSTATION_DIR}/bootstrap.sh" ]]; then
  fail "private workstation bootstrap is missing: ${WORKSTATION_DIR}/bootstrap.sh"
  finish
  exit 1
fi

action "run private workstation bootstrap"
"${WORKSTATION_DIR}/bootstrap.sh"

cat <<'EOF'

Base workstation provisioning completed.
Complete docs/MANUAL-STEPS.md, then run mac-doctor.
EOF

finish
