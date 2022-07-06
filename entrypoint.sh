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

if [ $INPUT_DESTINATION_HEAD_BRANCH == "main" ] || [ $INPUT_DESTINATION_HEAD_BRANCH == "master"]
then
  echo "Destination head branch cannot be 'main' nor 'master'"
  return -1
fi

if [ -z "$INPUT_PULL_REQUEST_REVIEWERS" ]
then
  PULL_REQUEST_REVIEWERS=$INPUT_PULL_REQUEST_REVIEWERS
else
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
  ls ${SOURCE_FOLDERS[$i]}
  cp ${SOURCE_FOLDERS[$i]} "$CLONE_DIR/${DESTINATION_FOLDERS[$i]}/"
done

cd "$CLONE_DIR"
git checkout -b "$INPUT_DESTINATION_HEAD_BRANCH"

echo "Adding git commit"
git add .
if git status | grep -q "Changes to be committed"
then
  git commit --message "Update from https://github.com/$GITHUB_REPOSITORY/commit/$GITHUB_SHA"
  echo "Pushing git commit"
  git push -u origin HEAD:$INPUT_DESTINATION_HEAD_BRANCH
  echo "Creating a pull request"
  gh pr create -t "$INPUT_TITLE" \
               -b "$INPUT_COMMENT" \
               -B "$INPUT_DESTINATION_BASE_BRANCH" \
               -H "$INPUT_DESTINATION_HEAD_BRANCH"
               #"$PULL_REQUEST_REVIEWERS"
else
  echo "No changes detected"
fi
