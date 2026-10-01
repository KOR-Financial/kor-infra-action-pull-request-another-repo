#!/bin/bash

set -e
#set -x

# gh_retry: retries gh calls through transient GitHub errors, notably the
# secondary rate limit ("was submitted too quickly") that hits PR creation
# when many promotions run at once.
# shellcheck source=gh_retry.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh_retry.sh"

if [ -z "$INPUT_SOURCE_FOLDERS" ]
then
  echo "Source folders must be defined"
  exit 1
fi

if [ -z "$INPUT_DESTINATION_FOLDERS" ]
then
  echo "Destination folders must be defined"
  exit 2
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
  exit 3
fi

if [ $INPUT_DESTINATION_HEAD_BRANCH == "main" ] || [ $INPUT_DESTINATION_HEAD_BRANCH == "master" ]
then
  echo "Destination head branch cannot be 'main' nor 'master'"
  exit 4
fi

LABEL_ARGS=()
LABELS=()  # raw values, for creating any that are missing on PR failure
if [ -n "$INPUT_LABELS" ]
then
  # Labels may be passed as a comma-separated list and/or multiline text.
  # Normalise both forms by turning commas into newlines, then read each label.
  while IFS= read -r label
  do
    label="${label#"${label%%[![:space:]]*}"}"  # trim leading whitespace
    label="${label%"${label##*[![:space:]]}"}"  # trim trailing whitespace
    if [ -n "$label" ]
    then
      LABEL_ARGS+=(--label "$label")
      LABELS+=("$label")
    fi
  done <<< "${INPUT_LABELS//,/$'\n'}"
  echo "Labels [${LABEL_ARGS[*]}]"
fi

# Create missing labels in the destination repo. No --force, so existing labels
# keep their colour/description; best-effort (a real failure surfaces on retry).
ensure_labels() {
  local label
  for label in "${LABELS[@]}"
  do
    echo "Ensuring label exists in destination repo: $label"
    gh_retry gh label create "$label" --color ededed \
      || echo "Note: label '$label' already exists or could not be created"
  done
}

# Retried through transient GitHub errors. A create can land server-side and
# still report an error, so each retry first checks whether the PR now exists.
open_pr() {
  gh_retry --check pr_exists_for_head \
    gh pr create -t "$INPUT_TITLE" \
                 -b "$INPUT_COMMENT" \
                 -B "$INPUT_DESTINATION_BASE_BRANCH" \
                 -H "$INPUT_DESTINATION_HEAD_BRANCH" \
                 "${LABEL_ARGS[@]}" || return $?
  # gh adds labels in a second call after creating the PR. When the retry
  # stopped because the PR already existed, that call may not have run, so
  # apply the labels now (idempotent; the REST call creates any missing label).
  if [ "${GH_RETRY_VIA_CHECK:-0}" = "1" ] && [ "${#LABELS[@]}" -gt 0 ]
  then
    local pr_number label_fields=() label
    pr_number=$(get_pr_number)
    for label in "${LABELS[@]}"
    do
      label_fields+=(-f "labels[]=$label")
    done
    echo "Pull request #$pr_number already existed after a retry; ensuring its labels"
    gh_retry gh api -X POST "repos/$INPUT_DESTINATION_REPO/issues/$pr_number/labels" \
      "${label_fields[@]}" > /dev/null
  fi
}

pr_exists_for_head() {
  [ -n "$(gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --json number --jq '.[0].number')" ]
}

create_pull_request() {
  echo "Creating a pull request"
  local pr_stderr
  pr_stderr=$(mktemp)
  trap 'rm -f "$pr_stderr"' RETURN
  # gh pr create aborts (no PR) if a --label doesn't exist. Try once; on a
  # missing-label failure create the labels and retry. Happy path pays nothing.
  if open_pr 2>"$pr_stderr"
  then
    cat "$pr_stderr" >&2
    return 0
  fi
  cat "$pr_stderr" >&2

  # Self-heal only the missing-label case (gh: "could not add label: 'x' not
  # found"); matching the label-specific phrase avoids firing on unrelated 404s.
  grep -qi "could not add label" "$pr_stderr" || return 1

  echo "PR creation failed on a missing label; creating labels and retrying once"
  ensure_labels
  open_pr
}

get_pr_number() {
  gh_retry gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --json number --jq '.[0].number'
}

write_pr_number_output() {
  local pr_number="$1"
  echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
  echo "PR_NUMBER=$pr_number" >> "$GITHUB_OUTPUT"
  echo "PR_NUMBER=$pr_number" >> "$GITHUB_ENV"
}

copy_source_folders() {
  echo "Copying contents to git repo"
  for i in "${!SOURCE_FOLDERS[@]}"; do
    echo "$i. source = ${SOURCE_FOLDERS[$i]}, dest = ${DESTINATION_FOLDERS[$i]}"
    dest_dir="$CLONE_DIR/${DESTINATION_FOLDERS[$i]}"
    mkdir -p "$dest_dir/"
    # Source paths are relative to the source repository, but this runs after
    # cd'ing into the destination clone, so resolve them against SOURCE_DIR.
    # Intentionally unquoted: lets callers pass 'cp'-style globs (e.g. '*.yml').
    # The trade-off is that source paths containing spaces are not supported.
    # shellcheck disable=SC2086
    for src in "$SOURCE_DIR"/${SOURCE_FOLDERS[$i]}; do
      dest="$dest_dir/$(basename "$src")"
      # Skip when the destination already holds identical content, to avoid a
      # no-op commit (e.g. when a repo is synced into a clone of itself).
      if [ -f "$dest" ] && cmp -s "$src" "$dest"
      then
        echo "Skipping '$src': identical content already at destination"
        continue
      fi
      cp "$src" "$dest"
    done
  done
}

# Stages, commits and pushes the working tree. Commit message is the first
# argument. Returns non-zero (without committing) when there is nothing to commit.
commit_and_push() {
  echo "Adding git commit"
  git add .
  if git diff --cached --quiet
  then
    echo "No changes detected"
    return 1
  fi
  git commit --message "$1"
  echo "Pushing git commit"
  # Non-force push: a non-fast-forward (e.g. someone edited the PR branch by
  # hand) fails loudly instead of silently discarding their commits.
  git push -u origin "HEAD:$INPUT_DESTINATION_HEAD_BRANCH"
}

# When sourced (e.g. by tests), stop here: only the functions above are needed.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  return 0
fi

# The directory the action was invoked from (the checked-out source repo).
# Captured before cd'ing into the clone so source paths resolve correctly.
SOURCE_DIR="$PWD"
CLONE_DIR=$(mktemp -d)
echo "env"
env
echo "Setting git variables"
export GITHUB_TOKEN=$API_TOKEN_GITHUB
git config --global user.email "$INPUT_USER_EMAIL"
git config --global user.name "$INPUT_USER_NAME"

echo "Cloning destination git repository"
git clone "https://$INPUT_USER_NAME:$API_TOKEN_GITHUB@github.com/$INPUT_DESTINATION_REPO.git" "$CLONE_DIR"

cd "$CLONE_DIR"

if git ls-remote --exit-code --heads origin "$INPUT_DESTINATION_HEAD_BRANCH" >/dev/null 2>&1
then
  echo "Destination head branch '$INPUT_DESTINATION_HEAD_BRANCH' already exists, syncing changes"
  git checkout "$INPUT_DESTINATION_HEAD_BRANCH"
  # --ff-only keeps the intent explicit and avoids set -e aborting the action
  # on an unexpected merge commit if the branch ever diverges.
  git pull --ff-only

  copy_source_folders
  commit_and_push "chore: Synced with source" || true

  pr_number=$(get_pr_number)
  if [ -z "$pr_number" ]
  then
    echo "No pull request linked to '$INPUT_DESTINATION_HEAD_BRANCH'"
    create_pull_request
    pr_number=$(get_pr_number)
  else
    echo "Pull request already linked to '$INPUT_DESTINATION_HEAD_BRANCH'"
  fi
  write_pr_number_output "$pr_number"
  exit 0
fi

copy_source_folders

git checkout -b "$INPUT_DESTINATION_HEAD_BRANCH"

if commit_and_push "$INPUT_TITLE"
then
  create_pull_request
  write_pr_number_output "$(get_pr_number)"
fi
