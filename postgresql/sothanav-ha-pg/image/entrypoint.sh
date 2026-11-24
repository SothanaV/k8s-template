#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# entrypoint.sh — one PostgreSQL + repmgr node (PID 1) for the pg-ha chart
#
# Kubernetes port of the entrypoint in
# docker-template/postgresql/postgresql-ha. The cluster logic is deliberately
# unchanged; only what a StatefulSet changes is different:
#
#   * Node identity comes from the pod: node_id = ordinal + 1, node_name = pod
#     name. Every address is `<pod>.<headless>.<namespace>.svc.<domain>`, because
#     a bare pod name does NOT resolve through a headless Service (per-pod records
#     live under the Service's subdomain, which is not in the search list).
#   * The boot order compose expressed with `depends_on` is now the StatefulSet's
#     OrderedReady policy: ordinal 0 is Ready before ordinal 1 is even created.
#   * pgcat's config is no longer a shared volume. pgcat-role-sync.sh publishes the
#     rendered pgcat.toml into a ConfigMap through the Kubernetes API; see that file.
#
# Everything below is intentionally runnable only as root: it chowns the volume and then
# steps down to uid 999 with as-postgres, which does with setpriv what the compose stack's
# gosu did. as-postgres rather than gosu because setpriv needs no child to signal, so the
# step-down still works on a node whose container AppArmor profile refuses signals — see
# image/as-postgres and the chart README ("AppArmor").
#
# Required env (all injected by templates/statefulset.yaml):
#   POD_NAME POD_NAMESPACE HEADLESS_SERVICE CLUSTER_DOMAIN BOOTSTRAP_PRIMARY_POD
#   PARTNER_HOSTS POSTGRES_PASSWORD REPMGR_PASSWORD PGCAT_CONFIGMAP
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${POD_NAME:?POD_NAME is required (downward API: metadata.name)}"
: "${POD_NAMESPACE:?POD_NAMESPACE is required (downward API: metadata.namespace)}"
: "${HEADLESS_SERVICE:?HEADLESS_SERVICE is required}"
: "${CLUSTER_DOMAIN:?CLUSTER_DOMAIN is required}"
: "${BOOTSTRAP_PRIMARY_POD:?BOOTSTRAP_PRIMARY_POD is required}"
: "${PARTNER_HOSTS:?PARTNER_HOSTS is required (comma-separated FQDNs, one per node)}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${REPMGR_PASSWORD:?REPMGR_PASSWORD is required}"
: "${PGCAT_CONFIGMAP:?PGCAT_CONFIGMAP is required}"

# --- optional, with the chart defaults --------------------------------------
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
REPMGR_USER="${REPMGR_USER:-repmgr}"
REPMGR_DB="${REPMGR_DB:-repmgr}"
FAILOVER_MODE="${FAILOVER_MODE:-automatic}"
PG_BIN_DIR="${PG_BIN_DIR:-/usr/lib/postgresql/18/bin}"
RECONNECT_ATTEMPTS="${RECONNECT_ATTEMPTS:-4}"
RECONNECT_INTERVAL="${RECONNECT_INTERVAL:-3}"
USE_REPLICATION_SLOTS="${USE_REPLICATION_SLOTS:-yes}"
MONITORING_HISTORY="${MONITORING_HISTORY:-yes}"
# Seconds a standby waits for a usable primary in the cluster before starting repmgrd.
PRIMARY_WAIT_SECONDS="${PRIMARY_WAIT_SECONDS:-60}"
# Directory holding pgcat.toml.tpl, postgresql-append.conf and repmgr-extra.conf
# (the chart's ConfigMap, mounted read-only).
TEMPLATE_DIR="${TEMPLATE_DIR:-/templates}"
PG_APPEND_CONF="${TEMPLATE_DIR}/postgresql-append.conf"
REPMGR_EXTRA_CONF="${TEMPLATE_DIR}/repmgr-extra.conf"

REPMGR_CONF="/etc/repmgr/repmgr.conf"
REPMGRD_LOG="/var/log/repmgr/repmgrd.log"
PG_LOG="/var/log/postgresql/postgresql.log"
REPMGRD_PIDFILE="${REPMGRD_PIDFILE:-/tmp/repmgrd.pid}"
# Flag file that tells the repmgrd supervisor a shutdown is in progress
# (a plain shell variable cannot cross into the background subshell).
SHUTDOWN_FLAG="/tmp/.entrypoint-shutting-down"
rm -f "${SHUTDOWN_FLAG}"

# --- node identity ----------------------------------------------------------
# The ordinal suffix is the only stable per-node number a StatefulSet offers, and it
# is what makes repmgr's node_id survive a restart, a rollout, and a node delete.
NODE_NAME="${POD_NAME}"
ORDINAL="${POD_NAME##*-}"
case "${ORDINAL}" in
  ''|*[!0-9]*)
    echo ">>> [${POD_NAME}] cannot derive an ordinal from POD_NAME='${POD_NAME}'; this entrypoint expects a StatefulSet pod (<name>-<ordinal>)" >&2
    exit 1
    ;;
esac
# 10# forces base 10: a three-digit statefulset would otherwise produce octal at 08/09.
NODE_ID=$(( 10#${ORDINAL} + 1 ))

DNS_SUFFIX="${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
SELF_HOST="${NODE_NAME}.${DNS_SUFFIX}"
PRIMARY_HOST="${BOOTSTRAP_PRIMARY_POD}.${DNS_SUFFIX}"

# The upstream postgres image exports PGDATA=/var/lib/postgresql/18/docker, which lives
# in the container layer, NOT on the volume mounted at /var/lib/postgresql/data. Using
# that value silently loses all data on every recreate, so pin PGDATA to the mount.
PGDATA_MOUNT="/var/lib/postgresql/data"
case "${PGDATA:-}" in
  "${PGDATA_MOUNT}"|"${PGDATA_MOUNT}"/*) : ;;
  *) [ -n "${PGDATA:-}" ] && echo ">>> [${NODE_NAME}] PGDATA='${PGDATA}' is outside the mounted volume, using '${PGDATA_MOUNT}/pgdata'"
     PGDATA="${PGDATA_MOUNT}/pgdata" ;;
esac
export PGDATA

echo ">>> [${NODE_NAME}] node_id=${NODE_ID} self=${SELF_HOST} bootstrap primary=${PRIMARY_HOST} failover=${FAILOVER_MODE}"

# ---------------------------------------------------------------------------
# Graceful shutdown handler (runs on `kubectl delete pod`, rollouts, eviction)
# ---------------------------------------------------------------------------
graceful_shutdown() {
  echo ">>> [${NODE_NAME}] Received shutdown signal. Stopping repmgrd and PostgreSQL gracefully..."
  : > "${SHUTDOWN_FLAG}"          # tell the supervisor (other subshell) not to respawn repmgrd
  # Kill the supervisor first, otherwise it respawns repmgrd mid-shutdown.
  if [ -n "${REPMGRD_SUPERVISOR_PID:-}" ]; then
    kill -TERM "${REPMGRD_SUPERVISOR_PID}" 2>/dev/null || true
  fi
  if [ -f "${REPMGRD_PIDFILE}" ]; then
    kill -TERM "$(cat "${REPMGRD_PIDFILE}")" 2>/dev/null || true
  fi
  if [ -n "${PGCAT_SYNC_PID:-}" ]; then
    kill -TERM "${PGCAT_SYNC_PID}" 2>/dev/null || true
  fi
  if as-postgres pg_ctl -D "${PGDATA}" status >/dev/null 2>&1; then
    as-postgres pg_ctl -D "${PGDATA}" -m fast -w -t "${PGCTL_STOP_TIMEOUT}" stop || true
  fi
  echo ">>> [${NODE_NAME}] Shutdown complete."
  exit 0
}
# `pg_ctl -w` gives up after 60 seconds by default, which is a trap in a container: a
# standby replaying a large WAL backlog is still perfectly healthy at 60 s, and a non-zero
# `pg_ctl start` under `set -e` would end PID 1, tear the postmaster down mid-recovery and
# crash-loop the pod without ever finishing the replay that the generous `probes.startup`
# budget exists to allow. The chart injects both budgets from the pod's own probe and
# grace-period settings; the fallbacks keep a standalone `docker run` of this image working.
PGCTL_START_TIMEOUT="${PGCTL_START_TIMEOUT:-600}"
PGCTL_STOP_TIMEOUT="${PGCTL_STOP_TIMEOUT:-120}"

trap graceful_shutdown SIGTERM SIGINT

# ---------------------------------------------------------------------------
# 0. Create ~/.pgpass for the postgres user
# ---------------------------------------------------------------------------
# repmgr opens its connections without a password in the conninfo and lets libpq supply it
# from a password file, so `standby follow`, `node rejoin` and the walreceiver all need this
# file to exist under scram-sha-256 over TCP.
#
# It is not merely a convenience. repmgr stores the conninfo it was given VERBATIM in the
# `repmgr.nodes` table and prints it in every `cluster show`, so a password in conninfo ends
# up replicated into the repmgr metadatabase on all three volumes and on every operator's
# screen — repmgr's own documentation says as much and recommends a password file instead.
#
# /var/lib/postgresql is the image layer (the volume mounts at .../data), so this file never
# lands on the PVC and is rebuilt on every pod start. PGPASSFILE is exported because libpq
# only finds this file by default as $HOME/.pgpass, and because `kubectl exec` builds a fresh
# environment from the pod spec: without the variable, the runbook commands in README.md
# would not authenticate.
PGPASS_FILE="${PGPASS_FILE:-${PGPASSFILE:-/var/lib/postgresql/.pgpass}}"
cat > "${PGPASS_FILE}" <<EOF
# generated by entrypoint.sh - do not edit
*:*:*:${REPMGR_USER}:${REPMGR_PASSWORD}
EOF
chown postgres:postgres "${PGPASS_FILE}"
chmod 600 "${PGPASS_FILE}"
export PGPASSFILE="${PGPASS_FILE}"

# ---------------------------------------------------------------------------
# 1. Write /etc/repmgr/repmgr.conf
# ---------------------------------------------------------------------------
# mkdir is for a non-Debian base image or a read-only-layer surprise; the Dockerfile in
# this directory already creates all three.
mkdir -p /etc/repmgr /var/log/repmgr /var/log/postgresql

cat > "${REPMGR_CONF}" <<EOF
node_id=${NODE_ID}
node_name='${NODE_NAME}'
# No password in conninfo. repmgr stores this string verbatim in its repmgr.nodes table and
# echoes it in 'cluster show', so a password here would be replicated to every standby's
# volume and printed in operator runbooks; the passfile= below keeps the credential in the
# file above, and libpq resolves it for every connection repmgr or pg_rewind opens. (repmgr
# has no pass_file configuration key — repmgr 5.5 ignores unknown keys with a warning.)
#
# HEREDOC DISCIPLINE: this body is unquoted, so bash expands it. A backtick pair, or a
# dollar-parenthesis substitution, anywhere in it is RUN AS A COMMAND and its output becomes
# file content. An earlier revision of the comment above wrapped two of its terms in
# backticks, so every pod start executed them as programs, logged 'command not found' three
# times, and blanked the words out of the rendered file — visible only as three stray lines
# in the log. Quote with apostrophes here, or move the prose outside the heredoc.
conninfo='host=${SELF_HOST} user=${REPMGR_USER} dbname=${REPMGR_DB} passfile=${PGPASS_FILE} connect_timeout=2'
data_directory='${PGDATA}'
pg_bindir='${PG_BIN_DIR}'
use_replication_slots=${USE_REPLICATION_SLOTS}
monitoring_history=${MONITORING_HISTORY}
failover='${FAILOVER_MODE}'
# The braces matter. Without them a refused ConfigMap patch (missing RBAC, API down) makes
# promote_command return non-zero AFTER the promotion already succeeded, which repmgrd
# reports as a failed promotion — it may retry the promote on a node that is already a
# primary. pgcat being stale is the lesser failure, the periodic sync loop retries it every
# PGCAT_SYNC_SECONDS, and the script logs the reason loudly.
promote_command='/usr/bin/repmgr standby promote -f ${REPMGR_CONF} --log-to-file && { /usr/local/bin/pgcat-role-sync.sh --force || true; }'
follow_command='/usr/bin/repmgr standby follow -f ${REPMGR_CONF} --log-to-file --upstream-node-id=%n'
reconnect_attempts=${RECONNECT_ATTEMPTS}
reconnect_interval=${RECONNECT_INTERVAL}
log_file='${REPMGRD_LOG}'
EOF

# repmgr.extraConfig, rendered by the chart as verbatim lines. Appended last: repmgr
# takes the last occurrence of a repeated key, so an operator override wins over the
# block above (the chart rejects the keys it must own, so this cannot break identity).
if [ -s "${REPMGR_EXTRA_CONF}" ]; then
  echo ">>> [${NODE_NAME}] appending ${REPMGR_EXTRA_CONF} (repmgr.settings)"
  printf '\n' >> "${REPMGR_CONF}"
  cat "${REPMGR_EXTRA_CONF}" >> "${REPMGR_CONF}"
fi

chown postgres:postgres "${REPMGR_CONF}"
mkdir -p /var/log/repmgr /var/log/postgresql
touch "${REPMGRD_LOG}" "${PG_LOG}" && chown postgres:postgres "${REPMGRD_LOG}" "${PG_LOG}"

# ---------------------------------------------------------------------------
# Return the hostname of the current primary among PARTNER_HOSTS (empty if none)
# ---------------------------------------------------------------------------
find_active_primary() {
  local host is_recovery
  IFS=',' read -ra NODES <<< "${PARTNER_HOSTS}"
  for host in "${NODES[@]}"; do
    host="$(echo "${host}" | xargs)"
    [ "${host}" = "${SELF_HOST}" ] && continue
    if PGPASSWORD="${REPMGR_PASSWORD}" as-postgres pg_isready -h "${host}" -U "${REPMGR_USER}" -d "${REPMGR_DB}" -t 2 >/dev/null 2>&1; then
      is_recovery="$(PGPASSWORD="${REPMGR_PASSWORD}" as-postgres psql -h "${host}" -U "${REPMGR_USER}" -d "${REPMGR_DB}" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "")"
      if [ "${is_recovery}" = "f" ]; then
        echo "${host}"
        return 0
      fi
    fi
  done
  echo ""
}

# ---------------------------------------------------------------------------
# 2. First boot (PGDATA is still empty)
# ---------------------------------------------------------------------------
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  mkdir -p "${PGDATA}"
  chown -R postgres:postgres "$(dirname "${PGDATA}")"
  chmod 700 "${PGDATA}"

  if [ "${NODE_NAME}" = "${BOOTSTRAP_PRIMARY_POD}" ]; then
    echo ">>> [${NODE_NAME}] Initializing PRIMARY node..."
    # Use a real temp file: process substitution (<(...)) creates a pipe owned by
    # root, which the step-down cannot reopen after dropping privileges to 'postgres'.
    PWFILE="$(mktemp /tmp/.pg_pwfile.XXXXXX)"
    printf '%s\n' "${POSTGRES_PASSWORD}" > "${PWFILE}"
    chown postgres:postgres "${PWFILE}" && chmod 600 "${PWFILE}"
    as-postgres initdb --username="${POSTGRES_USER}" --pwfile="${PWFILE}"
    # Unlink it as soon as initdb has consumed it. This is the only on-disk copy of the
    # superuser password in the container (.pgpass holds the replication role, not this one),
    # and `initdb` copies it into the freshly initialised cluster anyway.
    rm -f "${PWFILE}"

    {
      # Not operator-tunable: '*' so the other pods can reach this node for streaming
      # and repmgrd pings, and repmgr must be preloaded for its monitoring functions.
      echo "listen_addresses = '*'"
      echo "shared_preload_libraries = 'repmgr'"
      # postgresqlConfig from values, rendered by the chart. First init only: on a
      # populated volume this file is never read again (use ALTER SYSTEM there).
      if [ -s "${PG_APPEND_CONF}" ]; then
        cat "${PG_APPEND_CONF}"
      fi
    } >> "${PGDATA}/postgresql.conf"

    cat >> "${PGDATA}/pg_hba.conf" <<EOF
host all all 0.0.0.0/0 scram-sha-256
host replication ${REPMGR_USER} 0.0.0.0/0 scram-sha-256
EOF

    as-postgres pg_ctl -D "${PGDATA}" -w -t "${PGCTL_START_TIMEOUT}" start -l "${PG_LOG}"
    as-postgres psql -v ON_ERROR_STOP=1 <<-EOSQL
      CREATE USER ${REPMGR_USER} WITH SUPERUSER REPLICATION PASSWORD '${REPMGR_PASSWORD}';
      CREATE DATABASE ${REPMGR_DB} OWNER ${REPMGR_USER};
      ALTER USER ${REPMGR_USER} SET search_path TO ${REPMGR_DB}, public;
EOSQL
    as-postgres repmgr -f "${REPMGR_CONF}" primary register
    as-postgres pg_ctl -D "${PGDATA}" -m fast -w -t "${PGCTL_STOP_TIMEOUT}" stop

  else
    echo ">>> [${NODE_NAME}] Waiting for PRIMARY (${PRIMARY_HOST}) to be ready..."
    until PGPASSWORD="${REPMGR_PASSWORD}" as-postgres pg_isready -h "${PRIMARY_HOST}" -U "${REPMGR_USER}" -d "${REPMGR_DB}" -t 2 >/dev/null 2>&1; do
      sleep 2
    done
    sleep 3

    echo ">>> [${NODE_NAME}] Cloning from PRIMARY (${PRIMARY_HOST})..."
    PGPASSWORD="${REPMGR_PASSWORD}" as-postgres repmgr -h "${PRIMARY_HOST}" -U "${REPMGR_USER}" -d "${REPMGR_DB}" -f "${REPMGR_CONF}" standby clone --fast-checkpoint

    as-postgres pg_ctl -D "${PGDATA}" -w -t "${PGCTL_START_TIMEOUT}" start -l "${PG_LOG}"
    as-postgres repmgr -f "${REPMGR_CONF}" standby register
    as-postgres pg_ctl -D "${PGDATA}" -m fast -w -t "${PGCTL_STOP_TIMEOUT}" stop
  fi

# ---------------------------------------------------------------------------
# 3. Reboot / recovery after a restart (PGDATA already holds data)
# ---------------------------------------------------------------------------
else
  echo ">>> [${NODE_NAME}] Existing PGDATA detected. Checking cluster state..."
  chown -R postgres:postgres "$(dirname "${PGDATA}")"
  chmod 700 "${PGDATA}"

  # Drop the stale PID file left behind if the container was killed with -9
  # (OOMKill, eviction, `kubectl delete pod --force`).
  rm -f "${PGDATA}/postmaster.pid"

  ACTIVE_PRIMARY="$(find_active_primary)"
  if [ -n "${ACTIVE_PRIMARY}" ]; then
    echo ">>> [${NODE_NAME}] Active primary found at '${ACTIVE_PRIMARY}'. Running node rejoin (--force-rewind)..."
    # The conninfo is passed on the command line (world-readable through /proc/<pid>/cmdline
    # for as long as a rewind of a large database takes), so it carries a passfile reference
    # and not the password.
    as-postgres repmgr -f "${REPMGR_CONF}" node rejoin \
      -d "host=${ACTIVE_PRIMARY} user=${REPMGR_USER} dbname=${REPMGR_DB} passfile=${PGPASS_FILE}" \
      --force-rewind || {
        echo ">>> [${NODE_NAME}] Rewind failed or not needed; attempting standby follow after start..."
      }
  else
    echo ">>> [${NODE_NAME}] No other active primary found. Starting PostgreSQL in the role recorded in PGDATA..."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Start PostgreSQL and the repmgrd daemon
# ---------------------------------------------------------------------------
# `repmgr node rejoin` (above) starts the server for us and returns. Calling
# pg_ctl start again hits "lock file postmaster.pid already exists" and kills the pod,
# and the postmaster repmgr started logs somewhere nobody reads, so always stop it and
# start it from this script instead — with -l so the server log lands in the file that
# `tail -F` below pipes to `kubectl logs`.
ensure_postgres_started() {
  if as-postgres pg_ctl -D "${PGDATA}" status >/dev/null 2>&1; then
    echo ">>> [${NODE_NAME}] PostgreSQL was started by node rejoin, restarting it for clean logging..."
    as-postgres pg_ctl -D "${PGDATA}" -m fast -w -t "${PGCTL_STOP_TIMEOUT}" stop || true
  fi
  echo ">>> [${NODE_NAME}] Starting PostgreSQL (up to ${PGCTL_START_TIMEOUT}s for crash recovery)..."
  as-postgres pg_ctl -D "${PGDATA}" -w -t "${PGCTL_START_TIMEOUT}" start -l "${PG_LOG}"
}
ensure_postgres_started

# Make sure the latest state is registered in the repmgr metadata.
if [ -n "${ACTIVE_PRIMARY:-}" ]; then
  PGPASSWORD="${REPMGR_PASSWORD}" as-postgres repmgr -f "${REPMGR_CONF}" standby register --force || true
fi

# Split-brain guard. A standby that cannot see a primary must not release repmgrd yet:
# repmgrd would conclude the primary is dead and promote itself, giving a competing
# primary while the rest of the cluster is simply still starting (a rollout restarts
# pods one at a time, and a whole-namespace delete/restore looks identical from here).
#
# The criterion is the data directory, not the pod name: `standby.signal` means this
# node's own state says "follow somebody". A node without it is a primary as far as its
# volume is concerned and needs nobody else to know it.
if [ -z "${ACTIVE_PRIMARY:-}" ] && [ -f "${PGDATA}/standby.signal" ]; then
  echo ">>> [${NODE_NAME}] No active primary visible yet, waiting up to ${PRIMARY_WAIT_SECONDS}s for the cluster to settle..."
  DEADLINE=$(( $(date +%s) + PRIMARY_WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    ACTIVE_PRIMARY="$(find_active_primary)"
    [ -n "${ACTIVE_PRIMARY}" ] && break
    sleep 2
  done
  if [ -n "${ACTIVE_PRIMARY}" ]; then
    echo ">>> [${NODE_NAME}] Primary is up at '${ACTIVE_PRIMARY}', safe to monitor."
  else
    # This node booted without ever seeing a primary. That happens both when the whole
    # stack is restarting (the primary is merely slow) and when the primary is genuinely
    # gone, and a standby cannot tell the two apart. Promoting here would split the
    # cluster, so monitor only and leave the decision to an operator. repmgrd 5.x has no
    # --monitor-only flag; the equivalent is failover='manual' in repmgr.conf.
    echo ">>> [${NODE_NAME}] Still no primary after ${PRIMARY_WAIT_SECONDS}s: starting repmgrd in monitoring-only mode (failover=manual)."
    echo ">>> [${NODE_NAME}] Refusing to promote a node that never saw a primary (split-brain guard)."
    echo ">>> [${NODE_NAME}] If ${PRIMARY_HOST} is really gone, promote deliberately with:"
    echo ">>> [${NODE_NAME}]   kubectl exec ${NODE_NAME} -- as-postgres repmgr standby promote -f ${REPMGR_CONF}"
    sed -i "s|^failover=.*|failover='manual'|" "${REPMGR_CONF}"
  fi
fi

echo ">>> [${NODE_NAME}] Starting repmgrd daemon..."
# repmgrd exits immediately at startup when it cannot reach its upstream
# ("upstream node must be running before repmgrd can start"), and nothing restarted it
# in the compose version: the container still looked Up (tail held PID 1) while no
# monitoring/failover daemon was left, so automatic failover silently never happened.
# Run it under a loop so it self-heals.
# --daemonize=false is required because its default is true (it forks and the parent
# returns 0 immediately, the loop would think repmgrd died, and the next attempt then
# trips over "PID file exists"). --no-pid-file keeps repmgrd from rejecting startup over
# a pid file left by a previous pod.
repmgrd_supervisor() {
  while true; do
    as-postgres repmgrd -f "${REPMGR_CONF}" --daemonize=false --no-pid-file >>"${REPMGRD_LOG}" 2>&1 &
    REPMGRD_PID=$!
    echo "${REPMGRD_PID}" > "${REPMGRD_PIDFILE}"
    RC=0
    wait "${REPMGRD_PID}" || RC=$?     # do not read $? directly: set -e would end the subshell first
    if [ -f "${SHUTDOWN_FLAG}" ]; then
      return 0
    fi
    printf '[%s] [NOTICE] repmgrd exited (code %s); restarting in 5s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "${RC}" >> "${REPMGRD_LOG}"
    sleep 5
  done
}
repmgrd_supervisor &
REPMGRD_SUPERVISOR_PID=$!

# ---------------------------------------------------------------------------
# 5. Keep the pgcat write endpoint pointed at the current primary
# ---------------------------------------------------------------------------
# pgcat reads every role from pgcat.toml (it never checks pg_is_in_recovery() itself).
# If nobody rewrites that file, writes keep going to the old node after a failover.
# Here "rewrite" means PATCHing the ConfigMap pgcat's sidecar reads, so it needs the
# pod's ServiceAccount token (README "RBAC"). Only the primary node publishes — the
# script checks its own recovery state and exits quietly otherwise, which is why all
# nodes can run the same loop.
echo ">>> [${NODE_NAME}] Syncing pgcat write endpoint..."
/usr/local/bin/pgcat-role-sync.sh || true

pgcat_sync_loop() {
  while true; do
    sleep "${PGCAT_SYNC_SECONDS:-5}"
    /usr/local/bin/pgcat-role-sync.sh || true
  done
}
pgcat_sync_loop &
PGCAT_SYNC_PID=$!

# Tail both logs without blocking, so the SIGTERM trap can run immediately and
# `kubectl logs` shows initdb, repmgrd, and the server log in one stream.
as-postgres tail -F "${REPMGRD_LOG}" "${PG_LOG}" &
TAIL_PID=$!
wait "${TAIL_PID}"
