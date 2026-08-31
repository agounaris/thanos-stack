#!/usr/bin/env bash
# Render config/<group>/<team-or-service>/<service>/*.yaml into Kubernetes objects
# that the thanos-stack chart + Prometheus Operator consume.
#
#   ./build.sh config ./out
#
# Produces, per service directory that contains rule files:
#   <group>-<service>-rules            ConfigMap  (label thanos-stack.io/rule=true)
#                                       data: recordingrules.yaml, alertingrules.yaml
# Plus, when present:
#   <group>-<service>-scrape           ScrapeConfig      (from prometheus.yaml)
#   <group>-<service>-am               AlertmanagerConfig (from alertmanager.yaml)
#
# Point ArgoCD at ./out, or `kubectl apply -k` it. The Thanos Ruler picks up the
# ConfigMaps automatically when `ruler.dynamicRules.enabled=true`.
set -euo pipefail

SRC="${1:-config}"
OUT="${2:-out}"
NS_RULES="${RULES_NAMESPACE:-default}"        # where the ruler runs
RULE_LABEL="${RULE_LABEL:-thanos-stack.io/rule=true}"

mkdir -p "$OUT"
: > "$OUT/kustomization.yaml"
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n' >> "$OUT/kustomization.yaml"

shopt -s nullglob
for dir in "$SRC"/*/*/ "$SRC"/*/*/*/ ; do
  [ -d "$dir" ] || continue
  # derive group + service from the path tail
  rel="${dir#"$SRC"/}"; rel="${rel%/}"
  group="${rel%%/*}"
  service="${rel##*/}"
  name="${group}-${service}"

  rules=()
  [ -f "${dir}recordingrules.yaml" ] && rules+=("${dir}recordingrules.yaml")
  [ -f "${dir}alertingrules.yaml" ]  && rules+=("${dir}alertingrules.yaml")

  if [ ${#rules[@]} -gt 0 ]; then
    f="$OUT/${name}-rules.configmap.yaml"
    {
      echo "apiVersion: v1"
      echo "kind: ConfigMap"
      echo "metadata:"
      echo "  name: ${name}-rules"
      echo "  namespace: ${NS_RULES}"
      echo "  labels:"
      echo "    ${RULE_LABEL%=*}: \"${RULE_LABEL#*=}\""
      echo "    thanos-stack.io/group: ${group}"
      echo "    thanos-stack.io/service: ${service}"
      echo "data:"
      for r in "${rules[@]}"; do
        echo "  ${name}-$(basename "$r"): |"
        sed 's/^/    /' "$r"
      done
    } > "$f"
    echo "  - $(basename "$f")" >> "$OUT/kustomization.yaml"
    echo "rendered $f"
  fi

  # prometheus.yaml / alertmanager.yaml -> left as an exercise for your operator
  # flavour; see README section 4. Emit them verbatim next to the ConfigMap so a
  # follow-up step can convert them.
  [ -f "${dir}prometheus.yaml" ]   && cp "${dir}prometheus.yaml"   "$OUT/${name}.scrape.src.yaml"
  [ -f "${dir}alertmanager.yaml" ] && cp "${dir}alertmanager.yaml" "$OUT/${name}.am.src.yaml"
done

echo
echo "done -> $OUT/  (apply with: kubectl apply -k $OUT)"
