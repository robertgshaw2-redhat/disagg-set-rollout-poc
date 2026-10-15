#!/usr/bin/env bash
# Continuous in-cluster traffic, so the rollout is judged on requests rather than
# on what the objects say.
#
#   ./probe.sh start           launch the probe pod (loadgen.py, closed loop)
#   ./probe.sh mark <label>    stamp a phase boundary (on the pod's clock)
#   ./probe.sh flush           copy the capture into results/
#   ./probe.sh tail            follow the 10s summaries
#   ./probe.sh stop            flush, then delete the probe pod
#
# Tunables (env, read at start): WORKERS=32 MAX_TOKENS=400 PROMPT_WORDS=300
# POD, URL and RESULTS can be overridden to run a second, independent probe.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kermit.yaml}"
NS="${NS:-robshaw-dev}"
POD="${POD:-dsv2-probe}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$HERE/results}"
mkdir -p "$RESULTS"

k() { kubectl -n "$NS" "$@"; }

case "${1:-}" in

start)
  k delete pod "$POD" --ignore-not-found --wait=true >/dev/null
  k create configmap "$POD" --from-file=loadgen.py="$HERE/loadgen.py" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  cat <<YAML | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels: {app: $POD}
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: python:3.12-slim
      command: [python3, -u, /app/loadgen.py]
      env:
        - {name: URL, value: "${URL:-http://dsv2-epp:80}"}
        - {name: WORKERS, value: "${WORKERS:-32}"}
        - {name: MAX_TOKENS, value: "${MAX_TOKENS:-400}"}
        - {name: PROMPT_WORDS, value: "${PROMPT_WORDS:-300}"}
      resources:
        requests: {cpu: "1", memory: 512Mi}
        limits: {cpu: "4", memory: 1Gi}
      volumeMounts:
        - {name: app, mountPath: /app}
        - {name: results, mountPath: /results}
  volumes:
    - name: app
      configMap: {name: $POD}
    - name: results
      emptyDir: {}
YAML
  k wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
  rm -f "$RESULTS/requests.jsonl" "$RESULTS/timeline.tsv"
  "$0" mark probe-start
  ;;

mark)
  label=${2:?usage: probe.sh mark <label>}
  # Stamped inside the pod: same clock as the request log.
  k exec "$POD" -- python3 -c "
import time
line = f'{time.time():.3f}\t$label\n'
open('/results/timeline.tsv', 'a').write(line)
print(line, end='')"
  ;;

flush)
  # The capture lives in the pod's emptyDir, not its log stream, so nothing
  # rotates away -- but it dies with the pod. Flush before stop.
  k exec "$POD" -- cat /results/requests.jsonl > "$RESULTS/requests.jsonl.tmp"
  mv "$RESULTS/requests.jsonl.tmp" "$RESULTS/requests.jsonl"
  k exec "$POD" -- cat /results/timeline.tsv > "$RESULTS/timeline.tsv"
  echo "$(wc -l < "$RESULTS/requests.jsonl" | tr -d ' ') requests captured"
  ;;

tail)
  k logs -f "$POD" --tail=5
  ;;

stop)
  "$0" flush || true
  k delete pod "$POD" --ignore-not-found >/dev/null
  k delete configmap "$POD" --ignore-not-found >/dev/null
  echo "probe stopped"
  ;;

*)
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit 1
  ;;
esac
