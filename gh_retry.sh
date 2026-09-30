#!/usr/bin/env bash
# gh_retry.sh — retry GitHub-mutating gh calls through GitHub's transient failures.
#
# Source it; do not execute it. Safe under `set -euo pipefail`.
#
# GitHub throttles content creation (PRs, comments, reviews) with a *secondary*
# rate limit that is independent of the hourly quota. When several promotion
# workflows fire at once it answers with, e.g.:
#   GraphQL: was submitted too quickly (createPullRequest)
#   You have exceeded a secondary rate limit and have been temporarily blocked from content creation
#   GraphQL: Something went wrong while executing your query
# These go away after a short wait, so the call is retried with exponential
# backoff and jitter. Any other failure is returned at once, unchanged.
#
# A create can succeed server-side and still report an error, so a retry of a
# create first runs an existence check (--check) and stops if it now passes.
#
# Functions:
#   gh_retry [--check CMD] CMD [ARG...]
#       Runs CMD. On a transient failure, waits and retries. With --check, CMD
#       (a function or command name, run with no arguments) is evaluated
#       before every retry; exit 0 means "already done" and gh_retry returns 0.
#       stdout/stderr of the final attempt are passed through. Sets
#       GH_RETRY_VIA_CHECK=1 when it returned because the check passed (the
#       command itself never reported success), else 0.
#   gh_retry_pr_comment TARGET BODY_FILE [gh pr comment option...]
#       Posts BODY_FILE as a comment on PR TARGET (number or URL). Before a
#       retry it checks whether an identical comment was created since the
#       first attempt. Extra options are passed to both `gh pr comment` and the
#       `gh pr view` of the check, so keep them to ones both accept (--repo).
#   gh_retry_pr_approve TARGET [gh pr review option...]
#       Approves PR TARGET. Before a retry it checks whether an approval was
#       submitted since the first attempt. Same rule for extra options.
#
# Only content creation needs a check. Adding reviewers, assignees or labels
# is idempotent, so plain `gh_retry gh pr edit ...` is enough there.
#
# Tuning (environment):
#   GH_RETRY_ATTEMPTS    total attempts           (default 5)
#   GH_RETRY_BASE_DELAY  first backoff, seconds   (default 15)
#   GH_RETRY_MAX_DELAY   backoff cap, seconds     (default 120)
#   GH_RETRY_SLEEP       sleep command            (default sleep; tests stub it)

# Error signatures that are worth waiting out. Matched case-insensitively
# against the failed attempt's stdout+stderr.
GH_RETRY_TRANSIENT_PATTERN='submitted too quickly|secondary rate limit|rate limit exceeded|API rate limit|abuse detection|Something went wrong while executing your query|HTTP 429|HTTP 502|HTTP 503|Bad Gateway|Service Unavailable'

# gh_retry_is_transient FILE — 0 when FILE holds a transient error signature.
gh_retry_is_transient() {
  grep -Eqi "$GH_RETRY_TRANSIENT_PATTERN" "$1"
}

# gh_retry_delay ATTEMPT — seconds to wait after failed attempt ATTEMPT (1-based):
# min(cap, base * 2^(ATTEMPT-1)), then "equal jitter": half fixed, half random.
gh_retry_delay() {
  local attempt="$1"
  local base="${GH_RETRY_BASE_DELAY:-15}"
  local cap="${GH_RETRY_MAX_DELAY:-120}"
  local delay=$(( base * (1 << (attempt - 1)) ))
  (( delay > cap )) && delay=$cap
  local half=$(( delay / 2 ))
  echo $(( delay - half + RANDOM % (half + 1) ))
}

gh_retry() {
  local check=""
  if [ "${1:-}" = "--check" ]; then
    check="$2"
    shift 2
  fi

  local attempts="${GH_RETRY_ATTEMPTS:-5}"
  local sleep_cmd="${GH_RETRY_SLEEP:-sleep}"
  local out err rc attempt=1 delay
  out=$(mktemp)
  err=$(mktemp)
  GH_RETRY_VIA_CHECK=0

  while :; do
    rc=0
    "$@" >"$out" 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      cat "$out"
      cat "$err" >&2
      rm -f "$out" "$err"
      return 0
    fi

    cat "$out" "$err" > "$err.all"
    if ! gh_retry_is_transient "$err.all"; then
      cat "$out"
      cat "$err" >&2
      rm -f "$out" "$err" "$err.all"
      return "$rc"
    fi

    if [ "$attempt" -ge "$attempts" ]; then
      cat "$out"
      cat "$err" >&2
      echo "gh_retry: giving up after $attempt attempts: $*" >&2
      rm -f "$out" "$err" "$err.all"
      return "$rc"
    fi

    delay=$(gh_retry_delay "$attempt")
    echo "gh_retry: attempt $attempt/$attempts hit a transient GitHub error; retrying in ${delay}s: $(head -c 300 "$err.all" | tr '\n' ' ')" >&2
    rm -f "$err.all"
    "$sleep_cmd" "$delay"
    attempt=$((attempt + 1))

    if [ -n "$check" ] && "$check" >/dev/null 2>&1; then
      echo "gh_retry: the previous attempt took effect server-side; not repeating it: $*" >&2
      GH_RETRY_VIA_CHECK=1
      rm -f "$out" "$err"
      return 0
    fi
  done
}

# Timestamp (UTC, ISO 8601) a little before now, used to tell "created by this
# call" from older content. The margin absorbs runner/GitHub clock skew.
_gh_retry_since() {
  date -u -d "@$(( $(date -u +%s) - 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$(( $(date -u +%s) - 60 ))" +%Y-%m-%dT%H:%M:%SZ
}

gh_retry_pr_comment() {
  local target="$1" body_file="$2"
  shift 2
  _GH_RETRY_TARGET="$target"
  _GH_RETRY_BODY_FILE="$body_file"
  _GH_RETRY_SINCE=$(_gh_retry_since)
  _GH_RETRY_EXTRA=("$@")
  gh_retry --check _gh_retry_comment_exists \
    gh pr comment "$target" --body-file "$body_file" "$@"
}

# True when a comment with the exact body (trailing whitespace ignored) was
# created on the PR since the first attempt.
_gh_retry_comment_exists() {
  gh pr view "$_GH_RETRY_TARGET" ${_GH_RETRY_EXTRA[@]+"${_GH_RETRY_EXTRA[@]}"} --json comments 2>/dev/null \
    | jq -e --arg since "$_GH_RETRY_SINCE" --rawfile want "$_GH_RETRY_BODY_FILE" \
        '[.comments[] | select(.createdAt >= $since and ((.body | sub("\\s+$"; "")) == ($want | sub("\\s+$"; ""))))] | length > 0' \
        >/dev/null
}

gh_retry_pr_approve() {
  local target="$1"
  shift
  _GH_RETRY_TARGET="$target"
  _GH_RETRY_SINCE=$(_gh_retry_since)
  _GH_RETRY_EXTRA=("$@")
  gh_retry --check _gh_retry_approval_exists \
    gh pr review --approve "$target" "$@"
}

# True when an approval was submitted on the PR since the first attempt.
_gh_retry_approval_exists() {
  gh pr view "$_GH_RETRY_TARGET" ${_GH_RETRY_EXTRA[@]+"${_GH_RETRY_EXTRA[@]}"} --json reviews 2>/dev/null \
    | jq -e --arg since "$_GH_RETRY_SINCE" \
        '[.reviews[] | select(.state == "APPROVED" and .submittedAt >= $since)] | length > 0' \
        >/dev/null
}
