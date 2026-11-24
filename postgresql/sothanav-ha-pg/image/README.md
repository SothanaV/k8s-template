# Database image for the pg-ha chart

`postgres:18-bookworm` plus what a repmgr node needs that the official image does not
carry. This directory is published as **`sothanav/pg-ha:18-repmgr`** on Docker Hub, which is
the chart's default `image.repository`, so building it is optional: build and push your own
when you need to audit the layers, mirror the image, or the nodes cannot reach Docker Hub,
then set `image.repository` to where you pushed it.

```bash
# from the repository root
docker build -t registry.local:5000/pg-ha:18-repmgr postgresql/sothanav-ha-pg/image
docker push registry.local:5000/pg-ha:18-repmgr

# what the published tag is right now (also what `image.digest` should be pinned to)
docker buildx imagetools inspect sothanav/pg-ha:18-repmgr
```

## What is in it

| Package / file | Why |
| -------------- | --- |
| `postgresql-18-repmgr` | `repmgr` + `repmgrd` for the matching major; pulls nothing else in |
| `as-postgres` | root → uid 999 step-down (`setpriv`), installed as `/usr/local/bin/gosu` too — see the rule below |
| `iputils-ping` | `repmgr node check`, and operator debugging inside the pod |
| `curl`, `jq`, `ca-certificates` | the two scripts that read and PATCH the pgcat ConfigMap through the API |
| `entrypoint.sh` | PID 1 of a database pod: password file, repmgr.conf, `initdb`/`standby clone`/`node rejoin`, repmgrd supervisor, split-brain guard, pgcat sync loop |
| `pgcat-role-sync.sh` | Finds the real primary, renders `pgcat.toml`, PATCHes the ConfigMap. Also called from repmgr's `promote_command` |
| `pgcat-config-watch.sh` | PID 1 of the pgcat sidecar: GET the ConfigMap, substitute the passwords and the admin username, write `/config/pgcat.toml`, `RELOAD` |
| `/var/log/postgresql` | New versus the compose image: the server log is a file `tail -F` pipes to the container's stdout, so `kubectl logs` shows the server and repmgrd together |

The pgcat container does NOT use this image — it runs upstream
`ghcr.io/postgresml/pgcat`, and only the sidecar next to it is built here.

## Rules worth knowing before you edit it

- **`/usr/local/bin/gosu` is a symlink to `as-postgres`, and the real gosu is not installed.**
  gosu 1.20 (what `postgres:18-bookworm` ships, a Go binary) signals the child it forks, and on a
  node whose container AppArmor profile refuses `signal` that `kill()` comes back `EACCES` — gosu
  then spins at 100% CPU in state `R`, unkillable by SIGKILL, while `gosu --version` still answers
  instantly, so every database pod looks like an `initdb` that never finished. `as-postgres` uses
  util-linux `setpriv` (setgroups/setgid/setuid, then `execvp` in the same process: no child to
  signal) and sets `HOME`, which gosu set and `psql` and a `~/.pgpass` rely on. Measured on the
  affected node (k3s v1.36.5, containerd 2.3.4, Ubuntu 26.04.1, kernel `7.0.0-43-generic`,
  2026-11-24): `gosu postgres id` hangs while the pod carries
  `cri-containerd.apparmor.d (enforce)` and returns in 0 s with
  `appArmorProfile: {type: Unconfined}`; `setpriv --reuid=999 --regid=999 --init-groups id` returns
  immediately either way, and `as-postgres` is that line plus `HOME`. So the step-down survives a
  signal-hungry profile — **but it is a symptom, not the disease**: that same profile also refuses
  the latch signals between PostgreSQL's own processes, and a confined pod still cannot serve one
  query. The chart README's "AppArmor" section is the node-side fix.
- **Never put a backtick or a dollar-parenthesis substitution in an unquoted heredoc body.**
  `entrypoint.sh` writes `repmgr.conf`, `pg_hba.conf` and `.pgpass` with `cat > file <<EOF`,
  which expands: prose wrapped in backticks becomes a command that runs at every pod start,
  and its (empty) output replaces the words in the file. That happened — three
  `command not found` lines per pod and terms missing from `repmgr.conf`, invisible unless
  someone reads the log. `python3 <repo>/heredocguard.py` is the gate for it.

- **The sidecar has no writable filesystem.** `pgcat.sidecarSecurityContext` sets
  `readOnlyRootFilesystem: true` and mounts one emptyDir at `/config`, so a bare `mktemp`
  fails with EROFS (`/tmp` is on the read-only root). Every temporary file in
  `pgcat-config-watch.sh` is created next to the output file instead. This failure is
  invisible outside a cluster: the script logs `HTTP 000` forever and pgcat waits forever for
  a config file.
- **The PostgreSQL major must match in three places**: the base image tag,
  `postgresql-<major>-repmgr`, and `repmgr.pgBindir` in `values.yaml`. The chart fails the
  render when `image.tag` and `pgBindir` disagree, because repmgr shells out to the
  `pg_ctl`/`pg_rewind` of whatever directory it is pointed at.
- **No password in `repmgr.conf`'s `conninfo`.** repmgr stores that string verbatim in its
  `repmgr.nodes` table and prints it in `cluster show`, so a password there ends up replicated
  into the metadatabase on every volume and printed in runbooks. The conninfo carries
  `passfile=/var/lib/postgresql/.pgpass`, which `entrypoint.sh` rebuilds from the Secret at
  every start (image layer, never the PVC), and `PGPASSFILE` is set in the pod's env so
  `kubectl exec` sessions find it too. repmgr has no `pass_file` configuration key: 5.5
  ignores unknown keys with a warning, verified against the binary.
- **`pg_ctl -w` needs an explicit `-t`.** Its built-in wait is 60 s, and a non-zero
  `pg_ctl start` ends PID 1 — which tears down a postmaster that is still replaying WAL and
  turns a slow recovery into a crash loop that can never finish. `PGCTL_START_TIMEOUT`
  (from the startup probe budget) and `PGCTL_STOP_TIMEOUT` (from the grace period) are
  injected by the chart.
- **`STOPSIGNAL SIGTERM` matters**: `entrypoint.sh` traps it and runs `pg_ctl -m fast` inside
  `terminationGracePeriodSeconds`. Switching to `SIGQUIT` or running the postmaster as PID 1
  loses the clean-shutdown path.
- **`promote_command` ends in `{ … || true; }` on purpose.** A refused ConfigMap patch must
  not make `promote_command` return non-zero *after* `pg_promote()` already succeeded: repmgrd
  would report a failed failover. The sync loop retries the publish and the script logs the
  API's reason.
- **Do not change `ENTRYPOINT` expectations.** The chart runs the image's entrypoint for
  database pods and overrides `command` with `pgcat-config-watch.sh` for the sidecar. Both
  paths must keep working from one image.

## Verifying a build without Kubernetes

Two containers on one docker network, with network aliases standing in for the headless
Service records, exercise the same entrypoint and the same environment contract the
StatefulSet injects:

```bash
docker network create pgha
PARTNERS=pg-ha-0.pg-ha-headless.db.svc.cluster.local,pg-ha-1.pg-ha-headless.db.svc.cluster.local
for i in 0 1; do
  docker run -d --name pg-ha-$i --hostname pg-ha-$i --network pgha \
    --network-alias "pg-ha-${i}.pg-ha-headless.db.svc.cluster.local" \
    -v "$PWD/files:/templates:ro" \
    -e POD_NAME="pg-ha-$i" -e POD_NAMESPACE=db -e HEADLESS_SERVICE=pg-ha-headless \
    -e CLUSTER_DOMAIN=cluster.local -e BOOTSTRAP_PRIMARY_POD=pg-ha-0 \
    -e PARTNER_HOSTS="$PARTNERS" \
    -e POSTGRES_PASSWORD=secret -e REPMGR_PASSWORD=secret -e PGCAT_CONFIGMAP=pgcat-config \
    -e PGPASSFILE=/var/lib/postgresql/.pgpass \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    pg-ha:test
done
docker exec pg-ha-0 as-postgres repmgr -f /etc/repmgr/repmgr.conf cluster show
```

Expect two things here, both normal: `pgcat-role-sync.sh` logs an API failure (there is no
API server), and the second node waits for the first. What this loop is worth checking is the
replication itself — `cluster show` and `pg_stat_replication` — because everything else in
the entrypoint is either the config files or that wait.

To check the sidecar in isolation the way Kubernetes runs it, add `--read-only` and nothing
writable but one directory:

```bash
docker run --rm --read-only --user 999:999 \
  -v "$PWD/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" \
  -v /tmp/pgcat-config:/config \
  -e POD_NAMESPACE=db -e PGCAT_CONFIGMAP=pgcat-config \
  -e POSTGRES_PASSWORD=x -e PGCAT_ADMIN_PASSWORD=y \
  --entrypoint /usr/local/bin/pgcat-config-watch.sh pg-ha:test
```

It will log `GET … (HTTP 401/403)` without a real API, which is fine. What must NOT happen is
a scratch-file error, because that is the read-only-root failure mode.
