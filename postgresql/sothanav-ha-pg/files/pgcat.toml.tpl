# ---------------------------------------------------------------------------
# pgcat.toml.tpl — source of truth for the pgcat configuration
#
# pgcat cannot detect node roles on its own: every role comes from this file, so
# somebody has to rewrite it after repmgr promotes a new standby. That is what
# pgcat-role-sync.sh does on the primary node — it renders this template and
# publishes the result as the `pgcat.toml` key of the ConfigMap pgcat reads.
# Edit THIS file (or replace it with pgcat.configTemplate), never a rendered copy:
# rendered output lives in a ConfigMap and is overwritten.
#
# Two scripts substitute the double-underscore tokens below:
#
#   pgcat-role-sync.sh (runs in the database pods, as the repmgr primary)
#     server-list token  -> one `["<host>", <port>, "<role>"]` line per node, the
#                           node where pg_is_in_recovery() = 'f' first and marked
#                           primary, the rest replicas
#     database token     -> auth.database
#     pool user token    -> auth.username
#     pool size token    -> pgcat.poolSize
#
#   pgcat-config-watch.sh (runs beside pgcat, which is why the secrets stay out of
#   the ConfigMap — the published text keeps the tokens below)
#     postgres password token     -> the postgres-password Secret key
#     pgcat admin password token  -> the pgcat-admin-password Secret key
#     admin username token        -> pgcat.adminUser, the same value the sidecar itself
#                                    uses to authenticate its RELOAD, so the two cannot
#                                    drift apart and break every reload silently
#
# Substitution is a plain global string replacement, so do NOT spell any token
# name anywhere in this file, not even in a comment: a token inside a comment
# line gets replaced too, and injecting a server list into a comment produces
# invalid TOML ("invalid table header").
# ---------------------------------------------------------------------------

[general]
host = "0.0.0.0"
port = 6432

# pgcat-local admin account (NOT a PostgreSQL role). It must not collide with a
# username in the pool users below, otherwise normal client sessions hit the admin page.
admin_username = "__ADMIN_USER__"
admin_password = "__PGCAT_ADMIN_PASSWORD__"

healthcheck_delay = 1000
healthcheck_timeout = 1000
ban_time = 10

idle_timeout = 60000
connect_timeout = 3000
server_lifetime = 3600000

# pgcat re-reads this file every 3 seconds (value is in milliseconds). On
# Kubernetes that timer is the main mechanism, not a backstop: the sidecar writes
# the file as soon as the ConfigMap changes and also sends an admin RELOAD, but
# kubelet-level propagation is not involved here (the file is in an emptyDir the
# sidecar writes directly), so 3s bounds the worst case.
autoreload = 3000

enable_prometheus_exporter = true
prometheus_exporter_port = 9930

[pools.__DATABASE__]
pool_mode = "transaction"
# Fallback role for queries pgcat cannot classify. Keep it "primary": with "any"
# those queries land on a standby and fail with
# "cannot execute ... in a read-only transaction".
default_role = "primary"
query_parser_enabled = true
# pgcat 1.2.0 keeps read/write inference behind this flag, separately from
# query_parser_enabled. Without it pgcat picks a random server per query, so most
# writes go to a replica and fail.
query_parser_read_write_splitting = true
primary_reads_enabled = false
load_balancing_mode = "random"
checkout_timeout = 3000

[pools.__DATABASE__.shards.0]
servers = [
__SERVERS__
]
database = "__DATABASE__"

[pools.__DATABASE__.users.0]
username = "__DB_USER__"
password = "__POSTGRES_PASSWORD__"
pool_size = __POOL_SIZE__
statement_timeout = 0
