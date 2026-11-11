#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." >/dev/null || exit 1

source bin/lib/bash_test.sh

TEST_TMP_DIR="$(mktemp -d)"
# Remove the scratch repos.
cleanup_test_tmp() { rm -rf "${TEST_TMP_DIR}"; }
trap 'cleanup_test_tmp' EXIT

# Create a scratch git repo with a copy of bin/changelog; print its path.
mk_project() {
  local dir="${TEST_TMP_DIR}/${1}"
  mkdir -p "${dir}/bin/lib"
  cp bin/changelog "${dir}/bin/changelog"
  cp bin/lib/project.sh "${dir}/bin/lib/project.sh"
  git -C "${dir}" init -q
  printf '%s\n' "${dir}"
}

# Commit an empty commit at 1700000000+OFFSET seconds: DIR OFFSET SUBJECT [BODY].
commit_at() {
  local dir="${1}" when="${2}" subject="${3}" body="${4-}"
  GIT_AUTHOR_DATE="$((1700000000 + when)) +0000" GIT_COMMITTER_DATE="$((1700000000 + when)) +0000" \
    git -C "${dir}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "${subject}${body:+

${body}}"
}

# Run bin/changelog inside DIR; sets out and st.
run() {
  local dir="${1}"
  shift
  st=0
  out="$(cd "${dir}" && bin/changelog "$@" 2>&1)" || st=$?
}

test_changelog_next_bumps_from_conventional_commits() {
  local dir out st
  dir="$(mk_project next)"
  commit_at "${dir}" 1000 "chore: init"
  run "${dir}" next
  assert_eq "3" "${st}" "nothing releasable exits 3"
  assert_contains "${out}" "nothing releasable" "says why"
  commit_at "${dir}" 1100 "feat(api): add export"
  run "${dir}" next
  assert_eq "v0.1.0" "${out}" "first feat without tags gives v0.1.0"
  git -C "${dir}" tag v1.2.3
  commit_at "${dir}" 1300 "fix: crash"
  run "${dir}" next
  assert_eq "v1.2.4" "${out}" "fix gives a patch bump"
  commit_at "${dir}" 1400 "feat: more"
  run "${dir}" next
  assert_eq "v1.3.0" "${out}" "feat gives a minor bump"
  commit_at "${dir}" 1500 "refactor: x" "BREAKING CHANGE: api removed"
  run "${dir}" next
  assert_eq "v2.0.0" "${out}" "BREAKING CHANGE footer gives major"
}

test_changelog_render_groups_entries() {
  local dir out st
  dir="$(mk_project render)"
  commit_at "${dir}" 0 "chore: init"
  git -C "${dir}" tag v1.0.0
  commit_at "${dir}" 1000 "feat(api): add export"
  commit_at "${dir}" 1100 "fix: crash"
  commit_at "${dir}" 1200 "perf!: drop cache"
  run "${dir}" render
  assert_eq "0" "${st}" "render exits 0"
  assert_contains "${out}" "## v2.0.0" "heading has the next version"
  assert_contains "${out}" "### Changed (BREAKING)" "breaking section"
  assert_contains "${out}" "### Added" "added section"
  assert_contains "${out}" "- **api:** add export (" "scope and description format"
  assert_contains "${out}" "### Fixed" "fixed section"
  run "${dir}" bogus
  assert_eq "2" "${st}" "unknown subcommand exits 2"
}

test_changelog_due_uses_quiet_period() {
  local dir out st
  dir="$(mk_project due)"
  commit_at "${dir}" 10000 "feat: x"
  run "${dir}" due --now 1700010600
  assert_eq "4" "${st}" "inside the grace period exits 4"
  assert_eq "1h50m" "${out}" "prints the time left"
  run "${dir}" due --now 1700017200
  assert_eq "0" "${st}" "after the grace period exits 0"
  assert_eq "due" "${out}" "prints due"
}

test_changelog_update_inserts_section_and_refuses_duplicate() {
  local dir out st file
  dir="$(mk_project update)"
  commit_at "${dir}" 0 "chore: init"
  git -C "${dir}" tag v1.0.0
  commit_at "${dir}" 1000 "feat(api): add export"
  printf '# Changelog\n\n## [Unreleased]\n\n- hand written\n\n## [1.0.0] - 2026-01-01\n\n- old\n' >"${dir}/CHANGELOG.md"
  run "${dir}" update --date 2026-02-03
  assert_eq "0" "${st}" "update exits 0"
  file="$(cat "${dir}/CHANGELOG.md")"
  assert_contains "${file}" "## [1.1.0] - 2026-02-03" "new heading uses Keep a Changelog form"
  assert_contains "${file}" "- hand written" "Unreleased body stays by default"
  run "${dir}" update --date 2026-02-03
  assert_eq "1" "${st}" "second update refuses a duplicate version"
  assert_contains "${out}" "already has a section" "says why"
}

run_tests "$@"
