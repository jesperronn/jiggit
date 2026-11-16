#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." >/dev/null || exit 1

source bin/lib/bash_test.sh

ADAPTER_TEST_TMPDIR=""

# Build an isolated project and fake transports; no real Jira/config is used.
setup_adapter_fixture() {
  ADAPTER_TEST_TMPDIR="$(mktemp -d /tmp/jiggit-adapter-test.XXXXXX)"
  mkdir -p "${ADAPTER_TEST_TMPDIR}/tools" "${ADAPTER_TEST_TMPDIR}/repo" "${ADAPTER_TEST_TMPDIR}/home"
  cat >"${ADAPTER_TEST_TMPDIR}/projects.toml" <<EOF_CONFIG
[jira]
base_url = "https://jira.example.test"
bearer_token = "offline-token"

[widget]
repo_path = "${ADAPTER_TEST_TMPDIR}/repo"
jira_project_key = "ABC"
environments = []
EOF_CONFIG
  cat >"${ADAPTER_TEST_TMPDIR}/bridge fixture.sh" <<'EOF_BRIDGE'
# Match the connector bridge contract while keeping the transport fake.
jiggit_bridge_read() {
  shift 2
  "$JIRA_CONNECT_BIN" jiggit "$@"
}
# Only this fetch override should win after jiggit's helper load sequence.
fetch_jira_releases() {
  jiggit_bridge_read "$1" "${3:-}" versions "$2"
}
EOF_BRIDGE
  cat >"${ADAPTER_TEST_TMPDIR}/tools/connector fixture" <<'EOF_CONNECTOR'
#!/usr/bin/env bash
printf 'connector %s\n' "$*" >>"$ADAPTER_TEST_LOG"
[[ "${ADAPTER_CONNECTOR_FAIL:-0}" == 0 ]] || exit 7
printf '[{"id":"1","name":"connector_1.0.0","released":false,"archived":false}]\n'
EOF_CONNECTOR
  cat >"${ADAPTER_TEST_TMPDIR}/tools/curl" <<'EOF_CURL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$ADAPTER_TEST_LOG"
for arg; do
  case "$arg" in POST|PUT|DELETE|PATCH) exit 90 ;; esac
done
printf '[{"id":"2","name":"legacy_1.0.0","released":false,"archived":false}]\n'
EOF_CURL
  chmod +x "${ADAPTER_TEST_TMPDIR}/tools/connector fixture" "${ADAPTER_TEST_TMPDIR}/tools/curl"
}

# Remove the isolated fixture after every assertion group.
cleanup_adapter_fixture() {
  [[ -z "${ADAPTER_TEST_TMPDIR}" ]] || rm -rf "${ADAPTER_TEST_TMPDIR}"
}

# Invoke the actual CLI in a fresh process with only fictional Jira settings.
run_adapter_cli() {
  env -u JIRA_BASE_URL -u JIRA_BEARER_TOKEN -u JIRA_API_TOKEN -u JIRA_USER_EMAIL \
    -u JIGGIT_JIRA_ADAPTER -u JIRA_CONNECT_BIN -u JIRA_CONNECT_BRIDGE_PATH \
    HOME="${ADAPTER_TEST_TMPDIR}/home" JIGGIT_HOME="${ADAPTER_TEST_TMPDIR}/home/.jiggit" \
    JIGGIT_PROJECTS_FILE="${ADAPTER_TEST_TMPDIR}/projects.toml" \
    JIGGIT_DISCOVERED_PROJECTS_FILE="${ADAPTER_TEST_TMPDIR}/missing.toml" \
    PATH="${ADAPTER_TEST_TMPDIR}/tools:${PATH}" NO_COLOR=1 \
    ADAPTER_TEST_LOG="${ADAPTER_TEST_TMPDIR}/calls.log" \
    "$@"
}

# Assert rejected setup never reaches either read transport.
assert_adapter_no_transport() {
  if [[ ! -e "${ADAPTER_TEST_TMPDIR}/calls.log" ]]; then
    pass "$1"
  else
    fail "$1"
  fi
}

# Default and explicit legacy select the normal implementation without connector files.
test_default_and_explicit_legacy_use_existing_adapter() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output
  output="$(run_adapter_cli bash bin/jiggit releases widget)"
  assert_contains "${output}" 'legacy_1.0.0' 'default adapter renders legacy release data'
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=legacy JIRA_CONNECT_BIN=/missing JIRA_CONNECT_BRIDGE_PATH=/missing bash bin/jiggit releases widget)"
  assert_contains "${output}" 'legacy_1.0.0' 'explicit legacy ignores connector dependencies'
}

# Opt-in overrides helpers only after all their normal definitions have loaded.
test_opt_in_uses_connector_through_actual_entrypoint() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output calls
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect \
    JIRA_CONNECT_BIN="${ADAPTER_TEST_TMPDIR}/tools/connector fixture" \
    JIRA_CONNECT_BRIDGE_PATH="${ADAPTER_TEST_TMPDIR}/bridge fixture.sh" \
    bash bin/jiggit releases widget)"
  calls="$(cat "${ADAPTER_TEST_TMPDIR}/calls.log")"
  assert_contains "${output}" 'connector_1.0.0' 'opt-in renders connector release data'
  assert_eq 'connector jiggit versions ABC' "${calls}" 'opt-in performs one connector read and no legacy curl/write'
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=legacy bash bin/jiggit releases widget)"
  assert_contains "${output}" 'legacy_1.0.0' 'a new legacy invocation switches back cleanly'
}

# Help and config can load the selected adapter without contacting providers.
test_opt_in_help_and_config_do_not_call_connector_or_curl() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect \
    JIRA_CONNECT_BIN="${ADAPTER_TEST_TMPDIR}/tools/connector fixture" \
    JIRA_CONNECT_BRIDGE_PATH="${ADAPTER_TEST_TMPDIR}/bridge fixture.sh" bash bin/jiggit help)"
  assert_contains "${output}" 'jiggit releases' 'opt-in help remains available'
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect \
    JIRA_CONNECT_BIN="${ADAPTER_TEST_TMPDIR}/tools/connector fixture" \
    JIRA_CONNECT_BRIDGE_PATH="${ADAPTER_TEST_TMPDIR}/bridge fixture.sh" bash bin/jiggit config widget)"
  if [[ ! -e "${ADAPTER_TEST_TMPDIR}/calls.log" ]]; then
    pass 'help and config do not invoke Jira transports or credential providers'
  else
    fail 'help/config unexpectedly invoked a transport'
  fi
}

# Invalid selection fails before dispatch and never silently chooses legacy.
test_unknown_adapter_fails_explicitly() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output status=0
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=unknown bash bin/jiggit releases widget 2>&1)" || status=$?
  assert_eq 2 "${status}" 'unknown adapter returns usage failure'
  assert_contains "${output}" 'JIGGIT_JIRA_ADAPTER' 'unknown adapter diagnostic names the selector'
  assert_adapter_no_transport 'unknown adapter does not invoke either transport'
}

# An opted-in adapter needs explicit usable paths, without guessed fallbacks.
test_missing_connector_dependencies_fail_explicitly() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output status=0
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect bash bin/jiggit help 2>&1)" || status=$?
  assert_eq 1 "${status}" 'missing connector executable fails'
  assert_contains "${output}" 'JIRA_CONNECT_BIN' 'missing executable diagnostic gives its setting'
  status=0
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect \
    JIRA_CONNECT_BIN="${ADAPTER_TEST_TMPDIR}/tools/connector fixture" \
    JIRA_CONNECT_BRIDGE_PATH=/missing bash bin/jiggit releases widget 2>&1)" || status=$?
  assert_eq 1 "${status}" 'missing bridge fails'
  assert_contains "${output}" 'JIRA_CONNECT_BRIDGE_PATH' 'missing bridge diagnostic gives its setting'
  if [[ ! -e "${ADAPTER_TEST_TMPDIR}/calls.log" ]]; then
    pass 'invalid dependencies do not fall back to a transport'
  else
    fail 'invalid dependencies unexpectedly invoked a transport'
  fi
}

# Readable files without the connector bridge contract must not keep legacy reads active.
test_empty_or_unrelated_bridge_fails_before_transport() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local bridge output status
  : >"${ADAPTER_TEST_TMPDIR}/empty.sh"
  printf 'unrelated_helper() { :; }\n' >"${ADAPTER_TEST_TMPDIR}/unrelated.sh"
  for bridge in empty unrelated; do
    status=0
    output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect \
      JIRA_CONNECT_BIN="${ADAPTER_TEST_TMPDIR}/tools/connector fixture" \
      JIRA_CONNECT_BRIDGE_PATH="${ADAPTER_TEST_TMPDIR}/${bridge}.sh" \
      bash bin/jiggit releases widget 2>&1)" || status=$?
    assert_eq 1 "${status}" "${bridge} bridge fails before dispatch"
    assert_contains "${output}" 'JIRA_CONNECT_BRIDGE_PATH' "${bridge} bridge diagnostic identifies the setting"
    assert_adapter_no_transport "${bridge} bridge does not invoke either transport"
  done
}

# Relative executable paths must not change meaning after jiggit changes directory.
test_relative_connector_path_is_rejected_before_transport() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output status=0
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect \
    JIRA_CONNECT_BIN=bin/jiggit \
    JIRA_CONNECT_BRIDGE_PATH="${ADAPTER_TEST_TMPDIR}/bridge fixture.sh" \
    bash bin/jiggit releases widget 2>&1)" || status=$?
  assert_eq 1 "${status}" 'relative executable path is rejected'
  assert_contains "${output}" 'absolute' 'relative path diagnostic requests an absolute path'
  assert_adapter_no_transport 'relative executable does not invoke either transport'
}

# A connector read failure stays an error instead of retrying through legacy.
test_connector_failure_does_not_fall_back_to_legacy() {
  setup_adapter_fixture
  trap cleanup_adapter_fixture RETURN
  local output status=0 calls
  output="$(run_adapter_cli JIGGIT_JIRA_ADAPTER=jira-connect ADAPTER_CONNECTOR_FAIL=1 \
    JIRA_CONNECT_BIN="${ADAPTER_TEST_TMPDIR}/tools/connector fixture" \
    JIRA_CONNECT_BRIDGE_PATH="${ADAPTER_TEST_TMPDIR}/bridge fixture.sh" \
    bash bin/jiggit releases widget 2>&1)" || status=$?
  assert_eq 1 "${status}" 'connector fetch failure is propagated'
  calls="$(cat "${ADAPTER_TEST_TMPDIR}/calls.log")"
  assert_eq 'connector jiggit versions ABC' "${calls}" 'failed connector read never retries using legacy curl'
}

run_tests "$@"
