#!/usr/bin/env bash
# Put the `dhp-webroot` resource group into `oldest_first` on both projects.
#
#   37-resource-group-mode.sh [core|integration|both]   (default: both)
#
# Why this is not optional:
#
# Both publishing jobs declare `resource_group: dhp-webroot`, which stops two
# of them running at once. GitLab's default process mode is `unordered`: when
# several jobs are queued on a resource group, the one that gets the resource
# next is not defined. Pushing two release tags together - 0.9.1 and 0.9.2,
# say - therefore does not guarantee they publish in that order, and a release
# with `mode: milestone` (the default) takes over the canonical URL. Publishing
# 0.9.1 after 0.9.2 would leave https://dhp.uz/fhir/core/ serving 0.9.1.
#
# `oldest_first` runs the queue in the order the jobs were created, which for
# two pushed tags is the order they were pushed.
#
# ci/release.sh refuses to publish a version older than the newest already
# published (unless PUB_MODE=working), so the damage is prevented either way -
# but the job would fail rather than just wait, and the operator would have to
# work out why. Both, then: this makes the common case correct, and the check
# in the script catches the rest.
#
# The resource group only exists once a pipeline has created it, so run this
# after the first pipeline on each project (45-trigger-pipeline.sh). It is
# idempotent and safe to re-run.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require_token

WHICH="${1:-both}"
GROUP="${RESOURCE_GROUP:-dhp-webroot}"
MODE="${PROCESS_MODE:-oldest_first}"

set_mode() {
  local pid="$1" label="$2" body code current
  body="$(api_soft GET "/projects/$pid/resource_groups/$(urlenc "$GROUP")")"
  code="$(api_code GET "/projects/$pid/resource_groups/$(urlenc "$GROUP")")"
  if [[ "$code" == "404" ]]; then
    echo "$label: no resource group '$GROUP' yet - it is created by the first pipeline that uses it; re-run this after one has run"
    return 0
  fi
  if [[ "$code" != "200" ]]; then
    echo "$label: GET resource group returned $code: $body" >&2
    return 1
  fi
  current="$(printf '%s' "$body" | jq -r '.process_mode // "?"')"
  if [[ "$current" == "$MODE" ]]; then
    echo "$label: '$GROUP' already $MODE"
    return 0
  fi
  echo "$label: '$GROUP' is $current, setting $MODE"
  api PUT "/projects/$pid/resource_groups/$(urlenc "$GROUP")" \
    --header 'Content-Type: application/json' \
    --data "$(jq -n --arg m "$MODE" '{process_mode: $m}')" \
    | jq -r '"  now: \(.process_mode)"'
}

case "$WHICH" in
  core)        set_mode "${CORE_PROJECT_ID:-1}" core ;;
  integration) set_mode "${INTEGRATION_PROJECT_ID:-2}" integration ;;
  both)
    set_mode "${CORE_PROJECT_ID:-1}" core
    set_mode "${INTEGRATION_PROJECT_ID:-2}" integration
    ;;
  *) echo "usage: 37-resource-group-mode.sh [core|integration|both]" >&2; exit 2 ;;
esac
