#!/usr/bin/env python3
"""Interleaved chat-latency comparison between two Gemini models, on the operator's own prompts.

The 2026-09-03 model audit left exactly one question open about the Chat default: it measured
`gemini-3.8-flash` ~12% slower than `gemini-3.7-flash` (2958 vs 2640 ms, n=5, overlapping ranges)
and said, correctly, that the comparison had to be redone properly before hiding 3.7. This is that
comparison.

Three things it does differently from a quick probe, each of which can flip the answer:

  - **Interleaved, not batched.** A/B then B/A within every round, so a slow minute of the API
    lands on both models instead of on whichever was measured second.
  - **Time to first token, not total.** Chat streams into a bubble. What the reader feels is when
    the first words appear; total time is mostly a function of how long an answer the model chose
    to write, which is not a speed difference.
  - **Real prompts.** Read straight out of the staged usage log, so the mix is the operator's own
    (short factual questions, tool troubleshooting, opinion, one long paste) rather than whatever
    a synthetic benchmark would have asked.

    python3 scripts/benchmark-chat-latency.py [--rounds 3] [--models a,b] [--prompts N]

Key from .env (GEMINI_API_KEY), same as the other model scripts. Output is written as a table plus
a per-prompt breakdown; nothing is committed and no default is changed.
"""
import argparse, json, os, random, re, statistics, sys, time, urllib.request, urllib.error

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGING = os.path.join(REPO, "build", "usage-review-staging")
ENDPOINT = ("https://generativelanguage.googleapis.com/v1beta/models/"
            "{model}:streamGenerateContent?alt=sse&key={key}")


def api_key():
    env = os.path.join(REPO, ".env")
    if os.path.exists(env):
        for line in open(env, encoding="utf-8"):
            m = re.match(r"\s*(?:export\s+)?GEMINI_API_KEY\s*=\s*[\"']?([^\"'\s]+)", line)
            if m:
                return m.group(1)
    return os.environ.get("GEMINI_API_KEY")


def load_prompts(limit):
    """Self-contained questions from the staged chat log — a follow-up like "und wo entsteht der?"
    measures nothing without the thread it belonged to, so those are skipped."""
    rows = []
    for name in sorted(os.listdir(STAGING)):
        if not name.startswith("interactions-"):
            continue
        for line in open(os.path.join(STAGING, name), encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("mode") != "geminiChat":
                continue
            text = re.sub(r"<[^>]+>", "", r.get("userInstruction") or "").strip()
            if len(text) < 25:                      # "test", "double check", "where"
                continue
            if re.match(r"^(ja|nein|und|aber|okay|was denkst|double check)\b", text, re.I):
                continue
            rows.append(text)
    # Spread across the length range rather than taking the first N: the long pastes are a real
    # part of the mix and they are where a latency difference would actually be felt.
    rows.sort(key=len)
    if len(rows) <= limit:
        return rows
    step = len(rows) / limit
    return [rows[int(i * step)] for i in range(limit)]


def call(model, prompt, key, max_tokens, thinking, grounding):
    """One streaming request, shaped like the app's own chat request rather than a bare probe.

    Both matter and both were missing from the audit's probe. `GeminiAPIClient.swift:414` sends
    `google_search` + `url_context` + `code_execution` on every chat turn, and
    `PromptModel.geminiThinkingConfig` pins BOTH 3.7 and 3.8 to `thinkingLevel: low`. A search
    round-trip lands before the first visible word, so a measurement without it is timing a code
    path the operator never reaches.

    Returns (ttft_ms, total_ms, out_chars) or (None, None, error)."""
    payload = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"maxOutputTokens": max_tokens},
    }
    if thinking:
        payload["generationConfig"]["thinkingConfig"] = {"thinkingLevel": thinking}
    if grounding:
        payload["tools"] = [{"google_search": {}}, {"url_context": {}}, {"code_execution": {}}]
    body = json.dumps(payload).encode()
    req = urllib.request.Request(ENDPOINT.format(model=model, key=key), data=body,
                                 headers={"Content-Type": "application/json"})
    start = time.perf_counter()
    ttft = None
    chars = 0
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            for raw in resp:
                if not raw.startswith(b"data: "):
                    continue
                try:
                    chunk = json.loads(raw[6:])
                except ValueError:
                    continue
                for cand in chunk.get("candidates", []):
                    for part in cand.get("content", {}).get("parts", []):
                        text = part.get("text") or ""
                        if text and ttft is None:
                            ttft = (time.perf_counter() - start) * 1000
                        chars += len(text)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        return None, None, str(exc)
    return ttft, (time.perf_counter() - start) * 1000, chars


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="gemini-3.7-flash,gemini-3.8-flash")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--prompts", type=int, default=12)
    ap.add_argument("--max-tokens", type=int, default=1024,
                    help="bounds cost; low enough to stay cheap, high enough for a real answer")
    ap.add_argument("--thinking", default="low",
                    help="thinkingLevel — 'low' is what the app pins 3.7 and 3.8 to")
    ap.add_argument("--no-grounding", action="store_true",
                    help="drop google_search/url_context/code_execution (NOT what the app does)")
    args = ap.parse_args()

    key = api_key()
    if not key:
        sys.exit("no GEMINI_API_KEY (put it in .env or the environment)")
    models = [m.strip() for m in args.models.split(",")]
    prompts = load_prompts(args.prompts)
    print(f"{len(prompts)} prompts x {args.rounds} rounds x {len(models)} models = "
          f"{len(prompts) * args.rounds * len(models)} calls · thinking={args.thinking or 'api default'} "
          f"· grounding={'off' if args.no_grounding else 'on (as the app sends it)'}\n")

    results = {m: {"ttft": [], "total": [], "chars": [], "errors": 0} for m in models}
    per_prompt = []
    for i, prompt in enumerate(prompts):
        row = {"prompt": prompt, "len": len(prompt), "ttft": {m: [] for m in models}}
        for r in range(args.rounds):
            # Alternate the order every round: whichever model goes first pays for a cold
            # connection and for whatever the API was doing that second.
            order = models if (i + r) % 2 == 0 else list(reversed(models))
            for model in order:
                ttft, total, chars = call(model, prompt, key, args.max_tokens,
                                          args.thinking, not args.no_grounding)
                if ttft is None:
                    results[model]["errors"] += 1
                    continue
                results[model]["ttft"].append(ttft)
                results[model]["total"].append(total)
                results[model]["chars"].append(chars)
                row["ttft"][model].append(ttft)
        per_prompt.append(row)
        print(f"  [{i+1}/{len(prompts)}] {row['len']:5d}ch  " +
              "  ".join(f"{m.split('-')[1]}={statistics.median(row['ttft'][m]):6.0f}ms"
                        for m in models if row["ttft"][m]))

    print("\n=== Time to first token (what you feel) ===")
    print(f"{'model':22s} {'n':>4s} {'median':>9s} {'mean':>9s} {'p25':>9s} {'p75':>9s} {'errors':>7s}")
    for m in models:
        d = sorted(results[m]["ttft"])
        if not d:
            print(f"{m:22s}  no successful calls")
            continue
        print(f"{m:22s} {len(d):4d} {statistics.median(d):8.0f}m {statistics.mean(d):8.0f}m "
              f"{d[len(d)//4]:8.0f}m {d[3*len(d)//4]:8.0f}m {results[m]['errors']:7d}")

    print("\n=== Total time and answer length (context, not the verdict) ===")
    for m in models:
        if results[m]["total"]:
            print(f"{m:22s} total median {statistics.median(results[m]['total']):6.0f} ms · "
                  f"answer median {statistics.median(results[m]['chars']):5.0f} chars")

    # Paired comparison: the same prompt, same round, both models — the only honest way to say
    # "faster", because prompt difficulty varies far more than the models do.
    if len(models) == 2:
        a, b = models
        deltas = [statistics.median(r["ttft"][a]) - statistics.median(r["ttft"][b])
                  for r in per_prompt if r["ttft"][a] and r["ttft"][b]]
        if deltas:
            wins_b = sum(1 for d in deltas if d > 0)
            print(f"\n=== Paired, per prompt (n={len(deltas)}) ===")
            print(f"{b} faster on {wins_b}/{len(deltas)} prompts · "
                  f"median delta {statistics.median(deltas):+.0f} ms "
                  f"({'b faster' if statistics.median(deltas) > 0 else 'a faster'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
