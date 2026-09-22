# Publishing the DHP FHIR Implementation Guides from GitLab

This turns the current single continuous build into an HL7-style publication: every `X.Y.Z` tag becomes a
permanent versioned release, the root of each guide serves the newest release, and there is a history page,
a version list and package feeds. The continuous build of `main` keeps running, at a new address. Do the
steps in order; each ends with a check.

## 1. What you get

These must answer 200 when you are done, for `core` and again for `integrations`:

```
https://dhp.uz/fhir/core/                                latest release (language redirect stub)
https://dhp.uz/fhir/core/{en,ru,uz}/index.html           latest release, per language
https://dhp.uz/fhir/core/0.9.2/{en,ru,uz}/index.html     one folder per released version, e.g. 0.9.1, 0.9.2
https://dhp.uz/fhir/core/history.html                    all versions
https://dhp.uz/fhir/core/package-list.json               machine-readable version list
https://dhp.uz/fhir/core/package.tgz                     latest release, and .../0.9.2/package.tgz per version
https://dhp.uz/fhir/core/ci-build/{en,ru,uz}/index.html  continuous build of main, + ci-build-info.json
```

Plus four site-level files shared by both guides: `https://dhp.uz/package-feed.xml`,
`publication-feed.xml`, `package-registry.json`, `publish-setup.json`. Today
`https://dhp.uz/fhir/core/en/index.html` is the continuous build; afterwards it moves to `/ci-build/` and
the root serves the latest release.

## 2. Prerequisites

- GitLab Premium or Ultimate; pull mirroring is not in Free/CE. Known to work on GitLab EE 19.4.0-ee,
  Runner 19.4.0, Docker 28.3.3. An activation code is a cloud licence and needs the instance to reach
  `customers.gitlab.com`; an instance with no outbound internet needs a licence *file*.
- One runner, docker executor, `concurrent = 1`, tag `dhp`. No memory limit, or one above 12 GB - the
  publisher runs with a 12 GB heap. `docker compose` on the GitLab host too, for the mirror ticker.
- Disk: about 2.7 GB in the web root per core release, half that per integrations release, plus 12 GB free
  for temp, which peaks around 11 GB and grows as versions accumulate, because publishing version N copies
  every earlier version through temp. Caches add a few GB.
- Outbound network from job containers:

  | Host | For |
  |---|---|
  | `github.com` | mirroring, `publisher.jar`, and the clones step 6 makes (HL7/fhir-ig-history-template, FHIR/ig-registry, HL7/fhir-web-templates) |
  | `tx.fhir.org` | terminology validation |
  | `packages.fhir.org` | FHIR packages and the IG template `fhir2.base.template#current`. Its root answers 404, so test with a real package path, not `/` |
  | `packages2.fhir.org` | the publisher's secondary package server |
  | `hl7.org` | not needed by readers - `history.js` is vendored into the web root (step 7) |
  | Docker Hub, `registry.npmjs.org`, Ubuntu apt | only when building the image in step 4 |
  | `customers.gitlab.com` | only for an online activation code |

## 3. Mirror GitHub into GitLab

GitHub stays the source of truth. Set this per mirror project, in Settings > Repository > Mirroring
repositories or over the API - note `mirror_trigger_builds`, the UI's "Trigger pipelines for mirror
updates":

```sh
curl --header "PRIVATE-TOKEN: $TOKEN" -X PUT \
  --form "import_url=https://github.com/uzinfocom-org/digital-health-ig.git" \
  --form "mirror=true" --form "mirror_trigger_builds=true" \
  --form "only_mirror_protected_branches=false" \
  --form "mirror_overwrites_diverged_branches=false" \
  "https://<gitlab>/api/v4/projects/<id>"
```

`infra/scripts/enable-pull-mirror.sh both` does this for both projects and polls until the first pull
settles; its forced pull sends `force=true`, which also clears a mirror that has already hard-failed.

Check: `GET /projects/<id>/mirror/pull` reports `update_status: finished` and `last_error: null`, and the
branch and tag counts match GitHub. The GitLab-only `ci` branch from step 8 survives mirror updates: a ref
deleted in GitLab comes back on the next pull, a GitLab-only ref is left alone.

GitLab's own polling is enough: a tag is picked up within 30 minutes and the pipeline starts on its own.
Faster is preferable, so a release does not sit unpublished for half an hour, but it is not required.

<details>
<summary>Getting tags picked up faster than 30 minutes</summary>

Native polling has a hard floor of 30 minutes (`Gitlab::Mirror::MIN_DELAY` is a constant, not a setting).
Two ways to shorten it, both using a per-project access token, `api`-scoped at Maintainer with an expiry -
the narrowest thing that works on 19.4, since a Developer-level token gets 403 on `mirror/pull`.

1. A GitHub push webhook, if GitHub can reach the instance. Payload URL
   `https://<gitlab>/api/v4/projects/<id>/mirror/pull` with no query string, content type
   `application/json`, "Just the push event", and GitHub's Secret field set to that project's
   `external_webhook_token` from the hardening section - GitLab verifies GitHub's `X-Hub-Signature`, so no adapter is
   needed. Never put `?private_token=<token>` in a webhook URL: that is a full API credential, stored in
   GitHub's webhook configuration and echoed in its delivery log. To test without GitHub - a correct
   signature answers 200, a wrong one 404 (an invalid signature, not a wrong URL), a missing one 401:

   ```sh
   sig=$(openssl dgst -sha1 -hmac "$GITHUB_WEBHOOK_SECRET_1" -hex < payload.json | sed 's/^.* //')
   curl -i -X POST https://<gitlab>/api/v4/projects/1/mirror/pull \
     --header "Content-Type: application/json" --header "X-GitHub-Event: push" \
     --header "X-Hub-Signature: sha1=$sig" --data-binary @payload.json
   ```

2. A ticker forcing a pull on a schedule, for when GitHub cannot reach the instance. As a compose service
   the docker daemon brings it back after a reboot and a failing pull shows up in `docker ps`. Add this to
   your compose file, with `infra/mirror-tick/tick.sh` beside it:

   ```yaml
     mirror-tick:
       image: ${MIRROR_TICK_IMAGE:-dhp-ig-publisher:local}
       container_name: dhp-gl-mirror-tick
       restart: unless-stopped
       depends_on:
         - gitlab
       networks:
         - dhp-gl-net
       entrypoint: ["/bin/sh", "/usr/local/bin/tick.sh"]
       user: ${MIRROR_TICK_USER:-1001:1001}
       environment:
         API: ${GITLAB_EXTERNAL_URL}/api/v4
         INTERVAL: ${MIRROR_TICK_INTERVAL:-15}
         TOKEN_FILE: /run/secrets/mirror-tokens
       volumes:
         - ./mirror-tick/tick.sh:/usr/local/bin/tick.sh:ro
         - ./.mirror-tokens:/run/secrets/mirror-tokens:ro
       healthcheck:
         test: ["CMD-SHELL", "test ! -f /tmp/mirror-tick-unhealthy"]
         interval: 30s
         timeout: 5s
         retries: 2
         start_period: 30s
   ```

   `networks:` must be the network your GitLab service is on, and `container_name` must match
   `60-mirror-ticker.sh`, which has `dhp-gl-mirror-tick` fixed in it - rename in both or in neither. Drive
   the service through the wrapper, never `docker compose` directly:

   ```sh
   infra/scripts/60-mirror-ticker.sh start    # create tokens, write the token file, compose up --no-deps
   infra/scripts/60-mirror-ticker.sh health   # exits 1 if anything is wrong - put this in a monitor
   infra/scripts/60-mirror-ticker.sh stop     # stops this one service, not the stack
   ```

   `once`, `status` and `logs` are there too. Notes on the running service:

   - The wrapper exports `MIRROR_TICK_USER="$(id -u):$(id -g)"` so the container can read the token file,
     which is mode 600 and owned by whoever ran `start`. A bare `docker compose up -d mirror-tick` falls
     back to the literal `1001:1001` and the loop then flags itself unhealthy without ever pulling. If a
     pre-compose `docker run` ticker is still around, `start` refuses until you
     `docker rm -f dhp-gl-mirror-tick`.
   - Tokens arrive on the mounted `infra/.mirror-tokens` (written from `.env` by `start`), not through
     `environment:`, where `docker inspect` would hand them to anyone in the docker group.
   - The loop writes `/tmp/mirror-tick-unhealthy` on any non-200 forced pull and removes it on a 200, so
     the healthcheck fires within a minute of mirroring breaking. It sends `force=true`, because an
     unforced tick after a failed pull is a no-op for 30 minutes and 14 consecutive failures hard-fail the
     mirror, silently if outgoing mail is off.
   - `health` exits 1 on a mirror error, a mirror that never updated, a last success older than
     `MIRROR_STALE_SECONDS` (600) or an expired token, and warns `MIRROR_EXPIRY_WARN_DAYS` (14) out.

   Forced pulls are rate-limited by the plan limit `pull_mirror_interval_seconds` (default 300), which is
   not in the plan-limits API and must be lowered from the rails console:

   ```sh
   gitlab-rails runner 'Plan.default.actual_limits.update!(pull_mirror_interval_seconds: 30)'
   ```

   Tick faster than the limit, not at it - a 30 s limit with a 15 s tick gives updates about a minute
   apart. Pulls that change nothing create no pipelines.

</details>

Fallback for an unlicensed or CE instance, and for the initial population: `infra/scripts/manual-sync.sh
both` fetches both repos from GitHub into bare mirrors and pushes branches and tags into GitLab without
pruning, so GitLab-only refs survive. Run it from cron.

## 4. Build the job image

```sh
docker build -t dhp-ig-publisher:local ci/
```

`hl7fhir/ig-publisher-base` plus a pinned SUSHI, `jq`, `rsync`, `unzip`, `zip`, running as `USER 1001:1001`
(step 5). `publisher.jar` is not in the image; the pipeline downloads it into a mounted cache. Put the image
on every runner host (`pull_policy = ["if-not-present"]`), or push it to your registry and change the
`image:` line in `ci/gitlab-ci.yml`. Check: `docker run --rm dhp-ig-publisher:local sushi --version`.

## 5. Runner configuration

```toml
concurrent = 1

[[runners]]
  executor = "docker"
  environment = ["FF_DISABLE_UMASK_FOR_DOCKER_EXECUTOR=true"]
  [runners.docker]
    image = "dhp-ig-publisher:local"
    allowed_images = ["dhp-ig-publisher:local", "dhp-ig-publisher:*"]
    disable_entrypoint_overwrite = true
    pull_policy = ["if-not-present"]
    user = "<uid>:<gid>"
    volumes = [
      "/srv/dhp/webroot:/web:rw",
      "/srv/dhp/fhir-package-cache:/fhir-cache:rw",
      "/srv/dhp/txcache-seed:/txcache-seed-root:rw",
      "/srv/dhp/publisher-cache:/publisher-cache:rw",
      "/srv/dhp/publication:/publication:rw",
      "/srv/dhp/zips:/zips:rw",
    ]
```

- `user` must be the uid:gid owning those host directories - read it with
  `stat -c '%u:%g' /srv/dhp/webroot`, do not copy a number. GitLab CI never passes `--user`, so without it
  the job runs as the image's own `USER` (`1001:1001` in `ci/Dockerfile`, the backstop for callers that
  pass none) while `/web` is mounted read-write.
- `FF_DISABLE_UMASK_FOR_DOCKER_EXECUTOR=true` goes with it: the helper container that clones the repo
  always runs as root and the runner otherwise only applies `umask 0000`, leaving anything already in the
  cached `/builds` volume root-owned; git then fails in `before_script` with `unable to append to
  '.git/logs/refs/...': Permission denied`.
- `allowed_images` and `disable_entrypoint_overwrite` stop a `.gitlab-ci.yml` on any ref naming its own
  image or overriding the entrypoint while `/web` is mounted read-write.
- `concurrent = 1` is load-bearing twice: parallel builds collide on the FHIR package cache lock
  (`#dev.lock`), and it is the only thing stopping a core job and an integrations job writing the shared
  web root at once, since `resource_group` is project-scoped.
- The container paths are the defaults in `ci/lib/common.sh`, so no job needs a path override; host paths
  are absolute because job containers are spawned on the host docker daemon. `/txcache-seed-root` must be
  read-write - each build hands its warmed terminology cache back, and read-only every build pays a cold
  terminology pass, hours on an empty cache.
- Generating `config.toml` from a script is a trap: it carries host-specific paths and the runner's token,
  and replacing the mount list under the build scripts fails silently - `ci-build.sh` writes `/web/...`
  inside the discarded job container, reports the published URL and exits 0.

The runner does not reload `config.toml`, so restart it when pipelines are idle
(`docker restart <runner container>`); `user` does not chown what is already there, so once, afterwards:

```sh
docker volume ls -q --filter name=runner- | xargs -r docker volume rm
docker run --rm -u 0:0 -v /srv/dhp:/d alpine:latest chown -R <uid>:<gid> /d
```

Check the mounts against a running job, not `config.toml` - a runner not restarted after an edit still
uses the old list. `/builds` and `/home/publisher/ig` also appear and are expected:

```sh
docker inspect "$(docker ps --format '{{.Names}}' | grep -- '-concurrent-.*-build$' | head -1)" \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}'
```

## 6. Prepare the web root and publication workspace, once

On the machine that owns the web root, with a checkout of either guide to hand:

```sh
DATA_DIR=/srv/dhp WEB_ROOT_HOST=/srv/dhp/webroot \
  ci/run.sh /path/to/a/guide/checkout setup
```

Idempotent, and it never overwrites a file it already wrote. The web root gets `publish-setup.json` (layout
rule `uz.dhp.* -> https://dhp.uz/fhir/{3}`, covering both guides and any future one), empty
`package-feed.xml` and `publication-feed.xml`, `package-registry.json`, placeholder `index.html` and
`fhir/license.html`, and the vendored history assets under `fhir/assets-hist/`. `/srv/dhp/publication` gets
clones of HL7/fhir-ig-history-template and FHIR/ig-registry, a `templates/` seeded from
HL7/fhir-web-templates, and an empty `temp/`. Two content jobs are yours:

- `templates/` is HL7's site chrome, so released pages and `history.html` carry the HL7 logo and a link to
  hl7.org. Edit `preamble.template`, `header.template`, `postamble.template` and the images in place;
  nothing re-copies over them.
- `index.html` and `fhir/license.html` are placeholders written only if absent - the publisher writes
  neither, and `history.html` links to a `license.html` that would otherwise 404.

Check: the four machine-readable files exist in the web root and `publication/` has its four
subdirectories. `release.sh` refuses to start without them.

## 7. Web server

Serve the web root at `https://dhp.uz/`, so `/fhir/core/...` maps to `<webroot>/fhir/core/...`, with:

- `.tgz` served as `application/gzip`; `.json` and `.xml` from the stock mime map.
- `Cache-Control: no-store`, at least for the continuous build - it is rewritten on every commit to `main`.
- No dependency on `hl7.org`: `history.html` renders its version table client-side from `history.js` and
  `history-cm.js`, which step 6 vendors under `fhir/assets-hist/` and the pipeline points every
  `history.html` at.
- Canonical-URL resolution (`https://dhp.uz/fhir/core/StructureDefinition/X` returning the page or the
  JSON depending on `Accept`) is a web server job; the publisher cannot do it and the pipeline does not try.

## 8. Put the pipeline on the `ci` branch

The pipeline lives on a GitLab-only `ci` branch, so nothing in the mirrored content changes. Two mechanisms
point there: `ci_config_path` (step 10, or the hardening script), and a `.gitlab-ci.yml` in each repo that only `include:`s the
same file, as a fallback if `ci_config_path` is ever cleared. Jobs fetch the branch at run time and unpack
`ci/` outside the work tree, so the checkout stays as the tag has it - `-go-publish` copies the whole
source folder into the release.

1. Create the branch and protect it, so a stray push cannot clobber it:

   ```sh
   curl --header "PRIVATE-TOKEN: $TOKEN" -X POST --form "branch=ci" --form "ref=main" \
     "https://<gitlab>/api/v4/projects/<id>/repository/branches"

   curl --header "PRIVATE-TOKEN: $TOKEN" -X POST \
     --form "name=ci" --form "push_access_level=40" --form "merge_access_level=40" \
     --form "allow_force_push=false" "https://<gitlab>/api/v4/projects/<id>/protected_branches"
   ```

   In production point the jobs at an immutable ref: set `DHP_CI_REF` (a project CI/CD variable, default
   `ci`) to a tag of the `ci` branch. Jobs probe branch then tag, and the commit used is recorded as
   `DHP_CI_SHA` in `ci-build-info.json` and `publication-request.json`.

   Branching off `main` leaves a frozen copy of the guide on `ci` that nothing reads. On a fresh project
   prefer an orphan branch holding only `/.gitlab-ci.yml` and `ci/` (`git checkout --orphan ci`, then
   push; the Commits API cannot express "no parent"). Reshaping an existing `ci` branch is a force push to
   a protected branch - do it with no pipeline running, and re-protect afterwards.

2. Put these files on it, in both projects, with the executable bit on the `.sh` ones:

   ```
   /.gitlab-ci.yml   <- ci/gitlab-ci.yml
   /ci/ci-build.sh  /ci/release.sh  /ci/setup-webroot.sh  /ci/verify-site.sh
   /ci/run.sh  /ci/lib/common.sh  /ci/Dockerfile  /ci/entrypoint.sh
   ```

   `infra/scripts/36-publish-ci-scripts.sh [core|integration|both]` does it through the API, idempotently.
   Keep the two branches identical: nothing in these scripts is guide-specific - package id, canonical URL,
   version and title all come from the checked-out `sushi-config.yaml` - but it publishes to one project at
   a time.

The rules: no pipeline at all on the `ci` branch itself, so pushing scripts creates no job-less failed
pipelines; `ci-build` on the default branch, deploying to `/fhir/<ig>/ci-build/`, 3 h timeout; `release` on
tags matching `^\d+\.\d+\.\d+$` (bare semver, no `v` prefix), which builds and then runs `-go-publish`,
6 h timeout. Both jobs carry `resource_group: dhp-webroot` and `interruptible: false`, and keep
`output/qa.html`, `qa.txt` and `qa.json` as artifacts for a week. Changing a script later is a commit on
the `ci` branch - no image rebuild, nothing to install on the runner.

`ci/.gitlab-ci.yml` is the same pipeline for the arrangement where `ci/` is committed into the IG
repository itself, for use once the MOH owns the repositories. Do not publish it to the `ci` branch: a
project with both definitions would have two pipelines.

Check: pushing to `ci` creates no pipeline; a pipeline on `main` starts a `ci-build` job.

## 9. First continuous build

Set `CI_BUILD_REPO_URL` as a CI/CD variable on both projects, to the public GitHub URL of that guide: the
publish box cites the repository the build came from, and the default is `CI_PROJECT_URL`, your internal
GitLab host, which should not appear on a public page. Then run a pipeline on `main` in each project
(Build > Pipelines > Run pipeline, or `infra/scripts/45-trigger-pipeline.sh core main`). Expect 20-25 min.

Check: `https://dhp.uz/fhir/core/ci-build/en/index.html` answers 200 and its publish box says the guide is
a continuous build, citing that absolute URL - not "Local Development build", not "Publish Box goes here".
The job fails if either slips through.

Once each project has run one pipeline, run `infra/scripts/37-resource-group-mode.sh both`, once per
instance. Both jobs share `resource_group: dhp-webroot`, whose default mode is `unordered`: two tags pushed
together are not guaranteed to publish in order, and publishing 0.9.1 after 0.9.2 would leave the canonical
URL serving 0.9.1. `oldest_first` fixes it, and the API only knows a resource group once a job has used it.

## 10. Backfill the versions you want to keep

Publish oldest first, one at a time, waiting for each: the publisher rewrites every earlier version's
publish box from `package-list.json`. `release.sh` refuses a version that already has a folder or a
`package-list.json` entry, and one older than the newest published unless you pass `PUB_MODE=working`,
which publishes into the version folder without taking over the canonical URL. Core has tags back to
0.1.0 and each core release costs 73-93 min and about 2.7 GB, so decide how far back to go first.

Old tags predate `.gitlab-ci.yml` and could not start a pipeline at all (core 0.1.0 to 0.6.0, integrations
0.7.0 and 0.8.0). GitLab reports that as `The pipeline did not run. Review the workflow:rules
configuration`, which points at the wrong thing - the ref simply has no CI config, and `ci_config_path`
solves it. By hand it is Settings > CI/CD > General pipelines > "CI/CD configuration file", or:

```sh
curl --header "PRIVATE-TOKEN: $TOKEN" -X PUT \
  --form 'ci_config_path=.gitlab-ci.yml@<project path>:ci' "https://<gitlab>/api/v4/projects/<id>"
```

`--form 'ci_config_path='` clears it, but do not, other than to debug: it is what stops a mirrored ref
defining its own jobs.

The QA gate is opt-in. `FAIL_ON_QA_ERRORS` defaults to off in `ci-build.sh` and `release.sh`, because the
limits are already enforced on the GitHub side, where a failing check blocks the PR and the author can fix
it. Turn it on for a run - a first release after a big terminology change, say - with Run pipeline and
variable `FAIL_ON_QA_ERRORS` = `1`, which takes an Owner once the projects are hardened, or:

```sh
infra/scripts/45-trigger-pipeline.sh integration 0.9.0 nowait FAIL_ON_QA_ERRORS=1
```

When it fires, nothing is written to the web root; read `output/qa.json` from the job artifacts.

Check after each release: `verify-site.sh` (step 11), and `https://dhp.uz/fhir/<ig>/package-list.json`
lists the new version with `"current": true`.

## 11. Verifying the site

```sh
VERIFY_BASE=https://dhp.uz ci/verify-site.sh - core         0.9.1 0.9.2
VERIFY_BASE=https://dhp.uz ci/verify-site.sh - integrations 0.8.0 0.9.0
```

The last two arguments are the older and the newer of two published versions. It checks about 30 URLs per
guide, exits non-zero if a required one is not 200, and checks the four publish-box statements (current
published version, permanent home, superseded-by link, continuous build with an absolute source link),
which are easy to get wrong and silent when they are. The only expected 301s are `/fhir/core` and
`/fhir/integrations` without a trailing slash.

## 12. Troubleshooting

- A tag produced no pipeline, with "Review the workflow:rules configuration": that ref has no
  `.gitlab-ci.yml`. Set `ci_config_path` (step 10).
- Every pipeline fails at once on a missing configuration file or an unresolvable `include:`: the `ci`
  branch does not exist yet, is renamed, or the project path does not match.
- Tags or commits stopped arriving and no job failed: the mirror is hard-failed, which is silent with
  outgoing mail off. `60-mirror-ticker.sh health` names it; after a protected-ref change check the tag
  counts too (hardening section).
- A pipeline is rejected when you pass a variable on the Run pipeline form: that needs Owner once the projects are hardened.
- The published build reports more errors than the pipeline's build did: expected, `-go-publish` rebuilds
  with `-resetTx` and asks tx.fhir.org questions the warm CI build did not. Both numbers are in the job
  log, the detail in `https://dhp.uz/fhir/<ig>/qa.html`, and it does not fail on them.
- A build takes hours instead of 25 minutes: the terminology cache is cold. Check `/txcache-seed-root` is
  mounted read-write and the log does not say "not writable, not saving".
- The ci-build publish box says "Local Development build", or the job dies in the publish-box check: the
  build did not get `-auto-ig-build`, or `-repo` got something that is not an absolute URL.
- `GET /projects/<id>/mirror/pull` says `update_status: none` with null timestamps: not a failure, the
  mirror worker has not run yet.

## 13. The scripts in this directory

```
ci/Dockerfile                        build image (SUSHI pinned, jq, rsync, own entrypoint)
ci/entrypoint.sh                     image entrypoint; GitLab CI replaces it, so lib/common.sh repeats it
ci/lib/common.sh                     shared helpers; reads sushi-config.yaml for everything IG-specific
ci/setup-webroot.sh                  one-off web root + publication workspace (step 6)
ci/ci-build.sh                       build and deploy the continuous build
ci/release.sh <version>              verify, build, -go-publish (QA gate opt-in, step 10)
ci/release-rollback.sh <version>     undo one publication in the web root
ci/verify-site.sh                    curl the URLs that must work (step 11)
ci/run.sh                            docker run wrapper with the CI volume layout
ci/gitlab-ci.yml                     the pipeline, as /.gitlab-ci.yml on the `ci` branch
ci/.gitlab-ci.yml                    same pipeline for a repo that carries ci/ itself (step 8)
infra/scripts/lib.sh                 shared env + API helpers for the scripts below
infra/scripts/38-harden-projects.sh  apply|show the project settings of the hardening section
infra/scripts/37-resource-group-mode.sh  set dhp-webroot to oldest_first (step 9)
infra/scripts/enable-pull-mirror.sh  turn on pull mirroring for both projects
infra/scripts/60-mirror-ticker.sh    start|stop|health|status|once|logs - the mirror ticker
infra/mirror-tick/tick.sh            the ticker loop, mounted read-only into the container
infra/scripts/manual-sync.sh         CE/unlicensed fallback: fetch GitHub, push to GitLab
infra/scripts/45-trigger-pipeline.sh trigger a pipeline on a ref, optionally with variables
infra/scripts/36-publish-ci-scripts.sh push ci/ to the `ci` branch of both projects
```

The `infra/scripts/*` ones all source `lib.sh`, which reads an `infra/.env` beside the `scripts/`
directory and exits if it is missing. No file with real values ships here; create one with these keys:

```
GITLAB_EXTERNAL_URL=https://<your gitlab>
GITLAB_ROOT_TOKEN=<admin personal access token, api scope>
CORE_PROJECT_PATH=moh/dhp/deploy/fhir/igs/digital-health
INTEGRATION_PROJECT_PATH=moh/e-health/dhp/deployment/fhir/implementation-guides/digital-health-integration
CORE_GITHUB_URL=https://github.com/uzinfocom-org/digital-health-ig.git
INTEGRATION_GITHUB_URL=https://github.com/uzinfocom-org/digital-health-integration.git
CORE_PROJECT_ID=<numeric id>
INTEGRATION_PROJECT_ID=<numeric id>
GITLAB_HOST=<host>            # manual-sync.sh only
GITLAB_HTTP_PORT=<port>       # manual-sync.sh only
```

Optional, all with working defaults: `GITHUB_WEBHOOK_SECRET_<project id>` (per project, enables the HMAC
webhook route in step 3 - generate with `openssl rand -hex 16`), `MIRROR_TICK_INTERVAL` and
`MIRROR_TICK_IMAGE` (read by the compose service), `MIRROR_STALE_SECONDS` and `MIRROR_EXPIRY_WARN_DAYS`
(thresholds for `health`), `MAIN_PUSH_ACCESS_LEVEL` and `MAIN_MERGE_ACCESS_LEVEL` (hardening, default 40),
`GITLAB_CONTAINER`, `RUNNER_JOB_USER`. `60-mirror-ticker.sh` writes `CORE_MIRROR_TOKEN` and
`INTEGRATION_MIRROR_TOKEN` back into `.env` when it creates the project access tokens, and renders both
into `infra/.mirror-tokens` (mode 600); both files are gitignored.

Defaults to check before use:

- `60-mirror-ticker.sh` runs `docker compose` in the directory above `scripts/`, so it expects your
  `mirror-tick` service in `infra/docker-compose.yml` and the token file at `infra/.mirror-tokens`. The
  container name `dhp-gl-mirror-tick` is fixed in it. `MIRROR_TICK_IMAGE`, `MIRROR_TICK_INTERVAL` (15 s)
  and the printed-only `MIRROR_RATE_LIMIT` (the real limit is the rails setting in step 3) are overridable.
- `38-harden-projects.sh` reaches `gitlab-rails` with `docker exec dhp-gl-gitlab` for the webhook token
  only: set `GITLAB_CONTAINER`, or on omnibus make that call `sudo gitlab-rails`.
- `manual-sync.sh` builds its push URL as `http://root:$GITLAB_ROOT_TOKEN@$GITLAB_HOST:$GITLAB_HTTP_PORT/...`;
  on a real instance that has to be `https` and the user may not be `root` - edit the `push_url` line.
- `ci/run.sh` has no usable default `DATA_DIR`, so pass it, as step 6 does, along with `WEB_ROOT_HOST` and
  `IMAGE`.
- `ci/lib/common.sh` and `ci/setup-webroot.sh` default `SITE_URL` to `https://dhp.uz`, and
  `verify-site.sh` looks for `https://dhp.uz` links in published pages - change them if the site moves. The
  `http://localhost:8088` in `verify-site.sh`'s usage comment is an example `VERIFY_BASE`, not a setting.

Before debugging a job that stopped: `jq` is required and `$WEB_ROOT` must be a real mount, so a job that
would otherwise write the site into its own container filesystem stops instead
(`WEB_ROOT_MOUNT_OPTIONAL=1` overrides); publications serialise on `$WEB_ROOT/.publish.lock` with `flock`
for up to `WEB_LOCK_WAIT`; and both jobs check free space first, about 20 GB for temp and for the web root.
A half-published release is recoverable with `ci/release-rollback.sh <version> --yes`, which removes that
version folder and its entries from `package-list.json`, both site feeds and `package-registry.json`,
re-pointing `current` at the newest version left; then retry with `ALLOW_REPUBLISH=1`.

Other environment variables the scripts read, with defaults: `CI_BUILD_REPO_URL` (`CI_PROJECT_URL`),
`DHP_CI_REF` (`ci`), `PUB_MODE` (`milestone`), `FAIL_ON_QA_ERRORS` (`0`; `0`, `false`, `no` and `off` mean
off and anything else means on, so a typo leaves the gate on), `GATE_WARM_TXCACHE` (`0`), `ALLOW_REPUBLISH`
(`0`), `ROLLBACK_ASSUME_YES` (`0`), `KEEP_ZIP` (`0`), `NEED_TEMP_GB` and `NEED_WEB_GB` (`20`),
`WEB_ROOT_MOUNT_OPTIONAL` (`0`), `WEB_LOCK_WAIT` (`21600`), `PUBLISHER_VERSION` (unset, latest),
`PUBLISHER_REFRESH` (`0`), `STAGING_DIR` (`$WEB_ROOT/.staging`), `HIST_ASSETS_DIR`
(`$WEB_ROOT/fhir/assets-hist`).

## 14. State that lives only in GitLab

A fresh deployment, a restored backup or a rebuilt runner inherits none of this: the hardening settings on
both projects; `allowed_images`, `disable_entrypoint_overwrite`, `user` and
`FF_DISABLE_UMASK_FOR_DOCKER_EXECUTOR=true` in the live `config.toml`, with the restart, cache-volume
removal and chown of step 5; `CI_BUILD_REPO_URL`, `DHP_CI_REF` and the resource-group mode of steps 8 and
10; and the webhook secret of step 3. Two things need attention over time: outgoing mail enabled or
`60-mirror-ticker.sh health` on a schedule, because a hard-failed mirror is otherwise completely silent,
and the two mirror tokens rotated before they expire, staying `api`-scoped at Maintainer.

## Optional: harden the two projects

Not needed for the site to work, but recommended: these settings decide whether a mirrored branch can run
code on your runner and whether anyone can publish a version. `infra/scripts/38-harden-projects.sh` applies
them to both projects, idempotently; `show` changes nothing. Run it after creating the projects, and after
any change made by hand.

```sh
infra/scripts/38-harden-projects.sh show     # read-only, run this first
infra/scripts/38-harden-projects.sh          # apply
```

Per project it sets:

- `ci_config_path = .gitlab-ci.yml@<this project>:ci`. Without it GitLab reads `.gitlab-ci.yml` from the
  pushed ref, so any mirrored branch can define its own jobs and run them with the web root mounted
  read-write. It also lets old tags that carry no CI config build at all (step 10).
- `public_jobs = false`: job logs and QA artifacts stop being readable by every signed-in user.
- `ci_pipeline_variables_minimum_override_role = owner`: a Developer can no longer pass
  `FAIL_ON_QA_ERRORS`, `SKIP_DEPLOY`, `WEB_ROOT` or `PUB_MODE` on the Run pipeline form. Defaults still
  come from `.gitlab-ci.yml` on the `ci` branch and from CI/CD settings.
- A protected tag rule `*` at create = Maintainer (40), since pushing an `X.Y.Z` tag is all it takes to
  publish. Maintainer and not "No one" (0): the mirror creates tags as the mirror user, level 0 is refused
  for everybody, and a rule the mirror user cannot satisfy makes GitLab delete the matching tags and
  hard-fail the mirror. `main` stays at push and merge = 40 for the same reason.
- `external_webhook_token`, only when `GITHUB_WEBHOOK_SECRET_<project id>` is in `.env` (step 3).

All of it goes in over REST except the webhook token, which has no REST setter: that call is
`docker exec $GITLAB_CONTAINER gitlab-rails` (default `dhp-gl-gitlab`; set `GITLAB_CONTAINER` in `.env` if
your container has another name), or `sudo gitlab-rails` on an omnibus install.

Check: `show` prints both projects side by side. Then force a pull, run
`infra/scripts/60-mirror-ticker.sh health`, and compare tag counts against GitHub - a protected-ref rule
the mirror cannot satisfy deletes tags, so this is the one check not to skip.

## Not validated

- A real webhook delivery from GitHub: the HMAC route was only exercised with hand-signed payloads.
- A genuinely new upstream commit or tag arriving through the mirror: refs were deleted in GitLab and
  restored by a pull instead, which is the same code path.
- Your web server configuration: the site was only served with an `nginx:alpine` container.
