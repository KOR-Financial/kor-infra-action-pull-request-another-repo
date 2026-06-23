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

if [ -n "$INPUT_PULL_REQUEST_REVIEWERS" ]
then
  PULL_REQUEST_REVIEWERS='-r '$INPUT_PULL_REQUEST_REVIEWERS
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
               #"$PULL_REQUEST_REVIEWERS"
}

set_pr_number_output() {
  pr_number=$(gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --json number --jq '.[0].number')
  echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
  echo "PR_NUMBER=$pr_number" >> "$GITHUB_OUTPUT"
  echo "PR_NUMBER=$pr_number" >> "$GITHUB_ENV"
}

copy_source_folders() {
  echo "Copying contents to git repo"
  for i in "${!SOURCE_FOLDERS[@]}"; do
    echo "$i. source = ${SOURCE_FOLDERS[$i]}, dest = ${DESTINATION_FOLDERS[$i]}"
    mkdir -p "$CLONE_DIR/${DESTINATION_FOLDERS[$i]}/"
    cp ${SOURCE_FOLDERS[$i]} "$CLONE_DIR/${DESTINATION_FOLDERS[$i]}/"
  done
}

# Stages, commits and pushes the working tree. Commit message is the first
# argument. Returns non-zero (without committing) when there is nothing to commit.
commit_and_push() {
  echo "Adding git commit"
  git add .
  if git status | grep -q "Changes to be committed"
  then
    git commit --message "$1"
    echo "Pushing git commit"
    git push -uf origin "HEAD:$INPUT_DESTINATION_HEAD_BRANCH"
  else
    echo "No changes detected"
    return 1
  fi
}

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
  git pull

  copy_source_folders
  commit_and_push "chore: Synced with source" || true

  if [ -z "$(gh pr list --head "$INPUT_DESTINATION_HEAD_BRANCH" --json number --jq '.[0].number')" ]
  then
    echo "No pull request linked to '$INPUT_DESTINATION_HEAD_BRANCH'"
    create_pull_request
  else
    echo "Pull request already linked to '$INPUT_DESTINATION_HEAD_BRANCH'"
  fi
  set_pr_number_output
  exit 0
fi

copy_source_folders

git checkout -b "$INPUT_DESTINATION_HEAD_BRANCH"

if commit_and_push "$INPUT_TITLE"
then
  create_pull_request
  set_pr_number_output
fi
