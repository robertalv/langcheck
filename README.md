# LangCheck

A **native macOS app** (SwiftUI) for stylometric / forensic-linguistics text
analysis. Drop in a `.txt` file (or paste text), click **Analyze**, and get a
report across ten linguistic markers — built to help profile authorship in
true-crime documents.

The UI is native Swift; the linguistic analysis runs a bundled **spaCy** engine
as a subprocess, so all ten metrics keep full accuracy.

## The metrics

| # | Metric | What it measures | Example |
|---|--------|------------------|---------|
| 1 | **“Rather” as a degree adverb** | Intensifier use of *rather* (not *rather than*) | “I have grown **rather** angry” |
| 2 | **“In” before a gerund** | How often *in* precedes an *-ing* phrase | “fun **in trying** to catch me” |
| 3 | **Contraction rate** | Contracted vs. expanded forms | *don’t* vs *do not* |
| 4 | **“Will” vs “shall”** | Share of *shall* among the two modals | “I **shall** state…” |
| 5 | **Possessive + gerund** | Possessive determiner before a gerund | “your **asking** for more details” |
| 6 | **Dropped / missing article** *(heuristic)* | Singular count nouns with no *the/a/an* | “back to **developer**” |
| 7 | **Complementizer inclusion vs deletion** | Keeping vs dropping *which / that* | “facts **which** I know” vs “facts ∅ I know” |
| 8 | **“Is this” + cataphoric prompt** | *is this* pointing forward to a directive | “…is this, **please help me**.” |
| 9 | **Top-3 degree adverbs** | The writer’s dominant intensifiers and their share | *very, quite, rather…* |
| 10 | **Phrase / word rarity (COCA-style)** | How rare words/phrases are in modern English | via `wordfreq` Zipf scores |

Metrics 1–5, 8, 9 are exact. 6 and 7 are spaCy parser-based **heuristics** —
review the flagged examples rather than trusting the count blindly. Metric 10
approximates COCA frequencies with the open `wordfreq` corpora (no COCA license
needed); type a phrase into the **Rarity phrase** box to score it.

## Architecture

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  LangCheck.app  (SwiftUI)    │ stdin  │  pyengine (bundled venv)     │
│  ContentView / MetricCard    │ ─────▶ │  cli.py → analyzer.py        │
│  Engine.swift (Process)      │ ◀───── │  spaCy + wordfreq            │
└─────────────────────────────┘  JSON  └──────────────────────────────┘
```

The Swift app writes the text to the Python process's stdin, the engine prints
one JSON report to stdout, and Swift decodes it into native views.

## Build the app

You need Xcode (Swift toolchain) and the Python engine set up once:

```bash
# 1. set up the Python engine (one time)
cd langcheck
python3 -m venv venv
./venv/bin/python -m pip install -r requirements.txt
./venv/bin/python -m spacy download en_core_web_sm   # if not pulled by requirements

# 2. build the native app
mac/package_app.sh
open mac/dist/LangCheck.app
```

`package_app.sh` compiles the Swift release binary and bundles the Python engine
(spaCy model + wordfreq data) into `mac/dist/LangCheck.app`. First launch of an
unsigned app: right-click → **Open**, or *System Settings → Privacy & Security →
Open Anyway*.

### Develop / iterate quickly

```bash
cd mac/LangCheck
swift run                 # launches the app using the project venv (no packaging)
swift run LangCheck --selftest   # headless: verify the Swift↔Python bridge
```

You can also open `mac/LangCheck/Package.swift` in Xcode and hit Run.

### Command line (no UI)

```bash
./venv/bin/python analyzer.py yourfile.txt --phrase "some phrase to score"
cat yourfile.txt | ./venv/bin/python cli.py --phrase "..."   # JSON output
```

## Making it portable (other Macs)

The bundled `venv` references the system **Python.framework 3.13** it was built
against, so the app runs on Macs that have that framework. To ship to a Mac
without it, rebuild the engine on a **relocatable** Python
([python-build-standalone](https://github.com/astral-sh/python-build-standalone)),
`pip install -r requirements.txt` into it, and point `package_app.sh` at that
interpreter instead of `venv`. Everything else stays the same.

For CI/release builds, `scripts/build_portable_python.sh` does this automatically
and `mac/package_app.sh` bundles that runtime when `PYENGINE_PYTHON_DIR` is set.

## Release DMGs and in-app updates

LangCheck can be shipped as a GitHub Release DMG and updated in-app through
Sparkle.

### CI builds

`.github/workflows/ci.yml` runs on pushes, pull requests, and manual dispatch.
It validates the scripts, builds the Swift app, builds a portable Python
runtime, packages `LangCheck.app`, runs `--selftest`, creates a DMG, and uploads
the DMG as a GitHub Actions artifact. CI artifacts are test builds and are not
the public install channel. On pushes to `main`/`master` and manual CI runs, CI
assesses the DMG with Gatekeeper. It publishes a GitHub prerelease under a
`ci-<run_number>` tag only if the build is signed, notarized, and stapled; if
not, it keeps the DMG as an Actions artifact only.

Public releases are produced only by `.github/workflows/macos-release.yml`.
That workflow runs on pushes to `main`/`master`, version tags, and manual
dispatch. For normal pushes, it creates a version like `1.0.<run_number>`,
publishes tag `v1.0.<run_number>`, and marks that GitHub Release as **Latest**.
It requires Developer ID signing, Apple notarization, and Sparkle update signing
secrets before it will publish. This prevents shipping DMGs that macOS reports
as damaged or unsafe.

### One-time release setup

1. Create Sparkle EdDSA keys:

   ```bash
   # After SwiftPM has fetched Sparkle, locate generate_keys in .build or use
   # the Sparkle release tools from https://sparkle-project.org.
   generate_keys
   ```

2. Add these GitHub Actions secrets:

   | Secret | Purpose |
   |--------|---------|
   | `SPARKLE_PUBLIC_ED_KEY` | Embedded in the app so it can verify updates |
   | `SPARKLE_PRIVATE_ED_KEY` | Used only in CI to sign the update archive |
   | `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID `.p12` |
   | `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
   | `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
   | `DEVELOPER_ID_APPLICATION` | Signing identity, for example `Developer ID Application: Name (TEAMID)` |
   | `APPLE_ID` | Apple ID used for notarization |
   | `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
   | `APPLE_TEAM_ID` | Apple Developer Team ID |

The Apple and Sparkle secrets are required for public distribution without
Gatekeeper warnings. Without them, CI still creates a test DMG artifact, but the
release workflow will refuse to publish a public release.

### Publish a release

For an automatic latest release, push to `main` or `master` after the signing
secrets are configured.

For a specific semantic version, tag and push:

```bash
git tag v1.0.1
git push origin v1.0.1
```

The `.github/workflows/macos-release.yml` workflow builds a portable Python
runtime, packages `LangCheck.app`, creates `LangCheck-<version>-<arch>.dmg`,
generates `appcast.xml`, and attaches both files to the GitHub Release.

The app's update feed defaults to:

```text
https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
```

Users can install the first DMG manually. After that, **Settings → Updates →
Check for Updates** and the app menu's **Check for Updates...** button use
Sparkle to offer a native update/install button whenever a newer release exists.

## Project layout

```
analyzer.py        core analysis engine (no UI) — all ten metrics
cli.py             JSON bridge the Swift app calls
requirements.txt   Python deps (spaCy, wordfreq, model)
sample.txt         tiny test document hitting every metric

mac/
  package_app.sh   builds mac/dist/LangCheck.app (bundles the venv)
  LangCheck/
    Package.swift
    Sources/LangCheck/
      Entry.swift        @main + headless --selftest
      LangCheckApp.swift App + window + activation policy
      ContentView.swift  the UI (drop zone, controls, metric cards)
      MetricCard          a single metric card
      Engine.swift       runs the Python subprocess, decodes JSON
      Models.swift       Codable structs matching the JSON

app.py / run.sh    optional CustomTkinter GUI (cross-check / non-Mac fallback)
```

## Ideas / next steps

- **True COCA cross-reference** needs a COCA license; the `wordfreq` metric is a
  free, defensible proxy. A future option is bundling a downloaded n-gram list
  for phrase-level lookups.
- A **persistent** Python worker (load spaCy once, stream requests) would make
  repeat analyses near-instant; the current build spawns a fresh process per run
  (~2–4 s on the first call for model load).
- The dropped-article and complementizer heuristics can be tightened with a
  larger spaCy model (`en_core_web_trf`) at the cost of size/speed.
- Add an app icon (`Contents/Resources/AppIcon.icns`) and notarize for sharing.
```
