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
  *"/rest/api/2/issue/SKOLELOGIN-123"*)
    printf '{"key":"SKOLELOGIN-123","fields":{"summary":"Example issue","status":{"name":"Done"},"labels":["demo"],"fixVersions":[{"name":"1.2.3"}]}}'
    ;;
  *"/rest/api/2/issue/SKOLELOGIN-13603"*)
    printf '{"key":"SKOLELOGIN-13603","fields":{"summary":"Example all-mode issue","status":{"name":"Done"},"labels":["demo"],"fixVersions":[{"name":"Api-server_1.2.0"}]}}'
    ;;
  *"/rest/api/2/search?jql=project%20%3D%20%22SKOLELOGIN%22%20AND%20statusCategory%20%21%3D%20Done"*)
    printf '{"issues":[{"key":"SKOLELOGIN-1","fields":{"summary":"Open issue","status":{"name":"In Progress"}}},{"key":"SKOLELOGIN-2","fields":{"summary":"Another open issue","status":{"name":"To Do"}}}]}'
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

create_fake_curl_fail_on_myself() {
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"

case "$*" in
  *"/rest/api/2/myself"*)
    printf 'auth failed\n' >&2
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
  assert_contains "${output}" "bin/adhoc/jira_requests.sh project SKOLELOGIN --short" "show success next step"
  if [[ "${output}" == *"if failing:"* ]]; then
    fail "myself success output should omit failure next step"
    return 1
  fi
  pass "myself success output omits failure next step"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/myself" "call myself once"
}

test_jira_requests_issues_runs_request_and_prints_next_steps() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" issues SKOLELOGIN-123 2>&1)"

  assert_contains "${output}" '{"key":"SKOLELOGIN-123"' "print issue response"
  assert_contains "${output}" "Next steps:" "print next steps"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh issues SKOLELOGIN-123 --short" "show success next step"
  if [[ "${output}" == *"if failing:"* ]]; then
    fail "issues success output should omit failure next step"
    return 1
  fi
  pass "issues success output omits failure next step"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/issue/SKOLELOGIN-123" "call issue once"
}

test_jira_requests_issues_lists_open_requests_for_project_key() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" issues SKOLELOGIN 2>&1)"

  assert_contains "${output}" '{"issues":[{"key":"SKOLELOGIN-1"' "print open issues response"
  assert_contains "${output}" "Next steps:" "print next steps"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh issues SKOLELOGIN --short" "show list success next step"
  if [[ "${output}" == *"if failing:"* ]]; then
    fail "issues list success output should omit failure next step"
    return 1
  fi
  pass "issues list success output omits failure next step"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/search?jql=project%20%3D%20%22SKOLELOGIN%22%20AND%20statusCategory%20%21%3D%20Done" "call open issues search"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "maxResults=10" "default issues limit is ten"
}

test_jira_requests_issues_accepts_explicit_limit_after_project_key() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" issues SKOLELOGIN --limit 10 2>&1)"

  assert_contains "${output}" '{"issues":[{"key":"SKOLELOGIN-1"' "print open issues response"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "maxResults=10" "explicit issues limit is forwarded"
}

test_jira_requests_issues_treats_limit_zero_as_all() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" issues SKOLELOGIN --limit 0 2>&1)"

  assert_contains "${output}" '{"issues":[{"key":"SKOLELOGIN-1"' "print open issues response"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "maxResults=20" "limit zero falls back to the default result window"
}

test_jira_requests_releases_runs_request_and_prints_next_steps() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" releases SKOLELOGIN 2>&1)"

  assert_contains "${output}" '[{"name":"1.2.3"}]' "print releases response"
  assert_contains "${output}" "Next steps:" "print next steps"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh releases SKOLELOGIN --short" "show success next step"
  if [[ "${output}" == *"if failing:"* ]]; then
    fail "releases success output should omit failure next step"
    return 1
  fi
  pass "releases success output omits failure next step"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/project/SKOLELOGIN/versions" "call releases once"
}

test_jira_requests_releases_raw_mode_prints_only_response_body() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" --raw releases SKOLELOGIN 2>&1)"

  assert_contains "${output}" '[{"name":"1.2.3"}]' "raw releases output includes json body"
  if [[ "${output}" == *"Next steps:"* || "${output}" == *"review the releases page in Jira"* ]]; then
    fail "raw releases output should omit next steps"
    return 1
  fi
  pass "raw releases output stays pipe-friendly"
}

test_jira_requests_versions_accepts_raw_after_project_key() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_success

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" versions SKOLELOGIN --raw 2>&1)"

  assert_contains "${output}" '[{"name":"1.2.3"}]' "raw versions output includes json body"
    if [[ "${output}" == *"Next steps:"* || "${output}" == *"if successful:"* || "${output}" == *"if failing:"* ]]; then
    fail "raw versions output should omit next steps"
    return 1
  fi
  pass "raw versions output stays pipe-friendly"
}

test_jira_requests_search_uses_exact_release_tag_in_jql() {
  setup_test_tmpdir
  create_jira_requests_fixture

  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"

case "$*" in
  *"/rest/api/2/search?jql="*)
    printf '{"issues":[{"key":"SKOLELOGIN-321","fields":{"summary":"Ship API release","status":{"name":"Done"}}}]}'
    ;;
  *)
    printf 'unexpected curl call: %s\n' "$*" >&2
    exit 22
    ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" /opt/homebrew/bin/bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" search SKOLELOGIN Api-server_1.2.0 2>&1)"

  assert_contains "${output}" '"SKOLELOGIN-321"' "print resolved release search response"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "fixVersion%20%3D%20%22Api-server_1.2.0%22" "search uses the exact release tag for fixVersion"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "affectedVersion%20%3D%20%22Api-server_1.2.0%22" "search also checks affectedVersion"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh search SKOLELOGIN Api-server_1.2.0 --short" "search keeps command-style next step"
}

test_jira_requests_versions_accepts_short_after_project_key() {
  setup_test_tmpdir
  create_jira_requests_fixture

  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"

case "$*" in
  *"/rest/api/2/project/SKOLELOGIN/versions"*)
    printf '[{"name":"1.2.3"},{"name":"1.2.4"},{"name":"1.2.5"},{"name":"1.2.6"},{"name":"1.2.7"},{"name":"1.2.8"},{"name":"1.2.9"},{"name":"1.2.10"},{"name":"1.2.11"},{"name":"1.2.12"}]'
    ;;
  *)
    printf 'unexpected curl call: %s\n' "$*" >&2
    exit 22
    ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" versions SKOLELOGIN --short 2>&1)"

  assert_contains "${output}" "..." "short versions output is abbreviated"
  assert_contains "${output}" "Next steps:" "short versions output keeps guidance"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh search SKOLELOGIN Api-server_1.2.0 --short" "short versions output keeps success guidance"
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

  assert_contains "${output}" "bin/adhoc/jira_requests.sh myself --short" "print myself command in all mode"
  assert_contains "${output}" '{"name":"nine-jrj"}' "run myself before failure"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh project SKOLELOGIN --short" "print project command in all mode"
  assert_contains "${output}" "Next steps:" "print failure next steps block"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh project SKOLELOGIN --short" "print failure next step on project failure"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/myself" "call myself first"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/project/SKOLELOGIN" "call project second"
  if [[ "$(cat "${TEST_TMPDIR}/curl.log")" == *"/rest/api/2/project/SKOLELOGIN/versions"* ]]; then
    fail "fail-fast should stop before versions"
    return 1
  fi
  pass "fail-fast stops before versions"
}

test_jira_requests_all_stops_on_first_verification_failure_even_without_fail_fast() {
  setup_test_tmpdir
  create_jira_requests_fixture
  create_fake_curl_fail_on_myself

  local output
  if output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" --no-fail-fast all 2>&1)"; then
    fail "all should stop on first verification failure"
    return 1
  fi

  assert_contains "${output}" "bin/adhoc/jira_requests.sh myself --short" "print first command before guard failure"
  assert_contains "${output}" "auth failed" "report first verification failure"
  assert_contains "${output}" "Next steps:" "show failure next steps block only"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh myself --short" "show failure next step only"
  if [[ "${output}" == *"if successful:"* || "${output}" == *"if failing:"* ]]; then
    fail "failed myself probe should omit old guidance phrasing"
    return 1
  fi
  pass "failed myself probe omits old guidance phrasing"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/myself" "call myself first on brute-force guard"
  if [[ "$(cat "${TEST_TMPDIR}/curl.log")" == *"/rest/api/2/project/SKOLELOGIN" ]]; then
    fail "guard should stop before project probe"
    return 1
  fi
  pass "guard stops after the first verification failure"
}

test_jira_requests_all_prints_excerpt_for_long_output() {
  setup_test_tmpdir
  create_jira_requests_fixture

  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"

  case "$*" in
  *"/rest/api/2/myself"*)
    printf '{"name":"nine-jrj"}'
    ;;
  *"/rest/api/2/project/SKOLELOGIN"*)
    printf '{"key":"SKOLELOGIN"}'
    ;;
  *"/rest/api/2/project/SKOLELOGIN/versions"*)
    printf '[{"name":"1.2.3"}]'
    ;;
  *"/rest/api/2/issue/SKOLELOGIN-13603"*)
    printf '{"key":"SKOLELOGIN-1","fields":{"summary":"%s","status":{"name":"Done"},"labels":["demo"],"fixVersions":[{"name":"1.2.3"}]}}' "$(printf 'x%.0s' {1..400})"
    ;;
  *"/rest/api/2/search?jql="*)
    printf '{"issues":[]}'
    ;;
  *"/rest/api/2/project/SKOLELOGIN/versions"*)
    printf '[{"name":"1.2.3"}]'
    ;;
  *)
    printf 'unexpected curl call: %s\n' "$*" >&2
    exit 22
    ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_requests.sh" --no-fail-fast all 2>&1)"

  assert_contains "${output}" "bin/adhoc/jira_requests.sh myself --short" "print command for myself step"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh project SKOLELOGIN --short" "print command for project step"
  assert_contains "${output}" "bin/adhoc/jira_requests.sh issues SKOLELOGIN-13603 --short" "print command for issues step"
  assert_contains "${output}" "..." "truncate long output in all mode"
}

run_tests "$@"
