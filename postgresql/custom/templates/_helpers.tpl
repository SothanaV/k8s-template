{{/*
Naming, label, and validation helpers for the postgresql chart.
*/}}

{{- define "postgresql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. values.yaml sets `fullnameOverride` so the Service host is
`postgresql` whatever the release name is; an empty override falls back to the usual
`<release>-<chart>`, with the name de-duplicated when the release already contains it.
*/}}
{{- define "postgresql.fullname" -}}
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

{{- define "postgresql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.labels" -}}
helm.sh/chart: {{ include "postgresql.chart" . }}
{{ include "postgresql.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: postgresql
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service names. The headless Service is the StatefulSet's `serviceName` when enabled.
*/}}
{{- define "postgresql.headlessName" -}}
{{- printf "%s-headless" (include "postgresql.fullname" .) -}}
{{- end -}}

{{- define "postgresql.serviceName" -}}
{{- if .Values.headlessService.enabled -}}
{{- include "postgresql.headlessName" . -}}
{{- else -}}
{{- include "postgresql.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Merges annotation maps left to right (later maps win) and renders them as YAML, or
"" when the merge is empty. Combine with `with` so an object with no annotations gets
no `annotations:` key instead of an empty one:

  {{- with (include "postgresql.annotations" (list .Values.commonAnnotations)) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
*/}}
{{- define "postgresql.annotations" -}}
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
Image reference. An `image.digest` replaces the tag entirely:
`--set image.digest=sha256:<hex> --set image.tag=""`.
*/}}
{{- define "postgresql.image" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s/%s@%s" $registry $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
Full path of the mounted password file, used as POSTGRES_PASSWORD_FILE. The Secret is
mounted as a directory holding exactly one file, so nothing else sits next to it.
*/}}
{{- define "postgresql.passwordFile" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.auth.secretMountPath) .Values.auth.secretKey -}}
{{- end -}}

{{/*
Root of the cluster data in the image: `/var/lib/postgresql`, the postgres user's home
directory (mode 1777 in the Dockerfile) and the single path the data volume mounts at.
PG 18 moved the image VOLUME here from /var/lib/postgresql/data so that one mount keeps
working across a `pg_upgrade --link`.
*/}}
{{- define "postgresql.pgDataRoot" -}}
/var/lib/postgresql
{{- end -}}

{{/*
$PGDATA. PostgreSQL 18+ uses the pg_ctlcluster layout `<root>/<major>/docker`, so a
major-version image bump means bumping `pgMajor` too. The fail below exists because the
alternative is silent and destructive: the entrypoint would find no PG_VERSION at the
new path and run initdb, leaving an empty cluster beside the real data, and the old data
would only surface as the image's "old databases" error.
*/}}
{{- define "postgresql.pgData" -}}
{{- $major := .Values.pgMajor | toString -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- $tagMajor := regexFind "^[0-9]+" $tag | default $major -}}
{{- if not (eq $tagMajor $major) -}}
{{- fail (printf "pgMajor (%s) does not match image.tag (%s): $PGDATA is version-specific, so this pod would initialise an empty cluster next to its real data. Set pgMajor=%s when upgrading the major version." $major $tag $tagMajor) -}}
{{- end -}}
{{- printf "%s/%s/docker" (include "postgresql.pgDataRoot" .) $major -}}
{{- end -}}

{{/*
`postgres -c <key>=<value>` arguments from `postgresqlConfig`, then `args`. Arguments
rather than a bind-mounted file on purpose: the image entrypoint only writes inside
$PGDATA while it is empty, so a mounted postgresql.conf would need a `config_file`
indirection into a writable directory — and arguments also override what any ALTER
SYSTEM left behind in postgresql.auto.conf.
*/}}
{{- define "postgresql.serverArgs" -}}
{{- range $key, $value := .Values.postgresqlConfig }}
- "-c"
- {{ printf "%s=%s" $key (toString $value) | quote }}
{{- end }}
{{- with .Values.args }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Fails the render on values that would otherwise produce objects that quietly do nothing
on the cluster. Called from templates/statefulset.yaml, which is always rendered.
Placeholders are the case this exists for: `storageClassName: <STORAGE_CLASS>` creates a
PVC that stays Pending with a "storageclass not found" event, which is a slow way to
find out you edited the wrong file.
*/}}
{{- define "postgresql.validate" -}}
{{- if and .Values.persistence.enabled (not .Values.persistence.existingClaim) (contains "<" (toString .Values.persistence.storageClass)) -}}
{{- fail (printf "persistence.storageClass is the placeholder %q — use a StorageClass that exists in the target cluster (`kubectl get storageclass`), or \"\" for the cluster default" .Values.persistence.storageClass) -}}
{{- end -}}
{{- if not .Values.auth.existingSecret -}}
{{- fail "auth.existingSecret is empty — create the Secret first (README: Credentials) and put its name here" -}}
{{- else if contains "<" .Values.auth.existingSecret -}}
{{- fail (printf "auth.existingSecret is the placeholder %q — name the Secret that holds auth.secretKey in this namespace" .Values.auth.existingSecret) -}}
{{- end -}}
{{- if contains "<" (include "postgresql.image" .) -}}
{{- fail (printf "the image reference %q still contains a placeholder" (include "postgresql.image" .)) -}}
{{- end -}}
{{- if and (eq .Values.service.type "NodePort") .Values.service.nodePort (not (and (ge (int .Values.service.nodePort) 30000) (le (int .Values.service.nodePort) 32767))) -}}
{{- fail (printf "service.nodePort %v is outside the default NodePort range 30000-32767 (kubelet --service-node-port-range may differ; unset service.nodePort to let the cluster pick)" .Values.service.nodePort) -}}
{{- end -}}
{{- end -}}
