#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." > /dev/null || exit 1

source bin/lib/bash_test.sh
source bin/setup

TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/jiggit-setup-test.XXXXXX)"
}

cleanup_tmpdir() {
  if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
    rm -rf "${TEST_TMPDIR}"
  fi
}

create_fake_jiggit_on_path() {
  mkdir -p "${TEST_TMPDIR}/path-bin"
  cat > "${TEST_TMPDIR}/path-bin/jiggit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/path-bin/jiggit"
}

test_setup_help_mentions_usage() {
  local output
  output="$(bash bin/setup --help)"

  assert_contains "${output}" "Usage: bin/setup" "setup help renders usage"
}

test_startup_file_for_zsh_prefers_zshrc() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  local actual
  actual="$(HOME="${TEST_TMPDIR}" startup_file_for_shell zsh)"

  assert_eq "${TEST_TMPDIR}/.zshrc" "${actual}" "select .zshrc for zsh"
}

test_startup_file_for_bash_prefers_existing_bashrc() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  touch "${TEST_TMPDIR}/.bashrc"
  touch "${TEST_TMPDIR}/.bash_profile"

  local actual
  actual="$(HOME="${TEST_TMPDIR}" startup_file_for_shell bash)"

  assert_eq "${TEST_TMPDIR}/.bashrc" "${actual}" "prefer existing .bashrc for bash"
}

test_run_setup_reports_already_on_path_without_editing_files() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN
  create_fake_jiggit_on_path

  local output
  output="$(
    HOME="${TEST_TMPDIR}" \
      PATH="${TEST_TMPDIR}/path-bin:${PATH}" \
      SHELL="/bin/bash" \
      run_main
  )"

  assert_contains "${output}" "- status: \`already-on-path\`" "report jiggit already on path"
  if [[ -f "${TEST_TMPDIR}/.profile" ]]; then
    fail "do not create startup file when jiggit is already on PATH"
  else
    pass "do not create startup file when jiggit is already on PATH"
  fi
}

test_run_setup_appends_repo_bin_to_bash_profile_file() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  touch "${TEST_TMPDIR}/.profile"

  local output
  output="$(
    HOME="${TEST_TMPDIR}" \
      PATH="/usr/bin:/bin" \
      SHELL="/bin/bash" \
      run_main
  )"

  assert_contains "${output}" "- status: \`configured\`" "report configured status"
  assert_contains "${output}" "- startup file: \`${TEST_TMPDIR}/.profile\`" "report chosen startup file"
  assert_contains "$(cat "${TEST_TMPDIR}/.profile")" "# >>> jiggit setup >>>" "write managed snippet header"
  assert_contains "$(cat "${TEST_TMPDIR}/.profile")" "export PATH=\"$(pwd)/bin:\$PATH\"" "write repo bin path export"
}

test_run_setup_reports_already_configured_when_profile_contains_repo_bin() {
  setup_tmpdir
  trap cleanup_tmpdir RETURN

  cat > "${TEST_TMPDIR}/.zshrc" <<EOF
export PATH="$(pwd)/bin:\$PATH"
EOF

  local output
  output="$(
    HOME="${TEST_TMPDIR}" \
      PATH="/usr/bin:/bin" \
      SHELL="/bin/zsh" \
      run_main
  )"

  assert_contains "${output}" "- status: \`already-configured\`" "report already configured status"
}

run_tests "$@"
