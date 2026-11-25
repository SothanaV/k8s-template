# Generated from files/sentinel.conf.tpl by sentinel-entrypoint.sh; the
# @TOKENS@ there are filled from pod env (ports, Sentinel settings, and the
# passwords from the Secret). Sentinel rewrites THIS copy under /etc/valkey
# (emptyDir) as it learns replicas and fails over — same as compose kept
# rewriting the bind-mounted sentinel.conf.

port @SENTINEL_PORT@
dir /etc/valkey

# Sentinel's own AUTH (compose: requirepass SentinelPass123)
requirepass @SENTINEL_PASSWORD@

# Watch the master (compose: monitor mymaster 172.29.0.11 6379 2). The address
# is the per-node Service VIP of whichever node was master at start; Sentinel's
# own failovers move it, and the entrypoint watchdog restores it to a stable
# Service VIP after pod reschedules.
sentinel monitor @MASTER_NAME@ @MASTER_HOST@ @VALKEY_PORT@ @QUORUM@
sentinel auth-pass @MASTER_NAME@ @VALKEY_PASSWORD@
sentinel down-after-milliseconds @MASTER_NAME@ @DOWN_AFTER@
sentinel failover-timeout @MASTER_NAME@ @FAILOVER_TIMEOUT@
sentinel parallel-syncs @MASTER_NAME@ @PARALLEL_SYNCS@
