# PostgreSQL 18 (alpine) — self-contained chart

Single-instance PostgreSQL 18 for Kubernetes built on the official
`docker.io/library/postgres:18-alpine` image: chart templates live in this directory, so
there is no upstream chart dependency and every rendered line is editable here. Deploys
one StatefulSet replica with a PVC, a ClusterIP Service, a headless Service, and password
auth sourced from a pre-created Secret.

For the alternative — the upstream Bitnami chart with values overrides — see
[`../bitnami/README.md`](../bitnami/README.md).

## Table of Contents

- [Files](#files)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Values Reference](#values-reference)
- [Connecting](#connecting)
- [PG 18 Data Path](#pg-18-data-path)
- [Init Scripts](#init-scripts)
- [Server Configuration](#server-configuration)
- [Verify](#verify)
- [Restarting and Upgrading](#restarting-and-upgrading)
- [Rotating the Password](#rotating-the-password)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Files

| File | Purpose |
| ---- | ------- |
| `Chart.yaml` | Chart metadata; `appVersion` tracks the image tag (`18-alpine`) |
| `values.yaml` | Default values, with `<STORAGE_CLASS>` to fill in |
| `templates/statefulset.yaml` | Database pod: probes, mounts, `volumeClaimTemplates` |
| `templates/service.yaml` | ClusterIP Service, the connection host |
| `templates/service-headless.yaml` | Headless Service, the StatefulSet's governing Service |
| `templates/configmap.yaml` | `initScripts` mounted at `/docker-entrypoint-initdb.d` |
| `templates/tests/test-connection.yaml` | `helm test` pod (TCP connect + write/read + `hstore`) |
| `templates/_helpers.tpl` | Naming, labels, image/`$PGDATA` derivation, value validation |
| `templates/NOTES.txt` | Post-install instructions printed by Helm |
| `README.md` | This file |

Single chart, no dependencies, no subcharts: `helm dependency build` is never needed.

---

## Prerequisites

- Kubernetes 1.21+ (for `persistentVolumeClaimRetentionPolicy`), Helm 3+
- A StorageClass that can bind `ReadWriteOnce`: `hpe-rwo` on the HPE CSI driver, or
  `longhorn`. Check what exists before installing:

```bash
kubectl get storageclass
```

- The namespace, created once. This chart holds one database per release, so the
  namespace is a parameter, not a fixed value:

```bash
kubectl create ns <namespace>
```

- The password Secret, created in that namespace before the install (the chart reads it
  from a mounted file and never renders a credential into a manifest):

```bash
kubectl -n <namespace> create secret generic postgresql-secret \
  --from-literal=postgres-password="<POSTGRES_SUPERUSER_PASSWORD>"
```

> **Warning**: `values.yaml` ships `persistence.storageClass: "<STORAGE_CLASS>"` on
> purpose. Helm refuses to render it until you set a real value, because a PVC with a
> nonexistent StorageClass installs "successfully" and then sits in `Pending` forever.

---

## Installation

Run from the repository root so the `-f` paths resolve.

### 1. Preview the rendered manifests

```bash
helm template postgresql postgresql/custom \
  -n <namespace> \
  --set persistence.storageClass=<STORAGE_CLASS>
```

### 2. Install

```bash
helm install postgresql postgresql/custom \
  -n <namespace> \
  --set persistence.storageClass=<STORAGE_CLASS> \
  -f postgresql/custom/values.local.yaml
```

Keep credentials and the real `<STORAGE_CLASS>` in `values.local.yaml`; the path matches
the repo gitignore and is never committed.

`fullnameOverride` is pinned to `postgresql`, so the connection host is
`postgresql.<namespace>.svc` no matter what the release is called.

### 3. Watch first-time initialisation

A cold volume runs `initdb`, creates `auth.database`, and runs any `initScripts` before
the pod goes `Ready`. Expect 15-60 seconds on most provisioners.

```bash
kubectl -n <namespace> rollout status statefulset/postgresql --timeout=5m
kubectl -n <namespace> logs postgresql-0 -f
```

Expected output at the end of a cold start:

```
PostgreSQL init process complete; ready for start up.
...
LOG:  database system is ready to accept connections
```

**A pod that is `Running` is not yet `Ready` — wait for `1/1`.**

---

## Values Reference

| Parameter | Default | Description |
| --------- | ------- | ----------- |
| `fullnameOverride` | `postgresql` | Fixes object names, so the Service host is stable |
| `image.registry` | `docker.io` | Change for a private mirror |
| `image.repository` | `postgres` | Official Docker Hub image |
| `image.tag` | `18-alpine` | Must match `appVersion`; currently PostgreSQL 18.x |
| `image.digest` | `""` | `sha256:...` replaces the tag when set |
| `pgMajor` | `"18"` | Builds `$PGDATA`; render fails if it disagrees with `image.tag` |
| `terminationGracePeriodSeconds` | `60` | Room for SIGINT fast shutdown before SIGKILL |
| `service.type` | `ClusterIP` | `NodePort`/`LoadBalancer` for outside-cluster clients |
| `service.port` | `5432` | Service-side port; the container always uses 5432 |
| `service.nodePort` | `null` | Fixed port, validated against 30000-32767 |
| `headlessService.enabled` | `true` | Stable per-pod DNS |
| `auth.username` | `postgres` | Bootstrap superuser |
| `auth.database` | `postgres` | Database created on first boot |
| `auth.existingSecret` | `postgresql-secret` | Required Secret (chart does not create it) |
| `auth.secretKey` | `postgres-password` | Key holding the password |
| `auth.secretMountPath` | `/etc/postgresql/credentials` | Mounted at `<path>/<secretKey>` |
| `auth.hostAuthMethod` | `scram-sha-256` | `pg_hba.conf` method for host connections, first init only |
| `persistence.enabled` | `true` | `false` = ephemeral, dev only |
| `persistence.storageClass` | `<STORAGE_CLASS>` | Placeholder; `""` uses cluster default |
| `persistence.accessMode` | `ReadWriteOnce` | Keep as is; PostgreSQL is single-writer |
| `persistence.size` | `8Gi` | PVC size |
| `persistence.existingClaim` | `""` | Reuse an existing PVC instead of provisioning |
| `persistence.reclaimPolicy` | `Retain` | `Retain` survives `helm uninstall` |
| `resources` | 250m/256Mi – 1/1Gi | Requests and limits |
| `probes.startup.*` | 5s x 60 | Up to 300s for cold-start `initdb` |
| `postgresqlConfig` | see file | Rendered as `postgres -c <key>=<value>` arguments |
| `initScripts` | `{}` | Files for `/docker-entrypoint-initdb.d` (empty volume only) |
| `extraEnv` / `extraEnvVars` | `[]` | Extra env for the postgres container |
| `args` | `[]` | Extra `postgres` arguments |
| `podSecurityContext.fsGroup` | `70` | Required so uid 70 can read the mounted Secret |
| `nodeSelector` / `tolerations` / `affinity` | empty | Placement |
| `tests.enabled` | `true` | Renders the `helm test` pod |
| `tests.hstore` | `true` | Also `create extension hstore` in the test |

Values that changed meaning versus the Bitnami chart in `../bitnami/`: `architecture`,
`readReplicas`, and `primary.*`/`readReplicas.*` splits do not exist here — this chart is
single-instance by design, so resources and persistence are top-level.

---

## Connecting

In-cluster host `postgresql.<namespace>.svc`, port `5432`:

| Value | Default |
| ----- | ------- |
| Host | `postgresql.<namespace>.svc` |
| Port | `5432` |
| User | `postgres` (`auth.username`) |
| Database | `postgres` (`auth.database`) |
| Password | key `postgres-password` of Secret `postgresql-secret` |

Read the password without printing a values file:

```bash
kubectl -n <namespace> get secret postgresql-secret \
  -o jsonpath='{.data.postgres-password}' | base64 -d
```

Throwaway client pod (the server image already contains `psql`):

```bash
kubectl -n <namespace> run psql --rm -it --restart=Never \
  --image=docker.io/library/postgres:18-alpine -- \
  psql --host postgresql.<namespace>.svc --username postgres --dbname postgres
```

From another namespace, use the FQDN `postgresql.<namespace>.svc.cluster.local`. Apps
should reference the password with `valueFrom.secretKeyRef` on the same Secret rather
than copying it.

---

## PG 18 Data Path

PostgreSQL 18 changed the official image's data layout. The chart mounts **one** volume
at `/var/lib/postgresql`, and `$PGDATA` is `/var/lib/postgresql/18/docker`:

| Version | Volume mount | `$PGDATA` |
| ------- | ------------ | --------- |
| <= 17 images | `/var/lib/postgresql/data` | `/var/lib/postgresql/data` |
| 18+ images | `/var/lib/postgresql` | `/var/lib/postgresql/<major>/docker` |

Confirm it after install:

```bash
kubectl -n <namespace> exec postgresql-0 -- sh -c 'echo "$PGDATA"; ls "$PGDATA" | head'
```

Two consequences worth knowing:

- Setting `pgMajor` wrong (or bumping `image.tag` to a new major without it) makes the
  chart refuse to render, because the entrypoint would otherwise `initdb` an empty
  cluster next to the real data.
- The single mount at `/var/lib/postgresql` is what makes `pg_upgrade --link` possible
  across a major version without fighting mount boundaries.

---

## Init Scripts

`initScripts` entries are mounted into `/docker-entrypoint-initdb.d`, which the image
entrypoint processes **only while the data volume is empty**:

```yaml
initScripts:
  00-schema.sql: |
    CREATE SCHEMA IF NOT EXISTS app;
  10-roles.sh: |
    #!/bin/sh
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /dev/stdin <<'SQL'
    CREATE ROLE app LOGIN PASSWORD 'changeme-in-a-secret';
    SQL
```

`.sql`, `.sql.gz`, `.sql.xz`, `.sql.zst` are piped through `psql`; `.sh` files are
executed if executable, sourced otherwise. They run inside the temporary server started
during initialisation, in filename order.

> **Warning**: editing `initScripts` after the first boot changes nothing on a populated
> PVC — the entrypoint logs `Skipping initialization` and moves on. Applying a schema
> change to an existing database means running the SQL yourself (or a migration job), not
> editing values.

---

## Server Configuration

`postgresqlConfig` becomes `postgres -c <key>=<value>` container arguments:

```yaml
postgresqlConfig:
  max_connections: "200"
  shared_buffers: "512MB"
  work_mem: "16MB"
  wal_keep_size: "256MB"
```

Arguments, not a bind-mounted file, because `$PGDATA` is off-limits after initialisation:
a mounted `postgresql.conf` would need a `config_file` indirection into a writable path,
and arguments additionally override anything an earlier `ALTER SYSTEM` left in
`postgresql.auto.conf`. Check what the server is actually using:

```bash
kubectl -n <namespace> exec postgresql-0 -- \
  psql -U postgres -c "select name, setting, source from pg_settings where source != 'default' order by name;"
```

Settings that need a restart take effect on the next pod restart
([Restarting and Upgrading](#restarting-and-upgrading)). Settings that support
`reload` would need `pg_ctl reload`; there is no hook for that in this chart.

`auth.hostAuthMethod` controls the `host all all all <method>` line for TCP clients, also
written only at first init. The pod listens on `*` because the image's `postgresql.conf`
sample and `postgresqlConfig.listen_addresses` both say so.

---

## Verify

```bash
kubectl -n <namespace> get pods -l app.kubernetes.io/name=postgresql
# NAME           READY   STATUS    RESTARTS   AGE
# postgresql-0   1/1     Running   0          3m

kubectl -n <namespace> get pvc
# NAME                    STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
# pgdata-postgresql-0     Bound    pvc-...  8Gi        RWO            <STORAGE_CLASS>

kubectl -n <namespace> logs postgresql-0 --tail=50
# LOG:  database system is ready to accept connections
```

`kubectl get pvc` shows the claim as `<claimTemplate>-<statefulset>-<ordinal>`, so
`pgdata-postgresql-0` here.

Then the Helm test — it connects over TCP through the Service, so it covers DNS, the
Service selectors, SCRAM auth, a write/read round-trip, and `create extension hstore`:

```bash
helm test postgresql -n <namespace>
# Name: postgresql-test
# Session Status: Succeeded
```

The test script retries for up to 150 seconds, so it is safe to run right after an
upgrade. It creates and drops a `helm_smoke_test` table in `auth.database` and leaves the
`hstore` extension installed; do not point this chart at a database you do not own.

---

## Restarting and Upgrading

A restart drops all connections — schedule it.

```bash
kubectl -n <namespace> rollout restart statefulset/postgresql
kubectl -n <namespace> rollout status  statefulset/postgresql
```

Minor version image bump (`18-alpine` to a newer 18.x build) is ordinary: same data
directory format, nothing special required.

```bash
helm upgrade postgresql postgresql/custom -n <namespace> \
  -f postgresql/custom/values.local.yaml \
  --set image.tag=18-alpine3.23
```

> **Warning**: a **major** bump (18 to 19) is not a Helm operation. The data directory is
> version-specific, so a 19 image against PG 18 data refuses to start — see
> [Troubleshooting](#troubleshooting). `pg_upgrade` needs both majors available, a
> maintenance window, and a verified dump or snapshot first.

Pin a dated tag (`18-alpine3.23`) once things work, so a rebuild of the rolling
`18-alpine` tag cannot change your database by itself. The live manifest is helm get
values postgresql -n <namespace> plus the image reference.

---

## Rotating the Password

Helm cannot read `existingSecret`, so it cannot detect a rotation and no manifest change
restarts the pod on its own. Rotate in this order (the password in the file only feeds
`initdb`; the server authenticates against the SCRAM verifier stored in `pg_authid`):

```bash
# 1. Change the role's password. psql needs no host or password here: with no --host it
#    uses the unix socket at /var/run/postgresql, and `local` is `trust` in the pg_hba
#    lines the image writes
kubectl -n <namespace> exec postgresql-0 -- \
  psql -U postgres -c "alter user postgres with password '<NEW_POSTGRES_PASSWORD>';"

# 2. Replace the Secret so a future volume initialises from the new value
kubectl -n <namespace> create secret generic postgresql-secret \
  --from-literal=postgres-password="<NEW_POSTGRES_PASSWORD>" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Confirm clients can still connect with the new password
helm test postgresql -n <namespace>
```

Step 1 is what every client authenticates against. No pod restart is needed for the file
to catch up: this chart mounts the Secret as a **directory** volume, and kubelet refreshes
those files on its own (roughly a sync period; the mount is atomically swapped) — which is
exactly why no `subPath` is used here, since `subPath` mounts keep the value they had at
container start. Do restart if you want the refresh to be immediate.

Update every app's own Secret reference to the rotated value at the same time: existing
connections are unaffected by step 1, but reconnects from an app still holding the old
password start failing.

---

## Uninstall

```bash
helm uninstall postgresql -n <namespace>
```

With the default `persistence.reclaimPolicy: Retain` the PVC and volume survive: so does
every byte of data, and a reinstall with the same `persistence.name` picks the same
cluster back up on PVC `pgdata-postgresql-0`. To also destroy the data:

```bash
kubectl -n <namespace> delete pvc pgdata-postgresql-0
```

> **Warning**: that delete is irreversible. Take a dump first (`pg_dumpall` from a client
> pod, or a volume snapshot through your storage driver) if there is any chance the data
> is needed. PVCs are **not** removed by `helm uninstall` unless you set
> `persistence.reclaimPolicy=Delete`.

---

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `helm template` fails: `persistence.storageClass is the placeholder` | Expected guard. Pass `--set persistence.storageClass=<STORAGE_CLASS>` or set it in `values.local.yaml`; `""` uses the cluster default. |
| `helm template` fails: `pgMajor (17) does not match image.tag (18-alpine)` | Set `pgMajor` to the major in `image.tag`, or revert the tag. Never "fix" it by pointing `pgMajor` at a version whose data does not exist. |
| PVC stuck `Pending`, event `storageclass.storage.k8s.io "<STORAGE_CLASS>" not found` | Typo'd or missing StorageClass. `kubectl get storageclass` and re-upgrade with a real name. |
| Pod `CreateContainerConfigError: ... credentials/postgres-password` or initdb exits with `No such file or directory` on the password path | Secret missing in that namespace, wrong `auth.existingSecret`/`auth.secretKey`, or `podSecurityContext.enabled: false` removed the `fsGroup` that makes the 0440 file group-readable. Recreate the Secret, or keep `fsGroup: 70`. |
| Crashloop with `Error: Database is uninitialized and superuser password is not specified` | Same cause as the row above: `POSTGRES_PASSWORD_FILE` is unreadable, so the entrypoint sees no password. |
| Logs show `Error: in 18+, these Docker images are configured to store database data ... there appears to be PostgreSQL data in: /var/lib/postgresql/data` | The volume was formatted by a pre-18 image (or an old release) with data at `/var/lib/postgresql/data`. Either run `pg_upgrade`, or restore from a dump, or use a fresh volume — **do not** "fix" it by re-pointing the mount, which just hides the old cluster. |
| Pod stays `0/1` for minutes on a cold volume, no errors in logs | Still initialising. The startup probe allows 60 x 5s. Watch `kubectl logs postgresql-0 -f` for `init process complete`. |
| Pod `0/1` after a restart, logs show `database system was shut down at ...` then nothing | Likely recovering from an unclean shutdown (WAL replay). Wait before intervening; only act once liveness begins restarting it. |
| `helm test` fails after `waiting for postgresql.<namespace>.svc:5432` for 150s | Service selectors or the pod are not healthy: `kubectl -n <namespace> describe pod postgresql-0`, then `kubectl -n <namespace> get endpoints postgresql`. An empty endpoints list means the pod is not `Ready`. |
| `helm test` fails with `password authentication failed` | Secret content does not match the role's stored verifier — see [Rotating the Password](#rotating-the-password). |
| `FATAL: database "<name>" does not exist` when connecting | Clients must point at `auth.database` (default `postgres`); `auth.database` is only created on first boot, so changing the value later does not create anything. |
| `OCI runtime create failed ... permission denied` writing `/var/lib/postgresql` | Volume permissions: keep `podSecurityContext.fsGroup: 70`, or pre-chown the volume to 70:70 on drivers that ignore `fsGroup`. |
| Evicted / `OOMKilled` | Raise `resources.limits.memory` above 1Gi or lower `shared_buffers`/`work_mem` in `postgresqlConfig`; a 1Gi limit is a small-workload default. |

---

## References

- Official image and its entrypoint contract: <https://hub.docker.com/_/postgres>
- Image source, including the 18 layout change:
  <https://github.com/docker-library/postgres> (see `18/alpine3.23/Dockerfile`,
  `PGDATA /var/lib/postgresql/18/docker`)
- Server shutdown signals (`STOPSIGNAL SIGINT`):
  <https://www.postgresql.org/docs/current/server-shutdown.html>
- StatefulSet storage policy:
  <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/>
- Sibling variant using the Bitnami chart:
  [`../bitnami/README.md`](../bitnami/README.md)
