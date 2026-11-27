# Fleet runbook

The interim self-hosted runner fleet of the `ycpss91255-lab` organisation, as
deployed on 2026-11-28. It stays in this shape until the k3s migration. Every
host runs the scale-set listener (`scaleset-listener@<type>`) from this repo,
deployed with `script/deploy-listener.sh`.

For the deployment steps themselves see the
[deployment guide](../../deploy/README.md); for symptom-to-fix mapping see the
[troubleshooting runbook](TROUBLESHOOTING.md).

## Hosts

Every type uses `docker_socket: /var/run/docker.sock`, which is
**root-equivalent** on the host: a job of any type can control the host Docker
daemon.

### cpu type

Scale set `cpu`, labels `[self-hosted, linux, x64, cpu]`, image
`ghcr.io/ycpss91255-lab/runner-cpu@sha256:9e622508b7a16bcc4805f3ace3cc6490935e2a4bddaf2ba43380bbcef7de024f`.

| host | address / id | size | runner group | notes |
|---|---|---|---|---|
| core.kai-server | C01011920 | 32 cores / 123G | `ci-kai` | |
| core.samuel-server | C01009930 | 8 cores / 30G | `ci-samuel` | shares the host with another user's GitLab runner |
| cyc-nuc-002 | 10.42.0.185, behind core.rpi-002 | 8 cores / 30G | `ci-nuc-002` | |
| cyc-nuc-003 | 10.42.0.227, behind core.rpi-002 | 8 cores / 30G | `ci-nuc-003` | not yet observed taking a job (open items) |
| cyc-nuc-004 | 10.42.0.202, behind core.rpi-002 | 8 cores / 14G | `ci-nuc-004` | |
| core.ada2000-server | C01013605 | | `ci-ada2000-001` | `concurrency.reserve: 30`, leaves room for the gpu type |

### gpu type

Scale set `gpu`, labels `[self-hosted, linux, x64, gpu, cuda]`, image
`ghcr.io/ycpss91255-lab/gpu-runner@sha256:9d37990581dbf3ada886daeb1afca65e1482e0f6d70f83d2e3f9e499c41f933d`
(actions-runner 2.338.2, docker CLI with Compose and Buildx).

| host | id | GPU | runner group | notes |
|---|---|---|---|---|
| core.ada2000-server | C01013605 | RTX 2000 Ada 16G | `ci-ada2000-001` | |
| RTX 5090 dev host | C01013328 | RTX 5090 | `ci-5090` | no passwordless sudo: changes need the owner at the console |

## Deploying or migrating a host

Each host follows the high availability pattern of the
[deployment guide](../../deploy/README.md#high-availability-the-same-scale-set-name-in-one-runner-group-per-host):

- an org owner creates the host's runner group (`ci-<host>`) beforehand;
- the host's `/etc/github-runner-listener/runner-types.yaml` gives every type
  the **same scale set name** as every other host (`cpu`, `gpu`), its own
  `runner_group: ci-<host>`, and **identical labels**;
- deploy (or redeploy after a `git switch main && git pull`) one type at a
  time from the checkout:

```sh
./script/deploy-listener.sh --type cpu          # prints the plan, asks
./script/deploy-listener.sh --type gpu --yes    # non-interactive
```

A legacy single-unit `scaleset-listener.service` is migrated to
`scaleset-listener@<type>` by the same command. Moving a host from its own
scale set name to the shared one means: stop the listener, delete the old set
(`scaleset-admin delete --type <t> --yes`), edit `scale_set` and
`runner_group`, and deploy again (the restore log shows each such step).

**Failover, verified.** A job assigned to a host whose listener was stopped
was requeued to another host's scale set after about 5 minutes. A job is never
stranded behind one stopped host, but it can wait that long.

## Smoke tests

The smoke workflow is manual-only. `runs_on` must match the type's labels
exactly; `docker=true` also proves the host Docker daemon and same-path bind
mounts:

```sh
gh workflow run selfhosted-smoke.yaml --ref main \
  -f runs_on='["self-hosted","linux","x64","cpu"]' -f docker=true
gh workflow run selfhosted-smoke.yaml --ref main \
  -f runs_on='["self-hosted","linux","x64","gpu","cuda"]' -f docker=true
```

The job log's first step prints the host name, so repeated dispatches show
which hosts take jobs.

## Docker GC timer

Every listener host runs `scaleset-listener-gc.timer` daily (installed by
`script/deploy-listener.sh`; see
[section 5 of the deployment guide](../../deploy/README.md#5-docker-gc-of-ci-residue-daily-timer)).
It removes only unpinned runner images pulled by digest and empty CI compose
networks. Check or turn it off with:

```sh
systemctl list-timers scaleset-listener-gc.timer
journalctl -u scaleset-listener-gc.service --since today
sudo systemctl disable --now scaleset-listener-gc.timer   # a redeploy respects this
```

## Known open items

- **cyc-nuc-003 has not been observed taking a job.** Its scale set was
  recreated once to rule out a broken record; the listener is up with the same
  labels as the other hosts. Watch which host the smoke runs land on.
- **Listener tokens are personal `gh` OAuth tokens**, and a `docker_socket`
  job can read them (the socket is root-equivalent). The owner deferred the fix
  (a dedicated GitHub App or scoped credentials) to the k3s migration.
- **The classic runner `C01013328-ycpss91255-docker-org` is disabled but still
  registered.** Its service on the 5090 host is stopped and disabled, and kept
  as the restore fallback (restore log); unregister it once the gpu listener
  has proven itself.

## Restore log

Every host change made while setting up this fleet, with the backup taken and
the command that undoes it. Paths without a directory are in
`/etc/github-runner-listener/`.

### 2026-11-27

| host | change | backup | restore |
|---|---|---|---|
| kai, samuel | runner image 2.335.1 -> 2.338.2 in `runner-types.yaml` | `runner-types.yaml.bak-2.335.1` | `sudo cp <bak> runner-types.yaml && sudo systemctl restart scaleset-listener@cpu` |
| kai, samuel, nuc-002..004 | added `docker_socket: /var/run/docker.sock` (deployed 3f0b64c) | `runner-types.yaml.bak-before-dood` | `sudo cp <bak> runner-types.yaml`, then restart the listener |
| kai, samuel, nuc-002..004 | image -> `ghcr.io/ycpss91255-lab/runner-cpu@sha256:9e6225...`; repo main fd4c734; legacy `scaleset-listener.service` migrated to `scaleset-listener@cpu` (`deploy-listener.sh`) | `runner-types.yaml.bak-before-runner-cpu` | restore the yaml; check out the previous commit (3f0b64c) and redeploy with `./script/deploy-listener.sh --type cpu --skip-github --yes` |
| nuc-002..004 | first deploy: `gh` and `git` (apt, approved), `just` in `~/.local/bin`, repo `~/github_runner`, scale sets `cpu-nuc-00N` | none (new) | `./script/teardown-listener.sh --type cpu`; `scaleset-admin delete --type cpu --yes` |
| nuc-002..004 | `/etc/sudoers.d/90-yunchien-nopasswd` (added by the owner) | none | `sudo rm /etc/sudoers.d/90-yunchien-nopasswd` |

### 2026-11-28

| host | change | backup | restore |
|---|---|---|---|
| kai | `docker image rm` of `ghcr.io/actions/actions-runner@sha256:08c30b0a...` and `@sha256:6d0b2d80...` (unused, not configured) | registry copy | `sudo docker pull ghcr.io/actions/actions-runner@sha256:<digest>` |
| samuel, nuc-002..004 | `docker image rm` of `ghcr.io/actions/actions-runner@sha256:6d0b2d80...` (unused) | registry copy | the same pull |
| kai, samuel, nuc-002 | `docker network rm github_runner_default` (empty, left by CI compose) | none needed | recreated automatically by the next compose run |
| kai | `cpu.env` `SCALE_SET_OWNER` ycpss91255-lab -> C01011920, restarted `@cpu` | `cpu.env.bak-owner` | `sudo cp -p cpu.env.bak-owner cpu.env && sudo systemctl restart scaleset-listener@cpu` |
| kai | moved the orphan drop-in `/etc/systemd/system/scaleset-listener.service.d` (`RestartSec=30s`, legacy unit only) | `legacy-dropin.bak-scaleset-listener.service.d` | `sudo mv` it back, then `sudo systemctl daemon-reload` |
| org | deleted offline ghost JIT runners 2097 and 2099 (dead, single-use) | n/a | not needed (JIT runners are single-use) |
| kai, samuel, nuc-002..004 | `~/github_runner` detached HEAD -> switched to main (fd4c734) | n/a | `git checkout <sha>` |
| github | closed issues #134 (fixed by #135/#139) and #112 (done by #137) | n/a | `gh issue reopen <n>` |
| org | confirmed the old scale sets `cpu-runners` (23) and `gpu-runners` (24) no longer exist | n/a | n/a |
| nuc-003 | recreated scale set `cpu-nuc-003` (id 29 -> 31) to rule out a broken live record; same labels, Default group | n/a | `scaleset-admin delete --type cpu --yes`, then redeploy without `--skip-github` |
| ada2000 | stopped and disabled `scaleset-listener.service`, deleted scale set `gpu-ada2000-001` (id 26): the gpu image lacked the docker CLI, so every gpu job failed; gpu jobs went back to the 5090 classic runner | `runner-types.yaml` unchanged | `sudo systemctl enable --now scaleset-listener` (recreate the scale set with `./script/deploy-listener.sh --type gpu --yes`, i.e. without `--skip-github`) |
| kai | deleted 11 stale `jit-*.jitconfig.env` in the legacy `/opt/github-runner-listener/runners/work` (single-use credentials of dead runners; legacy unit gone) | none (credentials are single-use and expired) | not applicable |
| kai, samuel, nuc-002..004 | redeployed main 6cb63e6: jitconfig reap fix (#147) and daily `scaleset-listener-gc.timer` (#153) | n/a | `sudo systemctl disable --now scaleset-listener-gc.timer`, or redeploy with `--no-docker-gc` |
| ada2000 | deleted 2 stale `jit-*.jitconfig.env` (listener stopped) | none | not applicable |
| org | created runner groups `ci-kai` (6), `ci-samuel` (7), `ci-nuc-002` (8), `ci-nuc-003` (9), `ci-nuc-004` (10), `ci-ada2000-001` (11), visibility selected = the trusted self-hosted repos (base, isaac, isaac_lab, omniverse_web_viewer, sim_asset) | n/a | `gh api -X DELETE orgs/ycpss91255-lab/actions/runner-groups/<id>` |
| org | runner groups 6-11 visibility selected -> all (owner: every repo may use these runners) | n/a | `gh api -X PATCH orgs/ycpss91255-lab/actions/runner-groups/<id> -f visibility=selected`, plus the `selected_repository_ids` |
| ada2000 | main 417f26a; gpu image -> `gpu-runner@sha256:9d3799...` (docker CLI, Compose, Buildx); `docker_socket` on; legacy unit migrated to `scaleset-listener@gpu`; scale set `gpu-ada2000-001` recreated (id 32) | `runner-types.yaml.bak-before-gpu-docker` | restore the yaml and redeploy `--type gpu`; or `sudo systemctl disable --now scaleset-listener@gpu` and `scaleset-admin delete --type gpu --yes` to pull it again |
| kai, samuel, nuc-002..004 | main 80e626b; deleted scale sets `cpu-<host>` (27, 25, 30, 31, 28); new scale set `cpu` in group `ci-<host>` (ids 33, 34, 37, 36, 35); `runner-types.yaml` `scale_set: cpu` and `runner_group: ci-<host>` | `runner-types.yaml.bak-before-group` | `sudo systemctl stop scaleset-listener@cpu`; `scaleset-admin delete --type cpu --yes`; copy `.bak-before-group` back; `./script/deploy-listener.sh --type cpu --yes` (recreates `cpu-<host>` in Default) |
| ada2000 | gpu: scale set `gpu-ada2000-001` (32) -> `gpu` in `ci-ada2000-001` (38); added the cpu type: `cpu` in `ci-ada2000-001` (39), runner-cpu image, `docker_socket`, reserve 30 | `runner-types.yaml.bak-before-group`, `.bak-before-cpu` | gpu as the row above with `--type gpu`; cpu: `./script/teardown-listener.sh --type cpu`, `scaleset-admin delete --type cpu --yes`, restore `.bak-before-cpu` |
| org | created runner group `ci-5090` (12, visibility all) for the 5090 host | n/a | `gh api -X DELETE orgs/ycpss91255-lab/actions/runner-groups/12` |
| 5090 (C01013328) | classic runner service disabled and stopped (still registered); gpu listener `scaleset-listener@gpu`, scale set `gpu` in `ci-5090`, `gpu-runner@sha256:9d3799...`, `docker_socket` | `runner-types.yaml` (new) | `sudo systemctl disable --now scaleset-listener@gpu`; `sudo ./script/teardown-listener.sh --type gpu`; `sudo systemctl enable --now actions.runner.ycpss91255-docker.C01013328-ycpss91255-docker-org.service` |
