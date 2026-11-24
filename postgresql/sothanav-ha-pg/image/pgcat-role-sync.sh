#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pgcat-role-sync.sh — make pgcat follow repmgr's current primary
#
# pgcat never checks node roles itself (there is no pg_is_in_recovery() in its health
# check); every role comes from pgcat.toml alone. Without rewriting that file, all
# writes keep going to the node that used to be the primary (AllServersDown) or land on
# a standby ("cannot execute ... in a read-only transaction").
#
# workflow:
#   find the current primary among PARTNER_HOSTS -> render pgcat.toml from the template
#   -> compare with what the ConfigMap already holds -> PATCH the ConfigMap if it moved
#
# Why a ConfigMap and not a shared volume (the compose design): a volume that three
# database pods write and a pgcat pod reads needs ReadWriteMany storage, which is a poor
# fit for a database anyway. The Kubernetes API is the shared medium instead, and the
# ConfigMap becomes the auditable record: `kubectl get cm <name> -o jsonpath='{.metadata.annotations}'`
# shows which node published last and to which primary.
#
# Secrets stay out of the ConfigMap on purpose. This script substitutes only the server
# list, the database name, the pool user and the pool size; the two password tokens are
# left intact for pgcat-config-watch.sh to fill in inside the pgcat pod, which is the pod
# that holds those Secret keys.
#
# RBAC: `get` and `patch` on the one ConfigMap named by PGCAT_CONFIGMAP (chart's rbac).
#
# usage:
#   pgcat-role-sync.sh            periodic mode: exits quietly unless we are primary
#   pgcat-role-sync.sh --force    called from repmgr's promote_command (retries until
#                                 the promotion is visible)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${POD_NAME:?POD_NAME is required (downward API: metadata.name)}"
: "${PARTNER_HOSTS:?PARTNER_HOSTS is required (comma-separated FQDNs, one per node)}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${PGCAT_CONFIGMAP:?PGCAT_CONFIGMAP is required}"

NODE_NAME="${POD_NAME}"
PGCAT_TEMPLATE="${PGCAT_TEMPLATE:-/templates/pgcat.toml.tpl}"
PGCAT_KEY="${PGCAT_KEY:-pgcat.toml}"
PGCAT_PG_PORT="${PGCAT_PG_PORT:-5432}"
PGCAT_DB="${PGCAT_DB:-postgres}"
PGCAT_DB_USER="${PGCAT_DB_USER:-postgres}"
PGCAT_POOL_SIZE="${PGCAT_POOL_SIZE:-30}"

# Replication/monitoring is what the tokens above describe; nothing here needs the
# repmgr role, so only POSTGRES_PASSWORD is required.
SA_DIR="${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
POD_NAMESPACE="${POD_NAMESPACE:-$(cat "${SA_DIR}/namespace" 2>/dev/null || echo default)}"
# enableServiceLinks=false removes the auto-injected KUBERNETES_SERVICE_* pair, so the
# defaults keep the script working either way. The in-cluster API is always reachable at
# kubernetes.default.svc:443 from inside the cluster.
KUBERNETES_SERVICE_HOST="${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}"
KUBERNETES_SERVICE_PORT="${KUBERNETES_SERVICE_PORT:-443}"
API_URL="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/api/v1/namespaces/${POD_NAMESPACE}/configmaps/${PGCAT_CONFIGMAP}"

# Print the hostname of the node that is not a standby (pg_is_in_recovery() = 'f'),
# or an empty string when no primary is reachable.
find_current_primary() {
  local host recovery
  IFS=',' read -ra NODES <<< "${PARTNER_HOSTS}"
  for host in "${NODES[@]}"; do
    host="$(echo "${host}" | xargs)"
    [ -z "${host}" ] && continue
    recovery="$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${host}" -p "${PGCAT_PG_PORT}" \
      -U "${PGCAT_DB_USER}" -d "${PGCAT_DB}" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "")"
    if [ "${recovery}" = "f" ]; then
      echo "${host}"
      return 0
    fi
  done
  echo ""
}

# pg_is_in_recovery() of this node ('f' means we are the primary). Loopback TCP rather than
# the unix socket, and no privilege step-down at all: repmgr runs promote_command as the
# postgres user, where a step-down is pointless, and a socket path would depend on
# PGDATA/`unix_socket_directories` being the defaults.
self_recovery_state() {
  PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -p "${PGCAT_PG_PORT}" \
    -U "${PGCAT_DB_USER}" -d "${PGCAT_DB}" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Minimal ConfigMap client. Prints the response body on stdout; sets HTTP_CODE and
# HTTP_BODY. Returns non-zero for anything but 200/201 so callers can branch.
# ---------------------------------------------------------------------------
api_call() {
  local method="$1" body_file="${2:-}" tmp err code token
  tmp="$(mktemp)"
  err="$(mktemp)"
  if ! token="$(cat "${SA_DIR}/token" 2>/dev/null)"; then
    echo ">>> [${NODE_NAME}] pgcat-role-sync: no service account token in ${SA_DIR} (serviceAccount.create? automountServiceAccountToken?)" >&2
    rm -f "${tmp}" "${err}"
    return 1
  fi
  local -a args=(-sS --max-time 10 -o "${tmp}" -w '%{http_code}'
                 --cacert "${SA_DIR}/ca.crt"
                 -H "Authorization: Bearer ${token}")
  if [ -n "${body_file}" ]; then
    args+=(-H 'Content-Type: application/merge-patch+json' --data-binary "@${body_file}")
  fi
  # curl itself failing (DNS, TLS, API slow) must not abort the caller under set -e.
  # On failure curl still writes its -w code (000), so do not append a second one.
  if ! code="$(curl "${args[@]}" -X "${method}" "${API_URL}" 2>"${err}")"; then
    code="${code:-000}"
  fi
  HTTP_CODE="${code}"
  HTTP_BODY="$(cat "${tmp}")"
  # curl's diagnostics are separate from the response body: on a transport failure the body
  # is empty and the reason lives here, and appending it would corrupt a real JSON body.
  HTTP_ERR="$(cat "${err}")"
  rm -f "${tmp}" "${err}"
  [ "${code}" = "200" ] || [ "${code}" = "201" ]
}

# Literal string replacement with no pattern or replacement semantics.
#
# `${content//__TOKEN__/${PASSWORD}}` is the obvious one-liner and it is WRONG here: since
# bash 5.2 (so bookworm and trixie, i.e. every image this chart builds on) an unquoted `&`
# in the replacement expands to the matched text. A password like `p@ss&word` came out as
# `p@ss__POSTGRES_PASSWORD__word` in testing — a corrupted credential, on the node that
# just won a failover. The splitting below has no replacement grammar at all: `$needle` is
# quoted inside the pattern contexts, and `$repl` is plain string concatenation, so `&`,
# `\`, `|`, `/` and quotes all travel verbatim. Identical function in pgcat-config-watch.sh;
# the two scripts run in different pods and stay independently readable.
replace_all() {
  local hay="$1" needle="$2" repl="$3" out=""
  [ -z "${needle}" ] && { printf '%s' "${hay}"; return 0; }
  while [[ "${hay}" == *"${needle}"* ]]; do
    out+="${hay%%"${needle}"*}${repl}"
    hay="${hay#*"${needle}"}"
  done
  printf '%s%s' "${out}" "${hay}"
}

# Render pgcat.toml and print it on stdout. Password tokens are left untouched.
render_config() {
  local primary="$1" host first=1 servers="" content role
  IFS=',' read -ra NODES <<< "${PARTNER_HOSTS}"
  for host in "${NODES[@]}"; do
    host="$(echo "${host}" | xargs)"
    [ -z "${host}" ] && continue
    if [ "${host}" = "${primary}" ]; then
      role="primary"
    else
      role="replica"
    fi
    if [ "${first}" -eq 1 ]; then
      servers="    [\"${host}\", ${PGCAT_PG_PORT}, \"${role}\"]"
      first=0
    else
      servers="${servers},
    [\"${host}\", ${PGCAT_PG_PORT}, \"${role}\"]"
    fi
  done

  if [ ! -s "${PGCAT_TEMPLATE}" ]; then
    echo ">>> [${NODE_NAME}] pgcat-role-sync: template ${PGCAT_TEMPLATE} not found (is the chart ConfigMap mounted at /templates?)" >&2
    return 1
  fi

  content="$(cat "${PGCAT_TEMPLATE}")"
  # Plain bash substitution instead of sed, so a password or host with special characters
  # (&, |, \) cannot break the replacement.
  content="$(replace_all "${content}" "__SERVERS__" "${servers}")"
  content="$(replace_all "${content}" "__DATABASE__" "${PGCAT_DB}")"
  content="$(replace_all "${content}" "__DB_USER__" "${PGCAT_DB_USER}")"
  content="$(replace_all "${content}" "__POOL_SIZE__" "${PGCAT_POOL_SIZE}")"
  printf '%s\n' "${content}"
}

# Publish the rendered config. Skips the write when nothing changed: a PATCH per poll
# would bump resourceVersion constantly and make `kubectl get cm -w` useless.
sync_now() {
  local primary="$1" rendered tmp attempt code
  rendered="$(render_config "${primary}")" || return 1

  if ! api_call GET; then
    echo ">>> [${NODE_NAME}] pgcat-role-sync: GET ${API_URL} failed (HTTP ${HTTP_CODE}): ${HTTP_ERR:-$(printf '%s' "${HTTP_BODY}" | head -c 300)}" >&2
    return 1
  fi
  if [ "$(printf '%s' "${HTTP_BODY}" | jq -r --arg k "${PGCAT_KEY}" '.data[$k] // ""')" = "${rendered}" ]; then
    return 0                     # nothing changed, do not disturb pgcat
  fi

  tmp="$(mktemp)"
  # -Rs (NOT -n): stdin becomes one raw string, so jq handles every escape in the rendered
  # text. With -n the input is never read and `.` is null, which publishes a null value.
  if ! printf '%s\n' "${rendered}" | jq -Rs \
        --arg key "${PGCAT_KEY}" \
        --arg primary "${primary}" \
        --arg node "${NODE_NAME}" \
        --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{data: {($key): .},
          metadata: {annotations: {
            "pg-ha.sothana.io/primary":        $primary,
            "pg-ha.sothana.io/synced-by":      $node,
            "pg-ha.sothana.io/synced-at":      $when}}}
        ' > "${tmp}"; then
    echo ">>> [${NODE_NAME}] pgcat-role-sync: jq could not build the patch payload" >&2
    rm -f "${tmp}"
    return 1
  fi

  # Retry a few times: the API can be briefly unreachable right when a promotion lands,
  # and losing this write means writes keep going to the old primary.
  for attempt in 1 2 3; do
    if api_call PATCH "${tmp}"; then
      echo ">>> [${NODE_NAME}] pgcat-role-sync: pgcat write endpoint -> ${primary}"
      rm -f "${tmp}"
      return 0
    fi
    code="${HTTP_CODE}"
    sleep 2
  done
  echo ">>> [${NODE_NAME}] pgcat-role-sync: PATCH failed after 3 attempts (HTTP ${code}): ${HTTP_ERR:-$(printf '%s' "${HTTP_BODY}" | head -c 300)}" >&2
  case "${code}" in
    403|401) echo ">>> [${NODE_NAME}] pgcat-role-sync: not allowed to patch ${PGCAT_CONFIGMAP} — check the RoleBinding and that pgcat.fullnameOverride did not change (README: RBAC)" >&2 ;;
    404)     echo ">>> [${NODE_NAME}] pgcat-role-sync: ${PGCAT_CONFIGMAP} does not exist — it is rendered by this chart, so the release was probably uninstalled or renamed" >&2 ;;
    000)     echo ">>> [${NODE_NAME}] pgcat-role-sync: the API server is unreachable — pgcat keeps its previous server list and will follow once it answers" >&2 ;;
    *)       echo ">>> [${NODE_NAME}] pgcat-role-sync: pgcat keeps its previous server list until this succeeds" >&2 ;;
  esac
  rm -f "${tmp}"
  return 1
}

main() {
  local mode="${1:-}" primary="" attempt

  if [ "${mode}" = "--force" ]; then
    # repmgr calls this during promote, and pg_promote() may not be finished yet, so
    # retry for a while instead of giving up.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      primary="$(find_current_primary)"
      [ -n "${primary}" ] && break
      sleep 2
    done
  else
    # Periodic mode: let only the primary node own the file.
    [ "$(self_recovery_state)" = "f" ] || return 0
    primary="$(find_current_primary)"
  fi

  if [ -z "${primary}" ]; then
    echo ">>> [${NODE_NAME}] pgcat-role-sync: no primary found, leaving the published config untouched" >&2
    return 0
  fi

  sync_now "${primary}"
}

main "$@"
