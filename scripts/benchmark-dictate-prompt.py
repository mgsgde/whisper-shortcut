#!/usr/bin/env python3
"""Dictate Prompt benchmark: does the audio-chat model actually obey the editing rules?

The transcription benchmark cannot answer this — Dictate Prompt is a different path entirely
(chat completions with an inline `input_audio` part, the user's Dictate Prompt system prompt,
and the clipboard text as context). What matters here is not word accuracy but rule compliance:
the system prompt forbids formalizing casual text, forbids turning prose into bullet lists,
forbids answering questions found in the selection, and forbids appending the spoken instruction
to the output. Every one of those is a real failure this app has shipped at some point.

Each case pairs a *selected text* with a *spoken instruction* (synthesised with `say`, so the
model gets real audio like it would from the user) and a scorer that checks the specific rule.

    python3 scripts/benchmark-dictate-prompt.py
    python3 scripts/benchmark-dictate-prompt.py --models gpt-audio,gpt-audio-1.5 --rounds 3

Scoring is deliberately conservative: a case only counts as failed when the rule is
unambiguously broken, so a low score means something real rather than a strict grader.
"""
import argparse, base64, collections, json, os, re, subprocess, sys, time, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "build", "benchmark-fixtures", "dictate-prompt")
DEFAULT_MODELS = ["gpt-audio", "gpt-audio-1.5", "gpt-audio-mini"]
CLIPBOARD_HEADER = "SELECTED TEXT FROM CLIPBOARD (apply the voice instruction to this text):"


def load_env():
    path = os.path.join(REPO, ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


# SpeechService appends this to every Dictate Prompt system prompt at runtime
# (`buildPromptModeSystemPrompt` → `base + AppConstants.promptModeOutputRule`). Leaving it out
# makes the benchmark measure a prompt the app never sends — and this rule is precisely the one
# that forbids the append-instead-of-edit and meta-output failures being scored here. Keep in sync
# with AppConstants.promptModeOutputRule.
PROMPT_MODE_OUTPUT_RULE = (
    "\n\nCRITICAL – Output format: Return ONLY the edited/transformed text (the result of applying "
    "the voice instruction to the selected text). Never return the original selected text with the "
    "user's spoken words appended; the voice is a command to edit, not dictation to add. No "
    "meta-information, no explanations, no preamble (e.g. \"Here is...\"), no closing phrases. No "
    "decorative markdown (**bold**, # headers); bullet points with leading dash and space (- ) are "
    "allowed—use spaces to indent sub-bullets. Just the plain result that the user can paste "
    "directly.")


def system_prompt():
    """The user's Dictate Prompt system prompt, or the snapshot the transcription benchmark keeps."""
    for path in (
        os.path.expanduser("~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/"
                           "Application Support/WhisperShortcut/UserContext/system-prompts.md"),
        os.path.join(REPO, "build", "benchmark-fixtures", "system-prompts-snapshot.md"),
    ):
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        section, buf = None, []
        for line in text.splitlines(keepends=True):
            if line.startswith("==="):
                if section and "Dictate Prompt" in section:
                    break
                section = line.strip()
                buf = []
                continue
            if section and "Dictate Prompt" in section:
                buf.append(line)
        if buf:
            return "".join(buf).strip() + PROMPT_MODE_OUTPUT_RULE, os.path.basename(path)
    return ("You are a text editing assistant that applies voice instructions to selected text."
            + PROMPT_MODE_OUTPUT_RULE), "built-in fallback"


# (id, selected text, spoken instruction, scorer(output, selected) -> None if OK else reason)
def _not_formalized(out, sel):
    if re.search(r"\bIch habe\b", out) or re.search(r"\bes ist wirklich\b", out, re.I):
        return "formalized the casual register"
    if len(out) > len(sel) * 1.6:
        return f"rewrote instead of correcting ({len(out)} vs {len(sel)} chars)"
    return None


def _no_bullets(out, sel):
    bullets = [l for l in out.splitlines() if re.match(r"^\s*[-*•]\s+|^\s*\d+[.)]\s+", l)]
    return f"turned prose into {len(bullets)} bullet(s)" if bullets else None


def _no_answer(out, sel):
    if re.search(r"\b(ja|nein|yes|no)\b[,.! ]", out.strip()[:40], re.I):
        return "answered the question in the selection"
    if "?" not in out:
        return "dropped the question instead of just polishing it"
    return None


def _is_english(out, sel):
    german = re.findall(r"\b(der|die|das|und|ich|nicht|ist|mit|für|auch|noch)\b", out, re.I)
    return f"output still looks German ({len(german)} marker words)" if len(german) > 2 else None


def _is_shorter(out, sel):
    return None if len(out) < len(sel) else f"not shorter ({len(out)} vs {len(sel)} chars)"


def _no_instruction_echo(out, sel):
    if re.search(r"korrigiere|mach das kürzer|übersetze", out, re.I):
        return "echoed the spoken instruction into the output"
    return None


def _keeps_english(out, sel):
    """Language rule: a German *instruction* is a command, not a target language. English stays
    English. This is the rule the system prompt spells out most explicitly, because getting it
    wrong silently translates a message the user is about to send."""
    german = re.findall(r"\b(der|die|das|und|ich|nicht|ist|mit|für|wurde|weil)\b", out, re.I)
    return f"translated English text into German ({len(german)} marker words)" if len(german) > 2 else None


def _keeps_wrong_fact(out, sel):
    """Fact-integrity rule: never 'fix' a factual claim, even a wrong one. The selection says the
    30th of February — a model that corrects it rewrites a statement the user meant to send."""
    if "30. Februar" not in out and "30.2" not in out and "30. 2." not in out:
        return "altered the (deliberately wrong) date instead of leaving it alone"
    return None


def _keeps_emoji_and_casing(out, sel):
    if "🎉" not in out:
        return "dropped the emoji"
    if out.strip()[:1].isupper() and sel.strip()[:1].islower():
        return "capitalised a deliberately lowercase message"
    return None


def _edited_not_appended(out, sel):
    """The failure the system prompt's very first rule exists for: treating the spoken instruction
    as dictation and gluing it onto the selection instead of applying it."""
    if "später" in out.lower() and sel.lower() not in out.lower():
        return None
    if sel.strip() in out and len(out) > len(sel) * 1.05:
        return "appended to the selection instead of editing it"
    return None


CASES = [
    ("german-instruction-english-text",
     "just wanted to let you know the deploy went through, everything looks stable so far",
     "Korrigiere die Rechtschreibung.",
     [_keeps_english]),
    ("dont-fix-facts",
     "Der Termin findet am 30. Februar statt, bitte trag ihn dir ein.",
     "Korrigiere.",
     [_keeps_wrong_fact]),
    ("preserve-tone",
     "yes!! endlich läuft der build durch 🎉 hat nur 3 tage gedauert",
     "Korrigiere.",
     [_keeps_emoji_and_casing]),
    ("edit-not-append",
     "Hallo Anna, ich komme morgen gegen neun Uhr vorbei.",
     "Schreib dazu, dass ich später komme.",
     [_edited_not_appended]),
    ("correct-casual",
     "hab das mal ausprobiert, is echt schnell und funktioniert auch offline",
     "Korrigiere.",
     [_not_formalized, _no_instruction_echo]),
    ("reformat-prose",
     "Die neue Pipeline schneidet die Aufnahme in Abschnitte.   Danach werden die Teiltranskripte "
     "wieder zusammengefügt.\n\n  Das halbiert die Wartezeit.",
     "Formatiere neu.",
     [_no_bullets]),
    ("dont-answer",
     "Ich wollte nochmal nachfragen: der Termin ist doch am Dienstag, oder ist das falsch?",
     "Korrigiere die Rechtschreibung.",
     [_no_answer, _no_instruction_echo]),
    ("translate",
     "Ich habe gestern die Chunk-Transkription umgebaut, weil die Latenz zu hoch war.",
     "Übersetze das ins Englische.",
     [_is_english]),
    ("shorten",
     "Ich wollte dir nur ganz kurz Bescheid geben, dass ich den Termin, den wir eigentlich für "
     "morgen früh geplant hatten, leider nicht wahrnehmen kann, weil mir etwas dazwischengekommen "
     "ist, das sich nicht verschieben lässt.",
     "Mach das kürzer.",
     [_is_shorter, _no_instruction_echo]),
]


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


def unwrap_json_edit(text, selected):
    """Mirror of TextProcessingUtility.unwrappingJSONEditResponse.

    The benchmark has to score what the *user* ends up with, not the raw model reply — otherwise
    it keeps reporting a defect the app already neutralises. Keep in sync with the Swift version
    (and with JSONEditResponseTests, which pins the edge cases)."""
    t = text.strip()
    if not (t.startswith("{") and t.endswith("}")):
        return text
    try:
        obj = json.loads(t)
    except json.JSONDecodeError:
        return text
    if not isinstance(obj, dict):
        return text
    for key in ("text", "edited_text", "final_text", "result", "output", "content", "edited"):
        v = obj.get(key)
        if isinstance(v, str) and v.strip():
            return v
    tokens = ("text", "result", "output", "content", "edit", "final", "response")
    meta = ("type", "kind", "action", "operation", "mode", "reason")
    cands = [(v, k) for k, v in obj.items()
             if isinstance(v, str) and v.strip()
             and any(t in k.lower() for t in tokens)
             and not any(m in k.lower() for m in meta)]
    if cands:
        return max(cands, key=lambda kv: (len(kv[0]), kv[1]))[0]
    edits, sel = obj.get("edits"), (selected or "").strip()
    if not isinstance(edits, list) or not edits:
        return text
    # Single bare string, or a single edit whose replacement is long enough to be the whole
    # rewrite (index-based edits land here — LLM offsets are not trustworthy).
    if len(edits) == 1:
        lone = edits[0] if isinstance(edits[0], str) else None
        if lone is None and isinstance(edits[0], dict):
            lone = edits[0].get("replacement") or edits[0].get("new") or edits[0].get("text")
        if isinstance(lone, str) and lone.strip() and len(lone.strip()) >= len(sel) // 2:
            found = edits[0].get("find") or edits[0].get("original") if isinstance(edits[0], dict) else None
            if not (isinstance(found, str) and found in sel):
                return lone.strip()
    if not sel:
        return text
    result = sel
    for e in edits:
        if not isinstance(e, dict):
            return text
        find = e.get("find") or e.get("original")
        repl = e.get("replacement") or e.get("new") or e.get("text")
        if not isinstance(find, str) or not isinstance(repl, str) or find not in result:
            return text
        result = result.replace(find, repl)
    return result


def run(model, wav, selected, sys_prompt):
    """Mirrors SpeechService.promptWithOpenAI: system prompt, clipboard header + text, audio."""
    audio = base64.b64encode(open(wav, "rb").read()).decode()
    body = json.dumps({
        "model": model,
        "modalities": ["text"],
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": [
                {"type": "text", "text": f"{CLIPBOARD_HEADER}\n{selected}"},
                {"type": "input_audio", "input_audio": {"data": audio, "format": "wav"}},
            ]},
        ],
    }).encode()
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=120) as r:
        payload = json.load(r)
    elapsed = time.monotonic() - t0
    raw = (payload["choices"][0]["message"]["content"] or "").strip()
    # Score post-processing, the way the app delivers it to the clipboard.
    return unwrap_json_edit(raw, selected).strip(), elapsed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default=",".join(DEFAULT_MODELS))
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--cases", help="comma-separated case ids to run (default: all)")
    args = ap.parse_args()
    selected_cases = set(args.cases.split(",")) if args.cases else None
    load_env()
    if not os.environ.get("OPENAI_API_KEY"):
        sys.exit("missing OPENAI_API_KEY in .env")

    models = args.models.split(",")
    sys_prompt, source = system_prompt()
    print(f"# Dictate Prompt benchmark\n\nmodels: {', '.join(models)}\n"
          f"system prompt source: {source} ({len(sys_prompt)} chars)\n"
          f"rounds: {args.rounds} per case\n")

    passed, total = collections.Counter(), collections.Counter()
    times = collections.defaultdict(list)
    errors = collections.Counter()
    for case_id, selected, instruction, scorers in CASES:
        if selected_cases and case_id not in selected_cases:
            continue
        wav = synth(case_id, instruction)
        print(f"### {case_id} — spoken: \"{instruction}\"")
        for model in models:
            for _ in range(args.rounds):
                try:
                    out, elapsed = run(model, wav, selected, sys_prompt)
                except Exception as e:                                   # noqa: BLE001
                    errors[model] += 1
                    print(f"  ERR  {model:<16} {type(e).__name__}: {str(e)[:70]}")
                    continue
                times[model].append(elapsed)
                reasons = [r for s in scorers if (r := s(out, selected))]
                total[model] += 1
                if reasons:
                    print(f"  FAIL {model:<16} {'; '.join(reasons)}")
                    print(f"       → {out[:110]!r}")
                else:
                    passed[model] += 1
        print()

    print("## Summary\n")
    for model in models:
        if not total[model]:
            print(f"  {model:<16} no successful calls ({errors[model]} errors)")
            continue
        med = sorted(times[model])[len(times[model]) // 2]
        print(f"  {model:<16} {passed[model]}/{total[model]} rule checks passed "
              f"({100*passed[model]/total[model]:.0f}%)   median {med*1000:.0f} ms"
              + (f"   {errors[model]} request errors" if errors[model] else ""))


if __name__ == "__main__":
    main()
