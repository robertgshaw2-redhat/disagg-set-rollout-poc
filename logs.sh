#!/usr/bin/env bash
# Stream every model-server container's log to results/logs/ for the whole run.
#
#   ./logs.sh start     follow all current AND future pods (background)
#   ./logs.sh stop
#
# A rollout deletes pods on purpose, and LWS (RecreateGroupOnPodRestart) replaces
# a pod whose container crashed -- either way `kubectl logs` has nothing left to
# show afterwards. Files are keyed by pod name AND uid, so a recreated pod does
# not overwrite its predecessor.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${RESULTS:-$HERE/results}/logs"
PIDFILE="$OUT/.pid"
mkdir -p "$OUT"

case "${1:-}" in
start)
  "$0" stop >/dev/null 2>&1 || true
  (
    trap 'kill 0' TERM INT
    while :; do
      kubectl -n "$NS" get pods -l llm-d.ai/guide=dsv2-rollout \
        -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.metadata.labels.llm-d\.ai/role}{"\n"}{end}' 2>/dev/null |
      while read -r pod uid role; do
        containers=vllm; [[ $role == decode ]] && containers="vllm routing-proxy"
        for c in $containers; do
          f="$OUT/$pod.${uid:0:8}.$c.log"
          [[ -e $f.following ]] && continue
          # One follow per (pod uid, container). If the container had not started
          # yet kubectl exits at once with nothing written: retry on the next pass.
          ( touch "$f.following"
            kubectl -n "$NS" logs -f "$pod" -c "$c" >> "$f" 2>/dev/null || true
            [[ -s $f ]] || rm -f "$f.following" ) &
        done
      done
      sleep 5
    done
  ) >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  echo "following logs into $OUT (pid $(cat "$PIDFILE"))"
  ;;
stop)
  if [[ -f $PIDFILE ]]; then
    pkill -TERM -P "$(cat "$PIDFILE")" 2>/dev/null || true
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE" "$OUT"/*.following
    echo "stopped"
  fi
  ;;
*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 1 ;;
esac
