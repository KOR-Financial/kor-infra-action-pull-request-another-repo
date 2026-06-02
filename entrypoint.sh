#!/bin/bash

set -e
#set -x

if [ -z "$INPUT_SOURCE_FOLDERS" ]
then
  echo "Source folders must be defined"
  exit -1
fi

if [ -z "$INPUT_DESTINATION_FOLDERS" ]
then
  echo "Destination folders must be defined"
  exit -1
fi

IFS=';'
read -ra SOURCE_FOLDERS <<< "$INPUT_SOURCE_FOLDERS"
echo "Source folders [${SOURCE_FOLDERS[*]}]"
echo "Source folders size = ${#SOURCE_FOLDERS[*]}"

read -ra DESTINATION_FOLDERS <<< "$INPUT_DESTINATION_FOLDERS"
echo "Destination folders [${DESTINATION_FOLDERS[*]}]"
echo "Destination folders size = ${#DESTINATION_FOLDERS[*]}"

if [  ${#DESTINATION_FOLDERS[*]} != ${#SOURCE_FOLDERS[*]} ]
then
  echo "Source and destination folders count is not match"
  exit -1
fi

if [ $INPUT_DESTINATION_HEAD_BRANCH == "main" ] || [ $INPUT_DESTINATION_HEAD_BRANCH == "master" ]
then
  echo "Destination head branch cannot be 'main' nor 'master'"
  exit 1
fi

if [ -n "$INPUT_PULL_REQUEST_REVIEWERS" ]
then
  PULL_REQUEST_REVIEWERS='-r '$INPUT_PULL_REQUEST_REVIEWERS
fi

CLONE_DIR=$(mktemp -d)
echo "env"
env
echo "Setting git variables"
export GITHUB_TOKEN=$API_TOKEN_GITHUB
git config --global user.email "$INPUT_USER_EMAIL"
git config --global user.name "$INPUT_USER_NAME"

echo "Cloning destination git repository"
git clone "https://$INPUT_USER_NAME:$API_TOKEN_GITHUB@github.com/$INPUT_DESTINATION_REPO.git" "$CLONE_DIR"

echo "Copying contents to git repo"

for i in "${!SOURCE_FOLDERS[@]}"; do
  echo "$i. source = ${SOURCE_FOLDERS[$i]}, dest = ${DESTINATION_FOLDERS[$i]}"
  mkdir -p $CLONE_DIR/${DESTINATION_FOLDERS[$i]}/
  cp ${SOURCE_FOLDERS[$i]} "$CLONE_DIR/${DESTINATION_FOLDERS[$i]}/"
done

cd "$CLONE_DIR"
git checkout -b "$INPUT_DESTINATION_HEAD_BRANCH"

echo "Adding git commit"
git add .
if git status | grep -q "Changes to be committed"
then
  git commit --message "$INPUT_TITLE"
  echo "Pushing git commit"
  git push -uf origin HEAD:$INPUT_DESTINATION_HEAD_BRANCH

  # Retry gh pr create with exponential backoff. A burst of simultaneous deploy
  # merges fires many createPullRequest calls from the same identity within
  # seconds, which GitHub rejects with its secondary rate limit ("was submitted
  # too quickly"). The branch has already been pushed by this point, so a
  # non-retried failure silently drops the promotion PR. The CLI output is
  # captured here so the real error can be reported (and inspected by later logic).
  PR_CREATE_MAX_ATTEMPTS="${PR_CREATE_MAX_ATTEMPTS:-5}"
  pr_create_delay="${PR_CREATE_INITIAL_DELAY:-10}"
  pr_create_attempt=1
  while true; do
    echo "Attempt ${pr_create_attempt}/${PR_CREATE_MAX_ATTEMPTS}: creating pull request for '${INPUT_DESTINATION_HEAD_BRANCH}'..."
    if pr_create_output=$(gh pr create -t "$INPUT_TITLE" \
                                       -b "$INPUT_COMMENT" \
                                       -B "$INPUT_DESTINATION_BASE_BRANCH" \
                                       -H "$INPUT_DESTINATION_HEAD_BRANCH" 2>&1)
    then
      echo "$pr_create_output"
      echo "::notice::Pull request for '${INPUT_DESTINATION_HEAD_BRANCH}' created on attempt ${pr_create_attempt}/${PR_CREATE_MAX_ATTEMPTS}."
      break
    fi
    # Surface the real CLI error (e.g. the secondary-rate-limit message).
    echo "$pr_create_output"

    # Idempotency: a prior attempt may have created the PR even though the CLI
    # reported an error. Match by exact --head (not a scan of the default 30-row
    # list, which can miss the branch in a busy repo) and treat it as success.
    if gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --state open | grep -q .
    then
      echo "::notice::A pull request for '${INPUT_DESTINATION_HEAD_BRANCH}' already exists; treating as success after ${pr_create_attempt} attempt(s)."
      break
    fi

    # Only retry GitHub throttling. Genuine errors (bad credentials, validation,
    # missing base branch, ...) never succeed on retry, so fail fast instead of
    # burning the backoff window. Unrecognised errors also fail fast: no worse
    # than the pre-retry behaviour, strictly better for the throttling case.
    if ! printf '%s' "$pr_create_output" | grep -qiE 'submitted too quickly|secondary rate limit|abuse detection|too many requests|rate limit|try again later|retry your request|wait a few minutes'
    then
      echo "::error::gh pr create failed with a non-retryable error; not retrying. Error: ${pr_create_output}"
      exit 1
    fi

    if [ "$pr_create_attempt" -ge "$PR_CREATE_MAX_ATTEMPTS" ]
    then
      echo "::error::gh pr create failed after ${PR_CREATE_MAX_ATTEMPTS} attempts. Last error: ${pr_create_output}"
      exit 1
    fi

    echo "::warning::gh pr create hit GitHub throttling on attempt ${pr_create_attempt}/${PR_CREATE_MAX_ATTEMPTS}; retrying in ${pr_create_delay}s..."
    # Jitter (0..delay/2) so a burst of jobs that failed together do not retry
    # in lockstep and re-trip the same limit.
    sleep "$(( pr_create_delay + RANDOM % (pr_create_delay / 2 + 1) ))"
    pr_create_attempt=$((pr_create_attempt + 1))
    pr_create_delay=$((pr_create_delay * 2))
  done

  pr_number=$(gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --state all | awk 'NR==1{print $1}')
  echo "PR_NUMBER=$pr_number" >> "$GITHUB_OUTPUT"
  echo "PR_NUMBER=$pr_number" >> "$GITHUB_ENV"

  if [ -n "$GITHUB_STEP_SUMMARY" ]
  then
    echo "PR #${pr_number} (\`${INPUT_DESTINATION_HEAD_BRANCH}\` -> \`${INPUT_DESTINATION_BASE_BRANCH}\`) created after ${pr_create_attempt} attempt(s)." >> "$GITHUB_STEP_SUMMARY"
  fi

else
  echo "No changes detected"
fi
