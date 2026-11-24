# ---------------------------------------------------------------------------
# Database image for the pg-ha chart: PostgreSQL 18 + repmgr + the three scripts
# the chart's pods run. Published as sothanav/pg-ha:18-repmgr, which is the chart's
# default image.repository, so building it is optional — rebuild and push your own when
# you need to audit or mirror it, then point image.repository at that path:
#
#   docker build -t <REGISTRY>/pg-ha:18-repmgr postgresql/sothanav-ha-pg/image
#   docker push  <REGISTRY>/pg-ha:18-repmgr
#
# Whatever you build, keep the tag's PostgreSQL major equal to the base image below and to
# repmgr.pgBindir in values.yaml; the chart fails the render when they disagree.
#
# Everything except the major version and the step-down is the image in
# docker-template/postgresql/postgresql-ha; curl and jq are new because the Kubernetes port
# publishes pgcat's config through the API instead of a shared volume (see
# image/pgcat-role-sync.sh), and gosu is replaced by as-postgres (see below).
# ---------------------------------------------------------------------------
FROM postgres:18-bookworm

# postgresql-18-repmgr  repmgr + repmgrd, matching the major in the base tag
# iputils-ping        `repmgr node check` / operator debugging
# curl + jq           the two scripts that read and PATCH the pgcat ConfigMap
# ca-certificates     HTTPS to the Kubernetes API
#
# Deliberately NOT installed: gosu. The base image already ships one and this build
# replaces it (see below), and Debian's package would add a second, /usr/sbin/gosu, that
# nothing calls.
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql-18-repmgr \
        iputils-ping \
        curl \
        jq \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# /var/log/postgresql is new versus the compose image: the entrypoint starts the server
# with `pg_ctl -l`, so the server log is a file it tails into the container's stdout
# instead of vanishing into a detached postmaster.
RUN mkdir -p /etc/repmgr /var/log/repmgr /var/log/postgresql /var/run/repmgr \
    && chown -R postgres:postgres /etc/repmgr /var/log/repmgr /var/log/postgresql /var/run/repmgr

COPY entrypoint.sh pgcat-role-sync.sh pgcat-config-watch.sh as-postgres /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh \
        /usr/local/bin/pgcat-role-sync.sh \
        /usr/local/bin/pgcat-config-watch.sh \
        /usr/local/bin/as-postgres \
    && ln -sf /usr/local/bin/as-postgres /usr/local/bin/gosu

# ---------------------------------------------------------------------------
# Why gosu is a symlink here.
#
# The base image's /usr/local/bin/gosu is 1.20, a Go binary, and it signals the child it
# forks. On a node whose container AppArmor profile grants no `signal` permission -- the
# `cri-containerd.apparmor.d` profile containerd 2.x applies by default, measured on k3s
# v1.36.5 / containerd 2.3.4 / Ubuntu 26.04.1 kernel 7.0.0-43 on 2026-11-24 -- that kill()
# returns EACCES and gosu spins at 100% CPU in state R, unkillable by SIGKILL, while
# `gosu --version` still answers instantly. Every `gosu postgres ...` would then look like a
# PostgreSQL that never finishes initdb, and an operator typing the usual
# `kubectl exec ... -- gosu postgres repmgr cluster show` would wedge the pod with an
# unkillable process. Same pod, `appArmorProfile: {type: Unconfined}`: gosu returns in 0s.
#
# as-postgres does the same job with util-linux setpriv (setgroups/setgid/setuid then execvp
# in the same process: there is no child to signal) and sets HOME, which gosu set and
# psql/`~/.pgpass` depend on. It works confined and unconfined, so the step-down is never the
# thing that fails -- though a confined pod still cannot run PostgreSQL at all, because that
# same profile also refuses PostgreSQL's own latch signals. See the chart README: AppArmor.
# The symlink keeps every existing runbook command working, including gosu's `user[:group]
# command` argument form and --version/--help; it does not implement --init-groups or
# --preserve-environment, neither of which this image used.
# ---------------------------------------------------------------------------

EXPOSE 5432

# The entrypoint traps SIGTERM and runs `pg_ctl -m fast`, which is what buys a clean
# shutdown inside terminationGracePeriodSeconds.
STOPSIGNAL SIGTERM

# pgcat pods override this with command: /usr/local/bin/pgcat-config-watch.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
