#!/usr/bin/env bash
# Continuous build of the default branch.
#
# Builds the checked-out commit and deploys output/ to
#   $WEB_ROOT/<canonical path>/ci-build/
# e.g. $DHP_DATA/webroot/fhir/core/ci-build -> https://dhp.uz/fhir/core/ci-build/
#
# The swap is staged next to the target and moved into place, so a reader never
# sees a half-copied tree and no file from the previous build survives.
#
# By hand, from a checkout of the guide:
#   DHP_DATA=/srv/dhp ci/ci-build.sh
#
# GitLab CI runs it the same way, with IG_SRC=$CI_PROJECT_DIR.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

SKIP_DEPLOY="${SKIP_DEPLOY:-0}"

load_ig_config

# Everything below writes $WEB_ROOT except a SKIP_DEPLOY build, which is the one
# job that may run outside the web-root resource group. Take the lock before the
# build rather than before the copy: the build is what takes the time, and two
# builds racing here would also contend on the FHIR package cache.
if [ "$SKIP_DEPLOY" != "1" ]; then
  require_web_root
  lock_web_root
fi

CI_BUILD_DIR="$IG_WEB_DIR/ci-build"
CI_BUILD_URL="$SITE_URL$IG_DEST/ci-build"

COMMIT="${CI_COMMIT_SHA:-$(git -C "$IG_SRC" rev-parse HEAD 2>/dev/null || echo unknown)}"
REF="${CI_COMMIT_REF_NAME:-$(git -C "$IG_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
# -repo goes into the publish box verbatim as BOTH the href and the link text
# (STATUS_MSG_AUTOBUILD: <a href='{3}'>{3}</a>), so it has to be an absolute
# URL. An owner/repo/branch string produces a relative href that is broken on
# every page of the guide - over ten thousand broken links in one build.
#
# It is also on every one of the ~11000 pages of the ci-build, so on a public
# site it must be a URL the public can open. $CI_PROJECT_URL is the internal
# GitLab (an RFC-1918 address and a private project path), which is what the
# first ci-builds published. Two knobs, in order of precedence:
#
#   IG_REPO_URL         the complete value, used verbatim
#   CI_BUILD_REPO_URL   the repository's public home page; the branch-browsing
#                       path for $REF is appended. Defaults to $CI_PROJECT_URL.
#
# Set CI_BUILD_REPO_URL as a project CI/CD variable to cite the public GitHub
# repository instead of the internal mirror, e.g.
#   CI_BUILD_REPO_URL=https://github.com/uzinfocom-org/digital-health-integration
REPO_SOURCE="${IG_REPO_URL:-}"
if [ -z "$REPO_SOURCE" ]; then
  REPO_BASE="${CI_BUILD_REPO_URL:-${CI_PROJECT_URL:-}}"
  if [ -z "$REPO_BASE" ]; then
    REPO_BASE="$(git -C "$IG_SRC" remote get-url origin 2>/dev/null \
                 | sed -e 's#^git@\([^:]*\):#https://\1/#' -e 's#\.git$##' || echo)"
  fi
  REPO_BASE="${REPO_BASE%/}"
  if [ -n "$REPO_BASE" ]; then
    # GitLab browses a ref at /-/tree/<ref>, GitHub and Gitea at /tree/<ref>.
    case "$REPO_BASE" in
      *://github.com/*|*://gitea*|*://codeberg.org/*) REPO_SOURCE="$REPO_BASE/tree/$REF" ;;
      *)                                              REPO_SOURCE="$REPO_BASE/-/tree/$REF" ;;
    esac
  fi
fi
[ -n "$REPO_SOURCE" ] || die "cannot work out the repository URL for the publish box - set IG_REPO_URL"
case "$REPO_SOURCE" in
  http://*|https://*) ;;
  *) die "IG_REPO_URL must be an absolute URL, got '$REPO_SOURCE'" ;;
esac

prepare_publisher
seed_txcache

# -auto-ig-build is what makes the publisher write a continuous-build publish
# box ("this guide is not an authorized publication ...") instead of the "Local
# Development build" line a plain build produces. It is translated into ru and
# uz in the publisher's own phrase files, which a post-build rewrite could not
# match. -target is where the build will be served from and -repo is what the
# box cites as its source.
#
# -auto-ig-build also switches the publisher to the machine-wide package cache
# (/var/lib/.fhir on Linux), which the runner user cannot create, and it dies
# with an NPE out of FilesystemPackageCacheManager. -package-cache-folder points
# it back at the user cache every other build on this host uses.
BUILD_LOG="${BUILD_LOG:-$IG_SRC/ci-build.log}"
run_genonce "$BUILD_LOG" -auto-ig-build -target "$CI_BUILD_URL" -repo "$REPO_SOURCE" \
  -package-cache-folder "$HOME/.fhir"

[ -d "$IG_SRC/output" ] || die "no output/ directory after build"
[ -f "$IG_SRC/output/index.html" ] || die "output/index.html missing after build"

read -r ERRS WARNS <<<"$(qa_counts)"
log "QA: $ERRS errors, $WARNS warnings, $(broken_links) broken links"
notify "IG build: $IG_ID ci-build" "$ERRS errors, $WARNS warnings"

qa_gate "$ERRS" "deploy the ci-build"

# Merge-request and branch jobs want the build and the QA report, not a copy of
# 2.7 GB of output into a web root nobody serves.
#
# These jobs also leave the shared terminology seed alone. They are the only
# ones that can run outside the web-root resource group, so they are the only
# ones that could ever write it concurrently with another job.
if [ "$SKIP_DEPLOY" = "1" ]; then
  # A warning, not a log line: set as a project CI/CD variable rather than in
  # the merge-request job, this makes the default-branch ci-build go green
  # forever while the published continuous build silently goes stale.
  warn "SKIP_DEPLOY=1, build validated and NOT deployed - $CI_BUILD_URL is unchanged"
  exit 0
fi

check_ci_publish_box "$IG_SRC/output" "$REPO_SOURCE"

log "deploying output/ -> $CI_BUILD_DIR"
atomic_swap_dir "$IG_SRC/output" "$CI_BUILD_DIR"

# A stamp so it is obvious which commit the ci-build folder holds.
cat > "$CI_BUILD_DIR/ci-build-info.json" <<JSON
{
  "package-id": "$IG_ID",
  "version": "$IG_VERSION",
  "commit": "$COMMIT",
  "ref": "$REF",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "publisher": "${PUBLISHER_BUILD:-unknown}",
  "ci-scripts": "${DHP_CI_SHA:-unknown}",
  "source": "$REPO_SOURCE",
  "qa-errors": "$ERRS",
  "qa-warnings": "$WARNS"
}
JSON

save_txcache

log "ci-build published at $SITE_URL$IG_DEST/ci-build/"
