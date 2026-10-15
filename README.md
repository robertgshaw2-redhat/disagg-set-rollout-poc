# Manual zero-downtime rollout of llm-d P/D, with DisaggregatedSet

A worked example of replacing one version of a prefill/decode-disaggregated stack with
another, by hand, one step at a time, under live traffic:

| step | | fleet |
|---|---|---|
| 1 | deploy EPP v0 + **p0/d0** | v0 2P+2D |
| 2 | run traffic | |
| 3 | admit **p1/d1** | v0 2P+2D, v1 1P+1D |
| 4 | run traffic; confirm p0 pairs only with d0 and p1 only with d1 | |
| 5 | scale p0/d0 to 1, draining | v0 1P+1D, v1 1P+1D |
| 6 | scale p1/d1 to 2; confirm traffic | v0 1P+1D, v1 2P+2D |
| 7 | remove p0/d0, draining | v1 2P+2D |

Model is `deepseek-ai/DeepSeek-V2-Lite`. Every replica is one pod with 2 GPUs running
**DP=2 / TP=1 + expert parallel** over the `allgather_reducescatter` all2all, so the router
has to be DP-aware: it schedules over (pod, rank), not over pods. Runs on `kermit` in
`robshaw-dev`; peak footprint is 6 pods = 12 H200.

Results of the live run are in [RESULTS.md](RESULTS.md). Short version: 16,718 requests, none
failed, and the screener kept every P/D pair inside one revision.

## The mechanism

**Two DisaggregatedSet objects, one per version.** A single DisaggregatedSet rolls a template
change out by itself (and rejects `partition`, so it cannot be paused between steps). To
drive the rollout by hand, each version is its own object -- `dsv2-v0`, `dsv2-v1`, stamped
from one base by the `manifests/v0` and `manifests/v1` overlays -- and a "step" is a patch of
one object's replica counts. Nothing ever changes a live object's pod template, so the
controller never starts a rollout of its own.

What you still get from DisaggregatedSet is the part that matters to the router: prefill and
decode of one version are one unit, and every pod of that unit carries the same
`disaggregatedset.x-k8s.io/revision` label (here `v0` and `v1` hash to two different
revisions because their templates differ).

**One InferencePool, one EPP, and the rollout screener.** The pool selects every pod of every
version (`llm-d.ai/guide: dsv2-rollout`). Left alone, the EPP would run its prefill profile
and its decode profile over that whole pool independently and happily pair p0 with d1. The
`disaggregatedset-rollout-screener` plugin (llm-d-router, Alpha) runs once per request,
*before* both profiles: it picks one revision, weighted by Ready pods, and hides every other
revision's endpoints from both profiles. It also refuses to offer a revision that does not
have a Ready pod of every required role, which is why admitting v1 needs no traffic gate
while it loads. The chosen revision comes back in the `x-llm-d-disagg-revision` response
header.

```yaml
- type: disaggregatedset-rollout-screener
  parameters:
    scope:
      labelSelector: "llm-d.ai/guide=dsv2-rollout"   # spans BOTH objects
    revisionGating:
      mode: max-role
      requiredRoles: [prefill, decode]
```

The upstream guides scope the screener with `disaggregatedset.x-k8s.io/name=<set>`. That
does not work here -- there are two sets -- so the scope is the shared guide label.

**DP awareness.** vLLM runs one API server per DP rank (`--data-parallel-multi-port-external-lb`),
the pool lists one `targetPort` per rank (8000, 8001), and the EPP treats each (pod, port) as
an endpoint. On decode pods the routing-proxy sidecar owns 8000-8001 and forwards rank N to
vLLM on 8200+N. The screener filters on pod labels, so both ranks of a pod always share a
fate.

## Draining

A scale-down is `replicas: n -> n-1` on both roles of one object; LWS deletes the
highest-index group of each. What happens to a deleted pod:

1. It gets a deletionTimestamp. The EPP drops it from its datastore on that event, and the
   screener recomputes the revision shares. No new request is scheduled to it.
2. `preStop: sleep 20`. vLLM is still fully up. This covers requests the EPP had already
   scheduled, and -- for a prefill pod -- gives decodes time to pull the KV of prefills that
   just finished. vLLM cannot yet hold a prefill open until its blocks are fetched
   (see llm-d `docs/operations/disaggregation/vllm.md`), so this sleep is the mitigation.
3. SIGTERM. `--shutdown-timeout 90` makes vLLM finish in-flight requests instead of aborting
   them.
4. The routing-proxy is a native sidecar, so it is only stopped after the vllm container has
   exited: draining decode requests keep their proxy.
5. `terminationGracePeriodSeconds: 150` > 20 + 90.

`kv_load_failure_policy` is deliberately `fail`, not `recompute`: a drain that loses KV shows
up as a 500 in the probe instead of being papered over.

## Running it

Prerequisites: `kubectl`, `helm`, `jq`, `python3` locally; on the cluster, LWS v0.10+ with the
DisaggregatedSet CRD, a `llm-d-hf-token` secret (key `HF_TOKEN`) in the namespace, and 12 free
GPUs with `rdma/ib` (6 pods x 2) at the peak of steps 3-6. Everything defaults to `kermit` /
`robshaw-dev`; override with `KUBECONFIG=` and `NS=`.

```console
$ export KUBECONFIG=~/.kube/kermit.yaml
$ cd rollouts-disagg-set
```

### The whole thing in one go

```console
$ ./demo.sh                                  # all seven steps, ~25 min, traffic throughout
$ ./probe.sh stop && ./logs.sh stop && ./rollout.sh clean
```

`HOLD=60 ./demo.sh` shortens the traffic windows between steps (default 150s). The verdict
is printed at the end and saved to `results/report.txt`.

### Step by step

`demo.sh` is nothing but these commands in this order. Each `rollout.sh` step blocks until the
fleet has settled (new pods Ready, old pods drained and gone).

```console
# 1. EPP v0 + p0/d0 (2 prefill, 2 decode). ~4 min with the weights on the node, longer cold.
$ ./rollout.sh deploy
$ ./logs.sh start                            # follow every current and future pod into results/logs/
$ ./probe.sh start                           # 32 closed-loop workers -> http://dsv2-epp:80

# 2. traffic on v0
$ ./probe.sh mark 2-v0-2p2d
$ ./probe.sh tail                            # 10s summaries: total / bad / per-revision; ctrl-c to leave

# 3. admit p1/d1 (1 prefill, 1 decode) next to v0. ~2.5 min.
$ ./probe.sh mark 3-v1-loading
$ ./rollout.sh canary

# 4. traffic on both. Expect ~67% v0 / 33% v1, even per-rank counts, 0 crossed pairs.
$ ./probe.sh mark 4-v0-2p2d+v1-1p1d
$ ./rollout.sh status
$ ./pairing.py --label 4-canary

# 5. p0/d0 -> 1 replica each, draining. ~40s.
$ ./probe.sh mark 5-v0-draining-to-1
$ ./rollout.sh scale v0 1
$ ./probe.sh mark 5-v0-1p1d+v1-1p1d

# 6. p1/d1 -> 2 replicas each. ~1.5 min. Expect ~33% v0 / 67% v1 afterwards.
$ ./probe.sh mark 6-v1-scaling-to-2
$ ./rollout.sh scale v1 2
$ ./probe.sh mark 6-v0-1p1d+v1-2p2d
$ ./rollout.sh status
$ ./pairing.py --label 6-v1-majority

# 7. remove p0/d0, draining: scale to 0, wait, delete the object. ~35s.
$ ./probe.sh mark 7-v0-draining-to-0
$ ./rollout.sh retire v0
$ ./probe.sh mark 7-v1-2p2d-only
$ ./pairing.py --label 7-final

# verdict: per-phase request counts, failures, latency, revision share. Exits 1 on any bad request.
$ ./probe.sh flush && ./report.py

# teardown
$ ./probe.sh stop && ./logs.sh stop && ./rollout.sh clean
```

One request by hand, to see the revision the screener pinned it to:

```console
$ kubectl -n robshaw-dev port-forward svc/dsv2-epp 8000:80 &
$ curl -si localhost:8000/v1/completions -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-ai/DeepSeek-V2-Lite","prompt":"The capital of France is","max_tokens":8}' \
    | grep -i -e '^HTTP' -e x-llm-d-disagg-revision
```

### What `rollout.sh` runs underneath

```console
# deploy
$ helm upgrade --install dsv2 oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
    --version v0.10.0 -n robshaw-dev -f router.values.yaml
$ kubectl apply -k manifests/v0

# canary
$ kubectl apply -k manifests/v1

# scale v0 1   (both roles of ONE object; roles/0 is prefill, roles/1 is decode)
$ kubectl -n robshaw-dev patch disaggregatedset dsv2-v0 --type=json -p '[
    {"op":"replace","path":"/spec/roles/0/spec/replicas","value":1},
    {"op":"replace","path":"/spec/roles/1/spec/replicas","value":1}]'

# retire v0    (after scaling to 0 and waiting for the pods to go)
$ kubectl -n robshaw-dev delete disaggregatedset dsv2-v0

# clean
$ kubectl -n robshaw-dev delete disaggregatedset dsv2-v0 dsv2-v1 --ignore-not-found
$ helm uninstall dsv2 -n robshaw-dev
```

Do not re-`apply -k` an overlay mid-rollout: it resets that version's replica counts to its
admission shape (v0 2+2, v1 1+1).

### The control experiment (optional, not during a rollout you care about)

Needs both versions up (the state after step 4), otherwise there is nothing to cross.

```console
$ helm upgrade --install dsv2-noscreen oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
    --version v0.10.0 -n robshaw-dev -f router.values.yaml -f control.values.yaml
$ ./probe.sh mark control-start
$ POD=dsv2-control URL=http://dsv2-noscreen-epp:80 WORKERS=8 RESULTS=$PWD/results/control ./probe.sh start
$ sleep 60
$ POD=dsv2-control RESULTS=$PWD/results/control ./probe.sh stop
$ ./probe.sh mark control-end
$ ./pairing.py --control                     # pairs made inside the control window
$ helm uninstall dsv2-noscreen -n robshaw-dev
```

## How the claims are checked

**Zero downtime** -- `loadgen.py` keeps 32 requests in flight at all times, so every
scale-down lands on pods with work mid-generation. Each request is ~330 prompt tokens that
miss the prefix cache (a real prefill and a real KV transfer) and exactly 400 output tokens.
One in ten is a fixed greedy "capital of France" canary whose *answer* is checked: a
corrupted KV transfer returns 200 with garbage, and only the canary notices. `report.py`
counts anything that is not a correct answer as bad, per phase.

**Pairing** -- the response header only tells you the decode side's revision. The ground
truth is the decode pod's routing-proxy, which at log level 4 prints the prefill `ip:port`
the EPP chose for each request. `pairing.py` joins those against the pods and prints, per
decode pod, how many requests pulled KV from which prefill pod *and rank*, and exits 1 on
any cross-revision pair. `rollout.sh scale` snapshots it before every scale-down, because
deleted pods take their logs with them.

**DP awareness** -- `rollout.sh status` reads `vllm:request_success_total` off every rank's
own metrics port; `pairing.py` shows the prefill side per rank.

**That the screener is what does it** -- `control.values.yaml` is the same EPP without the
screener, installed as a second release over the same pods (see the header of that file). See
RESULTS.md: 61% of its pairs crossed revisions. Do **not** run it in the middle of a rollout
you care about: it makes KV-transfer peers out of pods of different versions, which ties the
two versions' pod lifecycles together.

## Files

| | |
|---|---|
| `manifests/base/disaggregatedset.yaml` | one version of the stack: prefill + decode roles, DP=2, drain settings |
| `manifests/v0`, `manifests/v1` | overlays: name suffix, admission replica counts, the version's knobs (`--max-num-seqs` 64 vs 128) |
| `router.values.yaml` | EPP v0: `llm-d-router-standalone` chart values with the rollout screener |
| `control.values.yaml` | control experiment: same EPP, no screener |
| `rollout.sh` | `deploy` / `canary` / `scale` / `retire` / `status` / `clean` |
| `probe.sh`, `loadgen.py` | in-cluster closed-loop traffic, phase marks, capture |
| `pairing.py` | prefill->decode pairing from the sidecar logs |
| `report.py` | per-phase verdict from the capture |
| `logs.sh` | follow all current and future pods into `results/logs/` |
| `demo.sh` | the seven steps, in order |
| `results/` | where the probe capture, pairing snapshots, logs and report of a run land (not checked in) |

## Things that bit

- The router chart names its Envoy ConfigMap plain `envoy`, so a second release in a
  namespace fails to install (`robshaw-dev` already has `glm`). `router.values.yaml` renames
  it via `router.proxy.configMap.name` + `router.proxy.volumes`.
- The screener is Alpha: the EPP needs `--allow-experimental-plugins=true`.
- The vLLM image is pinned by digest. `nightly` + `IfNotPresent` gives each node whatever
  nightly it happened to cache, and NIXL's compatibility hash includes the vLLM version --
  two nodes on two nightlies cannot transfer KV to each other.
- LWS `RecreateGroupOnPodRestart` replaces a crashed pod with a new pod object, so the
  crashed container's log is gone by the time you look. Hence `logs.sh`.
