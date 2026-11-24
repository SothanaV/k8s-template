#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pgcat-config-watch.sh — sidecar beside pgcat
#
# Copies the published pgcat.toml out of the ConfigMap into /config/pgcat.toml, an
# emptyDir pgcat reads, fills in the password tokens, and tells pgcat to reload.
#
# Why a sidecar instead of mounting the ConfigMap into pgcat directly: kubelet syncs
# mounted ConfigMaps on its own poll interval, so after a failover pgcat could keep the
# old server list for up to a minute and keep sending writes to a demoted node. Reading
# the API every few seconds and writing the file pgcat already watches keeps the
# propagation bound at watchIntervalSeconds + pgcat's own autoreload timer, which is
# what the compose stack with its shared volume achieved.
#
# The password substitution happens HERE rather than in pgcat-role-sync.sh so that the
# ConfigMap never contains a credential: `kubectl get cm -o yaml` and any viewer with
# read access to ConfigMaps in the namespace stay out of the secret path. Only this pod
# needs those two Secret keys.
#
# Runs unprivileged as uid 999 (pgcat.sidecarSecurityContext); it needs no capability,
# writes only the emptyDir, and re-reads the service account token every round so
# bounded-token rotation is invisible.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${PGCAT_CONFIGMAP:?PGCAT_CONFIGMAP is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${PGCAT_ADMIN_PASSWORD:?PGCAT_ADMIN_PASSWORD is required}"

SA_DIR="${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
POD_NAMESPACE="${POD_NAMESPACE:-$(cat "${SA_DIR}/namespace" 2>/dev/null || echo default)}"
KUBERNETES_SERVICE_HOST="${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}"
KUBERNETES_SERVICE_PORT="${KUBERNETES_SERVICE_PORT:-443}"
API_URL="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/api/v1/namespaces/${POD_NAMESPACE}/configmaps/${PGCAT_CONFIGMAP}"

PGCAT_KEY="${PGCAT_KEY:-pgcat.toml}"
PGCAT_OUT="${PGCAT_OUT:-/config/pgcat.toml}"
PGCAT_OUT_DIR="${PGCAT_OUT%/*}"
PGCAT_WATCH_SECONDS="${PGCAT_WATCH_SECONDS:-3}"
# RELOAD target: pgcat's own listener in this pod.
PGCAT_HOST="${PGCAT_HOST:-127.0.0.1}"
PGCAT_PORT="${PGCAT_PORT:-6432}"
PGCAT_ADMIN_USER="${PGCAT_ADMIN_USER:-pgcat_admin}"
# pgcat only opens an admin session when the database we connect to has no pool
# configured. Using the pooled database fails with "FATAL: No pool configured for
# database: postgres, user: pgcat_admin".
PGCAT_ADMIN_DB="${PGCAT_ADMIN_DB:-pgcat}"

WATCH_LOG_PREFIX="[pgcat-config-watch]"
PREVIOUS_PUBLISHED=""

cleanup() { exit 0; }
trap cleanup SIGTERM SIGINT

log()      { printf '%s %s\n' "${WATCH_LOG_PREFIX}" "$*"; }
log_error(){ printf '%s %s\n' "${WATCH_LOG_PREFIX}" "$*" >&2; }

# Literal string replacement with no pattern or replacement grammar.
#
# `${text//__TOKEN__/${PASSWORD}}` is the obvious one-liner and it corrupts passwords:
# since bash 5.2 (bookworm, trixie — every base this chart builds on) an unquoted `&` in
# the replacement expands to the matched text, so `p@ss&word` came out as
# `p@ss__POSTGRES_PASSWORD__word` in testing. Quoting `$needle` inside the pattern contexts
# and concatenating `$repl` makes `&`, `\`, `|`, `/` and quotes travel verbatim.
# Identical function in pgcat-role-sync.sh; the two scripts run in different pods.
replace_all() {
  local hay="$1" needle="$2" repl="$3" out=""
  [ -z "${needle}" ] && { printf '%s' "${hay}"; return 0; }
  while [[ "${hay}" == *"${needle}"* ]]; do
    out+="${hay%%"${needle}"*}${repl}"
    hay="${hay#*"${needle}"}"
  done
  printf '%s%s' "${out}" "${hay}"
}

# Escape a value for a TOML basic string (`password = "..."`). A backslash must be doubled
# before the quote pass, or `\"` would become `\\"`. Newlines and other control characters
# cannot be represented this way, so the README states that passwords must be printable
# ASCII without control characters — a newline in a Secret would otherwise produce a config
# pgcat refuses to parse, at 3 a.m., on the node that just took over.
toml_escape() {
  local s="$1"
  s="$(replace_all "${s}" '\' '\\')"
  replace_all "${s}" '"' '\"'
}

# Scratch file next to the output file, never in /tmp.
#
# The sidecar runs with `readOnlyRootFilesystem: true` and the emptyDir at /config is its
# ONLY writable directory (pgcat.sidecarSecurityContext), so a bare `mktemp` fails with
# EROFS: the caller sees an empty name, curl dies on `2>`, every round reports HTTP 000 and
# pgcat never receives a config. Same directory also keeps publish()'s `mv` an atomic rename
# rather than a cross-filesystem copy.
scratch() {
  local path
  if ! path="$(mktemp "${PGCAT_OUT_DIR}/.${1}.XXXXXX" 2>/dev/null)" || [ -z "${path}" ]; then
    return 1
  fi
  printf '%s' "${path}"
}

# Fetch the published config. Sets HTTP_CODE/HTTP_BODY/HTTP_ERR; non-zero on any transport
# or API failure so the caller can keep looping.
fetch_published() {
  local tmp err code token
  if ! tmp="$(scratch fetch)"; then
    log_error "cannot create a scratch file in ${PGCAT_OUT_DIR} (emptyDir mounted read-only? fsGroup?)"
    return 1
  fi
  if ! err="$(scratch err)"; then
    rm -f "${tmp}"
    log_error "cannot create a scratch file in ${PGCAT_OUT_DIR}"
    return 1
  fi
  # curl's own errors are kept out of the body: HTTP_BODY is piped straight into jq, and
  # a stray warning line after the JSON would make jq fail, which reads as
  # "nobody has published yet" and silently keeps the old server list.
  if ! token="$(cat "${SA_DIR}/token" 2>/dev/null)"; then
    log_error "no service account token in ${SA_DIR} (serviceAccount.create?)"
    rm -f "${tmp}" "${err}"
    return 1
  fi
  code="$(curl -sS --max-time 10 -o "${tmp}" -w '%{http_code}' \
            --cacert "${SA_DIR}/ca.crt" \
            -H "Authorization: Bearer ${token}" \
            "${API_URL}" 2>"${err}")" || code="${code:-000}"
  HTTP_CODE="${code}"
  HTTP_BODY="$(cat "${tmp}")"
  HTTP_ERR="$(cat "${err}")"
  rm -f "${tmp}" "${err}"
  [ "${code}" = "200" ]
}

# Tell pgcat to pick up the file now. Its autoreload timer (3s) is the fallback, and on
# the very first write pgcat is not listening yet, so a failure here is not an error.
notify_pgcat() {
  if PGPASSWORD="${PGCAT_ADMIN_PASSWORD}" psql -h "${PGCAT_HOST}" -p "${PGCAT_PORT}" \
       -U "${PGCAT_ADMIN_USER}" -d "${PGCAT_ADMIN_DB}" -c "RELOAD" >/dev/null 2>&1; then
    log "sent RELOAD to ${PGCAT_HOST}:${PGCAT_PORT}"
  else
    log "RELOAD not accepted yet (pgcat not up, or autoreload will pick the file up)"
  fi
}

# Write the rendered config atomically: pgcat can never read a half-written file, which
# its autoreload timer would otherwise parse as a broken config and drop every pool.
publish() {
  local rendered="$1" tmp
  if ! tmp="$(scratch pgcat.toml)"; then
    log_error "cannot create a temp file in ${PGCAT_OUT_DIR} (emptyDir mounted read-only? fsGroup?)"
    return 1
  fi
  printf '%s\n' "${rendered}" > "${tmp}"
  # 0644: the pgcat container may run as a different uid than this sidecar. The file
  # holds pool credentials, so the trust boundary is "anybody who can exec into this pod"
  # — the same boundary as the Secret mount of any pgcat deployment.
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${PGCAT_OUT}"
  return 0
}

one_round() {
  local published rendered

  if ! fetch_published; then
    log_error "GET ${API_URL} failed (HTTP ${HTTP_CODE}): ${HTTP_ERR:-$(printf '%s' "${HTTP_BODY}" | head -c 200)}"
    return 0
  fi
  if ! published="$(printf '%s' "${HTTP_BODY}" | jq -r --arg k "${PGCAT_KEY}" '.data[$k] // ""')"; then
    log_error "the ConfigMap response is not JSON I can read (key ${PGCAT_KEY}?): $(printf '%s' "${HTTP_BODY}" | head -c 200)"
    return 0
  fi

  # Empty means "nobody has published yet": right after install (no node is up) and for a
  # second after `helm upgrade` reset the key. Overwriting a good file with nothing would
  # make pgcat drop every pool, so keep what we have.
  if [ -z "${published}" ]; then
    if [ -z "${PREVIOUS_PUBLISHED}" ]; then
      log "no config published yet; waiting for the primary node to sync"
      PREVIOUS_PUBLISHED="(none)"
    fi
    return 0
  fi

  if [ "${published}" = "${PREVIOUS_PUBLISHED}" ] && [ -s "${PGCAT_OUT}" ]; then
    return 0                     # nothing changed since the last round
  fi

  # Literal substitution, with the same reason as pgcat-role-sync.sh: bash 5.2+ would let
  # an `&` in a password expand to the token it is replacing.
  rendered="$(replace_all "${published}" "__POSTGRES_PASSWORD__" "$(toml_escape "${POSTGRES_PASSWORD}")")"
  rendered="$(replace_all "${rendered}" "__PGCAT_ADMIN_PASSWORD__" "$(toml_escape "${PGCAT_ADMIN_PASSWORD}")")"
  # The admin username comes from this pod on purpose: `pgcat.adminUser` is also what
  # notify_pgcat() below authenticates with, so rendering it here means the name in the
  # config and the name used to reload can never drift apart and break every RELOAD quietly.
  rendered="$(replace_all "${rendered}" "__ADMIN_USER__" "${PGCAT_ADMIN_USER}")"

  # Any of these surviving means the text did not come from this chart's own scripts (a
  # hand-published ConfigMap, a role-sync from an older image), and pgcat would read a
  # literal `__SERVERS__` as a hostname and fail like a network problem. Refuse the file
  # instead: the previous working config stays live and the message names the token.
  # Deliberately a known-token list rather than any `__X__` pattern — a config of your own
  # may contain double-underscore text that has nothing to do with this chart.
  local token
  for token in __SERVERS__ __DATABASE__ __DB_USER__ __POOL_SIZE__ \
               __POSTGRES_PASSWORD__ __PGCAT_ADMIN_PASSWORD__ __ADMIN_USER__; do
    case "${rendered}" in
      *"${token}"*)
        log_error "refusing to write a config in which ${token} was never substituted (keeping the previous one)"
        PREVIOUS_PUBLISHED="${published}"     # do not retry the same broken text every round
        return 0 ;;
    esac
  done

  if [ -s "${PGCAT_OUT}" ] && printf '%s\n' "${rendered}" | cmp -s - "${PGCAT_OUT}"; then
    PREVIOUS_PUBLISHED="${published}"
    return 0
  fi

  if publish "${rendered}"; then
    # Which host pgcat will now send writes to, parsed out of the server list so the log
    # line stays one line. Deliberately anchored on a server tuple: the template's own
    # prose contains the word "primary" too, and matching that logged a comment line.
    local target
    target="$(grep -m1 '"primary"\]' "${PGCAT_OUT}" | cut -d'"' -f2 || true)"
    log "wrote ${PGCAT_OUT} (write endpoint -> ${target:-unparsable server list})"
    PREVIOUS_PUBLISHED="${published}"
    notify_pgcat
  fi
}

log "watching ConfigMap ${POD_NAMESPACE}/${PGCAT_CONFIGMAP} key ${PGCAT_KEY} every ${PGCAT_WATCH_SECONDS}s -> ${PGCAT_OUT}"
mkdir -p "${PGCAT_OUT_DIR}" 2>/dev/null || true
while true; do
  one_round
  sleep "${PGCAT_WATCH_SECONDS}"
done
