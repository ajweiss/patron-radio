See [CONTRIBUTING.md](CONTRIBUTING.md).

The macOS companion app lives in `macos/` (Swift package; see [macos/README.md](macos/README.md)):
```bash
cd macos && swift test && scripts/build-app.sh
```
Rules both apps share are test vectors in `tests/data/`. Change them there, not in one suite.
