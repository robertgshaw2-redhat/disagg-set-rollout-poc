#!/usr/bin/env bash
# Manual, step-by-step rollout of a P/D stack held in two DisaggregatedSets.
#
#   ./rollout.sh deploy              EPP + v0 (2 prefill, 2 decode); wait Ready
#   ./rollout.sh canary              admit v1 (1 prefill, 1 decode); wait Ready
#   ./rollout.sh scale <v0|v1> <n>   set BOTH roles of one version to n replicas;
#                                    waits for new pods Ready / old pods drained
#   ./rollout.sh retire <v0|v1>      scale to 0, wait for the drain, delete the object
#   ./rollout.sh status              pods by revision, per-DP-rank request counts,
#                                    the screener's traffic shares
#   ./rollout.sh clean               remove everything
#
# The user's sequence is: deploy, canary, scale v0 1, scale v1 2, retire v0 --
# with ./probe.sh running throughout and ./probe.sh mark <label> between steps.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
RELEASE=dsv2
CHART=oci://ghcr.io/llm-d/charts/llm-d-router-standalone
CHART_VERSION=v0.10.0
GUIDE="llm-d.ai/guide=dsv2-rollout"
DS_NAME=disaggregatedset.x-k8s.io/name
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

k()   { kubectl -n "$NS" "$@"; }
say() { printf '==> %s\n' "$*"; }
now() { date +%s; }

# "<total> <ready> <terminating>" for one version's pods.
counts() {
  k get pods -l "$DS_NAME=dsv2-$1" -o json | jq -r '
    [.items[]] | [length,
      (map(select(.metadata.deletionTimestamp == null
                  and any(.status.conditions[]?; .type == "Ready" and .status == "True"))) | length),
      (map(select(.metadata.deletionTimestamp != null)) | length)] | @tsv'
}

# Block until the version has exactly 2n pods, all Ready, none terminating.
settle() {
  local v=$1 want=$(( $2 * 2 )) t0 total ready term
  t0=$(now)
  while :; do
    read -r total ready term < <(counts "$v")
    if (( total == want && ready == want && term == 0 )); then break; fi
    printf '    %s: %s pods, %s ready, %s draining (want %s ready)  [%ss]\n' \
      "dsv2-$v" "$total" "$ready" "$term" "$want" "$(( $(now) - t0 ))"
    sleep 10
  done
  say "dsv2-$v settled at $2 prefill + $2 decode after $(( $(now) - t0 ))s"
}

case "${1:-}" in

deploy)
  say "EPP v0 (helm release $RELEASE)"
  helm upgrade --install "$RELEASE" "$CHART" --version "$CHART_VERSION" \
    -n "$NS" -f "$HERE/router.values.yaml" >/dev/null
  k rollout status "deploy/$RELEASE-epp" --timeout=300s
  say "v0: 2 prefill + 2 decode"
  k apply -k "$HERE/manifests/v0"
  settle v0 2
  ;;

canary)
  say "admitting v1: 1 prefill + 1 decode, alongside v0"
  k apply -k "$HERE/manifests/v1"
  # No traffic gate is needed while it loads: the screener only offers a
  # revision once it has a Ready pod of EVERY required role.
  settle v1 1
  ;;

scale)
  v=${2:?usage: rollout.sh scale <v0|v1> <n>}; n=${3:?usage: rollout.sh scale <v0|v1> <n>}
  # Pods that are about to go take their sidecar logs with them.
  "$HERE/pairing.py" --label "before-$v-to-$n" >/dev/null || say "WARNING: pairing.py found cross-revision pairs"
  say "dsv2-$v -> $n prefill + $n decode"
  k patch disaggregatedset "dsv2-$v" --type=json -p "[
    {\"op\":\"test\",\"path\":\"/spec/roles/0/name\",\"value\":\"prefill\"},
    {\"op\":\"test\",\"path\":\"/spec/roles/1/name\",\"value\":\"decode\"},
    {\"op\":\"replace\",\"path\":\"/spec/roles/0/spec/replicas\",\"value\":$n},
    {\"op\":\"replace\",\"path\":\"/spec/roles/1/spec/replicas\",\"value\":$n}]"
  sleep 3
  settle "$v" "$n"
  ;;

retire)
  v=${2:?usage: rollout.sh retire <v0|v1>}
  "$0" scale "$v" 0
  say "dsv2-$v is empty -- deleting the object"
  k delete disaggregatedset "dsv2-$v"
  ;;

status)
  say "pods"
  k get pods -l "$GUIDE" -o json | jq -r '
    .items | sort_by(.metadata.labels["rollout.poc/version"], .metadata.labels["llm-d.ai/role"], .metadata.name)[] |
    [.metadata.labels["rollout.poc/version"],
     .metadata.labels["disaggregatedset.x-k8s.io/revision"],
     .metadata.labels["llm-d.ai/role"],
     .metadata.name,
     (if .metadata.deletionTimestamp then "Draining"
      elif any(.status.conditions[]?; .type == "Ready" and .status == "True") then "Ready"
      else "NotReady" end),
     .spec.nodeName] | @tsv' | column -t
  echo
  say "requests finished per DP rank (vllm:request_success_total, since pod start)"
  k get pods -l "$GUIDE" --field-selector=status.phase=Running -o json | jq -r '
    .items | sort_by(.metadata.labels["rollout.poc/version"], .metadata.labels["llm-d.ai/role"], .metadata.name)[] |
    [.metadata.name, .metadata.labels["llm-d.ai/role"], .metadata.labels["rollout.poc/version"]] | @tsv' |
  while IFS=$'\t' read -r pod role ver; do
    base=8000; [[ $role == decode ]] && base=8200
    out=$(k exec "$pod" -c vllm -- python3 -c "
import re, urllib.request
for rank in (0, 1):
    try:
        m = urllib.request.urlopen('http://localhost:%d/metrics' % ($base + rank), timeout=5).read().decode()
        n = sum(float(x) for x in re.findall(r'^vllm:request_success_total\{[^}]*\} (\S+)', m, re.M))
        print('rank%d=%d' % (rank, n), end='  ')
    except Exception as e:
        print('rank%d=?' % rank, end='  ')
" 2>/dev/null || echo "unreachable")
    printf '    %-4s %-8s %-34s %s\n' "$ver" "$role" "$pod" "$out"
  done
  echo
  say "rollout screener traffic share per revision (EPP gauge)"
  k get --raw "/api/v1/namespaces/$NS/services/$RELEASE-epp:9090/proxy/metrics" 2>/dev/null \
    | grep -E '^llm_d_epp_disaggregatedset' | sed 's/^/    /' || echo "    (metrics endpoint not reachable)"
  ;;

clean)
  k delete disaggregatedset dsv2-v0 dsv2-v1 --ignore-not-found
  helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true
  ;;

*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 1
  ;;
esac
