#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/../.." > /dev/null || exit 1

source bin/lib/bash_test.sh

setup_test_tmpdir() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "${TEST_TMPDIR}/bin/adhoc" "${TEST_TMPDIR}/bin"
  cp bin/adhoc/jira_endpoint_smoke.sh "${TEST_TMPDIR}/bin/adhoc/jira_endpoint_smoke.sh"
  chmod +x "${TEST_TMPDIR}/bin/adhoc/jira_endpoint_smoke.sh"
}

# Install a fake curl that records calls and returns a small JSON body.
create_fake_curl() {
  cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/curl.log"
printf '{"ok":true}\n'
EOF
  chmod +x "${TEST_TMPDIR}/bin/curl"
}

# Install a fake op CLI that resolves the configured op:// secret reference.
create_fake_op() {
  cat > "${TEST_TMPDIR}/bin/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_TMPDIR}/op.log"

if [[ "${1:-}" == "read" && "${2:-}" == "op://JIRA_API_TOKEN_NINE_JRJ" ]]; then
  exit 1
fi

if [[ "${1:-}" == "item" && "${2:-}" == "list" && "${3:-}" == "--format" && "${4:-}" == "json" ]]; then
  printf '[{"id":"item-id-123","title":"JIRA_API_TOKEN_NINE_JRJ"}]\n'
  exit 0
fi

if [[ "${1:-}" == "item" && "${2:-}" == "get" && "${3:-}" == "JIRA_API_TOKEN_NINE_JRJ" && "${4:-}" == "--fields" && "${5:-}" == "password" ]]; then
  printf 'unexpected legacy item get call: %s\n' "$*" >&2
  exit 1
fi

if [[ "${1:-}" == "item" && "${2:-}" == "get" && "${3:-}" == "item-id-123" && "${4:-}" == "--fields" && "${5:-}" == "token" ]]; then
  printf 'test-op-token\n'
  exit 0
fi

printf 'unexpected op call: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/op"
}

test_jira_endpoint_smoke_dry_run_lists_all_endpoints() {
  setup_test_tmpdir
  create_fake_curl

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_endpoint_smoke.sh" --dry-run all 2>&1)"

  assert_contains "${output}" "/rest/api/2/myself" "dry run includes myself endpoint"
  assert_contains "${output}" "/rest/api/2/project/SKOLELOGIN" "dry run includes project endpoint"
  assert_contains "${output}" "/rest/api/2/project/SKOLELOGIN/versions" "dry run includes versions endpoint"
  assert_contains "${output}" "/rest/api/2/issue/SKOLELOGIN-13603" "dry run includes issue endpoint path"
  assert_contains "${output}" "fields=summary" "dry run includes issue field filter"
  assert_contains "${output}" "/rest/api/2/search" "dry run includes search endpoint path"
  assert_contains "${output}" "jql=project" "dry run includes encoded jql"
  assert_contains "${output}" "/rest/api/2/issue" "dry run includes create issue endpoint"
  assert_contains "${output}" "/rest/api/2/version" "dry run includes create version endpoint"
  assert_contains "${output}" "Authorization: Bearer <redacted>" "dry run redacts auth"
  assert_eq "" "$(cat "${TEST_TMPDIR}/curl.log" 2>/dev/null || true)" "dry run does not call curl"
}

test_jira_endpoint_smoke_resolves_op_reference_for_live_requests() {
  setup_test_tmpdir
  create_fake_curl
  create_fake_op

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_endpoint_smoke.sh" myself 2>&1)"

  assert_contains "${output}" '{"ok":true}' "live request prints response"
  assert_contains "$(cat "${TEST_TMPDIR}/op.log")" "read op://JIRA_API_TOKEN_NINE_JRJ" "try op read first"
  assert_contains "$(cat "${TEST_TMPDIR}/op.log")" "item list --format json" "search item list for shorthand ref"
  assert_contains "$(cat "${TEST_TMPDIR}/op.log")" "item get item-id-123 --fields token" "fall back to item lookup"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "Authorization: Bearer test-op-token" "forward resolved bearer token"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/myself" "call myself endpoint"
}

test_jira_endpoint_smoke_verbose_reports_secret_resolution_steps() {
  setup_test_tmpdir
  create_fake_curl
  create_fake_op

  local output
  output="$(PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_endpoint_smoke.sh" all --verbose 2>&1 || true)"

  assert_contains "${output}" "[verbose] resolve secret via 1Password reference op://JIRA_API_TOKEN_NINE_JRJ" "verbose shows secret reference"
  assert_contains "${output}" "[verbose] op read failed; trying item title lookup for JIRA_API_TOKEN_NINE_JRJ" "verbose shows fallback path"
  assert_contains "${output}" "[verbose] resolved matching 1Password item id item-id-123" "verbose shows matched item id"
  assert_contains "${output}" "[verbose] resolved secret via item token field" "verbose shows secret resolution success"
}

test_jira_endpoint_smoke_create_version_uses_numeric_project_id_payload() {
  setup_test_tmpdir
  create_fake_curl
  create_fake_op

  PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${TEST_TMPDIR}/bin/adhoc/jira_endpoint_smoke.sh" create-version >/dev/null 2>&1

  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" "/rest/api/2/version" "call create version endpoint"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" '"projectId":10000' "send numeric project id"
  assert_contains "$(cat "${TEST_TMPDIR}/curl.log")" '"name":"Api-server_1.2.0"' "send release name"
}

run_tests "$@"
