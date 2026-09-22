#!/usr/bin/env bash
# Turn on GitLab pull mirroring from GitHub for both projects, then force an
# immediate mirror update and poll until it settles.
#
# Pull mirroring is a Premium/Ultimate feature. On an unlicensed instance the
# API silently ignores `mirror=true` (it stays false) - see NOTES.md.
#
# Settings applied:
#   import_url                          the public GitHub URL
#   mirror=true                         enable pull mirroring
#   mirror_trigger_builds=true          mirrored commits AND tags create pipelines
#   only_mirror_protected_branches=false  mirror every branch, not just protected
#   mirror_overwrites_diverged_branches=false  do not clobber diverged branches
#
# Usage: ./enable-pull-mirror.sh [core|integration|both]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

# QA F-19: `api` (--fail-with-body), not `api_soft`, everywhere the body is not
# itself the thing being tested. The two api_soft calls left are marked.
show_mirror_state() {
  local enc="$1"
  api GET "/projects/${enc}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in ("mirror", "import_url", "mirror_trigger_builds",
          "only_mirror_protected_branches", "mirror_overwrites_diverged_branches",
          "import_status", "import_error"):
    if k in d:
        print("   %-36s= %s" % (k, d[k]))
'
}

enable_one() {
  local name="$1" github_url="$2" gitlab_path="$3"
  local enc; enc=$(urlenc "$gitlab_path")

  echo "=============================================================="
  echo "== $name  ($gitlab_path)"
  echo "=============================================================="

  echo "-- before:"
  show_mirror_state "$enc"

  echo "-- enabling pull mirroring"
  api PUT "/projects/${enc}" \
    --form "import_url=${github_url}" \
    --form "mirror=true" \
    --form "mirror_trigger_builds=true" \
    --form "only_mirror_protected_branches=false" \
    --form "mirror_overwrites_diverged_branches=false" > /dev/null

  echo "-- after:"
  show_mirror_state "$enc"

  local is_mirror
  is_mirror=$(api GET "/projects/${enc}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("mirror"))')
  if [[ "$is_mirror" != "True" && "$is_mirror" != "true" ]]; then
    echo
    echo "   mirror is still FALSE."
    echo "   GitLab accepted the request but did not enable mirroring - this is what"
    echo "   an unlicensed (Free) instance does. Apply a Premium/Ultimate licence"
    echo "   (scripts/apply-license.sh) and re-run. Use scripts/manual-sync.sh"
    echo "   in the meantime."
    return 1
  fi

  # force=true so this also clears a hard-failed mirror (QA F-02), and
  # api_code rather than api_soft so a 403/404 is reported instead of ignored.
  echo "-- forcing an immediate mirror update (POST /projects/:id/mirror/pull?force=true)"
  echo "   HTTP $(api_code POST "/projects/${enc}/mirror/pull?force=true")"

  echo "-- polling mirror status (the worker runs on a ~1 min cron, be patient)"
  for _ in $(seq 1 60); do
    local out
    out=$(api GET "/projects/${enc}/mirror/pull")
    local status
    # update_status stays "none" until the worker has actually run once, so
    # treat "none" as still-pending rather than terminal.
    status=$(python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); raise SystemExit
st = d.get("update_status", "unknown")
if st == "none" and not d.get("last_update_at"):
    st = "pending"
print(st)' <<<"$out")
    if [[ "$status" == "finished" || "$status" == "failed" ]]; then
      python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in ("enabled", "update_status", "last_update_at", "last_update_started_at",
          "last_successful_update_at", "last_error"):
    if k in d:
        print("   %-28s= %s" % (k, d[k]))' <<<"$out"
      break
    fi
    sleep 5
  done

  echo "-- refs now present in GitLab:"
  local nb nt
  nb=$(api GET "/projects/${enc}/repository/branches?per_page=100" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
  nt=$(api GET "/projects/${enc}/repository/tags?per_page=100" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
  echo "   branches: $nb   tags: $nt"
  # api_soft on purpose: a 404 here is the "ci branch gone" answer.
  if api_soft GET "/projects/${enc}/repository/branches/ci" | grep -q '"name":"ci"'; then
    echo "   ci branch: PRESENT (survived the mirror update)"
  else
    echo "   ci branch: GONE - pull mirroring removed it, re-run 35-seed-ci-branch.sh"
  fi
}

WHICH="${1:-both}"
RC=0
case "$WHICH" in
  core)        enable_one core "$CORE_GITHUB_URL" "$CORE_PROJECT_PATH" || RC=1 ;;
  integration) enable_one integration "$INTEGRATION_GITHUB_URL" "$INTEGRATION_PROJECT_PATH" || RC=1 ;;
  both)
    enable_one core "$CORE_GITHUB_URL" "$CORE_PROJECT_PATH" || RC=1
    enable_one integration "$INTEGRATION_GITHUB_URL" "$INTEGRATION_PROJECT_PATH" || RC=1 ;;
  *) echo "usage: $0 [core|integration|both]" >&2; exit 1 ;;
esac

exit $RC
