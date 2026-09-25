#!/usr/bin/env bash
# Replace "<version> - ci-build" in the page header of releases published before
# release.sh set the release label itself.
#
#   relabel-releases.sh <ig-code> [label]
#   DHP_DATA=/srv/dhp ci/relabel-releases.sh core
#
# Rewrites the HTML under $WEB_ROOT/fhir/<ig-code>/ except ci-build/, which
# covers every version folder and the copy at the canonical. The label defaults
# to each version's status in package-list.json (draft for 0.x), the same word
# release.sh now uses. Idempotent. Packages and JSON are left as published.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

IG="${1:?usage: relabel-releases.sh <ig-code> [label]}"
LABEL="${2:-}"
IG_DIR="$WEB_ROOT/fhir/$IG"
PL="$IG_DIR/package-list.json"
[ -f "$PL" ] || die "no $PL - is '$IG' a published guide?"

require_web_root
lock_web_root

# One sed expression per published version, so the tree is read once.
SED_ARGS=()
while read -r v status; do
  label="${LABEL:-$status}"
  [[ "$label" =~ ^[A-Za-z0-9.\ +-]+$ ]] || die "label '$label' for $v has characters sed would misread"
  SED_ARGS+=(-e "s/${v//./\\.} - ci-build/$v - $label/g")
  log "$v: '$v - ci-build' -> '$v - $label'"
done < <(jq -r '.list[] | select(.version != "current") | "\(.version) \(.status)"' "$PL")
[ "${#SED_ARGS[@]}" -gt 0 ] || die "$PL lists no published versions"

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
grep -rlZE --include='*.html' --exclude-dir=ci-build -- '[0-9]+\.[0-9]+\.[0-9]+ - ci-build' "$IG_DIR" > "$LIST" || true
n="$(tr -cd '\0' < "$LIST" | wc -c)"
log "$n pages carry a ci-build label outside ci-build/"
[ "$n" -gt 0 ] || exit 0
xargs -0 sed -i "${SED_ARGS[@]}" < "$LIST"

left="$(grep -rlE --include='*.html' --exclude-dir=ci-build -- '[0-9]+\.[0-9]+\.[0-9]+ - ci-build' "$IG_DIR" | wc -l || true)"
[ "$left" = "0" ] || die "$left pages still carry a ci-build label - a version missing from package-list.json?"
log "relabelled $n pages under $IG_DIR"
