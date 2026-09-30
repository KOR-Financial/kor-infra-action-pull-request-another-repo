#!/usr/bin/env bats
#
# Tests for the retry around PR creation (gh_retry.sh, used by entrypoint.sh):
# transient GitHub errors such as the secondary rate limit ("was submitted too
# quickly") are retried with backoff; anything else fails at once; a create
# that landed server-side is not repeated. gh is faked on PATH, sleep stubbed.

setup() {
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../entrypoint.sh"

  TESTTMP="$(mktemp -d)"
  BIN="${TESTTMP}/bin"
  mkdir -p "$BIN"

  export GH_CALLS="${TESTTMP}/gh_calls"
  export GH_ARGV="${TESTTMP}/gh_argv"
  export PR_STATE="${TESTTMP}/pr_created"   # exists once the PR exists
  export CREATE_COUNT="${TESTTMP}/create_count"
  : > "$GH_CALLS"
  : > "$GH_ARGV"
  echo 0 > "$CREATE_COUNT"

  cat > "$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh. FAKE_PR_CREATE picks the `pr create` behaviour:
#   throttled_once   first call throttled (no PR), then succeeds
#   throttled_landed first call creates the PR but reports throttling
#   always_throttled every call throttled
#   server_error     GraphQL "Something went wrong" once, then succeeds
#   http_422         a non-transient error
printf '%s %s\n' "$1" "$2" >> "$GH_CALLS"
printf 'ARG:%s\n' "$@" >> "$GH_ARGV"

throttled() { echo "pull request create failed: GraphQL: was submitted too quickly (createPullRequest)" >&2; exit 1; }

case "$1 $2" in
  "pr create")
    n=$(( $(cat "$CREATE_COUNT") + 1 )); echo "$n" > "$CREATE_COUNT"
    case "$FAKE_PR_CREATE" in
      throttled_once)   [ "$n" -eq 1 ] && throttled ;;
      throttled_landed) touch "$PR_STATE"; [ "$n" -eq 1 ] && throttled ;;
      always_throttled) throttled ;;
      server_error)     [ "$n" -eq 1 ] && { echo "GraphQL: Something went wrong while executing your query on 2026-09-29T22:12:45Z." >&2; exit 1; } ;;
      http_422)         echo "HTTP 422: Validation Failed" >&2; exit 1 ;;
    esac
    touch "$PR_STATE"
    echo "https://github.com/kor/repo/pull/123"
    ;;
  "pr list")
    [ -f "$PR_STATE" ] && echo "123"
    ;;
  "api -X")
    echo '[]'
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

  export GH_RETRY_SLEEP=true   # no real waiting

  export INPUT_SOURCE_FOLDERS="values"
  export INPUT_DESTINATION_FOLDERS="values"
  export INPUT_DESTINATION_REPO="kor-financial/kor-infra-argocd-prod"
  export INPUT_DESTINATION_HEAD_BRANCH="temp-branch-test"
  export INPUT_DESTINATION_BASE_BRANCH="main"
  export INPUT_TITLE="[PROD-INT] <- [DEV] rs-translator deploy main-2aa7372"
  export INPUT_COMMENT="test run"
  export INPUT_LABELS=$'system: rs\nenv: prod-int\napp: rs-translator'

  # shellcheck source=/dev/null
  source "$ENTRYPOINT"
  set +e
  IFS=$' \t\n'
}

teardown() {
  rm -rf "$TESTTMP"
}

pr_create_calls() { grep -c '^pr create$' "$GH_CALLS"; }
label_api_calls() { grep -c '^api -X$' "$GH_CALLS"; }

@test "R1: a throttled create is retried and succeeds" {
  export FAKE_PR_CREATE=throttled_once
  run create_pull_request
  [ "$status" -eq 0 ]
  [ "$(pr_create_calls)" -eq 2 ]
  [ "$(label_api_calls)" -eq 0 ]    # gh pr create applied the labels itself
  [ "$(get_pr_number)" = "123" ]
}

@test "R2: GraphQL 'Something went wrong' is retried" {
  export FAKE_PR_CREATE=server_error
  run create_pull_request
  [ "$status" -eq 0 ]
  [ "$(pr_create_calls)" -eq 2 ]
}

@test "R3: a create that landed server-side is not repeated, and its labels are applied" {
  export FAKE_PR_CREATE=throttled_landed
  run create_pull_request
  [ "$status" -eq 0 ]
  [ "$(pr_create_calls)" -eq 1 ]    # no duplicate create
  [ "$(label_api_calls)" -eq 1 ]
  grep -qxF 'ARG:repos/kor-financial/kor-infra-argocd-prod/issues/123/labels' "$GH_ARGV"
  grep -qxF 'ARG:labels[]=app: rs-translator' "$GH_ARGV"
}

@test "R4: persistent throttling gives up after 5 attempts and fails" {
  export FAKE_PR_CREATE=always_throttled
  run create_pull_request
  [ "$status" -ne 0 ]
  [ "$(pr_create_calls)" -eq 5 ]
  [[ "$output" == *"giving up after 5 attempts"* ]]
}

@test "R5: a non-transient error is not retried" {
  export FAKE_PR_CREATE=http_422
  run create_pull_request
  [ "$status" -ne 0 ]
  [ "$(pr_create_calls)" -eq 1 ]
}

@test "R6: backoff starts near 15s, grows, and is capped at 120s" {
  for _ in $(seq 1 30); do
    d1=$(gh_retry_delay 1); d4=$(gh_retry_delay 4); d9=$(gh_retry_delay 9)
    [ "$d1" -ge 8 ] && [ "$d1" -le 15 ]
    [ "$d4" -ge 60 ] && [ "$d4" -le 120 ]
    [ "$d9" -ge 60 ] && [ "$d9" -le 120 ]
  done
}
