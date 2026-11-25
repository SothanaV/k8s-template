#!/bin/sh
# sentinel-entrypoint.sh — render sentinel.conf at start (same copy-then-exec
# trick as compose, but from a chart template instead of a bind mount), then
# run Sentinel under a watchdog.
#
# The compose sentinel.conf hardcoded `sentinel monitor mymaster 172.29.0.11`.
# Here the monitor target is decided at start:
#   1. scan the node Services for a live role:master -> use its Service VIP
#   2. ask an existing Sentinel for the last known master
#   3. fall back to the bootstrap primary's Service VIP
# All three resolve to per-node ClusterIP VIPs, which — unlike the pod IPs raw
# Sentinel persists after its own failovers — never move under a Service.
#
# The watchdog matters: when Sentinel failovers on its own it rewrites its
# state file with the promoted replica's ANNOUNCED address, which is a pod IP.
# If that pod is later rescheduled, the VIP in the state file points at a
# different pod. Every pass the watchdog verifies the monitored address really
# reports role:master and re-points at the live master's Service VIP if not.
# (This is the Kubernetes analogue of compose's static IPs doing the work.)

. /scripts/common.sh
. /scripts/entrypoint-env.sh

log "waiting for my data node on 127.0.0.1:$VALKEY_PORT"
while ! val -h 127.0.0.1 -p "$VALKEY_PORT" ping | grep -q PONG; do
    sleep 2
done
log "data node answers — deciding the monitor target"

TARGET=""
if LIVE_MASTER=$(find_master_host); then
    TARGET=$(resolve_ip "$LIVE_MASTER")
    log "live master: $LIVE_MASTER ($TARGET)"
fi
if [ -z "$TARGET" ]; then
    if ANSWER=$(ask_sentinel_master); then
        set -- $ANSWER
        TARGET=$1
        log "no live master; Sentinel memory: $TARGET"
    fi
fi
if [ -z "$TARGET" ]; then
    TARGET=$(resolve_ip_wait "$PRIMARY_NODE_SERVICE_HOST")
    log "no live master, no memory: monitoring bootstrap primary $PRIMARY_NODE_SERVICE_HOST ($TARGET)"
fi

# Passwords arrive as env vars from the Secret; the render-time charset rule
# ([A-Za-z0-9._@:-]) keeps `|` a safe sed delimiter and free of & side effects.
mkdir -p /etc/valkey
sed \
    -e "s|@SENTINEL_PORT@|$SENTINEL_PORT|g" \
    -e "s|@MASTER_NAME@|$MASTER_NAME|g" \
    -e "s|@MASTER_HOST@|$TARGET|g" \
    -e "s|@VALKEY_PORT@|$VALKEY_PORT|g" \
    -e "s|@QUORUM@|$SENTINEL_QUORUM|g" \
    -e "s|@DOWN_AFTER@|$SENTINEL_DOWN_AFTER|g" \
    -e "s|@FAILOVER_TIMEOUT@|$SENTINEL_FAILOVER_TIMEOUT|g" \
    -e "s|@PARALLEL_SYNCS@|$SENTINEL_PARALLEL_SYNCS|g" \
    -e "s|@SENTINEL_PASSWORD@|$SENTINEL_PASSWORD|g" \
    -e "s|@VALKEY_PASSWORD@|$VALKEY_PASSWORD|g" \
    /etc/valkey-template/sentinel.conf.tpl > /etc/valkey/sentinel.conf
if [ -s /etc/valkey-template/extra.conf ]; then
    cat /etc/valkey-template/extra.conf >> /etc/valkey/sentinel.conf
fi
log "monitoring $MASTER_NAME at $TARGET:$VALKEY_PORT (quorum $SENTINEL_QUORUM)"

# ---- watchdog ----
(
    while :; do
        sleep "$SENTINEL_WATCHDOG_INTERVAL"
        current=$(vsent -h 127.0.0.1 -p "$SENTINEL_PORT" \
            sentinel get-master-addr-by-name "$MASTER_NAME" | tr -d '\r' | sed -n '1p')
        # Healthy: a named master that claims the role -> nothing to do.
        if [ -n "$current" ] && is_master "$current" "$VALKEY_PORT"; then
            continue
        fi
        # Otherwise: is somebody ELSE claiming the role right now? (During a
        # real failover nobody does — leave that to Sentinel itself.)
        if live=$(find_master_host); then
            lip=$(resolve_ip "$live")
            [ -n "$lip" ] || continue
            if [ "$lip" != "$current" ]; then
                log "watchdog: $live ($lip) is master, I monitor '${current:-<none>}' — re-pointing"
                point_sentinel "$lip"
            fi
        fi
    done
) &

exec valkey-sentinel /etc/valkey/sentinel.conf
