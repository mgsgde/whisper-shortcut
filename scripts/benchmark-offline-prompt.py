#!/usr/bin/env python3
"""Offline Dictate Prompt benchmark: which MLX model should the offline catalogue ship?

benchmark-dictate-prompt.py scores cloud audio-chat models. The offline path is different: the
spoken instruction is transcribed locally first (Parakeet / Whisper, measured on their own), then
an in-process MLX text model applies it (`SpeechService.executePromptWithLocal` →
`MLXChatProvider`). So this benchmark feeds the instruction as *text* and scores only the LLM
stage — same cases, same scorers, same system prompt, same user-turn layout as the app.

Mirrors of the app, keep in sync:
  - user turn: `<clipboard header>\\n\\n<selection>\\n\\nVOICE INSTRUCTION:\\n<instruction>`
  - `enable_thinking: false` in the chat template, `<think>` blocks stripped from the reply
  - GenerateParameters defaults: temperature 0.6, top-p 1.0; maxTokens = localPromptMaxOutputTokens
  - the system prompt is prefilled once per model and reused (`MLXPromptCache`), so the latency
    column is what a warm request costs, not a cold one

Runs on Python mlx-lm, not mlx-swift-lm. Same weights, same Metal kernels family; absolute
latency can differ a little from the app, the ranking should not.

    uv venv -p 3.12 build/mlx-bench-venv && uv pip install -p build/mlx-bench-venv mlx-lm
    build/mlx-bench-venv/bin/python scripts/benchmark-offline-prompt.py
    build/mlx-bench-venv/bin/python scripts/benchmark-offline-prompt.py \\
        --models mlx-community/Qwen3.5-4B-MLX-4bit --rounds 5 --show-outputs
"""
import argparse, copy, gc, importlib.util, os, re, statistics, time

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_sampler

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_MLX_DIR = os.path.expanduser(
    "~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/"
    "WhisperShortcut/MLXModels/hub/models")
DEFAULT_MODELS = [
    "mlx-community/Qwen3-4B-Instruct-2507-4bit",  # shipped default
    "mlx-community/Qwen3-8B-4bit",                # shipped, larger
    "mlx-community/Qwen3.5-4B-MLX-4bit",
    "mlx-community/Qwen3.5-9B-MLX-4bit",
    "mlx-community/gemma-4-e2b-it-4bit",
]
MAX_TOKENS = 4096  # AppConstants.localPromptMaxOutputTokens

# The shared cases are rule checks, and a 4B model passes nearly all of them — they separate
# "broken" from "fine", not "fine" from "good". These ask for real writing work; they have no
# scorer and are always printed, for a human (or judging model) to compare side by side.
JUDGED_CASES = [
    ("fix-typos-long",
     "hi thomas, danke für die schnelle rückmeldung. ich hab mir das angebot angeschaut und "
     "grundsätzlich passt das, aber der zweite posten ist mir nicht ganz klar, wieso der so "
     "teuer ist wenn doch die lizenz schon im ersten enthalten ist. kannst du mir das "
     "nochmal aufschlüssen? dann kann ich das bis freitag freigeben. lg magnus",
     "Korrigiere Rechtschreibung und Grammatik, aber lass den Ton locker."),
    ("make-polite-email",
     "brauch die zahlen bis morgen sonst wird das nix mit dem report",
     "Mach daraus eine höfliche kurze Mail an meine Kollegin Sarah."),
    ("summarize-bullets",
     "Wir haben heute besprochen, dass der Release auf nächsten Dienstag verschoben wird, weil "
     "die Zertifizierung noch fehlt. Lisa kümmert sich um die Release Notes, Jonas testet die "
     "Offline-Modelle auf einem 8-GB-Mac und ich schreibe die App-Store-Beschreibung neu. Das "
     "Budget für Werbung bleibt bei 500 Euro im Monat.",
     "Fass das als Stichpunkte mit Aufgaben und Verantwortlichen zusammen."),
    ("improve-english",
     "We are exciting to announce that our app now is supporting offline dictation, which "
     "means you dont need internet anymore for to transcribe your voice.",
     "Improve the wording, make it sound natural for a product announcement."),
]

_spec = importlib.util.spec_from_file_location(
    "cloud_bench", os.path.join(REPO, "scripts", "benchmark-dictate-prompt.py"))
cloud = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cloud)


def model_path(repo_id):
    """The app's own download when it has one, so shipped models are the exact bytes users run."""
    local = os.path.join(APP_MLX_DIR, repo_id)
    # A cancelled in-app download leaves config.json without weights — fall back to the hub.
    complete = os.path.isdir(local) and any(f.endswith(".safetensors") for f in os.listdir(local))
    return local if complete else repo_id


def render(tokenizer, messages, generation_prompt):
    return tokenizer.apply_chat_template(
        messages, add_generation_prompt=generation_prompt, tokenize=False, enable_thinking=False)


def strip_reasoning(text):
    """Mirror of LocalLLMChatProvider.strippingReasoningBlocks."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    return re.sub(r"^.*?</think>", "", text, flags=re.S).strip()


def bench_model(repo_id, sys_prompt, rounds, show):
    mx.reset_peak_memory()
    t0 = time.time()
    model, tokenizer = load(model_path(repo_id))
    load_s = time.time() - t0

    system = [{"role": "system", "content": sys_prompt}]
    # The cacheable prefix is what every request shares: the common start of two full renders.
    # (Rendering the system turn alone fails on templates that demand a user turn, e.g. Qwen3.5.)
    a, b = (tokenizer.encode(render(tokenizer, system + [{"role": "user", "content": u}], True),
                             add_special_tokens=False) for u in ("A", "B"))
    n = next(i for i, (x, y) in enumerate(zip(a, b)) if x != y)
    prefix_ids = a[:n]
    base_cache = make_prompt_cache(model)
    # Prefill the system prompt once (MLXPromptCache): run it through, discard the one token.
    for _ in stream_generate(model, tokenizer, prompt=prefix_ids, max_tokens=1,
                             prompt_cache=base_cache):
        pass
    # The single generated token went into the cache too; rebuild without it when trimmable.
    from mlx_lm.models.cache import can_trim_prompt_cache, trim_prompt_cache
    cached = can_trim_prompt_cache(base_cache)
    if cached:
        trim_prompt_cache(base_cache, 1)

    sampler = make_sampler(temp=0.6, top_p=1.0)
    fails, checks, latencies, outputs = [], 0, [], {}
    cases = cloud.CASES + [(c, s, i, []) for c, s, i in JUDGED_CASES]
    judged = {c for c, *_ in JUDGED_CASES}
    for case_id, selected, instruction, scorers in cases:
        user = (f"{cloud.CLIPBOARD_HEADER}\n\n{selected}\n\n"
                f"VOICE INSTRUCTION:\n{instruction}")
        full = render(tokenizer, system + [{"role": "user", "content": user}], True)
        full_ids = tokenizer.encode(full, add_special_tokens=False)
        use_cache = cached and full_ids[:len(prefix_ids)] == prefix_ids
        for r in range(rounds):
            cache = copy.deepcopy(base_cache) if use_cache else make_prompt_cache(model)
            prompt = full_ids[len(prefix_ids):] if use_cache else full_ids
            t = time.time()
            text = "".join(resp.text for resp in stream_generate(
                model, tokenizer, prompt=prompt, max_tokens=MAX_TOKENS, sampler=sampler,
                prompt_cache=cache))
            latencies.append(time.time() - t)
            out = strip_reasoning(text)
            outputs.setdefault(case_id, []).append(out)
            for scorer in scorers:
                checks += 1
                reason = scorer(out, selected)
                if reason:
                    fails.append((case_id, r, reason, out))
    peak_gb = mx.get_peak_memory() / 1e9

    print(f"\n## {repo_id}")
    print(f"  load {load_s:.1f}s · peak RAM {peak_gb:.1f} GB · prefix cache "
          f"{'on' if cached else 'OFF (cache not trimmable)'}")
    print(f"  rules {checks - len(fails)}/{checks} · latency median "
          f"{statistics.median(latencies):.2f}s, p90 "
          f"{sorted(latencies)[int(len(latencies) * 0.9) - 1]:.2f}s")
    for case_id, r, reason, out in fails:
        print(f"  FAIL {case_id} r{r}: {reason}\n       → {out[:160]!r}")
    for case_id, outs in outputs.items():
        if case_id in judged:
            for i, out in enumerate(outs):
                print(f"  [{case_id} r{i}]\n{out}\n")
        elif show:
            print(f"  [{case_id}] {outs[0][:200]!r}")

    del model, tokenizer, base_cache
    gc.collect()
    mx.clear_cache()
    return {"model": repo_id, "pass": checks - len(fails), "checks": checks,
            "median": statistics.median(latencies), "peak_gb": peak_gb}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default=",".join(DEFAULT_MODELS))
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--show-outputs", action="store_true")
    args = ap.parse_args()

    sys_prompt, source = cloud.system_prompt()
    print(f"System prompt: {source} ({len(sys_prompt)} chars) · {len(cloud.CASES)} cases × "
          f"{args.rounds} rounds · temp 0.6, thinking off")
    rows = [bench_model(m, sys_prompt, args.rounds, args.show_outputs)
            for m in args.models.split(",")]

    print("\n| Model | Rules | Median latency | Peak RAM |\n|---|---|---|---|")
    for r in rows:
        print(f"| `{r['model']}` | {r['pass']}/{r['checks']} | {r['median']:.2f} s | "
              f"{r['peak_gb']:.1f} GB |")


if __name__ == "__main__":
    main()
