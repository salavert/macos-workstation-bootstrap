#!/bin/bash
set -euo pipefail

MODE="install"
GITHUB_HOST="github.com"
WORKSTATION_REPOSITORY="${WORKSTATION_REPOSITORY:-salavert/macos-workstation}"
WORKSTATION_DIR="${WORKSTATION_DIR:-${HOME}/Developer/personal/macos-workstation}"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
MINIMUM_FREE_GIB=30
failures=0
github_auth_ready=false
repository_access_ready=false

usage() {
  cat <<'EOF'
Usage: install.sh [--dry-run | --check | --help]

Modes:
  (default)   Reconcile the Mac with the workstation bootstrap prerequisites,
              clone/update the private workstation repository, test it, and run
              its bootstrap.
  --dry-run   Read-only plan. Performs no filesystem, Git, authentication,
              package-manager, Keychain, or workstation mutations.
  --check     Read-only health check. Exits non-zero when required state is
              missing or unsafe.
  --help      Show this help.

Environment overrides (primarily for testing):
  WORKSTATION_REPOSITORY  GitHub owner/repository. Default: salavert/macos-workstation
  WORKSTATION_DIR         Checkout destination. Default:
                          ~/Developer/personal/macos-workstation
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
  if [[ "${failures}" -ne 0 ]]; then
    exit 1
  fi
  exit 0
}

fatal() {
  fail "$1"
  finish
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      if [[ "${MODE}" != "install" ]]; then
        echo "Error: choose only one mode." >&2
        exit 2
      fi
      MODE="dry-run"
      ;;
    --check)
      if [[ "${MODE}" != "install" ]]; then
        echo "Error: choose only one mode." >&2
        exit 2
      fi
      MODE="check"
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  fatal "macOS is required"
fi
pass "macOS"

if [[ "$(uname -m)" != "arm64" ]]; then
  fatal "Apple Silicon (arm64) is required"
fi
pass "Apple Silicon"

if [[ "${EUID}" -eq 0 ]]; then
  fatal "do not run this installer as root or with sudo"
fi
pass "running as a standard user"

ensure_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1; then
    pass "Xcode/Command Line Tools selected"
    return 0
  fi

  case "${MODE}" in
    check)
      fail "Xcode/Command Line Tools are missing"
      ;;
    dry-run)
      would "request Apple's Command Line Tools installer before Homebrew"
      ;;
    install)
      action "request Apple's Command Line Tools installer"
      xcode-select --install >/dev/null 2>&1 || true
      if xcode-select -p >/dev/null 2>&1; then
        pass "Xcode/Command Line Tools selected"
      else
        fail "Command Line Tools installation is pending; complete Apple's installer and rerun"
      fi
      ;;
  esac
}

check_disk_space() {
  local target="/System/Volumes/Data"
  local available_kb
  local available_gib
  local minimum_kb=$((MINIMUM_FREE_GIB * 1024 * 1024))

  if [[ ! -d "${target}" ]]; then
    target="/"
  fi

  available_kb="$(df -Pk "${target}" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "${available_kb}" =~ ^[0-9]+$ ]]; then
    available_gib=$((available_kb / 1024 / 1024))
  else
    fail "unable to determine available disk space"
    return 0
  fi

  if [[ "${available_kb}" -ge "${minimum_kb}" ]]; then
    pass "at least ${MINIMUM_FREE_GIB} GiB free (${available_gib} GiB available)"
  else
    fail "at least ${MINIMUM_FREE_GIB} GiB free is required before provisioning (${available_gib} GiB available)"
  fi
}

configure_brew_path() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
}

ensure_homebrew() {
  configure_brew_path
  if command -v brew >/dev/null 2>&1; then
    pass "Homebrew available"
    return 0
  fi

  case "${MODE}" in
    check)
      fail "Homebrew missing"
      return 0
      ;;
    dry-run)
      would "install Homebrew using the official installer"
      return 0
      ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    fatal "curl is required to install Homebrew"
  fi

  action "install Homebrew using the official installer"
  /bin/bash -c "$(curl -fsSL "${HOMEBREW_INSTALL_URL}")"
  configure_brew_path

  if ! command -v brew >/dev/null 2>&1; then
    fatal "Homebrew installation completed but brew is unavailable"
  fi
  pass "Homebrew installed"
}

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    pass "GitHub CLI available"
    return 0
  fi

  case "${MODE}" in
    check)
      fail "GitHub CLI missing"
      return 0
      ;;
    dry-run)
      would "install GitHub CLI with Homebrew"
      return 0
      ;;
  esac

  if ! command -v brew >/dev/null 2>&1; then
    fatal "cannot install GitHub CLI because Homebrew is unavailable"
  fi

  action "install GitHub CLI with Homebrew"
  brew install gh

  if ! command -v gh >/dev/null 2>&1; then
    fatal "GitHub CLI installation completed but gh is unavailable"
  fi
  pass "GitHub CLI installed"
}

ensure_github_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    case "${MODE}" in
      check) fail "GitHub authentication cannot be checked without gh" ;;
      dry-run) would "authenticate the personal GitHub account in the browser" ;;
      *) fatal "GitHub CLI is unavailable" ;;
    esac
    return 0
  fi

  if gh auth status --hostname "${GITHUB_HOST}" >/dev/null 2>&1; then
    github_auth_ready=true
    pass "GitHub authentication available"
    return 0
  fi

  case "${MODE}" in
    check)
      fail "GitHub authentication missing"
      ;;
    dry-run)
      would "authenticate the personal GitHub account in the browser"
      ;;
    install)
      action "authenticate the personal GitHub account in the browser"
      gh auth login --hostname "${GITHUB_HOST}" --git-protocol https --web
      if gh auth status --hostname "${GITHUB_HOST}" >/dev/null 2>&1; then
        github_auth_ready=true
        pass "GitHub authentication available"
      else
        fail "GitHub authentication did not become available"
      fi
      ;;
  esac
}

ensure_repository_access() {
  if ! command -v gh >/dev/null 2>&1; then
    case "${MODE}" in
      check) fail "private repository access cannot be checked without gh" ;;
      dry-run) would "verify access to ${WORKSTATION_REPOSITORY} after GitHub CLI is available" ;;
      *) fail "GitHub CLI is unavailable; cannot verify private repository access" ;;
    esac
    return 0
  fi

  if [[ "${github_auth_ready}" != true ]]; then
    case "${MODE}" in
      check) fail "private repository access cannot be checked without GitHub authentication" ;;
      dry-run) would "verify access to ${WORKSTATION_REPOSITORY} after authentication" ;;
      *) fail "GitHub authentication is unavailable; cannot access ${WORKSTATION_REPOSITORY}" ;;
    esac
    return 0
  fi

  if gh repo view "${WORKSTATION_REPOSITORY}" --json nameWithOwner --jq '.nameWithOwner' >/dev/null 2>&1; then
    repository_access_ready=true
    pass "GitHub access to ${WORKSTATION_REPOSITORY}"
  else
    fail "authenticated GitHub account cannot access ${WORKSTATION_REPOSITORY}; switch/login to the personal account and rerun"
  fi
}

ensure_chezmoi() {
  if command -v chezmoi >/dev/null 2>&1; then
    pass "chezmoi available for repository tests"
    return 0
  fi

  case "${MODE}" in
    check)
      fail "chezmoi missing"
      ;;
    dry-run)
      would "install chezmoi with Homebrew before running repository tests"
      ;;
    install)
      if ! command -v brew >/dev/null 2>&1; then
        fail "cannot install chezmoi because Homebrew is unavailable"
        return 0
      fi
      action "install chezmoi with Homebrew before running repository tests"
      brew install chezmoi
      if command -v chezmoi >/dev/null 2>&1; then
        pass "chezmoi installed"
      else
        fail "chezmoi installation completed but chezmoi is unavailable"
      fi
      ;;
  esac
}

configure_git_credentials() {
  if [[ "${MODE}" != "install" || "${repository_access_ready}" != true ]]; then
    return 0
  fi

  action "configure Git to use GitHub CLI credentials for HTTPS"
  gh auth setup-git --hostname "${GITHUB_HOST}"
}

origin_matches_expected_repository() {
  local origin="$1"
  local expected="${WORKSTATION_REPOSITORY}"
  origin="${origin%.git}"

  case "${origin}" in
    "https://github.com/${expected}" | \
      "git@github.com:${expected}" | \
      "git@github.com-personal:${expected}" | \
      "ssh://git@github.com/${expected}")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

repository_ready=false
ensure_repository() {
  local expected_https="https://github.com/${WORKSTATION_REPOSITORY}.git"
  local origin
  local status

  if [[ "${MODE}" == "install" && "${repository_access_ready}" != true ]]; then
    return 0
  fi

  if [[ ! -e "${WORKSTATION_DIR}" ]]; then
    case "${MODE}" in
      check)
        fail "workstation repository missing: ${WORKSTATION_DIR}"
        return 0
        ;;
      dry-run)
        would "clone ${expected_https} -> ${WORKSTATION_DIR}"
        return 0
        ;;
      install)
        action "clone ${expected_https} -> ${WORKSTATION_DIR}"
        mkdir -p "$(dirname "${WORKSTATION_DIR}")"
        git clone -- "${expected_https}" "${WORKSTATION_DIR}"
        repository_ready=true
        pass "workstation repository cloned"
        return 0
        ;;
    esac
  fi

  if [[ ! -d "${WORKSTATION_DIR}" || ! -e "${WORKSTATION_DIR}/.git" ]]; then
    fail "destination exists but is not the workstation Git repository: ${WORKSTATION_DIR}"
    return 0
  fi

  origin="$(git -C "${WORKSTATION_DIR}" remote get-url origin 2>/dev/null || true)"
  if [[ -z "${origin}" ]] || ! origin_matches_expected_repository "${origin}"; then
    fail "unexpected workstation origin: ${origin:-missing}"
    return 0
  fi
  pass "workstation repository origin"

  status="$(git -C "${WORKSTATION_DIR}" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  if [[ -n "${status}" ]]; then
    fail "workstation repository has local changes; refusing automatic update"
    return 0
  fi
  pass "workstation repository is clean"
  repository_ready=true

  case "${MODE}" in
    check)
      skip "repository update in check mode"
      ;;
    dry-run)
      would "git -C ${WORKSTATION_DIR} pull --ff-only"
      ;;
    install)
      action "update workstation repository with fast-forward only"
      git -C "${WORKSTATION_DIR}" pull --ff-only
      ;;
  esac
}

run_private_workstation() {
  if [[ "${repository_ready}" != true ]]; then
    case "${MODE}" in
      dry-run)
        would "run private repository tests after the repository is available"
        would "run the private workstation bootstrap"
        ;;
    esac
    return 0
  fi

  if [[ ! -f "${WORKSTATION_DIR}/Makefile" ]]; then
    fail "workstation Makefile missing"
    return 0
  fi
  if [[ ! -x "${WORKSTATION_DIR}/bootstrap.sh" ]]; then
    fail "workstation bootstrap is missing or not executable"
    return 0
  fi

  case "${MODE}" in
    check)
      if "${WORKSTATION_DIR}/bootstrap.sh" --check; then
        pass "private workstation bootstrap check"
      else
        fail "private workstation bootstrap check failed"
      fi
      ;;
    dry-run)
      would "make -C ${WORKSTATION_DIR} test"
      if "${WORKSTATION_DIR}/bootstrap.sh" --dry-run; then
        pass "private workstation dry-run"
      else
        fail "private workstation dry-run failed"
      fi
      ;;
    install)
      if ! command -v chezmoi >/dev/null 2>&1; then
        fail "chezmoi unavailable before repository tests; refusing to continue"
        return 0
      fi
      action "run workstation repository tests"
      make -C "${WORKSTATION_DIR}" test
      action "run private workstation bootstrap"
      "${WORKSTATION_DIR}/bootstrap.sh"
      ;;
  esac
}

ensure_command_line_tools
check_disk_space
if [[ "${MODE}" == "install" && "${failures}" -ne 0 ]]; then
  finish
fi

ensure_homebrew
ensure_gh
ensure_github_auth
ensure_repository_access
if [[ "${MODE}" == "install" && "${failures}" -ne 0 ]]; then
  finish
fi

ensure_chezmoi
if [[ "${MODE}" == "install" && "${failures}" -ne 0 ]]; then
  finish
fi

configure_git_credentials
ensure_repository
run_private_workstation

if [[ "${MODE}" == "install" && "${failures}" -eq 0 ]]; then
  cat <<'EOF'

Base workstation provisioning completed.

Continue with the private repository's documented manual steps, then run:
  mac-doctor

After SSH identities are configured, review repository cloning with:
  bash ~/Developer/personal/macos-workstation/scripts/clone-repositories.sh --dry-run
EOF
fi

finish
