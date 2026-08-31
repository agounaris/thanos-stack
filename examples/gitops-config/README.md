# GitOps config for the Thanos stack

A repo layout for letting many teams own their own scrape configs, rules and
alert routing, deployed with ArgoCD (or plain `kubectl apply -k`), and
**hot-reloaded** into the running stack without a Helm upgrade.

> Draft for review. Nothing here is wired into the chart's CI yet.

## Layout

```
config/
  <group>/                     # org unit — platform, data, payments, …
    <service>/                 # one deployable service
      recordingrules.yaml      # Prometheus rule groups (record:)
      alertingrules.yaml       # Prometheus rule groups (alert:)
      prometheus.yaml          # scrape_configs for this service
      alertmanager.yaml        # route + receivers for this service only
```

Example tree in [`config/`](config/): `platform/checkout`, `platform/web`,
`data/etl`.

**Ownership rules (enforced in CI, see §6):**

| File | May only set labels | Notes |
|---|---|---|
| `recordingrules.yaml` | — | `record:` rules only; group names globally unique, prefix with the service |
| `alertingrules.yaml` | `team`, `service` must equal the dir | so alerts can be routed back to the owner |
| `prometheus.yaml` | `team=<group>`, `service=<service>` via relabel | `label_limit` etc. required |
| `alertmanager.yaml` | `route.matchers` must include `team=<group>, service=<service>` | a team cannot capture another team's alerts |

## What each file becomes

| Source | Rendered object | Consumed by |
|---|---|---|
| `recordingrules.yaml` + `alertingrules.yaml` | one **ConfigMap** `‹group›-‹service›-rules`, label `thanos-stack.io/rule=true` | Thanos **Ruler** (this chart) |
| `prometheus.yaml` | **ScrapeConfig** CR *or* an entry in `additionalScrapeConfigs` | the operator's **Prometheus** / Alloy |
| `alertmanager.yaml` | **AlertmanagerConfig** CR *or* a fragment merged into the AM config | **Alertmanager** |

Render locally:

```sh
cd examples/gitops-config
RULES_NAMESPACE=default ./render/build.sh config ./out
kubectl apply -k ./out
```

## Deployment models

### A. Chart-native (recommended with this chart)

Rules travel as **labelled ConfigMaps**. Enable dynamic discovery on the ruler:

```yaml
# thanos-stack values
ruler:
  dynamicRules:
    enabled: true
    labelSelector: "thanos-stack.io/rule=true"
    namespaces: "ALL"
```

The ruler pod then runs a `k8s-sidecar` container that watches every ConfigMap
with that label across the cluster and writes them into `/etc/thanos/rules-dynamic/`.
The existing `prometheus-config-reloader` sidecar sees the change and calls
`POST /-/reload`. **Add a folder in git → ArgoCD creates a ConfigMap → rules are
live in ~1 minute, no Helm upgrade.**

Scrape configs go into the operator's Prometheus as `ScrapeConfig` CRs (§B) or
into `additionalScrapeConfigs`. Alert routing goes into Alertmanager as
`AlertmanagerConfig` CRs.

### B. Operator-native (if you run the Prometheus Operator)

Render each file straight to a CRD and skip the sidecar:

| Source | CRD |
|---|---|
| `recordingrules.yaml` / `alertingrules.yaml` | `PrometheusRule` (label it for the `ThanosRuler` `ruleSelector`) |
| `prometheus.yaml` | `ScrapeConfig` |
| `alertmanager.yaml` | `AlertmanagerConfig` |

Here the ruler is the operator's **`ThanosRuler`** CR (set `ruler.enabled=false`
in this chart) with `ruleSelector` matching your label. The operator generates
the config and runs the reloader itself.

Trade-off: the operator lifts the 1 MiB ConfigMap limit (it shards rules across
generated Secrets) and gives you `PrometheusRule` validation for free, at the
cost of a cluster-wide operator. See the chart's `RULES.md` §6.

## Auto-reload — how each config type refreshes

| Config | Mechanism | Latency |
|---|---|---|
| Ruler rule files (model A) | k8s-sidecar writes file → `configmap-reload` → `POST /-/reload` | ≤ ~60 s |
| Ruler rules (model B) | operator regenerates + reloads | seconds |
| Prometheus `ScrapeConfig` / `additionalScrapeConfigs` | operator regenerates config Secret → Prometheus `/-/reload` | seconds |
| `AlertmanagerConfig` | operator regenerates AM config → AM reload | seconds |
| Alloy scrape config (if Alloy is your collector) | ConfigMap change → Alloy's own file watcher | ≤ ~60 s |

No pod restarts in any row.

## ArgoCD

- [`argocd/applicationset.yaml`](argocd/applicationset.yaml) — a git-directory
  generator creates one `Application` per `config/<group>/<service>/`. Adding a
  service folder is a one-line PR.
- [`argocd/app-of-apps.yaml`](argocd/app-of-apps.yaml) — bootstraps the ApplicationSet.
- The `plugin: thanos-stack-config` runs `render/build.sh` for the directory
  (register it as a CMP, or pre-render in CI and point ArgoCD at `./out`).

Set `syncPolicy.automated.prune: true` so deleting a folder deletes its
ConfigMap / CRs — and the ruler drops the rules on the next sidecar sync.

## Validation in CI (recommended, not yet wired)

Run on every PR touching `config/**`:

1. `promtool check rules config/**/{recording,alerting}rules.yaml`
2. `amtool check-config` on the merged Alertmanager config
3. `promtool check config` on the merged scrape config
4. **Ownership lint** (small script): alerting-rule `labels.team/service` match
   the path; AM `route.matchers` are scoped to the owner; rule group names are
   globally unique and service-prefixed.
5. **Cardinality budget**: fail if a `prometheus.yaml` omits `sample_limit` /
   `label_limit`, or sets them above the org ceiling (see `../../PROTECTION.md`).
6. **Size**: fail if a rendered rules ConfigMap would exceed ~900 KiB.
