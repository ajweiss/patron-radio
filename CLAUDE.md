See [AGENTS.md](AGENTS.md).

Quick build, test, install, and restart Plasma:
```bash
cd build && cmake .. -DCMAKE_INSTALL_PREFIX=$HOME/.local && cmake --build . -j$(nproc) && ctest --output-on-failure
make install && systemctl --user restart plasma-plasmashell
```

macOS app (from `macos/`):
```bash
swift test && scripts/build-app.sh && open "dist/Patron Radio.app"
```
