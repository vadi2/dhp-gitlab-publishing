#!/usr/bin/env bash
# Put the real build/publish pipeline on the GitLab-only `ci` branch of both
# mirror projects.
#
#   36-publish-ci-scripts.sh [core|integration|both]
#
# What lands on the branch:
#   /.gitlab-ci.yml   <- ci/gitlab-ci.yml   (the pipeline the repos include)
#   /ci/...           <- ci/*.sh, ci/lib/*, ci/Dockerfile, ci/entrypoint.sh
#
# The jobs fetch this branch and unpack /ci/ at run time, so updating a script
# is a commit here - no image rebuild, nothing to install on the runner.
#
# Idempotent: existing files are updated, new ones created, and a run that
# changes nothing is reported as such instead of failing.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require_token

CI_SRC="$BASE_DIR/ci"
BRANCH="${DHP_CI_BRANCH:-ci}"

# Everything a job needs, plus the files that document how the image is built.
# `.gitlab-ci.yml` on the branch comes from ci/gitlab-ci.yml (see below).
# ci/.gitlab-ci.yml, the in-repository variant, is deliberately NOT published:
# it is the file the MOH commits into their own repository once they own it,
# and putting it on the `ci` branch as well would give each project two
# pipeline definitions.
FILES=(
  "ci-build.sh"
  "release.sh"
  "release-rollback.sh"
  "setup-webroot.sh"
  "verify-site.sh"
  "run.sh"
  "lib/common.sh"
  "Dockerfile"
  "entrypoint.sh"
)

publish_one() {
  local project_id="$1" label="$2"
  echo "=== $label (project $project_id) ==="

  # What is already on the branch, so each file gets create or update. Asking
  # per file rather than listing the tree: the `ci` branch was seeded from the
  # repo, so a recursive tree listing runs to several pages and ci/ falls off
  # the end of the first one - which silently turns every update into a create
  # and the commit is rejected with "A file with this name already exists".
  local existing="" dest
  for rel in ".gitlab-ci.yml" "${FILES[@]/#/ci/}"; do
    dest="$rel"
    if [ "$(api_code GET "/projects/$project_id/repository/files/$(urlenc "$dest")?ref=$BRANCH")" = "200" ]; then
      existing="$existing $dest"
    fi
  done

  python3 - "$project_id" "$BRANCH" "$CI_SRC" "$existing" <<'PY' > /tmp/dhp-ci-actions.json
import base64, json, os, sys
project_id, branch, ci_src, existing = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
have = set(existing.split())

files = [("gitlab-ci.yml", ".gitlab-ci.yml")]
for rel in os.environ["DHP_FILES"].split():
    files.append((rel, "ci/" + rel))

actions = []
for src_rel, dest in files:
    src = os.path.join(ci_src, src_rel)
    with open(src, "rb") as fh:
        content = fh.read()
    actions.append({
        "action": "update" if dest in have else "create",
        "file_path": dest,
        "content": base64.b64encode(content).decode("ascii"),
        "encoding": "base64",
        "execute_filemode": src_rel.endswith(".sh"),
    })

print(json.dumps({
    "branch": branch,
    "commit_message": "ci: real IG build and publish pipeline",
    "actions": actions,
}))
PY

  local body
  body="$(api_soft POST "/projects/$project_id/repository/commits" \
          --header "Content-Type: application/json" \
          --data @/tmp/dhp-ci-actions.json)"

  if printf '%s' "$body" | grep -q '"id"'; then
    printf '%s' "$body" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("committed", d["short_id"], d["title"])'
  elif printf '%s' "$body" | grep -qi 'no changes\|contents have not changed'; then
    echo "already up to date"
  else
    echo "FAILED: $body" >&2
    return 1
  fi
}

export DHP_FILES="${FILES[*]}"

case "${1:-both}" in
  core)        publish_one "$CORE_PROJECT_ID" core ;;
  integration) publish_one "$INTEGRATION_PROJECT_ID" integration ;;
  both)        publish_one "$CORE_PROJECT_ID" core
               publish_one "$INTEGRATION_PROJECT_ID" integration ;;
  *) echo "usage: $0 [core|integration|both]" >&2; exit 2 ;;
esac

rm -f /tmp/dhp-ci-actions.json
