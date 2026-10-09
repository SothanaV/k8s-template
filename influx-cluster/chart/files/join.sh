#!/bin/sh
# Registers this release's meta and data nodes with `influxd-ctl`, then seeds the admin
# user and cluster.databases through the data node HTTP API.
#
# Rendered next to this script by the ConfigMap:
#   /config/meta-addrs   one `<fqdn>:<metaAPI>` per line, ordinal order
#   /config/data-addrs   one `<fqdn>:<dataTCP>` per line, ordinal order
#   /config/databases    `name|<replication or ->` per line
#
# Environment (all set by the Job template):
#   JOIN_ENTRY          meta address this Job drives `influxd-ctl -bind` at
#   ENTRY_HTTP          same host, meta API port (for the /ping probe)
#   DATA_HOST           data Service DNS name
#   DATA_HTTP_PORT      data HTTP port
#   CTL_AUTH_TYPE       none | jwt
#   CTL_SECRET          meta internal shared secret, when CTL_AUTH_TYPE=jwt
#   ADMIN_USER / ADMIN_PASSWORD / ADMIN_ALL_PRIVILEGES  when cluster.adminUser.enabled
#   AUTH_INFLUX         "on" when the data HTTP API needs credentials
#   CREATE_ADMIN_USER / CREATE_DATABASES / JOIN_ONLY    "on"/"off"
#   WAIT_PORT_TIMEOUT / WAIT_LEADER_TIMEOUT / WAIT_DATA_TIMEOUT  seconds
#
# `add-meta`/`add-data` answer 200 for an address that is already a member, so the loop is
# about convergence and legible logs, not about avoiding a failure mode. What the
# exact-address semantics do mean: membership is keyed on the pod's DNS name, so a rename
# (`fullnameOverride`, another namespace) or a reused PVC leaves the OLD address in the
# raft set as a phantom member — remove it with `influxd-ctl remove-meta`, see README.
set -eu

log() { echo "[join $(date -u +%H:%M:%S)] $*"; }
die() { echo "[join] ERROR: $*" >&2; exit 1; }
now() { date -u +%s; }
nonblank() { tr -d '\r' | grep -v '^[[:space:]]*$' || true; }

[ -r /config/meta-addrs ] || die "missing /config/meta-addrs"
[ -n "${JOIN_ENTRY:-}" ] || die "JOIN_ENTRY is not set"
[ -n "${DATA_HOST:-}" ] || die "DATA_HOST is not set"

META_ADDRS=$(nonblank < /config/meta-addrs)
DATA_ADDRS=$(nonblank < /config/data-addrs)
DATABASES=$(nonblank < /config/databases)
[ -n "$META_ADDRS" ] || die "/config/meta-addrs is empty"

DATA_URL="http://${DATA_HOST}:${DATA_HTTP_PORT}"

# ---------------------------------------------------------------------------
# influxd-ctl wrapper. With meta auth on, `influxd-ctl` signs its own request as a JWT
# (-secret must be the meta INTERNAL shared secret: the handler verifies tokens whose
# `username` claim is empty against InternalSharedSecret).
# ---------------------------------------------------------------------------
ctl() {
    if [ "${CTL_AUTH_TYPE:-none}" = "jwt" ]; then
        [ -n "${CTL_SECRET:-}" ] || die "CTL_AUTH_TYPE=jwt but CTL_SECRET is empty"
        influxd-ctl -auth-type jwt -secret "$CTL_SECRET" -bind "$JOIN_ENTRY" "$@"
    else
        influxd-ctl -bind "$JOIN_ENTRY" "$@"
    fi
}

show() { ctl show 2>/dev/null || true; }

# A snapshot right after the first add-meta often comes back empty: no leader yet means
# no raft state to read. Everything in this script is therefore "count what is there,
# register what is missing, loop". A not-yet-speaking entry node makes `show` return an
# empty string, which count_listed/missing_list read as "nothing is a member yet".
count_listed() {
    list="$1"; members="$2"; n=0
    for addr in $list; do
        printf '%s' "$members" | grep -qF -- "$addr" && n=$((n + 1))
    done
    echo "$n"
}

missing_list() {
    list="$1"; members="$2"; out=""
    for addr in $list; do
        printf '%s' "$members" | grep -qF -- "$addr" || out="${out} ${addr}"
    done
    echo "$out"
}

# Any HTTP reply counts as "listening" — including 401 (meta auth on) and 503 (store
# still opening): both mean the listener is up.
wait_port() {
    host="$1"; port="$2"; deadline=$(( $(now) + ${3:-300} ))
    while :; do
        if curl -s -o /dev/null --max-time 3 "http://${host}:${port}/ping"; then
            log "  ${host}:${port} is up"
            return 0
        fi
        [ "$(now)" -lt "$deadline" ] || return 1
        sleep 2
    done
}

# Runs InfluxQL against the data HTTP API. Two failure shapes must be told apart, and
# curl alone cannot tell them:
#   - HTTP 4xx with a top-level {"error": ...} = the statement itself is wrong (a retry
#     will never help), or the cluster refuses our credentials
#   - HTTP 200 with {"results":[{"error": ...}]} = a per-statement error
#   - HTTP 5xx / connection refused = the cluster is still forming -> retryable
# Sets RETRY_LATER=1 for the retryable case, prints the reason, returns non-zero.
RETRY_LATER=0
HTTP_BODY=$(mktemp) || HTTP_BODY=/tmp/join-body.$$
api_query() {
    local code
    RETRY_LATER=0
    if [ "${AUTH_INFLUX:-off}" = "on" ]; then
        code=$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' --max-time 30 \
            -u "${ADMIN_USER}:${ADMIN_PASSWORD}" --data-urlencode "q=$1" "${DATA_URL}/query" 2>&1) || code=000
    else
        code=$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' --max-time 30 \
            --data-urlencode "q=$1" "${DATA_URL}/query" 2>&1) || code=000
    fi
    case "$code" in
        2*) ;;
        # 5xx and 000 (no reply at all) mean the cluster is still forming: retryable
        5*|000) echo "HTTP ${code}: $(tr -d '\n' < "$HTTP_BODY")" >&2; return 1 ;;
        *) echo "HTTP ${code}: $(tr -d '\n' < "$HTTP_BODY")" >&2; return 1 ;;
    esac
    # A data node answers 200 for per-statement errors too, including `database already
    # exists`, which arrives when another actor won the race a moment ago.
    if grep -q '"error"' "$HTTP_BODY"; then
        if grep -q 'already exists' "$HTTP_BODY"; then
            # InfluxQL has no `CREATE ... IF NOT EXISTS` (the parser rejects `IF`), and
            # the "user already exists" / "database already exists" replies arrive as
            # HTTP 200 with a per-statement error. Treat them as success and tell the
            # caller, so re-runs converge without grepping SHOW output for names (which
            # collides with column labels like "user"/"admin").
            ALREADY_EXISTS=1
            cat "$HTTP_BODY"
            return 0
        fi
        tr -d '\n' < "$HTTP_BODY" >&2
        return 1
    fi
    ALREADY_EXISTS=0
    cat "$HTTP_BODY"
}

# ---------------------------------------------------------------------------
# 1. Every meta API port must answer before the first add-meta, because serveJoin reads
#    the target node's /status; and the node named by -bind must be one of ours.
# ---------------------------------------------------------------------------
log "waiting for ${META_ADDRS}$(printf '\n')"
for addr in $META_ADDRS; do
    host=${addr%:*}
    port=${addr##*:}
    wait_port "$host" "$port" "${WAIT_PORT_TIMEOUT:-300}" ||
        die "meta node ${addr} never answered on ${WAIT_PORT_TIMEOUT:-300}s — check its PVC binding and pod logs"
    if [ "${host}:${port}" = "$JOIN_ENTRY" ]; then entry_seen=1; fi
done
[ "${entry_seen:-0}" = "1" ] || die "JOIN_ENTRY ${JOIN_ENTRY} is not part of the meta replica set"

# ---------------------------------------------------------------------------
# 2. Register meta nodes. The very first add-meta bootstraps the raft group from the node
#    named by -bind, so that entry iterates with the entry node first.
# ---------------------------------------------------------------------------
META_EXPECTED=$(printf '%s\n' "$META_ADDRS" | grep -c . )
log "registering ${META_EXPECTED} meta nodes"
attempt=0
while :; do
    attempt=$((attempt + 1))
    members=$(show)
    missing=$(missing_list "$META_ADDRS" "$members")
    if [ -z "$missing" ]; then
        log "all meta nodes are members"
        break
    fi
    if [ "$attempt" -gt 30 ]; then
        die "meta nodes still missing after ${attempt} attempts:${missing}"
    fi
    for addr in $missing; do
        # -bind decides which node bootstraps the group; on the first attempt force the
        # entry node so the raft set is seeded from a pod of this release
        if [ "$attempt" -eq 1 ] && [ "$addr" != "$JOIN_ENTRY" ] && [ -z "$members" ]; then
            log "  waiting for the entry node ${JOIN_ENTRY} to bootstrap before ${addr}"
            continue
        fi
        log "  add-meta ${addr} (attempt ${attempt})"
        if out=$(ctl add-meta "$addr" 2>&1); then
            log "    ${out}"
        else
            log "    rejected: ${out}"
        fi
    done
    sleep 5
done

# ---------------------------------------------------------------------------
# 3. Full peer set before touching data nodes: serveAddData answers "data node failed to
#    contact valid meta server in list []" while there is no leader.
# ---------------------------------------------------------------------------
log "waiting for a meta leader with all ${META_EXPECTED} peers"
deadline=$(( $(now) + ${WAIT_LEADER_TIMEOUT:-180} ))
while :; do
    joined=$(count_listed "$META_ADDRS" "$(show)")
    [ "$joined" -ge "$META_EXPECTED" ] && { log "meta cluster: ${joined}/${META_EXPECTED}"; break; }
    [ "$(now)" -lt "$deadline" ] || die "meta cluster holds ${joined}/${META_EXPECTED} nodes after ${WAIT_LEADER_TIMEOUT:-180}s: no quorum. Check pods stuck NotReady, or a stale raft store in a reused PVC (README: Stale raft state)"
    log "  ${joined}/${META_EXPECTED} meta nodes in the raft set..."
    sleep 5
done

# ---------------------------------------------------------------------------
# 4. Register data nodes.
# ---------------------------------------------------------------------------
if [ -n "$DATA_ADDRS" ]; then
    DATA_EXPECTED=$(printf '%s\n' "$DATA_ADDRS" | grep -c . )
    log "registering ${DATA_EXPECTED} data nodes"
    attempt=0
    while :; do
        attempt=$((attempt + 1))
        members=$(show)
        missing=$(missing_list "$DATA_ADDRS" "$members")
        if [ -z "$missing" ]; then
            log "all data nodes are members"
            break
        fi
        if [ "$attempt" -gt $(( ${WAIT_DATA_TIMEOUT:-300} / 5 )) ]; then
            die "data nodes still missing after ${attempt} attempts:${missing}"
        fi
        for addr in $missing; do
            host=${addr%:*}
            if ! wait_port "$host" "${DATA_HTTP_PORT}" 10; then
                log "  ${host} HTTP port not open yet; add-data needs only its TCP port"
            fi
            log "  add-data ${addr} (attempt ${attempt})"
            out=$(ctl add-data "$addr" 2>&1) || log "    rejected: ${out}"
            [ -n "${out:-}" ] && log "    ${out}"
        done
        sleep 5
    done
else
    log "no data nodes to register"
fi

# ---------------------------------------------------------------------------
# 5. Admin user, then databases. With meta auth on, every meta endpoint answers "must
#    create admin user first" until an admin user exists, so the user comes first.
#
#    InfluxQL has NO `CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS` (the
#    parser rejects `IF`, and this fork matches InfluxDB 1.x there), so existence is read
#    from SHOW USERS / SHOW DATABASES first. api_query also swallows an "already exists"
#    reply, which covers the race where another actor created it a moment ago.
# ---------------------------------------------------------------------------
# Both CREATEs lean on api_query turning "already exists" into success (ALREADY_EXISTS),
# because InfluxQL has no `CREATE USER/DATABASE IF NOT EXISTS` — this fork matches
# InfluxDB 1.x, whose parser answers `found NOT, expected ;`.
seed() {
    RETRY_LATER=0
    if [ "${CREATE_ADMIN_USER:-off}" = "on" ]; then
        [ -n "${ADMIN_PASSWORD:-}" ] || die "CREATE_ADMIN_USER=on but ADMIN_PASSWORD is empty"
        priv="WITH PASSWORD '${ADMIN_PASSWORD}'"
        [ "${ADMIN_ALL_PRIVILEGES:-true}" = "true" ] && priv="${priv} WITH ALL PRIVILEGES"
        if api_query "CREATE USER \"${ADMIN_USER}\" ${priv}" >/dev/null; then
            if [ "${ALREADY_EXISTS:-0}" = "1" ]; then
                log "user ${ADMIN_USER} already exists"
            else
                log "created user ${ADMIN_USER} (admin=${ADMIN_ALL_PRIVILEGES:-true})"
            fi
        else
            return 1
        fi
    fi
    if [ "${CREATE_DATABASES:-off}" = "on" ] && [ -n "$DATABASES" ]; then
        # `for` over the newline-separated list, not a piped `while`: the pipe body runs
        # in a subshell where `return 1` would vanish. Entries are `name|factor`; names
        # are validated as InfluxQL identifiers, so they contain no whitespace.
        for entry in $DATABASES; do
            name=${entry%%|*}
            replication=${entry##*|}
            [ -n "$name" ] || continue
            line="CREATE DATABASE \"${name}\""
            case "$replication" in
                ''|'-') ;;
                *) line="${line} WITH REPLICATION ${replication}" ;;
            esac
            if api_query "$line" >/dev/null; then
                if [ "${ALREADY_EXISTS:-0}" = "1" ]; then
                    log "database ${name} exists (a changed replication factor is NOT applied here — README)"
                else
                    log "created database ${name} (replication ${replication:-default})"
                fi
            else
                return 1
            fi
        done
    fi
}

if [ "${JOIN_ONLY:-off}" = "on" ]; then
    log "cluster.joiner.joinOnly: not seeding users or databases"
else
    attempt=0
    while :; do
        attempt=$((attempt + 1))
        if seed; then
            break
        fi
        if [ "${RETRY_LATER}" != "1" ]; then
            # the API answered and rejected the statement: retrying cannot help
            die "the data HTTP API rejected the seeding statement above (see the HTTP response just logged) — not retrying"
        fi
        if [ "$attempt" -ge 40 ]; then
            die "the data HTTP API at ${DATA_URL} stayed unavailable after ${attempt} attempts"
        fi
        log "  data HTTP API still unavailable, retrying (attempt ${attempt})"
        sleep 5
    done
fi

log "final cluster state:"
show || log "(influxd-ctl show failed — nodes are registered but unreadable; check CTL_AUTH_TYPE and the meta credentials)"
log "done"
