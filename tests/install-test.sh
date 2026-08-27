#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fakebin="${test_root}/bin"
log="${test_root}/commands.log"
mkdir -p "${fakebin}"
: >"${log}"

cat >"${fakebin}/xcode-select" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'xcode-select %s\n' "$*" >>"${BOOTSTRAP_TEST_LOG}"
if [[ "${1:-}" == "-p" ]]; then
  if [[ "${BOOTSTRAP_TEST_CLT_STATUS:-0}" == "0" ]]; then
    echo /Library/Developer/CommandLineTools
    exit 0
  fi
  exit 1
fi
exit 0
EOF

cat >"${fakebin}/df" <<'EOF'
#!/bin/bash
set -euo pipefail
available="${BOOTSTRAP_TEST_AVAILABLE_KB:-90000000}"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/test 100000000 1000 %s 1%% /System/Volumes/Data\n' "${available}"
EOF

cat >"${fakebin}/brew" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'brew %s\n' "$*" >>"${BOOTSTRAP_TEST_LOG}"
exit 0
EOF

cat >"${fakebin}/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"${BOOTSTRAP_TEST_LOG}"
if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  exit "${BOOTSTRAP_TEST_GH_STATUS:-0}"
fi
if [[ "${1:-} ${2:-}" == "repo view" ]]; then
  exit "${BOOTSTRAP_TEST_GH_REPO_ACCESS:-0}"
fi
exit 0
EOF

cat >"${fakebin}/git" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${BOOTSTRAP_TEST_LOG}"

if [[ "${1:-}" == "clone" ]]; then
  target="${!#}"
  mkdir -p "${target}/.git"
  cat >"${target}/bootstrap.sh" <<'EOF_BOOTSTRAP'
#!/bin/bash
set -euo pipefail
printf 'private-bootstrap %s\n' "$*" >>"${BOOTSTRAP_TEST_LOG}"
case "${1:-}" in
  --dry-run)
    exit 0
    ;;
  "")
    mkdir -p "${HOME}/.workstation-test"
    printf 'installed\n' >"${HOME}/.workstation-test/state"
    ;;
  *)
    exit 2
    ;;
esac
EOF_BOOTSTRAP
  chmod 755 "${target}/bootstrap.sh"
  exit 0
fi

if [[ "${1:-}" == "-C" ]]; then
  shift 2
  case "$*" in
    "remote get-url origin")
      printf '%s\n' "${BOOTSTRAP_TEST_ORIGIN:-https://github.com/salavert/macos-workstation.git}"
      exit 0
      ;;
    "status --porcelain=v1 --untracked-files=all")
      if [[ "${BOOTSTRAP_TEST_GIT_DIRTY:-0}" == "1" ]]; then
        printf ' M README.md\n'
      fi
      exit 0
      ;;
    "pull --ff-only")
      exit 0
      ;;
  esac
fi

printf 'unexpected fake git invocation: %s\n' "$*" >&2
exit 3
EOF

chmod 755 "${fakebin}/xcode-select" "${fakebin}/df" "${fakebin}/brew" "${fakebin}/gh" "${fakebin}/git"

run_installer() {
  local home="$1"
  shift
  HOME="${home}" \
    PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
    BOOTSTRAP_TEST_LOG="${log}" \
    bash "${repo_root}/install.sh" "$@"
}

fail_if_log_matches() {
  local pattern="$1"
  local message="$2"
  if grep -Eq "${pattern}" "${log}"; then
    cat "${log}" >&2
    echo "${message}" >&2
    exit 1
  fi
}

# Help and dry-run are harmless.
help_home="${test_root}/help-home"
mkdir -p "${help_home}"
run_installer "${help_home}" --help >/dev/null
if [[ -n "$(find "${help_home}" -mindepth 1 -print -quit)" ]]; then
  echo "--help mutated HOME" >&2
  exit 1
fi

dry_home="${test_root}/dry-home"
mkdir -p "${dry_home}"
: >"${log}"
run_installer "${dry_home}" --dry-run >"${test_root}/dry.out"
if [[ -n "$(find "${dry_home}" -mindepth 1 -print -quit)" ]]; then
  echo "--dry-run mutated HOME" >&2
  exit 1
fi
fail_if_log_matches \
  'xcode-select --install|brew install|gh auth login|gh auth setup-git|git clone|git -C .* pull|private-bootstrap' \
  "--dry-run invoked a mutation"
if ! grep -Fq 'WOULD clone https://github.com/salavert/macos-workstation.git' "${test_root}/dry.out"; then
  cat "${test_root}/dry.out" >&2
  echo "--dry-run did not describe the private clone" >&2
  exit 1
fi

# Missing CLT and low disk fail before package/Git mutation.
clt_home="${test_root}/clt-home"
mkdir -p "${clt_home}"
: >"${log}"
set +e
HOME="${clt_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_CLT_STATUS=1 \
  bash "${repo_root}/install.sh" >/dev/null 2>&1
clt_status=$?
set -e
if [[ "${clt_status}" -eq 0 ]]; then
  echo "missing CLT accepted" >&2
  exit 1
fi
if ! grep -q '^xcode-select --install$' "${log}"; then
  cat "${log}" >&2
  echo "missing CLT did not request Apple's installer" >&2
  exit 1
fi
fail_if_log_matches '^brew |^gh |^git clone' "setup continued before CLT was ready"

disk_home="${test_root}/disk-home"
mkdir -p "${disk_home}"
: >"${log}"
set +e
HOME="${disk_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_AVAILABLE_KB=1000000 \
  bash "${repo_root}/install.sh" >/dev/null 2>&1
disk_status=$?
set -e
if [[ "${disk_status}" -eq 0 ]]; then
  echo "low disk accepted" >&2
  exit 1
fi
fail_if_log_matches '^brew |^gh |^git clone' "setup continued with insufficient disk space"

# First install verifies private access, clones, and hands off directly to private bootstrap.
install_home="${test_root}/install-home"
mkdir -p "${install_home}"
: >"${log}"
run_installer "${install_home}" >"${test_root}/install.out"
workstation="${install_home}/Developer/personal/macos-workstation"
if [[ ! -d "${workstation}/.git" || ! -x "${workstation}/bootstrap.sh" ]]; then
  echo "first install did not create the workstation checkout" >&2
  exit 1
fi
if [[ ! -f "${install_home}/.workstation-test/state" ]]; then
  echo "private bootstrap was not executed" >&2
  exit 1
fi
if ! grep -q '^gh repo view salavert/macos-workstation ' "${log}"; then
  cat "${log}" >&2
  echo "private repository access was not verified" >&2
  exit 1
fi
if ! grep -q '^gh auth setup-git ' "${log}"; then
  cat "${log}" >&2
  echo "HTTPS credentials were not configured after access verification" >&2
  exit 1
fi
if ! grep -q '^git clone ' "${log}"; then
  cat "${log}" >&2
  echo "private repository was not cloned" >&2
  exit 1
fi
if ! grep -q '^private-bootstrap $' "${log}"; then
  cat "${log}" >&2
  echo "private bootstrap handoff did not occur" >&2
  exit 1
fi
fail_if_log_matches '^make ' "public loader unexpectedly ran repository tests"

# HTTPS access failure blocks cloning.
access_home="${test_root}/access-home"
mkdir -p "${access_home}"
: >"${log}"
set +e
HOME="${access_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_GH_REPO_ACCESS=1 \
  bash "${repo_root}/install.sh" >"${test_root}/access.out" 2>&1
access_status=$?
set -e
if [[ "${access_status}" -eq 0 ]]; then
  echo "inaccessible private repo accepted" >&2
  exit 1
fi
fail_if_log_matches '^git clone ' "private repository was cloned without verified access"

# Once the checkout uses canonical SSH, public re-entry does not depend on gh auth.
: >"${log}"
HOME="${install_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_ORIGIN='git@github.com:salavert/macos-workstation.git' \
  BOOTSTRAP_TEST_GH_STATUS=1 \
  BOOTSTRAP_TEST_GH_REPO_ACCESS=1 \
  bash "${repo_root}/install.sh" >/dev/null
fail_if_log_matches '^gh repo view |^gh auth setup-git ' "SSH re-entry unexpectedly depended on gh authentication"
if ! grep -q 'git -C .* pull --ff-only' "${log}"; then
  cat "${log}" >&2
  echo "SSH re-entry did not update with pull --ff-only" >&2
  exit 1
fi
if ! grep -q '^private-bootstrap $' "${log}"; then
  cat "${log}" >&2
  echo "SSH re-entry did not hand off to private bootstrap" >&2
  exit 1
fi

# Old synthetic work/personal aliases are deliberately rejected.
legacy_home="${test_root}/legacy-home"
mkdir -p "${legacy_home}/Developer/personal/macos-workstation/.git"
cat >"${legacy_home}/Developer/personal/macos-workstation/bootstrap.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "${legacy_home}/Developer/personal/macos-workstation/bootstrap.sh"
set +e
HOME="${legacy_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_ORIGIN='git@github.com-personal:salavert/macos-workstation.git' \
  bash "${repo_root}/install.sh" >/dev/null 2>&1
legacy_status=$?
set -e
if [[ "${legacy_status}" -eq 0 ]]; then
  echo "legacy GitHub SSH alias was accepted" >&2
  exit 1
fi

# Existing non-Git data and dirty checkouts are preserved/refused.
non_git_home="${test_root}/non-git-home"
mkdir -p "${non_git_home}/Developer/personal/macos-workstation"
printf 'keep\n' >"${non_git_home}/Developer/personal/macos-workstation/data.txt"
set +e
run_installer "${non_git_home}" >/dev/null 2>&1
non_git_status=$?
set -e
if [[ "${non_git_status}" -eq 0 || ! -f "${non_git_home}/Developer/personal/macos-workstation/data.txt" ]]; then
  echo "existing non-Git destination was not preserved/refused" >&2
  exit 1
fi

dirty_home="${test_root}/dirty-home"
mkdir -p "${dirty_home}/Developer/personal/macos-workstation/.git"
cat >"${dirty_home}/Developer/personal/macos-workstation/bootstrap.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "${dirty_home}/Developer/personal/macos-workstation/bootstrap.sh"
: >"${log}"
set +e
HOME="${dirty_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_GIT_DIRTY=1 \
  bash "${repo_root}/install.sh" >/dev/null 2>&1
dirty_status=$?
set -e
if [[ "${dirty_status}" -eq 0 ]]; then
  echo "dirty checkout was accepted" >&2
  exit 1
fi
fail_if_log_matches 'git -C .* pull --ff-only' "dirty checkout was updated"

# Unknown arguments are usage errors.
set +e
run_installer "${dry_home}" --unknown >/dev/null 2>&1
unknown_status=$?
set -e
if [[ "${unknown_status}" -ne 2 ]]; then
  echo "unknown argument did not return usage status 2" >&2
  exit 1
fi

echo "Bootstrap behavioral tests passed."
