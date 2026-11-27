# Scale-set listener (ADR-0001 Phase 4)

The orchestration layer for the ephemeral / JIT runner model
([ADR-0001](../doc/adr/0001-ephemeral-jit-runners.md)). It integrates the
official **Runner Scale Set Client** ([`github.com/actions/scaleset`](https://github.com/actions/scaleset),
Go) as the non-k8s, outbound long-poll orchestrator and supplies the one piece
that client does *not*: the per-job container provisioning where the
residue/secret isolation actually lands.

## Session and provisioning

The GitHub client handles the outbound long-poll protocol. The listener
advertises its resolved pool bound on every poll and reconciles assigned
demand against its local runner count. It starts a single-use rootless
container for each runner through [`provision-job.sh`](provision-job.sh) and
[`lib/runner-container.sh`](../lib/runner-container.sh). GitHub dispatches
assigned jobs to those runners.

## What workflows target: the labels, not the name

**A workflow's `runs-on` is matched against the scale set's LABELS. The scale
set name is only an identifier.** They coincide only when the scale set was
created with its name as its single label -- which is the default when a runner
type declares no labels, and is exactly why the name *looks* like the routing
target when it is not.

This is the most expensive thing to get wrong here, because it fails silently:
the job sits in `queued` with no error anywhere. The REST job status also stays
`queued` after a job has been assigned to a scale set, so `queued` alone does
not prove a routing failure.

The labels are decided when the scale set is **created** — see
[`cmd/scaleset-admin`](cmd/scaleset-admin) and
[`deploy/README.md`](../deploy/README.md). Either the runner type's `labels` are
used verbatim, or, when it declares none, the labels are set to exactly the
scale set name. Both are written explicitly rather than left to the client's
fill-from-name fallback, so the recorded config always states the routing key;
`scaleset-admin` prints the literal `runs-on:` line to paste.

## Layout

- [`listener.go`](listener.go) — the demand→provision loop. `Session` is an
  **injectable interface** mirroring the subset of
  `*scaleset.MessageSessionClient` the loop drives (`GetMessage`,
  `AcquireJobs`, `DeleteMessage`, `Session`, `Close`). A compile-time
  assertion (`var _ Session = (*scaleset.MessageSessionClient)(nil)`) proves
  the real client satisfies it, so the loop is unit-testable against a fake
  with no live GitHub.
- [`provisioner.go`](provisioner.go) — `ContainerProvisioner`, the production
  `Provisioner` that shells out to `provision-job.sh`.
- [`provision-job.sh`](provision-job.sh) — the per-job container entrypoint
  (`provision-job.sh <job-id> <jit-config-file> <image>`). The JIT config
  crosses the boundary as a **file**, never on argv (ADR-0003 / #133), so the
  single-use credential is not exposed in the host process table; the script
  reads the file, sources the Phase 3 seam, runs one throwaway container,
  propagates its exit status, and removes the per-job runner dir so no residue
  survives.
- [`cmd/scaleset-listener`](cmd/scaleset-listener) — the production entrypoint
  that wires the real client into the listener (the **live** path).
- [`scalesetadmin.go`](scalesetadmin.go) — the scale-set **lifecycle** logic:
  create (idempotent) and delete, plus `RoutingLabels` / `RunsOn` and the
  shared `SelectType`. `ScaleSetAdmin` is the injectable seam (the subset of
  `*scaleset.Client` these drive), with the same compile-time assertion the
  `Session` seam carries, so create/delete are unit-tested with no credentials
  and no live GitHub.
- [`cmd/scaleset-admin`](cmd/scaleset-admin) — the operator command over that
  logic: `scaleset-admin create|delete`, driven by the runner-type config
  rather than by flags. Credentials come from the environment
  (`GITHUB_CONFIG_URL` / `GITHUB_TOKEN`), never from a flag — a token in a flag
  is a token in the host process table.

## Build & test (in a container — `go` is not on the host)

The module requires Go ≥ 1.25.3 (a transitive constraint of
`actions/scaleset v0.4.0`):

```sh
cd listener
docker run --rm -v "$PWD:/src" -w /src golang:1.25.3 sh -c 'go build ./... && go test ./...'
```

The unit tests (`listener_test.go`, `provisioner_test.go`) drive the loop
through the `Session` seam with a scripted fake session and a recording
provisioner, asserting:

- new runners receive a JIT config and the configured image,
- every poll advertises the resolved bound,
- startup, message statistics, and empty polls reconcile assigned demand,
- each processed message is acked (`DeleteMessage`),
- a provisioner error is reported and the loop continues,
- a clean drain still tears the session down,
- available-but-unassigned jobs do **not** provision,
- the real client satisfies `Session`.

Host-side, [`test/bats/integration/listener_provision.bats`](../test/bats/integration/listener_provision.bats)
covers the entrypoint script with a stubbed container CLI.

## Live end-to-end gap (the one untested path)

The unit + bats suites cover every seam **except** a real long-poll against a
**live, provisioned GitHub scale set** — that needs operator credentials
(`GITHUB_TOKEN` with scale-set admin scope), a `GITHUB_CONFIG_URL`, and an
actual scale set, none of which exist in CI. That single gap is:

- documented here,
- exercised by [`integration_test.go`](integration_test.go), gated behind the
  `integration` build tag and skipped unless the live env knobs are set, so it
  never runs (or fails) in the default suite.

Run it manually against a real scale set:

```sh
GITHUB_CONFIG_URL=https://github.com/<org> \
GITHUB_TOKEN=<scale-set-admin-token> \
SCALE_SET_NAME=<name> \
docker run --rm -e GITHUB_CONFIG_URL -e GITHUB_TOKEN -e SCALE_SET_NAME \
  -v "$PWD:/src" -w /src golang:1.25.3 \
  go test -tags=integration -run TestLiveScaleSetSession -v ./...
```

## Production entrypoint env

`cmd/scaleset-listener` reads:

| Env | Meaning |
| --- | --- |
| `GITHUB_CONFIG_URL` | GitHub organization or repository URL (required) |
| `SCALE_SET_OWNER` | session owner (listener falls back to the hostname, then a generated UUID) |
| `GITHUB_TOKEN` | token with scale-set admin scope (required) |
| `SCALE_SET_NAME` | the scale set to connect to, **by name** (required). An identifier, not the runs-on target -- see above |
| `RUNNER_IMAGE` | per-job container image (default `ghcr.io/actions/actions-runner:latest`) |
| `AUTO_SIZE_DEVICES` | when set, size the pool to the detected device count (#103) instead of reactive live-admission |
| `DEVICE_DETECT_CMD` | device-enumeration command for auto-sizing (default `nvidia-smi`, one device per output line) |
| `HOST_PROBE_CMD` | host reader for reactive live-admission (default installed `listener/host-probe.sh`; ADR-0005, #163) |
| `PROVISION_SCRIPT` | default installed `listener/provision-job.sh` |
| `REAP_SCRIPT` | orphan-sweep entrypoint (default installed `listener/reap.sh`) |

Deployment sets `HOST_PROBE_CMD`, `PROVISION_SCRIPT`, and `REAP_SCRIPT` to
their installed paths under `${LISTENER_PREFIX}/listener`. Reruns backfill absent
or empty settings in the mode-0600 environment file and replace effective
relative script paths. Absolute script overrides are preserved.

The bash seams read a few more knobs at provision/reap time:
`RUNNER_WORK_ROOT` (parent of the per-job temp dir, default `${RUNNER_HOME}/work`
— #130; reap.sh prunes the **same** root, #148),
`RUNNER_JOB_MAX_LIFETIME` (per-job watchdog ceiling in seconds, default 6h, 0
disables, #107), and `RUNNER_MANAGED_BY` (the `managed-by` label value the
reaper keys on, #104/#105). The history ledger defaults to
`${RUNNER_HOME}/history/ledger.tsv` and honors `RUNNER_HISTORY_DIR` and
`RUNNER_HISTORY_LEDGER` overrides.

### Per-job container hardening (#114/#115/#116/#117)

Every per-job container is hardened by default (ADR-0001 defense-in-depth); the
provisioner exposes these knobs, set per runner type by the listener from the
runner-type config (the shell-out contract, ADR-0003):

| Env | Meaning |
| --- | --- |
| `RUNNER_PIDS_LIMIT` | `--pids-limit` value (default `4096`); bounds in-container PIDs (#114) |
| `RUNNER_CAP_ADD` | space-separated capabilities to add back on top of `--cap-drop=ALL` (default none) (#114) |
| `RUNNER_DEVICES` | space/newline-separated host device nodes passed through precisely as `--device` -- never `--privileged` (#117) |
| `RUNNER_CONTAINER_HOME` | the runner's home inside the image, used as the container's working directory (default `/home/runner`); set it only for an image that installs the runner elsewhere |
| `RUNNER_DOCKER_SOCKET` | Host Docker socket path from the runner type's `docker_socket` setting. Explicitly empty when the type leaves access off (#116). |

Fixed (not knobs): `--cap-drop=ALL` and `--security-opt no-new-privileges` are
always applied; the **default seccomp profile is kept** (never
`seccomp=unconfined`) and **MAC stays enforced** -- there is no `label=disable`,
and any bind mount (only the opt-in docker socket) is relabelled `:Z` (#115).
The container is **never `--privileged`**.

**No host directory is mounted into a job.** The container runs the runner the
image ships at `RUNNER_CONTAINER_HOME` (default `/home/runner`, the layout of
both `images/runner-base.Dockerfile` and `ghcr.io/actions/actions-runner`) as
its working directory. The job's `_work` and `_diag` live in the container's own
writable layer and are removed with it by `--rm`. The per-job host dir under the
work root is only bookkeeping: it anchors the credential env-file, which sits
beside it rather than inside it (#140), and it is what the reaper sweeps.

### Host Docker socket opt-in (#116)

Set `docker_socket: /var/run/docker.sock` on a runner type to bind-mount that
host socket at the same path in its job containers. The path must be absolute
and clean, with no colons, whitespace, or control characters. Access defaults
to off. The listener passes the configured path as `RUNNER_DOCKER_SOCKET` for
that type and explicitly passes an empty value for every other type, overriding
any inherited value. The provisioner adds `--group-add <host socket gid>` so
the image's runner user can open the socket even if its image-local Docker
group has a different GID. The `:Z` relabel and all other container hardening
stay in place.

**Host Docker socket access is ROOT-EQUIVALENT on the host.** Any job on the
opted-in type can ask the daemon to start a privileged container or mount the
host filesystem. Enable access only on a type whose jobs you trust. Fork PRs
are expected to be gated by the organization's approval policy
(`approval_policy=all_external_contributors`).

Containers started by a job are siblings on the host daemon. The daemon resolves
`docker run -v <path>:...` and Compose bind mounts on the host filesystem.
The job's checkout under `_work` exists only inside the job container because
the job has no host directory mounted. Avoid both relative and absolute bind
mounts of that workspace. Use `docker build` with a workspace context, which
the CLI streams to the daemon, or stream a build context on stdin and use
`COPY` in the Dockerfile. Use named volumes for shared data and `docker cp`
to copy files into or out of containers, including a container that mounts a
named volume you want to populate.

### Daemonless image builds (#118/#119)

Build-type runners build images **without the docker socket and without
`--privileged`** (ADR-0001 "Build path without privilege"). A runner type selects
its builder with `build_tool: kaniko` or `build_tool: buildkit` in the config
(the Go parser is authoritative and rejects any other value, #119); the listener
carries it across the shell-out as `RUNNER_BUILD_TOOL`, and the bash build seam
(`lib/runner-build.sh`) routes it -- `runner_build_dispatch` reads
`RUNNER_BUILD_TOOL` and calls `runner_build_image` with the selected tool
(`none`/empty is a deliberate no-op) -- running the daemonless builder inside a
throwaway rootless container (`--rm` + the same baseline hardening, build context
mounted `:Z`):

| `build_tool` | Builder | How it builds |
| --- | --- | --- |
| `kaniko` | `gcr.io/kaniko-project/executor` (`RUNNER_KANIKO_IMAGE`) | reads Dockerfile + context from `/workspace`, pushes the destination -- no daemon, no socket, no privilege |
| `buildkit` | `moby/buildkit:rootless` (`RUNNER_BUILDKIT_IMAGE`) | rootless BuildKit builds from the mounted context and exports the image -- daemonless, socketless, unprivileged |
| `none` / empty | -- | the type builds no images; the seam refuses to run |

Pin the builder images by digest in production via `RUNNER_KANIKO_IMAGE` /
`RUNNER_BUILDKIT_IMAGE`.

## Concurrency, capacity & lifecycle

- The listener acknowledges each message envelope before batching valid
  request IDs from its availability events. Acquisition and JIT minting for an
  acknowledged envelope continue if shutdown begins. Dispatch still observes
  cancellation.
- The target is the lesser of `TotalAssignedJobs` and the pool bound. Idle,
  busy, and dispatched runners count toward the target. The listener starts
  only the shortfall, and assignment events can supply metadata for those
  runners. Empty polls reuse the latest statistics.
- Assignment events with the same raw job ID are skipped while the first
  assignment is pending dispatch or running. The listener can accept that ID
  again once the worker finishes or dispatch is abandoned.
- **Bounded worker pool (#101):** each runner provisions in its own
  goroutine gated by a semaphore sized to the pool bound, so the loop keeps
  long-polling; a clean shutdown drains in-flight jobs before teardown.
- **Reactive live-admission (ADR-0005, #163):** by default the listener admits
  each job only while every resource (CPU, memory) keeps a reserve headroom free
  (default 10%, the one operator knob, upward-only). Local capacity snapshots
  record admission headroom. A batch that would breach the reserve parks and
  re-probes.
  The host reading is `host-probe.sh` (`HOST_PROBE_CMD`).
- **Auto-sizing (#103):** with `AUTO_SIZE_DEVICES` (or `mode: auto`), the bound
  follows the detected device count instead of reactive admission; otherwise a
  sane default. The internal semaphore is only a goroutine safety ceiling.
- **Reaping (#104/#105/#106):** each container gets a deterministic name +
  `managed-by`/`job-id` labels; the listener sweeps orphaned labelled
  containers and leaked `jit-*` temp dirs on startup and on an interval,
  sparing in-flight jobs.
- **Watchdog (#107):** a per-job watchdog stops+removes a container that
  outlives `RUNNER_JOB_MAX_LIFETIME`.

## Deployment (host binary under systemd, #108/#109)

The host needs **no Go toolchain** — the binary is built inside a golang
container and only the resulting static binary + its sibling shell scripts are
installed.

The whole of it is one command -- see
[`script/deploy-listener.sh`](../script/deploy-listener.sh) and
[`deploy/README.md`](../deploy/README.md). It does the GitHub side (create the
runner type's scale set if it is not there) and the local side (build, install,
service user, 0600 environment file, systemd unit, enable, start), verifies the
listener connected and is reporting capacity, and prints the `runs-on:` line to
paste. The steps below are what it performs.

```sh
# Build the static binary (containerized; reproducible, CGO off):
just build-listener            # -> bin/scaleset-listener

# Install binary + provision-job.sh + reap.sh + lib/ to PREFIX:
sudo just PREFIX=/opt/github-runner-listener install-listener
```

The install preserves the sibling layout the listener shells out against:
`<prefix>/bin/scaleset-listener`, `<prefix>/listener/{provision-job,reap}.sh`,
`<prefix>/lib/*.sh`. systemd then supervises it — see
[`deploy/scaleset-listener.service`](../deploy/scaleset-listener.service) and
[`deploy/README.md`](../deploy/README.md) for the unit and install steps.
