# Port of the compose haproxy.cfg. Structure and the role-detecting tcp-checks
# are verbatim; three things change for Kubernetes:
#
#   * backend servers are the per-node Service FQDNs (the SERVERS token is filled
#     by Helm from .Values.replicas) instead of hardcoded 172.29.0.x — a Service
#     VIP follows its pod across reschedules, so haproxy's startup-time DNS
#     resolution stays valid for the process lifetime and no resolvers section
#     is needed
#   * @VALKEY_PASSWORD@ / @STATS_PASSWORD@ are substituted from the container
#     environment at start (see the deployment command), so no password lives
#     in a ConfigMap
#   * the replica backend accepts role:slave AND role:replica (regex), since
#     INFO replication wording differs across valkey versions

global
    log stdout format raw local0
    maxconn @MAXCONN@

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 3s
    timeout client  1m
    timeout server  1m

# ================= STATS DASHBOARD =================
listen stats
    bind *:@STATS_PORT@
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
    stats auth @STATS_USER@:@STATS_PASSWORD@
    http-request use-service prometheus-exporter if { path /metrics }

# ================= MASTER (READ / WRITE) =================
# Only the node answering role:master stays UP here, so this frontend follows
# Sentinel failovers within ~check-interval without knowing what Sentinel is.
frontend valkey_master_front
    bind *:@MASTER_PORT@
    default_backend valkey_master_back

backend valkey_master_back
    option tcp-check
    tcp-check send AUTH\ @VALKEY_PASSWORD@\r\n
    tcp-check expect string +OK
    tcp-check send INFO\ replication\r\n
    tcp-check expect string role:master
    tcp-check send QUIT\r\n
    tcp-check expect string +OK

@SERVERS@

# ================= REPLICAS (READ-ONLY) =================
frontend valkey_replica_front
    bind *:@REPLICA_PORT@
    default_backend valkey_replica_back

backend valkey_replica_back
    balance roundrobin
    option tcp-check
    tcp-check send AUTH\ @VALKEY_PASSWORD@\r\n
    tcp-check expect string +OK
    tcp-check send INFO\ replication\r\n
    tcp-check expect rstring role:slave|role:replica
    tcp-check send QUIT\r\n
    tcp-check expect string +OK

@SERVERS@
