#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/install

TEST_TMPDIR=""

# Create one temporary sandbox per test.
setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-install-test.XXXXXX)"
}

# Clean up the temporary sandbox created for a test.
cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

# Create a minimal install source tree that records setup invocation.
create_mock_install_source() {
  local source_dir="${1}"

  mkdir -p "${source_dir}/bin"
  cat > "${source_dir}/VERSION" <<'EOF'
9.9.9
EOF
  cat > "${source_dir}/bin/jiggit" <<'EOF'
#!/usr/bin/env bash
printf 'mock jiggit\n'
EOF
  chmod +x "${source_dir}/bin/jiggit"
  cat > "${source_dir}/bin/setup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'setup-ran\n' >> "${SETUP_LOG_PATH}"
printf '%s\n' "- link dir: \`${JIGGIT_LINK_DIR:-unset}\`"
EOF
  chmod +x "${source_dir}/bin/setup"
}

# Return the current repository root for source-override based installer tests.
repo_root() {
  pwd
}

# Exercise the installer against the real repository with deterministic env vars.
run_real_install() {
  local output_file="${1}"
  shift

  env \
    HOME="${TEST_TMPDIR}/home" \
    PATH="$*" \
    JIGGIT_INSTALL_ROOT="${TEST_TMPDIR}/home/.local/share/jiggit" \
    JIGGIT_INSTALL_SOURCE_DIR="$(repo_root)" \
    bash bin/install > "${output_file}"
}

test_install_help_mentions_public_usage() {
  local output
  output="$(bash bin/install --help)"

  assert_contains "${output}" "curl -fsSL https://raw.githubusercontent.com/jesperronn/jiggit/main/bin/install | bash" "install help renders public usage"
}

test_install_creates_symlink_in_single_writable_path_dir() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/home/bin"
  local output_file="${TEST_TMPDIR}/output.txt"
  run_real_install "${output_file}" "${TEST_TMPDIR}/home/bin:/usr/bin:/bin"

  local output
  output="$(cat "${output_file}")"
  assert_contains "${output}" "- link dir: \`${TEST_TMPDIR}/home/bin\`" "install reports selected PATH directory"
  if [[ -L "${TEST_TMPDIR}/home/bin/jiggit" ]]; then
    pass "install creates jiggit symlink"
  else
    fail "install creates jiggit symlink"
  fi
}

test_install_reuses_existing_symlink_location_on_repeat_run() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/home/bin"
  local output_file="${TEST_TMPDIR}/first.txt"
  run_real_install "${output_file}" "${TEST_TMPDIR}/home/bin:/usr/bin:/bin"

  output_file="${TEST_TMPDIR}/second.txt"
  run_real_install "${output_file}" "${TEST_TMPDIR}/home/bin:${TEST_TMPDIR}/home/other-bin:/usr/bin:/bin"

  local output
  output="$(cat "${output_file}")"
  assert_contains "${output}" "- status: \`already-linked\`" "repeat install keeps existing symlink"
  assert_contains "${output}" "- link dir: \`${TEST_TMPDIR}/home/bin\`" "repeat install reuses previous link directory"
}

test_install_prompts_when_multiple_writable_path_dirs_exist() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/home/one" "${TEST_TMPDIR}/home/two"
  local output
  output="$(
    printf '2\n' | env \
      HOME="${TEST_TMPDIR}/home" \
      PATH="${TEST_TMPDIR}/home/one:${TEST_TMPDIR}/home/two:/usr/bin:/bin" \
      JIGGIT_INSTALL_ROOT="${TEST_TMPDIR}/home/.local/share/jiggit" \
      JIGGIT_INSTALL_SOURCE_DIR="$(repo_root)" \
      bash bin/install 2>&1
  )"

  assert_contains "${output}" "Choose a PATH directory for the \`jiggit\` symlink:" "install prompts when multiple PATH dirs are writable"
  assert_contains "${output}" "- link dir: \`${TEST_TMPDIR}/home/two\`" "install honors the selected PATH directory"
}

test_install_fails_when_no_writable_path_dir_exists() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/home/readonly-one" "${TEST_TMPDIR}/home/readonly-two"
  chmod 555 "${TEST_TMPDIR}/home/readonly-one" "${TEST_TMPDIR}/home/readonly-two"

  local output=""
  if output="$(
    env \
      HOME="${TEST_TMPDIR}/home" \
      PATH="${TEST_TMPDIR}/home/readonly-one:${TEST_TMPDIR}/home/readonly-two:/usr/bin:/bin" \
      JIGGIT_INSTALL_ROOT="${TEST_TMPDIR}/home/.local/share/jiggit" \
      JIGGIT_INSTALL_SOURCE_DIR="$(repo_root)" \
      bash bin/install 2>&1
  )"; then
    fail "install should fail when no writable PATH directory exists"
  else
    pass "install should fail when no writable PATH directory exists"
    assert_contains "${output}" "No writable PATH directories are available for the \`jiggit\` symlink." "install reports PATH write failure"
  fi
}

test_install_runs_installed_setup_script() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/home/bin"
  local source_dir="${TEST_TMPDIR}/source"
  local setup_log="${TEST_TMPDIR}/setup.log"
  create_mock_install_source "${source_dir}"

  env \
    HOME="${TEST_TMPDIR}/home" \
    PATH="${TEST_TMPDIR}/home/bin:/usr/bin:/bin" \
    JIGGIT_INSTALL_ROOT="${TEST_TMPDIR}/home/.local/share/jiggit" \
    JIGGIT_INSTALL_SOURCE_DIR="${source_dir}" \
    SETUP_LOG_PATH="${setup_log}" \
    bash bin/install > /dev/null

  assert_contains "$(cat "${setup_log}")" "setup-ran" "install invokes the installed setup script"
}

test_install_updates_existing_install_root_contents() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  mkdir -p "${TEST_TMPDIR}/home/bin"
  local source_dir="${TEST_TMPDIR}/source"
  create_mock_install_source "${source_dir}"

  env \
    HOME="${TEST_TMPDIR}/home" \
    PATH="${TEST_TMPDIR}/home/bin:/usr/bin:/bin" \
    JIGGIT_INSTALL_ROOT="${TEST_TMPDIR}/home/.local/share/jiggit" \
    JIGGIT_INSTALL_SOURCE_DIR="${source_dir}" \
    SETUP_LOG_PATH="${TEST_TMPDIR}/setup.log" \
    bash bin/install > /dev/null

  cat > "${source_dir}/VERSION" <<'EOF'
10.0.0
EOF

  env \
    HOME="${TEST_TMPDIR}/home" \
    PATH="${TEST_TMPDIR}/home/bin:/usr/bin:/bin" \
    JIGGIT_INSTALL_ROOT="${TEST_TMPDIR}/home/.local/share/jiggit" \
    JIGGIT_INSTALL_SOURCE_DIR="${source_dir}" \
    SETUP_LOG_PATH="${TEST_TMPDIR}/setup.log" \
    bash bin/install > /dev/null

  assert_eq "10.0.0" "$(cat "${TEST_TMPDIR}/home/.local/share/jiggit/VERSION")" "repeat install refreshes the installed checkout"
}

run_tests "$@"
