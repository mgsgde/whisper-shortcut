#!/usr/bin/env python3
"""Regenerates the shipped-default fingerprints in
WhisperShortcut/SystemPromptDefaultsHistory.swift.

Every wording of the constants listed for a section is fingerprinted (SHA-256 of the
whitespace-normalised text). Sources are HEAD history plus every release tag plus the
working tree. The generated file is append-only: entries are never dropped, since an
installed user may still have that wording. A squash merge drops branch commits from
history.

The first constant is the current default the section is lifted to. Dictation and Dictate
Prompt keep the built-in core as that default. The additions sections' default is empty.

Also writes `shippedLineSets`: for Dictation and Dictate Prompt, one set per historical
wording of the core constant, each set the fingerprints of that wording's non-empty
normalised lines. Migration uses a set when a legacy prompt still contains every line.

Run after changing one of the default prompt constants, then commit the regenerated
Swift file. The test `SystemPromptDefaultsHistoryTests` fails until you do.

    python3 scripts/prompt-default-fingerprints.py
"""
import hashlib, re, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONSTANTS = ROOT / "WhisperShortcut" / "AppConstants.swift"
OUT = ROOT / "WhisperShortcut" / "SystemPromptDefaultsHistory.swift"

# (Swift section case, constant names). The first name is the current default.
SECTIONS = [
    ("dictationAdditions", ["defaultDictationAdditions"]),
    ("promptModeAdditions", ["defaultPromptModeAdditions"]),
    ("dictation", ["defaultTranscriptionSystemPrompt"]),
    ("whisperGlossary", ["defaultWhisperGlossary"]),
    ("promptMode", ["defaultPromptModeSystemPrompt"]),
    ("chat", ["defaultChatSystemPrompt"]),
    ("readAloudRewrite", ["defaultReadAloudRewritePrompt"]),
]

# Cores whose historical lines migration may strip out of a legacy full prompt.
LINE_SET_CONSTANTS = {
    "dictation": "defaultTranscriptionSystemPrompt",
    "promptMode": "defaultPromptModeSystemPrompt",
}


def normalized(text: str) -> str:
    # Must match SystemPromptDefaultsHistory.normalized in Swift.
    return re.sub(r"\s+", " ", text).strip()


def fingerprint(text: str) -> str:
    return hashlib.sha256(normalized(text).encode("utf-8")).hexdigest()


def line_set(text: str):
    """Fingerprints of non-empty normalised lines, in sorted order for a stable file."""
    seen = set()
    for line in text.splitlines():
        norm = normalized(line)
        if not norm:
            continue
        seen.add(fingerprint(norm))
    return tuple(sorted(seen))


def extract(src: str, name: str):
    m = re.search(
        r"static let %s\s*=\s*(?:\n\s*)?(\"\"\"\n(.*?)\n\s*\"\"\"|\"((?:[^\"\\]|\\.)*)\")" % name,
        src, re.S)
    if not m:
        return None
    return m.group(2) if m.group(2) is not None else m.group(3)


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


_HEX = re.compile(r'"([0-9a-f]{64})"')


def existing_entries(path) -> tuple[dict[str, list[str]], dict[str, list[tuple]]]:
    """Fingerprints and line sets already written in the generated Swift file.

    Empty dicts when the file is missing. Only the shippedFingerprints and
    shippedLineSets blocks are read; anything else in the file is ignored.
    """
    if not path.is_file():
        return {}, {}
    lines = path.read_text().splitlines()

    def block(marker):
        start = next((i for i, line in enumerate(lines) if marker in line), None)
        if start is None:
            return []
        out = []
        for line in lines[start + 1:]:
            if line == "  ]":
                break
            out.append(line)
        return out

    fingerprints: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in block("static let shippedFingerprints"):
        matched = re.match(r"    \.(\w+): \[", line)
        if matched:
            current = []
            fingerprints[matched.group(1)] = current
            continue
        if line == "    ],":
            current = None
            continue
        if current is None:
            continue
        found = _HEX.search(line)
        if found:
            current.append(found.group(1))

    line_sets: dict[str, list[tuple]] = {}
    sets: list[tuple] | None = None
    acc: list[str] | None = None
    for line in block("static let shippedLineSets"):
        if acc is None:
            matched = re.match(r"    \.(\w+): \[", line)
            if matched:
                sets = []
                line_sets[matched.group(1)] = sets
                continue
            if line == "    ],":
                sets = None
                continue
        if line == "      Set([":
            acc = []
            continue
        if line == "      ]),":
            if sets is not None and acc is not None:
                sets.append(tuple(sorted(acc)))
            acc = None
            continue
        if acc is None:
            continue
        found = _HEX.search(line)
        if found:
            acc.append(found.group(1))

    return fingerprints, line_sets


def merge_kept(computed, old):
    """Computed order, then entries the file already had that history no longer does.

    Between two wordings that are still in history, a newly found wording is
    written first and any wording only the existing file still has follows it,
    in the file's order. Wordings older than everything history still has are
    appended. Entries the file already has are never dropped.
    """
    computed_set = set(computed)
    groups = {}
    anchor = None
    for item in reversed(old):
        if item in computed_set:
            anchor = item
            continue
        groups.setdefault(anchor, []).append(item)
    for items in groups.values():
        items.reverse()

    merged = []
    for item in computed:
        merged.extend(groups.pop(item, ()))
        merged.append(item)
    merged.extend(groups.pop(None, ()))
    kept = len(old) - sum(1 for item in old if item in computed_set)
    return merged, kept


def main():
    # Working tree first (uncommitted edits count), then HEAD history and every release tag.
    sources = [("working tree", CONSTANTS.read_text())]
    for sha in git("log", "--format=%H", "HEAD", "--tags", "--", "WhisperShortcut/AppConstants.swift").split():
        sources.append((sha[:8], git("show", f"{sha}:WhisperShortcut/AppConstants.swift")))

    per_section = {case: [] for case, _ in SECTIONS}  # ordered, newest first, unique
    line_sets = {case: [] for case in LINE_SET_CONSTANTS}  # newest first, unique sets
    seen_line_sets = {case: set() for case in LINE_SET_CONSTANTS}
    for label, src in sources:
        for case, names in SECTIONS:
            for name in names:
                text = extract(src, name)
                if text is None:
                    continue
                fp = fingerprint(text)
                if fp not in per_section[case]:
                    per_section[case].append(fp)
        for case, name in LINE_SET_CONSTANTS.items():
            text = extract(src, name)
            if text is None:
                continue
            fps = line_set(text)
            if not fps or fps in seen_line_sets[case]:
                continue
            seen_line_sets[case].add(fps)
            line_sets[case].append(fps)

    # Keep every entry the existing file already has. History is newest-first;
    # a wording only the file still has stays after the history entries that
    # precede it, so a squash merge cannot drop an installed user's wording.
    old_fingerprints, old_line_sets = existing_entries(OUT)
    kept = 0
    known_sections = {case for case, _ in SECTIONS}
    for case, old in old_fingerprints.items():
        if case not in known_sections:
            continue
        per_section[case], added = merge_kept(per_section[case], old)
        kept += added
    for case, old in old_line_sets.items():
        if case not in LINE_SET_CONSTANTS:
            continue
        line_sets[case], added = merge_kept(line_sets[case], old)
        kept += added

    lines = [
        "//",
        "//  SystemPromptDefaultsHistory.swift",
        "//  WhisperShortcut",
        "//",
        "//  GENERATED by scripts/prompt-default-fingerprints.py — do not edit by hand.",
        "//  Re-run the script after changing a default prompt or additions constant.",
        "//  shippedFingerprints are whole-text hashes. shippedLineSets are per-line hashes of",
        "//  each historical Dictation and Dictate Prompt core.",
        "//",
        "",
        "import CryptoKit",
        "import Foundation",
        "",
        "/// Every wording the shipped default system prompts have ever had, as fingerprints.",
        "///",
        "/// `SystemPromptsStore` materialises the defaults into the user's `system-prompts.md` on first",
        "/// launch and reads only that file afterwards, so a change to a default constant never reached",
        "/// an existing install — even one whose user had not touched the section. This list is how the",
        "/// store tells \"never edited\" (still equal to some former default) from \"edited\": the former is",
        "/// lifted to the current default on launch, the latter is left alone.",
        "///",
        "/// Fingerprints are SHA-256 over whitespace-normalised text, so a stray trailing newline or",
        "/// re-wrapped paragraph in the file does not count as a user edit.",
        "enum SystemPromptDefaultsHistory {",
        "",
        "  /// Collapses whitespace runs and trims. Mirrors `normalized()` in the generator script.",
        "  static func normalized(_ text: String) -> String {",
        "    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: \" \")",
        "  }",
        "",
        "  static func fingerprint(_ text: String) -> String {",
        "    SHA256.hash(data: Data(normalized(text).utf8)).map { String(format: \"%02x\", $0) }.joined()",
        "  }",
        "",
        "  /// The current default for a section — the text an unedited section is lifted to.",
        "  static func currentDefault(for section: SystemPromptSection) -> String {",
        "    switch section {",
    ]
    for case, names in SECTIONS:
        lines.append(f"    case .{case}: return AppConstants.{names[0]}")
    lines += [
        "    }",
        "  }",
        "",
        "  /// True when `text` is, modulo whitespace, some default this app has ever shipped for `section`.",
        "  static func isShippedDefault(",
        "    _ text: String, for section: SystemPromptSection,",
        "    in history: [SystemPromptSection: Set<String>] = shippedFingerprints",
        "  ) -> Bool {",
        "    history[section]?.contains(fingerprint(text)) == true",
        "  }",
        "",
        "  /// Sections whose content is a former shipped default, mapped to the current default. Sections",
        "  /// already on the current wording, edited by the user, or missing are not included.",
        "  /// `shippedFingerprints` is injectable for tests only.",
        "  static func upgrades(",
        "    for sections: [SystemPromptSection: String],",
        "    shippedFingerprints history: [SystemPromptSection: Set<String>] = shippedFingerprints",
        "  ) -> [SystemPromptSection: String] {",
        "    var result: [SystemPromptSection: String] = [:]",
        "    for (section, content) in sections {",
        "      let current = currentDefault(for: section)",
        "      guard normalized(content) != normalized(current), isShippedDefault(content, for: section, in: history)",
        "      else { continue }",
        "      result[section] = current",
        "    }",
        "    return result",
        "  }",
        "",
        "  /// Newest first. Includes the current default so a section on the current wording also",
        "  /// reads as \"never edited\" (relevant for the next time the default changes).",
        "  static let shippedFingerprints: [SystemPromptSection: Set<String>] = [",
    ]
    for case, _ in SECTIONS:
        lines.append(f"    .{case}: [")
        for fp in per_section[case]:
            lines.append(f"      \"{fp}\",")
        lines.append("    ],")
    lines += [
        "  ]",
        "",
        "  /// Newest first. One set per historical wording of the built-in core: the fingerprints",
        "  /// of its non-empty normalised lines. A legacy prompt contains that wording when every",
        "  /// fingerprint in the set occurs among its own lines.",
        "  static let shippedLineSets: [SystemPromptSection: [Set<String>]] = [",
    ]
    for case in ("dictation", "promptMode"):
        lines.append(f"    .{case}: [")
        for fps in line_sets[case]:
            lines.append("      Set([")
            for fp in fps:
                lines.append(f"        \"{fp}\",")
            lines.append("      ]),")
        lines.append("    ],")
    lines += ["  ]", "}", ""]
    OUT.write_text("\n".join(lines))
    total = sum(len(v) for v in per_section.values())
    print(f"wrote {OUT.relative_to(ROOT)}: {total} fingerprints across {len(SECTIONS)} sections")
    for case, fps in per_section.items():
        print(f"  {case}: {len(fps)}")
    print(f"kept {kept} entries from the existing file that git history no longer has")


if __name__ == "__main__":
    main()
