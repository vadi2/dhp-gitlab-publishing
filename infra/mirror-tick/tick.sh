#!/bin/sh
# The mirror ticker loop. Runs inside the dhp-gl-mirror-tick container, mounted
# read-only; the lifecycle is infra/scripts/60-mirror-ticker.sh and the service
# definition is in infra/docker-compose.yml.
#
# It forces a pull-mirror update of every project listed in TOKEN_FILE, every
# INTERVAL seconds. Three things matter here and each is a QA finding:
#
#   force=true                              F-02
#       Without it StartPullMirroringService is called with
#       pause_on_hard_failure: true and answers 403 forever once the mirror has
#       hard failed (14 consecutive failures, which at this cadence is about
#       ten minutes of GitHub being unreachable). force=true resets the retry
#       count, so a blip no longer stops mirroring permanently.
#
#   the status code is tested                F-02
#       A non-200 goes to stderr and writes UNHEALTHY_FILE, which the compose
#       healthcheck reads, so `docker inspect` and 50-verify.sh can see it. The
#       old loop printed the code into a log nobody reads.
#
#   tokens come from a mounted file          F-12
#       Not from the container environment, where
#       `docker inspect --format '{{json .Config.Env}}'` hands them to anyone
#       in the docker group. The file is re-read every tick, so rotating a
#       token does not need the container recreated.
#
# TOKEN_FILE format, one project per line, "<project id> <token>":
#
#   1 glpat-xxxxxxxxxxxxxxxxxxxx
#   2 glpat-yyyyyyyyyyyyyyyyyyyy
#
# Blank lines and # comments are ignored. Nothing here ever prints a token.

set -u

API="${API:?API is required, e.g. https://<gitlab>/api/v4}"
INTERVAL="${INTERVAL:-15}"
TOKEN_FILE="${TOKEN_FILE:-/run/secrets/mirror-tokens}"
UNHEALTHY_FILE="${UNHEALTHY_FILE:-/tmp/mirror-tick-unhealthy}"

if [ ! -r "$TOKEN_FILE" ]; then
  echo "mirror-tick: cannot read $TOKEN_FILE" >&2
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) token file $TOKEN_FILE unreadable" > "$UNHEALTHY_FILE"
  # Stay up rather than crash-looping: the file is a bind mount and may appear.
  while [ ! -r "$TOKEN_FILE" ]; do sleep "$INTERVAL"; done
  rm -f "$UNHEALTHY_FILE"
fi

echo "mirror-tick: forcing a pull every ${INTERVAL}s, projects from $TOKEN_FILE"

while true; do
  trouble=""

  while IFS=' ' read -r id tok _rest; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -n "$tok" ] || { trouble="${trouble}project ${id}: no token; "; continue; }

    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
           --header "PRIVATE-TOKEN: $tok" \
           "$API/projects/$id/mirror/pull?force=true" 2>/dev/null)

    if [ "$code" = "200" ]; then
      echo "$(date -u +%H:%M:%S) project $id -> HTTP $code"
    else
      echo "$(date -u +%H:%M:%S) project $id -> HTTP $code (forced pull FAILED)" >&2
      trouble="${trouble}project ${id}: HTTP ${code}; "
    fi
  done < "$TOKEN_FILE"

  if [ -n "$trouble" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $trouble" > "$UNHEALTHY_FILE"
  else
    rm -f "$UNHEALTHY_FILE"
  fi

  sleep "$INTERVAL"
done
