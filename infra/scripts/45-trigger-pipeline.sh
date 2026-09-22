#!/usr/bin/env bash
# Trigger a pipeline on a ref and wait for it to finish.
#
#   ./45-trigger-pipeline.sh core main
#   ./45-trigger-pipeline.sh integration 0.9.0
#   ./45-trigger-pipeline.sh core 0.9.2 nowait
#   ./45-trigger-pipeline.sh integration main nowait CI_BUILD_REPO_URL=https://github.com/uzinfocom-org/digital-health-integration
#
# Useful because the mirror projects are usually already up to date, so there is
# no push event to ride on.
#
# A real IG build takes 20-25 minutes and a release three times that, so the
# wait runs for up to POLL_LIMIT ticks of 30s (6 hours by default), matching the
# job timeouts in .gitlab-ci.yml. Pass `nowait` to return as soon as the
# pipeline exists.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

WHICH="${1:?usage: $0 <core|integration> <ref> [nowait]}"
REF="${2:?usage: $0 <core|integration> <ref> [nowait]}"
WAIT="${3:-wait}"
POLL_LIMIT="${POLL_LIMIT:-720}"   # 720 x 30s = 6h

case "$WHICH" in
  core)        PROJECT_PATH="$CORE_PROJECT_PATH" ;;
  integration) PROJECT_PATH="$INTEGRATION_PROJECT_PATH" ;;
  *) echo "unknown project '$WHICH'" >&2; exit 1 ;;
esac

ENC=$(urlenc "$PROJECT_PATH")

# Any KEY=VALUE arguments after the wait mode become CI/CD variables on this one
# pipeline, e.g. CI_BUILD_REPO_URL to override the repository cited in the
# publish box, or FAIL_ON_QA_ERRORS=1 to turn the QA gate on for this run (it is
# off by default - the GitHub side enforces the limits).
VAR_ARGS=()
VAR_NOTE=""
shift 3 2>/dev/null || shift $#
for kv in "$@"; do
  case "$kv" in
    *=*) VAR_ARGS+=(--form "variables[][key]=${kv%%=*}" --form "variables[][value]=${kv#*=}")
         VAR_NOTE="$VAR_NOTE $kv" ;;
    *) echo "ignoring '$kv': expected KEY=VALUE" >&2 ;;
  esac
done

echo "triggering pipeline on ${PROJECT_PATH} @ ${REF}${VAR_NOTE:+ with$VAR_NOTE}"
RESP=$(api_soft POST "/projects/${ENC}/pipeline" --form "ref=${REF}" "${VAR_ARGS[@]+"${VAR_ARGS[@]}"}")

PID=$(python3 -c '
import sys, json
d = json.load(sys.stdin)
print(d.get("id", ""))' <<<"$RESP")

if [[ -z "$PID" ]]; then
  echo "pipeline was NOT created:"
  python3 -c '
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d, indent=2)[:3000])' <<<"$RESP"
  exit 1
fi

echo "pipeline #$PID created: ${GL}/${PROJECT_PATH}/-/pipelines/${PID}"
[[ "$WAIT" == "nowait" ]] && exit 0

for i in $(seq 1 "$POLL_LIMIT"); do
  OUT=$(api_soft GET "/projects/${ENC}/pipelines/${PID}")
  ST=$(python3 -c '
import sys, json
print(json.load(sys.stdin).get("status", "unknown"))' <<<"$OUT")
  case "$ST" in
    success|failed|canceled|skipped)
      DUR=$(python3 -c '
import sys, json
print(json.load(sys.stdin).get("duration") or 0)' <<<"$OUT")
      echo "pipeline #$PID -> $ST after ${DUR}s"
      echo "jobs:"
      api_soft GET "/projects/${ENC}/pipelines/${PID}/jobs" | python3 -c '
import sys, json
for j in json.load(sys.stdin):
    print("  %-22s %-10s %s" % (j["name"], j["status"], j.get("stage")))'
      [[ "$ST" == "success" ]] && exit 0 || exit 1
      ;;
  esac
  sleep 30
done

echo "timed out waiting for pipeline #$PID (last status: $ST)"
exit 1
