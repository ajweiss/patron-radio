# Contributing to Patron Radio

## Getting Started

1. Fork the repo and clone your fork
2. Install dependencies (see README.md)
3. Build and run the tests:
   ```bash
   mkdir build && cd build
   cmake ..
   make -j$(nproc)
   ctest --output-on-failure
   ```
4. Add the widget to your panel and test manually

Working on the macOS app instead? It needs macOS 14+ and Xcode 16+:
```bash
cd macos
swift test
scripts/build-app.sh && open "dist/Patron Radio.app"
```

## Git Workflow

### Commits

- **All commits must be signed.** The existing history is signed with an SSH key:
  ```bash
  git config gpg.format ssh
  git config user.signingkey ~/.ssh/id_ed25519.pub   # or "key::ssh-ed25519 AAAA…" to sign via ssh-agent
  git config commit.gpgsign true
  ```
  To verify signatures locally (`git log --show-signature`), list your key in an allowed-signers file:
  `echo "you@example.com namespaces=\"git\" $(cat ~/.ssh/id_ed25519.pub)" >> ~/.config/git/allowed_signers`
  and `git config gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers`. GPG signing works too.
- Subjects use a conventional-commit prefix: `fix:`, `feat:`, `docs:`, `test:`, `ci:`, `chore:`, `build:`, `refactor:`, with an optional scope such as `fix(ui):`, `feat(macos):` or `refactor(audio):`
- Write the rest in imperative mood: "fix: stop the radio auto-resuming", not "fixed …"
- Keep the first line under 72 characters; explain the *why* in a short body wrapped at about 72 columns
- Reference issue numbers where applicable: `fix: recover the stream after network loss (#42)`
- Agent-assisted commits end with an `Assisted-by: Claude:<model-id>` trailer (e.g. `Assisted-by: Claude:claude-opus-5`), not `Co-Authored-By`

### Branches

- `main` is the release branch — always buildable, always tested
- Feature branches: `feature/short-description`
- Bug fixes: `fix/short-description`
- PRs should target `main` and be rebased (no merge commits)

### Pull Requests

- One logical change per PR
- Include a test plan in the PR description
- All tests must pass before merge
- If adding a new feature, include tests
- **Pull requests from autonomous coding agents without a responsible human author are not currently accepted.** Agent-assisted PRs are welcome, but a human must review, take responsibility for, and sign off on the changes.

## Code Style

### C++ (src/)

- **Standard**: C++17
- **Indentation**: 4 spaces, no tabs
- **Braces**: Opening brace on same line for functions and control flow
  ```cpp
  void RadioBackend::play() {
      if (!m_icyReader->isActive()) {
          m_icyReader->start(QUrl(m_currentUrl));
      }
  }
  ```
- **Naming**:
  - Classes: `PascalCase` (`RadioBackend`, `IcyStreamReader`)
  - Member variables: `m_camelCase` (`m_player`, `m_currentUrl`)
  - Methods: `camelCase` (`isPlaying()`, `setCurrentUrl()`)
  - Constants: `UPPER_SNAKE_CASE` (`RECONNECT_MAX_MS`, `READY_THRESHOLD`)
  - MPRIS methods follow the D-Bus convention: `PascalCase` (`PlaybackStatus()`, `SetVolume()`)
- **Qt conventions**:
  - Use `QStringLiteral()` for string literals
  - Use `Q_EMIT` instead of `emit`
  - Prefer `connect()` with lambdas for local logic; use member slots for complex handlers
- **Signals**: Always emit the most specific signal. Don't emit `bufferingChanged()` when you mean `playingChanged()`.
- **Memory**: Use Qt's parent-child ownership. Raw `new` is fine when the parent is set. No `std::shared_ptr` for QObjects.

### QML (contents/ui/)

- **Indentation**: 4 spaces, no tabs
- **Component structure**: Properties first, then signals, then functions, then child items
- **Naming**:
  - Properties: `camelCase` (`playbackState`, `currentStationName`)
  - State enum values: `stateCamelCase` (`stateStopped`, `statePlaying`) — QML requires lowercase first letter
  - IDs: `camelCase` (`audioRouter`, `stationApi`)
  - Files: `PascalCase.qml` (`AudioRouter.qml`, `CompactRepresentation.qml`)
- **Component sizing**: Keep QML files focused. If a file exceeds ~200 lines, consider extracting a sub-component.
- **Imports**: Only import what you use. Group standard Qt imports, then KDE imports, then local imports.

### Swift (macos/)

- **Toolchain**: Swift 6 package (tools 6.0) compiled in Swift 5 language mode, targeting macOS 14
- **Indentation**: 4 spaces, no tabs; opening brace on the same line
- **Naming**: Swift API guidelines — types `PascalCase`, everything else `camelCase`
- **Layout**: logic goes in `PatronRadioCore` (no AppKit or SwiftUI there), UI goes in `PatronRadio`
- **State**: `@Observable` models on the main actor; the audio pipeline (`StreamSession`) runs on its own serial queue and reports back to the main queue
- **Logging**: `NSLog("patron-radio: …")`, the same prefix as the widget
- **Ports**: when porting a widget change, keep the behavior and the comments explaining it in sync, and say in the commit which side it came from

### Config Schema (contents/config/main.xml)

- Every config entry must have a `<default>` value
- Remove config entries that are no longer referenced — don't leave dead keys
- JSON stored in string config entries should be valid when empty: use `[]` or `{}` as defaults
- The macOS app mirrors these keys in `macos/Sources/PatronRadioCore/AppSettings.swift`. Add or rename them there too
- The default station list is also the macOS app's: after editing it, run `macos/scripts/sync-stations.sh` (a macOS test fails if they drift)

## Testing

### Running Tests

```bash
cd build
ctest --output-on-failure
```

The macOS app's tests run with `cd macos && swift test`.

Or run a specific test with verbose output:
```bash
./bin/test_radiobackend -v1
./bin/test_icystream -v1
```

### Writing Tests

- Tests live in `tests/` and link against `patronradiocore`
- Use Qt Test framework (`QTest`, `QSignalSpy`)
- **Name tests by what they verify**, not how: `testStopCancelsReconnect`, not `testStopMethod`
- Test categories to cover:
  - **State transitions**: play/pause/stop in all orderings
  - **Signal correctness**: verify signals fire (and don't fire) at the right times
  - **Deduplication**: setting the same value twice should not re-emit signals
  - **Edge cases**: empty URLs, invalid device IDs, rapid operations
  - **Resource cleanup**: destroy objects in various states, verify no crash/leak
  - **Stress**: rapid station switching, create/destroy loops
- When adding a new backend feature, add tests for:
  1. The happy path
  2. Double-invocation safety
  3. Interaction with stop/pause
  4. Destruction while the feature is active

### Shared Test Vectors

Rules that both the widget and the macOS app implement (HTML entity decoding in stream titles, the loudness gain policy) are written once as JSON in `tests/data/` and loaded by both test suites. When you change such a rule, change the vectors, then make both sides pass. When you add a rule that both apps implement, add a vector file rather than hard-coding the cases in one suite. See [tests/data/README.md](tests/data/README.md).

### Manual Testing Checklist

Before submitting a PR that touches playback or routing:

- [ ] Play a station, verify audio and stream title appear
- [ ] Switch stations rapidly (5+ times in quick succession)
- [ ] Pause via MPRIS (`playerctl pause`), verify no buffering spinner
- [ ] Stop and restart playback
- [ ] Disconnect network, verify reconnect after restoring
- [ ] Connect/disconnect a Bluetooth audio device while playing
- [ ] Verify `systemd-inhibit --list` shows the lock while playing (if inhibit is enabled)
- [ ] Open widget settings, change options, verify no crash on apply

macOS app, before submitting a PR that touches playback or routing:

- [ ] Play from the popover and verify the stream title in both the popover and the menu bar
- [ ] Switch stations rapidly; use the play/pause and next/previous media keys
- [ ] Unplug headphones (or disconnect AirPods) while playing and verify it pauses rather than switching to the speakers
- [ ] Disconnect the network and verify it reconnects after restoring
- [ ] Verify `pmset -g assertions` lists Patron Radio while playing (if sleep prevention is on)

## Architecture Notes

See the **Architecture** section in README.md for why the C++ backend exists (Qt6 ICY metadata and audio routing bugs).

Key design decisions:
- **Playback state machine** in `main.qml` — single `playbackState` property, not independent booleans
- **Reconnect with backoff** in `RadioBackend` — exponential backoff with jitter, capped retries
- **Extracted QML components** — `AudioRouter.qml`, `StationApi.qml`, `ContextActions.qml` keep `main.qml` focused on orchestration
- **Sleep inhibit** via `org.freedesktop.login1.Manager.Inhibit` — held as a file descriptor, released on stop/pause

### Architecture Constraints

- The C++ backend exists to work around Qt6 bugs ([QTBUG-107661](https://bugreports.qt.io/browse/QTBUG-107661), [QTBUG-108383](https://bugreports.qt.io/browse/QTBUG-108383)). Do not replace it with QML `MediaPlayer`/`AudioOutput` — those don't support ICY metadata or reliable device switching in widget contexts.
- `main.qml` uses a single `playbackState` integer as its state machine. Do not add independent boolean state flags — use the enum values (`stateStopped`, `statePlaying`, etc.).
- New logic should go in the appropriate extracted sub-component (`AudioRouter.qml`, `StationApi.qml`, `ContextActions.qml`), not back into `main.qml`.
- Reconnect logic lives in `RadioBackend` (C++), not QML.
- Tests must not depend on network access or real audio hardware.
- The macOS app follows the same constraints: one `PlaybackState` in `RadioController` (no independent flags), reconnect logic in `RadioBackend`, and `DefaultStations.swift` is generated. Never edit it by hand.

### Keeping the widget and the macOS app in sync

When a widget change lands, port it to the matching Swift file (and the reverse):

| Widget | macOS (`macos/Sources/…`) |
|---|---|
| `contents/ui/main.qml` (state machine, history, stations, tooltip text) | `PatronRadioCore/RadioController.swift` |
| `contents/ui/AudioRouter.qml` | `RadioController.swift` ("Output routing") + `PatronRadioCore/AudioDevices.swift` |
| `contents/ui/StationApi.qml` (Fix, nearest station) | `RadioController.swift` + `RadioBrowser`/`Geo` in `PatronRadioCore/Helpers.swift` |
| `contents/ui/ContextActions.qml` | `MenuModel` in `PatronRadio/Components.swift` |
| `contents/ui/FullRepresentation.qml` | `PatronRadio/PopoverView.swift` |
| `contents/ui/CompactRepresentation.qml`, `RadioToolTip.qml` | `PatronRadio/StatusItemController.swift` |
| `contents/ui/config*.qml` | `PatronRadio/SettingsView.swift` |
| `contents/config/main.xml` keys | `PatronRadioCore/AppSettings.swift` (same key names) |
| `main.xml` default stations | `PatronRadioCore/DefaultStations.swift`, generated by `macos/scripts/sync-stations.sh` |
| `src/radiobackend.cpp` (reconnect, stall watchdog, loudness, sleep lock) | `PatronRadioCore/RadioBackend.swift` + `Loudness.swift` |
| `src/icystreamreader.cpp` | `PatronRadioCore/IcyParser.swift` (demux, entities) + `StreamSession.swift` (network, decode, output) |
| MPRIS adaptor | `PatronRadio/NowPlaying.swift` |

There's no macOS counterpart to the cross-instance sync bus (`sharedStations`/`sharedSettings`): the app is a
single process. Deliberate behavior differences are listed in `macos/README.md`. Keep them deliberate.

Two upkeep rules:

- The macOS CI workflow (`.github/workflows/macos.yml`) only runs when `macos/`, `tests/data/`,
  `contents/config/main.xml` or the workflow itself changes. If the app starts depending on another file,
  add it to the `paths` filter, or CI will silently stop covering it.
- README screenshots in `macos/docs/screenshots/` are real screen captures (offscreen renders can't show the
  real menu bar or popover chrome). Refresh them after any visible UI change.

### Things to Avoid

- Don't add toggle flags for dead code paths (e.g., `m_useCustomIcyParser` was removed for this reason). If it's always on, remove the conditional.
- Don't store debug/test scaffolding in the config schema. Ship it behind a build flag or don't ship it.
- Don't leave unused config entries in `main.xml` — they persist in user config files permanently.
- Don't use `console.log` in QML for permanent debug output. Use `qDebug()` in C++ where needed.
