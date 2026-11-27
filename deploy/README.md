# Deploying the scale-set listener under systemd (#108/#109)

Package and supervise the [scale-set listener](../listener/) as a host binary
under systemd (option a, [ADR-0001](../doc/adr/0001-ephemeral-jit-runners.md)).
The host needs **no Go toolchain**: the binary is built inside a golang
container (#108) and only the static binary plus its sibling shell scripts are
installed.

## 0. Read this first: what a workflow actually targets

**Workflows target a runner type by its `labels`. The scale set name is only an
identifier.** A workflow's `runs-on` is matched against the scale set's
**labels**, which are fixed when the scale set is created.

The name and the labels coincide only when the scale set was created with its
name as its single label. That is the default here when a runner type declares
no labels of its own, and it is exactly why the name *looks* like the routing
target when it is not.

Getting this wrong is the most expensive mistake available in this system,
because it produces no error at all: the job simply sits in `queued`. Note also
that the REST job status **stays `queued` even after a job has been assigned to
a scale set**, so `queued` on its own is not evidence of a routing failure.

Two ways to decide the labels, both explicit:

| Runner type declares | Scale set is created with | A workflow writes |
| --- | --- | --- |
| no `labels` | labels = exactly the scale set name | `runs-on: <scale-set-name>` |
| `labels: [a, b]` | labels = `a`, `b` verbatim (the name is never added) | `runs-on: [a, b]` |

Either way the labels are **written into the scale set explicitly** and recorded
in `runner-types.yaml`, so the configuration always states what the routing key
is. `scaleset-admin` prints the exact `runs-on:` line to paste; use what it
prints.

> **What has been confirmed.** A scale set created this way received and ran a
> real job end to end, which confirmed matching against the scale set's labels.
> It did not exercise a job requesting a *subset* of a multi-label scale set.
> Standard Actions semantics is that every label a job requests must be present
> on the runner, but that subset case is unverified here -- so have the workflow
> request exactly what `scaleset-admin` printed.

## The short way: one command

The deploy command builds and installs one listener instance for a runner
type. See section 3a for running several types on the same host.

```sh
sudo ./script/deploy-listener.sh --config-url https://github.com/<org> --type gpu --dry-run
sudo ./script/deploy-listener.sh --config-url https://github.com/<org> --type gpu
```

**What the scale set binds to.** `--config-url` takes either shape, and the
client tells them apart by path segments alone:

| URL | Scope |
| --- | --- |
| `https://github.com/<org>` | the organisation -- every repo in it can use the runner |
| `https://github.com/<owner>/<repo>` | that **one repository** |
| `https://github.com/enterprises/<name>` | the enterprise |

Repository scope is how a **personal repo** gets a self-hosted runner. GitHub has
no user-account scope -- there is no way to serve all of one account's repos with
a single runner -- so a personal repo gets its own, serving only itself. To share
one runner between several repos they have to live in the same organisation,
which is the only level where "many repos, one runner" exists.

Two things are weaker at repository scope, and they are worth knowing before
pointing a GPU host at a repo: there are no runner groups, so the per-repo and
per-workflow allowlists an organisation can impose do not exist, and there is no
organisation-level fork-PR approval gate. The host's exposure is otherwise
identical -- `docker` group membership is root-equivalent either way.

`--org-url` is still accepted as the former name of the same flag.

It covers both halves and says which is which: the **GitHub side** (create the
runner type's scale set, if it is not already there -- section 3c) and the
**local side** (build and install, service user and its engine access, the
per-type writable runner state tree, 0600 environment file, and systemd
instance in section 3a). It then verifies the listener
actually connected and is reporting capacity, and prints the exact `runs-on:`
line for your first job.

It is **idempotent**: every step detects what is already in place and skips it,
so re-running after a partial run or a config change is the normal way to use
it. On the second and later machines the scale set already exists, so nothing
outward needs to happen -- pass `--skip-github` and it does the local half only.

**A clean checkout needs no preparation.** The command reads the runner-type
config through `scaleset-admin` (section 3c) -- before every other step, and so
before the local half that installs it -- and it settles which binary that is by
itself: this checkout's `bin/`, else `PATH`, else `just build-admin`. Section 1
is therefore something the command does for you, not something to do first. A
first `--dry-run` may have to build that one binary to read the config at all,
and says so; it still installs nothing, changes nothing on GitHub and asks for
no token. Set `SCALESET_ADMIN_BIN` to name a particular binary instead, and
`LISTENER_BIN_DIR` (relative to the repository root, like the justfile's
`BIN_DIR`) to build somewhere other than `bin/`.

The admin token is **prompted for and never a flag**: `/proc/<pid>/cmdline` is
world-readable, so a token in an argument is a token any local user on the box
can read, and it would sit in shell history besides.

To remove all listener instances from this host: `sudo ./script/teardown-listener.sh`. It reverses
the local half only, and deliberately does not delete the scale set -- that is
shared by every machine serving the runner type, so retiring it is a separate
explicit act (`scaleset-admin delete`).

## 1. Build & install the binaries (#108)

```sh
# Build the static binaries inside a pinned golang container:
just build-listener                 # -> bin/scaleset-listener
just build-admin                    # -> bin/scaleset-admin

# Install both binaries + provision-job.sh + reap.sh + lib/ under PREFIX:
sudo just PREFIX=/opt/github-runner-listener install-listener
```

This lays down a self-contained tree the listener shells out against:

```
/opt/github-runner-listener/
├── bin/scaleset-listener           # the static binary systemd runs
├── bin/scaleset-admin              # create / delete a runner scale set
├── listener/provision-job.sh       # per-job container entrypoint
├── listener/reap.sh                # orphan-sweep entrypoint
└── lib/*.sh                         # the bash seams those scripts source
```

## 2. Create the unprivileged service user

The unit runs as a dedicated non-root user (acceptance: never root). It must be
able to reach the container engine the provisioner uses. `deploy-listener.sh`
does both: it creates the user, and on a rootful docker host (no `podman` on
`PATH`, a `docker` group present) it adds the user to the `docker` group,
skipping a user that is already a member. Rootless podman needs no group, and a
missing `docker` group is reported rather than created. By hand:

```sh
sudo useradd --system --create-home --shell /usr/sbin/nologin ci-runner
# Rootful docker only:
sudo usermod -aG docker ci-runner
```

`docker` group membership is root-equivalent on the host; job code never gets
the socket (see `listener/README.md`), only the listener does.

## 2a. Create the writable runner state tree for a manual single-unit install

The unit runs under `ProtectSystem=strict`, which makes `/opt` read-only, and
grants back exactly `ReadWritePaths=/opt/github-runner-listener/runners`
(`RUNNER_HOME`): the per-job dirs go under its `work/` root and the job-history
ledger under `history/`. The directory has to exist and belong to the service
user; systemd refuses to start the unit when a `ReadWritePaths` entry is
missing. Create this tree for the legacy unit in section 4:

```sh
sudo install -d -m 0750 -o ci-runner -g ci-runner \
  /opt/github-runner-listener/runners /opt/github-runner-listener/runners/work
```

## 3. Provide the token for a manual single-unit install (#109)

The scale-set admin token is **never** baked into the unit, passed on the
command line, or logged — it is read from a root-only EnvironmentFile:

```sh
sudo install -d -m 0755 /etc/github-runner-listener
sudo install -m 0600 deploy/scaleset-listener.env.sample \
  /etc/github-runner-listener/scaleset-listener.env
sudo "${EDITOR:-vi}" /etc/github-runner-listener/scaleset-listener.env
# Fill in GITHUB_CONFIG_URL, GITHUB_TOKEN, SCALE_SET_OWNER, and SCALE_SET_NAME.
# SCALE_SET_NAME names a scale set; it is NOT what workflows target (section 0).
# Verify it is 0600 and root-owned:
sudo stat -c '%a %U' /etc/github-runner-listener/scaleset-listener.env   # -> 600 root
```

The listener defaults the session owner to the hostname, then a generated UUID.
It looks for its scripts under `${LISTENER_PREFIX}/listener` by default. To
override a script in the environment file, use an absolute path. The deploy
script fills absent or empty settings on reruns and replaces relative script
paths with absolute installed paths. It derives a missing owner from
`hostname` and fails if that lookup fails or returns an empty value. If an existing environment
file has a mode other than 0600, deployment warns that the token may have been
exposed and should be rotated, then restores mode 0600.

## 3a. Deploy one listener instance per runner type (#110/#112/#113)

Each entry in the **runner-type config** maps one runner type to one
homogeneous scale set (labels, image, device passthrough, runtime, build tool,
concurrency); adding a type is a new entry, not a code change.
Concurrency is reactive live-admission by default — the count is derived from
live host headroom, not configured, and the only knob is `reserve` percent
([ADR-0005](../doc/adr/0005-reactive-live-admission.md)); a GPU type opts into
device-count sizing with `mode: auto`. The Go listener is the authoritative
parser ([ADR-0003](../doc/adr/0003-go-bash-boundary.md)).

```sh
sudo install -m 0644 deploy/runner-types.sample.yaml \
  /etc/github-runner-listener/runner-types.yaml
sudo "${EDITOR:-vi}" /etc/github-runner-listener/runner-types.yaml
```

The shipped sample defines a **GPU** type with precise device passthrough and
concurrency based on the detected GPU count, and a **CPU** type. Deploy both
on the same host using their names. Omit `--skip-github` if the CPU scale set
still needs to be created.

```sh
sudo ./script/deploy-listener.sh --config-url https://github.com/<org> --type gpu
sudo ./script/deploy-listener.sh --config-url https://github.com/<org> --type cpu --skip-github
journalctl -u scaleset-listener@gpu.service -f
```

The deploy command installs `scaleset-listener@.service` once and enables
`scaleset-listener@<type>.service` for each deployed type. It creates the token
file `/etc/github-runner-listener/<type>.env` at mode 0600 and sets
`RUNNER_TYPE` and `RUNNER_HOME`. Each instance can write to its own
`/opt/github-runner-listener/runners/<type>` tree, with jobs in `work/` and
ledger data in `history/`. This keeps each instance's reaper scoped to its
own jobs.

Pass `--type` when the config defines multiple types. With a single entry,
deploy resolves its name through `scaleset-admin show`. Type names must match
`^[a-z0-9][a-z0-9_-]{0,62}$`. The names `work` and `history` are reserved.

To remove just the CPU instance, preview and then confirm the local teardown.

```sh
sudo ./script/teardown-listener.sh --type cpu --dry-run
sudo ./script/teardown-listener.sh --type cpu
```

The template and shared installation stay in place while another instance or
the legacy unit remains. Omit `--type` to remove all listeners from the host.
The scale sets on GitHub remain available to other hosts.

> **Live GPU validation is HITL.** The config, its loading, and auto-concurrency
> from the GPU count are exercised AFK (the detector is stubbed in the Go tests).
> A GPU job *actually running* needs a real GPU host with the NVIDIA stack — an
> operator step on the target host.

### Migrating a single-unit host

Run the deploy command for the type that the legacy listener serves. Use
`--dry-run` to preview the migration and `--skip-github` if the scale set
already exists. Deploy stops and disables `scaleset-listener.service`, moves
`/etc/github-runner-listener/scaleset-listener.env` to `<type>.env`, and
reuses the existing token. If `<type>.env` already exists, deploy keeps it
and removes the legacy env file. It backfills settings, removes the old unit,
reloads systemd, and starts the instance.

Deploy identifies the legacy type from `RUNNER_TYPE`, or from the only
configured type if that setting is empty. If you deploy another type first,
the legacy unit keeps serving its current type until you deploy that type.
Migration leaves `/opt/github-runner-listener/runners/work` in place.

## 3b. Build (or pin) the per-type runner images (#92: #120/#121/#122)

The `image` each runner type references is produced one of two ways (ADR-0001
"Runner images"):

**CI publishes the self-built images.** The `runner images` workflow
(`.github/workflows/runner-images.yaml`) builds the SEC-5 base and the GPU
image on a GitHub-hosted runner, through the same script and Dockerfile shown
below, and pushes them to:

- `ghcr.io/ycpss91255-lab/runner-base:<runner-version>`
- `ghcr.io/ycpss91255-lab/gpu-runner:<runner-version>`

It runs on every push to `main` that changes `images/**`, and on demand:

```sh
# Publish now; runner_version is optional (empty = the resolved latest release).
gh workflow run runner-images.yaml --ref main -f runner_version=2.334.0
gh run watch "$(gh run list --workflow runner-images.yaml --limit 1 --json databaseId -q '.[0].databaseId')"
```

The run's **job summary** lists both digests and the ready-to-paste
`image: ghcr.io/ycpss91255-lab/gpu-runner@sha256:<digest>` line for the gpu
type -- pin that, never the tag. Each image carries an
`org.opencontainers.image.source` label linking the package to this repository,
and a signed build provenance attestation you can check with
`gh attestation verify oci://ghcr.io/ycpss91255-lab/gpu-runner@sha256:<digest> --repo ycpss91255-lab/github_runner`.
A pull request that touches `images/**` builds both images without pushing.

> **First publish.** A package an organisation publishes for the first time is
> created **private**. Until an org owner makes it public (package settings ->
> Change visibility), a GPU host must `docker login ghcr.io` with a token that
> has `read:packages` before it can pull the image.

The manual build below is the fallback, for a registry other than this
organisation's or when CI is unavailable.

**Self-built image, SEC-5 supply chain (#120).** Device/GPU types need a
self-built image because stock actions-runner images can't run GPU jobs. The
runner tarball baked into that image is obtained through the **same SEC-5 check
the host bootstrap uses** (`verify_runner_tarball`, strict) — a tampered mirror
/ MITM can never reach the image. The wrapper downloads + verifies on the host,
then hands the already-verified tarball to a digest-pinned, hermetic build:

```sh
# Build the SEC-5 base (gh is a prereq: the digest is verified strict).
# RUNNER_VERSION pins the version; omit for the resolved latest.
RUNNER_VERSION=2.334.0 \
  images/build-runner-image.sh --tag ghcr.io/your-org/runner-base:2.334.0
```

**GPU/device image, layered on the SEC-5 base (#121).** The CUDA/device stack
is layered on that base (so the runner stays the SEC-5-verified one). Both
`FROM`s are pinned by digest; the build is hermetic (the CUDA libs are copied
from a pinned `nvidia/cuda` image, no NVIDIA apt repo at build time):

```sh
docker build -f images/runner-gpu.Dockerfile \
  --build-arg RUNNER_BASE_IMAGE=ghcr.io/your-org/runner-base:2.334.0 \
  --build-arg RUNNER_VERSION=2.334.0 \
  -t ghcr.io/your-org/gpu-runner:2.334.0 .

# Push, then pin the runner-type config's `image:` by the resulting DIGEST:
docker push ghcr.io/your-org/gpu-runner:2.334.0
docker buildx imagetools inspect ghcr.io/your-org/gpu-runner:2.334.0   # copy Digest
# -> image: ghcr.io/your-org/gpu-runner@sha256:<digest>
```

> **A GPU job actually executing is HITL.** The images *build* and are wired
> into the GPU runner-type config AFK; running a real GPU job needs a host with
> the NVIDIA driver + container runtime — an operator step on the target host.

**Plain CPU type — pin the upstream image by digest (#122).** A CPU type needs
no self-built image; it uses the **official** `ghcr.io/actions/actions-runner`
image pinned by `@sha256:` digest (never `:latest`). Bump the digest
deliberately:

```sh
docker buildx imagetools inspect ghcr.io/actions/actions-runner:latest
# copy the top-level "Digest: sha256:..." into the cpu type's image:, then commit.
# (Pin the version you validated, not whatever :latest moved to.)
```

## 3c. Create the runner type's scale set on GitHub (`scaleset-admin`)

The listener **connects to** a scale set; it never creates one. Until this step
has run there is nothing for `SCALE_SET_NAME` / the type's `scale_set` to name,
and the listener exits telling you so.

`scaleset-admin` is driven by the same runner-type config the listener reads --
the name comes from the type's `scale_set` and the routing labels from its
`labels`, and neither can be passed as a flag. That is deliberate: it makes
`runner-types.yaml` the single source of truth for routing, so the config and
the live scale set cannot be made to disagree by a one-off command line.

```sh
export GITHUB_CONFIG_URL=https://github.com/<org>
read -rs GITHUB_TOKEN && export GITHUB_TOKEN   # scale-set admin scope
                                               # (prompted: never in argv or history)

# Preview first -- prints exactly what would be created on GitHub:
scaleset-admin create --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu --dry-run

# Then create it. Running it again is a no-op that says so.
scaleset-admin create --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu
```

It prints the literal line to paste into a workflow, which is the answer to the
question section 0 is about:

```
Workflows target this runner type by its LABELS (the name is only an identifier).
Paste into your workflow job:

    runs-on: [self-hosted, linux, gpu]
```

**Idempotent.** A second run over an existing scale set changes nothing,
reports the existing id, and exits 0 -- so standing up a second machine against
the same runner type needs no GitHub-side step at all. If the live scale set's
labels have drifted from the config, it says so loudly rather than reusing a
scale set nobody's config describes.

Options: `--group <name>` picks the runner group to create in (default
`Default`); `--type` may be omitted when the config holds exactly one type.
`GITHUB_CONFIG_URL` and `GITHUB_TOKEN` are read from the environment and are
deliberately not flags -- a token in a flag is a token in the host process
table.

**Deleting is a separate, explicit act.** Nothing else in this repo deletes a
scale set; no install, teardown or uninstall path touches it. Removing it makes
every workflow targeting those labels stop being served, so it is its own verb
and it insists on `--yes`:

```sh
scaleset-admin delete --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu --dry-run     # preview
scaleset-admin delete --config /etc/github-runner-listener/runner-types.yaml \
  --type gpu --yes
```

Deleting one that is not there succeeds as a no-op, so a teardown can be re-run.

## 4. Install, enable & start the legacy unit by hand

Use this unit with the state tree and token file in sections 2a and 3 for a
manual single-listener install. The deploy command uses the template in
section 3a.

```sh
sudo install -m 0644 deploy/scaleset-listener.service \
  /etc/systemd/system/scaleset-listener.service
sudo systemctl daemon-reload
sudo systemctl enable --now scaleset-listener.service

# Watch it come up (the token never appears in the logs):
journalctl -u scaleset-listener -f
```

`Restart=always` (with a 5s backoff) keeps the listener supervised across a
clean drain (SIGTERM cancels the context, in-flight jobs drain within
`TimeoutStopSec`) or a transient error, so the host is never left without a
listener.

## Verifying the unit file

The unit is checkable without a live install:

```sh
systemd-analyze verify deploy/scaleset-listener@.service deploy/scaleset-listener.service
```

> **Live install is HITL.** Enabling the unit on a real host needs that host,
> a real scale set, and a valid admin token (none exist in CI). The unit file,
> the env sample, and these steps are the deliverable; the live
> enable/verify is performed by an operator on the target host.
