{{/* ---------------------------------------------------------------------- */}}
{{/* Names                                                                   */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "thanos-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "thanos-stack.fullname" -}}
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

{{- define "thanos-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* component fullname: <release>-<component> */}}
{{- define "thanos-stack.componentName" -}}
{{- printf "%s-%s" (include "thanos-stack.fullname" .ctx) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* Labels                                                                  */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "thanos-stack.labels" -}}
helm.sh/chart: {{ include "thanos-stack.chart" . }}
app.kubernetes.io/name: {{ include "thanos-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: thanos
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* selectorLabels for a component: pass dict "ctx" $ "component" "query" */}}
{{- define "thanos-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "thanos-stack.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* Image / SA                                                              */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "thanos-stack.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{- define "thanos-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "thanos-stack.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* Object storage                                                          */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "thanos-stack.objstoreSecretName" -}}
{{- if .Values.objstore.existingSecret -}}
{{- .Values.objstore.existingSecret -}}
{{- else -}}
{{- printf "%s-objstore" (include "thanos-stack.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "thanos-stack.objstoreSecretKey" -}}
{{- if .Values.objstore.existingSecret -}}
{{- .Values.objstore.existingSecretKey | default "objstore.yml" -}}
{{- else -}}
{{- "objstore.yml" -}}
{{- end -}}
{{- end -}}

{{/* volume + mount snippets for components that talk to the bucket */}}
{{- define "thanos-stack.objstoreVolume" -}}
- name: objstore
  secret:
    secretName: {{ include "thanos-stack.objstoreSecretName" . }}
{{- end -}}

{{- define "thanos-stack.objstoreVolumeMount" -}}
- name: objstore
  mountPath: /etc/thanos/objstore
  readOnly: true
{{- end -}}

{{- define "thanos-stack.objstoreArg" -}}
--objstore.config-file=/etc/thanos/objstore/{{ include "thanos-stack.objstoreSecretKey" . }}
{{- end -}}

{{/* --label flags from .Values.externalLabels */}}
{{- define "thanos-stack.externalLabelArgs" -}}
{{- range $k, $v := .Values.externalLabels }}
- --label={{ $k }}="{{ $v }}"
{{- end }}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* Cross-component discovery (DNS SRV on headless services)                */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "thanos-stack.storeEndpoints" -}}
{{- $ := .ctx -}}
{{- $cfg := include "thanos-stack.cfg" $ | fromYaml -}}
{{- $fn := include "thanos-stack.fullname" $ -}}
{{- $ns := $.Release.Namespace -}}
{{- if $cfg.receive.enabled }}
- --endpoint=dnssrv+_grpc._tcp.{{ $fn }}-receive-headless.{{ $ns }}.svc.cluster.local
{{- end }}
{{- if $cfg.storeGateway.enabled }}
{{- range $cfg.storeGateway.timeShards }}
- --endpoint=dnssrv+_grpc._tcp.{{ $fn }}-storegateway-{{ .name }}-headless.{{ $ns }}.svc.cluster.local
{{- end }}
{{- end }}
{{- if $cfg.ruler.enabled }}
{{- range (include "thanos-stack.rulerShards" $ | fromYamlArray) }}
- --endpoint=dnssrv+_grpc._tcp.{{ $fn }}-ruler-{{ .name }}-headless.{{ $ns }}.svc.cluster.local
{{- end }}
{{- end }}
{{- end -}}

{{/* Normalised ruler shard list: [] -> single "default" shard */}}
{{- define "thanos-stack.rulerShards" -}}
{{- $cfg := include "thanos-stack.cfg" . | fromYaml -}}
{{- $shards := $cfg.ruler.shards | default list -}}
{{- if eq (len $shards) 0 -}}
{{- $shards = list (dict "name" "default" "replicas" ($cfg.ruler.replicas | default 1)) -}}
{{- end -}}
{{- $shards | toYaml -}}
{{- end -}}

{{- define "thanos-stack.podMeta" -}}
{{- with .Values.podAnnotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* ---------------------------------------------------------------------- */}}
{{/* Hardening / scheduling — shared pod-spec fields.                        */}}
{{/* call: include "thanos-stack.podHardening" (dict "ctx" $ "component" "query") */}}
{{/* ---------------------------------------------------------------------- */}}
{{- define "thanos-stack.podHardening" -}}
{{- $ := .ctx -}}
automountServiceAccountToken: {{ .automountServiceAccountToken | default false }}
{{- with $.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with $.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
terminationGracePeriodSeconds: {{ .terminationGracePeriodSeconds | default 60 }}
{{- if $.Values.affinity }}
affinity:
  {{- toYaml $.Values.affinity | nindent 2 }}
{{- else if $.Values.podAntiAffinity.enabled }}
affinity:
  podAntiAffinity:
    {{- if eq $.Values.podAntiAffinity.type "hard" }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: {{ $.Values.podAntiAffinity.topologyKey }}
        labelSelector:
          matchLabels:
            {{- include "thanos-stack.selectorLabels" (dict "ctx" $ "component" .component) | nindent 12 }}
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: {{ $.Values.podAntiAffinity.topologyKey }}
          labelSelector:
            matchLabels:
              {{- include "thanos-stack.selectorLabels" (dict "ctx" $ "component" .component) | nindent 14 }}
    {{- end }}
{{- end }}
{{- with $.Values.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "thanos-stack.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65534
runAsGroup: 65534
fsGroup: 65534
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "thanos-stack.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/* "true" when the receive limits ConfigMap is rendered (explicit or per-tenant). */}}
{{- define "thanos-stack.receiveHasLimits" -}}
{{- $cfg := include "thanos-stack.cfg" . | fromYaml -}}
{{- if $cfg.receive.limitsConfig -}}true
{{- else if and .Values.multiTenancy.enabled .Values.multiTenancy.tenants -}}
{{- range .Values.multiTenancy.tenants }}{{- if .limits }}true{{- end }}{{- end -}}
{{- end -}}
{{- end -}}

{{/* Alloy per-scrape limit args (pass .Values.alloy). Emit only the set ones. */}}
{{- define "thanos-stack.alloyScrapeLimits" -}}
{{- $l := .limits | default dict -}}
{{- if gt (int ($l.labelLimit | default 0)) 0 }}
label_limit              = {{ int $l.labelLimit }}
{{- end }}
{{- if gt (int ($l.labelNameLengthLimit | default 0)) 0 }}
label_name_length_limit  = {{ int $l.labelNameLengthLimit }}
{{- end }}
{{- if gt (int ($l.labelValueLengthLimit | default 0)) 0 }}
label_value_length_limit = {{ int $l.labelValueLengthLimit }}
{{- end }}
{{- if gt (int ($l.sampleLimit | default 0)) 0 }}
sample_limit             = {{ int $l.sampleLimit }}
{{- end }}
{{- end -}}
