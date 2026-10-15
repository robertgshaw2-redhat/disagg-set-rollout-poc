# Results -- kermit / robshaw-dev, 2026-09-18

vLLM `0.29.1rc1.dev347+gdee37d891` (nightly `sha256:dea7fa04...`, `nixl_cu13`), routing sidecar
v0.10.0, EPP `main@sha256:790c4f7d...`, LWS v0.10.0. DeepSeek-V2-Lite, DP=2/TP=1/EP per pod,
H200, `rdma/ib: 1`.

One end-to-end run of the seven steps with `./demo.sh`, traffic running throughout, plus a
control experiment with the screener removed.

## The seven steps

**16,718 requests, 0 bad, 1,664 canaries all correct, largest gap between completions 1.19s.**

```
phase                     secs      n  bad    p50    p99  revision share
2-v0-2p2d                  152   2417    0   2.17   2.63  v0=2417 (100%)
3-v1-loading               156   2537    0   2.17   2.27  v0=2522 (99%)  v1=15 (1%)
4-v0-2p2d+v1-1p1d          158   2684    0   2.08   2.21  v0=1748 (65%)  v1=936 (35%)
5-v0-draining-to-1          48    774    0   2.20   2.35  v0=385 (50%)   v1=389 (50%)
5-v0-1p1d+v1-1p1d           61    970    0   2.20   2.37  v0=492 (51%)   v1=478 (49%)
6-v1-scaling-to-2           99   1592    0   2.19   2.59  v0=728 (46%)   v1=864 (54%)
6-v0-1p1d+v1-2p2d          158   2664    0   2.08   2.25  v0=924 (35%)   v1=1740 (65%)
7-v0-draining-to-0          38    618    0   2.17   2.25  v0=14 (2%)     v1=604 (98%)
7-v1-2p2d-only             148   2430    0   2.17   2.25  v1=2430 (100%)
```

- **Shares follow the fleet.** 2P2D vs 1P1D gives 65/35 (`max-role` says 67/33); 1:1 gives
  50/50; 1P1D vs 2P2D gives 35/65. The screener's own gauge
  (`llm_d_epp_disaggregatedset_revision_gating_share`) reads 0.667 / 0.333 in step 4.
- **No gate needed while v1 loads.** During `3-v1-loading` v1 got nothing until both its
  prefill and its decode were Ready (the 15 requests are the tail of the phase, after that).
  Before v0's decode was Ready the EPP answered `503 ... screeners eliminated all endpoint
  candidates` -- it fails closed rather than pairing across or sending to a half-up revision.
- **Drains are clean.** Both scale-downs (2->1, 1->0) landed on pods that were serving their
  share of 32 in-flight ~2s requests; none failed, none came back short. A drain takes
  32-42s wall clock: 20s preStop, then vLLM exits once its in-flight requests are done.
- **Pairing: 0 cross-revision pairs** in every `pairing.py` snapshot, e.g. before v0 was
  retired: 10,315 prefill->decode pairs, 0 crossed.
- **DP-aware on both sides.** Per-rank `vllm:request_success_total` is even within every pod
  (e.g. decode-0 `rank0=2490 rank1=2524`, prefill-0 `rank0=2510 rank1=2497`), and
  `pairing.py` shows each decode pulling from both ranks (`:8000`, `:8001`) of each prefill.

```
dsv2-v0-...-decode-0  [v0 rev=176f6821]  691 requests
    <- dsv2-v0-...-prefill-0:8000  [v0 rev=176f6821]   166
    <- dsv2-v0-...-prefill-0:8001  [v0 rev=176f6821]   181
    <- dsv2-v0-...-prefill-1:8000  [v0 rev=176f6821]   165
    <- dsv2-v0-...-prefill-1:8001  [v0 rev=176f6821]   179
dsv2-v1-...-decode-0  [v1 rev=0bed69d3]  686 requests
    <- dsv2-v1-...-prefill-0:8000  [v1 rev=0bed69d3]   346
    <- dsv2-v1-...-prefill-0:8001  [v1 rev=0bed69d3]   340
```

## Control -- the same EPP without the screener

A second EPP release (`control.values.yaml`), same pods, 2P2D v0 + 1P1D v1, 245 requests:
**150 of 245 pairs (61%) crossed revisions** (`./pairing.py --control`). All 245 still
returned 200 with correct canaries, because v0 and v1 here are KV-compatible -- which is the
point: nothing but the screener stops it, and nothing would tell you it was happening.

## Smaller observations

- A freshly started decode answers its first requests a little slowly
  (p99 2.59s in `6-v1-scaling-to-2` vs 2.25s steady): NIXL handshakes happen lazily on the
  first pull from each prefill rank.
- `max-role` ties (equal P and D totals) are broken by the first entry of `requiredRoles`;
  irrelevant at symmetric xPyD ratios like these.
