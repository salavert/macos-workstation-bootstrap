#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

fakebin="${test_root}/bin"
log="${test_root}/commands.log"
mkdir -p "${fakebin}"
: >"${log}"

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
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit "${BOOTSTRAP_TEST_GH_STATUS:-0}"
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
  cat >"${target}/Makefile" <<'EOF_MAKE'
test:
	@true
EOF_MAKE
  cat >"${target}/bootstrap.sh" <<'EOF_BOOTSTRAP'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  --check | --dry-run)
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
  directory="$2"
  shift 2
  case "${1:-} ${2:-} ${3:-}" in
    "remote get-url origin")
      printf 'https://github.com/salavert/macos-workstation.git\n'
      exit 0
      ;;
    "status --porcelain=v1 --untracked-files=all")
      if [[ "${BOOTSTRAP_TEST_GIT_DIRTY:-0}" == "1" ]]; then
        printf ' M README.md\n'
      fi
      exit 0
      ;;
    "pull --ff-only ")
      exit 0
      ;;
  esac
  printf 'unexpected fake git invocation in %s: %s\n' "${directory}" "$*" >&2
  exit 3
fi

printf 'unexpected fake git invocation: %s\n' "$*" >&2
exit 3
EOF

cat >"${fakebin}/make" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'make %s\n' "$*" >>"${BOOTSTRAP_TEST_LOG}"
exit 0
EOF

chmod 755 "${fakebin}/brew" "${fakebin}/gh" "${fakebin}/git" "${fakebin}/make"

run_installer() {
  local home="$1"
  shift
  HOME="${home}" \
    PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
    BOOTSTRAP_TEST_LOG="${log}" \
    bash "${repo_root}/install.sh" "$@"
}

snapshot_home() {
  local home="$1"
  (
    cd "${home}"
    find . -type d -print | LC_ALL=C sort
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      shasum "${file}"
    done
  )
}

# Help must be harmless.
help_home="${test_root}/help-home"
mkdir -p "${help_home}"
run_installer "${help_home}" --help >/dev/null
if [[ -n "$(find "${help_home}" -mindepth 1 -print -quit)" ]]; then
  echo "--help mutated HOME." >&2
  exit 1
fi

# Dry-run on a clean machine must not create anything.
dry_home="${test_root}/dry-home"
mkdir -p "${dry_home}"
: >"${log}"
run_installer "${dry_home}" --dry-run >"${test_root}/dry-run.out"
if [[ -n "$(find "${dry_home}" -mindepth 1 -print -quit)" ]]; then
  echo "--dry-run mutated HOME." >&2
  find "${dry_home}" -mindepth 1 -print >&2
  exit 1
fi
if grep -Eq 'gh auth setup-git|git clone|git -C|make ' "${log}"; then
  cat "${log}" >&2
  echo "--dry-run invoked a mutating external command." >&2
  exit 1
fi
if ! grep -q 'WOULD clone' "${test_root}/dry-run.out"; then
  cat "${test_root}/dry-run.out" >&2
  echo "--dry-run did not describe the repository clone." >&2
  exit 1
fi

# Check on a clean machine must fail but remain read-only.
check_home="${test_root}/check-home"
mkdir -p "${check_home}"
: >"${log}"
set +e
run_installer "${check_home}" --check >"${test_root}/check.out" 2>&1
check_status=$?
set -e
if [[ "${check_status}" -eq 0 ]]; then
  cat "${test_root}/check.out" >&2
  echo "--check unexpectedly succeeded on an unprovisioned HOME." >&2
  exit 1
fi
if [[ -n "$(find "${check_home}" -mindepth 1 -print -quit)" ]]; then
  echo "--check mutated HOME." >&2
  exit 1
fi
if grep -Eq 'gh auth setup-git|git clone|git -C .* pull|make ' "${log}"; then
  cat "${log}" >&2
  echo "--check invoked a mutating external command." >&2
  exit 1
fi

# First install creates the desired fixture state.
install_home="${test_root}/install-home"
mkdir -p "${install_home}"
: >"${log}"
run_installer "${install_home}" >"${test_root}/first-install.out"
workstation="${install_home}/Developer/personal/macos-workstation"
if [[ ! -d "${workstation}/.git" || ! -x "${workstation}/bootstrap.sh" ]]; then
  cat "${test_root}/first-install.out" >&2
  echo "First installation did not create the workstation checkout." >&2
  exit 1
fi
if [[ ! -f "${install_home}/.workstation-test/state" ]]; then
  echo "Private bootstrap was not executed." >&2
  exit 1
fi
if ! grep -q '^git clone ' "${log}"; then
  cat "${log}" >&2
  echo "First installation did not clone." >&2
  exit 1
fi

first_snapshot="$(snapshot_home "${install_home}")"

# Second install must update, not reclone, and leave equivalent desired state.
: >"${log}"
run_installer "${install_home}" >"${test_root}/second-install.out"
if grep -q '^git clone ' "${log}"; then
  cat "${log}" >&2
  echo "Second installation recloned the repository." >&2
  exit 1
fi
if ! grep -q 'git -C .* pull --ff-only' "${log}"; then
  cat "${log}" >&2
  echo "Second installation did not perform the safe update path." >&2
  exit 1
fi
second_snapshot="$(snapshot_home "${install_home}")"
if [[ "${first_snapshot}" != "${second_snapshot}" ]]; then
  diff <(printf '%s\n' "${first_snapshot}") <(printf '%s\n' "${second_snapshot}") >&2 || true
  echo "Repeated installation changed desired fixture state." >&2
  exit 1
fi

# Read-only modes must remain read-only after provisioning too.
before_read_only="$(snapshot_home "${install_home}")"
: >"${log}"
run_installer "${install_home}" --dry-run >/dev/null
run_installer "${install_home}" --check >/dev/null
after_read_only="$(snapshot_home "${install_home}")"
if [[ "${before_read_only}" != "${after_read_only}" ]]; then
  echo "Read-only modes changed a provisioned HOME." >&2
  exit 1
fi
if grep -Eq 'gh auth setup-git|git clone|git -C .* pull|make ' "${log}"; then
  cat "${log}" >&2
  echo "Read-only modes invoked a mutating external command after provisioning." >&2
  exit 1
fi

# An existing non-repository destination is a hard error and is preserved.
conflict_home="${test_root}/conflict-home"
conflict_dir="${conflict_home}/Developer/personal/macos-workstation"
mkdir -p "${conflict_dir}"
printf 'keep me\n' >"${conflict_dir}/important.txt"
set +e
run_installer "${conflict_home}" >"${test_root}/conflict.out" 2>&1
conflict_status=$?
set -e
if [[ "${conflict_status}" -eq 0 ]]; then
  cat "${test_root}/conflict.out" >&2
  echo "Conflicting destination was accepted." >&2
  exit 1
fi
if [[ "$(cat "${conflict_dir}/important.txt")" != "keep me" ]]; then
  echo "Conflicting destination was modified." >&2
  exit 1
fi

# A dirty workstation checkout is never automatically updated.
: >"${log}"
set +e
HOME="${install_home}" \
  PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin" \
  BOOTSTRAP_TEST_LOG="${log}" \
  BOOTSTRAP_TEST_GIT_DIRTY=1 \
  bash "${repo_root}/install.sh" >"${test_root}/dirty.out" 2>&1
dirty_status=$?
set -e
if [[ "${dirty_status}" -eq 0 ]]; then
  cat "${test_root}/dirty.out" >&2
  echo "Dirty workstation checkout was accepted." >&2
  exit 1
fi
if grep -q 'pull --ff-only' "${log}"; then
  cat "${log}" >&2
  echo "Dirty workstation checkout was updated." >&2
  exit 1
fi

echo "Bootstrap behavior tests passed."
