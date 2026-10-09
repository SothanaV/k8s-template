{{/*
Naming, label, address, and validation helpers for the influxdb-cluster chart.

Cluster formation rests on the address helpers below: each node advertises itself
as `<pod>.<headless>.<namespace>.svc.<domain>` — the fully-qualified name its own
headless Service resolves — and the join Job registers exactly those strings with
`influxd-ctl add-meta` / `add-data`. The raft peer set stored in the meta PVCs and
the `client.json` stored on each data node therefore contain only addresses the
StatefulSets can produce again after any restart.
*/}}

{{- define "influxdb-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. values.yaml pins `fullnameOverride` so the client Service
host is `influxdb-cluster-data` whatever the release is called.
*/}}
{{- define "influxdb-cluster.fullname" -}}
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

{{- define "influxdb-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace for every object and for the advertised hostnames. Point it somewhere
other than the release namespace only if those pods can resolve these headless
records.
*/}}
{{- define "influxdb-cluster.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "influxdb-cluster.labels" -}}
helm.sh/chart: {{ include "influxdb-cluster.chart" . }}
{{ include "influxdb-cluster.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: influxdb-cluster
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "influxdb-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "influxdb-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Component labels: call as (list . "meta") or (list . "data"). The component label is
inside every selector, so the two StatefulSets cannot adopt each other's pods.
*/}}
{{- define "influxdb-cluster.componentLabels" -}}
{{ include "influxdb-cluster.labels" (first .) }}
app.kubernetes.io/component: {{ last . }}
{{- end -}}

{{- define "influxdb-cluster.componentSelectorLabels" -}}
{{ include "influxdb-cluster.selectorLabels" (first .) }}
app.kubernetes.io/component: {{ last . }}
{{- end -}}

{{/*
Merges annotation maps left to right (later maps win), renders them as YAML, or ""
when the merge is empty. Pair with `with` so an object with nothing to annotate gets
no `annotations:` key at all:

  {{- with (include "influxdb-cluster.annotations" (list .Values.commonAnnotations .Values.meta.podAnnotations)) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
*/}}
{{- define "influxdb-cluster.annotations" -}}
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
Image reference: (list . "meta") or (list . "data"). One repository carries both
binary sets (upstream docker/{meta,data}/Dockerfile):

  <tag>-meta  influxd-meta, influxd-ctl          (no influxd, no influx CLI)
  <tag>-data  influxd, influx, influx_inspect    (no influxd-ctl)

No image has both `influxd-ctl` and `influx`, which is why the join Job must run on the
meta image and the `helm test` pod on the data one. `image.digest` must be the map form
{meta: sha256:…, data: sha256:…}: the two node types are two tags, so a single digest
cannot pin both.
*/}}
{{- define "influxdb-cluster.image" -}}
{{- $root := first . -}}
{{- $component := last . -}}
{{- $registry := trimSuffix "/" (default "docker.io" $root.Values.image.registry) -}}
{{- $repository := $root.Values.image.repository -}}
{{- if and (kindIs "map" $root.Values.image.digest) (get $root.Values.image.digest $component) -}}
{{- printf "%s/%s@%s" $registry $repository (get $root.Values.image.digest $component) -}}
{{- else if kindIs "map" $root.Values.image.digest -}}
{{/* an empty digest map means "use the tag": the validator requires both keys once any is set */}}
{{- $tag := printf "%s-%s" ($root.Values.image.tag | default $root.Chart.AppVersion) $component -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- $tag := printf "%s-%s" ($root.Values.image.tag | default $root.Chart.AppVersion) $component -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Join Job image: always the meta flavour of either the chart repository or an override.
*/}}
{{- define "influxdb-cluster.joinerImage" -}}
{{- $root := . -}}
{{- $o := default (dict) .Values.cluster.joiner.image -}}
{{- if or (get $o "repository") (get $o "tag") (get $o "digest") -}}
{{- $registry := trimSuffix "/" (default $root.Values.image.registry (get $o "registry")) -}}
{{- $repository := default $root.Values.image.repository (get $o "repository") -}}
{{- if get $o "digest" -}}
{{- printf "%s/%s@%s" $registry $repository (get $o "digest") -}}
{{- else -}}
{{- $tag := default (printf "%s-meta" ($root.Values.image.tag | default $root.Chart.AppVersion)) (get $o "tag") -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- end -}}
{{- else -}}
{{- include "influxdb-cluster.image" (list . "meta") -}}
{{- end -}}
{{- end -}}

{{/*
Object names. The headless Services are the governing Services and the DNS label
inside every advertised address.
*/}}
{{- define "influxdb-cluster.metaName" -}}
{{- printf "%s-meta" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.dataName" -}}
{{- printf "%s-data" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.metaHeadlessName" -}}
{{- printf "%s-meta-headless" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.dataHeadlessName" -}}
{{- printf "%s-data-headless" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.metaConfigName" -}}
{{- printf "%s-meta-config" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.dataConfigName" -}}
{{- printf "%s-data-config" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.jobName" -}}
{{- printf "%s-join" (include "influxdb-cluster.fullname" .) -}}
{{- end -}}

{{- define "influxdb-cluster.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "influxdb-cluster.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
DNS suffix inside advertised hostnames: `<namespace>.svc.<clusterDomain>`.
*/}}
{{- define "influxdb-cluster.suffix" -}}
{{- printf "%s.svc.%s" (include "influxdb-cluster.namespace" .) (trimPrefix "." (default "cluster.local" .Values.clusterDomain)) -}}
{{- end -}}

{{/*
Advertised addresses. First argument is the root context, last is the pod ordinal:

  {{ include "influxdb-cluster.metaPodAddr" (list $ 0) }}
*/}}
{{- define "influxdb-cluster.metaPodHost" -}}
{{- $root := first . -}}
{{- printf "%s-%d.%s.%s" (include "influxdb-cluster.metaName" $root) (int (last .)) (include "influxdb-cluster.metaHeadlessName" $root) (include "influxdb-cluster.suffix" $root) -}}
{{- end -}}

{{- define "influxdb-cluster.metaPodAddr" -}}
{{- $root := first . -}}
{{- printf "%s:%d" (include "influxdb-cluster.metaPodHost" .) (int $root.Values.ports.metaAPI) -}}
{{- end -}}

{{- define "influxdb-cluster.dataPodHost" -}}
{{- $root := first . -}}
{{- printf "%s-%d.%s.%s" (include "influxdb-cluster.dataName" $root) (int (last .)) (include "influxdb-cluster.dataHeadlessName" $root) (include "influxdb-cluster.suffix" $root) -}}
{{- end -}}

{{- define "influxdb-cluster.dataPodAddr" -}}
{{- $root := first . -}}
{{- printf "%s:%d" (include "influxdb-cluster.dataPodHost" .) (int $root.Values.ports.dataTCP) -}}
{{- end -}}

{{/*
Newline-separated address lists consumed by the join script. `add-meta` and `add-data`
are NOT idempotent (registering the same address twice returns an error), and an
already-registered node is not re-registered by a later call, so the sets are fixed by
ordinal and the script skips whatever `influxd-ctl show` already lists — that is what
makes a retried or re-run Job converge instead of failing.
*/}}
{{- define "influxdb-cluster.metaAddrs" -}}
{{- $root := . -}}
{{- $out := list -}}
{{- range $ordinal := until (int $root.Values.meta.replicas) -}}
{{- $out = append $out (include "influxdb-cluster.metaPodAddr" (list $root $ordinal)) -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end -}}

{{- define "influxdb-cluster.dataAddrs" -}}
{{- $root := . -}}
{{- $out := list -}}
{{- range $ordinal := until (int $root.Values.data.replicas) -}}
{{- $out = append $out (include "influxdb-cluster.dataPodAddr" (list $root $ordinal)) -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end -}}

{{/*
`cluster.databases` (name -> replication factor) as `name|factor` lines.
*/}}
{{- define "influxdb-cluster.databaseList" -}}
{{- $out := list -}}
{{- range $name, $replication := (default (dict) .Values.cluster.databases) -}}
{{- $out = append $out (printf "%s|%s" $name (toString $replication)) -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end -}}

{{/*
Pod `securityContext` from one values block. `enabled: false` renders nothing and so
keeps the images' own default (root) — the upstream volume ownership assumes it, and it
is the only mode this chart is verified against. With `enabled: true` the `auto`
sentinels resolve to uid/gid/fsGroup 1001 (first uid past the system range, valid on
both the Debian and the `*_alpine` image flavours); on provisioners that ignore fsGroup
also enable initContainers.chownData.
*/}}
{{- define "influxdb-cluster.podSecurityContext" -}}
{{- $sc := deepCopy (default (dict) .) -}}
{{- if hasKey $sc "enabled" | ternary (get $sc "enabled") true -}}
{{- $_ := unset $sc "enabled" -}}
{{- if eq (toString (default "auto" $sc.runAsUser)) "auto" -}}
{{- $_ := set $sc "runAsUser" 1001 -}}
{{- end -}}
{{- if eq (toString (default "auto" $sc.runAsGroup)) "auto" -}}
{{- $_ := set $sc "runAsGroup" 1001 -}}
{{- end -}}
{{- if eq (toString (default "auto" $sc.fsGroup)) "auto" -}}
{{- $_ := set $sc "fsGroup" 1001 -}}
{{- end -}}
{{- if empty $sc }}{}{{ else }}{{ toYaml $sc }}{{ end -}}
{{- end -}}
{{- end -}}

{{- define "influxdb-cluster.containerSecurityContext" -}}
{{- $sc := deepCopy (default (dict) .) -}}
{{- if hasKey $sc "enabled" | ternary (get $sc "enabled") true -}}
{{- $_ := unset $sc "enabled" -}}
{{- if empty $sc }}{}{{ else }}{{ toYaml $sc }}{{ end -}}
{{- end -}}
{{- end -}}

{{/*
Probe body. Input dict:
  mode  "tcp" (default) | "http" (GET /ping) | "none"
  port  a named container port
  https render scheme HTTPS (http mode only)
  spec  timing keys spliced in verbatim

`tcp` is the default on purpose. The meta `/ping` answers 200 with an EMPTY body until a
raft leader exists, and the data `/ping` answers 503 until the node has joined (its
handler asks the meta client). An HTTP readiness probe on a cold install therefore
deadlocks the bootstrap this chart automates: pods stay NotReady, nothing joins, the Job
times out. Switch a probe to `http` on an already-formed cluster when you want `/ping` to
catch a node that lost the quorum.
*/}}
{{- define "influxdb-cluster.probe" -}}
{{- $spec := deepCopy (default (dict) .spec) -}}
{{- /* `enabled` gates whether the probe is rendered at all; it is not a probe field, and
     the API server rejects unknown keys inside startupProbe/livenessProbe/readinessProbe */ -}}
{{- $_ := unset $spec "enabled" -}}
{{- if eq .mode "http" -}}
httpGet:
  path: /ping
  port: {{ .port }}
  scheme: {{ ternary "HTTPS" "HTTP" (default false .https) }}
{{- else if eq .mode "none" -}}
{{- else -}}
tcpSocket:
  port: {{ .port }}
{{- end -}}
{{- with $spec }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
TOML scalars: booleans and integers unquoted, everything else a quoted string.
BurntSushi/toml accepts the same double-quoted escapes Go/JSON use, and `%q` is a
real Go printf verb — Go's printf has NO `%S`, which is why the `%S` version of
this helper rendered `%!S(string=info)`.
*/}}
{{- define "influxdb-cluster.tomlValue" -}}
{{- if kindIs "bool" . -}}
{{- ternary "true" "false" . -}}
{{- else if or (kindIs "int64" .) (kindIs "float64" .) -}}
{{- . -}}
{{- else if kindIs "string" . -}}
{{- if regexMatch `^-?[0-9]+(\.[0-9]+)?$` . -}}
{{- . -}}
{{- else -}}
{{- printf "%q" . -}}
{{- end -}}
{{- else -}}
{{- printf "%q" (toString .) -}}
{{- end -}}
{{- end -}}

{{/*
Flat map -> `key = <value>` lines, joined with NO trailing or leading newline. The
caller positions them with `nindent`, and a stray blank line inside a `[section]` block
would end a YAML literal scalar early. Sprig sorts map keys, so renders are stable.
*/}}
{{- define "influxdb-cluster.tomlLines" -}}
{{- $lines := list -}}
{{- range $key, $value := (default (dict) .) -}}
{{- $lines = append $lines (printf "%s = %s" $key (include "influxdb-cluster.tomlValue" $value)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
Extra TOML sections from `<kind>.config`, rendered last so a deliberate override still
lands. Call as

  {{- include "influxdb-cluster.customSections" (dict "sections" .Values.meta.config "kind" "meta") | nindent 0 }}
*/}}
{{- define "influxdb-cluster.customSections" -}}
{{- $kind := .kind -}}
{{- range $section, $entries := (default (dict) .sections) -}}
{{- if not (kindIs "map" $entries) -}}
{{- fail (printf "%s.config.%s must be a map of key = value (the chart renders the section header for you)" $kind $section) -}}
{{- end }}

[{{ $section }}]
  {{- include "influxdb-cluster.tomlLines" $entries | nindent 2 }}
{{- end -}}
{{- end -}}

{{/*
Sections a `<kind>.config` map may not define, because the chart renders them from
other values: `managed` names a section with no keys allowed at all.
*/}}
{{- define "influxdb-cluster.validateCustomSections" -}}
{{- $kind := .kind -}}
{{- $managed := .managed -}}
{{- range $section, $entries := (default (dict) .sections) -}}
{{- if has $section $managed -}}
{{- fail (printf "%s.config.%s is not allowed: the chart renders that section from its own values (ports, persistence, cluster.auth, data.http, data.inputs); drop the section and set those" $kind $section) -}}
{{- else if not (kindIs "map" $entries) -}}
{{- fail (printf "%s.config.%s must be a map of key = value — the chart writes the [section] header for you" $kind $section) -}}
{{- else -}}
{{- $_ := $section -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Keys a per-section override map may not set, because the chart derives them from pod
identity or from another value. An override of `hostname`/`bind-address`-class keys is
the nastiest failure this catches: the node registers an address its peers cannot
resolve, so the cluster forms and then splits on the first pod restart.

  include "influxdb-cluster.rejectKeys" (dict "label" "meta.raft" "map" .Values.meta.raft
    "keys" (list "dir" "bind-address" "http-bind-address"))
*/}}
{{- define "influxdb-cluster.rejectKeys" -}}
{{- range $key, $_ := (default (dict) .map) -}}
{{- if has $key $.keys -}}
{{- fail (printf "%s.%s is not allowed: the chart derives it from ports, persistence, cluster.auth or data.http; drop the key and change those" $.label $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Every key-level rule in one place, so the templates and the validator cannot drift.
*/}}
{{- define "influxdb-cluster.validateConfigKeys" -}}
{{- include "influxdb-cluster.rejectKeys" (dict "label" "meta.raft" "map" .Values.meta.raft "keys" (list "hostname" "dir" "bind-address" "http-bind-address" "auth-enabled" "internal-shared-secret" "shared-secret")) -}}
{{- include "influxdb-cluster.rejectKeys" (dict "label" "data.tsdb" "map" .Values.data.tsdb "keys" (list "dir" "wal-dir")) -}}
{{- include "influxdb-cluster.rejectKeys" (dict "label" "data.hintedHandoff" "map" .Values.data.hintedHandoff "keys" (list "dir")) -}}
{{- $httpKeys := (list "enabled" "bind-address" "auth-enabled" "shared-secret" "https-enabled" "https-certificate" "https-private-key" "realm" "max-body-size" "flux-enabled") -}}
{{- include "influxdb-cluster.rejectKeys" (dict "label" "data.http.config" "map" .Values.data.http.config "keys" $httpKeys) -}}
{{- range $input, $decl := (default (dict) .Values.data.inputs) -}}
{{- include "influxdb-cluster.rejectKeys" (dict "label" (printf "data.inputs.%s.config" $input) "map" $decl.config "keys" (list "enabled" "bind-address" "port")) -}}
{{- end -}}
{{- end -}}

{{/*
Environment that turns authentication on, per consumer. The binaries apply INFLUXDB_*
variables on top of the config file (toml.ApplyEnvOverrides in toml/toml.go), which is
the ONLY way a secret reaches config: influxdb does NOT expand ${VAR} inside the TOML
files, so `shared-secret = "${X}"` would be stored literally as the secret.

Env keys, named after the config structs (services/meta/config.go,
services/httpd/config.go):

  influxd-meta  INFLUXDB_META_AUTH_ENABLED
                INFLUXDB_META_INTERNAL_SHARED_SECRET   (service-to-service JWT)
                INFLUXDB_META_SHARED_SECRET            (user JWT)
  influxd       INFLUXDB_META_META_AUTH_ENABLED        ([meta] meta-auth-enabled)
                INFLUXDB_META_META_INTERNAL_SHARED_SECRET
                INFLUXDB_HTTP_AUTH_ENABLED             ([http] auth-enabled)
                INFLUXDB_HTTP_SHARED_SECRET            ([http] shared-secret)
*/}}
{{- define "influxdb-cluster.authEnv" -}}
{{- $auth := .Values.cluster.auth }}
{{- if eq .kind "meta" }}
{{- if $auth.meta }}
- name: INFLUXDB_META_AUTH_ENABLED
  value: "true"
- name: INFLUXDB_META_INTERNAL_SHARED_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ required "cluster.auth.secretName" $auth.secretName }}
      key: {{ $auth.internalSharedSecretKey }}
- name: INFLUXDB_META_SHARED_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $auth.secretName }}
      key: {{ $auth.sharedSecretKey }}
{{- end }}
{{- else }}
{{- if $auth.meta }}
- name: INFLUXDB_META_META_AUTH_ENABLED
  value: "true"
- name: INFLUXDB_META_META_INTERNAL_SHARED_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ required "cluster.auth.secretName" $auth.secretName }}
      key: {{ $auth.internalSharedSecretKey }}
{{- end }}
{{- if $auth.http }}
- name: INFLUXDB_HTTP_AUTH_ENABLED
  value: "true"
- name: INFLUXDB_HTTP_SHARED_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $auth.secretName }}
      key: {{ $auth.sharedSecretKey }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Credentials for the join script. `influxd-ctl -auth-type jwt -secret <s>` signs its own
token, and the meta handler verifies a token whose `username` claim is empty against
InternalSharedSecret (services/meta/handler.go) — so the Job needs the INTERNAL secret,
not the user-facing one. ADMIN_* are for the data HTTP API, where CREATE USER runs.

Emitted at column 0 and re-indented by `nindent` at the call site.
*/}}
{{- define "influxdb-cluster.joinerEnv" -}}
{{- if .Values.cluster.auth.meta }}
- name: CTL_AUTH_TYPE
  value: jwt
- name: CTL_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ required "cluster.auth.secretName" .Values.cluster.auth.secretName }}
      key: {{ .Values.cluster.auth.internalSharedSecretKey }}
{{- else }}
- name: CTL_AUTH_TYPE
  value: none
{{- end }}
{{- if .Values.cluster.adminUser.enabled }}
- name: ADMIN_USER
  valueFrom:
    secretKeyRef:
      name: {{ required "cluster.adminUser.existingSecret" .Values.cluster.adminUser.existingSecret }}
      key: {{ .Values.cluster.adminUser.userKey }}
- name: ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cluster.adminUser.existingSecret }}
      key: {{ .Values.cluster.adminUser.passwordKey }}
{{- end }}
{{- end -}}

{{/*
Refuses values that would install "successfully" and then quietly do nothing — or, worse,
form a cluster that splits on the first restart. Called from meta-statefulset.yaml,
which always renders. A placeholder storageClassName is the motivating case: every PVC
lands in Pending with one event nobody reads.
*/}}
{{- define "influxdb-cluster.validate" -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" (include "influxdb-cluster.namespace" .)) -}}
{{- fail (printf "namespace %q is not a valid Kubernetes namespace name" (include "influxdb-cluster.namespace" .)) -}}
{{- end -}}
{{- $meta := int .Values.meta.replicas -}}
{{- $data := int .Values.data.replicas -}}
{{- if and (ne $meta 1) (eq (mod $meta 2) 0) -}}
{{- fail (printf "meta.replicas must be odd — raft needs an odd cluster size to hold a quorum; got %d" $meta) -}}
{{- end -}}
{{- if and (gt $meta 1) (lt $meta 3) -}}
{{- fail "meta.replicas must be 1 (single-server bootstrap) or at least 3" -}}
{{- end -}}
{{- if lt $data 1 -}}
{{- fail "data.replicas must be at least 1" -}}
{{- end -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag is empty — it builds the <tag>-meta and <tag>-data image suffixes" -}}
{{- end -}}
{{- if and (kindIs "map" .Values.image.digest) (ne (len .Values.image.digest) 0) -}}
{{- range $component := (list "meta" "data") -}}
{{- if not (get $.Values.image.digest $component) -}}
{{- fail (printf "image.digest has no %q entry — give both a meta and a data sha256, or clear image.digest and use image.tag" $component) -}}
{{- end -}}
{{- end -}}
{{- else if .Values.image.digest -}}
{{- fail "image.digest must be a map of {meta: sha256:…, data: sha256:…}: the two node types are two tags, so one digest cannot pin both" -}}
{{- end -}}
{{- if contains "<" (printf "%v %v" .Values.image.repository .Values.image.tag) -}}
{{- fail (printf "the image reference %q still contains a placeholder" (include "influxdb-cluster.image" (list . "data"))) -}}
{{- end -}}
{{/* the four chart-owned ports share two pods' network namespaces */}}
{{- if eq (int .Values.ports.metaRaft) (int .Values.ports.metaAPI) -}}
{{- fail (printf "ports.metaRaft and ports.metaAPI must differ: raft and the meta HTTP API are separate listeners in the same pod (%d)" .Values.ports.metaRaft) -}}
{{- end -}}
{{- if eq (int .Values.ports.dataTCP) (int .Values.ports.dataHTTP) -}}
{{- fail (printf "ports.dataTCP and ports.dataHTTP must differ (%d)" .Values.ports.dataTCP) -}}
{{- end -}}
{{- include "influxdb-cluster.validateConfigKeys" . -}}
{{/*
The data image's /init-influxdb.sh (upstream docker/data/entrypoint.sh) starts a
temporary STANDALONE influxd on 127.0.0.1:8086 when it sees INFLUXDB_DB,
INFLUXDB_ADMIN_USER or a non-empty /docker-entrypoint-initdb.d while [meta] dir is still
empty. That is OSS-single-node bootstrapping: it writes into the cluster data dir, then
dies, and the resulting node is at best confused. Cluster-mode user/database creation goes
through the data HTTP API instead — the join Job does it.
*/}}
{{- $ossBootstrapEnv := (list "INFLUXDB_DB" "INFLUXDB_ADMIN_USER" "INFLUXDB_ADMIN_PASSWORD" "INFLUXDB_USER" "INFLUXDB_USER_PASSWORD" "INFLUXDB_READ_USER" "INFLUXDB_WRITE_USER" "INFLUXDB_META_DIR" "INFLUXDB_HTTP_AUTH_ENABLED") -}}
{{- range $entry := (default (list) .Values.data.env) -}}
{{- if has $entry.name $ossBootstrapEnv -}}
{{- fail (printf "data.env entry %q triggers the data image's single-node init script (/init-influxdb.sh), which starts a throwaway standalone influxd over the cluster data dir. Create users/databases through the join Job (cluster.databases, cluster.adminUser) or with influx against the data Service" $entry.name) -}}
{{- end -}}
{{- end -}}
{{- range $entry := (default (list) .Values.meta.env) -}}
{{- if has $entry.name (list "INFLUXDB_META_CONFIG_PATH" "INFLUXDB_HOSTNAME") -}}
{{- fail (printf "meta.env entry %q would override the config path or the pod identity this chart manages" $entry.name) -}}
{{- end -}}
{{- end -}}
{{- range $entry := (default (list) .Values.data.env) -}}
{{- if has $entry.name (list "INFLUXDB_CONFIG_PATH" "INFLUXDB_HOSTNAME") -}}
{{- fail (printf "data.env entry %q would override the config path or the pod identity this chart manages" $entry.name) -}}
{{- end -}}
{{- end -}}
{{- $managedByKind := dict "meta" (list "meta" "logging") "data" (list "meta" "data" "http" "hinted-handoff" "coordinator" "graphite" "collectd" "opentsdb" "udp") -}}
{{- range $kind, $decl := (dict "meta" .Values.meta "data" .Values.data) -}}
{{- $sc := toString $decl.persistence.storageClass -}}
{{- if and $decl.persistence.enabled (not $decl.persistence.existingClaim) (contains "<" $sc) -}}
{{- fail (printf "%s.persistence.storageClass is the placeholder %q — use a StorageClass that exists in the target cluster (`kubectl get storageclass`), or \"\" for the cluster default" $kind $sc) -}}
{{- end -}}
{{- if and $decl.persistence.enabled (not $decl.persistence.existingClaim) $sc (not (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" $sc)) -}}
{{- fail (printf "%s.persistence.storageClass %q is not a valid StorageClass name; \"\" selects the cluster default" $kind $sc) -}}
{{- end -}}
{{- if and (not $decl.persistence.enabled) (not $.Values.cluster.allowEphemeral) -}}
{{- fail (printf "%s.persistence.enabled is false, so this node's data dies with the pod; set cluster.allowEphemeral: true to accept that (dev only)" $kind) -}}
{{- end -}}
{{- $mount := trimSuffix "/" (toString $decl.persistence.mountPath) -}}
{{- if not (regexMatch "^/[a-zA-Z0-9._/-]*$" $mount) -}}
{{- fail (printf "%s.persistence.mountPath %q must be a clean absolute path without '..'" $kind $decl.persistence.mountPath) -}}
{{- end -}}
{{- include "influxdb-cluster.validateCustomSections" (dict "kind" (printf "%s.config" $kind) "sections" $decl.config "managed" (get $managedByKind $kind)) -}}
{{- range $section, $entries := (default (dict) $decl.config) -}}
{{- if gt (len $section) 32 -}}
{{- fail (printf "%s.config section name %q is suspiciously long" $kind $section) -}}
{{- end -}}
{{- range $key, $value := (default (dict) $entries) -}}
{{- if kindIs "map" $value -}}
{{- fail (printf "%s.config.%s.%s is a nested map: these TOML sections are flat key = value tables" $kind $section $key) -}}
{{- end -}}
{{- if kindIs "slice" $value -}}
{{- range $item := $value -}}
{{- if kindIs "map" $item -}}
{{- fail (printf "%s.config.%s.%s contains a table inside an array; array-of-tables sections ([[graphite]]) are rendered by data.inputs, not by config" $kind $section $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (index $decl "pdb").enabled (not (index $decl "pdb").maxUnavailable) (le (int $decl.replicas) (int (index $decl "pdb").minAvailable)) -}}
{{- fail (printf "%s.pdb: minAvailable %v with %d replicas blocks every voluntary eviction; scale up, lower minAvailable, or disable the budget" $kind (index $decl "pdb").minAvailable $decl.replicas) -}}
{{- end -}}
{{- range $container := (default (list) $decl.extraContainers) -}}
{{- if or (not $container.name) (not $container.image) -}}
{{- fail (printf "%s.extraContainers entries need at least a name and an image: %v" $kind $container) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $input, $decl := (default (dict) .Values.data.inputs) -}}
{{- if $decl.enabled -}}
{{- $port := int $decl.port -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail (printf "data.inputs.%s.port %v is not a valid port" $input $decl.port) -}}
{{- end -}}
{{- if has $port (list (int $.Values.ports.metaAPI) (int $.Values.ports.metaRaft) (int $.Values.ports.dataHTTP) (int $.Values.ports.dataTCP)) -}}
{{- fail (printf "data.inputs.%s.port %d collides with a chart-owned port in `ports`" $input $port) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $name, $replication := (default (dict) .Values.cluster.databases) -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $name) -}}
{{- fail (printf "cluster.databases key %q is not a usable InfluxQL database identifier (letters, digits, underscore)" $name) -}}
{{- end -}}
{{- if or (lt (int $replication) 1) (gt (int $replication) $data) -}}
{{- fail (printf "cluster.databases.%s replication %v must be between 1 and data.replicas (%d)" $name $replication $data) -}}
{{- end -}}
{{- end -}}
{{- if .Values.cluster.joiner.enabled -}}
{{- if lt (int .Values.cluster.joiner.backoffLimit) 1 -}}
{{- fail "cluster.joiner.backoffLimit must be at least 1 — raft election can need several retries" -}}
{{- end -}}
{{- if not (has "before-hook-creation" (default (list) .Values.cluster.joiner.hookDeletePolicy)) -}}
{{- fail "cluster.joiner.hookDeletePolicy must contain before-hook-creation: the hook Job keeps the same name across upgrades, so without it the second run fails with 'already exists'" -}}
{{- end -}}
{{- if not .Values.data.headlessService.enabled -}}
{{- fail "cluster.joiner.enabled needs data.headlessService.enabled: true — the data pod addresses the Job registers are headless-Service names" -}}
{{- end -}}
{{- if not (or .Values.cluster.joiner.createDatabases .Values.cluster.adminUser.enabled (ne (len .Values.cluster.databases) 0)) -}}
{{- fail "cluster.joiner.enabled with createDatabases: false, adminUser.enabled: false and no cluster.databases: the Job would join nodes and do nothing else — that is a valid configuration, so set cluster.joiner.joinOnly: true to say you mean it" -}}
{{- end -}}
{{- end -}}
{{- if not .Values.data.headlessService.enabled -}}
{{- fail "data.headlessService.enabled: false is not supported: the addresses registered with influxd-ctl are headless-Service pod names, and without that Service the data nodes advertise localhost and the cluster cannot gossip (README: Manual joining covers running without it)" -}}
{{- end -}}
{{- $auth := .Values.cluster.auth -}}
{{- if or $auth.http $auth.meta -}}
{{- if not .Values.cluster.adminUser.enabled -}}
{{- fail "cluster.auth.http/meta need cluster.adminUser.enabled: true. With meta auth on, the meta API answers 'must create admin user first' to every request — including /ping — until an ADMIN user exists in raft, and that user can only be created through the data HTTP API" -}}
{{- else if contains "<" (toString .Values.cluster.adminUser.existingSecret) -}}
{{- fail (printf "cluster.adminUser.existingSecret is the placeholder %q — create the Secret and put its name here" .Values.cluster.adminUser.existingSecret) -}}
{{- else if not $auth.acknowledged -}}
{{- fail "cluster.auth.http/meta are on but cluster.auth.acknowledged is empty. Turn authentication on in a SECOND upgrade, after `kubectl exec <pod> -- influx -execute 'SHOW USERS'` lists the admin user (README: Authentication)" -}}
{{- else if not $auth.secretName -}}
{{- fail "cluster.auth.http/meta need cluster.auth.secretName: [http] shared-secret and the influxd-ctl JWT are both read from that Secret" -}}
{{- else if contains "<" $auth.secretName -}}
{{- fail (printf "cluster.auth.secretName is the placeholder %q — create the Secret and put its name here" $auth.secretName) -}}
{{- end -}}
{{- if and $auth.meta (not .Values.cluster.joiner.enabled) -}}
{{- fail "cluster.auth.meta with cluster.joiner.enabled: false leaves the cluster unformed: influxd-ctl cannot authenticate. Enable the joiner, or join by hand with `influxd-ctl -auth-type jwt -secret <INTERNAL_SHARED_SECRET>`" -}}
{{- end -}}
{{- if and $auth.meta (not .Values.cluster.adminUser.admin) -}}
{{- fail "cluster.auth.meta needs cluster.adminUser.admin: true — the meta API only accepts an admin user's credentials" -}}
{{- end -}}
{{- end -}}
{{- if and (not .Values.data.http.enabled) .Values.tests.enabled -}}
{{- fail "data.http.enabled is false, so `helm test` (which writes and queries over HTTP) cannot pass: set tests.enabled: false or re-enable the HTTP API" -}}
{{- end -}}
{{- if and (not .Values.data.http.enabled) (gt (len .Values.cluster.databases) 0) .Values.cluster.joiner.createDatabases -}}
{{- fail "cluster.databases needs data.http.enabled: true: the Job creates them through the data HTTP API" -}}
{{- end -}}
{{- if .Values.data.ingress.enabled -}}
{{- range $host := .Values.data.ingress.hosts -}}
{{- if not $host.host -}}
{{- fail "every data.ingress.hosts entry needs a `host`" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and (eq .Values.data.service.type "NodePort") .Values.data.service.nodePort (not (and (ge (int .Values.data.service.nodePort) 30000) (le (int .Values.data.service.nodePort) 32767))) -}}
{{- fail (printf "data.service.nodePort %v is outside the default NodePort range 30000-32767 (unset it to let the cluster pick)" .Values.data.service.nodePort) -}}
{{- end -}}
{{- end -}}
