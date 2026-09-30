#!/usr/bin/env python3
"""List offline-model candidates on HuggingFace for model-lineup-check.sh.

The cloud fetchers in model-lineup-check.sh ask provider APIs; every offline model the app ships
comes from HuggingFace instead, which no loop watched — Parakeet Ultra and Qwen3.5 were found by
hand. This prints one candidate per line as `<id>\t<note>`, filtered to what the app could load
without a dependency change, so the lineup check can diff it against its seen-list like any
provider.

Sources (argv[1]):
  mlx         mlx-community text-generation repos → reported by their *base* model
              (e.g. `Qwen/Qwen3.5-4B`), so the six quantisations of one release are one line.
              Kept only if: the architecture is in the pinned mlx-swift-lm's LLMModelFactory,
              1.5B–10B parameters (fits an 8 GB Mac beside a dictation model at 4-bit), the base
              comes from a model lab rather than a community finetune, and a 4-bit build exists.
  whisperkit  variant folders in argmaxinc/whisperkit-coreml (what ModelManager downloads).
  fluidaudio  FluidInference Core ML speech-recognition repos (what FluidAudio downloads).

Exit status is non-zero when HuggingFace or GitHub cannot be reached, so the caller reports a
fetch failure instead of silently seeing "nothing new".
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PACKAGE_RESOLVED = (REPO / "WhisperShortcut.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
                    / "Package.resolved")

# Orgs whose own releases are worth a heads-up. Finetunes and merges of their models by third
# parties point their base_model at the finetune, not here, and drop out.
MODEL_LABS = {
    "Qwen", "google", "meta-llama", "mistralai", "microsoft", "ibm-granite", "nvidia",
    "HuggingFaceTB", "LiquidAI", "allenai", "deepseek-ai", "openai", "zai-org", "THUDM",
    "moonshotai", "openbmb", "baidu", "tencent", "XiaomiMiMo", "CohereLabs", "LGAI-EXAONE",
    "swiss-ai", "inclusionAI", "MiniMaxAI",
}
MIN_PARAMS, MAX_PARAMS = 1.5e9, 10e9


def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode()


def hf(path):
    return json.loads(get(f"https://huggingface.co/api/{path}"))


def supported_mlx_model_types():
    """`model_type` keys of LLMModelFactory at the mlx-swift-lm revision the app is pinned to."""
    pins = json.loads(PACKAGE_RESOLVED.read_text())["pins"]
    rev = next(p["state"]["revision"] for p in pins if p["identity"] == "mlx-swift-lm")
    src = get("https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/"
              f"{rev}/Libraries/MLXLLM/LLMModelFactory.swift")
    types = set(re.findall(r'"([a-z0-9_]+)"\s*:\s*create', src))
    if not types:
        raise RuntimeError("no model types parsed from LLMModelFactory.swift")
    return types


def mlx():
    supported = supported_mlx_model_types()
    # ~200 newest repos reach back ~3 months; the check runs every two weeks.
    repos = hf("models?author=mlx-community&filter=text-generation&sort=createdAt&direction=-1"
               "&limit=200&expand[]=config&expand[]=cardData&expand[]=safetensors")
    best = {}
    for m in repos:
        rid = m["id"]
        if not re.search(r"4bit|4-bit|oq4", rid, re.I):
            continue
        if (m.get("config") or {}).get("model_type") not in supported:
            continue
        params = (m.get("safetensors") or {}).get("total") or 0
        if not MIN_PARAMS <= params <= MAX_PARAMS:
            continue
        base = (m.get("cardData") or {}).get("base_model")
        base = base[0] if isinstance(base, list) and base else base
        if not isinstance(base, str) or base.split("/")[0] not in MODEL_LABS:
            continue
        best.setdefault(base, (rid, params))
    for base, (rid, params) in sorted(best.items()):
        print(f"{base}\t{params / 1e9:.1f}B params, e.g. {rid}")


def whisperkit():
    tree = hf("models/argmaxinc/whisperkit-coreml/tree/main")
    for entry in tree:
        if entry["type"] == "directory":
            print(f"{entry['path']}\targmaxinc/whisperkit-coreml")


def fluidaudio():
    for m in hf("models?author=FluidInference&limit=500&expand[]=pipeline_tag"):
        if m.get("pipeline_tag") == "automatic-speech-recognition" and m["id"].endswith("-coreml"):
            print(f"{m['id']}\tCore ML ASR for FluidAudio")


if __name__ == "__main__":
    {"mlx": mlx, "whisperkit": whisperkit, "fluidaudio": fluidaudio}[sys.argv[1]]()
