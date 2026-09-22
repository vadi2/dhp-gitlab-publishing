#!/usr/bin/env bash
# Force a pull-mirror update of both projects every minute.
#
#   60-mirror-ticker.sh start     create tokens if needed, write the token file,
#                                 bring up the compose service
#   60-mirror-ticker.sh stop      stop and remove the compose service
#   60-mirror-ticker.sh status    container state, last mirror update per project
#   60-mirror-ticker.sh once      one forced pull of both projects, from the host
#   60-mirror-ticker.sh health    mirror + token health, exit 1 if anything is
#                                 wrong. This is the thing to put in a monitor.
#   60-mirror-ticker.sh logs      tail the ticker's own log
#
# Why this exists: GitLab's native pull-mirror interval has a hard floor of 30
# minutes (Gitlab::Mirror::MIN_DELAY, a constant, not a setting). The only way
# to get closer to real time is to call the pull endpoint yourself. That call
# is rate limited by the plan limit pull_mirror_interval_seconds, which is 300
# by default and was lowered to 30 on this instance:
#
#   docker exec dhp-gl-gitlab gitlab-rails runner \
#     'Plan.default.actual_limits.update!(pull_mirror_interval_seconds: 30)'
#
# Lifecycle: the ticker is service `mirror-tick` in infra/docker-compose.yml
# with `restart: unless-stopped`, so the docker daemon brings it back after a
# reboot and `docker compose up -d` brings it up with the rest of the stack. It
# used to be a bare `docker run` from this script, which is why `docker compose
# up` silently left mirroring at the native 30-minute cadence (F-18).
#
# `start` and `stop` here act on that one service with --no-deps, so they never
# recreate GitLab, the runner or nginx.
#
# Token: a PROJECT access token per project with the api scope and Maintainer
# role, not the instance-wide root PAT. It can touch only its own project.
# `api` really is the narrowest thing that works, and Maintainer really is the
# floor - both measured, see qa/gitlab/RESOLUTION.md F-12. The tokens reach the
# container through a mounted file, not the environment, so
# `docker inspect dhp-gl-mirror-tick` no longer hands them out.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

CONTAINER="dhp-gl-mirror-tick"
SERVICE="mirror-tick"
# Mounted read-only into the container as /run/secrets/mirror-tokens. Mode 600,
# gitignored. One "<project id> <token>" per line.
TOKEN_FILE="$INFRA_DIR/.mirror-tokens"
# Tick FASTER than the rate limit, not at it. The plan limit
# pull_mirror_interval_seconds rejects a forced pull that arrives sooner than
# that after the last successful one - silently, still HTTP 200. A ticker at
# exactly the limit keeps landing just inside the window, so roughly every
# other call is dropped.
#
# The achievable cadence is the limit, plus how long a pull takes (10-20s on
# this box while an IG build has the CPU), plus up to one tick interval. With
# the limit at 30 and a 15s tick that lands near a minute; with the limit at 60
# and a 30s tick it was 1m45s-2m05s.
INTERVAL="${MIRROR_TICK_INTERVAL:-15}"
RATE_LIMIT="${MIRROR_RATE_LIMIT:-30}"
# How stale last_successful_update_at may get before `health` fails.
STALE_SECONDS="${MIRROR_STALE_SECONDS:-600}"
# Warn this many days before a ticker token expires.
EXPIRY_WARN_DAYS="${MIRROR_EXPIRY_WARN_DAYS:-14}"
TOKEN_NAME="dhp-mirror-tick"

compose() { (cd "$INFRA_DIR" && docker compose "$@"); }

# Create a project access token unless .env already carries a working one.
ensure_token() {
  local project_id="$1" var="$2"
  local current="${!var:-}"

  if [[ -n "$current" ]]; then
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
            --header "PRIVATE-TOKEN: $current" \
            "$API/projects/$project_id")"
    if [[ "$code" == "200" ]]; then
      echo "$var: existing token works"
      return 0
    fi
    echo "$var: existing token returns $code, creating a new one"
  fi

  local body
  body="$(api POST "/projects/$project_id/access_tokens" \
          --header "Content-Type: application/json" \
          --data "$(python3 -c '
import json, sys, datetime
print(json.dumps({
  "name": "dhp-mirror-tick",
  "scopes": ["api"],
  "access_level": 40,
  "expires_at": (datetime.date.today() + datetime.timedelta(days=90)).isoformat(),
}))')")"

  local token
  token="$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"
  env_set "$var" "$token"
  echo "$var: created a project access token (api scope, Maintainer, 90 days)"
}

# Render .env's token values into the file the container mounts. Never printed.
write_token_file() {
  local tmp
  # A `docker compose up` that reaches this service before the file exists
  # creates the bind-mount source as an empty DIRECTORY. Clear that away, or
  # the mv below would move the temp file inside it and the container would
  # mount a directory where it expects a file.
  if [[ -d "$TOKEN_FILE" ]]; then
    rmdir "$TOKEN_FILE" 2>/dev/null || {
      echo "$TOKEN_FILE is a non-empty directory - remove it by hand" >&2
      return 1
    }
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/mirror-tokens.XXXXXX")"
  chmod 600 "$tmp"
  {
    echo "# Written by 60-mirror-ticker.sh. Mounted read-only into"
    echo "# $CONTAINER as /run/secrets/mirror-tokens. Never commit this."
    printf '%s %s\n' "$CORE_PROJECT_ID" "$CORE_MIRROR_TOKEN"
    printf '%s %s\n' "$INTEGRATION_PROJECT_ID" "$INTEGRATION_MIRROR_TOKEN"
  } > "$tmp"
  mv "$tmp" "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "token file: $TOKEN_FILE (mode 600, $(grep -cv '^#' "$TOKEN_FILE") projects)"
}

pull_once() {
  local project_id="$1" token="$2" label="$3"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
          --header "PRIVATE-TOKEN: $token" \
          "$API/projects/$project_id/mirror/pull?force=true")"
  printf '%-12s POST mirror/pull?force=true -> HTTP %s\n' "$label" "$code"
  [[ "$code" == "200" ]]
}

case "${1:-status}" in

start)
  require_token
  ensure_token "$CORE_PROJECT_ID" CORE_MIRROR_TOKEN
  ensure_token "$INTEGRATION_PROJECT_ID" INTEGRATION_MIRROR_TOKEN
  write_token_file

  # The pre-compose ticker was a bare `docker run --name dhp-gl-mirror-tick`.
  # Compose will not adopt a container it did not create, it just fails with
  # "container name is already in use", so say what to do about it.
  if docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' \
       "$CONTAINER" 2>/dev/null | grep -qv "^${SERVICE}$"; then
    echo "$CONTAINER exists but is not managed by compose (it predates the"
    echo "compose service). Remove it first, then run start again:"
    echo "  docker rm -f $CONTAINER"
    exit 1
  fi

  # --no-deps: `depends_on: gitlab` would otherwise recreate GitLab, which is
  # never what you want on a running instance.
  # The container runs as the user who owns the mode-600 token file (us).
  MIRROR_TICK_USER="$(id -u):$(id -g)" compose up -d --no-deps "$SERVICE"
  echo "ticker $CONTAINER started, every ${INTERVAL}s (plan limit: one pull per ${RATE_LIMIT}s)"
  ;;

stop)
  compose rm -sf "$SERVICE" >/dev/null 2>&1 && echo "ticker stopped" || echo "ticker was not running"
  ;;

once)
  require_token
  ensure_token "$CORE_PROJECT_ID" CORE_MIRROR_TOKEN
  ensure_token "$INTEGRATION_PROJECT_ID" INTEGRATION_MIRROR_TOKEN
  rc=0
  pull_once "$CORE_PROJECT_ID" "$CORE_MIRROR_TOKEN" core || rc=1
  pull_once "$INTEGRATION_PROJECT_ID" "$INTEGRATION_MIRROR_TOKEN" integration || rc=1
  exit $rc
  ;;

logs)
  docker logs --tail "${2:-40}" "$CONTAINER"
  ;;

status)
  require_token
  docker ps -a --filter "name=$CONTAINER" --format '{{.Names}} {{.Status}}' || true
  for pair in "$CORE_PROJECT_ID:core" "$INTEGRATION_PROJECT_ID:integration"; do
    id="${pair%%:*}"; label="${pair#*:}"
    api GET "/projects/$id/mirror/pull" \
      | python3 -c "import sys,json
d=json.load(sys.stdin)
print('%-12s status=%s last=%s next=%s err=%s' % ('$label',
      d.get('update_status'), d.get('last_update_at'),
      d.get('next_execution_timestamp'), d.get('last_error')))"
  done
  ;;

health)
  require_token
  rc=0

  # Container: running, and not flagged unhealthy by the loop. The compose
  # healthcheck tests for /tmp/mirror-tick-unhealthy inside the container.
  state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo absent)"
  hstate="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$CONTAINER" 2>/dev/null || echo none)"
  printf 'ticker       container=%s health=%s\n' "$state" "$hstate"
  if [[ "$state" != "running" ]]; then
    echo "ERROR ticker container is $state" >&2
    rc=1
  elif [[ "$hstate" == "unhealthy" ]]; then
    echo "ERROR ticker reports unhealthy:" >&2
    docker exec "$CONTAINER" cat /tmp/mirror-tick-unhealthy >&2 2>/dev/null || true
    rc=1
  fi

  # Mirror: last_error and a stalling last_successful_update_at are the two
  # things that actually matter. Watching the ticker's own log is not enough -
  # a hard-failed mirror answers 403 and a paused one answers 200 (F-02).
  for pair in "$CORE_PROJECT_ID:core" "$INTEGRATION_PROJECT_ID:integration"; do
    id="${pair%%:*}"; label="${pair#*:}"
    if ! api GET "/projects/$id/mirror/pull" \
         | STALE="$STALE_SECONDS" LABEL="$label" python3 -c '
import datetime, json, os, sys
d = json.load(sys.stdin)
label = os.environ["LABEL"]
stale = int(os.environ["STALE"])
err = d.get("last_error")
ok = d.get("last_successful_update_at")
age = None
if ok:
    t = datetime.datetime.fromisoformat(ok.replace("Z", "+00:00"))
    age = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds())
print("%-12s update_status=%s last_successful_update_at=%s (%s) last_error=%s"
      % (label, d.get("update_status"), ok,
         "%ds ago" % age if age is not None else "never", err))
bad = []
if err:
    bad.append("last_error is set")
if age is None:
    bad.append("never updated successfully")
elif age > stale:
    bad.append("last success %ds ago, limit %ds" % (age, stale))
for b in bad:
    print("ERROR %s: %s" % (label, b), file=sys.stderr)
sys.exit(1 if bad else 0)'; then
      rc=1
    fi
  done

  # Token expiry: the failure nobody notices. When these expire the ticker gets
  # HTTP 401 forever and mirroring silently drops to GitLab's 30-minute
  # cadence, so the site keeps updating and is just an hour late (F-12).
  for pair in "$CORE_PROJECT_ID:core" "$INTEGRATION_PROJECT_ID:integration"; do
    id="${pair%%:*}"; label="${pair#*:}"
    if ! api GET "/projects/$id/access_tokens" \
         | WARN="$EXPIRY_WARN_DAYS" LABEL="$label" NAME="$TOKEN_NAME" python3 -c '
import datetime, json, os, sys
tokens = json.load(sys.stdin)
label, name = os.environ["LABEL"], os.environ["NAME"]
warn = int(os.environ["WARN"])
live = [t for t in tokens if t.get("name") == name and t.get("active")]
if not live:
    print("%-12s token %s: NOT FOUND or revoked" % (label, name))
    print("ERROR %s: no active %s token" % (label, name), file=sys.stderr)
    sys.exit(1)
rc = 0
for t in live:
    exp = t.get("expires_at")
    if not exp:
        print("%-12s token id=%s expires_at=never" % (label, t["id"]))
        continue
    days = (datetime.date.fromisoformat(exp) - datetime.date.today()).days
    print("%-12s token id=%s expires_at=%s (%d days)" % (label, t["id"], exp, days))
    if days < 0:
        print("ERROR %s: token expired %s" % (label, exp), file=sys.stderr)
        rc = 1
    elif days <= warn:
        print("WARNING %s: token expires in %d days (%s) - rotate it with "
              "`60-mirror-ticker.sh start` after revoking the old one"
              % (label, days, exp), file=sys.stderr)
sys.exit(rc)'; then
      rc=1
    fi
  done

  if (( rc )); then echo "MIRROR HEALTH: PROBLEMS above"; else echo "MIRROR HEALTH: ok"; fi
  exit $rc
  ;;

*)
  echo "usage: $0 [start|stop|once|status|health|logs]" >&2
  exit 2
  ;;
esac
