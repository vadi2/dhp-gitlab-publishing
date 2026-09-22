#!/usr/bin/env bash
# Thin `docker run` wrapper: the same volume layout the GitLab runner will use,
# so a local run and a CI job exercise identical script paths.
#
#   run.sh <ig-checkout> setup
#   run.sh <ig-checkout> ci-build
#   run.sh <ig-checkout> release <version>
#   run.sh <ig-checkout> shell
#
# Env: DATA_DIR, WEB_ROOT_HOST, IMAGE, TXCACHE_NAME, CONTAINER_NAME,
#      FAIL_ON_QA_ERRORS, SITE_URL, JAVA_HEAP, plus everything in PASS_ENV below
#      (ALLOW_REPUBLISH, GATE_WARM_TXCACHE, PUB_MODE, ... ) which is forwarded
#      into the container only when set.

set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$(cd "$CI_DIR/../data" && pwd)}"
WEB_ROOT_HOST="${WEB_ROOT_HOST:-$DATA_DIR/webroot-scratch}"
IMAGE="${IMAGE:-dhp-ig-publisher:local}"

SRC_HOST="${1:?usage: run.sh <ig-checkout> <setup|ci-build|release|shell> [args]}"
SRC_HOST="$(cd "$SRC_HOST" && pwd)"
ACTION="${2:?usage: run.sh <ig-checkout> <setup|ci-build|release|shell> [args]}"
shift 2

# Which terminology seed to use: one directory per package id, so core and
# integrations keep separate caches. The GitLab jobs derive it the same way.
[ -f "$SRC_HOST/sushi-config.yaml" ] || \
  { echo "no sushi-config.yaml in $SRC_HOST - is that an IG checkout?" >&2; exit 2; }
PKG_ID="$(sed -n '0,/^id:/s/^id:[[:space:]]*//p' "$SRC_HOST/sushi-config.yaml" | tr -d '\r')"
# An empty id used to fall through: TXCACHE_NAME became empty, and the mkdir
# below created and then mounted $DATA_DIR/txcache-seed itself as /txcache-seed
# - i.e. every guide sharing one cache, which is exactly what the per-id
# directory exists to prevent. The first symptom is cross-contaminated
# terminology results, which is not a symptom anyone traces back to here.
[ -n "$PKG_ID" ] || \
  { echo "no 'id:' in $SRC_HOST/sushi-config.yaml - cannot pick a terminology cache" >&2; exit 2; }
TXCACHE_NAME="${TXCACHE_NAME:-$PKG_ID}"
[ -n "$TXCACHE_NAME" ] || { echo "TXCACHE_NAME is empty" >&2; exit 2; }
mkdir -p "$DATA_DIR/txcache-seed/$TXCACHE_NAME" "$DATA_DIR/zips" \
         "$WEB_ROOT_HOST" "$DATA_DIR/publication/temp" "$DATA_DIR/fhir-package-cache"

CONTAINER_NAME="${CONTAINER_NAME:-dhp-pub-$ACTION-$(date +%s)}"

# Knobs the scripts read from the environment, forwarded only when the caller
# set them. Without this a local run cannot reach them at all: `docker run`
# passes nothing through by default, so e.g. ALLOW_REPUBLISH=1 ci/run.sh ...
# looked like it had been accepted and had no effect inside the container.
PASS_ENV=(
  ALLOW_REPUBLISH
  CI_BUILD_REPO_URL
  CLONE_XML_JSON
  DHP_CI_SHA
  GATE_WARM_TXCACHE
  IG_REPO_URL
  KEEP_PUB_TEMP
  NEED_TEMP_GB
  NEED_WEB_GB
  OFFLINE
  PUBLISHER_REFRESH
  PUBLISHER_VERSION
  PUB_MODE
  PUB_STATUS
  SITE_ORG
  SITE_TITLE
  SKIP_DEPLOY
)
ENV_ARGS=()
for v in "${PASS_ENV[@]}"; do
  [ -n "${!v:-}" ] && ENV_ARGS+=(-e "$v=${!v}")
done

case "$ACTION" in
  setup)    CMD=(/ci/setup-webroot.sh) ;;
  ci-build) CMD=(/ci/ci-build.sh) ;;
  release)  CMD=(/ci/release.sh "$@") ;;
  shell)    CMD=(bash) ;;
  *) echo "unknown action $ACTION" >&2; exit 2 ;;
esac

exec docker run --rm --name "$CONTAINER_NAME" \
  --user "$(id -u):$(id -g)" \
  -v "$CI_DIR:/ci:ro" \
  -v "$SRC_HOST:/src" \
  -v "$WEB_ROOT_HOST:/web" \
  -v "$DATA_DIR/publication:/publication" \
  -v "$DATA_DIR/fhir-package-cache:/fhir-cache" \
  -v "$DATA_DIR/publisher-cache:/publisher-cache" \
  -v "$DATA_DIR/txcache-seed/$TXCACHE_NAME:/txcache-seed" \
  -v "$DATA_DIR/zips:/zips" \
  -e TXCACHE_SEED=/txcache-seed \
  -e IG_SRC=/src -e WEB_ROOT=/web \
  -e IG_HISTORY=/publication/ig-history \
  -e IG_REGISTRY=/publication/ig-registry \
  -e PUB_TEMPLATES=/publication/templates \
  -e PUB_TEMP=/publication/temp \
  -e ZIPS_DIR=/zips \
  -e SITE_URL="${SITE_URL:-https://dhp.uz}" \
  -e JAVA_HEAP="${JAVA_HEAP:--Xmx12g}" \
  -e FAIL_ON_QA_ERRORS="${FAIL_ON_QA_ERRORS:-0}" \
  "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
  "$IMAGE" "${CMD[@]}"
