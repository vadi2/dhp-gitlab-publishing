#!/usr/bin/env bash
# Apply the project-level settings the GitLab QA review asked for
# (qa/gitlab/FINDINGS.md F-01, F-03, F-05, F-06, F-11, F-14, F-21) to both
# mirror projects. Idempotent: re-running it reports "already" and changes
# nothing.
#
#   38-harden-projects.sh            apply everything
#   38-harden-projects.sh show       print the current state, change nothing
#
# Per project:
#
#   ci_config_path = .gitlab-ci.yml@<this project>:ci        F-01, F-21
#       Without it GitLab reads .gitlab-ci.yml out of the pushed ref, so any
#       mirrored branch can define its own jobs and run them as root on the
#       runner with the web root mounted rw. With it the repo's own file is
#       ignored and only the `ci` branch defines the pipeline.
#
#   public_jobs = false                                      F-14
#       Job traces and QA artifacts stop being readable by every signed-in
#       user on an internal project.
#
#   ci_pipeline_variables_minimum_override_role = owner      F-06
#       FAIL_ON_QA_ERRORS=0 (and SKIP_DEPLOY, WEB_ROOT, PUB_MODE ...) can no
#       longer be passed by a Developer starting a pipeline.
#
#   protected tag '*', create_access_level 40 (Maintainer)   F-03, F-11
#       Stops Developers creating an X.Y.Z tag, which is all it takes to
#       publish. 40 and not 0: the pull mirror evaluates the rule as the
#       mirror user, and a rule it does not satisfy makes GitLab DELETE the
#       matching tags and hard-fail the mirror (F-11). Verify after applying
#       that GET /projects/:id/mirror/pull still reports last_error null.
#
#   protected branch 'main'                                  F-05
#       push level is MAIN_PUSH_ACCESS_LEVEL, default 40 (Maintainer), merge
#       MAIN_MERGE_ACCESS_LEVEL, default 40. "No one" (0) is what F-05 asked
#       for; see the note below and the F-05 entry in qa/gitlab/RESOLUTION.md
#       for why the default is not 0.
#
#   external_webhook_token                                   F-13
#       A per-project shared secret that lets POST /projects/:id/mirror/pull be
#       called with an HMAC-signed GitHub payload instead of a
#       Maintainer-or-above API token. Without it the only way to give GitHub a
#       webhook is to hand it a token that can also read and write the
#       repository. There is no REST setter for this column, so it goes in
#       through gitlab-rails. The value is read from infra/.env as
#       GITHUB_WEBHOOK_SECRET_<project id> (you generate it, e.g.
#       `openssl rand -hex 16`; when absent this step is skipped and the
#       command to add it is printed) and never printed: not by this script,
#       not into the process list (it reaches the container over a pipe, not
#       as an argument), and not into the shell history.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_token

# 0 = "No one", 40 = Maintainer, 30 = Developer.
#
# 0 locks a human out of main in GitLab, which is what F-05 wanted, but the
# pull mirror fast-forwards main as the mirror user and the protected-branch
# push check has no mirror exemption: ProtectedRefAccess#check_access returns
# false for access_level 0 before it looks at who is asking, admin included.
# So with 0 the first real upstream commit to main raises UpdateError, and with
# the ticker forcing a retry every 30-45s the mirror hard-fails in about ten
# minutes (F-02) and nothing recovers it. Measured, not assumed - see
# RESOLUTION.md F-05.
MAIN_PUSH_ACCESS_LEVEL="${MAIN_PUSH_ACCESS_LEVEL:-40}"
MAIN_MERGE_ACCESS_LEVEL="${MAIN_MERGE_ACCESS_LEVEL:-40}"

PROJECT_IDS=("$CORE_PROJECT_ID" "$INTEGRATION_PROJECT_ID")

MODE="${1:-apply}"
case "$MODE" in
  apply|show) ;;
  *) echo "usage: $0 [apply|show]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- helpers ----

# jget <python expression over `d`>, JSON on stdin
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

project_path() { api GET "/projects/$1" | jget 'd["path_with_namespace"]'; }

show_project() {
  local id="$1"
  echo "== project $id ($(project_path "$id"))"
  api GET "/projects/$id" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in ("ci_config_path", "public_jobs",
          "ci_pipeline_variables_minimum_override_role",
          "restrict_user_defined_variables"):
    print("   %-44s= %r" % (k, d.get(k)))'
  echo "   protected tags:"
  api GET "/projects/$id/protected_tags" | python3 -c '
import sys, json
for t in json.load(sys.stdin):
    print("     %-8s create=%s" % (t["name"],
          [a["access_level"] for a in t.get("create_access_levels", [])]))'
  echo "   protected branches:"
  api GET "/projects/$id/protected_branches" | python3 -c '
import sys, json
for b in json.load(sys.stdin):
    print("     %-8s push=%s merge=%s force_push=%s" % (b["name"],
          [a["access_level"] for a in b.get("push_access_levels", [])],
          [a["access_level"] for a in b.get("merge_access_levels", [])],
          b.get("allow_force_push")))'
  # Presence only - the value is a shared secret and is never printed.
  if [[ "${SHOW_WEBHOOK_TOKEN:-1}" == "1" ]]; then
    local key="GITHUB_WEBHOOK_SECRET_${id}" have=absent
    [[ -n "${!key:-}" ]] && have=present
    printf '   %-44s= %s in GitLab, %s in .env (%s)\n' \
      "external_webhook_token" "$(webhook_token_state "$id")" "$have" "$key"
  fi
}

# ------------------------------------------------------- project settings ----

apply_settings() {
  local id="$1" path="$2"
  local want_ci_path=".gitlab-ci.yml@${path}:ci"

  local cur cur_ci cur_pub cur_role
  cur=$(api GET "/projects/$id")
  cur_ci=$(jget 'd.get("ci_config_path") or ""' <<<"$cur")
  cur_pub=$(jget 'str(d.get("public_jobs")).lower()' <<<"$cur")
  cur_role=$(jget 'd.get("ci_pipeline_variables_minimum_override_role") or ""' <<<"$cur")

  if [[ "$cur_ci" == "$want_ci_path" && "$cur_pub" == "false" && "$cur_role" == "owner" ]]; then
    echo "   settings: already ci_config_path / public_jobs / override_role"
    return 0
  fi

  api PUT "/projects/$id" \
    --form "ci_config_path=${want_ci_path}" \
    --form "public_jobs=false" \
    --form "ci_pipeline_variables_minimum_override_role=owner" >/dev/null
  echo "   settings: ci_config_path=${want_ci_path}, public_jobs=false, override_role=owner"
}

# ---------------------------------------------------------- protected tag ----

apply_protected_tag() {
  local id="$1" code levels
  code=$(api_code GET "/projects/$id/protected_tags/%2A")

  if [[ "$code" == "200" ]]; then
    levels=$(api GET "/projects/$id/protected_tags/%2A" \
             | jget '",".join(str(a["access_level"]) for a in d.get("create_access_levels", []))')
    if [[ "$levels" == "40" ]]; then
      echo "   protected tag '*': already create=Maintainer(40)"
      return 0
    fi
    echo "   protected tag '*': create=${levels}, replacing with 40"
    api DELETE "/projects/$id/protected_tags/%2A" >/dev/null
  fi

  api POST "/projects/$id/protected_tags" \
    --form 'name=*' --form 'create_access_level=40' >/dev/null
  echo "   protected tag '*': create=Maintainer(40)"
}

# ------------------------------------------------------- protected branch ----

apply_protected_main() {
  local id="$1" code cur body
  code=$(api_code GET "/projects/$id/protected_branches/main")
  if [[ "$code" != "200" ]]; then
    api POST "/projects/$id/protected_branches" \
      --form "name=main" \
      --form "push_access_level=${MAIN_PUSH_ACCESS_LEVEL}" \
      --form "merge_access_level=${MAIN_MERGE_ACCESS_LEVEL}" \
      --form "allow_force_push=false" >/dev/null
    echo "   protected branch 'main': created push=${MAIN_PUSH_ACCESS_LEVEL} merge=${MAIN_MERGE_ACCESS_LEVEL}"
    return 0
  fi

  cur=$(api GET "/projects/$id/protected_branches/main")
  # PATCH takes allowed_to_push / allowed_to_merge as arrays of objects; an
  # existing role entry is replaced by destroying it by id and adding the new
  # level in the same call, so main is never left unprotected.
  body=$(PUSH="$MAIN_PUSH_ACCESS_LEVEL" MERGE="$MAIN_MERGE_ACCESS_LEVEL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
want = {"push": int(os.environ["PUSH"]), "merge": int(os.environ["MERGE"])}
out = {}
for kind, key in (("push", "push_access_levels"), ("merge", "merge_access_levels")):
    have = d.get(key) or []
    if len(have) == 1 and have[0].get("access_level") == want[kind] \
       and not have[0].get("user_id") and not have[0].get("group_id") \
       and not have[0].get("deploy_key_id"):
        continue
    entries = [{"id": a["id"], "_destroy": True} for a in have]
    entries.append({"access_level": want[kind]})
    out["allowed_to_%s" % kind] = entries
print(json.dumps(out))' <<<"$cur")

  if [[ "$body" == "{}" ]]; then
    echo "   protected branch 'main': already push=${MAIN_PUSH_ACCESS_LEVEL} merge=${MAIN_MERGE_ACCESS_LEVEL}"
    return 0
  fi

  api PATCH "/projects/$id/protected_branches/main" \
    --header "Content-Type: application/json" --data "$body" >/dev/null
  echo "   protected branch 'main': push=${MAIN_PUSH_ACCESS_LEVEL} merge=${MAIN_MERGE_ACCESS_LEVEL}"
}

# ------------------------------------------------------ webhook secret ------

GITLAB_CONTAINER="${GITLAB_CONTAINER:-dhp-gl-gitlab}"

# This script does not generate or store the secret. It takes
# GITHUB_WEBHOOK_SECRET_<project id> from the environment (infra/.env is
# already sourced by lib.sh) and installs it in GitLab. Adding the line is a
# deliberate act by whoever runs this, not a side effect of a hardening script,
# and it keeps the value out of anything this file writes.
#
# The value reaches the container on stdin, not as an argument: `sh -c 'read'`
# consumes the single line we pipe in and exports it, so the secret appears in
# no argv and `ps` shows nothing, inside the container or out.
rails_with_secret() {   # rails_with_secret <ruby source>; secret on stdin
  docker exec -i "$GITLAB_CONTAINER" sh -c \
    'read -r __tok; DHP_WEBHOOK_SECRET="$__tok" gitlab-rails runner "$1"' \
    sh "$1"
}

webhook_token_state() {  # prints set / unset; never the value
  local id="$1"
  docker exec "$GITLAB_CONTAINER" gitlab-rails runner \
    "p = Project.find_by_id(${id}); \
     puts p.nil? ? 'no-such-project' : (p.external_webhook_token.present? ? 'set' : 'unset')" \
    2>/dev/null | tr -d '\r' | tail -1
}

apply_webhook_token() {
  local id="$1" secret state
  local key="GITHUB_WEBHOOK_SECRET_${id}"

  secret="${!key:-}"
  if [[ -z "$secret" ]]; then
    echo "   external_webhook_token: skipped, ${key} is not set."
    echo "     To enable the HMAC webhook route for this project, generate a"
    echo "     secret and add it to $ENV_FILE yourself, then re-run:"
    echo "       printf '%s=%s\\n' ${key} \"\$(openssl rand -hex 16)\" >> $ENV_FILE"
    echo "     Nothing else in the pipeline depends on it; see NOTES.md (F-13)."
    return 0
  fi

  # Both halves have to agree - GitLab verifies the signature against its copy,
  # the caller signs with ours - so an already-set token is replaced with the
  # one in .env rather than left alone.
  state=$(webhook_token_state "$id")
  if [[ "$state" == "no-such-project" ]]; then
    echo "   external_webhook_token: project $id not found by gitlab-rails" >&2
    return 1
  fi

  if printf '%s\n' "$secret" | rails_with_secret \
      "p = Project.find(${id}); \
       p.update_column(:external_webhook_token, ENV.fetch('DHP_WEBHOOK_SECRET')); \
       puts 'ok'" | grep -q '^ok$'; then
    echo "   external_webhook_token: installed from ${key} (was ${state})"
  else
    echo "   external_webhook_token: FAILED - is ${GITLAB_CONTAINER} running?" >&2
    return 1
  fi
}

# ------------------------------------------------------------------- main ----

if [[ "$MODE" == "show" ]]; then
  for id in "${PROJECT_IDS[@]}"; do show_project "$id"; done
  exit 0
fi

for id in "${PROJECT_IDS[@]}"; do
  path=$(project_path "$id")
  echo "== project $id ($path)"
  apply_settings "$id" "$path"
  apply_protected_tag "$id"
  apply_protected_main "$id"
  apply_webhook_token "$id"
done

echo
echo "done. Now confirm the pull mirror is still healthy on both projects:"
echo "  ./60-mirror-ticker.sh health"
echo "A protected tag rule the mirror user does not satisfy deletes the matching"
echo "tags and hard-fails the mirror (F-11), so do not skip that check."
