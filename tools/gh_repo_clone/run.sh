#!/bin/bash
# gh_repo_clone/run.sh — clone a GitHub repository into a temporary directory
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .repo, optional .ref)
# Writes: cloned repository to /tmp/shai-clone-XXXXXX; clone path to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
repo=$(printf '%s' "$input" | jq -r '.repo')
ref=$(printf '%s' "$input" | jq -r '.ref // empty')

if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf 'Invalid repo format: %s (expected OWNER/REPO)' "$repo"
  exit 1
fi

clone_dir=$(mktemp -d /tmp/shai-clone-XXXXXX) || {
  printf 'Cannot create temp directory'
  exit 1
}

timeout 120s gh repo clone "$repo" "$clone_dir" -- --quiet 2>&1 || {
  rm -rf "$clone_dir"
  printf 'Clone failed for %s' "$repo"
  exit 1
}

if [ -n "$ref" ]; then
  git -C "$clone_dir" checkout "$ref" --quiet 2>&1 || {
    rm -rf "$clone_dir"
    printf 'Cloned but checkout of %s failed; temp directory cleaned up' "$ref"
    exit 1
  }
fi

printf 'Cloned %s to %s' "$repo" "$clone_dir"
