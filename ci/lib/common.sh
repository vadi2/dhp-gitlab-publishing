#!/usr/bin/env bash
# Shared helpers for ci-build.sh and release.sh.
#
# Everything IG-specific is derived from the checked-out repo's
# sushi-config.yaml, so the same scripts serve uz.dhp.core and
# uz.dhp.integrations (and any later DHP IG) unchanged.
#
# Paths are container paths by default; every one can be overridden by env var
# so the scripts also run natively.

# -E so the ERR trap below also fires inside functions and subshells.
set -Eeuo pipefail

# An unhandled failure under `set -e` leaves no trace at all, which cost one
# 17-minute build to diagnose. Name the command and the line before exiting.
trap 'rc=$?; [ $rc -eq 0 ] || printf "[%s] FAILED rc=%s at %s:%s: %s\n" \
      "$(date -u +%H:%M:%S)" "$rc" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---------------------------------------------------------------- environment

IG_SRC="${IG_SRC:-/src}"                       # checked-out IG repo
WEB_ROOT="${WEB_ROOT:-/web}"                   # publication web root (W)
PUBLISHER_CACHE="${PUBLISHER_CACHE:-/publisher-cache}"
PUBLISHER_JAR="${PUBLISHER_JAR:-$PUBLISHER_CACHE/publisher.jar}"
TXCACHE_SEED="${TXCACHE_SEED:-}"               # optional seed for input-cache/txcache
FHIR_PACKAGE_CACHE="${FHIR_PACKAGE_CACHE:-/fhir-cache}"
SITE_URL="${SITE_URL:-https://dhp.uz}"         # what WEB_ROOT is served as
BUILD_TEMP="${BUILD_TEMP:-/tmp/dhp-build}"
JAVA_HEAP="${JAVA_HEAP:--Xmx12g}"

# Local copy of the two scripts the HL7 history template hard-codes to
# hl7.org; vendored by setup-webroot.sh, linked by localise_history_scripts.
HIST_ASSETS_DIR="${HIST_ASSETS_DIR:-$WEB_ROOT/fhir/assets-hist}"

# go-publish prerequisites (set up by setup-webroot.sh)
IG_HISTORY="${IG_HISTORY:-/publication/ig-history}"
IG_REGISTRY="${IG_REGISTRY:-/publication/ig-registry}"
PUB_TEMPLATES="${PUB_TEMPLATES:-/publication/templates}"
PUB_TEMP="${PUB_TEMP:-/publication/temp}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }
warn() { printf '[%s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# jq is not optional: the QA gate, the package check and the idempotence checks
# all read JSON with it, and every one of them used to degrade to "unknown"
# (which the gate then treated as "clean") when jq was missing. The pipeline
# invites the MOH to substitute their own image, so say so at the top rather
# than silently publishing an unvalidated build.
command -v jq >/dev/null 2>&1 || \
  die "jq is not on PATH - the QA gate and the package checks need it; install jq in the build image"

# ------------------------------------------------------------ package cache
#
# The publisher finds the FHIR package cache through user.home, and -go-publish
# does not forward -package-cache-folder to the builds it starts itself, so the
# only reliable lever is user.home. The image entrypoint sets this up for plain
# `docker run`, but GitLab CI replaces the image entrypoint with its own shell,
# so the same wiring has to happen here. Both are idempotent and it does not
# matter which one runs first, or whether both do.
wire_package_cache() {
  export HOME="${HOME:-/tmp/dhp-home}"
  mkdir -p "$HOME" "$FHIR_PACKAGE_CACHE/packages" 2>/dev/null || true

  # Only create the link if nothing is there. A real ~/.fhir directory, or a
  # volume the runner mounted at that path, is left exactly as it is.
  [ -e "$HOME/.fhir" ] || ln -sfn "$FHIR_PACKAGE_CACHE" "$HOME/.fhir" 2>/dev/null || true

  case " ${_JAVA_OPTIONS:-} " in
    *" -Duser.home="*) ;;
    *) export _JAVA_OPTIONS="-Duser.home=$HOME ${_JAVA_OPTIONS:-}" ;;
  esac

  # The IG checkout belongs to another uid in a CI job, and every script reads
  # the commit out of it.
  git config --global --add safe.directory '*' 2>/dev/null || true
}
wire_package_cache

# ------------------------------------------------------------- config parsing

# Read a top-level scalar key out of sushi-config.yaml. Deliberately simple:
# only top-level "key: value" lines, comments and quotes stripped. No yq in the
# image and none of the values we need are nested or multi-line.
#
# Order matters and used to be wrong (gotcha 18):
#   - a UTF-8 BOM makes the very first key unmatchable, so `id` came back empty
#     and the run died with "sushi-config.yaml has no id"
#   - a trailing CR defeats the `^"..."$` anchor below, so a CRLF file with
#     quoted values kept its quotes and the canonical check failed with a
#     message pointing at the canonical rather than at the line endings
#   - stripping `#` before the quotes truncates a quoted title at the first
#     `#` inside it, silently, and that value reaches package-list.json
# So: BOM and CR first, then quotes, and a comment is only a comment outside
# quotes. Block scalars (`>`/`|`) are still not supported - load_ig_config
# refuses them explicitly rather than publishing the literal `>-`.
sushi_get() {
  local key="$1" file="${2:-$IG_SRC/sushi-config.yaml}" raw
  raw="$(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$file" \
         | sed -n "s/^${key}:[[:space:]]*//p" | sed -n 1p)"
  case "$raw" in
    '"'*)  raw="${raw#\"}";  raw="${raw%%\"*}"  ;;   # quoted: ends at the closing quote
    "'"*)  raw="${raw#\'}";  raw="${raw%%\'*}"  ;;
    *)     raw="$(printf '%s' "$raw" | sed 's/[[:space:]]*#.*$//')" ;;
  esac
  printf '%s' "$raw" | sed 's/[[:space:]]*$//'
  printf '\n'
}

# Populate IG_ID, IG_CANONICAL, IG_VERSION, IG_TITLE, IG_STATUS, IG_DEST,
# IG_WEB_DIR from the checked-out repo.
load_ig_config() {
  [ -f "$IG_SRC/sushi-config.yaml" ] || die "no sushi-config.yaml in $IG_SRC"

  IG_ID="$(sushi_get id)"
  IG_CANONICAL="$(sushi_get canonical)"
  IG_VERSION="$(sushi_get version)"
  IG_TITLE="$(sushi_get title)"
  IG_DESCRIPTION="$(sushi_get description)"
  IG_STATUS="$(sushi_get status)"

  [ -n "$IG_ID" ]        || die "sushi-config.yaml has no id"
  [ -n "$IG_CANONICAL" ] || die "sushi-config.yaml has no canonical"
  [ -n "$IG_VERSION" ]   || die "sushi-config.yaml has no version"

  # title and description are copied verbatim into publication-request.json and
  # from there into package-list.json, history.html and the entry proposed for
  # FHIR/ig-registry, so a value this parser got wrong is silent and permanent.
  # Block scalars (`title: >-` on its own line) yield the literal ">-"; an empty
  # value means the key is nested, wrapped or spelled differently. Refuse both.
  local name value
  for name in title description; do
    case "$name" in title) value="$IG_TITLE" ;; *) value="$IG_DESCRIPTION" ;; esac
    case "$value" in
      '') die "sushi-config.yaml has no readable top-level '$name:' - these scripts read simple scalars only" ;;
      '>'*|'|'*)
        die "'$name:' in sushi-config.yaml is a block scalar ($value) - write it on one line, these scripts read simple scalars only" ;;
    esac
  done

  # Canonical must live under the site the web root is served as, otherwise the
  # publish layout rules cannot place the IG.
  case "$IG_CANONICAL" in
    "$SITE_URL"/*) : ;;
    *) die "canonical $IG_CANONICAL is not under SITE_URL $SITE_URL" ;;
  esac

  IG_DEST="${IG_CANONICAL#$SITE_URL}"          # e.g. /fhir/core
  IG_WEB_DIR="$WEB_ROOT$IG_DEST"               # e.g. /web/fhir/core

  log "IG            : $IG_ID"
  log "canonical     : $IG_CANONICAL"
  log "version       : $IG_VERSION"
  log "web directory : $IG_WEB_DIR"
}

# ------------------------------------------------------------------ publisher

# The version the jar itself reports, or "" if it cannot be run at all.
# No `| head -1`: head closes the pipe, grep dies of SIGPIPE and pipefail turns
# that into a silent exit (gotcha 6). `sed -n '1s/.../p'` reads to the end.
publisher_build_of() {
  java -jar "$1" -version 2>/dev/null \
    | grep -oE 'Version [0-9]+\.[0-9]+\.[0-9]+' | sed -n '1s/^Version //p' || true
}

# Put a publisher.jar in the repo's input-cache without re-downloading it on
# every run. Refreshes only when missing, when PUBLISHER_REFRESH=1, or when
# PUBLISHER_VERSION pins a version the cached jar is not.
#
# PUBLISHER_VERSION is the release tag in HL7/fhir-ig-publisher (e.g. 2.3.4).
# Unset means "whatever is current", which is how every release so far was
# built - convenient, but it means a release is not reproducible from its tag
# and that a publisher release can turn a green tag red overnight (same class
# as gotcha 8). Pin it once the pipeline is live.
prepare_publisher() {
  mkdir -p "$PUBLISHER_CACHE"
  local want="${PUBLISHER_VERSION:-}" url refresh=0
  if [ -n "$want" ]; then
    url="https://github.com/HL7/fhir-ig-publisher/releases/download/$want/publisher.jar"
  else
    url="https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar"
  fi
  [ -s "$PUBLISHER_JAR" ] || refresh=1
  [ "${PUBLISHER_REFRESH:-0}" = "1" ] && refresh=1
  if [ "$refresh" = "0" ] && [ -n "$want" ] && \
     [ "$(publisher_build_of "$PUBLISHER_JAR")" != "$want" ]; then
    log "cached publisher is not $want"
    refresh=1
  fi
  if [ "$refresh" = "1" ]; then
    log "downloading IG publisher${want:+ $want} to $PUBLISHER_JAR"
    curl -fsSL -o "$PUBLISHER_JAR.tmp" "$url"
    mv "$PUBLISHER_JAR.tmp" "$PUBLISHER_JAR"
  fi
  mkdir -p "$IG_SRC/input-cache"
  cp -f "$PUBLISHER_JAR" "$IG_SRC/input-cache/publisher.jar"

  PUBLISHER_BUILD="$(publisher_build_of "$PUBLISHER_JAR")"
  log "IG publisher  : ${PUBLISHER_BUILD:-unknown} ($(stat -c %s "$PUBLISHER_JAR") bytes)"

  # A jar truncated by a killed job or a full disk is a valid file of non-zero
  # length, so the refresh test above keeps reusing it. The version probe is the
  # only thing that notices - it used to end in `|| true` and carry on, and the
  # build then died 40 minutes later with an error pointing at _genonce.sh, or,
  # on the release path, after the gated build had already passed. Stop here.
  [ -n "$PUBLISHER_BUILD" ] || die \
    "$PUBLISHER_JAR does not report a version - it is truncated or not a jar. Delete it, or re-run with PUBLISHER_REFRESH=1"
  if [ -n "$want" ] && [ "$PUBLISHER_BUILD" != "$want" ]; then
    die "PUBLISHER_VERSION=$want but $PUBLISHER_JAR reports $PUBLISHER_BUILD"
  fi
}

# -go-publish clones and zips the whole source folder, so everything
# prepare_publisher and seed_txcache put in input-cache/ ends up in the release
# zip and in $PUB_TEMP: a 245 MB third-party binary and a terminology cache, for
# every release, on the same filesystem as the web root. The publisher itself is
# launched from $PUBLISHER_JAR in the mounted cache, never from the tree, and
# the builds -go-publish starts are in-process, so the copy is only needed by
# _genonce.sh. Drop it once the gated build is done. (gotcha 19)
drop_publisher_from_source() {
  [ -f "$IG_SRC/input-cache/publisher.jar" ] || return 0
  log "removing input-cache/publisher.jar from the source tree ($(stat -c %s "$IG_SRC/input-cache/publisher.jar") bytes) so -go-publish does not clone and zip it"
  rm -f "$IG_SRC/input-cache/publisher.jar"
}

# A build against an empty terminology cache stalls for hours on tx.fhir.org
# lookups, so seed input-cache/txcache when a seed directory is available.
# -tx n/a is not an option: it crashes the publisher.
seed_txcache() {
  [ -n "$TXCACHE_SEED" ] || { log "no TXCACHE_SEED set, terminology cache starts cold"; return 0; }
  [ -d "$TXCACHE_SEED" ] || { log "TXCACHE_SEED $TXCACHE_SEED does not exist, skipping"; return 0; }
  mkdir -p "$IG_SRC/input-cache/txcache"
  if [ -z "$(ls -A "$IG_SRC/input-cache/txcache" 2>/dev/null)" ]; then
    log "seeding txcache from $TXCACHE_SEED ($(du -sh "$TXCACHE_SEED" | cut -f1))"
    cp -a "$TXCACHE_SEED/." "$IG_SRC/input-cache/txcache/"
  else
    log "txcache already populated, leaving it alone"
  fi
}

# The opposite of seed_txcache: make sure the build starts with no terminology
# cache at all, which is what -go-publish's own builds do (they run -resetTx,
# gotcha 1). A gate measured against a warm cache does not measure the build
# that ships - three of the first four published versions carry validation
# errors the gate never saw (gotcha 1a). Costs one cold terminology pass,
# ~15 min on these guides.
cold_txcache() {
  if [ -d "$IG_SRC/input-cache/txcache" ]; then
    log "clearing $IG_SRC/input-cache/txcache: the gated build runs cold, like -go-publish's own builds"
    rm -rf "${IG_SRC:?}/input-cache/txcache"
  else
    log "no terminology cache in the source tree, the gated build already starts cold"
  fi
}

# Copy the (grown) terminology cache back to the seed directory so the next
# pipeline run starts warm. Best effort.
# Test TXCACHE_SEED itself, not its parent: it is a mounted volume, and the
# directory above a volume mount point (/ in the container) is not writable by
# the unprivileged uid the container runs as. Checking the parent silently
# turned this whole function into a no-op.
save_txcache() {
  [ -n "$TXCACHE_SEED" ] || return 0
  [ -d "$IG_SRC/input-cache/txcache" ] || return 0
  mkdir -p "$TXCACHE_SEED" 2>/dev/null || true
  if [ ! -w "$TXCACHE_SEED" ]; then
    log "txcache seed $TXCACHE_SEED is not writable, not saving"
    return 0
  fi
  cp -a "$IG_SRC/input-cache/txcache/." "$TXCACHE_SEED/" 2>/dev/null || true
  log "txcache saved back to $TXCACHE_SEED ($(du -sh "$TXCACHE_SEED" | cut -f1))"
}

# ---------------------------------------------------------------------- build

# Build with the repo's own _genonce.sh, which runs SUSHI internally.
# _genonce.sh hard-exports JAVA_TOOL_OPTIONS="-Xms6g -Xmx12g", so the heap is
# capped through _JAVA_OPTIONS, which the JVM applies after JAVA_TOOL_OPTIONS.
run_genonce() {
  local log_file="${1:-$IG_SRC/build.log}"
  shift || true
  # _genonce.sh forwards "$*" to the publisher, so extra arguments land there.
  local extra=( "$@" )
  export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} $JAVA_HEAP"
  # A reused checkout can still hold output/ from a different version, and
  # -go-publish clones and zips the whole source folder, stale files included.
  if [ "${CLEAN_OUTPUT:-1}" = "1" ] && [ -d "$IG_SRC/output" ]; then
    log "clearing stale $IG_SRC/output"
    rm -rf "${IG_SRC:?}/output"
  fi
  log "building with ./_genonce.sh ${extra[*]:-} (log: $log_file)"
  local start; start=$(date +%s)
  chmod +x "$IG_SRC/_genonce.sh"
  ( cd "$IG_SRC" && ./_genonce.sh "${extra[@]}" ) >"$log_file" 2>&1 || {
    tail -60 "$log_file" >&2
    die "_genonce.sh failed, see $log_file"
  }
  log "build finished in $(( ($(date +%s) - start) / 60 ))m$(( ($(date +%s) - start) % 60 ))s"
}

# Errors/warnings from the build's QA output, for notifications and for the
# job log. Prints "errors warnings", or "? ?" if they cannot be determined.
#
# Read qa.json, not qa.html: qa.html carries the counts inside prose that has
# changed shape between publisher versions, and a grep that stops matching
# silently reports zero errors - which would let a broken build be published.
# qa.json has them as numbers and is also what -go-publish itself reads.
qa_counts() {
  local qaj="$IG_SRC/output/qa.json"
  [ -f "$qaj" ] || { echo "? ?"; return 0; }
  local out
  out="$(jq -r 'if (.errs|type) == "number" and (.warnings|type) == "number"
                then "\(.errs) \(.warnings)" else "? ?" end' "$qaj" 2>/dev/null || true)"
  echo "${out:-? ?}"
}

# Is the QA gate on? Off by default, and that is a decision rather than an
# oversight: the GitHub side already enforces its own error and warning limits
# on every pull request and every release, so gating here too would stop a
# publication for something that has already been reviewed and accepted
# upstream, in a pipeline whose job is to publish what upstream approved.
#
# The switch stays, per project or per run, for the case where this pipeline is
# the only check - a repository without the GitHub workflows, or a deliberately
# strict release.
#
# Which values mean what is the other half of this: the only value that used to
# enable the gate was the literal "1", so FAIL_ON_QA_ERRORS=true, set by an
# admin who believed they were hardening the pipeline, disabled it for every
# build and every release of that project, invisibly. Accept the words an
# operator will reach for as "off", and treat anything else - including a typo -
# as "on", so a mistake in the value leaves the gate on rather than off.
qa_gate_enabled() {
  local v="${FAIL_ON_QA_ERRORS:-0}"
  case "${v,,}" in
    0|false|no|off) return 1 ;;
    *)              return 0 ;;
  esac
}

# Report the QA counts, and apply the gate if it is on. $1 is the error count
# from qa_counts, $2 what refusing would mean.
#
# "?" is not "clean". qa_counts returns it when qa.json is absent, truncated,
# has renamed fields or non-numeric counts. With the gate on that is fatal - an
# unreadable report used to publish as readily as a clean one, which is the hole
# gotcha 10 was written to close, re-opened from the other side. With the gate
# off nothing here can refuse, so it is a loud warning instead: the counts in
# the job log are the only place anyone will see them, and "?" has to look
# different from "0".
qa_gate() {
  local errs="$1" what="$2"
  if ! qa_gate_enabled; then
    if [ "$errs" = "?" ]; then
      warn "the QA counts in $IG_SRC/output/qa.json could not be read (absent, truncated, or 'errs'/'warnings' are not numbers)"
      warn "  the QA gate is off (FAIL_ON_QA_ERRORS=${FAIL_ON_QA_ERRORS:-0}), so this does not stop the $what - but nothing here has checked the build"
      warn "  read the published qa.html, and set FAIL_ON_QA_ERRORS=1 if this pipeline is meant to be the check"
    elif [ "$errs" != "0" ]; then
      warn "the build reports $errs QA errors and the QA gate is off (FAIL_ON_QA_ERRORS=${FAIL_ON_QA_ERRORS:-0}), so the $what goes ahead"
      warn "  the error limits are enforced on the GitHub side; set FAIL_ON_QA_ERRORS=1 to gate here as well"
    else
      log "QA gate off (FAIL_ON_QA_ERRORS=${FAIL_ON_QA_ERRORS:-0}), and the build is clean anyway"
    fi
    return 0
  fi
  if [ "$errs" = "?" ]; then
    die "the QA counts in $IG_SRC/output/qa.json could not be read (absent, truncated, or 'errs'/'warnings' are not numbers) - refusing to $what"
  fi
  [ "$errs" = "0" ] || die "build produced $errs QA errors, refusing to $what"
}

# The publisher does not derive the destination folder from the canonical, it
# derives it from publish-setup.json's layout rule - "/fhir/{3}", where {3} is
# the third dot-separated part of the package id. IG_WEB_DIR comes from the
# canonical instead. They agree for uz.dhp.core and uz.dhp.integrations; for a
# future uz.dhp.core.v2 they would not, and every idempotence check here would
# read one directory while the publisher wrote another.
assert_layout_rule() {
  local setup="$WEB_ROOT/publish-setup.json"
  [ -f "$setup" ] || return 0
  local rule
  # `.npm as $n` first: inside test()'s argument the input is the piped $id, not
  # the rule, so a plain `.npm` there is an index of a string and jq aborts.
  # Nothing is swallowed here - a jq failure has to be a failure, or this check
  # degrades into the warning it exists to replace.
  rule="$(jq -r --arg id "$IG_ID" '
      [ .["layout-rules"][]?
        | select(.npm as $n
                 | $id | test("^" + ($n | gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$")) ]
      | if length == 0 then "" else "\(.[0].canonical)\t\(.[0].destination)" end' \
      "$setup")" || die "could not read the layout-rules from $setup - is it valid JSON?"
  if [ -z "$rule" ]; then
    warn "no layout rule in $setup matches $IG_ID - -go-publish will refuse the publication"
    return 0
  fi
  local canon="${rule%%$'\t'*}" dest="${rule#*$'\t'}" i
  local parts=()
  local IFS='.'
  read -r -a parts <<<"$IG_ID"
  unset IFS
  for i in "${!parts[@]}"; do
    canon="${canon//\{$((i+1))\}/${parts[$i]}}"
    dest="${dest//\{$((i+1))\}/${parts[$i]}}"
  done
  [ "$canon" = "$IG_CANONICAL" ] || die \
    "publish-setup.json puts $IG_ID at $canon, but sushi-config.yaml says the canonical is $IG_CANONICAL - fix one of them before publishing"
  [ "$WEB_ROOT$dest" = "$IG_WEB_DIR" ] || die \
    "publish-setup.json puts $IG_ID in $WEB_ROOT$dest, but the canonical implies $IG_WEB_DIR - the checks here and the publisher would use different folders"
  log "layout rule   : $IG_ID -> $canon ($WEB_ROOT$dest)"
}

# Warn when the built package depends on a sibling DHP package version this site
# does not publish: a client that resolves dependencies from $SITE_URL will not
# find it and has to fall back to packages.fhir.org. Never fatal - an old tag
# legitimately depends on a core version that was never published here, which is
# exactly the situation on the site today (integrations 0.9.0 -> core 0.9.0).
check_site_dependencies() {
  local tgz="$IG_SRC/output/package.tgz" meta prefix dep ver seg pl
  [ -f "$tgz" ] || return 0
  meta="$(tar -xzOf "$tgz" package/package.json 2>/dev/null || true)"
  [ -n "$meta" ] || return 0
  # Siblings are the packages the site's layout rule covers, i.e. the ones that
  # share this guide's first two id segments (uz.dhp.*).
  prefix="$(printf '%s' "$IG_ID" | cut -d. -f1-2)."
  while IFS=$'\t' read -r dep ver; do
    [ -n "$dep" ] || continue
    seg="$(printf '%s' "$dep" | cut -d. -f3)"
    pl="$WEB_ROOT/fhir/$seg/package-list.json"
    if [ -f "$pl" ] && jq -e --arg v "$ver" '.list[]? | select(.version == $v)' "$pl" >/dev/null 2>&1; then
      log "dependency    : $dep#$ver is published at $SITE_URL/fhir/$seg/$ver/"
    else
      warn "$IG_ID#$IG_VERSION depends on $dep#$ver, which $SITE_URL does not publish"
      warn "  a client resolving dependencies from $SITE_URL will not find it; it will only work by falling back to packages.fhir.org"
      warn "  publish $dep#$ver to this site, or release against a version that is published"
    fi
  done < <(printf '%s' "$meta" \
           | jq -r --arg p "$prefix" '.dependencies // {} | to_entries[]
                                      | select(.key | startswith($p)) | "\(.key)\t\(.value)"')
}

# Broken links are not counted in qa.json - they are the first number on the
# "Build Errors :" line at the top of qa.txt. Worth reporting separately,
# because a single bad argument can add one to every page in the guide.
broken_links() {
  local qat="${1:-$IG_SRC/output}/qa.txt"
  [ -f "$qat" ] || { echo "?"; return 0; }
  local n
  # `{p;q}` rather than `| head -1`: head closes the pipe, sed dies of SIGPIPE
  # and pipefail turns that into a failed job (gotchas 6 and 15).
  n="$(sed -n 's/^ *Build Errors *: *\([0-9]*\).*/\1/p;/^ *Build Errors *:/q' "$qat")"
  echo "${n:-?}"
}

# Confirm the built package really is <id>#<version>, the same check the
# GitHub release workflow makes before it publishes anything.
verify_package() {
  local want_id="$1" want_version="$2"
  local tgz="$IG_SRC/output/package.tgz"
  [ -f "$tgz" ] || die "output/package.tgz was not produced"
  local meta name ver
  meta="$(tar -xzOf "$tgz" package/package.json)"
  name="$(echo "$meta" | jq -r .name)"
  ver="$(echo "$meta" | jq -r .version)"
  log "built package : $name#$ver"
  [ "$name" = "$want_id" ] || die "built package id $name != $want_id"
  [ "$ver" = "$want_version" ] || die "built package version $ver != $want_version"
}

# ------------------------------------------------------------------- deploy

# $WEB_ROOT has to be the bind mount of the real web root, not a directory the
# container happens to have. If the runner is regenerated without the volume, or
# a volume name is mistyped, `mkdir -p $WEB_ROOT` in the scripts below quietly
# creates it inside the container's own filesystem: the build then "publishes"
# into a layer that is discarded when the job ends, the job goes green, and the
# site is untouched with nothing in the log to say so. Every write path here
# depends on the mount being real, so prove it before doing any work.
#
# WEB_ROOT_MOUNT_OPTIONAL=1 for the case this cannot cover: a host run where the
# web root is an ordinary directory on the same filesystem as everything else
# (setup-webroot.sh on a laptop). It is never right in the job image.
require_web_root_mount() {
  local wr="${WEB_ROOT%/}"
  [ -n "$wr" ] || die "WEB_ROOT is empty"
  if [ "${WEB_ROOT_MOUNT_OPTIONAL:-0}" = "1" ]; then
    log "web root      : $wr (mount check skipped, WEB_ROOT_MOUNT_OPTIONAL=1)"
    return 0
  fi
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$wr" && { log "web root      : $wr (bind mount)"; return 0; }
  elif [ -r /proc/mounts ] && grep -qs " ${wr} " /proc/mounts; then
    log "web root      : $wr (bind mount)"
    return 0
  elif [ ! -r /proc/mounts ] && ! command -v mountpoint >/dev/null 2>&1; then
    warn "cannot tell whether $wr is a mount (no mountpoint(1) and no /proc/mounts) - skipping the check"
    return 0
  fi
  die "$wr is not a mount point. The web root volume is not mounted into this container, so anything published would be written to the container's own filesystem and thrown away. Check the -v <webroot>:$wr in the docker run, or the runner's volumes = [...] in config.toml. To publish into a plain directory on purpose, set WEB_ROOT_MOUNT_OPTIONAL=1"
}

# Serialise everything that writes the web root. `resource_group: dhp-webroot`
# only serialises within one project, and core is serialised against
# integrations by `concurrent = 1` on the runner - one line in a file the admins
# own, invisible from the pipeline, and broken without warning by registering a
# second runner with the `dhp` tag. The shared site files (package-feed.xml,
# publication-feed.xml, package-registry.json) are rewritten by every release,
# so two concurrent releases would interleave read-modify-write and lose one
# guide's entry. Put the mutex on the resource instead. (gotcha 20)
#
# The lock is held for the life of the script through fd 9, so it is released
# whatever happens to the job, including SIGKILL.
lock_web_root() {
  local lockfile="$WEB_ROOT/.publish.lock" wait="${WEB_LOCK_WAIT:-21600}"
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock is not in this image - web-root writes are serialised only by the runner's concurrent = 1"
    return 0
  fi
  mkdir -p "$WEB_ROOT" 2>/dev/null || true
  exec 9>"$lockfile" || die "cannot create the lock file $lockfile - is $WEB_ROOT writable?"
  if ! flock -n 9; then
    log "another publish is holding $lockfile, waiting up to ${wait}s"
    flock -w "$wait" 9 || die "gave up after ${wait}s waiting for $lockfile - another publish is still running"
  fi
  log "web-root lock : $lockfile"
}

# Refuse to start a release that cannot finish. -go-publish clones the source
# folder twice and zips one of the copies, and finishes with one copyDirectory
# over the web root; an interruption half way through leaves a version folder
# and a package-list.json entry for a publication that is not there, which
# release.sh then refuses to re-run. Disk is the likeliest trigger and the
# script used to only print the free space.
require_free_space() {
  local path="$1" need_gb="$2" what="$3" free_kb
  mkdir -p "$path" 2>/dev/null || true
  free_kb="$(df -Pk "$path" | awk 'NR==2{print $4}')"
  case "$free_kb" in
    ''|*[!0-9]*) warn "could not read the free space at $path, skipping the check"; return 0 ;;
  esac
  local free_gb=$(( free_kb / 1024 / 1024 ))
  log "free space    : ${free_gb}G at $path ($what)"
  [ "$free_kb" -ge $(( need_gb * 1024 * 1024 )) ] || die \
    "only ${free_gb}G free at $path, a release needs about ${need_gb}G there ($what). Free space or set PUB_TEMP/WEB_ROOT to a bigger filesystem"
}

# Replace a directory with new content without ever leaving a half-written or
# stale-file state visible: stage outside the served tree, then swap directories.
#
# Staging used to be $parent/.<base>.new.$$, i.e. inside $IG_WEB_DIR, which
# nginx serves. A failed copy left the whole multi-GB tree there - and the most
# likely reason for the copy to fail is the disk being full in the first place.
# Nothing collected it either: the cleanup only named the current pid. It now
# stages under $WEB_ROOT/.staging (same filesystem, so the swap is still a
# rename), and sweeps both locations on entry. (gotcha 21)
#
# Still two renames, not a symlink swap: -go-publish copies its working root
# over the web root with a plain directory copy, and how that behaves when a
# published path is a symlink is unverified. The window between the renames is
# two syscalls wide and the next run repairs it (see below).
atomic_swap_dir() {
  local src="$1" dest="$2"
  local parent; parent="$(dirname "$dest")"
  local base;   base="$(basename "$dest")"
  local stage_root="${STAGING_DIR:-$WEB_ROOT/.staging}"
  local staging="$stage_root/${base}.new.$$"
  local old="$stage_root/${base}.old.$$"

  mkdir -p "$parent" "$stage_root"

  local leftovers=() d
  shopt -s nullglob
  leftovers=( "$stage_root/${base}".old.* "$parent/.${base}".old.* )
  shopt -u nullglob

  # A job killed between the two renames leaves the live directory parked as
  # <base>.old.<pid> and nothing at $dest - the site 404s until someone notices.
  # Put it back rather than sweeping it away, so the window closes itself.
  if [ ! -d "$dest" ] && [ ${#leftovers[@]} -gt 0 ]; then
    warn "$dest is missing and ${leftovers[0]} is parked next to it"
    warn "  a previous swap was killed between its two renames; restoring the old build"
    mv "${leftovers[0]}" "$dest"
  fi

  shopt -s nullglob
  for d in "$stage_root/${base}".new.* "$stage_root/${base}".old.* \
           "$parent/.${base}".new.*    "$parent/.${base}".old.* ; do
    [ -e "$d" ] || continue
    log "sweeping stale staging tree $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
    rm -rf "$d"
  done
  shopt -u nullglob

  mkdir -p "$staging"
  # -a preserves times so unchanged files keep their mtimes; --delete is
  # irrelevant here because staging starts empty.
  cp -a "$src/." "$staging/"

  if [ -d "$dest" ]; then
    mv "$dest" "$old"
  fi
  mv "$staging" "$dest"
  rm -rf "$old"
}

# The publish box is written by the publisher, not by us. A plain build produces
# "<title> - Local Development build (vX) built by the FHIR Build Tools", which
# is wrong for something served at a public ci-build URL. Passing
# -auto-ig-build makes it emit the continuous-build statement instead, and the
# publisher has that phrase translated for every language the guide builds.
#
# This only confirms the result, since getting it wrong is silent: the page
# still has a publish box, it just says the wrong thing.
# $2, optional: the URL that was passed to -repo, so the box can be checked
# against what was actually asked for rather than against a guess.
check_ci_publish_box() {
  local dir="$1" expect="${2:-}" page="$1/en/index.html"
  [ -f "$page" ] || page="$dir/index.html"
  [ -f "$page" ] || { log "no page to check the publish box on"; return 0; }

  # Cut the box out with bash string operations rather than a regex. The
  # publisher sometimes emits it on one long line and sometimes wraps it, and
  # it may prefix the text with a line-number anchor, so a line-oriented grep
  # with a fixed character window finds the opening tag but can stop short of
  # the links inside. Flattening the page and matching `.\{0,4000\}` against
  # the resulting single half-megabyte line is worse still - grep takes minutes
  # over it. `${var#...}` has neither problem.
  local html box=""
  html=$(< "$page")
  html=${html//$'\n'/ }
  if [ "${html#*<p id=\"publish-box\">}" != "$html" ]; then
    box=${html#*<p id=\"publish-box\">}
    box="<p id=\"publish-box\">${box%%</p>*}"
  fi
  log "publish box: ${box:0:260}"

  case "$box" in
    *"Publish Box goes here"*)
      die "the publish box is still the template placeholder - the build did not fill it in" ;;
    *"Local Development build"*)
      die "the publish box says 'Local Development build' - -auto-ig-build did not take effect" ;;
    "")
      die "no publish box found in $page" ;;
  esac

  # The box cites -repo as <a href='...'>, using the value as both the href and
  # the link text. A value without a scheme becomes a relative link that is
  # broken on every page in the guide, so catch it here rather than in ten
  # thousand lines of qa.txt.
  #
  # No pipeline here on purpose: `grep ... | head -1 | sed ...` fails the whole
  # job under `set -e` plus pipefail the moment grep matches nothing, which is
  # how this check broke a build that was otherwise perfectly good (gotcha 15).
  #
  # Both quote styles, in one alternation so whichever link comes first wins.
  # The phrase in rendering-phrases.properties is written `<a href=''{3}''>`,
  # which MessageFormat renders with single quotes, and whether they survive to
  # the published page depends on which fragment the release header went
  # through - the integrations ci-build comes out with double quotes and the
  # core one with single. A check that only knew about double quotes would go
  # quietly blind on half the builds.
  local href=""
  if [[ "$box" =~ href=(\"[^\"]*\"|\'[^\']*\') ]]; then
    href="${BASH_REMATCH[1]}"
    href="${href:1:${#href}-2}"
  fi

  if [ -n "$expect" ] && [ "$href" = "$expect" ]; then
    log "publish box source link: $href"
    return 0
  fi

  case "$href" in
    "")
      # Not fatal. The three checks above already prove the box says the right
      # thing; a missing link is worth knowing about but not worth throwing
      # away an hour of build.
      log "WARNING: no link found in the publish box - check $page by hand" ;;
    http://*|https://*)
      if [ -n "$expect" ]; then
        log "WARNING: publish box cites $href, not the $expect passed to -repo"
      else
        log "publish box source link: $href"
      fi ;;
    *)
      die "the publish box cites '$href' as its source, which is not an absolute URL - pass -repo a full URL" ;;
  esac
}

# The HL7 history template hard-codes two script tags to https://hl7.org/fhir/,
# and -go-publish writes them into every history.html it generates. The history
# page is the landing page of each guide, so on a site meant to work inside the
# MOH network it is the one page that silently degrades when hl7.org is
# unreachable: the version table is built by history.js, so without it the page
# renders its header and nothing else.
#
# setup-webroot.sh vendors both files into $HIST_ASSETS_DIR once; this points
# the two tags at that copy. Two lines, rewritten after every publication
# because -go-publish regenerates history.html each time.
#
# Deliberately narrow: only $IG_WEB_DIR/history.html, only those two src
# values. qa-tx.html and searchform.html carry the same URLs but are publisher
# artefacts nothing links to (see the rejected findings in NOTES.md).
localise_history_scripts() {
  local page="${1:-$IG_WEB_DIR/history.html}" rel
  [ -f "$page" ] || { warn "no $page to localise the history scripts in"; return 0; }
  if [ ! -s "$HIST_ASSETS_DIR/history.js" ] || [ ! -s "$HIST_ASSETS_DIR/history-cm.js" ]; then
    warn "$HIST_ASSETS_DIR does not hold history.js and history-cm.js - leaving $page pointing at hl7.org. Re-run setup-webroot.sh with network access to vendor them"
    return 0
  fi
  # Relative, not site-absolute: the destination folder comes from the
  # publish-setup.json layout rule and is not guaranteed to be two deep.
  rel="$(realpath -m --relative-to="$(dirname "$page")" "$HIST_ASSETS_DIR" 2>/dev/null || echo)"
  [ -n "$rel" ] || { warn "cannot work out a relative path from $page to $HIST_ASSETS_DIR"; return 0; }
  sed -i \
    -e "s#https://hl7\.org/fhir/history-cm\.js#$rel/history-cm.js#g" \
    -e "s#https://hl7\.org/fhir/history\.js#$rel/history.js#g" \
    "$page"
  if grep -q 'hl7\.org/fhir/history' "$page"; then
    warn "$page still references hl7.org/fhir/history*.js after the rewrite - the template markup changed"
  else
    log "history scripts in $page now load from $rel/"
  fi
}

# ----------------------------------------------------------------- rollback
#
# The newest published version according to package-list.json, by `sort -V`.
# "current" is the ci-build entry, not a version, so it is excluded.
newest_published() {
  local pl="${1:-$IG_WEB_DIR/package-list.json}"
  [ -f "$pl" ] || return 0
  jq -r '[.list[]?.version | select(. != "current")] | .[]' "$pl" 2>/dev/null \
    | sort -V | tail -1
}

# package-list.json is read by four checks here and by -go-publish itself, and a
# malformed one used to fail quietly in different ways in each of them (a first
# release would lose its title, ci-build, category and registry fields because
# an empty jq result left FIRST=false). Say so once, loudly.
require_valid_package_list() {
  local pl="${1:-$IG_WEB_DIR/package-list.json}"
  [ -f "$pl" ] || return 0
  jq -e . "$pl" >/dev/null 2>&1 || die \
    "$pl is not valid JSON - the publication history of this guide lives in that file; fix or restore it before publishing"
  # Valid JSON is not enough: `{}` passes jq and then every `.list[]?` in here
  # yields nothing, which reads as "nothing has been published yet".
  jq -e '(.list | type) == "array"' "$pl" >/dev/null 2>&1 || die \
    "$pl has no \"list\" array - it is not a package-list.json; fix or restore it before publishing"
}

# Undo a publication from the web root: the version folder, its entry in
# package-list.json, its item in the two site feeds, and its trace in
# package-registry.json. Used by release-rollback.sh and by release.sh under
# ALLOW_REPUBLISH=1, for the one case that has no other way out - a -go-publish
# that was interrupted after it started writing the web root.
#
# It does not touch ig-history, the ig-registry clone or $ZIPS_DIR: the first
# two are re-derived on the next publication, and a stale zip is harmless.
rollback_version() {
  local version="$1"
  local pl="$IG_WEB_DIR/package-list.json"
  local removed=0

  require_valid_package_list "$pl"

  log "rolling back $IG_ID#$version from $WEB_ROOT:"
  [ -d "$IG_WEB_DIR/$version" ] && \
    log "  remove directory     $IG_WEB_DIR/$version ($(du -sh "$IG_WEB_DIR/$version" 2>/dev/null | cut -f1))"
  [ -f "$pl" ] && \
    log "  drop the $version entry from $pl"
  log "  drop the $version item from $WEB_ROOT/package-feed.xml and $WEB_ROOT/publication-feed.xml"
  log "  recompute $IG_ID in $WEB_ROOT/package-registry.json"

  if [ -d "$IG_WEB_DIR/$version" ]; then
    rm -rf "${IG_WEB_DIR:?}/${version:?}"
    removed=$((removed+1))
  fi

  if [ -f "$pl" ]; then
    # Drop the entry, then hand `current` to the newest remaining version, so
    # history.html and the registry do not end up with no current release.
    local keep newest
    keep="$(jq --arg v "$version" '.list |= map(select(.version != $v))' "$pl")"
    newest="$(printf '%s' "$keep" | jq -r '[.list[]?.version | select(. != "current")] | .[]' | sort -V | tail -1)"
    printf '%s' "$keep" \
      | jq --arg n "$newest" '.list |= map(if .version == $n and $n != "" then .current = true
                                           elif .version != "current" then del(.current) else . end)' \
      > "$pl.tmp"
    mv "$pl.tmp" "$pl"
    log "  package-list.json now lists: $(jq -r '[.list[]?.version] | join(", ")' "$pl")"
  fi

  local feed
  for feed in "$WEB_ROOT/package-feed.xml" "$WEB_ROOT/publication-feed.xml"; do
    [ -f "$feed" ] || continue
    python3 - "$feed" "$IG_CANONICAL/$version/" <<'PY'
import re, sys
path, prefix = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
kept, dropped = [], 0
pos = 0
out = []
for m in re.finditer(r"[ \t]*<item>.*?</item>\n?", text, re.S):
    item = m.group(0)
    if prefix in item:
        out.append(text[pos:m.start()])
        pos = m.end()
        dropped += 1
out.append(text[pos:])
if dropped:
    open(path, "w", encoding="utf-8").write("".join(out))
print("  %s: dropped %d item(s)" % (path, dropped), file=sys.stderr)
PY
  done

  # package-registry.json is derived from the per-guide package-list.json files,
  # so recompute this guide's entry from the file we just rewrote rather than
  # guessing. `publisher.jar -generate-package-registry <web root>` rebuilds the
  # whole file if you would rather have the publisher do it.
  local reg="$WEB_ROOT/package-registry.json"
  if [ -f "$reg" ]; then
    local newest_now latest_path latest_date
    newest_now="$(newest_published "$pl")"
    if [ -z "$newest_now" ]; then
      jq --arg pid "$IG_ID" '.packages |= map(select(.["package-id"] != $pid))' "$reg" > "$reg.tmp"
    else
      latest_path="$(jq -r --arg v "$newest_now" '[.list[]? | select(.version == $v)][0].path // ""' "$pl")"
      latest_date="$(jq -r --arg v "$newest_now" '[.list[]? | select(.version == $v)][0].date // ""' "$pl")"
      jq --arg pid "$IG_ID" --arg v "$newest_now" --arg p "$latest_path" --arg d "$latest_date" \
         --argjson n "$(jq '[.list[]?.version | select(. != "current")] | length' "$pl")" '
         .packages |= map(if .["package-id"] == $pid
                          then .["version-count"] = $n
                             | .latest    = {version: $v, date: $d, path: $p}
                             | .milestone = {version: $v, date: $d, path: $p}
                          else . end)' "$reg" > "$reg.tmp"
    fi
    mv "$reg.tmp" "$reg"
    log "  package-registry.json recomputed for $IG_ID"
  fi

  log "rollback of $IG_ID#$version finished"
}

notify() {
  command -v notify-send >/dev/null 2>&1 && notify-send "$@" || true
}
