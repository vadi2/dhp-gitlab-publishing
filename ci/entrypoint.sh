#!/usr/bin/env bash
# Entrypoint for the DHP IG build image.
#
# Replaces the base image entrypoint, which cloned ig-publisher-scripts and ran
# `npm install -g fsh-sushi` on every container start. Both are already in the
# image, and both need the network.
#
# Responsibilities:
#   - give the (possibly passwd-less) uid a usable HOME
#   - point the FHIR package cache at the dedicated mount instead of ~/.fhir
set -euo pipefail

export HOME="${HOME:-/home/anyuser}"
if [ ! -w "$HOME" ]; then
  export HOME=/tmp/home
  mkdir -p "$HOME"
fi

# The publisher resolves the package cache as <user.home>/.fhir. Java takes
# user.home from the passwd entry, not $HOME, so set it explicitly too via
# _JAVA_OPTIONS and symlink for the Node tools.
CACHE_DIR="${FHIR_PACKAGE_CACHE:-/fhir-cache}"
mkdir -p "$CACHE_DIR/packages"
if [ ! -e "$HOME/.fhir" ]; then
  ln -sfn "$CACHE_DIR" "$HOME/.fhir"
fi
export _JAVA_OPTIONS="-Duser.home=$HOME ${_JAVA_OPTIONS:-}"

# Git refuses to operate on a checkout owned by another uid otherwise.
git config --global --add safe.directory '*' 2>/dev/null || true

exec "$@"
