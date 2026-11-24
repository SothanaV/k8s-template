# =============================================================================
# Append this block to the END of the LIVE superset-config secret's
# superset_config.py (ns/superset). It is a fragment, not a standalone file --
# the live secret's superset_config.py is a different, richer file than the
# copy in this folder. Do NOT replace the live secret with this repo's copy:
# the live one holds the real OAuth provider, Celery beat schedule, SMTP,
# FEATURE_FLAGS, SECRET_KEY and RESULTS_BACKEND.
#
#   kubectl -n superset get secret superset-config \
#     -o jsonpath='{.data.superset_config\.py}' | base64 -d > /tmp/sc.py
#   # ...append the chosen OPTION to /tmp/sc.py, then:
#   kubectl -n superset create secret generic superset-config \
#     --from-file=superset_config.py=/tmp/sc.py \
#     --from-file=superset_bootstrap.sh=... --from-file=superset_init.sh=... \
#     --dry-run=client -o yaml | kubectl -n superset apply -f -
#   kubectl -n superset rollout restart deploy/superset-mcp deploy/superset
#
# MCP_* keys MUST live here. auth.py reads them via current_app.config.get(),
# which only ever sees superset_config.py -- container env vars are ignored.
# =============================================================================

# --- Superset MCP service ----------------------------------------------------

# Tools that build Explore/chart-preview links default to
# http://localhost:9001 (see mcp_service/mcp_config.py), which is wrong here.
SUPERSET_WEBSERVER_ADDRESS = "http://superset.superset.svc:8088"

# MCP_RBAC_ENABLED defaults to True and should stay that way: tools with a
# class_permission_name are checked against the FAB security manager as
# whoever the request resolves to.
MCP_RBAC_ENABLED = True

# -----------------------------------------------------------------------------
# OPTION A -- single shared identity (unblocks today). ONLY acceptable while
# /mcp is not publicly reachable, because every caller inherits this one
# identity and its full RBAC grant. Pick a least-privilege service user;
# 'data_user' (Gamma, read-only) already exists. 'admin' is what is currently
# used elsewhere and grants execute_sql + create_virtual_dataset over all data.
# -----------------------------------------------------------------------------
MCP_DEV_USERNAME = "data_user"

# -----------------------------------------------------------------------------
# OPTION B -- JWT against oauth-prd-moma. NOT AVAILABLE TODAY. Do not set these
# until the IdP is fixed; with no keys configured, mcp_config.py logs
# "MCP_AUTH_ENABLED is True but no JWT keys/secret configured", returns None,
# and you are back to the original "No authenticated user found" failure.
#
# Blockers verified in ns/oauth (image oauth:development-20261120-0655):
#   1. No JWKS endpoint. authen/urls.py registers only the two
#      openid-configuration views; GET /.well-known/jwks.json and
#      /o/.well-known/jwks.json both 404.
#   2. authen/views.py::_openid_configuration builds the discovery doc by hand
#      and never emits a "jwks_uri" key.
#   3. No OIDC_RSA_KEY in backend/settings.py or in the container env, so
#      django-oauth-toolkit has no RSA signing key. The advertised
#      "id_token_signing_alg_values_supported": ["RS256"] is a hardcoded
#      placeholder (the source comment literally says "Specify the algorithm
#      you are using").
#   4. django-oauth-toolkit 3.0.1 issues OPAQUE access tokens. A bearer access
#      token cannot be verified as a JWT, so JWKS-based validation has nothing
#      to validate.
#
# MCP_JWT_ALGORITHM = "RS256"
# MCP_JWKS_URI = "https://oauth-prd-moma.tlnw.magnecomp.com/.well-known/jwks.json"
# MCP_JWT_ISSUER = "https://oauth-prd-moma.tlnw.magnecomp.com"
# MCP_JWT_AUDIENCE = "superset-mcp"
# MCP_REQUIRED_SCOPES = ["superset:read"]
# MCP_DEV_USERNAME = None

# -----------------------------------------------------------------------------
# OPTION B IS ALSO NOT SUFFICIENT ON ITS OWN -- read this before committing to
# a JWT project.
#
# In this build, nothing maps a verified principal to a Superset FAB user.
# auth.py::get_user_from_request() tries exactly two things: `g.user` (set by
# "external middleware" that does not ship here) and MCP_DEV_USERNAME.
# jwt_verifier.py reads claims only for logging and scope checks (claims.get
# ("client_id") or claims.get("sub")), never to look up a User.
#
# So the claim in how-to-superset-mcp.md -- "The MCP server resolves the
# Superset user automatically from sub, client_id, email, or username JWT
# claims" -- is FALSE for image superset:20260626. Turning on Option B alone
# gets you per-request token *validation* but the same user-resolution error.
# True per-user RBAC needs custom code: an MCP_AUTH_FACTORY provider plus
# middleware that sets g.user from the verified principal.
#
# MCP_AUTH_FACTORY contract (fastmcp 3.2.4, installed at runtime):
#   from fastmcp.server.auth import AuthProvider, AccessToken
#   class UserinfoAuthProvider(AuthProvider):
#       async def verify_token(self, token: str) -> AccessToken | None:
#           # POST/GET the bearer to the IdP userinfo endpoint
#           #   http://oauth-service.oauth:8000/api/v1/account/me/
#           # which works with OPAQUE tokens (no IdP change needed), then:
#           #   return AccessToken(token=token, client_id=username,
#           #                      scopes=[...], subject=username, claims={...})
#           #   return None  # -> 401
#       ...and middleware to copy the verified subject onto flask.g.user.
# -----------------------------------------------------------------------------
