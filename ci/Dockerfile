# DHP FHIR IG build/publish image.
#
# Base: hl7fhir/ig-publisher-base (Ubuntu 24.04, Temurin JDK 21, Node 22,
# Ruby 3.2 + Jekyll 4.4.1, git, curl). That image installs fsh-sushi at
# container start from its entrypoint, which needs the network on every run and
# gives a different SUSHI on every build. We pin SUSHI here instead and replace
# the entrypoint, so the container starts offline-capable and reproducible.
#
# Missing from the base and added here: fsh-sushi, jq, rsync, unzip, zip,
# gettext-base (envsubst), python3 (throwaway static server for smoke tests),
# ca-certificates refresh.

FROM hl7fhir/ig-publisher-base:latest

ARG SUSHI_VERSION=3.20.1

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      jq rsync unzip zip gettext-base python3 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g fsh-sushi@${SUSHI_VERSION} \
 && npm cache clean --force \
 && sushi --version

# The IG publisher and SUSHI both read the FHIR package cache from
# $XDG_CACHE_HOME/.fhir or ~/.fhir. CI mounts a dedicated cache at /fhir-cache
# so parallel builds never contend on a shared ~/.fhir lock file.
ENV FHIR_PACKAGE_CACHE=/fhir-cache
ENV JAVA_TOOL_OPTIONS=-Xmx12g
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Run as the invoking user (docker run --user "$(id -u):$(id -g)") so everything
# written into the mounted volumes is owned by the host user. HOME is forced to
# a writable path because an unknown uid has no passwd entry.
COPY entrypoint.sh /usr/local/bin/dhp-entrypoint.sh
RUN chmod +x /usr/local/bin/dhp-entrypoint.sh \
 && mkdir -p /home/anyuser /fhir-cache \
 && chmod 0777 /home/anyuser /fhir-cache \
 # -auto-ig-build switches the publisher to the machine-wide package cache at
 # /var/lib/.fhir and ignores user.home entirely. Without this link it dies with
 # an NPE out of FilesystemPackageCacheManager before it reads anything.
 && ln -sfn /fhir-cache /var/lib/.fhir

ENV HOME=/home/anyuser
WORKDIR /src

# A non-root default user, for callers that pass none. `docker run --user`
# still overrides it, and ci/run.sh passes the invoking user; what this covers
# is a plain `docker run` and any CI or compose service that forgets. The
# default used to be root (inherited from the base image, and from the USER
# root above, which nothing switched back), which is why the published site was
# owned by uid 0: no host account could touch data/webroot without sudo, and
# any code in a checked-out branch ran as root with the web root mounted
# read-write.
#
# 1001 is the base image's `publisher` account, so it has a passwd entry, and
# it is the uid that owns the mounted data tree on this host - the same value
# the runner sets with `user = "1001:1001"` under [runners.docker] (see
# infra/runner-config/config.toml). Keep the three in step: the Dockerfile
# default, the runner config, and `stat -c '%u:%g' data/webroot`. They diverged
# once, with 1000 here and 1001 everywhere else, and the symptom was a compose
# service on this image failing to read a mode-600 file it owned.
#
# On a host where the data tree is owned by some other uid, the runner's
# `user =` is what has to change; this line only has to be non-root.
# $HOME is /home/anyuser, mode 0777, so any uid works either way.
USER 1001:1001

ENTRYPOINT ["/usr/local/bin/dhp-entrypoint.sh"]
CMD ["bash"]
