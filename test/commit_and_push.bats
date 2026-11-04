#!/usr/bin/env bats
#
# commit_and_push runs as a condition (`if commit_and_push`, `... || true`),
# where bash ignores set -e. A failed git step must still stop the action
# rather than read as "nothing to commit" and skip the PR.
#
# Regression: on 2026-11-04 GitHub rejected three promotion pushes with
# "Internal Server Error" and the action exited 0 without opening the PRs.

setup() {
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../entrypoint.sh"

  TESTTMP="$(mktemp -d)"
  BIN="${TESTTMP}/bin"
  mkdir -p "$BIN"

  # Fake git: `diff --cached --quiet` exits 1 (staged changes) unless
  # FAKE_CHANGES=no; `push` fails when FAKE_PUSH=fail.
  cat > "$BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
case "$1" in
  diff) [ "${FAKE_CHANGES:-yes}" = "yes" ] && exit 1 ;;
  push)
    if [ "${FAKE_PUSH:-ok}" = "fail" ]; then
      echo " ! [remote rejected]     HEAD -> temp-branch-test (Internal Server Error)" >&2
      exit 1
    fi
    ;;
esac
exit 0
FAKE_GIT
  chmod +x "$BIN/git"
  PATH="$BIN:$PATH"

  export INPUT_SOURCE_FOLDERS="values"
  export INPUT_DESTINATION_FOLDERS="values"
  export INPUT_DESTINATION_HEAD_BRANCH="temp-branch-test"

  # shellcheck source=/dev/null
  source "$ENTRYPOINT"
  # Keep errexit on: bats runs setup and the test in one shell, and every
  # assertion below needs it to fail the test.
  IFS=$' \t\n'
}

teardown() {
  rm -rf "$TESTTMP"
}

# Mirrors how the entrypoint calls commit_and_push: as a condition.
call_as_condition() {
  if commit_and_push "title"
  then
    echo "pull request step"
  fi
  echo "continued"
}

@test "push failure stops the action even when called as a condition" {
  export FAKE_PUSH=fail
  run call_as_condition
  [ "$status" -ne 0 ]
  [[ "$output" != *"continued"* ]]
}

@test "nothing to commit skips the pull request step and continues" {
  export FAKE_CHANGES=no
  run call_as_condition
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes detected"* ]]
  [[ "$output" != *"pull request step"* ]]
  [[ "$output" == *"continued"* ]]
}

@test "successful push reaches the pull request step" {
  run call_as_condition
  [ "$status" -eq 0 ]
  [[ "$output" == *"pull request step"* ]]
}
