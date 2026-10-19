#!/usr/bin/env python3
"""List offline-model candidates on HuggingFace for model-lineup-check.sh.

The cloud fetchers in model-lineup-check.sh ask provider APIs; every offline model the app ships
comes from HuggingFace instead, which no loop watched — Parakeet Ultra and Qwen3.5 were found by
hand. This prints one candidate per line as `<id>\t<note>`, filtered to what the app could load
without a dependency change, so the lineup check can diff it against its seen-list like any
provider.

Sources (argv[1]):
  mlx         MLX text-generation repos from mlx-community, lmstudio-community and each model
              lab's own org (e.g. `ibm-granite/granite-4.2-3b-q4-mlx`) → reported by their *base*
              model (e.g. `Qwen/Qwen3.5-4B`), so the quantisations of one release are one line.
              Kept only if: the architecture is in the pinned mlx-swift-lm's LLMModelFactory,
              1.5B–10B parameters (read from the base: a 4-bit repo's tensor count is packed),
              the base comes from a model lab rather than a community finetune, and a 4-bit build
              exists.
  whisperkit  variant folders in argmaxinc/whisperkit-coreml (what ModelManager downloads).
  fluidaudio  FluidInference Core ML speech-recognition repos (what FluidAudio downloads).

Exit status is non-zero when HuggingFace or GitHub cannot be reached, so the caller reports a
fetch failure instead of silently seeing "nothing new".
"""
import json
import re
import sys
import urllib.error
import urllib.parse
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


def hf_or_none(path):
    """`hf()`, but None when the repo is missing; every other error still raises.

    HuggingFace answers 401 (not 404) for a repo id that does not exist, so both mean "missing".
    """
    try:
        return hf(path)
    except urllib.error.HTTPError as e:
        if e.code in (401, 404):
            return None
        raise


EXPAND = "&expand[]=config&expand[]=cardData&expand[]=safetensors"


def mlx_candidates():
    """MLX repos from mlx-community, lmstudio-community and every model lab's own org."""
    query = "sort=createdAt&direction=-1" + EXPAND
    # ~600 newest repos reach back ~3 months; the check runs every two weeks. No text-generation
    # filter: multimodal builds (Gemma 4) are tagged image-text-to-text; model_type filters later.
    repos = hf(f"models?author=mlx-community&{query}&limit=600")
    repos += hf(f"models?author=lmstudio-community&{query}&limit=200")
    for org in sorted(MODEL_LABS):
        repos += hf_or_none(f"models?author={org}&search=mlx&{query}&limit=50") or []
    seen = {}
    for m in repos:
        seen.setdefault(m["id"], m)
    return list(seen.values())


def derive_base(rid):
    """Base id of a lab's own MLX repo: strip a trailing MLX/quant suffix from the name."""
    org, name = rid.split("/", 1)
    name = re.sub(r"(?:[-_](?:mlx|q4|[48]-?bit|mxfp4|qat|bf16))+$", "", name, flags=re.I)
    return f"{org}/{name}"


def guess_base(rid, guessed={}):
    """Lab repo named like `rid` without its quant suffix, found by one name search per name."""
    name = derive_base(rid).split("/", 1)[1]
    if name not in guessed:
        hits = hf(f"models?search={urllib.parse.quote(name)}&sort=downloads&direction=-1&limit=100")
        guessed[name] = next((h["id"] for h in hits
                              if h["id"].split("/")[0] in MODEL_LABS
                              and h["id"].split("/", 1)[1].lower() == name.lower()), None)
    return guessed[name]


def mlx():
    supported = supported_mlx_model_types()
    bases = {}  # base id -> {"config", "safetensors"} or None (404)

    def base_info(base):
        if base not in bases:
            bases[base] = hf_or_none(f"models/{base}?expand[]=safetensors&expand[]=config")
        return bases[base]

    best = {}
    for m in mlx_candidates():
        rid = m["id"]
        org = rid.split("/")[0]
        if not re.search(r"4bit|4-bit|oq4|q4|mxfp4", rid, re.I):
            continue
        base = (m.get("cardData") or {}).get("base_model")
        base = base[0] if isinstance(base, list) and base else base
        derived = not isinstance(base, str)
        if derived and org in MODEL_LABS:
            base = derive_base(rid)
        elif derived:
            # Repo without base_model in its card (e.g. mlx-community/gemma-4-E4B-it-qat-4bit):
            # only worth a name search for architectures we support.
            if (m.get("config") or {}).get("model_type") not in supported:
                continue
            base = guess_base(rid)
            if not base:
                continue
        if base.split("/")[0] not in MODEL_LABS:
            continue
        info = base_info(base)
        if derived and info is None:
            continue
        info = info or {}
        model_type = (m.get("config") or {}).get("model_type") or (info.get("config") or {}).get("model_type")
        if model_type not in supported:
            continue
        params = ((info.get("safetensors") or {}).get("total")
                  or (m.get("safetensors") or {}).get("total") or 0)
        if not MIN_PARAMS <= params <= MAX_PARAMS:
            continue
        # one line per base; an mlx-community repo is the preferred example
        if base not in best or (org == "mlx-community" and not best[base][0].startswith("mlx-community/")):
            best[base] = (rid, params)
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
