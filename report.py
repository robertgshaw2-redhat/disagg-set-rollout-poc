#!/usr/bin/env python3
"""Turn a probe capture into a rollout verdict.

    ./report.py [results-dir]

Reads requests.jsonl (one JSON object per request, see loadgen.py) and
timeline.tsv ("<epoch>\t<label>" per phase boundary). A request is attributed to
the phase it STARTED in, so a request that was in flight across a scale-down
counts against the phase before it -- look at the phase on both sides of a mark.

"bad" is anything that is not a correct answer: a non-200, a transport error, a
load request that came back short, or a canary that came back wrong.
"""
import gzip, json, pathlib, sys
from collections import Counter

results = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                       pathlib.Path(__file__).parent / "results")
raw = results / "requests.jsonl"
if not raw.exists() and not raw.with_suffix(".jsonl.gz").exists():
    sys.exit(f"no capture at {raw} -- run ./probe.sh flush first")
text = raw.read_text() if raw.exists() else gzip.open(raw.with_suffix(".jsonl.gz"), "rt").read()

reqs = []
for line in text.splitlines():
    try:
        reqs.append(json.loads(line))
    except ValueError:
        continue  # torn last line of a live capture
if not reqs:
    sys.exit(f"{raw} has no parseable requests")
reqs.sort(key=lambda r: r["t0"])

marks = []
tl = results / "timeline.tsv"
if tl.exists():
    for line in tl.read_text().splitlines():
        ts, _, label = line.partition("\t")
        if label:
            marks.append((float(ts), label))
marks.sort()

# Revision hash -> v0/v1, from the pods pairing.py has seen.
names = {}
pods = results / "pods.json"
if pods.exists():
    for info in json.loads(pods.read_text()).values():
        if info.get("rev"):
            names[info["rev"]] = info.get("version") or info["rev"]


def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(len(vals) * p))] if vals else 0.0


def shares(rs):
    c = Counter(names.get(r.get("rev", ""), r.get("rev") or "none") for r in rs)
    n = sum(c.values()) or 1
    return "  ".join(f"{k}={v} ({100 * v / n:.0f}%)" for k, v in sorted(c.items()))


t0, t1 = reqs[0]["t0"], reqs[-1]["t0"]
bad = [r for r in reqs if not r.get("ok")]
canary = [r for r in reqs if r["kind"] == "canary"]
durs = [r["dur"] for r in reqs if r.get("ok") and r["kind"] == "load"]
done = sorted(r["t0"] + r["dur"] for r in reqs if r.get("ok"))
gap = max((b - a for a, b in zip(done, done[1:])), default=0.0)

print("REQUESTS")
print(f"  total            {len(reqs)}")
print(f"  correct          {len(reqs) - len(bad)}")
print(f"  bad              {len(bad)}")
print(f"  canaries         {len(canary)}  ({sum(1 for r in canary if not r.get('ok'))} wrong)")
print(f"  window           {t1 - t0:.0f}s  ({len(reqs) / max(t1 - t0, 1):.1f} req/s)")
print(f"  latency p50/p99  {pct(durs, .50):.2f}s / {pct(durs, .99):.2f}s  (load requests)")
print(f"  max gap between completions  {gap:.2f}s")
print(f"  by revision      {shares(reqs)}")

if marks:
    print("\nBY PHASE  (a request belongs to the phase it started in)")
    print(f"  {'phase':<24} {'secs':>5} {'n':>6} {'bad':>4} {'p50':>6} {'p99':>6}  revision share")
    for i, (start, label) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else float("inf")
        ph = [r for r in reqs if start <= r["t0"] < end]
        if not ph:
            continue
        pb = sum(1 for r in ph if not r.get("ok"))
        pd = [r["dur"] for r in ph if r.get("ok") and r["kind"] == "load"]
        print(f"  {label:<24} {min(end, t1) - start:>5.0f} {len(ph):>6} {pb:>4} "
              f"{pct(pd, .50):>6.2f} {pct(pd, .99):>6.2f}  {shares(ph)}"
              f"{'   <-- FAILURES' if pb else ''}")

if bad:
    print("\nBAD REQUESTS")
    codes = Counter((r.get("code"), r["kind"]) for r in bad)
    for (code, kind), n in sorted(codes.items(), key=lambda kv: -kv[1]):
        print(f"  {n:>5}  code={code} kind={kind}")
    print("  first few:")
    for r in bad[:8]:
        phase = next((l for ts, l in reversed(marks) if ts <= r["t0"]), "-")
        print(f"    +{r['t0'] - t0:7.1f}s  [{phase}] code={r.get('code')} rev={names.get(r.get('rev'), r.get('rev'))} "
              f"dur={r['dur']:.2f}s  {r.get('err', '')[:140]}")

sys.exit(1 if bad else 0)
