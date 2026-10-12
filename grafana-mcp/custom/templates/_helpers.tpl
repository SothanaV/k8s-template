{{/*
Naming, label, and validation helpers for the mcp-grafana chart.

The selector labels are deliberately a single `app: mcp-grafana` key. The live
Deployment and Service already select on exactly that, and both `spec.selector.matchLabels`
and a Service selector are immutable — any extra key here makes `helm upgrade` fail on the
existing release with "field is immutable".
*/}}

{{- define "mcp-grafana.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcp-grafana.fullname" -}}
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

{{- define "mcp-grafana.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcp-grafana.selectorLabels" -}}
app: {{ include "mcp-grafana.name" . }}
{{- end -}}

{{- define "mcp-grafana.labels" -}}
helm.sh/chart: {{ include "mcp-grafana.chart" . }}
{{ include "mcp-grafana.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mcp-grafana
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Credential Secret name: the explicit override, the chart-managed fullname, or the
pre-created Secret named in `secret.existingSecret`.
*/}}
{{- define "mcp-grafana.secretName" -}}
{{- if .Values.secret.create -}}
{{- default (printf "%s-env" (include "mcp-grafana.fullname" .)) .Values.secret.name -}}
{{- else -}}
{{- required "secret.existingSecret is empty — create the Secret first (README: Prerequisites) or set secret.create=true" .Values.secret.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "mcp-grafana.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "mcp-grafana.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- required "serviceAccount.name is required when serviceAccount.create=false" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. `image.digest` replaces the tag entirely:
`--set image.digest=sha256:<hex> --set image.tag=""`.
*/}}
{{- define "mcp-grafana.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
Probe port: `probes.port` when set, otherwise the container port.
*/}}
{{- define "mcp-grafana.probePort" -}}
{{- if .Values.probes.port -}}
{{- .Values.probes.port -}}
{{- else -}}
{{- .Values.containerPort -}}
{{- end -}}
{{- end -}}

{{/*
Merges annotation maps left to right (later maps win) and renders them as YAML, or "" when
the merge is empty. Combine with `with` so an object with no annotations gets no
`annotations:` key rather than an empty one.
*/}}
{{- define "mcp-grafana.annotations" -}}
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
Fails the render on values that would otherwise produce objects that quietly do nothing, or
that install a pod which cannot start. Called from templates/deployment.yaml, which is
always rendered. Two of these guards are direct responses to how this release was first
installed on the cluster: a `serviceAccount: {}` map that rendered an invalid
serviceAccountName (revision 1, `Release ... failed`), and a placeholder image reference
that installs "successfully" and then sits in ImagePullBackOff.
*/}}
{{- define "mcp-grafana.validate" -}}
{{- if contains "<" (include "mcp-grafana.image" .) -}}
{{- fail (printf "the image reference %q still contains a placeholder — set image.repository/image.tag (or image.digest) in values.local.yaml" (include "mcp-grafana.image" .)) -}}
{{- end -}}

{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) -}}
{{- fail "ingress.enabled is true but ingress.hosts is empty — nothing would route to this server" -}}
{{- end -}}
{{- range $i, $h := .Values.ingress.hosts -}}
{{- if contains "<" (toString $h.host) -}}
{{- fail (printf "ingress.hosts[%d].host is the placeholder %q — set the public host of your ingress controller" $i $h.host) -}}
{{- end -}}
{{- end -}}

{{/*
`serviceAccount.create` must be a bool. A map here once rendered the Deployment
`serviceAccountName: map[create:true name:]`, which the API rejected with an RFC 1123
error and left the release in a failed state.
*/}}
{{- if and (ne (.Values.serviceAccount.create | toString) "true") (ne (.Values.serviceAccount.create | toString) "false") -}}
{{- fail (printf "serviceAccount.create must be true or false, got %v — a map here renders an invalid serviceAccountName" .Values.serviceAccount.create) -}}
{{- end -}}

{{- if and (not .Values.secret.create) (contains "<" (toString .Values.secret.existingSecret)) -}}
{{- fail (printf "secret.existingSecret is the placeholder %q — name the Secret that holds GRAFANA_SERVICE_ACCOUNT_TOKEN in this namespace" .Values.secret.existingSecret) -}}
{{- end -}}

{{- if and .Values.secret.create (contains "<" (toString .Values.plainText)) -}}
{{- fail (printf "secret.create is true but plaintext still contains a placeholder: %v" .Values.plainText) -}}
{{- end -}}

{{/*
`--address` must agree with containerPort, or the pod goes Ready on a port nothing listens
on and every tool call dies with `connection refused`. Only checked when the command binds
an explicit host:port, which is the default form here.
*/}}
{{- $joined := join " " (default (list) .Values.command) -}}
{{- $addr := regexFind "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+" $joined -}}
{{- if $addr -}}
{{- $bound := regexFind ":[0-9]+$" $addr | trimPrefix ":" -}}
{{- if ne $bound (.Values.containerPort | toString) -}}
{{- fail (printf "command binds %s but containerPort is %v — the probes and the Service target a port nothing listens on" $addr .Values.containerPort) -}}
{{- end -}}
{{- end -}}
{{- end -}}
