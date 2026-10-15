#!/usr/bin/env python3
"""Prove which prefill each decode actually used.

    ./pairing.py [--since 10m] [--label canary] [--control]

The response header only says which revision the *decode* side was on. The
ground truth for the pair is the decode pod's routing-proxy: at log level 4 it
prints one line per request naming the prefill "ip:port" the EPP chose. Join
that ip against the pods and you get, per decode pod, the revision (and the DP
rank) of every prefill it pulled KV from.

Exit status is 1 if any request crossed revisions.

Requests sent between a `control-start` and a `control-end` timeline mark are
the screener-off control experiment (README "Control"). They are left out by
default; --control reports only them.

Pods come and go during a rollout, and a deleted pod takes its logs and its IP
with it. So: every run remembers the pods it saw in results/pods.json, and
rollout.sh calls this before every scale-down.
"""
import argparse, collections, json, os, pathlib, subprocess, sys

NS = os.environ.get("NS", "robshaw-dev")
SELECTOR = "llm-d.ai/guide=dsv2-rollout"
REV = "disaggregatedset.x-k8s.io/revision"
HERE = pathlib.Path(__file__).parent
RESULTS = pathlib.Path(os.environ.get("RESULTS", HERE / "results"))
os.environ.setdefault("KUBECONFIG", os.path.expanduser("~/.kube/kermit.yaml"))

ap = argparse.ArgumentParser()
ap.add_argument("--since", default="", help="only log lines newer than this (kubectl --since, e.g. 10m)")
ap.add_argument("--label", default="", help="also save the report as results/pairing-<label>.txt")
ap.add_argument("--control", action="store_true", help="report only the control-start..control-end windows")
args = ap.parse_args()


def kubectl(*a):
    return subprocess.run(["kubectl", "-n", NS, *a], capture_output=True, text=True, check=True).stdout


RESULTS.mkdir(exist_ok=True)
seen_path = RESULTS / "pods.json"
seen = json.loads(seen_path.read_text()) if seen_path.exists() else {}
live = []
for p in json.loads(kubectl("get", "pods", "-l", SELECTOR, "-o", "json"))["items"]:
    ip = p["status"].get("podIP")
    if not ip:
        continue
    lab = p["metadata"]["labels"]
    info = {"pod": p["metadata"]["name"], "role": lab.get("llm-d.ai/role"),
            "rev": lab.get(REV), "version": lab.get("rollout.poc/version")}
    seen[ip] = info
    live.append(info)
seen_path.write_text(json.dumps(seen, indent=1))


def control_windows():
    """[(start, end)] from the probe's timeline; the live pod's copy if there is one."""
    try:
        text = kubectl("exec", os.environ.get("POD", "dsv2-probe"), "--", "cat", "/results/timeline.tsv")
    except subprocess.CalledProcessError:
        tl = RESULTS / "timeline.tsv"
        text = tl.read_text() if tl.exists() else ""
    windows, start = [], None
    for line in text.splitlines():
        ts, _, label = line.partition("\t")
        if label == "control-start":
            start = float(ts)
        elif label == "control-end" and start is not None:
            windows.append((start, float(ts)))
            start = None
    if start is not None:
        windows.append((start, float("inf")))
    return windows


WINDOWS = control_windows()


def prefill_targets(log):
    for line in log.splitlines():
        if "sending prefill request" not in line:
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if any(a <= j["ts"] <= b for a, b in WINDOWS) == args.control:
            yield j["to"]


lines = []
cross = total = unknown = 0
for d in sorted((i for i in live if i["role"] == "decode"), key=lambda i: i["pod"]):
    cmd = ["logs", d["pod"], "-c", "routing-proxy"]
    if args.since:
        cmd.append(f"--since={args.since}")
    targets = collections.Counter(prefill_targets(kubectl(*cmd)))
    lines.append(f'{d["pod"]}  [{d["version"]} rev={d["rev"]}]  {sum(targets.values())} requests')
    for hostport, n in sorted(targets.items()):
        ip, _, port = hostport.rpartition(":")
        total += n
        if ip not in seen:  # pod came and went between two runs of this script
            unknown += n
            lines.append(f'    <- {hostport}  [pod no longer known]  {n:>6}')
            continue
        p = seen[ip]
        same = p["rev"] == d["rev"]
        cross += 0 if same else n
        lines.append(f'    <- {p["pod"]}:{port}  [{p["version"]} rev={p["rev"]}]  {n:>6}'
                     f'{"" if same else "   <-- CROSS-REVISION"}')

lines.append("")
lines.append(f"{total} prefill->decode pairs, {cross} crossed revisions"
             + ("" if cross else "  -- every pair stayed inside one revision")
             + (f"  ({unknown} to a prefill IP this script never saw alive)" if unknown else ""))
report = "\n".join(lines)
print(report)
if args.label:
    (RESULTS / f"pairing-{args.label}.txt").write_text(report + "\n")
sys.exit(1 if cross else 0)
