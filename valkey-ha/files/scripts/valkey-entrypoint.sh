#!/bin/sh
# valkey-entrypoint.sh — start one data node as master or replica WITHOUT the
# compose template's hardcoded `--replicaof 172.29.0.11`. Priority at boot:
#
#   1. scan the per-node Services for a live `role:master`
#      -> replica of it (stable Service VIP, not a pod IP)
#   2. nothing live: ask any Sentinel who the master was, but only when this
#      pod has data (an empty volume means a cold install — waiting on a
#      master that never existed is pure startup latency). The answer may be a
#      dead address; starting as a replica of it just retries in the
#      background, which is exactly what you want while the master restarts.
#   3. no live master, no Sentinel memory: bootstrap rule —
#      bootstrap.primaryOrdinal starts as master, everyone else replicates it.
#
# A background watcher then keeps a replica honest: if its link stays down
# while some other node reports role:master (failover happened while we were
# away), it re-issues REPLICAOF toward the live master.

. /scripts/common.sh
. /scripts/entrypoint-env.sh

cd /data || exit 1

MY_ORDINAL=${POD_NAME##*-}
MY_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
i=0
while [ -z "$MY_IP" ] && [ "$i" -lt 30 ]; do
    MY_IP=$(resolve_ip "$POD_NAME")
    [ -z "$MY_IP" ] && sleep 1
    i=$((i + 1))
done
[ -n "$MY_IP" ] || { log "FATAL: cannot determine my pod IP"; exit 1; }

# My own Service FQDN = the (ordinal+1)-th entry of the space-separated list.
MY_SVC_HOST=$(echo "$NODE_SERVICE_HOSTS" | awk -v n="$((MY_ORDINAL + 1))" '{print $n}')

REPLICA_OF=""

# ---- 1. is there a live master behind a Service VIP? ----
if LIVE_MASTER=$(find_master_host); then
    if [ "$LIVE_MASTER" = "$MY_SVC_HOST" ]; then
        # Our Service answered role:master while our own valkey is not up yet
        # -> the previous container has not finished dying. Treat as self.
        log "a master already answers on my Service VIP — assuming it is my dying predecessor"
    else
        REPLICA_OF=$(resolve_ip "$LIVE_MASTER")
        # transient nslookup blip: never start with an empty replicaof target
        [ -n "$REPLICA_OF" ] || REPLICA_OF=$(resolve_ip_wait "$LIVE_MASTER")
        log "live master: $LIVE_MASTER ($REPLICA_OF)"
    fi
fi

# ---- 2. no live master; if I have data, ask Sentinel memory ----
if [ -z "$REPLICA_OF" ] && [ -n "$(ls -A /data 2>/dev/null)" ]; then
    deadline=$(( $(date +%s) + SENTINEL_ANSWER_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        ANSWER=$(ask_sentinel_master) && break
        ANSWER=""
        sleep 2
    done
    if [ -n "$ANSWER" ]; then
        set -- $ANSWER   # $1=ip $2=port
        OLD_IP=$1
        if [ "$OLD_IP" = "$MY_IP" ] || [ "$OLD_IP" = "$(resolve_ip "$MY_SVC_HOST")" ]; then
            log "Sentinel names ME as master ($OLD_IP) — starting as master"
        else
            # Deliberately not verified reachable: an unreachable target is
            # still the right one to retry against.
            REPLICA_OF=$OLD_IP
            log "no live master; Sentinel memory says $OLD_IP — replicating (and retrying) toward it"
        fi
    fi
fi

# ---- 3. bootstrap rule ----
if [ -z "$REPLICA_OF" ]; then
    if [ "$MY_ORDINAL" -eq "$PRIMARY_ORDINAL" ]; then
        log "bootstrapping as master (ordinal $MY_ORDINAL == bootstrap.primaryOrdinal)"
    else
        REPLICA_OF=$(resolve_ip_wait "$PRIMARY_NODE_SERVICE_HOST")
        log "bootstrapping as replica of $PRIMARY_NODE_SERVICE_HOST ($REPLICA_OF)"
    fi
fi

# ---- background: keep following the real master ----
watch_replication() {
    down_count=0
    while :; do
        sleep 15
        info=$(val -h 127.0.0.1 -p "$VALKEY_PORT" info replication | tr -d '\r')
        # -LOADING, restarts, blips: no role line, nothing to decide on yet
        echo "$info" | grep -q '^role:' || continue
        echo "$info" | grep -q '^role:master' && { down_count=0; continue; }
        if echo "$info" | grep -q '^master_link_status:up'; then
            down_count=0
            continue
        fi
        down_count=$((down_count + 1))
        [ "$down_count" -lt 2 ] && continue
        live=$(find_master_host) || continue
        lip=$(resolve_ip "$live")
        [ -n "$lip" ] || continue
        cur=$(echo "$info" | sed -n 's/^master_host://p')
        if [ "$lip" != "$cur" ]; then
            log "watch: $live ($lip) is master, I follow '$cur' — re-following"
            if val -h 127.0.0.1 -p "$VALKEY_PORT" replicaof "$lip" "$VALKEY_PORT" \
                | grep -q OK; then
                down_count=0
            fi
        fi
    done
}
watch_replication &

# ---- assemble the valkey-server command (compose's flags, pod-ified) ----
set -- valkey-server \
    --port "$VALKEY_PORT" \
    --dir /data \
    --requirepass "$VALKEY_PASSWORD" \
    --masterauth "$VALKEY_PASSWORD" \
    --replica-announce-ip "$MY_IP" \
    --replica-announce-port "$VALKEY_PORT"
if [ "$APPENDONLY" = "yes" ]; then
    set -- "$@" --appendonly yes
fi
if [ -n "$REPLICA_OF" ]; then
    set -- "$@" --replicaof "$REPLICA_OF" "$VALKEY_PORT"
fi
# shellcheck disable=SC2086  # intentional word splitting: --key value pairs
[ -n "$VALKEY_EXTRA_ARGS" ] && set -- "$@" $VALKEY_EXTRA_ARGS

log "starting: pod=$POD_NAME announce=$MY_IP follows=${REPLICA_OF:-<master role>}"
exec "$@"
