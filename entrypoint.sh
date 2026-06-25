#!/bin/bash

set -e
#set -x

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
    fi
  done <<< "${INPUT_LABELS//,/$'\n'}"
  echo "Labels [${LABEL_ARGS[*]}]"
fi

create_pull_request() {
  echo "Creating a pull request"
  gh pr create -t "$INPUT_TITLE" \
               -b "$INPUT_COMMENT" \
               -B "$INPUT_DESTINATION_BASE_BRANCH" \
               -H "$INPUT_DESTINATION_HEAD_BRANCH" \
               "${LABEL_ARGS[@]}"
}

get_pr_number() {
  gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --json number --jq '.[0].number'
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
