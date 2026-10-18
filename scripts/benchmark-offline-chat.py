#!/usr/bin/env python3
"""Offline Chat benchmark: is a larger in-process MLX model worth offering for Chat?

Chat Q&A, not Dictate Prompt. Feeds `AppConstants.defaultOfflineChatSystemPrompt` (read from the
Swift source so it never drifts) plus one real question per case, and records first-token latency,
first *visible* token latency (after any reasoning channel), decode tokens/s and peak RAM.
Quality is judged by reading the answers; there are no rule scorers.

Runs on Python mlx-lm, like `benchmark-offline-prompt.py`:
    build/mlx-bench-venv/bin/python scripts/benchmark-offline-chat.py \\
        --models mlx-community/Qwen3-4B-Instruct-2507-4bit,mlx-community/Qwen3.5-9B-MLX-4bit
"""

import argparse
import gc
import os
import re
import statistics
import time

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_TOKENS = 1200

QUESTIONS = [
    ("yt-dlp-de", "Wie lade ich mit yt-dlp nur die Audiospur von "
                  "https://www.youtube.com/watch?v=dQw4w9WgXcQ als mp3 herunter?"),
    ("port-en", "How do I find which process is using port 8080 on macOS and kill it?"),
    ("gmbh-ug-de", "Was ist der Unterschied zwischen einer GmbH und einer UG, und wann lohnt sich welche?"),
    ("https-en", "Briefly explain how a browser validates an HTTPS certificate."),
    ("westfalen-de", "Was war der Westfälische Frieden und warum ist er historisch wichtig?"),
    ("atemlos-de", "Wer hat 'Atemlos durch die Nacht' gesungen und in welchem Jahr kam es raus?"),
    ("csv-en", "In Python, how do I read a CSV file and compute the average of the 'price' column "
               "without pandas?"),
    ("email-en", "Write a short, friendly email declining a meeting on Friday because I'm travelling. "
                 "Suggest Tuesday instead."),
    ("translate-de", "Übersetz mir das ins Englische: Ich hab grad keine Zeit, lass uns morgen "
                     "telefonieren, passt dir 10 Uhr?"),
    ("mietrecht-de", "Darf mein Vermieter in Deutschland die Miete einfach so um 20 % erhöhen?"),
]


def offline_system_prompt():
    src = open(os.path.join(REPO, "WhisperShortcut", "AppConstants.swift"), encoding="utf-8").read()
    body = re.search(r'defaultOfflineChatSystemPrompt =\s*"""\n(.*?)"""', src, re.S).group(1)
    return "Today's date: Sunday, October 18, 2026.\n\n" + body.strip()


def visible(text):
    """What the chat bubble shows: no <think> block, no gpt-oss analysis channel."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    if "<|channel|>final<|message|>" in text:
        text = text.split("<|channel|>final<|message|>", 1)[1]
    elif "<|channel|>" in text:
        return ""  # still in the analysis channel
    return re.sub(r"<\|[a-z_]+\|>", "", text).strip()


def bench(repo_id, rounds, sampler):
    mx.reset_peak_memory()
    t0 = time.time()
    model, tokenizer = load(repo_id)
    load_s = time.time() - t0
    system = offline_system_prompt()
    ttft, ttvt, tps, answers = [], [], [], {}
    for case_id, question in QUESTIONS:
        messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False,
            enable_thinking=False, reasoning_effort="low")
        for _ in range(rounds):
            t, first, first_visible, raw, last = time.time(), None, None, "", None
            for resp in stream_generate(model, tokenizer, prompt=prompt, max_tokens=MAX_TOKENS,
                                        sampler=sampler):
                now = time.time()
                first = first or now
                raw += resp.text
                if first_visible is None and visible(raw):
                    first_visible = now
                last = resp
            ttft.append(first - t)
            ttvt.append((first_visible or time.time()) - t)
            tps.append(last.generation_tps)
            answers.setdefault(case_id, []).append(visible(raw))
    peak = mx.get_peak_memory() / 1e9
    del model, tokenizer
    gc.collect()
    mx.clear_cache()
    return {"model": repo_id, "load_s": load_s, "peak_gb": peak,
            "ttft": statistics.median(ttft), "ttvt": statistics.median(ttvt),
            "tps": statistics.median(tps), "answers": answers}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--rounds", type=int, default=1)
    args = ap.parse_args()
    sampler = make_sampler(temp=0.6, top_p=0.95)
    rows = []
    for repo_id in args.models.split(","):
        r = bench(repo_id, args.rounds, sampler)
        rows.append(r)
        print(f"\n## {repo_id}\n  load {r['load_s']:.1f}s · peak RAM {r['peak_gb']:.1f} GB · "
              f"first token {r['ttft']:.2f}s · first visible {r['ttvt']:.2f}s · {r['tps']:.1f} tok/s")
        for case_id, outs in r["answers"].items():
            for out in outs:
                print(f"\n### [{case_id}]\n{out}")
    print("\n| Model | Peak RAM | First token | First visible | Decode |\n|---|---|---|---|---|")
    for r in rows:
        print(f"| `{r['model']}` | {r['peak_gb']:.1f} GB | {r['ttft']:.2f} s | {r['ttvt']:.2f} s | "
              f"{r['tps']:.1f} tok/s |")


if __name__ == "__main__":
    main()
