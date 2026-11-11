#!/usr/bin/env bash
set -euo pipefail

pushd "$(dirname "$0")/.." >/dev/null || exit 1

source bin/lib/bash_test.sh

TEST_TMP_DIR="$(mktemp -d)"
# Remove the scratch repos.
cleanup_test_tmp() { rm -rf "${TEST_TMP_DIR}"; }
trap 'cleanup_test_tmp' EXIT

# Create a scratch repo (with a bare "origin") holding bin/release, bin/changelog and one commit; print its path.
mk_project() {
  local dir="${TEST_TMP_DIR}/${1}"
  mkdir -p "${dir}/bin/lib" "${TEST_TMP_DIR}/${1}.git"
  cp bin/release bin/changelog "${dir}/bin/"
  cp bin/lib/project.sh "${dir}/bin/lib/"
  git init -q --bare "${TEST_TMP_DIR}/${1}.git"
  git -C "${dir}" init -q -b main
  git -C "${dir}" remote add origin "${TEST_TMP_DIR}/${1}.git"
  printf '1.0.0\n' >"${dir}/VERSION"
  git -C "${dir}" add -A
  git -C "${dir}" -c user.name=t -c user.email=t@t commit -q -m "feat: first"
  printf '%s\n' "${dir}"
}

# Run bin/release in DIR with ANSWER on stdin; sets out and st.
run_release() {
  local dir="${1}" answer="${2}"
  shift 2
  st=0
  out="$(cd "${dir}" && printf '%s\n' "${answer}" | GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bin/release "$@" 2>&1)" || st=$?
}

test_release_tags_locally_and_does_not_push_without_yes() {
  local dir out st
  dir="$(mk_project local)"
  run_release "${dir}" n v1.1.0
  assert_eq "0" "${st}" "release exits 0"
  assert_eq "1.1.0" "$(cat "${dir}/VERSION")" "VERSION is updated"
  assert_contains "$(git -C "${dir}" tag)" "v1.1.0" "tag exists locally"
  assert_contains "$(git -C "${dir}" log -1 --format=%s)" "chore(release): v1.1.0" "release commit made"
  assert_eq "" "$(git -C "${TEST_TMP_DIR}/local.git" tag)" "remote has no tag after answering n"
  assert_contains "${out}" "not pushed" "says it did not push"
}

test_release_pushes_branch_and_tag_after_yes() {
  local dir out st
  dir="$(mk_project push)"
  run_release "${dir}" y v1.1.0
  assert_eq "0" "${st}" "release exits 0"
  assert_eq "v1.1.0" "$(git -C "${TEST_TMP_DIR}/push.git" tag)" "remote has the tag after answering y"
}

test_release_refuses_dirty_tree_and_existing_tag() {
  local dir out st
  dir="$(mk_project refuse)"
  printf 'x\n' >"${dir}/dirty"
  run_release "${dir}" n v1.1.0
  assert_eq "1" "${st}" "dirty tree exits 1"
  assert_contains "${out}" "not clean" "says why"
  rm "${dir}/dirty"
  git -C "${dir}" tag v1.1.0
  run_release "${dir}" n v1.1.0
  assert_eq "1" "${st}" "existing tag exits 1"
  assert_contains "${out}" "already exists" "says why"
}

test_release_derives_version_and_rejects_bad_input() {
  local dir out st
  dir="$(mk_project derive)"
  run_release "${dir}" n
  assert_eq "0" "${st}" "version from changelog next exits 0"
  assert_contains "$(git -C "${dir}" tag)" "v0.1.0" "feat since no tag gives v0.1.0"
  run_release "${dir}" n 1.2
  assert_eq "2" "${st}" "malformed version exits 2"
}

run_tests "$@"
