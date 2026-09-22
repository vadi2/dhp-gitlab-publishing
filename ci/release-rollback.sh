#!/usr/bin/env bash
# Undo one publication in the web root.
#
#   release-rollback.sh <version> [--yes]
#
# Removes, for the IG of the checked-out repository:
#   $WEB_ROOT/<dest>/<version>/          the published version folder
#   its entry in <dest>/package-list.json (and re-points `current` at the
#                                          newest version that is left)
#   its <item> in $WEB_ROOT/package-feed.xml and publication-feed.xml
#   its trace in $WEB_ROOT/package-registry.json
#
# It exists for one case: a -go-publish interrupted after it started copying
# into the web root leaves the version folder and the package-list.json entry
# behind for a publication that is not really there, and every later attempt to
# publish that tag is then refused forever. Nothing else in the toolchain can
# clear that.
#
# It is NOT the way to replace a version that really was published. Once a
# version has been announced, consumers have its package.tgz and its URLs; the
# mechanism for fixing it is a technical correction (mode: technical-correction
# in publication-request.json), which republishes the same version number with a
# new build and says so on the history page.
#
# The canonical (/<dest>/index.html and friends) is left exactly as the
# interrupted run left it, because only a publication run can regenerate it.
# After a rollback, re-run the release: -go-publish rewrites all of that.
#
# docker run:
#   docker run --rm --user "$(id -u):$(id -g)" \
#     -v <repo>:/src -v <webroot>:/web \
#     dhp-ig-publisher:local /ci/release-rollback.sh 0.9.1
#
# Env: WEB_ROOT, IG_SRC, plus KEEP_ZIP=1 to keep $ZIPS_DIR/<id>#<version>.zip.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

VERSION="${1:-}"
ASSUME_YES="${2:-}"
[ -n "$VERSION" ] || die "usage: release-rollback.sh <version> [--yes]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not MAJOR.MINOR.PATCH"

load_ig_config
require_web_root_mount
# Same mutex as release.sh and ci-build.sh: this rewrites the shared feeds and
# package-registry.json, which a concurrent release also rewrites.
lock_web_root

require_valid_package_list

PRESENT=0
[ -d "$IG_WEB_DIR/$VERSION" ] && PRESENT=1
if [ -f "$IG_WEB_DIR/package-list.json" ] && \
   jq -e --arg v "$VERSION" '.list[]? | select(.version == $v)' \
      "$IG_WEB_DIR/package-list.json" >/dev/null 2>&1; then
  PRESENT=1
fi
[ "$PRESENT" = "1" ] || die "$IG_ID#$VERSION is not published in $WEB_ROOT - nothing to roll back"

NEWEST="$(newest_published)"
cat >&2 <<EOF

About to roll back a publication from $WEB_ROOT

  guide           $IG_ID  ($IG_TITLE)
  version         $VERSION
  destination     $IG_WEB_DIR
  newest on site  ${NEWEST:-none}

This is only correct if that publication was interrupted part way through.
If it completed and was announced, use a technical correction instead - see the
header of this script.

EOF

if [ "$ASSUME_YES" != "--yes" ] && [ "${ROLLBACK_ASSUME_YES:-0}" != "1" ]; then
  # A tty may not be there (CI, docker run without -t); refuse rather than
  # guess, since the whole point of the prompt is that this is destructive.
  [ -t 0 ] || die "not running interactively - re-run with --yes (or ROLLBACK_ASSUME_YES=1) if this is really what you want"
  printf 'Type the version to confirm: ' >&2
  read -r reply
  [ "$reply" = "$VERSION" ] || die "got '$reply', expected '$VERSION' - nothing was changed"
fi

rollback_version "$VERSION"

if [ "${KEEP_ZIP:-0}" != "1" ]; then
  ZIPS_DIR="${ZIPS_DIR:-/zips}"
  zip="$ZIPS_DIR/$IG_ID#$VERSION.zip"
  if [ -f "$zip" ]; then
    log "removing $zip"
    rm -f "$zip"
  fi
fi

log ""
log "rolled back $IG_ID#$VERSION"
log "$IG_CANONICAL/ still serves whatever the interrupted run left there."
log "Re-run the release for $VERSION to regenerate it."
