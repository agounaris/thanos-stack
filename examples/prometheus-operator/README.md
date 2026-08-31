# Prometheus Operator alongside thanos-stack

Runs the operator so `ServiceMonitor`, `PodMonitor`, `Probe`, `ScrapeConfig` and
`PrometheusRule` objects (from anywhere in the cluster) drive a Prometheus that
**remote-writes into this stack's Receive**. Verified on Docker Desktop.

## Install

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  -f kube-prometheus-stack-values.yaml

# blackbox exporter, for Probe objects
helm install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring

kubectl apply -f crds-probe-podmonitor-scrapeconfig.yaml
```

Then turn on the chart's own operator objects:

```sh
helm upgrade thanos-stack ../.. -n default -f ../local-docker-desktop.yaml \
  --set serviceMonitor.enabled=true --set prometheusRule.enabled=true
```

## What the values file does

- `*SelectorNilUsesHelmValues: false` + empty `*Selector` + empty
  `*NamespaceSelector` → the Prometheus picks up **all** ServiceMonitors,
  PodMonitors, Probes, ScrapeConfigs and PrometheusRules in **every** namespace.
- `remoteWrite` → `http://thanos-stack-receive.default.svc.cluster.local:19291/api/v1/receive`
  (the router Service). Everything scraped lands in Thanos.
- `additionalScrapeConfigs` → a raw scrape job, rendered by the chart into a
  Secret — the "scrape config" escape hatch for things without a CRD.
- `nodeExporter.enabled: false` — the DaemonSet crashloops on Docker Desktop
  (`path / is mounted on / but it is not a shared or slave mount`); Alloy's
  kubelet/cAdvisor scrape covers node metrics. Enable it on a real cluster.
- Grafana disabled; Alertmanager kept (the Thanos Ruler routes alerts to it —
  see `ruler.alertmanagers` in `../local-docker-desktop.yaml`).

## Verify

```sh
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/targets?state=active | \
  jq -r '.data.activeTargets[].scrapePool' | sort -u
```

Expect pools for `serviceMonitor/default/thanos-stack-*`,
`probe/default/thanos-endpoints`, `scrapeConfig/default/alloy-self`,
`podMonitor/default/minio`, and `additional-static-demo`.

Same data through Thanos (the operator's Prometheus tags everything
`prometheus="monitoring/kps-prometheus"`):

```sh
curl -s -G -H 'Host: thanos.local' http://localhost/api/v1/query \
  --data-urlencode 'query=count by (job) (up{prometheus="monitoring/kps-prometheus"})'
```

## crds-probe-podmonitor-scrapeconfig.yaml

- **Probe** `thanos-endpoints` — blackbox `http_2xx` against the query-frontend,
  query and receive `/-/healthy` endpoints.
- **PodMonitor** `minio` — scrapes the MinIO pods directly (needs
  `MINIO_PROMETHEUS_AUTH_TYPE=public` on the MinIO deployment).
- **ScrapeConfig** `alloy-self` — a static-target scrape job as a CR.
