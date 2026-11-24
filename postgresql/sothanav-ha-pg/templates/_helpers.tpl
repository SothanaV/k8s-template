{{/*
Naming, label, address, config-rendering and validation helpers for the pg-ha chart.

Cluster formation rests on the address helpers below: each node registers itself with
repmgr as `<pod>.<headless>.<namespace>.svc.<domain>` — the per-pod record its own
headless Service publishes — and the same strings land in pgcat's server list. A bare pod
name would NOT resolve: per-pod records live under the headless Service's subdomain, which
is not part of a pod's search list. So every address in this chart is fully qualified, and
`entrypoint.sh` rebuilds them from POD_NAME/HEADLESS_SERVICE/CLUSTER_DOMAIN at boot.
*/}}

{{- define "sothanav-ha-pg.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. values.yaml pins `fullnameOverride` to `pg-ha` so node
hostnames stay `pg-ha-<ordinal>.pg-ha-headless.<namespace>.svc` whatever the release is
called — repmgr stores those hostnames in its own metadata, so a rename mid-life means
every registration in the volume points at a name nothing resolves.
*/}}
{{- define "sothanav-ha-pg.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "sothanav-ha-pg.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sothanav-ha-pg.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "sothanav-ha-pg.labels" -}}
helm.sh/chart: {{ include "sothanav-ha-pg.chart" . }}
{{ include "sothanav-ha-pg.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: pg-ha
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "sothanav-ha-pg.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sothanav-ha-pg.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Component labels: call as (list . "database") or (list . "pgcat"). The component label is
inside every selector, so the pooler Deployment can never adopt database pods, and the
ServiceMonitor can select the pooler Service alone.
*/}}
{{- define "sothanav-ha-pg.componentLabels" -}}
{{ include "sothanav-ha-pg.labels" (first .) }}
app.kubernetes.io/component: {{ last . }}
{{- end -}}

{{- define "sothanav-ha-pg.componentSelectorLabels" -}}
{{ include "sothanav-ha-pg.selectorLabels" (first .) }}
app.kubernetes.io/component: {{ last . }}
{{- end -}}

{{/*
Merges annotation maps left to right (later maps win) and renders them as YAML, or ""
when the merge is empty. Combine with `with` so an object with no annotations gets no
`annotations:` key instead of an empty one:

  {{- with (include "sothanav-ha-pg.annotations" (list .Values.commonAnnotations)) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
*/}}
{{- define "sothanav-ha-pg.annotations" -}}
{{- $merged := dict -}}
{{- range $map := . -}}
{{- range $key, $value := default (dict) $map -}}
{{- $_ := set $merged $key $value -}}
{{- end -}}
{{- end -}}
{{- if $merged }}
{{- toYaml $merged }}
{{- end }}
{{- end -}}

{{/*
Database image reference — the image you built from `image/Dockerfile`. An
`image.digest` replaces the tag entirely.

`image.registry` may be empty, and it should be when `image.repository` already carries
the host (`registry.local:5000/pg-ha`): prefixing `docker.io` there would produce
`docker.io/registry.local:5000/pg-ha`, which no registry serves.
*/}}
{{- define "sothanav-ha-pg.image" -}}
{{- $registry := trimSuffix "/" (default "" .Values.image.registry) -}}
{{- $ref := .Values.image.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry .Values.image.repository -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $ref .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
pgcat image reference. Upstream image, unmodified; it publishes no semver tags, so
`pgcat.image.digest` is the only reproducible pin (README "Images").
*/}}
{{- define "sothanav-ha-pg.pgcatImage" -}}
{{- $registry := trimSuffix "/" (default "ghcr.io" .Values.pgcat.image.registry) -}}
{{- if .Values.pgcat.image.digest -}}
{{- printf "%s/%s@%s" $registry .Values.pgcat.image.repository .Values.pgcat.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .Values.pgcat.image.repository (.Values.pgcat.image.tag | default "latest") -}}
{{- end -}}
{{- end -}}

{{/*
Object names.
*/}}
{{- define "sothanav-ha-pg.headlessName" -}}
{{- printf "%s-headless" (include "sothanav-ha-pg.fullname" .) -}}
{{- end -}}

{{/*
ConfigMap holding pgcat.toml.tpl, postgresql-append.conf and repmgr-extra.conf, mounted
read-only at /templates in the database pods. Nothing writes it at runtime: it is chart
output, so `helm diff`/`helm rollback` covers it.
*/}}
{{- define "sothanav-ha-pg.confName" -}}
{{- printf "%s-conf" (include "sothanav-ha-pg.fullname" .) -}}
{{- end -}}

{{/*
ConfigMap holding the LIVE pgcat.toml, published by pgcat-role-sync.sh on the primary
node and read by the pgcat sidecar. Separate from the one above because Helm owns that
one and the cluster owns this one at runtime.
*/}}
{{- define "sothanav-ha-pg.publishedName" -}}
{{- printf "%s-config" (include "sothanav-ha-pg.pgcatName" .) -}}
{{- end -}}

{{- define "sothanav-ha-pg.pgcatName" -}}
{{- if .Values.pgcat.fullnameOverride -}}
{{- .Values.pgcat.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-pgcat" (include "sothanav-ha-pg.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "sothanav-ha-pg.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "sothanav-ha-pg.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Identity of the pgcat pod. Deliberately NOT the database ServiceAccount: the sidecar only
reads the published ConfigMap, and binding one identity to both workloads would give the
externically reachable pooler a write on the file the sidecar then substitutes the real
database password into. See rbac.yaml.
*/}}
{{- define "sothanav-ha-pg.pgcatServiceAccountName" -}}
{{- if .Values.pgcat.serviceAccount.create -}}
{{- default (include "sothanav-ha-pg.pgcatName" .) .Values.pgcat.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.pgcat.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
DNS suffix inside every advertised hostname: `<namespace>.svc.<clusterDomain>`.
*/}}
{{- define "sothanav-ha-pg.dnsSuffix" -}}
{{- printf "%s.svc.%s" (include "sothanav-ha-pg.namespace" .) (trimPrefix "." (default "cluster.local" .Values.clusterDomain)) -}}
{{- end -}}

{{/*
Fully qualified host of one node. Arguments are the root context and the pod ordinal:

  {{ include "sothanav-ha-pg.podHost" (list $ 0) }}
*/}}
{{- define "sothanav-ha-pg.podHost" -}}
{{- $root := first . -}}
{{- printf "%s-%d.%s.%s" (include "sothanav-ha-pg.fullname" $root) (int (last .)) (include "sothanav-ha-pg.headlessName" $root) (include "sothanav-ha-pg.dnsSuffix" $root) -}}
{{- end -}}

{{/*
Pod name (not the FQDN) of the ordinal that bootstraps as primary. `entrypoint.sh`
compares this with its own POD_NAME to decide between `initdb` + `primary register` and
`standby clone`, and passes it to pgcat-role-sync.sh only for log/annotation messages.
*/}}
{{- define "sothanav-ha-pg.bootstrapPrimaryPod" -}}
{{- printf "%s-%d" (include "sothanav-ha-pg.fullname" .) (int .Values.bootstrap.primaryOrdinal) -}}
{{- end -}}

{{/*
Comma-separated FQDNs of every node, in ordinal order — PARTNER_HOSTS in the entrypoint.
Generated here rather than derived in bash so the database pods, the sync script, and
`repmgr cluster show` all agree on one spelling of the cluster membership.
*/}}
{{- define "sothanav-ha-pg.partnerHosts" -}}
{{- $root := . -}}
{{- $hosts := list -}}
{{- range $i := until (int .Values.replicas) -}}
{{- $hosts = append $hosts (include "sothanav-ha-pg.podHost" (list $root $i)) -}}
{{- end -}}
{{- join "," $hosts -}}
{{- end -}}

{{/*
`postgresqlConfig` as postgresql.conf lines, appended to `$PGDATA/postgresql.conf` on
first init only. Values are quoted when they are not a plain token, because
`listen_addresses = *` is a syntax error while `listen_addresses = '*'` is not, and
`max_connections = '200'` is accepted just as `200` is.
*/}}
{{- define "sothanav-ha-pg.postgresqlAppendConf" -}}
{{- range $key, $value := .Values.postgresqlConfig }}
{{- $v := toString $value }}
{{- if regexMatch "^[A-Za-z0-9_.:+/-]+$" $v }}
{{ printf "%s = %s" $key $v }}
{{- else }}
{{ printf "%s = '%s'" $key $v }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
`repmgr.settings` as verbatim repmgr.conf lines. The chart rejects the keys it renders
itself (see `sothanav-ha-pg.validate`), so an append here cannot contradict identity.
*/}}
{{- define "sothanav-ha-pg.repmgrExtraConf" -}}
{{- range $key, $value := .Values.repmgr.settings }}
{{- $v := toString $value }}
{{- if regexMatch "^[A-Za-z0-9_.:+/-]+$" $v }}
{{ printf "%s=%s" $key $v }}
{{- else }}
{{ printf "%s='%s'" $key $v }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The pgcat template text: `pgcat.configTemplate` when set, `files/pgcat.toml.tpl`
otherwise. Keeping the default in a file rather than inline in values.yaml means the
token contract stays editable/diffable as TOML, and `--set-file pgcat.configTemplate=...`
replaces it without touching the chart.
*/}}
{{- define "sothanav-ha-pg.pgcatTemplate" -}}
{{- $custom := trim (toString .Values.pgcat.configTemplate) -}}
{{- if $custom -}}
{{- $custom -}}
{{- else -}}
{{- .Files.Get "files/pgcat.toml.tpl" -}}
{{- end -}}
{{- end -}}

{{/*
Rejects keys a per-key override map may not set, because the chart derives them from pod
identity or from another value. The nastiest case this catches is a `postgresqlConfig`
that drops `shared_preload_libraries`: the cluster boots, repmgrd cannot load its
extension, and automatic failover is silently dead until the first primary loss.

  include "sothanav-ha-pg.rejectKeys" (dict "label" "repmgr.settings" "map" .Values.repmgr.settings
    "keys" (list "node_id" "node_name"))
*/}}
{{- define "sothanav-ha-pg.rejectKeys" -}}
{{- range $key, $_ := (default (dict) .map) -}}
{{- if has $key $.keys -}}
{{- fail (printf "%s.%s is not allowed: the chart renders that key from pod identity, ports, or another value — drop the key and change those" $.label $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Every key-level rule in one place, so the templates and the validator cannot drift.
*/}}
{{- define "sothanav-ha-pg.validateConfigKeys" -}}
{{- include "sothanav-ha-pg.rejectKeys" (dict "label" "postgresqlConfig" "map" .Values.postgresqlConfig "keys" (list "listen_addresses" "shared_preload_libraries")) -}}
{{- include "sothanav-ha-pg.rejectKeys" (dict "label" "repmgr.settings" "map" .Values.repmgr.settings "keys" (list "node_id" "node_name" "conninfo" "data_directory" "pg_bindir" "failover" "promote_command" "follow_command" "log_file")) -}}
{{- end -}}

{{/*
Fails the render on values that would otherwise produce a cluster that quietly does the
wrong thing. Called from templates/statefulset.yaml, which is always rendered.

Placeholders are one case this exists for: a PVC with a nonexistent StorageClass installs
"successfully" and then sits in Pending, and an image you never pushed installs
"successfully" and then sits in ImagePullBackOff — both slow ways to learn you edited the
wrong file. The rest are the pairings that break failover rather than boot, which is worse
because they stay hidden until the first primary loss: pool sizes that exceed
max_connections, an admin database that is also a pooled database (pgcat then refuses the
RELOAD that follows every failover), and a securityContext that forbids the root to uid 999
step-down the entrypoint is built on.
*/}}
{{- define "sothanav-ha-pg.validate" -}}
{{- include "sothanav-ha-pg.validateConfigKeys" . -}}

{{- /* ---- placeholders ---- */ -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository is empty — the rendered image reference would be unpullable. Build image/Dockerfile, push it, and put that path here" -}}
{{- end -}}
{{- if contains "<" (include "sothanav-ha-pg.image" .) -}}
{{- fail (printf "image.repository is the placeholder %q — build image/Dockerfile and push it, then set image.repository to that path (README: Build the database image)" .Values.image.repository) -}}
{{- end -}}
{{- if and .Values.persistence.enabled (not .Values.persistence.existingClaim) (contains "<" (toString .Values.persistence.storageClass)) -}}
{{- fail (printf "persistence.storageClass is the placeholder %q — use a StorageClass that exists in the target cluster (`kubectl get storageclass`), or \"\" for the cluster default" .Values.persistence.storageClass) -}}
{{- end -}}
{{- if contains "<" (include "sothanav-ha-pg.pgcatImage" .) -}}
{{- fail (printf "pgcat.image.repository is the placeholder %q" .Values.pgcat.image.repository) -}}
{{- end -}}
{{- if not .Values.auth.existingSecret -}}
{{- fail "auth.existingSecret is empty — create the Secret first (README: Credentials) and put its name here" -}}
{{- else if contains "<" .Values.auth.existingSecret -}}
{{- fail (printf "auth.existingSecret is the placeholder %q — name the Secret that holds the three password keys in this namespace" .Values.auth.existingSecret) -}}
{{- end -}}

{{- /* ---- cluster size and failover ---- */ -}}
{{- $replicas := int .Values.replicas -}}
{{- if lt $replicas 1 -}}
{{- fail (printf "replicas is %d — this chart drives one StatefulSet and needs at least 1" $replicas) -}}
{{- end -}}
{{- if not (has .Values.repmgr.failover (list "automatic" "manual")) -}}
{{- fail (printf "repmgr.failover is %q — repmgr accepts only 'automatic' or 'manual'" .Values.repmgr.failover) -}}
{{- end -}}
{{- if and (eq .Values.repmgr.failover "automatic") (lt $replicas 3) -}}
{{- fail (printf "replicas is %d with repmgr.failover=automatic — two nodes can both conclude the other is gone and promote themselves. Use 3 or more, or set repmgr.failover=manual and promote by hand" $replicas) -}}
{{- end -}}
{{- if ge (int .Values.bootstrap.primaryOrdinal) $replicas -}}
{{- fail (printf "bootstrap.primaryOrdinal (%v) must be an existing pod: replicas is %d, so the ordinals are 0-%d" .Values.bootstrap.primaryOrdinal $replicas (sub $replicas 1)) -}}
{{- end -}}

{{- /* ---- versions ---- */ -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- $tagMajor := regexFind "^[0-9]+" $tag -}}
{{- $binMajor := regexFind "postgresql/[0-9]+" .Values.repmgr.pgBindir | trimPrefix "postgresql/" -}}
{{- if and $tagMajor $binMajor (not (eq $tagMajor $binMajor)) -}}
{{- fail (printf "image.tag (%s) and repmgr.pgBindir (%s) disagree on the PostgreSQL major: repmgr must call the matching pg_ctl/pg_rewind, and the package is postgresql-<major>-repmgr in image/Dockerfile" $tag .Values.repmgr.pgBindir) -}}
{{- end -}}

{{- /* ---- persistence ---- */ -}}
{{- if and .Values.persistence.existingClaim (gt $replicas 1) -}}
{{- fail (printf "persistence.existingClaim with replicas=%d would mount ONE volume in %d pods: every node would open the same data directory and corrupt it. One claim per node comes from volumeClaimTemplates, so leave existingClaim empty" $replicas $replicas) -}}
{{- end -}}

{{- /* ---- security context vs the root -> 999 step-down ---- */ -}}
{{- if and .Values.podSecurityContext.enabled .Values.podSecurityContext.runAsNonRoot -}}
{{- fail "podSecurityContext.runAsNonRoot is true, but entrypoint.sh starts as root and steps down to uid 999 with as-postgres: kubelet would refuse to start the pod and no node would ever initialise. Leave runAsNonRoot=false (README: Security)" -}}
{{- end -}}
{{- if and .Values.containerSecurityContext.enabled (not .Values.containerSecurityContext.allowPrivilegeEscalation) -}}
{{- fail "containerSecurityContext.allowPrivilegeEscalation is false, but the step-down from root to uid 999 is a privilege transition: the entrypoint would die before initdb. Keep it true (README: Security)" -}}
{{- end -}}

{{- /* ---- AppArmor profile (only checked when you set one; README: AppArmor) ----
A `podSecurityContext.appArmorProfile` that renders is a pod the API accepts; an empty or
mis-typed one is a pod kubelet never starts, which looks like a broken chart. */ -}}
{{- range $key, $ctx := (dict "podSecurityContext" .Values.podSecurityContext "pgcat.podSecurityContext" .Values.pgcat.podSecurityContext) -}}
{{- if hasKey $ctx "appArmorProfile" -}}
{{- $aa := default (dict) $ctx.appArmorProfile -}}
{{- $type := default "" $aa.type -}}
{{- if not (has $type (list "Unconfined" "RuntimeDefault" "Localhost")) -}}
{{- fail (printf "%s.appArmorProfile.type is %q: the API accepts only Unconfined, RuntimeDefault or Localhost (and an omitted type is a validation error, so `appArmorProfile: {}` is not the same as leaving it out)" $key $type) -}}
{{- end -}}
{{- if and (eq $type "Localhost") (not $aa.profileName) -}}
{{- fail (printf "%s.appArmorProfile.type is Localhost but profileName is empty — Localhost names a profile loaded on every node, e.g. profileName: my-postgres-profile (README: AppArmor)" $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ---- pgcat vs the database ---- */ -}}
{{- if eq .Values.pgcat.adminDatabase .Values.auth.database -}}
{{- fail (printf "pgcat.adminDatabase equals auth.database (%q): pgcat only opens an admin session on a database with NO pool configured, so the RELOAD after every failover would die with 'No pool configured for database'. Set adminDatabase to something unused, e.g. pgcat" .Values.auth.database) -}}
{{- end -}}
{{- if eq .Values.pgcat.adminUser .Values.auth.username -}}
{{- fail (printf "pgcat.adminUser equals auth.username (%q): normal client sessions would land on pgcat's admin page instead of a pooled connection" .Values.auth.username) -}}
{{- end -}}
{{- $maxConns := int (default "100" (toString (default (dict) .Values.postgresqlConfig).max_connections)) -}}
{{- $needed := mul (int .Values.pgcat.poolSize) (int .Values.pgcat.replicas) -}}
{{- if gt $needed $maxConns -}}
{{- fail (printf "pgcat.poolSize (%d) x pgcat.replicas (%d) = %d backend connections, over postgresqlConfig.max_connections (%d): the pools would sit in a connect/retry loop under load" (int .Values.pgcat.poolSize) (int .Values.pgcat.replicas) $needed $maxConns) -}}
{{- end -}}
{{- if gt $needed (div (mul $maxConns 4) 5) -}}
{{- fail (printf "pgcat.poolSize x pgcat.replicas = %d of %d max_connections: keep at least 20%% free for repmgrd pings, monitoring, and an operator psql session during an incident" $needed $maxConns) -}}
{{- end -}}
{{- if and (eq .Values.pgcat.service.type "NodePort") .Values.pgcat.service.nodePort (not (and (ge (int .Values.pgcat.service.nodePort) 30000) (le (int .Values.pgcat.service.nodePort) 32767))) -}}
{{- fail (printf "pgcat.service.nodePort %v is outside the default NodePort range 30000-32767 (kubelet --service-node-port-range may differ; unset pgcat.service.nodePort to let the cluster pick)" .Values.pgcat.service.nodePort) -}}
{{- end -}}

{{- /* ---- the template must actually carry the tokens the scripts fill in ---- */ -}}
{{- $tpl := include "sothanav-ha-pg.pgcatTemplate" . -}}
{{- if not $tpl -}}
{{- fail "no pgcat template found: pgcat.configTemplate is empty and files/pgcat.toml.tpl is missing from the chart" -}}
{{- end -}}
{{- if not (contains "__SERVERS__" $tpl) -}}
{{- fail "the pgcat template has no server-list token, so pgcat-role-sync.sh cannot publish a primary: a failover would leave pgcat pointing at a fixed server list. Copy files/pgcat.toml.tpl and keep the token, or drop the custom pgcat.configTemplate" -}}
{{- end -}}
{{- if not (contains "__POSTGRES_PASSWORD__" $tpl) -}}
{{- fail "the pgcat template has no postgres-password token, so pgcat has no credential for its pools and every client connection is rejected. Keep the token from files/pgcat.toml.tpl" -}}
{{- end -}}
{{- /*
The admin username is a value, so the template has to take it from the value: a template that
hardcodes `pgcat_admin` while pgcat.adminUser says otherwise makes every RELOAD fail with an
authentication error that the sidecar reports as "pgcat not up yet".
*/ -}}
{{- if not (contains "__ADMIN_USER__" $tpl) -}}
{{- fail "the pgcat template has no admin-username token, so pgcat.adminUser would be ignored while the sidecar still reloads with it: every RELOAD after a failover would be rejected. Keep the token from files/pgcat.toml.tpl" -}}
{{- end -}}
{{- end -}}
