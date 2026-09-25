#!/usr/bin/env bash
# Curl the URLs that must work on the published site after a release.
#
#   verify-site.sh <base-url> <ig-code> <older-version> <newer-version>
#   verify-site.sh https://dhp.uz core 0.9.1 0.9.2
#
# Prints one line per URL: <status> <url> [note]. Exits non-zero if any
# required URL is not 200.

set -uo pipefail

BASE="${1:?usage: verify-site.sh <base-url> <ig-code> <older> <newer>}"
IG="${2:?ig code, e.g. core or integrations}"
OLD="${3:?older version}"
NEW="${4:?newer version}"
BASE="${BASE%/}"
echo "checking $BASE"

fail=0

check() {
  local path="$1" want="${2:-200}" note="${3:-}"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$path")
  if [ "$code" = "$want" ]; then
    printf '%s  %s %s\n' "$code" "$path" "$note"
  else
    printf '%s  %s %s   <-- expected %s\n' "$code" "$path" "$note" "$want"
    fail=1
  fi
}

# Which version does a page claim to be? The publish box carries it as
# "(v0.9.2: Releases Draft)" on a release and "for version 0.9.2" on a ci-build.
version_of() {
  curl -s "$BASE$1" \
    | grep -oE '\(v[0-9]+\.[0-9]+\.[0-9]+[^)]*\)|for version [0-9]+\.[0-9]+\.[0-9]+' \
    | sed -n '1p'
}

echo "== current release (should be $NEW) =="
for lang in en ru uz; do
  check "/fhir/$IG/$lang/index.html" 200 "[$(version_of "/fhir/$IG/$lang/index.html")]"
done

echo "== older release $OLD =="
for lang in en ru uz; do
  check "/fhir/$IG/$OLD/$lang/index.html" 200 "[$(version_of "/fhir/$IG/$OLD/$lang/index.html")]"
done

echo "== newer release $NEW =="
for lang in en ru uz; do
  check "/fhir/$IG/$NEW/$lang/index.html" 200 "[$(version_of "/fhir/$IG/$NEW/$lang/index.html")]"
done

echo "== site furniture =="
check "/fhir/$IG/history.html"
check "/fhir/$IG/package-list.json"
check "/fhir/$IG/package.tgz"
check "/fhir/$IG/$OLD/package.tgz"
check "/fhir/$IG/$NEW/package.tgz"
check "/fhir/$IG/ci-build/en/index.html"
check "/fhir/$IG/ci-build/ci-build-info.json"
check "/package-feed.xml"
check "/publication-feed.xml"
check "/package-registry.json"
check "/publish-setup.json"

# Informational only: a server with autoindex on answers a bare directory with
# a listing even when no index.html exists there. The index.html checks below
# are the ones that prove the page is really present.
echo "== directory requests (informational: autoindex may answer these) =="
for p in "/fhir/$IG/" "/fhir/$IG/$OLD/" "/fhir/$IG/$NEW/" "/fhir/$IG/ci-build/" "/fhir/$IG/en/"; do
  check "$p"
done

echo "== root index redirects (multilingual) =="
check "/fhir/$IG/index.html"
check "/fhir/$IG/$OLD/index.html"
check "/fhir/$IG/$NEW/index.html"
check "/fhir/$IG/ci-build/index.html"
for p in "/fhir/$IG/index.html" "/fhir/$IG/$OLD/index.html"; do
  echo "--- $p ---"
  curl -s "$BASE$p" | head -8
done

echo "== history lists both versions =="
for v in "$OLD" "$NEW"; do
  if curl -s "$BASE/fhir/$IG/history.html" | grep -q "$v"; then
    echo "ok    history.html mentions $v"
  else
    echo "FAIL  history.html does not mention $v"; fail=1
  fi
done

# history.html carries the version list as inline JSON, so the check above
# passes even when the page renders empty: the table is drawn by history.js,
# which release.sh points at /fhir/assets-hist/. Every on-site script and the
# license link the page carries have to load.
echo "== history.html scripts and license link load =="
curl -s "$BASE/fhir/$IG/history.html" \
  | grep -oE '(src="[^"]*\.js"|href="[^"]*license\.html")' | sed -E 's/^(src|href)="//; s/"$//' | sort -u \
  | { bad=0
      while read -r ref; do
        case "$ref" in
          http://*|https://*) echo "note  off-site: $ref"; continue ;;
          /*) path="$ref" ;;
          *)  path="$(realpath -m "/fhir/$IG/$ref")" ;;
        esac
        code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$path")
        if [ "$code" = "200" ]; then echo "200  $path"; else echo "$code  $path   <-- expected 200"; bad=1; fi
      done
      exit $bad; } || fail=1

# The page header reads "<version> - <releaseLabel>". A release built from a
# sushi-config.yaml that still says ci-build is labelled a ci-build on every
# page; release.sh now prevents it, relabel-releases.sh repairs older ones.
echo "== page header release label =="
for p in "/fhir/$IG/en/index.html" "/fhir/$IG/$OLD/en/index.html" "/fhir/$IG/$NEW/en/index.html"; do
  label=$(curl -s "$BASE$p" | tr '\n' ' ' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+ - [A-Za-z0-9.+-]+' | sed -n 1p)
  case "$label" in
    *" - ci-build") echo "FAIL  $p header says '$label' - run ci/relabel-releases.sh $IG"; fail=1 ;;
    "")            echo "warn  $p: no '<version> - <label>' in the header - check it by hand" ;;
    *)             echo "ok    $p header says '$label'" ;;
  esac
done

echo "== package-list.json =="
curl -s "$BASE/fhir/$IG/package-list.json" \
  | jq -r '{"package-id", canonical, title, category,
            list: [.list[] | {version, date, status, sequence, current, path}]}' 2>/dev/null \
  || echo "FAIL  package-list.json is not valid JSON"

# Cut the box out with index()/substr() rather than a regex: the page is one
# half-megabyte line once the newlines are gone, and a bounded or greedy regex
# over that is either slow or stops short of the links inside the box. Also no
# `| head -1` anywhere here - head closes the pipe and the upstream stage dies
# of SIGPIPE, which pipefail reports as a failure (gotchas 6 and 15).
publish_box() {
  curl -s "$BASE$1" | awk 'BEGIN{RS="\0"} {
    gsub(/\n/, " ")
    i = index($0, "<p id=\"publish-box\">")
    if (i) { s = substr($0, i); j = index(s, "</p>"); print j ? substr(s, 1, j + 3) : s }
  }'
}

# PublishBoxStatementGenerator writes, for a superseded version:
#   "The current version which supersedes this version is <a ...>NEW</a>"
# and for the one at the canonical:
#   "This is the current published version"
echo "== publish box: older version $OLD (should say it is superseded by $NEW) =="
publish_box "/fhir/$IG/$OLD/en/index.html" | cut -c1-700
if publish_box "/fhir/$IG/$OLD/en/index.html" \
     | grep -q "current version which supersedes this version is.*$NEW"; then
  echo "ok    $OLD says it is superseded by $NEW and links to it"
else
  echo "FAIL  $OLD does not name $NEW as the superseding version"; fail=1
fi

echo "== publish box: current release at the canonical =="
publish_box "/fhir/$IG/en/index.html" | cut -c1-700
if publish_box "/fhir/$IG/en/index.html" | grep -q "This is the current published version"; then
  echo "ok    canonical says it is the current published version"
else
  echo "FAIL  canonical does not say it is the current published version"; fail=1
fi

echo "== publish box: version $NEW in its permanent home =="
publish_box "/fhir/$IG/$NEW/en/index.html" | cut -c1-700
if publish_box "/fhir/$IG/$NEW/en/index.html" | grep -q "permanent home"; then
  echo "ok    $NEW is labelled as the current version in its permanent home"
else
  echo "FAIL  $NEW is not labelled as the current version in its permanent home"; fail=1
fi

echo "== publish box: ci-build =="
publish_box "/fhir/$IG/ci-build/en/index.html" | cut -c1-700
if publish_box "/fhir/$IG/ci-build/en/index.html" | grep -q "Publish Box goes here"; then
  echo "FAIL  ci-build still carries the placeholder publish box"; fail=1
fi
# -repo lands in the box as href AND text; a value without a scheme is a broken
# link on every page of the guide.
# Both quote styles: the publisher emits href='...' on some builds and
# href="..." on others, depending on which fragment the release header went
# through. The sed strips whichever quote character it turns out to be.
ci_href=$(publish_box "/fhir/$IG/ci-build/en/index.html" \
          | grep -oE "href=(\"[^\"]*\"|'[^']*')" | sed -n '1s/^href=.\(.*\).$/\1/p')
case "$ci_href" in
  http://*|https://*) echo "ok    ci-build source link is absolute: $ci_href" ;;
  "") echo "warn  no link in the ci-build publish box - check it by hand" ;;
  *) echo "FAIL  ci-build source link \"$ci_href\" is relative - -repo needs a full URL"; fail=1 ;;
esac

echo "== the 'Directory of published versions' links resolve =="
for p in "/fhir/$IG/$OLD/en/index.html" "/fhir/$IG/en/index.html" "/fhir/$IG/ci-build/en/index.html"; do
  # Only the absolute on-site links matter here; off-site ones are HL7's.
  curl -s "$BASE$p" | grep -oE 'href="https://dhp\.uz[^"]*"' | sort -u \
    | sed 's/href="https:\/\/dhp.uz//; s/"$//' | while read -r l; do
      printf '  %s  (from %s) %s\n' \
        "$(curl -s -o /dev/null -w '%{http_code}' "$BASE$l")" "$p" "$l"
    done
done

exit $fail
