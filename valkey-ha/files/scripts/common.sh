# common.sh — sourced (not executed) by valkey-entrypoint.sh and
# sentinel-entrypoint.sh. Everything it needs arrives as environment variables
# rendered by templates/statefulset.yaml and templates/configmap-scripts.yaml.
#
# POSIX sh / busybox only: the valkey alpine image has sh, valkey-cli, nslookup
# and awk — nothing else. Passwords are validated at Helm render time against
# [A-Za-z0-9._@:-], which is why sed and gsub below never escape them.

log() {
    echo "[valkey-ha] $(date -u '+%H:%M:%S') $*"
}

# valkey-cli against the DATA port with the valkey password
val() {
    valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" "$@" 2>/dev/null
}

# valkey-cli against a SENTINEL port with the sentinel password
vsent() {
    valkey-cli --no-auth-warning -a "$SENTINEL_PASSWORD" "$@" 2>/dev/null
}

# resolve_ip <fqdn> — first A record, or empty. busybox nslookup prints
# "Name:" then "Address 1: <ip> ..."; we grab the dotted quad.
resolve_ip() {
    nslookup "$1" 2>/dev/null | awk '
        /^Name:/ { f = 1; next }
        f && /^Address/ {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
        }'
}

# resolve_ip_wait <fqdn> — never returns until it resolves. Used for per-node
# Service VIPs, which exist as soon as Helm applied the Services; a failure
# here means the DNS suffix or namespaceOverride is wrong, and looping loudly
# beats starting a node pointed at nothing.
resolve_ip_wait() {
    _ip=""
    while [ -z "$_ip" ]; do
        _ip=$(resolve_ip "$1")
        [ -z "$_ip" ] && { log "waiting for DNS: $1"; sleep 2; }
    done
    echo "$_ip"
}

# is_master <host> [port] — 0 if the valkey at host:port answers INFO
# replication with role:master
is_master() {
    val -h "$1" -p "${2:-$VALKEY_PORT}" info replication | grep -q '^role:master'
}

# find_master_host — FQDN of the first node Service whose valkey reports
# role:master. Works whenever any master is reachable, even with zero live
# Sentinels (bootstrapping, sentinel pod restarts).
find_master_host() {
    for _h in $NODE_SERVICE_HOSTS; do
        if is_master "$_h" "$VALKEY_PORT"; then
            echo "$_h"
            return 0
        fi
    done
    return 1
}

# ask_sentinel_master — echoes "<ip> <port>" from the first Sentinel that can
# name the master (get-master-addr-by-name). The answer can be STALE (an IP a
# rescheduled pod used to have) — callers must verify with is_master before
# trusting it, or use it only as a "who was master last" hint.
ask_sentinel_master() {
    for _h in $NODE_SERVICE_HOSTS; do
        _out=$(vsent -h "$_h" -p "$SENTINEL_PORT" \
            sentinel get-master-addr-by-name "$MASTER_NAME" | tr -d '\r')
        _ip=$(echo "$_out" | sed -n '1p')
        _port=$(echo "$_out" | sed -n '2p')
        if [ -n "$_ip" ] && [ "$_ip" != "127.0.0.1" ]; then
            echo "$_ip ${_port:-$VALKEY_PORT}"
            return 0
        fi
    done
    return 1
}

# point_sentinel <ip> — re-point THIS pod's sentinel (127.0.0.1) at a new
# master. SENTINEL MONITOR at runtime only takes name/ip/port/quorum, so the
# tuning has to be re-SENTINEL SET afterwards — otherwise a re-pointed
# sentinel would watch with default timeouts and no auth-pass.
point_sentinel() {
    vsent -h 127.0.0.1 -p "$SENTINEL_PORT" sentinel remove "$MASTER_NAME" >/dev/null
    if ! vsent -h 127.0.0.1 -p "$SENTINEL_PORT" \
        sentinel monitor "$MASTER_NAME" "$1" "$VALKEY_PORT" "$SENTINEL_QUORUM" \
        | grep -q OK; then
        log "ERROR: SENTINEL MONITOR $MASTER_NAME $1 was rejected"
        return 1
    fi
    vsent -h 127.0.0.1 -p "$SENTINEL_PORT" sentinel set "$MASTER_NAME" \
        auth-pass "$VALKEY_PASSWORD" \
        down-after-milliseconds "$SENTINEL_DOWN_AFTER" \
        failover-timeout "$SENTINEL_FAILOVER_TIMEOUT" \
        parallel-syncs "$SENTINEL_PARALLEL_SYNCS" >/dev/null
}
