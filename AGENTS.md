See [CONTRIBUTING.md](CONTRIBUTING.md) — including its porting map for keeping the widget and the
macOS app in sync. The macOS app itself is documented in [macos/README.md](macos/README.md):

```bash
cd macos && swift test && scripts/build-app.sh
```

## Environment notes for agents

- On macOS the KDE side can't be built (no KF6), so the Fedora CI job is the only check for C++/QML
  changes. Say so in the PR test plan.
- On a headless Mac, `screencapture` doesn't work. Use the debug-only snapshot mode documented under
  **Tests** in [macos/README.md](macos/README.md) (`--snapshots`), and trust its `real-*` captures
  over the offscreen renders.
- To refresh the README screenshots from a session without Screen Recording permission, run
  `open -a Screenshot` (it needs no permission), have the user capture the entire screen, then crop.
