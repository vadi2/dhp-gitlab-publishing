# Publishing the DHP FHIR Implementation Guides from GitLab

This turns the current single continuous build into an HL7-style publication: every `X.Y.Z` tag becomes a
permanent versioned release, the root of each guide serves the newest release, and there is a history page,
a version list and package feeds. The continuous build of `main` keeps running, at a new address. Do the
steps in order; each ends with a check.

No containers anywhere: the pipeline is shell scripts run by a GitLab runner with the shell executor, on a
host that has the same toolchain the guides' GitHub Actions use.

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

- GitLab Premium or Ultimate; pull mirroring is not in Free/CE. Known to work on GitLab EE 19.4.0-ee and
  Runner 19.4.0. An activation code is a cloud licence and needs the instance to reach
  `customers.gitlab.com`; an instance with no outbound internet needs a licence *file*.
- One runner, shell executor, `concurrent = 1`, tag `dhp` (step 4). Its host needs Java 21, Node with
  `fsh-sushi` (`npm install -g fsh-sushi`), Ruby with `jekyll`, `git`, `curl`, `jq`, `rsync`, `unzip` and
  `zip` - what the guides' GitHub Actions install - and 16 GB of RAM: the publisher runs with a 12 GB heap.
- Disk on the runner host: about 2.7 GB in the web root per core release, half that per integrations
  release, plus 12 GB free for temp, which peaks around 11 GB and grows as versions accumulate, because
  publishing version N copies every earlier version through temp. Caches add a few GB.
- Outbound network from the runner host:

  | Host | For |
  |---|---|
  | `github.com` | mirroring, `publisher.jar`, and the clones step 5 makes (HL7/fhir-ig-history-template, FHIR/ig-registry, HL7/fhir-web-templates) |
  | `tx.fhir.org` | terminology validation |
  | `packages.fhir.org` | FHIR packages and the IG template `fhir2.base.template#current`. Its root answers 404, so test with a real package path, not `/` |
  | `packages2.fhir.org` | the publisher's secondary package server |
  | `hl7.org` | not needed by readers - `history.js` is vendored into the web root (step 6) |
  | `registry.npmjs.org`, `rubygems.org`, apt | only when installing the toolchain |
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
branch and tag counts match GitHub. The GitLab-only `ci` branch from step 7 survives mirror updates: a ref
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
   `external_webhook_token` from the hardening section - GitLab verifies GitHub's `X-Hub-Signature`, so no
   adapter is needed. Never put `?private_token=<token>` in a webhook URL: that is a full API credential,
   stored in GitHub's webhook configuration and echoed in its delivery log. To test without GitHub - a
   correct signature answers 200, a wrong one 404 (an invalid signature, not a wrong URL), a missing one
   401:

   ```sh
   sig=$(openssl dgst -sha1 -hmac "$GITHUB_WEBHOOK_SECRET_1" -hex < payload.json | sed 's/^.* //')
   curl -i -X POST https://<gitlab>/api/v4/projects/1/mirror/pull \
     --header "Content-Type: application/json" --header "X-GitHub-Event: push" \
     --header "X-Hub-Signature: sha1=$sig" --data-binary @payload.json
   ```

2. A cron job forcing a pull every minute, for when GitHub cannot reach the instance:

   ```sh
   infra/scripts/60-mirror-ticker.sh setup    # creates the two tokens into infra/.env, prints the cron line
   infra/scripts/60-mirror-ticker.sh health   # exits 1 if anything is wrong - put this in a monitor
   ```

   The line `setup` prints goes in the crontab of the user that owns `infra/.env`:

   ```
   * * * * * /path/to/infra/scripts/60-mirror-ticker.sh once >/dev/null 2>&1
   ```

   `once` and `status` are there too. `once` sends `force=true`, because an unforced pull after a failed
   one is a no-op for 30 minutes and 14 consecutive failures hard-fail the mirror, silently if outgoing
   mail is off. `health` exits 1 on a mirror error, a mirror that never updated, a last success older than
   `MIRROR_STALE_SECONDS` (600) or an expired token, and warns `MIRROR_EXPIRY_WARN_DAYS` (14) out.

   Forced pulls are rate-limited by the plan limit `pull_mirror_interval_seconds` (default 300), which is
   not in the plan-limits API and must be lowered from the rails console:

   ```sh
   gitlab-rails runner 'Plan.default.actual_limits.update!(pull_mirror_interval_seconds: 30)'
   ```

   Set it below the cron interval, not at it - 30 s under a one-minute cron. Pulls that change nothing
   create no pipelines.

</details>

Fallback for an unlicensed or CE instance, and for the initial population: `infra/scripts/manual-sync.sh
both` fetches both repos from GitHub into bare mirrors and pushes branches and tags into GitLab without
pruning, so GitLab-only refs survive. Run it from cron.

## 4. Runner

Install `gitlab-runner` from GitLab's package repository on the build host, and install the toolchain from
step 2 where the `gitlab-runner` user can see it. Create the runner in GitLab first - Admin > CI/CD >
Runners > New instance runner, tag `dhp`, "Run untagged jobs" off - or over the API:

```sh
curl --header "PRIVATE-TOKEN: $TOKEN" -X POST --form "runner_type=instance_type" \
  --form "tag_list=dhp" --form "run_untagged=false" --form "description=dhp" \
  "https://<gitlab>/api/v4/user/runners"
```

That returns the `glrt-...` authentication token. Register with it and nothing but the executor: tags,
locked, untagged and paused now live on the server, and `register` aborts with "Runner configuration other
than name and executor configuration is reserved" if `--tag-list` or any of them is passed.

```sh
sudo gitlab-runner register --non-interactive --url https://<gitlab> --token glrt-... --executor shell
```

`/etc/gitlab-runner/config.toml` then needs one edit, `concurrent = 1` at the top, and `sudo gitlab-runner
restart`:

```toml
concurrent = 1

[[runners]]
  executor = "shell"
  # only if the tools are not on the runner's default PATH, e.g. sushi installed with nvm or in ~/.npm-global
  # environment = ["PATH=/home/gitlab-runner/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"]
```

- `concurrent = 1` is load-bearing twice: parallel builds collide on the FHIR package cache lock
  (`#dev.lock`), and it is the only thing stopping a core job and an integrations job writing the shared
  web root at once, since `resource_group` is project-scoped.
- Jobs run as the `gitlab-runner` user, with its home directory: `~/.fhir` is the FHIR package cache, and
  everything the pipeline keeps between jobs lives under `$DHP_DATA` (default `/srv/dhp`, a `variables:`
  entry in `ci/gitlab-ci.yml`; override it as a project CI/CD variable), which that user has to own
  (step 5). No shared volumes, no uid mapping.
- The shell executor runs the job in a non-login shell, so tools installed through a version manager are
  not found unless `environment = ["PATH=..."]` names them. Install them system-wide, or set the line.

Check, as the runner user: `sudo -u gitlab-runner -H bash -c 'java -version && sushi --version && jekyll
--version && jq --version'`, and under Admin > CI/CD > Runners (or `GET /runners/all`) exactly one runner
with the `dhp` tag is online. A second one, say a test runner someone left registered, takes jobs just the
same and writes wherever its own `DHP_DATA` points, with nothing in the job log to say so.

## 5. Prepare the web root and publication workspace, once

On the runner host, as the runner user, with a checkout of this repository:

```sh
sudo mkdir -p /srv/dhp && sudo chown gitlab-runner: /srv/dhp
sudo -u gitlab-runner -H env DHP_DATA=/srv/dhp ci/setup-webroot.sh
```

Idempotent, and it never overwrites a file it already wrote. It downloads `publisher.jar` (about 245 MB)
from GitHub into `publisher-cache/` and clones three GitHub repositories;
`PUBLISHER_JAR=/path/to/an/existing/publisher.jar` skips the download. `/srv/dhp` gets `webroot/`,
`publication/`, `publisher-cache/`, `txcache-seed/` and `zips/` - it is the published site, so back it up
like one. The web root gets `publish-setup.json` (layout rule
`uz.dhp.* -> https://dhp.uz/fhir/{3}`, covering both guides and any future one), empty `package-feed.xml`
and `publication-feed.xml`, `package-registry.json`, placeholder `index.html` and `fhir/license.html`, and
the vendored history assets under `fhir/assets-hist/`. `publication/` gets clones of
HL7/fhir-ig-history-template and FHIR/ig-registry, a `templates/` seeded from HL7/fhir-web-templates, and
an empty `temp/`. Two content jobs are yours:

- `templates/` is HL7's site chrome, so released pages and `history.html` carry the HL7 logo and a link to
  hl7.org. Edit `preamble.template`, `header.template`, `postamble.template` and the images in place;
  nothing re-copies over them.
- `index.html` and `fhir/license.html` are placeholders written only if absent - the publisher writes
  neither, and `history.html` links to a `license.html` that would otherwise 404.

Check: the four machine-readable files exist in the web root and `publication/` has its four
subdirectories. `release.sh` refuses to start without them.

## 6. Web server

Serve `/srv/dhp/webroot` at `https://dhp.uz/`, so `/fhir/core/...` maps to `webroot/fhir/core/...`, with:

- `.tgz` served as `application/gzip`; `.json` and `.xml` from the stock mime map.
- `Cache-Control: no-store`, at least for the continuous build - it is rewritten on every commit to `main`.
- No dependency on `hl7.org`: `history.html` renders its version table client-side from `history.js` and
  `history-cm.js`, which step 5 vendors under `fhir/assets-hist/` and the pipeline points every
  `history.html` at.
- Canonical-URL resolution (`https://dhp.uz/fhir/core/StructureDefinition/X` returning the page or the
  JSON depending on `Accept`) is a web server job; the publisher cannot do it and the pipeline does not try.

Serve the whole web root, not only the guide folders: `history.html` loads its version table from
`/fhir/assets-hist/history.js` and links `/fhir/license.html`, and a server that maps only `/fhir/core/` and
`/fhir/integrations/` leaves every history page empty. `verify-site.sh` checks both.

The web server only reads; the runner user is the only writer. If they are different machines, the web
root has to be a share the runner host mounts read-write - the pipeline swaps directories into place with
`mv`, so it must be one filesystem.

## 7. Put the pipeline on the `ci` branch

The pipeline lives on a GitLab-only `ci` branch, so nothing in the mirrored content changes. Two mechanisms
point there: `ci_config_path` (step 9, or the hardening script), and a `.gitlab-ci.yml` in each repo that
only `include:`s the same file, as a fallback if `ci_config_path` is ever cleared. Jobs fetch the branch at
run time and unpack `ci/` outside the work tree, so the checkout stays as the tag has it - `-go-publish`
copies the whole source folder into the release.

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
   /ci/ci-build.sh  /ci/release.sh  /ci/release-rollback.sh  /ci/setup-webroot.sh  /ci/verify-site.sh
   /ci/lib/common.sh
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
the `ci` branch - nothing to install on the runner.

Check: pushing to `ci` creates no pipeline; a pipeline on `main` starts a `ci-build` job.

## 8. First continuous build

Two project CI/CD variables to set on both projects before the first pipeline: `CI_BUILD_REPO_URL`, the
public GitHub URL of that guide - the publish box cites the repository the build came from, and the
default is `CI_PROJECT_URL`, your internal GitLab host, which should not appear on a public page - and
`DHP_DATA`, only if the runner host uses a path other than `/srv/dhp`. Then run a pipeline on `main` in each project
(Build > Pipelines > Run pipeline, or `infra/scripts/45-trigger-pipeline.sh core main`). Expect 20-25 min
once the terminology cache is warm; the very first build on a host is cold and takes longer.

Check: `https://dhp.uz/fhir/core/ci-build/en/index.html` answers 200 and its publish box says the guide is
a continuous build, citing that absolute URL - not "Local Development build", not "Publish Box goes here".
The job fails if either slips through.

Once each project has run one pipeline, run `infra/scripts/37-resource-group-mode.sh both`, once per
instance. Both jobs share `resource_group: dhp-webroot`, whose default mode is `unordered`: two tags pushed
together are not guaranteed to publish in order, and publishing 0.9.1 after 0.9.2 would leave the canonical
URL serving 0.9.1. `oldest_first` fixes it, and the API only knows a resource group once a job has used it.

## 9. Backfill the versions you want to keep

Publish oldest first, one at a time, waiting for each: the publisher rewrites every earlier version's
publish box from `package-list.json`. `release.sh` refuses a version that already has a folder or a
`package-list.json` entry, and one older than the newest published unless you pass `PUB_MODE=working`,
which publishes into the version folder without taking over the canonical URL. Core has tags back to
0.1.0 and each core release costs 73-93 min and about 2.7 GB, so decide how far back to go first. An
integrations release is 48 min for the first version and 78 min once there is an earlier one to carry
along.

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

Check after each release: `https://dhp.uz/fhir/<ig>/package-list.json` lists the new version with
`"current": true`, and from the second release on `verify-site.sh` (step 10) - it needs an older and a
newer version, so after the very first release check the version folder and the publish box by hand.

## 10. Verifying the site

```sh
ci/verify-site.sh https://dhp.uz core         0.9.1 0.9.2
ci/verify-site.sh https://dhp.uz integrations 0.8.0 0.9.0
```

The last two arguments are the older and the newer of two published versions. It checks about 30 URLs per
guide, exits non-zero if a required one is not 200, and checks the four publish-box statements (current
published version, permanent home, superseded-by link, continuous build with an absolute source link),
that every script `history.html` loads answers 200, and that no release's page header says
`<version> - ci-build` - all easy to get wrong and silent when they are. The only expected 301s are `/fhir/core` and
`/fhir/integrations` without a trailing slash. The last section, "'Directory of published versions' links
resolve", is informational: it follows the cross-guide links in the published pages and shows 404s for
the other guide until that one is published too, without failing the run.

## 11. Troubleshooting

- A tag produced no pipeline, with "Review the workflow:rules configuration": that ref has no
  `.gitlab-ci.yml`. Set `ci_config_path` (step 9).
- Every pipeline fails at once on a missing configuration file or an unresolvable `include:`: the `ci`
  branch does not exist yet, is renamed, or the project path does not match.
- The job dies in `before_script` or at `require_web_root`: `$DHP_DATA/webroot` is missing, not owned by
  the runner user, or has no `publish-setup.json` - step 5 was skipped or run as the wrong user, or
  `DHP_DATA` on the project does not match the host.
- `sushi: command not found` or `jekyll: command not found` in the job log while both work in your own
  shell: the runner's non-login shell has another PATH. Set `environment = ["PATH=..."]` (step 4).
- Tags or commits stopped arriving and no job failed: the mirror is hard-failed, which is silent with
  outgoing mail off. `60-mirror-ticker.sh health` names it; after a protected-ref change check the tag
  counts too (hardening section).
- A pipeline is rejected when you pass a variable on the Run pipeline form: that needs Owner once the
  projects are hardened.
- The published build reports more errors than the pipeline's build did: expected, `-go-publish` rebuilds
  with `-resetTx` and asks tx.fhir.org questions the warm CI build did not. Both numbers are in the job
  log, the detail in `https://dhp.uz/fhir/<ig>/qa.html`, and it does not fail on them.
- A build takes hours instead of 25 minutes: the terminology cache is cold. Check
  `$DHP_DATA/txcache-seed/<package id>/` is filling up and the log does not say "not writable, not saving".
- The ci-build dies with a `NullPointerException` in `FilesystemPackageCacheManager`: `-auto-ig-build`
  switches the publisher to the machine-wide package cache `/var/lib/.fhir`, which the runner user cannot
  create. `ci-build.sh` passes `-package-cache-folder "$HOME/.fhir"` for that; a hand-run build without it
  is the usual cause.
- The ci-build publish box says "Local Development build", or the job dies in the publish-box check: the
  build did not get `-auto-ig-build`, or `-repo` got something that is not an absolute URL.
- `history.html` shows its heading and no table: `/fhir/assets-hist/history.js` answers 404, so the web
  server is not serving the whole web root (step 6), or step 5 never vendored the file.
- Every page of a release says `0.9.2 - ci-build` next to the version: the guides keep
  `releaseLabel: ci-build` in `sushi-config.yaml`, and releases published before `release.sh` started
  replacing it for release builds kept it. `DHP_DATA=/srv/dhp ci/relabel-releases.sh core` (and
  `integrations`) fixes the published pages in place, in under a minute.
- `GET /projects/<id>/mirror/pull` says `update_status: none` with null timestamps: not a failure, the
  mirror worker has not run yet.

## 12. The scripts in this directory

```
ci/lib/common.sh                     shared helpers; reads sushi-config.yaml for everything IG-specific
ci/setup-webroot.sh                  one-off $DHP_DATA layout, web root + publication workspace (step 5)
ci/ci-build.sh                       build and deploy the continuous build
ci/release.sh <version>              verify, build, -go-publish (QA gate opt-in, step 9)
ci/release-rollback.sh <version>     undo one publication in the web root
ci/relabel-releases.sh <ig>          fix a "- ci-build" page header on already-published releases
ci/verify-site.sh                    curl the URLs that must work (step 10)
ci/gitlab-ci.yml                     the pipeline, as /.gitlab-ci.yml on the `ci` branch
infra/scripts/lib.sh                 shared env + API helpers for the scripts below
infra/scripts/38-harden-projects.sh  apply|show the project settings of the hardening section
infra/scripts/37-resource-group-mode.sh  set dhp-webroot to oldest_first (step 8)
infra/scripts/enable-pull-mirror.sh  turn on pull mirroring for both projects
infra/scripts/60-mirror-ticker.sh    setup|once|status|health - forced mirror pulls from cron
infra/scripts/manual-sync.sh         CE/unlicensed fallback: fetch GitHub, push to GitLab
infra/scripts/45-trigger-pipeline.sh trigger a pipeline on a ref, optionally with variables
infra/scripts/36-publish-ci-scripts.sh push ci/ to the `ci` branch of both projects
```

The `ci/*` scripts run by hand exactly as the pipeline runs them, from a checkout of a guide:
`DHP_DATA=/srv/dhp ci/ci-build.sh`, `DHP_DATA=/srv/dhp ci/release.sh 0.9.1`. Run them as the runner user,
since it owns everything they write.

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
webhook route in step 3 - generate with `openssl rand -hex 16`), `MIRROR_STALE_SECONDS` and
`MIRROR_EXPIRY_WARN_DAYS` (thresholds for `health`), `MAIN_PUSH_ACCESS_LEVEL` and
`MAIN_MERGE_ACCESS_LEVEL` (hardening, default 40), `GITLAB_RAILS` (how `38-harden-projects.sh` reaches the
rails console, default `sudo gitlab-rails`; for a containerised GitLab `docker exec -i <container>
gitlab-rails`). `60-mirror-ticker.sh setup` writes `CORE_MIRROR_TOKEN` and `INTEGRATION_MIRROR_TOKEN` back
into `.env` when it creates the project access tokens; the file is gitignored.

Defaults to check before use:

- `manual-sync.sh` builds its push URL as `http://root:$GITLAB_ROOT_TOKEN@$GITLAB_HOST:$GITLAB_HTTP_PORT/...`;
  on a real instance that has to be `https` and the user may not be `root` - edit the `push_url` line.
- `ci/lib/common.sh` and `ci/setup-webroot.sh` default `SITE_URL` to `https://dhp.uz`, and
  `verify-site.sh` looks for `https://dhp.uz` links in published pages - change them if the site moves.
- `ci/gitlab-ci.yml` defaults `DHP_DATA` to `/srv/dhp`; a project CI/CD variable overrides it.

Before debugging a job that stopped: `jq` is required; `$DHP_DATA/webroot` must exist, be writable by the
runner user and hold `publish-setup.json`, so a job cannot write the site somewhere nobody serves;
publications serialise on `$WEB_ROOT/.publish.lock` with `flock` for up to `WEB_LOCK_WAIT`; and both jobs
check free space first, about 20 GB for temp and for the web root. A half-published release is recoverable
with `ci/release-rollback.sh <version> --yes`, which removes that version folder and its entries from
`package-list.json`, both site feeds and `package-registry.json`, re-pointing `current` at the newest
version left; then retry with `ALLOW_REPUBLISH=1`.

Other environment variables the scripts read, with defaults: `DHP_DATA` (`/srv/dhp`) and the paths derived
from it - `WEB_ROOT` (`$DHP_DATA/webroot`), `PUBLICATION_DIR` (`$DHP_DATA/publication`), `PUBLISHER_CACHE`
(`$DHP_DATA/publisher-cache`), `ZIPS_DIR` (`$DHP_DATA/zips`), `TXCACHE_SEED` (set per package id by the
pipeline, unset by hand means no seeding); `JAVA_HEAP` (`-Xmx12g`); `CI_BUILD_REPO_URL` (`CI_PROJECT_URL`),
`DHP_CI_REF` (`ci`), `PUB_MODE` (`milestone`), `PUB_RELEASE_LABEL` (the publication status, `draft` for
0.x, used when `sushi-config.yaml` says `releaseLabel: ci-build`), `FAIL_ON_QA_ERRORS` (`0`; `0`, `false`, `no` and `off` mean
off and anything else means on, so a typo leaves the gate on), `GATE_WARM_TXCACHE` (`0`), `ALLOW_REPUBLISH`
(`0`), `ROLLBACK_ASSUME_YES` (`0`), `KEEP_ZIP` (`0`), `NEED_TEMP_GB` and `NEED_WEB_GB` (`20`),
`WEB_LOCK_WAIT` (`21600`), `PUBLISHER_VERSION` (unset, latest), `PUBLISHER_REFRESH` (`0`), `STAGING_DIR`
(`$WEB_ROOT/.staging`), `HIST_ASSETS_DIR` (`$WEB_ROOT/fhir/assets-hist`).

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
  pushed ref, so any mirrored branch can define its own jobs and run them as the runner user, which owns
  the web root. It also lets old tags that carry no CI config build at all (step 9).
- `public_jobs = false`: job logs and QA artifacts stop being readable by every signed-in user.
- `ci_pipeline_variables_minimum_override_role = owner`: a Developer can no longer pass
  `FAIL_ON_QA_ERRORS`, `SKIP_DEPLOY`, `DHP_DATA` or `PUB_MODE` on the Run pipeline form. Defaults still
  come from `.gitlab-ci.yml` on the `ci` branch and from CI/CD settings.
- A protected tag rule `*` at create = Maintainer (40), since pushing an `X.Y.Z` tag is all it takes to
  publish. Maintainer and not "No one" (0): the mirror creates tags as the mirror user, level 0 is refused
  for everybody, and a rule the mirror user cannot satisfy makes GitLab delete the matching tags and
  hard-fail the mirror. `main` stays at push and merge = 40 for the same reason.
- `external_webhook_token`, only when `GITHUB_WEBHOOK_SECRET_<project id>` is in `.env` (step 3).

All of it goes in over REST except the webhook token, which has no REST setter: that call is
`$GITLAB_RAILS runner`, default `sudo gitlab-rails`, with the secret passed on stdin so it never appears
in a process listing. `show` reads the token the same way, so it needs rails access too;
`SHOW_WEBHOOK_TOKEN=0` leaves that line out and makes `show` pure REST.

Check: `show` prints both projects side by side. Then force a pull, run
`infra/scripts/60-mirror-ticker.sh health`, and compare tag counts against GitHub - a protected-ref rule
the mirror cannot satisfy deletes tags, so this is the one check not to skip.

## Not validated

- A real webhook delivery from GitHub: the HMAC route was only exercised with hand-signed payloads.
- A genuinely new upstream commit or tag arriving through the mirror: refs were deleted in GitLab and
  restored by a pull instead, which is the same code path.
- A packaged `gitlab-runner` service running as the `gitlab-runner` user: every run here, including one
  by someone following this README with no other help, used the static binary as an ordinary user with
  `DHP_DATA` in that user's directory. The `environment = ["PATH=..."]` line was required there for a
  SUSHI installed under `~/.npm-global`; a service install may or may not need it.
- Your web server configuration: the site was only served by a stock nginx with the web root as its
  document root.
