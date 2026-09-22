#!/usr/bin/env bash
# Common helpers for the DHP GitLab demo scripts. Source, do not execute.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="$(cd "$INFRA_DIR/.." && pwd)"
ENV_FILE="$INFRA_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

GL="${GITLAB_EXTERNAL_URL}"
API="${GL}/api/v4"

# Write/replace a KEY=value line in .env (values may contain / and &).
env_set() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(True)
out = []
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={val}\n")
    else:
        out.append(line)
open(path, "w").write("".join(out))
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
  export "${key}=${val}"
}

# Authenticated API call: api GET /projects
api() {
  local method="$1" path="$2"; shift 2
  curl -sS --fail-with-body -X "$method" \
    --header "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
    "$@" "${API}${path}"
}

# Same but never fails the script - caller inspects the body.
api_soft() {
  local method="$1" path="$2"; shift 2
  curl -sS -X "$method" \
    --header "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
    "$@" "${API}${path}"
}

# Just the HTTP status, for existence checks.
api_code() {
  local method="$1" path="$2"; shift 2
  curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
    --header "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
    "$@" "${API}${path}"
}

urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

require_token() {
  if [[ -z "${GITLAB_ROOT_TOKEN:-}" ]]; then
    echo "GITLAB_ROOT_TOKEN is empty in $ENV_FILE - run scripts/10-create-root-pat.sh first" >&2
    exit 1
  fi
}

# Readiness: the sign-in page answering 200 means puma + workhorse + nginx are
# all up. /-/health is NOT used here because it is restricted to
# gitlab_rails['monitoring_whitelist'] and 404s for everyone else.
wait_for_gitlab() {
  echo "waiting for GitLab at ${GL} ..."
  local i=0
  until [[ "$(curl -sS -o /dev/null -w '%{http_code}' "${GL}/users/sign_in" 2>/dev/null)" == "200" ]]; do
    i=$((i+1))
    if (( i > 120 )); then echo "GitLab did not become ready in 20 min" >&2; exit 1; fi
    sleep 10
  done
  echo "GitLab is up."
}
