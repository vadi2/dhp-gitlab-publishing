#!/usr/bin/env bash
# Force a pull-mirror update of both projects, and check that mirroring works.
#
#   60-mirror-ticker.sh setup     create the two project access tokens (into
#                                 infra/.env) and print the cron line to install
#   60-mirror-ticker.sh once      one forced pull of both projects - this is
#                                 what cron runs
#   60-mirror-ticker.sh status    last mirror update per project
#   60-mirror-ticker.sh health    mirror + token health, exit 1 if anything is
#                                 wrong. This is the thing to put in a monitor.
#
# Why this exists: GitLab's native pull-mirror interval has a hard floor of 30
# minutes (Gitlab::Mirror::MIN_DELAY, a constant, not a setting). The only way
# to get closer to real time is to call the pull endpoint yourself. That call
# is rate limited by the plan limit pull_mirror_interval_seconds, which is 300
# by default and can be lowered from the rails console:
#
#   gitlab-rails runner \
#     'Plan.default.actual_limits.update!(pull_mirror_interval_seconds: 30)'
#
# force=true matters: without it the endpoint answers 403 forever once the
# mirror has hard-failed (14 consecutive failures), and a hard failure is
# silent unless outgoing mail is on. force=true resets the retry count.
#
# Token: a PROJECT access token per project with the api scope and Maintainer
# role, not the instance-wide root PAT. It can touch only its own project.
# `api` is the narrowest scope that works and Maintainer is the floor - a
# Developer-level token gets 403 on mirror/pull. Nothing here prints a token.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# How stale last_successful_update_at may get before `health` fails.
STALE_SECONDS="${MIRROR_STALE_SECONDS:-600}"
# Warn this many days before a token expires.
EXPIRY_WARN_DAYS="${MIRROR_EXPIRY_WARN_DAYS:-14}"
TOKEN_NAME="dhp-mirror-tick"

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

pull_once() {
  local project_id="$1" token="$2" label="$3"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
          --header "PRIVATE-TOKEN: $token" \
          "$API/projects/$project_id/mirror/pull?force=true")"
  printf '%-12s POST mirror/pull?force=true -> HTTP %s\n' "$label" "$code"
  [[ "$code" == "200" ]]
}

require_mirror_tokens() {
  [[ -n "${CORE_MIRROR_TOKEN:-}" && -n "${INTEGRATION_MIRROR_TOKEN:-}" ]] || {
    echo "no mirror tokens in $ENV_FILE - run: $0 setup" >&2
    exit 1
  }
}

case "${1:-status}" in

setup)
  require_token
  ensure_token "$CORE_PROJECT_ID" CORE_MIRROR_TOKEN
  ensure_token "$INTEGRATION_PROJECT_ID" INTEGRATION_MIRROR_TOKEN
  cat <<EOF

Tokens are in $ENV_FILE. Install this in the crontab of the user that owns it
(crontab -e); one forced pull per minute is the useful floor, since the plan
limit rejects anything faster than pull_mirror_interval_seconds:

  * * * * * $HERE/60-mirror-ticker.sh once >/dev/null 2>&1

and put \`$HERE/60-mirror-ticker.sh health\` in whatever monitors this host.
EOF
  ;;

once)
  require_mirror_tokens
  rc=0
  pull_once "$CORE_PROJECT_ID" "$CORE_MIRROR_TOKEN" core || rc=1
  pull_once "$INTEGRATION_PROJECT_ID" "$INTEGRATION_MIRROR_TOKEN" integration || rc=1
  exit $rc
  ;;

status)
  require_token
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

  # Mirror: last_error and a stalling last_successful_update_at are the two
  # things that actually matter. A hard-failed mirror answers 403 to forced
  # pulls and a paused one answers 200, so the cron job's exit code alone is
  # not enough.
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

  # Token expiry: the failure nobody notices. When these expire the cron job
  # gets HTTP 401 forever and mirroring silently drops to GitLab's 30-minute
  # cadence, so the site keeps updating and is just an hour late.
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
        print("WARNING %s: token expires in %d days (%s) - revoke it and run "
              "`60-mirror-ticker.sh setup` for a new one" % (label, days, exp), file=sys.stderr)
sys.exit(rc)'; then
      rc=1
    fi
  done

  if (( rc )); then echo "MIRROR HEALTH: PROBLEMS above"; else echo "MIRROR HEALTH: ok"; fi
  exit $rc
  ;;

*)
  echo "usage: $0 [setup|once|status|health]" >&2
  exit 2
  ;;
esac
