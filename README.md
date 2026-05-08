# Q*Й

Smart keyboard layout switcher for macOS. Like Punto Switcher / Caramba, but native, open-source, and built for Apple Silicon.

Detects when you've typed in the wrong layout (e.g., `ghbdtn` instead of `привет`), auto-fixes it, and switches the system input source so you continue in the right layout.

## Features

- **Auto-conversion on the fly** — type a word in the wrong layout, hit space, it fixes itself
- **Smart detector** — uses Russian/English dictionaries + n-gram analysis. Doesn't touch valid words.
- **Context-aware** — looks at the surrounding text to disambiguate (single letter `f` after Russian text → `а`)
- **Retro-conversion** — fixes preceding single-letter prepositions retroactively when a word triggers conversion
- **Mixed-alphabet handling** — `;му`, `'kkf` → `жму`, `элла`. Recognises layout-mistakes even when they include punctuation.
- **Manual hotkey (default left Option)**:
  - Toggles the latest replacement back and forth
  - Or converts the last typed word / current selection
- **Force swap hotkey** (⌥⇧S) — unconditional layout swap on selection or last word
- **Transliteration hotkey** (⌥⇧T) — Cyrillic → Latin per GOST 7.79-2000
- **Quick disable hotkey** — bind any key combo to instantly toggle the app on/off
- **Cleanup-friendly** — `Cmd+A`, mouse clicks, focus changes all properly invalidate state
- **Secure-input aware** — disables itself in password fields automatically
- **Auto-updates** via Sparkle from GitHub releases

## Installation

Download the latest `.dmg` from [Releases](https://github.com/graninilya/keyswitcher/releases/latest), open it, drag `Q*Й.app` to `Applications`.

First-time launch: macOS will warn that the app is from an unidentified developer (we ad-hoc sign — Apple Developer ID costs $99/year and we keep this free). To open:
- **Right-click** the app → **Open** → confirm
- Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Q*Й.app`

Then grant Accessibility permission in **System Settings → Privacy & Security → Accessibility**.

## Building from source

Requirements: Xcode Command Line Tools.

```bash
git clone https://github.com/graninilya/keyswitcher.git
cd keyswitcher/App
./build.sh

# Output: App/dist/keySwitcher.app
```

Move/copy `dist/keySwitcher.app` to `/Applications/` (rename to `Q*Й.app` if you want).

Dictionary JSONs and the AppIcon are committed under `dictionaries/processed/` and
`App/icons/` respectively, so a fresh clone builds without extra tooling.

## How auto-detection works

For each completed word the detector runs through:

1. Length < 2? → skip (single-letter rule kicks in only for known prepositions)
2. Word valid in its alphabet's dictionary? → keep
3. Exact match in Punto-style trigger list (~33k entries)? → swap
4. Swapped form a valid word in the other language? → swap
5. Weighted bad-substring score (3-grams weight 1, 4-grams weight 2, 5-grams weight 3, 6-grams weight 4) ≥ 2 AND swap's score ≤ word_score / 1.8 → swap
6. Context (last 3 words + focused element text via AX) clearly disagrees with current alphabet? → swap
7. Otherwise → leave alone

After a confident swap, the detector also walks back through preceding single-letter "words" and converts any that swap to a valid preposition in the same target language.

## Architecture

```
App/Sources/keySwitcher/
├── main.swift              entry / NSApp setup
├── AppDelegate.swift       menubar, hotkeys, settings UI lifecycle
├── EventMonitor.swift      shared CGEventTap + KeystrokeBuffer (with context tracking)
├── KeyTranslator.swift     UCKeyTranslate wrapper (handles dead keys)
├── LayoutResolver.swift    reads user's actual keyboard layouts via TIS APIs
├── LayoutMap.swift         layout swap + autoConvert detector
├── ContextResolver.swift   reads focused element text via Accessibility
├── AutoConverter.swift     auto-replacement on word completion + retro chain
├── ClipboardConverter.swift  selection / last-word conversion via clipboard or buffer
├── SelectionDetector.swift   AX-based selection detection
├── HotkeyManager.swift     Carbon RegisterEventHotKey wrapper
├── InputInjection.swift    centralised CGEvent posting + buffer-mute
├── InputSourceSwitcher.swift  TISSelectInputSource wrapper
├── Settings.swift          UserDefaults-backed config
├── SettingsWindow.swift    SwiftUI settings window with hotkey recorders
├── Transliteration.swift   GOST 7.79 ru→latin
├── UpdaterController.swift Sparkle integration
└── Log.swift               os.Logger setup
```

Dictionary assets are derived algorithmically from open hunspell dictionaries (LibreOffice ru_RU + en_US) — no copyrighted Punto data shipped.

## Privacy

- All processing runs locally. Nothing leaves your machine.
- Update checks query GitHub Releases (public). No telemetry.
- The keystroke buffer stores only the most recent word in process memory; secure-input fields are skipped.

## License

MIT — see [LICENSE](LICENSE).
