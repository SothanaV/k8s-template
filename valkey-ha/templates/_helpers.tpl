{{/*
Naming, label, address and validation helpers for the valkey-ha chart.

Cluster formation rests on the per-node Service helpers below: instead of the compose
template's static IPs (172.29.0.11-13), each pod is reached through `<fullname>-node-<i>`,
a ClusterIP Service whose VIP survives pod rescheduling. Sentinel's persisted monitor
line, HAProxy's generated server list, and the entrypoints' boot-time master discovery
all speak these addresses, so a pod that moves to another node (new pod IP) never
invalidates anything the cluster stored — kube-proxy follows the pod, the VIP does not
move.
*/}}

{{- define "valkey-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name. values.yaml pins `fullnameOverride` to `valkey-ha` so node
addresses stay `<fullname>-node-<i>` whatever the release is called — Sentinel rewrites
its state file with the address it monitors, and those strings outlive the config that
seeded them.
*/}}
{{- define "valkey-ha.fullname" -}}
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

{{- define "valkey-ha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "valkey-ha.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "valkey-ha.labels" -}}
helm.sh/chart: {{ include "valkey-ha.chart" . }}
{{ include "valkey-ha.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: valkey-ha
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "valkey-ha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "valkey-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Component labels: call as (list . "valkey"), (list . "haproxy") or (list . "redis-insight").
The component label is inside every selector, so the HAProxy Deployment can never adopt
data pods and the node Services can never select the proxies.
*/}}
{{- define "valkey-ha.componentLabels" -}}
{{ include "valkey-ha.labels" (first .) }}
app.kubernetes.io/component: {{ last . }}
{{- end -}}

{{- define "valkey-ha.componentSelectorLabels" -}}
{{ include "valkey-ha.selectorLabels" (first .) }}
app.kubernetes.io/component: {{ last . }}
{{- end -}}

{{/*
Image references. `image.registry` may be empty, and it should be when `repository`
already carries the host (`registry.local:5000/valkey`): prefixing `docker.io` there
would produce `docker.io/registry.local:5000/valkey`, which no registry serves.
*/}}
{{- define "valkey-ha.image" -}}
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

{{- define "valkey-ha.haproxyImage" -}}
{{- $img := .Values.haproxy.image -}}
{{- $registry := trimSuffix "/" (default "" $img.registry) -}}
{{- $ref := $img.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $img.repository -}}
{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (default "latest" $img.tag) -}}
{{- end -}}
{{- end -}}

{{- define "valkey-ha.redisInsightImage" -}}
{{- $img := .Values.redisInsight.image -}}
{{- $registry := trimSuffix "/" (default "" $img.registry) -}}
{{- $ref := $img.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $img.repository -}}
{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (default "latest" $img.tag) -}}
{{- end -}}
{{- end -}}

{{/*
Object names.
*/}}
{{- define "valkey-ha.headlessName" -}}
{{- printf "%s-headless" (include "valkey-ha.fullname" .) -}}
{{- end -}}

{{- define "valkey-ha.scriptsName" -}}
{{- printf "%s-scripts" (include "valkey-ha.fullname" .) -}}
{{- end -}}

{{- define "valkey-ha.sentinelConfName" -}}
{{- printf "%s-sentinel" (include "valkey-ha.fullname" .) -}}
{{- end -}}

{{- define "valkey-ha.haproxyName" -}}
{{- printf "%s-haproxy" (include "valkey-ha.fullname" .) -}}
{{- end -}}

{{- define "valkey-ha.redisInsightName" -}}
{{- printf "%s-insight" (include "valkey-ha.fullname" .) -}}
{{- end -}}

{{- define "valkey-ha.secretName" -}}
{{- default (include "valkey-ha.fullname" .) (default .Values.auth.secretName .Values.auth.existingSecret) -}}
{{- end -}}

{{- define "valkey-ha.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "valkey-ha.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
DNS suffix inside every advertised address: `<namespace>.svc.<clusterDomain>`.
*/}}
{{- define "valkey-ha.dnsSuffix" -}}
{{- printf "%s.svc.%s" (include "valkey-ha.namespace" .) (trimPrefix "." (default "cluster.local" .Values.clusterDomain)) -}}
{{- end -}}

{{/*
Stable per-node Service name. Arguments are the root context and the pod ordinal:

  {{ include "valkey-ha.nodeServiceName" (list $ 0) }}
*/}}
{{- define "valkey-ha.nodeServiceName" -}}
{{- printf "%s-node-%d" (include "valkey-ha.fullname" (first .)) (int (last .)) -}}
{{- end -}}

{{/*
Fully qualified address of one node's Service — the string Sentinel persists and the
entrypoints resolve. Same argument shape as `nodeServiceName`.
*/}}
{{- define "valkey-ha.nodeServiceHost" -}}
{{- printf "%s.%s" (include "valkey-ha.nodeServiceName" .) (include "valkey-ha.dnsSuffix" (first .)) -}}
{{- end -}}

{{/*
Space-separated FQDNs of every node Service, ordinal order — NODE_SERVICE_HOSTS in both
entrypoints. Space- (not comma-) separated because the shell scripts iterate it with
plain `for`; generated here rather than derived at runtime so HAProxy's server list,
Sentinel's monitor target and the discovery scans all agree on one spelling of
membership.
*/}}
{{- define "valkey-ha.nodeServiceHosts" -}}
{{- $root := . -}}
{{- $hosts := list -}}
{{- range $i := until (int .Values.replicas) -}}
{{- $hosts = append $hosts (include "valkey-ha.nodeServiceHost" (list $root $i)) -}}
{{- end -}}
{{- join " " $hosts -}}
{{- end -}}

{{/*
FQDN of the Service that fronts the bootstrap master ordinal. The fallback monitor
target when neither the cluster nor any Sentinel can name a live master.
*/}}
{{- define "valkey-ha.primaryNodeServiceHost" -}}
{{- include "valkey-ha.nodeServiceHost" (list . .Values.bootstrap.primaryOrdinal) -}}
{{- end -}}

{{/*
`valkey.config` as `--key value` CLI pairs appended to the valkey-server command —
the compose command line's style of passing settings. Values must be single tokens;
the validator refuses anything with whitespace.
*/}}
{{- define "valkey-ha.valkeyExtraArgs" -}}
{{- $args := list -}}
{{- range $key, $value := (default (dict) .Values.valkey.config) -}}
{{- $args = append $args (printf "--%s %v" $key $value) -}}
{{- end -}}
{{- join " " $args -}}
{{- end -}}

{{/*
HAProxy backend server lines, generated from `replicas` — replaces the three hardcoded
`server valkey-N 172.29.0.x` lines from the compose haproxy.cfg. One line per node
Service so role-based tcp-checks keep their 1:1 server<->role mapping.
*/}}
{{- define "valkey-ha.haproxyServers" -}}
{{- $root := . -}}
{{- range $i := until (int .Values.replicas) }}
    server node-{{ $i }} {{ include "valkey-ha.nodeServiceHost" (list $root $i) }}:{{ $root.Values.valkey.port }} check inter {{ $root.Values.haproxy.checkInterval }} fall {{ $root.Values.haproxy.checkFallCount }} rise {{ $root.Values.haproxy.checkRiseCount }}
{{- end -}}
{{- end -}}

{{/*
The haproxy.cfg text: `haproxy.configTemplate` when set, `files/haproxy.cfg.tpl`
otherwise, with @SERVERS@ and the port/maxconn tokens filled from values. The
@VALKEY_PASSWORD@ / @STATS_PASSWORD@ tokens stay literal — the container substitutes
them from its environment at start, so no password is ever stored in a ConfigMap.
*/}}
{{- define "valkey-ha.haproxyConfig" -}}
{{- $custom := trim (toString .Values.haproxy.configTemplate) -}}
{{- if $custom -}}
{{- $tpl := $custom -}}
{{- include "valkey-ha.haproxyConfigFill" (dict "tpl" $tpl "root" .) -}}
{{- else -}}
{{- $tpl := .Files.Get "files/haproxy.cfg.tpl" -}}
{{- include "valkey-ha.haproxyConfigFill" (dict "tpl" $tpl "root" .) -}}
{{- end -}}
{{- end -}}

{{- define "valkey-ha.haproxyConfigFill" -}}
{{- $root := .root -}}
{{- .tpl
  | replace "@SERVERS@" (include "valkey-ha.haproxyServers" $root)
  | replace "@MASTER_PORT@" (toString $root.Values.haproxy.masterPort)
  | replace "@REPLICA_PORT@" (toString $root.Values.haproxy.replicaPort)
  | replace "@STATS_PORT@" (toString $root.Values.haproxy.statsPort)
  | replace "@STATS_USER@" (toString $root.Values.haproxy.statsUser)
  | replace "@MAXCONN@" (toString $root.Values.haproxy.maxConnections)
|}}
{{- end -}}

{{/*
Fails the render on values that would otherwise produce a cluster that quietly does the
wrong thing. Called from templates/statefulset.yaml, which is always rendered. The
cases below are the ones that cost data or availability rather than a clean error at
install time: a non-majority quorum promotes two masters on a partition; a password
outside the restricted charset breaks the sed-rendered sentinel.conf or HAProxy's
space-delimited tcp-check AUTH mid-failover, which is the worst moment to learn it; a
PDB of minAvailable == replicas blocks every node drain forever.
*/}}
{{- define "valkey-ha.validate" -}}
{{- $replicas := int .Values.replicas -}}
{{- if lt $replicas 1 -}}
{{- fail (printf "replicas is %d — this chart drives one StatefulSet and needs at least 1" $replicas) -}}
{{- end -}}

{{- $quorum := int .Values.sentinel.quorum -}}
{{- if or (lt $quorum 1) (gt $quorum $replicas) -}}
{{- fail (printf "sentinel.quorum is %d but there are only %d sentinels (one sidecar per data pod) — valid range is 1-%d" $quorum $replicas $replicas) -}}
{{- end -}}
{{- if and (gt $replicas 1) (le (mul $quorum 2) $replicas) -}}
{{- fail (printf "sentinel.quorum (%d) is not a majority of replicas (%d) — on a network partition each half reaches quorum and promotes its own master. With %d nodes use quorum %d" $quorum $replicas $replicas (div (add $replicas 2) 2)) -}}
{{- end -}}

{{- $primary := int .Values.bootstrap.primaryOrdinal -}}
{{- if or (lt $primary 0) (ge $primary $replicas) -}}
{{- fail (printf "bootstrap.primaryOrdinal (%d) must be an existing pod: replicas is %d, so the ordinals are 0-%d" $primary $replicas (sub $replicas 1)) -}}
{{- end -}}

{{- /* ---- ports ---- */ -}}
{{- if .Values.haproxy.enabled -}}
{{- $ports := list (int .Values.haproxy.masterPort) (int .Values.haproxy.replicaPort) (int .Values.haproxy.statsPort) -}}
{{- if ne (len (uniq $ports)) 3 -}}
{{- fail (printf "haproxy masterPort/replicaPort/statsPort (%s) must be distinct — they share one proxy process and one Service" (join "/" $ports)) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._@-]+$" (toString .Values.haproxy.statsUser)) -}}
{{- fail (printf "haproxy.statsUser %q is not usable — haproxy.cfg's `stats auth` accepts letters, digits and . _ @ - only" .Values.haproxy.statsUser) -}}
{{- end -}}
{{- range $name, $np := (default (dict) .Values.haproxy.service.nodePorts) -}}
{{- if and $np (not (and (ge (int $np) 30000) (le (int $np) 32767))) -}}
{{- fail (printf "haproxy.service.nodePorts.%s is %v — outside the default NodePort range 30000-32767 (kube-apiserver --service-node-port-range may differ; leave it empty to let the cluster pick)" $name $np) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ---- secrets ---- */ -}}
{{- if not .Values.auth.existingSecret -}}
{{- range $name, $pw := (dict "auth.valkeyPassword" .Values.auth.valkeyPassword "auth.sentinelPassword" .Values.auth.sentinelPassword "haproxy.statsPassword" .Values.haproxy.statsPassword) -}}
{{- if not $pw -}}
{{- fail (printf "%s is empty — the chart creates its Secret from this value (or set auth.existingSecret to a Secret that carries the password keys)" $name) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._@:-]+$" (toString $pw)) -}}
{{- fail (printf "%s contains characters outside [A-Za-z0-9._@:-] — the value is sed-substituted into sentinel.conf and lands in HAProxy's space-delimited `tcp-check send AUTH ...` line, where spaces and & / \\ break the config at the worst possible moment (failover health checks)" $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ---- valkey.config tokens must survive `--key value` word splitting ---- */ -}}
{{- range $key, $value := (default (dict) .Values.valkey.config) -}}
{{- if or (contains " " (toString $value)) (contains " " $key) -}}
{{- fail (printf "valkey.config.%s is %q — values are appended to the CLI as separate `--key value` tokens, so a space would split it into a bogus extra argument. Use the dash form (e.g. allkeys-lru), or move the setting into valkey.configTemplate-style extra args" $key $value) -}}
{{- end -}}
{{- end -}}

{{- /* ---- PDB must leave something to evict ---- */ -}}
{{- $vPdb := .Values.podDisruptionBudget.valkey -}}
{{- if and $vPdb.enabled (hasKey $vPdb "minAvailable") (ge (int $vPdb.minAvailable) $replicas) -}}
{{- fail (printf "podDisruptionBudget.valkey.minAvailable (%v) >= replicas (%d) — every node drain and every `kubectl delete pod` would block forever, because the PDB would never allow a single voluntary eviction" $vPdb.minAvailable $replicas) -}}
{{- end -}}
{{- if and .Values.haproxy.enabled .Values.podDisruptionBudget.haproxy.enabled (ge (int .Values.podDisruptionBudget.haproxy.minAvailable) (int .Values.haproxy.replicas)) -}}
{{- fail (printf "podDisruptionBudget.haproxy.minAvailable (%v) >= haproxy.replicas (%d) — drains would block forever. With one proxy replica, set podDisruptionBudget.haproxy.enabled=false" .Values.podDisruptionBudget.haproxy.minAvailable .Values.haproxy.replicas) -}}
{{- end -}}

{{- /* ---- the haproxy template must actually carry the tokens we fill ---- */ -}}
{{- if .Values.haproxy.enabled -}}
{{- $tpl := default "" (trim (toString .Values.haproxy.configTemplate)) -}}
{{- if $tpl -}}
{{- range $token := (list "@SERVERS@" "@VALKEY_PASSWORD@" "@STATS_PASSWORD@") -}}
{{- if not (contains $token $tpl) -}}
{{- fail (printf "haproxy.configTemplate has no %s token — the chart cannot inject the backend server list or the runtime secrets into it. Keep the tokens from files/haproxy.cfg.tpl or leave haproxy.configTemplate empty" $token) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
