#!/usr/bin/env python3
"""Warm serving-layer load test for an OpenAI-compatible endpoint (vLLM/SIE/...).

Measures TTFT, TPOT, end-to-end latency percentiles and throughput at a given
concurrency. Stdlib only — no pip install needed (urllib + threads). Talks the
streaming Chat Completions API so TTFT is the time to the first token.

Usage:
  python3 loadtest.py --base-url http://localhost:8000/v1 --model Qwen/Qwen3.6-27B \
      --concurrency 4 --requests 16 --max-tokens 128

Point --base-url at a `kubectl port-forward`ed service (see run-matrix.sh).
"""
import argparse
import json
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor

PROMPT = "List three benefits of data-driven decision making, with one sentence each."


def _percentile(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def one_request(base_url, model, max_tokens, api_key):
    """Fire one streaming request. Returns (ttft, e2e, out_tokens, ok, err)."""
    url = base_url.rstrip("/") + "/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "stream": True,
        "temperature": 0,
        "max_tokens": max_tokens,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {api_key}")
    t0 = time.monotonic()
    ttft = None
    out_tokens = 0
    usage_tokens = None
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "ignore").strip()
                if not line.startswith("data:"):
                    continue
                data = line[len("data:"):].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices") or []
                if choices:
                    delta = choices[0].get("delta", {})
                    if delta.get("content"):
                        if ttft is None:
                            ttft = time.monotonic() - t0
                        out_tokens += 1  # content-delta count = token proxy
                if chunk.get("usage"):
                    usage_tokens = chunk["usage"].get("completion_tokens")
        e2e = time.monotonic() - t0
        toks = usage_tokens if usage_tokens else out_tokens
        return (ttft, e2e, toks, True, None)
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        return (None, time.monotonic() - t0, 0, False, str(e))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--concurrency", type=int, default=1)
    ap.add_argument("--requests", type=int, default=8)
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--api-key", default="local")
    ap.add_argument("--json", action="store_true", help="emit JSON only")
    args = ap.parse_args()

    wall0 = time.monotonic()
    results = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futs = [ex.submit(one_request, args.base_url, args.model, args.max_tokens, args.api_key)
                for _ in range(args.requests)]
        for f in futs:
            results.append(f.result())
    wall = time.monotonic() - wall0

    ok = [r for r in results if r[3]]
    ttfts = [r[0] for r in ok if r[0] is not None]
    e2es = [r[1] for r in ok]
    total_tokens = sum(r[2] for r in ok)
    # TPOT: mean over requests of (e2e - ttft) / (tokens - 1)
    tpots = [(r[1] - r[0]) / max(r[2] - 1, 1) for r in ok if r[0] is not None and r[2] > 1]

    summary = {
        "model": args.model,
        "concurrency": args.concurrency,
        "requests": args.requests,
        "ok": len(ok),
        "errors": len(results) - len(ok),
        "error_rate": round((len(results) - len(ok)) / len(results), 3) if results else None,
        "ttft_p50_s": round(_percentile(ttfts, 50), 3) if ttfts else None,
        "ttft_p95_s": round(_percentile(ttfts, 95), 3) if ttfts else None,
        "tpot_mean_s": round(sum(tpots) / len(tpots), 4) if tpots else None,
        "e2e_p50_s": round(_percentile(e2es, 50), 3) if e2es else None,
        "e2e_p95_s": round(_percentile(e2es, 95), 3) if e2es else None,
        "e2e_p99_s": round(_percentile(e2es, 99), 3) if e2es else None,
        "throughput_tok_s": round(total_tokens / wall, 1) if wall else None,
        "throughput_req_s": round(len(ok) / wall, 3) if wall else None,
        "wall_s": round(wall, 2),
    }
    if args.json:
        print(json.dumps(summary))
    else:
        print(f"\n=== {args.model} @ concurrency {args.concurrency} ({len(ok)}/{args.requests} ok) ===")
        for k, v in summary.items():
            print(f"  {k:20} {v}")
        if summary["errors"]:
            first_err = next((r[4] for r in results if not r[3]), "")
            print(f"  first_error          {first_err[:120]}")


if __name__ == "__main__":
    main()
