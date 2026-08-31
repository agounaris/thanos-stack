{{/*
Size profiles. Each is deep-merged over the component defaults in values.yaml,
then .Values.overrides is deep-merged on top of that.
Resolve the effective config anywhere with:  include "thanos-stack.cfg" .
*/}}
{{- define "thanos-stack.profiles" -}}
custom: {}

small:
  receive:
    router:
      replicas: 2
      resources:
        requests: { cpu: "250m", memory: 512Mi }
        limits: { memory: 512Mi }
    replicas: 2
    replicationFactor: 2
    persistence: { size: 20Gi }
    resources:
      requests: { cpu: "500m", memory: 2Gi }
      limits: { memory: 2Gi }
  storeGateway:
    timeShards:
      - { name: all, minTime: "", maxTime: "" }
    persistence: { size: 10Gi }
    resources:
      requests: { cpu: "250m", memory: 2Gi }
      limits: { memory: 2Gi }
  compactor:
    persistence: { size: 50Gi }
    concurrency: 1
    resources:
      requests: { cpu: "500m", memory: 4Gi }
      limits: { memory: 4Gi }
  query:
    replicas: 2
    resources:
      requests: { cpu: "500m", memory: 1Gi }
      limits: { memory: 1Gi }
  queryFrontend:
    replicas: 1
    cache: { type: inmemory, inmemory: { maxSize: 256MB } }
    resources:
      requests: { cpu: "100m", memory: 256Mi }
      limits: { memory: 256Mi }
  ruler:
    replicas: 1
    persistence: { size: 10Gi }
    resources:
      requests: { cpu: "250m", memory: 2Gi }
      limits: { memory: 2Gi }

medium:
  receive:
    router:
      replicas: 2
      resources:
        requests: { cpu: "500m", memory: 1Gi }
        limits: { memory: 1Gi }
    replicas: 3
    replicationFactor: 3
    persistence: { size: 50Gi }
    resources:
      requests: { cpu: "1", memory: 4Gi }
      limits: { memory: 4Gi }
  storeGateway:
    timeShards:
      - { name: recent, minTime: "-30d", maxTime: "" }
      - { name: historical, minTime: "", maxTime: "-29d" }
    persistence: { size: 20Gi }
    resources:
      requests: { cpu: "500m", memory: 4Gi }
      limits: { memory: 4Gi }
  compactor:
    persistence: { size: 100Gi }
    concurrency: 1
    resources:
      requests: { cpu: "1", memory: 8Gi }
      limits: { memory: 8Gi }
  query:
    replicas: 3
    resources:
      requests: { cpu: "1", memory: 2Gi }
      limits: { memory: 2Gi }
  queryFrontend:
    replicas: 2
    cache: { type: inmemory, inmemory: { maxSize: 512MB } }
    resources:
      requests: { cpu: "250m", memory: 512Mi }
      limits: { memory: 512Mi }
  ruler:
    replicas: 2
    persistence: { size: 20Gi }
    resources:
      requests: { cpu: "500m", memory: 4Gi }
      limits: { memory: 4Gi }

large:
  receive:
    router:
      replicas: 3
      resources:
        requests: { cpu: "1", memory: 1Gi }
        limits: { memory: 1Gi }
    replicas: 4
    replicationFactor: 3
    persistence: { size: 100Gi }
    resources:
      requests: { cpu: "2", memory: 8Gi }
      limits: { memory: 8Gi }
  storeGateway:
    timeShards:
      - { name: recent, minTime: "-14d", maxTime: "" }
      - { name: mid, minTime: "-90d", maxTime: "-13d" }
      - { name: deep, minTime: "", maxTime: "-89d" }
    replicasPerShard: 2
    persistence: { size: 50Gi }
    resources:
      requests: { cpu: "1", memory: 8Gi }
      limits: { memory: 8Gi }
  compactor:
    persistence: { size: 200Gi }
    concurrency: 2
    resources:
      requests: { cpu: "2", memory: 16Gi }
      limits: { memory: 16Gi }
  query:
    replicas: 4
    resources:
      requests: { cpu: "2", memory: 3Gi }
      limits: { memory: 3Gi }
  queryFrontend:
    replicas: 2
    cache: { type: inmemory, inmemory: { maxSize: 1GB } }
    resources:
      requests: { cpu: "500m", memory: 1Gi }
      limits: { memory: 1Gi }
  ruler:
    replicas: 2
    persistence: { size: 50Gi }
    resources:
      requests: { cpu: "1", memory: 8Gi }
      limits: { memory: 8Gi }

xl:
  receive:
    replicas: 6
    replicationFactor: 3
    persistence: { size: 150Gi }
    resources:
      requests: { cpu: "3", memory: 12Gi }
      limits: { memory: 12Gi }
    router:
      replicas: 3
      resources:
        requests: { cpu: "1", memory: 1Gi }
        limits: { memory: 1Gi }
  storeGateway:
    timeShards:
      - { name: recent, minTime: "-14d", maxTime: "" }
      - { name: mid, minTime: "-60d", maxTime: "-13d" }
      - { name: old, minTime: "-180d", maxTime: "-59d" }
      - { name: deep, minTime: "", maxTime: "-179d" }
    replicasPerShard: 2
    persistence: { size: 80Gi }
    resources:
      requests: { cpu: "2", memory: 12Gi }
      limits: { memory: 12Gi }
  compactor:
    persistence: { size: 300Gi }
    concurrency: 4
    resources:
      requests: { cpu: "4", memory: 24Gi }
      limits: { memory: 24Gi }
  query:
    replicas: 6
    resources:
      requests: { cpu: "3", memory: 4Gi }
      limits: { memory: 4Gi }
  queryFrontend:
    replicas: 3
    cache: { type: inmemory, inmemory: { maxSize: 2GB } }
    resources:
      requests: { cpu: "1", memory: 2Gi }
      limits: { memory: 2Gi }
  ruler:
    replicas: 3
    persistence: { size: 80Gi }
    resources:
      requests: { cpu: "2", memory: 8Gi }
      limits: { memory: 8Gi }

xxl:
  receive:
    replicas: 8
    replicationFactor: 3
    persistence: { size: 200Gi }
    resources:
      requests: { cpu: "5", memory: 16Gi }
      limits: { memory: 16Gi }
    router:
      replicas: 4
      resources:
        requests: { cpu: "2", memory: 2Gi }
        limits: { memory: 2Gi }
  storeGateway:
    timeShards:
      - { name: recent, minTime: "-7d", maxTime: "" }
      - { name: mid, minTime: "-30d", maxTime: "-6d" }
      - { name: old, minTime: "-90d", maxTime: "-29d" }
      - { name: older, minTime: "-365d", maxTime: "-89d" }
      - { name: deep, minTime: "", maxTime: "-364d" }
    replicasPerShard: 2
    persistence: { size: 120Gi }
    resources:
      requests: { cpu: "3", memory: 16Gi }
      limits: { memory: 16Gi }
  compactor:
    persistence: { size: 500Gi }
    concurrency: 6
    resources:
      requests: { cpu: "8", memory: 32Gi }
      limits: { memory: 32Gi }
  query:
    replicas: 8
    resources:
      requests: { cpu: "4", memory: 6Gi }
      limits: { memory: 6Gi }
  queryFrontend:
    replicas: 4
    cache: { type: inmemory, inmemory: { maxSize: 4GB } }
    resources:
      requests: { cpu: "2", memory: 4Gi }
      limits: { memory: 4Gi }
  ruler:
    replicas: 3
    persistence: { size: 120Gi }
    resources:
      requests: { cpu: "3", memory: 12Gi }
      limits: { memory: 12Gi }
{{- end -}}


{{/* Effective, fully-merged config: defaults <- size profile <- overrides */}}
{{- define "thanos-stack.cfg" -}}
{{- $all := include "thanos-stack.profiles" . | fromYaml -}}
{{- $size := .Values.size | default "medium" -}}
{{- if not (hasKey $all $size) -}}
{{- fail (printf "thanos-stack: unknown size %q (want small|medium|large|xl|xxl|custom)" $size) -}}
{{- end -}}
{{- $defaults := dict
  "receive" (deepCopy .Values.receive)
  "storeGateway" (deepCopy .Values.storeGateway)
  "compactor" (deepCopy .Values.compactor)
  "query" (deepCopy .Values.query)
  "queryFrontend" (deepCopy .Values.queryFrontend)
  "ruler" (deepCopy .Values.ruler)
-}}
{{- $cfg := mergeOverwrite $defaults (deepCopy (index $all $size)) -}}
{{- $cfg = mergeOverwrite $cfg (deepCopy (.Values.overrides | default dict)) -}}
{{- $cfg | toYaml -}}
{{- end -}}
