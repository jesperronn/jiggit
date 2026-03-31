#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh

setup_test_tmpdir() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  trap 'rm -rf "${TEST_TMPDIR}"' RETURN
}

create_jira_requests_fixture() {
  mkdir -p "${TEST_TMPDIR}/bin/adhoc"
  cp bin/adhoc/jira_requests.sh "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh"
  chmod +x "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh"

  cat > "${TEST_TMPDIR}/bin/adhoc/_jira_variables.sh" <<'EOF'
# shellcheck shell=bash
export JIRA_BASE_URL="https://jira.stil.dk"
export JIRA_PROJECT_KEY="SKOLELOGIN"
export JIRA_API_TOKEN="test-token"
EOF

  mkdir -p "${TEST_TMPDIR}/bin"
}

create_fake_curl_success() {
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"

case "$*" in
  *"/rest/api/2/myself"*)
    printf '{"name":"nine-jrj"}'
    ;;
  *"/rest/api/2/project/SKOLELOGIN/versions"*)
    printf '[{"name":"1.2.3"}]'
    ;;
  *"/rest/api/2/project/SKOLELOGIN"*)
    printf '{"key":"SKOLELOGIN"}'
    ;;
  *"/rest/api/2/search?jql="*)
    printf '{"issues":[]}'
    ;;
  *)
    printf 'unexpected curl call: %s\n' "$*" >&2
    exit 22
    ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"
}

create_fake_curl_fail_on_project() {
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"

case "$*" in
  *"/rest/api/2/myself"*)
    printf '{"name":"nine-jrj"}'
    ;;
  *"/rest/api/2/project/SKOLELOGIN"*)
    printf 'project missing or inaccessible\n' >&2
    exit 22
    ;;
  *"/rest/api/2/project/SKOLELOGIN/versions"*)
    printf '{"name":"should-not-run"}' >&2
    exit 22
    ;;
  *)
    printf 'unexpected curl call: %s\n' "$*" >&2
    exit 22
    ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"
}

test_jira_requests_dry_run_prints_commands_without_calling_curl() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success
  : > "${TEST_TMPDIR}/curl.log"

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" --dry-run all 2>&1)"

  assert_contains "${output}" "curl --silent --show-error --fail -H 'Authorization: Bearer \$JIRA_API_TOKEN'" "print redacted curl command"
  assert_contains "${output}" "/rest/api/2/myself" "print myself request"
  assert_contains "${output}" "/rest/api/2/project/SKOLELOGIN" "print project request"
  assert_contains "${output}" "/rest/api/2/project/SKOLELOGIN/versions" "print versions request"
  assert_eq "" "$(cat "${TEST_TMPDIR}/curl.log")" "dry run does not call curl"
}

test_jira_requests_myself_runs_request_and_prints_next_steps() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" myself 2>&1)"

  assert_contains "${output}" '{"name":"nine-jrj"}' "print myself response"
  assert_contains "${output}" "Next steps:" "print next steps"
  assert_contains "${output}" "if successful: bin/adhoc/jira_requests.sh project SKOLELOGIN" "show success next step"
  assert_contains "${output}" "if failing: refresh PAT and rerun myself" "show failure next step"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/myself" "call myself once"
}

test_jira_requests_all_stops_on_first_failure_by_default() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_fail_on_project

  local output
  if output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" all 2>&1)"; then
    fail "all should stop on first failure"
    return 1
  fi

  assert_contains "${output}" '{"name":"nine-jrj"}' "run myself before failure"
  assert_contains "${output}" "if successful: bin/adhoc/jira_requests.sh project SKOLELOGIN" "print success next step before failure"
  assert_contains "${output}" "if failing: check project key and permissions" "print failure next step on project failure"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/myself" "call myself first"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/project/SKOLELOGIN" "call project second"
  if [[ "$(cat "${TEST_TMPDIR}/curl.log")" == *"/rest/api/2/project/SKOLELOGIN/versions"* ]]; then
    fail "fail-fast should stop before versions"
    return 1
  fi
  pass "fail-fast stops before versions"
}

run_tests "$@"
