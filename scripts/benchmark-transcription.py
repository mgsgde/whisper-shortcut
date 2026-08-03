#!/usr/bin/env python3
"""Empirical transcription benchmark: latency, glossary adherence, silence hallucination.

`test-*-models.sh` answers "does this model ID still serve?". This answers the question that
actually decides which model we default to: "which one is fastest, spells the user's vocabulary
right, and doesn't invent a transcript when the audio is silent?"

Run it from the repo root (reads OPENAI_API_KEY / GEMINI_API_KEY / XAI_API_KEY from .env):

    python3 scripts/benchmark-transcription.py                # all three suites
    python3 scripts/benchmark-transcription.py --suite latency --rounds 10
    python3 scripts/benchmark-transcription.py --models gemini-3.1-flash-lite,gpt-transcribe

Method notes that matter for comparability across runs:
  - Latency rounds are *interleaved and shuffled*: one call per model per round, order randomised
    each round, so network drift and time-of-day effects hit every model equally. A sequential
    "10x model A, then 10x model B" loop produced 2x differences that did not replicate.
  - Every model gets a warm-up call first (TLS handshake, connection setup), matching the app,
    which pre-warms connections via ConnectionPrewarmer.
  - Report medians, not means. One 200 s network stall otherwise decides the ranking.
  - Fixtures are synthesised with `say -v Anna`, i.e. clean studio-like speech. Absolute accuracy
    is therefore optimistic; the comparison between models is the usable output.
"""
import argparse, base64, collections, json, os, random, re, statistics, subprocess, sys, urllib.error, urllib.request, wave

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "build", "benchmark-fixtures")

# Every cloud transcription model the app can dictate with. Keep in sync with TranscriptionModel.
#
# gemini-3.1-pro-preview is deliberately absent. It was added here on 2026-08-03 and the first run
# exposed why it should never have been in the picker: with any real transcription prompt it returns
# nothing at all for the 1.3 s case — 4/4, including a 300 s attempt that received zero bytes, while
# a trivial-prompt control answered in ~6 s between the failures. Streaming and reworded prompts
# fail identically. `TranscriptionModel.isSelectableForDictation` stopped offering it the same day
# (the enum case stays — PromptModel resolves its Gemini endpoint through it). Re-add it here (with
# a `minimal`→`low` thinking-level clamp — Pro 400s on `minimal`) only to check whether Google has
# fixed it; expect three 90 s timeouts per run until they have.
MODELS = {
    "gemini-3.1-flash-lite": "gemini",
    "gemini-3.5-flash-lite": "gemini",
    "gemini-3.5-flash": "gemini",
    "gemini-3.6-flash": "gemini",
    "gpt-transcribe": "openai-keywords",
    "gpt-4o-transcribe": "openai-prompt",
    "gpt-4o-mini-transcribe": "openai-prompt",
    "grok-stt": "xai",
}

# Fixtures: (id, seconds-ish, spoken text, terms that must appear verbatim).
# The sentences deliberately load the vocabulary that is hard for ASR — product names that are
# one word, near-homophones, German proper nouns — because that is where models actually differ.
CASES = [
    ("short", "Testing one two three.", []),
    ("claude",
     "Ich habe gestern mit der Claude CLI im Projekt WhisperShortcut gearbeitet und danach "
     "Claude Opus gefragt, ob sich das Vibe-Coding lohnt.",
     ["Claude CLI", "WhisperShortcut", "Claude Opus", "Vibe-Coding"]),
    ("names",
     "Magnus Gödde hat den Termin mit EnBW in Karlsruhe verschoben und danach bei SMARTBROKER "
     "das Backup eingerichtet.",
     ["Magnus Gödde", "EnBW", "Karlsruhe", "SMARTBROKER", "Backup"]),
    ("tools",
     "Bitte prüfe im Vault, ob das Event in Heidelberg mit Gemini Flash oder mit Grok geplant war.",
     ["Vault", "Event", "Heidelberg", "Gemini", "Grok"]),
    ("long",
     "Magnus Gödde hat gestern im Xcode-Projekt WhisperShortcut die Chunk-Transkription umgebaut, "
     "weil die Latenz bei längeren Diktaten zu hoch war. Die neue Pipeline schneidet die Aufnahme "
     "in überlappende Abschnitte und schickt sie parallel an das Modell. Danach werden die "
     "Teiltranskripte wieder zusammengefügt, wobei die Überlappung erkannt und entfernt wird.",
     ["WhisperShortcut", "Chunk-Transkription", "Magnus Gödde"]),
]

SILENCE_DURATIONS = (1, 3, 8)


# --------------------------------------------------------------------------- prompts


def load_env():
    path = os.path.join(REPO, ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


CONTAINER_PROMPTS = os.path.expanduser(
    "~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/"
    "WhisperShortcut/UserContext/system-prompts.md")
SNAPSHOT = os.path.join(FIXTURES, "system-prompts-snapshot.md")


def _parse_prompts(text):
    section, buf = None, collections.defaultdict(list)
    for line in text.splitlines(keepends=True):
        if line.startswith("==="):
            section = line.strip()
            continue
        if section:
            buf[section].append(line)
    dictation = glossary = ""
    for header, lines in buf.items():
        if "Dictation" in header:
            dictation = "".join(lines).strip()
        elif "Glossary" in header:
            glossary = "".join(lines).strip()
    return dictation, glossary


def user_prompts():
    """The real Dictation prompt + Whisper Glossary, with a snapshot fallback.

    Benchmarking against the shipped defaults would understate the problem: glossary echo and
    term adherence only show up once a real vocabulary list is in the prompt.

    Reading them is not always possible, though. The file lives inside the app's sandbox
    container, which macOS protects with TCC: a Terminal run inherits the terminal's Full Disk
    Access and succeeds, while the same script started by launchd gets EPERM. That difference is
    invisible in testing and killed the first real cron run outright.

    So: read the container when allowed and keep a snapshot in build/ for when it is not. A
    missing or stale vocabulary degrades the benchmark's realism — it must never abort it, and
    the caller prints which source was used so a report can never silently claim otherwise.
    """
    source = None
    text = None
    try:
        with open(CONTAINER_PROMPTS, encoding="utf-8") as f:
            text = f.read()
        source = "app container (live)"
        os.makedirs(FIXTURES, exist_ok=True)                 # refresh the snapshot while we can
        with open(SNAPSHOT, "w", encoding="utf-8") as f:
            f.write(text)
    except (PermissionError, OSError):
        try:
            with open(SNAPSHOT, encoding="utf-8") as f:
                text = f.read()
            source = f"snapshot from {os.path.basename(SNAPSHOT)} (container not readable)"
        except OSError:
            source = "built-in defaults (no container access, no snapshot)"

    dictation, glossary = _parse_prompts(text) if text else ("", "")
    if not dictation:
        dictation = ("Transcribe speech verbatim with proper punctuation and capitalization. "
                     "If the audio is silent or unintelligible, return nothing.")
    return dictation, glossary, source


def glossary_terms(glossary):
    """Mirror of SpeechService.parsedGlossary: annotations stripped, rejected spellings dropped,
    phrase-style entries (>3 words) dropped."""
    rejected, terms = set(), []
    for line in glossary.splitlines():
        for m in re.findall(r"\((?:not|nicht)\s+([^)]*)\)", line, re.I):
            for form in m.split(","):
                rejected.add(fold(form.strip(" \"'")))
        clean = re.sub(r"\s*\((?:not|nicht)\s+[^)]*\)", "", line, flags=re.I)
        for part in clean.split(","):
            t = re.sub(r"^\s*Terms:\s*", "", part, flags=re.I).strip()
            if t and len(t.split()) <= 3 and fold(t) not in rejected:
                terms.append(t)
    return [t for t in terms if fold(t) not in rejected]


def fold(w):
    return w.lower().replace("ö", "o").replace("ä", "a").replace("ü", "u").replace("ß", "ss")


def build_prompt(dictation, terms):
    """appendGlossaryHint's reference-vocabulary block, as SpeechService assembles it."""
    if not terms:
        return dictation
    return dictation + "\n\n" + (
        "Reference vocabulary — correct spellings of names and terms this speaker uses. "
        "If, and only if, you clearly hear one of them, transcribe it with exactly this spelling "
        "and capitalization instead of a more common, similar-sounding word. This list is a "
        "spelling reference only, NOT content: never output a listed term you did not clearly "
        "hear, and never append these terms to the transcript. If the audio is silent or "
        "unintelligible, return an empty response.\n" + ", ".join(terms))


# --------------------------------------------------------------------------- fixtures


def synth(case_id, text):
    os.makedirs(FIXTURES, exist_ok=True)
    wav = os.path.join(FIXTURES, f"{case_id}.wav")
    if not os.path.exists(wav):
        aiff = os.path.join(FIXTURES, f"{case_id}.aiff")
        subprocess.run(["say", "-v", "Anna", "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav],
                       check=True)
        os.remove(aiff)
    return wav


def silence_wav(seconds):
    os.makedirs(FIXTURES, exist_ok=True)
    path = os.path.join(FIXTURES, f"silence_{seconds}s.wav")
    if not os.path.exists(path):
        w = wave.open(path, "wb")
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(b"\x00\x00" * int(16000 * seconds)); w.close()
    return path


def duration(wav):
    with wave.open(wav) as w:
        return w.getnframes() / w.getframerate()


# --------------------------------------------------------------------------- requests


def transcribe(model, wav, prompt, terms):
    """One transcription call in the same request shape the app uses for that model family."""
    kind = MODELS[model]
    if kind == "gemini":
        audio = base64.b64encode(open(wav, "rb").read()).decode()
        # The app's default effort is `minimal`, which every tier in MODELS accepts. Pro rejects it
        # with HTTP 400, so the clamp stays here for whoever re-adds Pro to check on Google's fix —
        # otherwise the run would measure a 400 rather than the model. No shipped tier needs it.
        level = "low" if "-pro" in model else "minimal"
        body = json.dumps({
            "contents": [{"parts": [{"text": prompt},
                                    {"inline_data": {"mimeType": "audio/wav", "data": audio}}]}],
            "generationConfig": {"thinkingConfig": {"thinkingLevel": level}, "temperature": 0.0},
        }).encode()
        req = urllib.request.Request(
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            f"?key={os.environ['GEMINI_API_KEY']}",
            data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=90) as r:
            payload = json.load(r)
        parts = ((payload.get("candidates") or [{}])[0].get("content") or {}).get("parts") or []
        return "".join(p.get("text", "") for p in parts if not p.get("thought")).strip()

    if kind == "xai":
        cmd = ["curl", "-sS", "-m", "90", "-X", "POST", "https://api.x.ai/v1/stt",
               "-H", f"Authorization: Bearer {os.environ['XAI_API_KEY']}",
               "-F", f"file=@{wav};type=audio/wav", "-F", "model=grok-stt",
               "-F", f"prompt={prompt}"]
    elif kind == "openai-keywords":
        # gpt-transcribe takes vocabulary via repeated `keywords` parts and ignores instructions
        # in `prompt` — see sendOpenAICompatibleTranscriptionRequest.
        cmd = ["curl", "-sS", "-m", "90", "-X", "POST",
               "https://api.openai.com/v1/audio/transcriptions",
               "-H", f"Authorization: Bearer {os.environ['OPENAI_API_KEY']}",
               "-F", f"file=@{wav};type=audio/wav", "-F", f"model={model}"]
        for t in terms:
            cmd += ["-F", f"keywords={t}"]
    else:
        cmd = ["curl", "-sS", "-m", "90", "-X", "POST",
               "https://api.openai.com/v1/audio/transcriptions",
               "-H", f"Authorization: Bearer {os.environ['OPENAI_API_KEY']}",
               "-F", f"file=@{wav};type=audio/wav", "-F", f"model={model}",
               "-F", f"prompt={prompt}"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return json.loads(out).get("text", "").strip()
    except json.JSONDecodeError:
        raise RuntimeError(out[:200])


# --------------------------------------------------------------------------- suites


def suite_latency(models, prompt, terms, rounds):
    print(f"\n## Latency — {rounds} interleaved rounds, shuffled order, median of successes\n")
    fixtures = [(cid, synth(cid, text)) for cid, text, _ in CASES if cid in ("short", "claude", "long")]
    for cid, wav in fixtures:
        times = collections.defaultdict(list)
        for m in models:                                            # warm-up
            try: transcribe(m, wav, prompt, terms)
            except Exception: pass
        for _ in range(rounds):
            order = list(models); random.shuffle(order)
            for m in order:
                try:
                    import time
                    t0 = time.monotonic()
                    transcribe(m, wav, prompt, terms)
                    times[m].append(time.monotonic() - t0)
                except Exception as e:
                    print(f"  (drop: {m} — {str(e)[:60]})")
        print(f"### {cid} ({duration(wav):.1f} s of audio)")
        for m in sorted(models, key=lambda x: statistics.median(times[x]) if times[x] else 9e9):
            xs = sorted(times[m])
            if not xs:
                print(f"  {m:<24} no successful runs"); continue
            print(f"  {m:<24} median {statistics.median(xs)*1000:7.0f} ms   "
                  f"min {xs[0]*1000:6.0f}   max {xs[-1]*1000:6.0f}   n={len(xs)}")
        print()


def suite_glossary(models, prompt, terms, rounds):
    print(f"\n## Glossary adherence — {rounds} runs per case, terms reproduced verbatim\n")
    hits, total = collections.Counter(), collections.Counter()
    for cid, text, expected in CASES:
        if not expected:
            continue
        wav = synth(cid, text)
        for m in models:
            for _ in range(rounds):
                try:
                    out = transcribe(m, wav, prompt, terms)
                except Exception as e:
                    print(f"  (drop: {m} — {str(e)[:60]})"); continue
                got = [t for t in expected if t in out]
                hits[m] += len(got); total[m] += len(expected)
                missing = [t for t in expected if t not in out]
                if missing:
                    print(f"  MISS {m:<24} {cid}: missing {missing} → {out[:80]!r}")
    print()
    for m in sorted(models, key=lambda x: -(hits[x] / total[x]) if total[x] else 0):
        if total[m]:
            print(f"  {m:<24} {hits[m]}/{total[m]} terms ({100*hits[m]/total[m]:.0f}%)")


def suite_silence(models, prompt, terms, rounds):
    """Silence hallucination, scored through the app's two plausibility gates.

    Reimplements TextProcessingUtility.discardingImplausibleTranscript (drop if
    len > duration*60 + 40) and discardingGlossaryEchoTranscript (drop if len < duration*3 and
    every word is a glossary term), so the verdict is what the *user* would see, not the raw
    model answer. A model that confabulates but always at implausible length is safe in practice;
    one that confabulates at plausible length is not.
    """
    print(f"\n## Silence hallucination — {rounds} runs per duration, scored through the app's gates\n")
    folded = {fold(w) for t in terms for w in re.split(r"[^0-9A-Za-zÀ-ÿ]+", t) if w}
    leaks = collections.Counter()
    for secs in SILENCE_DURATIONS:
        wav = silence_wav(secs)
        for m in models:
            for _ in range(rounds):
                try:
                    out = transcribe(m, wav, prompt, terms).strip()
                except Exception as e:
                    print(f"  (drop: {m} — {str(e)[:60]})"); continue
                if not out:
                    verdict = "empty"
                elif len(out) > secs * 60 + 40:
                    verdict = f"caught by length gate ({len(out)} chars)"
                else:
                    words = [fold(w) for w in re.split(r"[^0-9A-Za-zÀ-ÿ]+", out) if w]
                    if len(out) < secs * 3 and words and all(w in folded for w in words):
                        verdict = f"caught by glossary-echo gate ({len(out)} chars)"
                    else:
                        verdict = f"LEAKS ({len(out)} chars)"
                        leaks[m] += 1
                if verdict != "empty":
                    print(f"  {secs}s {m:<24} {verdict:<40} {out[:60]!r}")
    print()
    for m in models:
        n = rounds * len(SILENCE_DURATIONS)
        print(f"  {m:<24} {leaks[m]}/{n} invented transcripts reached the clipboard")


# --------------------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", choices=["latency", "glossary", "silence", "all"], default="all")
    ap.add_argument("--rounds", type=int, default=None,
                    help="runs per model (default: 10 latency, 3 glossary/silence)")
    ap.add_argument("--models", help="comma-separated subset of the model IDs")
    ap.add_argument("--seed", type=int, default=0, help="RNG seed for the shuffled round order")
    args = ap.parse_args()

    load_env()
    random.seed(args.seed)
    models = args.models.split(",") if args.models else list(MODELS)
    unknown = [m for m in models if m not in MODELS]
    if unknown:
        sys.exit(f"unknown model(s): {unknown}. Known: {', '.join(MODELS)}")

    missing = {"gemini": "GEMINI_API_KEY", "xai": "XAI_API_KEY"}
    needed = {missing.get(MODELS[m], "OPENAI_API_KEY") for m in models}
    absent = [k for k in needed if not os.environ.get(k)]
    if absent:
        sys.exit(f"missing key(s) in .env: {', '.join(absent)}")

    dictation, glossary, prompt_source = user_prompts()
    terms = glossary_terms(glossary)
    prompt = build_prompt(dictation, terms)
    print(f"# Transcription benchmark\n\nmodels: {', '.join(models)}\n"
          f"prompt/glossary source: {prompt_source}\n"
          f"glossary: {len(terms)} terms")
    if not terms:
        print("\nWARNING: no glossary terms — the adherence and silence suites are measuring "
              "against a generic prompt and will understate both problems.")

    if args.suite in ("latency", "all"):
        suite_latency(models, prompt, terms, args.rounds or 10)
    if args.suite in ("glossary", "all"):
        suite_glossary(models, prompt, terms, args.rounds or 3)
    if args.suite in ("silence", "all"):
        suite_silence(models, prompt, terms, args.rounds or 3)


if __name__ == "__main__":
    main()
