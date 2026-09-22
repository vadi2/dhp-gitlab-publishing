#!/usr/bin/env bash
# Fallback for an unlicensed instance (or plain CE): fetch both repos from
# GitHub and push all branches + tags into the GitLab mirror projects.
#
# Safety properties:
#   - It NEVER pushes to GitHub. The GitHub remote is only ever fetched.
#   - It NEVER uses `git push --mirror` / `--prune`, so the GitLab-only `ci`
#     branch (and any other GitLab-only ref) survives every sync.
#   - It touches no existing checkout: it uses its own bare mirrors under
#     infra/mirrors/.
#
# Usage:
#   ./manual-sync.sh              # sync both
#   ./manual-sync.sh core         # sync only core
#   ./manual-sync.sh integration  # sync only integration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

MIRRORS="$INFRA_DIR/mirrors"
mkdir -p "$MIRRORS"

sync_one() {
  local name="$1" github_url="$2" gitlab_path="$3"
  local bare="$MIRRORS/${name}.git"

  echo "=============================================================="
  echo "== $name"
  echo "=============================================================="

  if [[ ! -d "$bare" ]]; then
    echo "-- bare mirror missing, cloning from GitHub"
    git clone --mirror "$github_url" "$bare"
  else
    echo "-- fetching from GitHub"
    # --prune keeps the LOCAL bare mirror faithful to GitHub. It has no effect
    # on GitLab because the push below never prunes.
    git -C "$bare" fetch --prune --tags "$github_url" \
      '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
  fi

  local push_url="http://root:${GITLAB_ROOT_TOKEN}@${GITLAB_HOST}:${GITLAB_HTTP_PORT}/${gitlab_path}.git"

  echo "-- pushing branches + tags to ${GL}/${gitlab_path}"
  # Explicit refspecs, no --prune: creates/updates refs, deletes nothing.
  git -C "$bare" push --quiet "$push_url" \
    '+refs/heads/*:refs/heads/*' \
    '+refs/tags/*:refs/tags/*' 2>&1 | grep -v '^remote:' || true

  echo "-- refs now in GitLab:"
  local enc; enc=$(urlenc "$gitlab_path")
  local nb nt
  nb=$(api GET "/projects/${enc}/repository/branches?per_page=100" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
  nt=$(api GET "/projects/${enc}/repository/tags?per_page=100" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
  echo "   branches: $nb   tags: $nt"

  # QA F-19: api_soft on purpose - a 404 here is the "ci branch missing"
  # answer, so the body has to come back rather than abort the script. Every
  # other call in this file uses `api` (--fail-with-body).
  if api_soft GET "/projects/${enc}/repository/branches/ci" | grep -q '"name":"ci"'; then
    echo "   ci branch: present (survived the sync)"
  else
    echo "   ci branch: MISSING - run 35-seed-ci-branch.sh"
  fi
}

WHICH="${1:-both}"

case "$WHICH" in
  core)
    sync_one core "$CORE_GITHUB_URL" "$CORE_PROJECT_PATH" ;;
  integration)
    sync_one integration "$INTEGRATION_GITHUB_URL" "$INTEGRATION_PROJECT_PATH" ;;
  both)
    sync_one core "$CORE_GITHUB_URL" "$CORE_PROJECT_PATH"
    sync_one integration "$INTEGRATION_GITHUB_URL" "$INTEGRATION_PROJECT_PATH" ;;
  *)
    echo "usage: $0 [core|integration|both]" >&2; exit 1 ;;
esac

echo
echo "done."
