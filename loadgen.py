#!/usr/bin/env python3
"""Closed-loop load generator for the rollout probe. Runs inside the probe pod.

N workers each keep exactly one /v1/completions request in flight, so there is
always work mid-generation when a pod is told to go away -- which is the only
way a drain can be judged. Stdlib only: the pod is a bare python image.

One JSON line per request goes to $OUT (default /results/requests.jsonl):

    t0        start, epoch seconds
    dur       seconds to the full response
    code      HTTP status, or 0 for a transport error (then `err` says what)
    rev       x-llm-d-disagg-revision response header -- the revision the
              rollout screener pinned this request to
    kind      "load" (random prompt, ignore_eos, exactly MAX_TOKENS out) or
              "canary" (fixed prompt, greedy; `ok` says the answer was right)
    ntok      completion tokens reported by the server
    id        x-request-id we sent

A canary that comes back wrong is how a corrupted or mismatched KV transfer
would show up: the HTTP status alone cannot tell.
"""
import json, os, random, sys, threading, time, uuid
import http.client
from urllib.parse import urlparse

URL = urlparse(os.environ.get("URL", "http://dsv2-epp:80"))
MODEL = os.environ.get("MODEL", "deepseek-ai/DeepSeek-V2-Lite")
WORKERS = int(os.environ.get("WORKERS", "32"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "400"))
PROMPT_WORDS = int(os.environ.get("PROMPT_WORDS", "300"))
CANARY_EVERY = int(os.environ.get("CANARY_EVERY", "10"))
TIMEOUT = float(os.environ.get("TIMEOUT", "120"))
OUT = os.environ.get("OUT", "/results/requests.jsonl")
REV_HEADER = "x-llm-d-disagg-revision"

CANARY_PROMPT = "Question: What is the capital of France?\nAnswer: The capital of France is"
CANARY_EXPECT = "Paris"

WORDS = ("time year people way day man thing woman life child world school state "
         "family student group country problem hand part place case week company "
         "system program question work government number night point home water "
         "room mother area money story fact month lot right study book eye job "
         "word business issue side kind head house service friend father power "
         "hour game line end member law car city community name").split()

lock = threading.Lock()
out = open(OUT, "a", buffering=1)
stats = {"n": 0, "bad": 0, "revs": {}}


def body_for(kind, rng):
    if kind == "canary":
        return {"model": MODEL, "prompt": CANARY_PROMPT, "max_tokens": 8,
                "temperature": 0}
    # A unique leading token keeps every prompt off the prefix cache, so each
    # request is a real prefill and a real KV transfer.
    prompt = uuid.uuid4().hex + " " + " ".join(rng.choices(WORDS, k=PROMPT_WORDS))
    return {"model": MODEL, "prompt": prompt, "max_tokens": MAX_TOKENS,
            "temperature": 0, "ignore_eos": True}


def worker(i):
    rng = random.Random(i)
    conn = None
    n = 0
    while True:
        n += 1
        kind = "canary" if CANARY_EVERY and n % CANARY_EVERY == 0 else "load"
        rid = f"probe-{i}-{uuid.uuid4().hex[:12]}"
        rec = {"t0": time.time(), "kind": kind, "id": rid}
        t = time.monotonic()
        try:
            if conn is None:
                conn = http.client.HTTPConnection(URL.hostname, URL.port or 80, timeout=TIMEOUT)
            conn.request("POST", "/v1/completions", json.dumps(body_for(kind, rng)),
                         {"Content-Type": "application/json", "x-request-id": rid})
            resp = conn.getresponse()
            data = resp.read()
            rec["code"] = resp.status
            rec["rev"] = resp.getheader(REV_HEADER, "")
            if resp.status == 200:
                j = json.loads(data)
                rec["ntok"] = j.get("usage", {}).get("completion_tokens")
                if kind == "canary":
                    rec["ok"] = CANARY_EXPECT in j["choices"][0]["text"]
                else:
                    rec["ok"] = rec["ntok"] == MAX_TOKENS
            else:
                rec["ok"] = False
                rec["err"] = data[:300].decode("utf-8", "replace")
                # A fail-closed router answers in a millisecond; without a pause
                # 32 workers turn one outage into 100k+ log lines.
                time.sleep(0.2)
            if resp.getheader("connection", "").lower() == "close":
                conn.close()
                conn = None
        except Exception as e:  # transport error: count it, reconnect, carry on
            rec.update(code=0, ok=False, rev="", err=f"{type(e).__name__}: {e}"[:300])
            try:
                conn.close()
            except Exception:
                pass
            conn = None
            time.sleep(0.2)
        rec["dur"] = round(time.monotonic() - t, 4)
        with lock:
            out.write(json.dumps(rec) + "\n")
            stats["n"] += 1
            stats["bad"] += 0 if rec["ok"] else 1
            stats["revs"][rec["rev"]] = stats["revs"].get(rec["rev"], 0) + 1


for i in range(WORKERS):
    threading.Thread(target=worker, args=(i,), daemon=True).start()

print(f"loadgen: {WORKERS} workers -> {URL.geturl()} ({MODEL}), max_tokens={MAX_TOKENS}", flush=True)
while True:
    time.sleep(10)
    with lock:
        snap = dict(stats, revs=dict(stats["revs"]))
        stats["revs"].clear()
    print(f"{time.strftime('%H:%M:%S')} total={snap['n']} bad={snap['bad']} last10s_by_rev={snap['revs']}", flush=True)
