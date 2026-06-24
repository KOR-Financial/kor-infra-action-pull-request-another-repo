# Action pull request another repository 
This GitHub Action copies a folder from the current repository to a location in another repository and create a pull request

## Example Workflow
    name: Push File

    on: push

    jobs:
      pull-request:
        runs-on: ubuntu-latest
        steps:
        - name: Checkout
          uses: actions/checkout@v2

        - name: Create pull request
          uses: paygoc6/action-pull-request-another-repo@v1.0.1
          env:
            API_TOKEN_GITHUB: ${{ secrets.API_TOKEN_GITHUB }}
          with:
            source_folders: 'source-folder'
            destination_repo: 'user-name/repository-name'
            destination_folders: 'folder-name'
            destination_base_branch: 'branch-name'
            destination_head_branch: 'branch-name'
            user_email: 'user-name@paygo.com.br'
            user_name: 'user-name'

## Variables
* source_folders: The folder (or ";" delimited folders) to be moved. Uses the same syntax as the `cp` command. Incude the path for any files not in the repositories root directory.
* destination_repo: The repository to place the file or directory in.
* destination_folder:  The folder (or ";" delimited folders) in the destination repository to place the file in, if not the root directory.
* user_email: The GitHub user email associated with the API token secret.
* user_name: The GitHub username associated with the API token secret.
* destination_base_branch: [optional] The branch into which you want your code merged. Default is `main`.
* destination_head_branch: The branch to create to push the changes. Cannot be `master` or `main`.

## ENV
* API_TOKEN_GITHUB: You must create a personal access token in you account. Follow the link:
- [Personal access token](https://docs.github.com/en/free-pro-team@latest/github/authenticating-to-github/creating-a-personal-access-token)

> You must select the scopes: 'repo = Full control of private repositories', 'admin:org = read:org' and 'write:discussion = Read:discussion'; 


## Behavior Notes
The action will create any destination paths if they don't exist. It will also overwrite existing files if they already exist in the locations being copied to. It will not delete the entire destination repository.

When the `destination_head_branch` already exists in the destination repository, the action syncs the latest source into it (committing and pushing on top of the existing branch) instead of failing. If a pull request is already open for that branch it is reused; otherwise a new one is created. The branch is updated with a normal (non-force) push, so manual commits pushed to the PR branch are preserved — a genuinely diverged branch makes the push fail rather than silently discarding work.

The `pr_number` output (and `PR_NUMBER` env) is set whenever a pull request exists for the head branch — both when a new one is created and when an existing one is reused. Previously it was only set when a new PR was created, so consumers that branched on it being unset should account for the change.
