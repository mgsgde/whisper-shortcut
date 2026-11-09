# Contributing

Thanks for wanting to improve WhisperShortcut. This page says what gets merged and why, so you can tell
before you write a large PR whether it will land.

## Who the app is built for

The default user is someone on a **16 GB Apple Silicon MacBook** (often a medical or legal practice)
who never opens Settings beyond the first setup. Every decision below protects that user: a clean
Settings window, models that fit in 16 GB next to a browser, no extra LLM calls they didn't ask for.

Power users are welcome too. Their features just have to live where the default user doesn't trip
over them.

## One codebase, no private forks

Everyone works on `main` of this repo. Different needs are handled by **configuration at runtime**,
not by separate branches or forks that drift apart. Avoid `#if` compile-time switches for product
variants: code that only builds in one variant breaks unnoticed in the other. (The App Store /
direct build split is the one exception, and it exists for sandbox and review rules, not taste.)

## Where a feature goes

| The feature… | Where it goes |
|---|---|
| helps every user | Built in, on by default |
| helps some users, costs the others nothing | Built in, behind a setting that is **off by default**, inside the collapsed **Advanced** group of its tab (`AdvancedSettingsGroup`) |
| only makes sense on stronger hardware | Gated automatically by hardware, like local models with `minimumPhysicalMemoryGB` / `isOfferable`. No setting needed, a 16 GB Mac never sees it |
| connects to the user's own infrastructure (LM Studio, Ollama, LiteLLM, Azure, …) | Through the existing **own-server** path (`OwnServerEndpointSection` and its `Route`s, `CustomEndpointPreferences`). Add a route, don't build a second URL/key form |
| is large and serves one person's workflow | Discuss first (see below). Usually it fits one of the rows above once it is cut down |

Matters of pure taste (a font, a title format, the Dock icon) are fine as an off-by-default setting
in **Advanced**, but only if the change stays small: one setting, one code path, no extra network or
LLM calls.

## What a PR must bring

1. **Reuse the existing extension points** above. A second implementation of something the app
   already has (a settings form, a key lookup, a model catalogue) gets sent back.
2. **No cost for the default user.** No new LLM call during dictation or meetings unless switched
   on, nothing new in the main Settings view, no new sandbox entitlement without a strong reason.
3. **Tests for the logic and German strings** in `Localizable.xcstrings` for every new user-facing
   string.
4. **One concern per PR.** Unrelated commits (a picker change inside a model PR, an App Store change
   inside a layout PR) are split out or dropped.
5. **Benchmarks for model or transcription changes** (`bash scripts/dictation-benchmark.sh`), main vs
   your branch.

## Talk before you build

For anything over roughly 300 lines, or anything that adds a setting, a model, a provider or an
entitlement: open an issue (or message the maintainer) with three lines first. What it does, who it
is for, and which row of the table above it falls into. That saves both of us a PR that gets closed.

## Ownership

Whoever contributes a power-user feature looks after it: bug reports about it go to them first. A
feature that stays unused and unmaintained for a few months gets removed rather than carried
indefinitely, since every setting doubles the combinations that have to keep working.
