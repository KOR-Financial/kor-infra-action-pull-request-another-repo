#!/usr/bin/env bats
#
# Unit tests for the label self-heal in entrypoint.sh: source the functions
# (bottom half is BASH_SOURCE-guarded) and run them against a fake gh on PATH.

setup() {
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../entrypoint.sh"

  # mktemp rather than BATS_TEST_TMPDIR so the suite runs on older bats too.
  TESTTMP="$(mktemp -d)"
  BIN="${TESTTMP}/bin"
  mkdir -p "$BIN"

  # Call/argument logs and simulated state, read/written by the fake gh.
  export GH_CALLS="${TESTTMP}/gh_calls"
  export GH_ARGV="${TESTTMP}/gh_argv"
  export GH_LABEL_REGISTRY="${TESTTMP}/gh_labels"
  : > "$GH_CALLS"
  : > "$GH_ARGV"
  : > "$GH_LABEL_REGISTRY"

  cat > "$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh: logs calls, simulates `pr create`, `label create`, `pr list`.
printf '%s %s\n' "$1" "$2" >> "$GH_CALLS"
printf 'ARG:%s\n' "$@" >> "$GH_ARGV"

case "$1 $2" in
  "pr create")
    case "${FAKE_PR_CREATE:-ok}" in
      ok)
        echo "https://github.com/kor/repo/pull/123"
        ;;
      missing_label)
        # Succeeds only once the app label has actually been created.
        if grep -qxF 'app: kc-rd-dispatcher' "$GH_LABEL_REGISTRY" 2>/dev/null; then
          echo "https://github.com/kor/repo/pull/123"
        else
          echo "could not add label: 'app: kc-rd-dispatcher' not found" >&2
          exit 1
        fi
        ;;
      other_error)
        # "not found" but not "could not add label" -- must NOT self-heal.
        echo 'failed to create pull request: base branch "main" not found' >&2
        exit 1
        ;;
    esac
    ;;
  "label create")
    case "${FAKE_LABEL_CREATE:-ok}" in
      ok)       echo "$3" >> "$GH_LABEL_REGISTRY" ;;      # $3 = label name
      exists)   echo "label already exists" >&2; exit 1 ;; # benign 422
      forbidden) echo "HTTP 403: not accessible" >&2; exit 1 ;; # no perms
    esac
    ;;
  "pr list")
    echo "123"
    ;;
  *)
    echo "fake gh: unhandled call: $*" >&2
    exit 99
    ;;
esac
exit 0
FAKE_GH
  chmod +x "$BIN/gh"
  PATH="$BIN:$PATH"

  # Inputs required so sourcing passes validation without exiting. The three
  # labels mirror a real promotion PR; INPUT_LABELS is parsed at source time.
  export INPUT_SOURCE_FOLDERS="values"
  export INPUT_DESTINATION_FOLDERS="values"
  export INPUT_DESTINATION_HEAD_BRANCH="temp-branch-test"
  export INPUT_DESTINATION_BASE_BRANCH="main"
  export INPUT_TITLE="[PROD] <- [DEV] kc-rd-dispatcher deploy main-2aa7372"
  export INPUT_COMMENT="test run"
  export INPUT_LABELS=$'system: kc\nenv: prod\napp: kc-rd-dispatcher'

  # shellcheck source=/dev/null
  source "$ENTRYPOINT"
  set +e          # sourcing turned on errexit; assertions need it off
  IFS=$' \t\n'    # sourcing set IFS=';' for folder parsing; restore default
}

teardown() {
  rm -rf "$TESTTMP"
}

pr_create_calls()  { grep -c '^pr create$'  "$GH_CALLS"; }
label_create_calls() { grep -c '^label create$' "$GH_CALLS"; }

@test "AC1: missing label self-heals — creates labels then retries and succeeds" {
  export FAKE_PR_CREATE=missing_label FAKE_LABEL_CREATE=ok
  run create_pull_request
  [ "$status" -eq 0 ]
  [ "$(pr_create_calls)" -eq 2 ]      # initial (fails) + retry (succeeds)
  [ "$(label_create_calls)" -eq 3 ]   # all three labels ensured
}

@test "AC2: happy path — labels exist, no label create/list, single pr create" {
  export FAKE_PR_CREATE=ok
  run create_pull_request
  [ "$status" -eq 0 ]
  [ "$(pr_create_calls)" -eq 1 ]
  [ "$(label_create_calls)" -eq 0 ]
  ! grep -q '^label list' "$GH_CALLS"   # no per-deploy label lookup
}

@test "AC3: label creation never uses --force (existing labels not clobbered)" {
  export FAKE_PR_CREATE=missing_label FAKE_LABEL_CREATE=ok
  run create_pull_request
  [ "$status" -eq 0 ]
  ! grep -q '^ARG:--force$' "$GH_ARGV"
}

@test "AC4: non-label failure fails loudly and does not self-heal" {
  export FAKE_PR_CREATE=other_error
  run create_pull_request
  [ "$status" -ne 0 ]
  [ "$(pr_create_calls)" -eq 1 ]      # no retry
  [ "$(label_create_calls)" -eq 0 ]   # classifier did not match "not found"
}

@test "AC5: label-create failure still fails loudly on retry (no silent success)" {
  export FAKE_PR_CREATE=missing_label FAKE_LABEL_CREATE=forbidden
  run create_pull_request
  [ "$status" -ne 0 ]
  [ "$(pr_create_calls)" -eq 2 ]      # retried once, retry still failed
  [ "$(label_create_calls)" -ge 1 ]   # attempted the (failing) create
}

@test "AC7: colon+space label passed to gh as a single argument" {
  export FAKE_PR_CREATE=ok
  run create_pull_request
  [ "$status" -eq 0 ]
  grep -qxF 'ARG:app: kc-rd-dispatcher' "$GH_ARGV"   # one arg, not split
  grep -qxF 'ARG:--label' "$GH_ARGV"
}
