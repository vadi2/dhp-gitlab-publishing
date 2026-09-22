#!/usr/bin/env bash
# Publish a tagged release of a DHP IG to the web root, HL7 style.
#
#   release.sh [<version>]
#
# Version defaults to $CI_COMMIT_TAG. It must equal the version in
# sushi-config.yaml and the version of the built package, the same two checks
# the GitHub release workflow makes.
#
# What it does:
#   1. refuses if that version is already published (package-list.json entry or
#      an existing version folder in the web root)
#   2. builds the IG with ./_genonce.sh - -go-publish requires output/qa.json
#      and output/package.tgz to be present before it will start
#   3. writes publication-request.json if the repo does not carry one
#   4. runs `publisher.jar -go-publish`, which rebuilds the IG twice more (once
#      for the version folder, once for the canonical/milestone copy), updates
#      package-list.json, history.html, the publish box on every previously
#      published page, the redirects, the RSS feeds, package-registry.json and
#      the local ig-registry clone, then copies the result into the web root
#
# By hand, from a checkout of the tag:
#   DHP_DATA=/srv/dhp ci/release.sh 0.9.1
#
# GitLab CI runs it the same way, with IG_SRC=$CI_PROJECT_DIR and the version
# taken from $CI_COMMIT_TAG.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

VERSION="${1:-${CI_COMMIT_TAG:-}}"
[ -n "$VERSION" ] || die "usage: release.sh <version>   (or set CI_COMMIT_TAG)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not MAJOR.MINOR.PATCH"


load_ig_config
require_web_root
lock_web_root

# ------------------------------------------------------------------- checks

[ "$VERSION" = "$IG_VERSION" ] || \
  die "tag $VERSION does not match sushi-config.yaml version $IG_VERSION - bump sushi-config first"

# The publisher rejects a source folder that carries a package-list.json: that
# file belongs to the web root and is maintained there.
[ -f "$IG_SRC/package-list.json" ] && \
  die "$IG_SRC/package-list.json must not exist - package-list.json is maintained in the web root"

for f in header.template preamble.template postamble.template searchform.template.html; do
  [ -f "$PUB_TEMPLATES/$f" ] || die "missing $PUB_TEMPLATES/$f - run setup-webroot.sh first"
done
[ -f "$WEB_ROOT/publish-setup.json" ]    || die "missing $WEB_ROOT/publish-setup.json - run setup-webroot.sh first"
[ -f "$WEB_ROOT/package-registry.json" ] || die "missing $WEB_ROOT/package-registry.json - run setup-webroot.sh first"
[ -f "$IG_REGISTRY/fhir-ig-list.json" ]  || die "missing $IG_REGISTRY/fhir-ig-list.json - run setup-webroot.sh first"
[ -d "$IG_HISTORY" ]                     || die "missing $IG_HISTORY - run setup-webroot.sh first"

# The publisher works out where to put the guide from publish-setup.json's
# layout rule, not from the canonical every check below uses. Prove they agree.
assert_layout_rule
require_valid_package_list

# Idempotence. -go-publish makes both of these checks itself and fails with a
# validation message, but it only does so after a full build, so check up front.
#
# ALLOW_REPUBLISH=1 is the way out of the one case that has no other: a
# -go-publish interrupted after it started copying into the web root leaves the
# version folder and the package-list.json entry behind for a publication that
# is not there, and every retry of the same tag was then refused forever. It
# rolls the half-written publication back first, naming what it removes. It is
# not a way to replace a version that really was published - for that, HL7's
# mechanism is a technical correction (mode: technical-correction).
ALREADY=0
[ -d "$IG_WEB_DIR/$VERSION" ] && ALREADY=1
if [ -f "$IG_WEB_DIR/package-list.json" ] && \
   jq -e --arg v "$VERSION" '.list[]? | select(.version == $v)' \
      "$IG_WEB_DIR/package-list.json" >/dev/null 2>&1; then
  ALREADY=1
fi
if [ "$ALREADY" = "1" ]; then
  if [ "${ALLOW_REPUBLISH:-0}" = "1" ]; then
    log "ALLOW_REPUBLISH=1: $IG_ID#$VERSION is already present in the web root and will be removed before re-publishing."
    log "Use this only to retry a publication that was interrupted part way through."
    rollback_version "$VERSION"
  else
    [ -d "$IG_WEB_DIR/$VERSION" ] && \
      die "$IG_WEB_DIR/$VERSION already exists - $IG_ID#$VERSION is already published. If a previous run was interrupted, roll it back with ci/release-rollback.sh $VERSION, or re-run with ALLOW_REPUBLISH=1"
    die "package-list.json already has an entry for $VERSION - $IG_ID#$VERSION is already published. If a previous run was interrupted, roll it back with ci/release-rollback.sh $VERSION, or re-run with ALLOW_REPUBLISH=1"
  fi
fi

# Publishing out of order silently takes over the canonical: with mode
# milestone (the default) the version being published becomes `current`, so
# releasing 0.8.5 after 0.9.2 replaces the guide at the canonical with the older
# one and rewrites package-list.json to say so. Two ordinary actions reach it -
# tagging a backport, and pushing two tags at once, because GitLab's resource
# group default process mode is `unordered` and two queued release jobs are not
# guaranteed to run in tag order (set it to oldest_first; see infra/NOTES.md).
# -go-publish does not object, so object here.
NEWEST="$(newest_published)"
if [ -n "$NEWEST" ] && [ "$NEWEST" != "$VERSION" ] && \
   [ "$NEWEST" = "$(printf '%s\n%s\n' "$NEWEST" "$VERSION" | sort -V | tail -1)" ]; then
  [ "${PUB_MODE:-milestone}" = "working" ] || die \
    "$VERSION is older than the published $NEWEST - publishing it as a milestone would make it the current release at $IG_CANONICAL. Publish in order, or set PUB_MODE=working to publish it only under /$VERSION/"
  log "$VERSION is older than the published $NEWEST, but PUB_MODE=working, so the canonical stays on $NEWEST"
fi

# -go-publish clones the source folder twice and zips one of them, then copies
# its working root over the web root. Running out of space part way through is
# the likeliest way to get the half-written publication ALLOW_REPUBLISH exists
# for, and both numbers used to only be printed.
require_free_space "$PUB_TEMP" "${NEED_TEMP_GB:-20}" "-go-publish clones and zips the source folder here"
require_free_space "$WEB_ROOT" "${NEED_WEB_GB:-20}"  "the published version folder is copied here"

# ------------------------------------------------- publication-request.json
#
# Only generated when the repo does not carry one, so a hand-written request
# (a ballot, a technical correction, a custom description) always wins.
#
# Values chosen for DHP, and why:
#   mode     milestone  - each semver release becomes the current release, so
#                         https://dhp.uz/fhir/<ig>/ serves the newest one.
#                         "working" would publish only under /<version>/ and
#                         leave the canonical pointing at the older release.
#   status   draft for 0.x, release for >= 1.0.0 - matches `status: draft` in
#                         sushi-config.yaml and is honest about 0.x stability.
#                         The publisher accepts
#                         release|trial-use|update|preview|ballot|draft|
#                         normative+trial-use|normative|informative.
#   sequence Releases   - DHP uses plain semver, not HL7 ballot cycles, so one
#                         flat group on the history page. It also matches the
#                         edition name already recorded for uz.dhp.core in
#                         FHIR/ig-registry.
#   ci-build the local continuous build, https://dhp.uz/fhir/<ig>/ci-build,
#            because that is the build this pipeline maintains and keeps in step
#            with the default branch.
#
# "dhp-ci-scripts" is ours, not HL7's: the short sha of the `ci` branch the job
# ran from ($DHP_CI_SHA, exported by gitlab-ci.yml). The publisher reads the
# request field by field with asString(<name>) and never enumerates it, so an
# extra key is ignored rather than rejected - confirmed by disassembling
# org.hl7.fhir.igtools.web.PublicationProcess in publisher 2.3.4 and by a real
# -go-publish run. A hand-written publication-request.json in the repo wins over
# all of this, so it carries the field only if the author adds it.
PUB_STATUS="${PUB_STATUS:-}"
if [ -z "$PUB_STATUS" ]; then
  case "$VERSION" in
    0.*) PUB_STATUS=draft ;;
    *)   PUB_STATUS=release ;;
  esac
fi
PUB_MODE="${PUB_MODE:-milestone}"
PUB_SEQUENCE="${PUB_SEQUENCE:-Releases}"
PUB_CATEGORY="${PUB_CATEGORY:-National Base}"
PUB_COUNTRY="${PUB_COUNTRY:-uz}"
PUB_AUTHORITY="${PUB_AUTHORITY:-MOH Uzbekistan}"
PUB_CI_BUILD="${PUB_CI_BUILD:-$SITE_URL$IG_DEST/ci-build}"

# Installed before GENERATED_PR is set, not after: the flag used to be raised
# before the file was written and the trap installed after the jq that writes
# it, so a failure inside that jq left a partial publication-request.json in the
# checkout. Harmless in CI (GitLab cleans the work tree) but not outside it.
GENERATED_PR=0
cleanup() {
  [ "$GENERATED_PR" = "1" ] && rm -f "$IG_SRC/publication-request.json"
  return 0
}
trap cleanup EXIT

if [ -f "$IG_SRC/publication-request.json" ]; then
  log "using the publication-request.json carried by the repository"
else
  GENERATED_PR=1
  DESCRIPTION="$IG_DESCRIPTION"
  # The introduction is dropped straight into the markup of the history page,
  # so quotes have to arrive as entities. Neither DHP guide contains one today.
  DESCRIPTION="${DESCRIPTION//\"/&quot;}"
  DESCRIPTION="${DESCRIPTION//\'/&apos;}"
  DESC="${PUB_DESC:-Release $VERSION of the $IG_TITLE.}"

  # "first" is true only when this IG has never been published to this web
  # root. package-list.json is created by the first publication run; before
  # that there is nothing at the canonical but the ci-build folder.
  FIRST=false
  if [ ! -f "$IG_WEB_DIR/package-list.json" ]; then
    FIRST=true
  elif [ "$(jq '[.list[]? | select(.version != "current")] | length' "$IG_WEB_DIR/package-list.json")" = "0" ]; then
    FIRST=true
  fi
  log "publication-request.json: first=$FIRST mode=$PUB_MODE status=$PUB_STATUS sequence=$PUB_SEQUENCE"

  CHANGES=""
  if [ -f "$IG_SRC/input/pagecontent/changelog.md" ]; then
    CHANGES="changelog.html"
  fi

  jq -n \
    --arg pid "$IG_ID" \
    --arg version "$VERSION" \
    --arg path "$IG_CANONICAL/$VERSION" \
    --arg mode "$PUB_MODE" \
    --arg status "$PUB_STATUS" \
    --arg sequence "$PUB_SEQUENCE" \
    --arg desc "$DESC" \
    --arg changes "$CHANGES" \
    --argjson first "$FIRST" \
    --arg title "$IG_TITLE" \
    --arg cibuild "$PUB_CI_BUILD" \
    --arg category "$PUB_CATEGORY" \
    --arg intro "$DESCRIPTION" \
    --arg country "$PUB_COUNTRY" \
    --arg authority "$PUB_AUTHORITY" \
    --arg cisha "${DHP_CI_SHA:-unknown}" \
    '{
       "package-id": $pid,
       version: $version,
       path: $path,
       mode: $mode,
       status: $status,
       sequence: $sequence,
       desc: $desc,
       "dhp-ci-scripts": $cisha
     }
     + (if $changes == "" then {} else {changes: $changes} end)
     + {first: $first}
     + (if $first then {
         title: $title,
         "ci-build": $cibuild,
         category: $category,
         introduction: $intro,
         "registry-description": $intro,
         "registry-country": $country,
         "registry-authority": $authority
       } else {} end)' \
    > "$IG_SRC/publication-request.json"

  cat "$IG_SRC/publication-request.json" >&2
fi

# -------------------------------------------------------------------- build

prepare_publisher

# A gate has to ask the terminology server the same question the build that
# ships will ask. -go-publish rebuilds the guide with -resetTx, i.e. against an
# empty terminology cache, and that rebuild is what lands on the site; measuring
# a warm seeded cache instead is how three of the first four published versions
# came to carry validation errors the pipeline reported as clean (gotcha 1a).
# The cost is one cold terminology pass, about 15 minutes on these guides.
#
# So the cold pass is spent only when there is a gate to spend it on. With
# FAIL_ON_QA_ERRORS off - the default, because the GitHub side already enforces
# the limits - nothing here can refuse the publication, the pre-build is only
# there to produce the qa.json and package.tgz that -go-publish requires, and 15
# minutes of cold terminology lookups would buy a number nobody acts on.
# GATE_WARM_TXCACHE=1 forces the warm cache even with the gate on.
if ! qa_gate_enabled; then
  log "QA gate off, so the pre-build runs warm: it is not measuring what ships, it is producing the inputs -go-publish needs"
  seed_txcache
elif [ "${GATE_WARM_TXCACHE:-0}" = "1" ]; then
  warn "GATE_WARM_TXCACHE=1: gating against the warm seeded cache. This is faster, but it is NOT what -go-publish will build - see gotcha 1a"
  seed_txcache
else
  cold_txcache
fi

BUILD_LOG="${BUILD_LOG:-$IG_SRC/release-build.log}"
run_genonce "$BUILD_LOG"

verify_package "$IG_ID" "$VERSION"
[ -f "$IG_SRC/output/qa.json" ] || die "output/qa.json missing - -go-publish needs it"

read -r ERRS WARNS <<<"$(qa_counts)"
# Called the pre-build, not "QA", because a release produces two sets of counts
# and the other one is the one on the site. Both are reported; they can differ
# (gotcha 1a), and with the gate off nobody is stopped by either, so the log is
# the only place they are seen.
log "QA of the pre-build: $ERRS errors, $WARNS warnings, $(broken_links) broken links"
notify "IG build: $IG_ID $VERSION" "$ERRS errors, $WARNS warnings"

qa_gate "$ERRS" "publish"

# Advisory: a guide whose dependencies are not on this site still publishes.
check_site_dependencies

# --------------------------------------------------------------- go-publish

mkdir -p "$PUB_TEMP" "$ZIPS_DIR"

# The publisher is run from $PUBLISHER_JAR in $PUBLISHER_CACHE; the copy in the
# source tree is only there for _genonce.sh, which has now finished with it.
drop_publisher_from_source

PUBLISH_LOG="${PUBLISH_LOG:-$IG_SRC/go-publish.log}"
log "running -go-publish (this rebuilds the IG twice; expect 2-3x a normal build)"
start=$(date +%s)

set +e
java $JAVA_HEAP -jar "$PUBLISHER_JAR" -go-publish \
  -source    "$IG_SRC" \
  -web       "$WEB_ROOT" \
  -registry  "$IG_REGISTRY/fhir-ig-list.json" \
  -history   "$IG_HISTORY" \
  -templates "$PUB_TEMPLATES" \
  -temp      "$PUB_TEMP" \
  -zips      "$ZIPS_DIR" \
  >"$PUBLISH_LOG" 2>&1
rc=$?
set -e

elapsed=$(( $(date +%s) - start ))
log "-go-publish exited $rc after $((elapsed/60))m$((elapsed%60))s"

# The publisher writes validation failures to stdout and can still exit 0, so
# the success marker is what decides.
if ! grep -q "Finished Publishing" "$PUBLISH_LOG"; then
  tail -80 "$PUBLISH_LOG" >&2
  notify "IG publish FAILED: $IG_ID $VERSION" "see $PUBLISH_LOG"
  die "-go-publish did not reach 'Finished Publishing' - see $PUBLISH_LOG"
fi
[ "$rc" = "0" ] || die "-go-publish exited $rc - see $PUBLISH_LOG"

# The QA report that ships is the one from the publisher's own rebuild, not the
# one from _genonce.sh above. That rebuild runs with -resetTx, so a value set
# expansion answered from a warm cache during CI is re-fetched here and can come
# back different. Report both numbers; the site is already written by now, so
# this is a signal to the IG team rather than a reason to fail the job.
PUB_ERRS="?"; PUB_WARNS="?"
PUB_QA="$PUB_TEMP/ig-builds/$IG_ID#$VERSION-milestone/output/qa.json"
[ -f "$PUB_QA" ] || PUB_QA="$PUB_TEMP/ig-builds/$IG_ID#$VERSION/output/qa.json"
if [ -f "$PUB_QA" ]; then
  read -r PUB_ERRS PUB_WARNS <<<"$(jq -r 'if (.errs|type) == "number" and (.warnings|type) == "number"
                                          then "\(.errs) \(.warnings)" else "? ?" end' "$PUB_QA" 2>/dev/null || echo "? ?")"
  log "QA of the published build: $PUB_ERRS errors, $PUB_WARNS warnings (pre-build: $ERRS errors, $WARNS warnings)"
  if [ "$PUB_ERRS" != "0" ]; then
    warn "the build that was PUBLISHED reports $PUB_ERRS errors and $PUB_WARNS warnings (the pre-build reported $ERRS and $WARNS)"
    warn "  the site at $SITE_URL$IG_DEST/ is already written, so this is a signal, not a gate"
    # Not $PUB_QA: that lives under $PUB_TEMP, which is emptied a few lines down.
    warn "  the findings are in the published $SITE_URL$IG_DEST/qa.html"
    warn "  if the pre-build was clean, this is gotcha 1a: -resetTx re-resolves terminology from scratch, and a warm pre-build cannot see it"
  elif [ "$PUB_ERRS" != "$ERRS" ] || [ "$PUB_WARNS" != "$WARNS" ]; then
    # Not an error, but the two numbers disagreeing is the whole of gotcha 1a
    # and it is what tells the IG team the pre-build count is not the site's.
    warn "the published build ($PUB_ERRS errors, $PUB_WARNS warnings) does not agree with the pre-build ($ERRS, $WARNS) - gotcha 1a; the site's own numbers are at $SITE_URL$IG_DEST/qa.html"
  fi
else
  warn "no qa.json from the published build under $PUB_TEMP/ig-builds - the counts on the site are unknown; read $SITE_URL$IG_DEST/qa.html"
fi

# ------------------------------------------------------------------ verify

for p in \
  "$IG_WEB_DIR/package-list.json" \
  "$IG_WEB_DIR/history.html" \
  "$IG_WEB_DIR/$VERSION/index.html" \
  "$IG_WEB_DIR/$VERSION/package.tgz" ; do
  [ -e "$p" ] || die "expected $p after publication but it is missing"
done

if [ "$PUB_MODE" = "milestone" ]; then
  [ -e "$IG_WEB_DIR/index.html" ] || die "milestone release but $IG_WEB_DIR/index.html is missing"
fi

# -go-publish rewrites history.html on every publication, so this runs on every
# publication too.
localise_history_scripts

save_txcache

# The temp clones are several GB each; nothing downstream needs them.
if [ "${KEEP_PUB_TEMP:-0}" != "1" ]; then
  log "clearing $PUB_TEMP"
  rm -rf "${PUB_TEMP:?}/ig-builds" "${PUB_TEMP:?}/web-root"
fi

log "published $IG_ID#$VERSION"
log "  version : $SITE_URL$IG_DEST/$VERSION/"
log "  current : $SITE_URL$IG_DEST/   (mode=$PUB_MODE)"
log "  history : $SITE_URL$IG_DEST/history.html"
log ""
log "ig-registry was updated locally at $IG_REGISTRY/fhir-ig-list.json."
log "Open a PR against FHIR/ig-registry with that change (and, on the very first"
log "publication, register $SITE_URL/package-feed.xml in package-feeds.json)."
notify "IG published: $IG_ID $VERSION" "published build: $PUB_ERRS errors, $PUB_WARNS warnings"
