#!/usr/bin/env python3
"""Python port of the deterministic `dictation_candidates` generator.

Spec (single source of truth, shared with the Swift app): plans/active/improve-dictation-candidates.md
Pure module: no data, no paths to private data. `python3 scripts/dictation_candidates.py --self-test`
runs the spec's shared test vectors and the cologne() checks.
"""
import bisect
import os
import re
import subprocess
import sys
import unicodedata
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from functools import lru_cache

MAX_CANDIDATES = 5
RANK = {"self_complaint": 1, "glossary_not_working": 2, "typed_correction": 3, "retry_diff": 4,
        "sounds_like_known": 5, "spelling_variants": 6, "unknown_recurring": 7}
BASE_SCORE = {"self_complaint": 1000, "glossary_not_working": 800, "typed_correction": 500, "retry_diff": 300,
              "spelling_variants": 100, "unknown_recurring": 0}

PRODUCT_VOCABULARY = [
    "Claude", "Claude Code", "Anthropic", "OpenAI", "ChatGPT", "Codex", "Gemini", "Google", "Grok", "xAI",
    "Cursor", "Copilot", "GitHub", "GitLab", "Perplexity", "Mistral", "Llama", "Ollama", "DeepSeek", "Qwen",
    "Whisper", "WhisperShortcut", "Parakeet", "Xcode", "Swift", "Python", "JavaScript", "TypeScript", "Slack",
    "Notion", "Figma", "Supabase", "Vercel", "Docker", "Kubernetes", "Firebase", "Hugging Face", "LangChain",
    "Midjourney", "ElevenLabs", "WhatsApp", "Telegram", "Zoom", "Linear", "Jira", "Obsidian", "Raycast",
    "Homebrew",
]

STOPWORDS = set("""ich du er sie es wir ihr mir mich dir dich uns euch ihm ihn ihnen das der die den dem des ein eine
einen einem einer und oder aber also doch nicht noch auch nur schon mal ja nee nein okay ok gut bitte danke warum
wieso weshalb was wer wie wo wann welche welcher welches kannst koennen konnen kann soll sollen sollte muss musst
wird werden wurde ist sind war hat habe haben hast gibt mach mache machen dann wenn weil dass damit hier dort jetzt
heute morgen frau herr herrn dr prof hallo hey hi liebe lieber the and but this that what why how who when where
which can could would should will please thanks hello okay yes also just then there here today tomorrow mr mrs ms
dear""".split())

COMPLAINT_RE = re.compile(
    r"falsch (geschrieben|erkannt|transkribiert|diktiert)|schreibt man|heißt nicht|richtig geschrieben"
    r"|schreibweise|buchstabier|(wrong(ly)?|incorrectly) (spelled|transcribed)"
    r"|spelled (wrong|incorrectly)|misspell(ed|s)?", re.I)
REPEAT_RE = re.compile(r"\b([^\W\d_]{3,})\b,?\s+nicht\s+\1\b", re.I)
PHONETIC_PAIRS = {frozenset(p) for p in ("sz", "ck", "vw", "fv", "bp", "dt", "gk")}

INFLECTIONAL_ENDINGS = {"e", "n", "en", "s", "es", "er", "ern", "nen"}
MIN_LENGTH_FOR_TWO_EDITS = 8
TYPED_TAGS = ("<typed_by_user>", "</typed_by_user>", "<pasted_content>", "</pasted_content>")

HERE = os.path.dirname(os.path.abspath(__file__))
ORACLE_SRC = os.path.join(HERE, "spell_oracle.swift")
ORACLE_BIN = os.path.expanduser("~/.cache/whisper-shortcut/spell_oracle")


# ---------------------------------------------------------------- text helpers
def tokens(text):
    return re.findall(r"[^\W_]+", text or "")


@lru_cache(maxsize=None)
def fold(s):
    n = unicodedata.normalize("NFD", s)
    return "".join(c for c in n if unicodedata.category(c) != "Mn").lower()


def compact(s):
    return "".join(ch for ch in s.lower() if ch.isalnum())


def is_name_like(t):
    if len(t) < 4 or fold(t) in STOPWORDS:
        return False
    return t[0].isupper() or any(c.isdigit() for c in t) or any(c.isupper() for c in t[1:])


def is_complaint_name(t):
    """Relaxed name-likeness for self_complaint: len >= 3, first-uppercase is enough (may be a known word)."""
    if len(t) < 3 or fold(t) in STOPWORDS:
        return False
    return t[0].isupper() or any(c.isdigit() for c in t) or any(c.isupper() for c in t[1:])


@lru_cache(maxsize=None)
def cologne(s):
    f = fold(s).replace("ß", "s")
    letters = [c for c in f if "a" <= c <= "z"]
    codes = []
    for i, c in enumerate(letters):
        prev = letters[i - 1] if i > 0 else ""
        nxt = letters[i + 1] if i + 1 < len(letters) else ""
        if c in "aeijouy":
            code = "0"
        elif c == "h":
            continue
        elif c == "b":
            code = "1"
        elif c == "p":
            code = "3" if nxt == "h" else "1"
        elif c in "dt":
            code = "8" if nxt in ("c", "s", "z") else "2"
        elif c in "fvw":
            code = "3"
        elif c in "gkq":
            code = "4"
        elif c == "c":
            if i == 0:
                code = "4" if nxt in ("a", "h", "k", "l", "o", "q", "r", "u", "x") else "8"
            elif prev in ("s", "z"):
                code = "8"
            else:
                code = "4" if nxt in ("a", "h", "k", "o", "q", "u", "x") else "8"
        elif c == "x":
            code = "8" if prev in ("c", "k", "q") else "48"
        elif c == "l":
            code = "5"
        elif c in "mn":
            code = "6"
        elif c == "r":
            code = "7"
        elif c in "sz":
            code = "8"
        else:
            continue
        codes.append(code)
    seq = "".join(codes)
    out = []
    for ch in seq:
        if not out or out[-1] != ch:
            out.append(ch)
    seq = "".join(out)
    return seq[:1] + seq[1:].replace("0", "") if seq else ""


def levenshtein(a, b, limit):
    """Edit distance if <= limit else None (GlossaryFastLearner.levenshtein)."""
    if abs(len(a) - len(b)) > limit:
        return None
    if not a or not b:
        d = max(len(a), len(b))
        return d if d <= limit else None
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        row_min = cur[0]
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            row_min = min(row_min, cur[j])
        if row_min > limit:
            return None
        prev = cur
    return prev[len(b)] if prev[len(b)] <= limit else None


def is_inflectional_variant(a, b):
    if a == b:
        return False
    shorter, longer = (a, b) if len(a) <= len(b) else (b, a)
    return longer.startswith(shorter) and longer[len(shorter):] in INFLECTIONAL_ENDINGS


@lru_cache(maxsize=None)
def lev_close(a, b):
    fa, fb = fold(a), fold(b)
    if fa == fb or not fa or not fb or fa[0] != fb[0]:
        return False
    if is_inflectional_variant(fa, fb):
        return False
    limit = 2 if min(len(fa), len(fb)) >= MIN_LENGTH_FOR_TWO_EDITS else 1
    return levenshtein(fa, fb, limit) is not None


@lru_cache(maxsize=None)
def close(a, b):
    if lev_close(a, b):
        return True
    fa, fb = fold(a), fold(b)
    if fa == fb or not fa or not fb or is_inflectional_variant(fa, fb):
        return False
    if len(fa) < 5 or len(fb) < 5 or abs(len(fa) - len(fb)) > 2:
        return False
    ca = cologne(a)
    if not ca or ca != cologne(b):
        return False
    return fa[:2] == fb[:2] or frozenset((fa[0], fb[0])) in PHONETIC_PAIRS


def first_char_peers(ch):
    """First chars a `close` partner may start with: the same char or a phonetic pair partner."""
    out = {ch}
    for p in PHONETIC_PAIRS:
        if ch in p:
            out |= p
    return out


# ---------------------------------------------------------------- glossary
def split_terms(text):
    text = re.sub(r"^\s*Terms:\s*", "", text or "")
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch in ",\n" and depth == 0:
            if cur.strip():
                out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_glossary(text):
    """-> (heads [original], rejected [original])"""
    heads, rejected = [], []
    for entry in split_terms(text):
        entry = re.sub(r"^\s*Terms:\s*", "", entry)
        head, _, rest = entry.partition(" (not ")
        head = head.strip()
        if head:
            heads.append(head)
        rejected += re.findall(r"[\"“„]([^\"”“„]*)[\"”“]", rest)
    return heads, [r.strip() for r in rejected if r.strip()]


# ---------------------------------------------------------------- spell oracle
class OracleChecker:
    def __init__(self, path):
        self.path = path
        self.cache = {}
        self.sent = 0

    def prefetch(self, words):
        todo = sorted({w for w in words if w not in self.cache})
        if not todo:
            return
        out = subprocess.run([self.path], input="\n".join(todo) + "\n", capture_output=True, text=True,
                             check=True).stdout.split("\n")
        if len(out) < len(todo):
            raise RuntimeError("spell oracle returned too few lines")
        for w, v in zip(todo, out):
            self.cache[w] = v.strip() == "1"
        self.sent += len(todo)

    def __call__(self, word):
        if word not in self.cache:
            self.prefetch([word])
        return self.cache[word]


_CHECKER = None


def spell_oracle_checker():
    """Cached batch-capable is_known_word backed by scripts/spell_oracle.swift (compiled with swiftc once)."""
    global _CHECKER
    if _CHECKER is None:
        stale = (not os.path.exists(ORACLE_BIN)) or os.path.getmtime(ORACLE_SRC) > os.path.getmtime(ORACLE_BIN)
        if stale:
            os.makedirs(os.path.dirname(ORACLE_BIN), exist_ok=True)
            subprocess.run(["swiftc", "-O", ORACLE_SRC, "-o", ORACLE_BIN], check=True)
        _CHECKER = OracleChecker(ORACLE_BIN)
    return _CHECKER


# ---------------------------------------------------------------- input preparation
def parse_ts(s):
    if isinstance(s, datetime):
        return s if s.tzinfo else s.replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _collapse(s):
    return " ".join(fold(s).split())


def _prepare_rows(rows, now, window_days):
    lo = now - timedelta(days=window_days)
    win = []
    for r in rows:
        try:
            t = parse_ts(r["ts"])
        except Exception:
            continue
        if lo <= t <= now:
            win.append((t, r))
    win.sort(key=lambda x: x[0])
    trans = [(t, r) for t, r in win if r.get("mode") == "transcription" and r.get("result")]
    trans_times = [t for t, _ in trans]
    trans_folded = [_collapse(r["result"]) for _, r in trans]
    prepared = []  # dict(ts, kind, text, toks, folds)
    for t, r in win:
        mode = r.get("mode")
        if mode == "transcription":
            text, kind = r.get("result") or "", "dictated"
        elif mode == "prompt":
            text, kind = r.get("userInstruction") or "", "dictated"
        elif mode == "geminiChat":
            text = r.get("userInstruction") or ""
            for tag in TYPED_TAGS:
                text = text.replace(tag, "")
            text, kind = text.strip(), "typed"
            if kind == "typed" and text:
                key = _collapse(text)
                a = bisect.bisect_left(trans_times, t - timedelta(seconds=180))
                b = bisect.bisect_right(trans_times, t + timedelta(seconds=180))
                if any(key and key in trans_folded[i] for i in range(a, b)):
                    continue
        else:
            continue
        if not text.strip():
            continue
        toks = tokens(text)
        prepared.append({"ts": r["ts"], "t": t, "kind": kind, "text": text, "toks": toks,
                         "folds": [fold(x) for x in toks]})
    return prepared, trans


def _sentences(text):
    out, cur = [], []
    for i, ch in enumerate(text):
        if ch in "!?\n":
            out.append("".join(cur)); cur = []
        elif ch == ".":
            m = re.search(r"([A-Za-z]+)$", "".join(cur))
            if m and m.group(1) in ("Dr", "Fr", "Hr", "St"):
                cur.append(ch)
            else:
                out.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return [s for s in out if s.strip()]


# ---------------------------------------------------------------- compute
def compute(rows, signals, glossary, history, app_names, is_known_word, now=None, window_days=7):
    now = parse_ts(now) if now is not None else datetime.now(timezone.utc)
    prep, trans = _prepare_rows(rows, now, window_days)
    dictated = [p for p in prep if p["kind"] == "dictated"]
    typed = [p for p in prep if p["kind"] == "typed"]

    heads, rejected = parse_glossary(glossary)
    head_folds = {fold(h) for h in heads}
    glossary_tokens = {fold(t) for h in heads for t in tokens(h)}
    rejected_folds = {fold(r) for r in rejected}
    removed_lines = [x for h in history for x in h.get("removed", [])]
    removed_tokens = set()
    for line in removed_lines:
        removed_tokens |= {fold(t) for t in tokens(line) if len(t) >= 3}
    app_names = sorted({a for a in app_names if a})

    # distinct folded tokens per dictated row
    row_sets = [set(p["folds"]) for p in dictated]
    folded_rows = Counter()           # fold -> #dictated rows
    exact_rows = Counter()            # exact token -> #dictated rows
    orig_by_fold = defaultdict(Counter)
    for p in dictated:
        for tk in set(p["toks"]):
            exact_rows[tk] += 1
        for tk, f in set(zip(p["toks"], p["folds"])):
            orig_by_fold[f][tk] += 1
        for f in set(p["folds"]):
            folded_rows[f] += 1
    distinct_tokens = sorted(orig_by_fold)  # folded
    name_like = sorted({tk for p in dictated for tk in p["toks"] if is_name_like(tk)})

    # bulk spell prefetch: name-like tokens first
    if hasattr(is_known_word, "prefetch"):
        is_known_word.prefetch({tk for p in prep for tk in p["toks"]})
        is_known_word.prefetch(set(name_like) | {tk for p in typed for tk in p["toks"] if is_name_like(tk)})

    hits = []  # (heard, suggested, source, row_ts, extra dict)

    def add(heard, suggested, source, ts, also=None, glossary_target=False):
        hits.append({"heard": heard, "suggested": suggested, "source": source, "ts": ts,
                     "also": also or [], "gt": glossary_target})

    # 1. self_complaint
    def suggest(pick):
        ch = [h for h in heads if close(pick, h)]
        return ch[0] if len(ch) == 1 else None
    for p in dictated + typed:
        for sent in _sentences(p["text"]):
            m = REPEAT_RE.search(sent)
            if m:
                w = m.group(1)
                if fold(w) not in STOPWORDS and (not is_known_word(w) or any(close(w, h) for h in heads)):
                    add(w, suggest(w), "self_complaint", p["ts"])
                continue
            m = COMPLAINT_RE.search(sent)
            if not m:
                continue
            toks = [(mt.group(0), mt.start(), mt.end()) for mt in re.finditer(r"[^\W_]+", sent)]
            before = [t for t in toks if t[2] <= m.start() and is_complaint_name(t[0])]
            after = [t for t in toks if t[1] >= m.end() and is_complaint_name(t[0])]
            pick = before[-1][0] if before else (after[0][0] if after else None)
            if pick is None:
                continue
            sug = suggest(pick)
            if is_known_word(pick) and not any(close(pick, h) for h in heads):
                continue
            add(pick, sug, "self_complaint", p["ts"])

    # 2. glossary_not_working
    ann = {}  # folded rejected spelling -> (ts, head, original)
    for hrow in history:
        for line in hrow.get("added", []):
            head, _, rest = line.partition(" (not ")
            for rej in re.findall(r"[\"“„]([^\"”“„]*)[\"”“]", rest):
                k = fold(rej.strip())
                t = parse_ts(hrow["ts"])
                if k and (k not in ann or t >= ann[k][0]):
                    ann[k] = (t, re.sub(r"^\s*Terms:\s*", "", head).strip(), rej.strip())
    cur_rejected = {fold(r) for r in rejected}
    for k, (t, head, orig) in ann.items():
        if k not in cur_rejected:
            continue
        kt = [fold(x) for x in tokens(orig)]
        rs = [p for p in dictated if p["t"] > t and any(
            p["folds"][i:i + len(kt)] == kt for i in range(len(p["folds"]) - len(kt) + 1))]
        if len(rs) >= 2:
            for p in rs:
                add(orig, head, "glossary_not_working", p["ts"])
                hits[-1]["gnw_rows"] = [q["ts"] for q in rs]

    # 3. typed_correction
    for p in typed:
        for ty in dict.fromkeys(tk for tk in p["toks"] if len(tk) >= 4 and tk[0].isupper()):
            if fold(ty) in glossary_tokens:
                continue
            best, best_count = None, -1
            for d in name_like:
                if d == ty or not lev_close(ty, d):
                    continue
                if is_known_word(ty) and is_known_word(d):
                    continue
                c = exact_rows.get(d, 0)
                if c > best_count:
                    best, best_count = d, c
            if best is not None and exact_rows.get(ty, 0) < best_count:
                add(best, ty, "typed_correction", p["ts"])

    # 4. retry_diff
    by_ts = {r["ts"]: i for i, (_, r) in enumerate(trans)}
    prep_by_ts = {p["ts"]: p for p in dictated}
    for sg in signals or []:
        if sg.get("kind") != "dictationRestart":
            continue
        ref = sg.get("refTs")
        if ref not in by_ts:
            continue
        i = by_ts[ref]
        if i + 1 >= len(trans):
            continue
        ta, ra = trans[i]
        tb, rb = trans[i + 1]
        if (tb - ta).total_seconds() > 120:
            continue
        pa, pb = prep_by_ts.get(ra["ts"]), prep_by_ts.get(rb["ts"])
        if not pa or not pb:
            continue
        fa, fb = set(pa["folds"]), set(pb["folds"])
        for a in dict.fromkeys(tk for tk in pa["toks"] if is_name_like(tk)):
            if fold(a) in fb:
                continue
            bs = [b for b in dict.fromkeys(pb["toks"]) if len(b) >= 4 and fold(b) not in fa and close(a, b)
                  and not (is_known_word(a) and is_known_word(b))]
            if bs:
                add(a, bs[0], "retry_diff", ra["ts"])

    # 5. sounds_like_known
    targets = {}
    for h in heads:
        targets.setdefault(fold(h), (h, True))
    for v in PRODUCT_VOCABULARY + app_names:
        targets.setdefault(fold(v), (v, False))
        if fold(v) in head_folds:
            targets[fold(v)] = (targets[fold(v)][0], True)
    by_first = defaultdict(list)
    for f in distinct_tokens:
        by_first[f[:1]].append(f)
    # bigram index
    bigram_rows = defaultdict(set)
    for ri, p in enumerate(dictated):
        for a, b in zip(p["folds"], p["folds"][1:]):
            bigram_rows[(a, b)].add(ri)
    folded_to_original = {f: min(orig_by_fold[f].items(), key=lambda kv: (-kv[1], kv[0]))[0] for f in orig_by_fold}
    single_pending = []  # (t_folded, V, is_head)
    bigram_pending = []
    for fv, (v, is_head) in targets.items():
        vt = tokens(v)
        if len(vt) == 1 and len(vt[0]) >= 4:
            for f in (x for c in sorted(first_char_peers(fv[:1])) for x in by_first.get(c, [])):
                if f == fv or folded_rows[f] < 2:
                    continue
                if close(folded_to_original[f], v):
                    single_pending.append((f, v, is_head))
        elif len(vt) == 2:
            f1, f2 = fold(vt[0]), fold(vt[1])
            vkey = (f1, f2)
            c1s = [f for c in sorted(first_char_peers(f1[:1])) for f in by_first.get(c, []) if f == f1 or close(f, vt[0])]
            c2s = [f for c in sorted(first_char_peers(f2[:1])) for f in by_first.get(c, []) if f == f2 or close(f, vt[1])]
            for a in c1s:
                for b in c2s:
                    if (a, b) == vkey or (a, b) not in bigram_rows:
                        continue
                    rs = bigram_rows[(a, b)]
                    if len(rs) >= 2:
                        bigram_pending.append(((a, b), v, is_head, rs))
    if hasattr(is_known_word, "prefetch"):
        is_known_word.prefetch({folded_to_original[f] for f, _, _ in single_pending})
    for f, v, is_head in single_pending:
        t = folded_to_original[f]
        if is_known_word(t):
            continue
        for ri, p in enumerate(dictated):
            if f in row_sets[ri]:
                add(t, v, "sounds_like_known", p["ts"], glossary_target=is_head)
    for (a, b), v, is_head, rs in bigram_pending:
        heard = folded_to_original[a] + " " + folded_to_original[b]
        for ri in rs:
            add(heard, v, "sounds_like_known", dictated[ri]["ts"], glossary_target=is_head)

    # 6/7. spelling_variants, unknown_recurring
    def best_spelling(counter, only_name_like=False):
        """Most frequent spelling (distinct rows), ties to the smaller string."""
        items = [(tk, n) for tk, n in counter.items() if not only_name_like or is_name_like(tk)]
        return min(items, key=lambda kv: (-kv[1], kv[0]))[0] if items else None
    unknown_by_fold = {}  # the spelling judged is the most frequent name-like one (the one shown)
    for f in sorted(orig_by_fold):
        rep = best_spelling(orig_by_fold[f], True)
        if rep is None:
            continue
        if is_known_word(rep):  # fallback: the most frequent unknown name-like spelling with >= 2 rows
            alts = {tk: n for tk, n in orig_by_fold[f].items() if n >= 2 and is_name_like(tk) and not is_known_word(tk)}
            rep = best_spelling(alts) if alts else None
        if rep is not None:
            unknown_by_fold[f] = rep
    ufolds = sorted(unknown_by_fold)
    row_of_fold = defaultdict(list)
    for ri, p in enumerate(dictated):
        for f in set(p["folds"]):
            if f in unknown_by_fold:
                row_of_fold[f].append(ri)
    parent = {f: f for f in ufolds}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    buckets = defaultdict(list)
    for f in ufolds:
        buckets[f[:1]].append(f)
    for c1, c2 in [(x, y) for x in buckets for y in buckets if x <= y and y in first_char_peers(x)]:
        fs1, fs2 = buckets[c1], buckets[c2]
        for i, a in enumerate(fs1):
            for b in (fs1[i + 1:] if c1 == c2 else fs2):
                if close(unknown_by_fold[a], unknown_by_fold[b]):
                    parent[find(a)] = find(b)
    groups = defaultdict(list)
    for f in ufolds:
        groups[find(f)].append(f)
    for members in groups.values():
        if len(members) < 2:
            continue
        rs = sorted({ri for f in members for ri in row_of_fold[f]})
        if len(rs) < 3:
            continue
        members.sort(key=lambda f: (-len(row_of_fold[f]), unknown_by_fold[f]))
        mostf = {f: unknown_by_fold[f] for f in members}
        for ri in rs:
            add(mostf[members[0]], None, "spelling_variants", dictated[ri]["ts"],
                also=[mostf[f] for f in members[1:]])
    for f in ufolds:
        if len(row_of_fold[f]) >= 3:
            for ri in row_of_fold[f]:
                add(unknown_by_fold[f], None, "unknown_recurring", dictated[ri]["ts"])

    # ---- merge, filter, rank
    all_prep = prep
    index = defaultdict(set)
    for ri, p in enumerate(all_prep):
        for f in set(p["folds"]):
            index[f].add(ri)

    def containing(heard):
        hf = [fold(x) for x in tokens(heard)]
        if not hf:
            return []
        rs = set.intersection(*[index.get(f, set()) for f in hf])
        if len(hf) == 1:
            return sorted(rs)
        out = []
        for ri in rs:
            fs = all_prep[ri]["folds"]
            if any(fs[i:i + len(hf)] == hf for i in range(len(fs) - len(hf) + 1)):
                out.append(ri)
        return sorted(out)

    def majority_casing(heard):
        hf = [fold(x) for x in tokens(heard)]
        c = Counter()
        for ri in containing(heard):
            p = all_prep[ri]
            seen = set()
            for i in range(len(p["folds"]) - len(hf) + 1):
                if p["folds"][i:i + len(hf)] == hf:
                    seen.add(" ".join(p["toks"][i:i + len(hf)]))
            c.update(seen)
        return sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[0][0] if c else heard

    merged = {}
    for h in hits:
        key = fold(h["heard"])
        cur = merged.get(key)
        if cur is None or RANK[h["source"]] < RANK[cur["source"]] or (
                h["source"] == cur["source"] == "sounds_like_known" and h["gt"] and not cur["gt"]):
            if cur is not None and h["source"] == "spelling_variants":
                h["also"] = h["also"]
            merged[key] = dict(h)
        elif cur is not None and h["source"] == cur["source"] and h["also"] and not cur["also"]:
            cur["also"] = h["also"]

    out = []
    for key, h in merged.items():
        heard = majority_casing(h["heard"])
        sug = h["suggested"]
        toks = [fold(x) for x in tokens(heard)]
        if key in head_folds or key in glossary_tokens:
            continue
        if key in rejected_folds and h["source"] != "glossary_not_working":
            continue
        if h["source"] in ("spelling_variants", "unknown_recurring") and any(
                fold(a) in rejected_folds for a in h["also"]):
            continue
        if key in removed_tokens or (sug and fold(sug) in removed_tokens):
            continue
        if all(t in STOPWORDS for t in toks):
            continue
        if sug and fold(sug) == key:
            suggested_is_head = fold(sug) in head_folds
            if heard == majority_casing(heard) and not suggested_is_head:
                continue
        if sug and compact(heard) == compact(sug):
            continue
        rs = containing(heard)
        if not rs:
            continue
        ids = [all_prep[ri]["ts"] for ri in rs]
        if h["source"] == "glossary_not_working":
            ids = list(h["gnw_rows"])
            rs = ids
        ids.sort(reverse=True)
        if h["source"] == "sounds_like_known":
            score = 200 if h["gt"] else 150
        else:
            score = BASE_SCORE[h["source"]]
        count = len(rs)
        score += 10 * min(count, 20)
        also = [a for a in dict.fromkeys(h["also"]) if fold(a) != key]
        out.append({"heard": heard, "suggested": sug, "source": h["source"], "count": count,
                    "row_ids": ids[:5], "also_heard": also if h["source"] == "spelling_variants" else [],
                    "_score": score})
    out.sort(key=lambda c: (-c["_score"], -c["count"], c["heard"]))
    seen_sug, deduped = set(), []
    for c in out:  # sorted best first: keep the first (highest score) per suggested term
        k = fold(c["suggested"]) if c["suggested"] else None
        if k is not None:
            if k in seen_sug:
                continue
            seen_sug.add(k)
        deduped.append(c)
    for c in deduped:
        del c["_score"]
    return deduped[:MAX_CANDIDATES]


# ---------------------------------------------------------------- self-test
def _self_test():
    # cologne
    assert cologne("Claude") == cologne("Cloud") == "452", (cologne("Claude"), cologne("Cloud"))
    assert cologne("Müller-Lüdenscheidt") == "65752682", cologne("Müller-Lüdenscheidt")
    assert cologne("Läufer") == cologne("Läuffer") == "537"
    assert cologne("Wikipedia") == "3412", cologne("Wikipedia")
    assert cologne("Breschnew") == "17863", cologne("Breschnew")
    assert cologne("") == ""
    assert levenshtein("kitten", "sitting", 3) == 3 and levenshtein("kitten", "sitting", 2) is None
    assert close("Läufer", "Läuffer") and not close("Seite", "Seite") and not close("Hauptfall", "Hauptfalls")
    assert close("Cloud", "Claude") and not close("Wäre", "Wir")

    glossary = 'Terms: Läuffer, Grok Bot (not "Grogbot")'
    unknown = {"zorvex", "grogbot", "lauffer", "bianko"}
    stub = lambda t: fold(t) not in unknown
    def mk(texts, base, step=60):
        return [{"ts": (base + timedelta(seconds=step * i)).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                 "mode": "transcription", "result": t} for i, t in enumerate(texts)]
    base = datetime(2026, 11, 20, 10, 0, tzinfo=timezone.utc)
    texts = ["Frau Dr. Läufer hat angerufen.", "Ich habe Frau Dr. Läufer geschrieben.",
             "Warum wird Läufer immer falsch geschrieben?", "Wir nutzen Cloud Code für das Projekt.",
             "Cloud Code ist gut.", "Grogbot startet nicht.", "Die Seite lädt nicht.", "Die Seite ist neu.",
             "Termin mit Zorvex am Montag.", "Zorvex hat abgesagt.", "Zorvex kommt später."]
    hist = [{"ts": "2026-11-20T09:00:00.000Z", "section": "whisper_glossary", "added": [],
             "removed": ['Seiter (not "Seite")']}]
    got = compute(mk(texts, base), [], glossary, hist, [], stub, now=base + timedelta(minutes=30))
    brief = [(c["heard"], c["source"], c["suggested"], c["count"]) for c in got]
    expected = [("Läufer", "self_complaint", "Läuffer", 3), ("Cloud Code", "sounds_like_known", "Claude Code", 2),
                ("Zorvex", "unknown_recurring", None, 3)]
    print("A got     :", brief)
    print("A expected:", expected)
    assert brief == expected, "vector A FAILED"
    assert not any(c["heard"] in ("Grogbot", "Seite") for c in got)
    # B
    gl_b = 'Grok Bot (not "Grogbot")'
    rows_b = mk(["Grogbot startet nicht.", "Der Grogbot hängt."], base, 60)
    def run_b(t0):
        h = [{"ts": t0, "section": "whisper_glossary", "added": [gl_b], "removed": []}]
        return compute(rows_b, [], gl_b, h, [], stub, now=base + timedelta(minutes=30))
    got = run_b("2026-11-20T09:00:00.000Z")
    brief = [(c["heard"], c["source"], c["suggested"], c["count"]) for c in got]
    print("B got     :", brief)
    assert brief == [("Grogbot", "glossary_not_working", "Grok Bot", 2)], "vector B FAILED"
    got = run_b("2026-11-20T10:05:00.000Z")
    print("B late    :", got)
    assert got == [], "vector B (late annotation) FAILED"
    # D: rule (2), variants containing a rejected spelling are dropped
    got = compute(mk(["Grokbot geht.", "Grogbot geht.", "Grokbot läuft."], base), [], gl_b, [], [], stub,
                  now=base + timedelta(minutes=30))
    print("D got     :", [(c["heard"], c["source"]) for c in got])
    assert not any(fold(c["heard"]) == "grokbot" for c in got), "vector D FAILED"
    # E: a suggestion that differs only in case, spacing or punctuation is dropped (v4)
    assert compact("sabaki dance") == compact("sabaki.dance") and compact("Datev") == compact("DATEV")
    gl_e = "sabaki.dance"
    stub_e = lambda t: fold(t) != "sabakidance"
    rows_e = mk(["Sabakidance ist falsch geschrieben."], base)
    got = compute(rows_e, [], gl_e, [], [], stub_e, now=base + timedelta(minutes=30))
    print("E got     :", [(c["heard"], c["suggested"]) for c in got])
    assert got == [], "vector E FAILED"
    # F: a known single-token heard is never a sounds_like_known candidate, even for a glossary head (v5)
    got = compute(mk(["Das braucht Zeit.", "Er braucht Hilfe."], base), [], "Parakeet", [], [], stub,
                  now=base + timedelta(minutes=30))
    print("F got     :", [(c["heard"], c["suggested"]) for c in got])
    assert got == [], "vector F FAILED"
    got = compute(mk(["Zorvex ruft an.", "Zorvex schreibt."], base), [], "Zorvax", [], [], stub,
                  now=base + timedelta(minutes=30))
    assert [(c["heard"], c["suggested"]) for c in got] == [("Zorvex", "Zorvax")], "vector F (control) FAILED"
    # G: a suggestion the user removed on purpose is dropped (v5)
    hist_g = [{"ts": "2026-11-20T09:00:00.000Z", "section": "whisper_glossary", "added": [], "removed": ["Zorvax"]}]
    got = compute(mk(["Zorvex ruft an.", "Zorvex schreibt."], base), [], "Zorvax", hist_g, [], stub,
                  now=base + timedelta(minutes=30))
    print("G got     :", [(c["heard"], c["suggested"]) for c in got])
    assert got == [], "vector G FAILED"
    # H: group judged unknown via an unknown spelling with >= 2 rows although the top spelling is "known" (v5)
    rows_h = ["AutoMagic läuft."] * 4 + ["Automagic läuft."] * 2
    got = compute(mk(rows_h, base), [], "", [], [], lambda t: t != "Automagic", now=base + timedelta(minutes=30))
    print("H got     :", [(c["heard"], c["source"], c["count"]) for c in got])
    assert [(c["heard"], c["source"], c["count"]) for c in got] == [("AutoMagic", "unknown_recurring", 6)], "vector H FAILED"
    # C
    got = compute(mk(["Das ist Bianko, nicht Bianko, merk dir das."], base), [], "", [], [], stub,
                  now=base + timedelta(minutes=30))
    brief = [(c["heard"], c["source"], c["suggested"], c["count"]) for c in got]
    print("C got     :", brief)
    assert brief == [("Bianko", "self_complaint", None, 1)], "vector C FAILED"
    print("self-test OK")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        _self_test()
    else:
        print(__doc__)
