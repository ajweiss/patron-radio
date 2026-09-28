# Shared test vectors

Behavior that the Plasma widget (C++, `tests/*.cpp`) and the macOS app
(Swift, `macos/Tests/`) must agree on is written down here once, as data.
Both test suites load these files, so changing a rule means changing one
file and seeing both implementations pass (or fail) against it.

| File | Rule | Widget test | macOS test |
|---|---|---|---|
| `html_entities.json` | Decoding HTML entities in ICY stream titles | `test_icystream` | `HTMLEntityTests` |
| `loudness_gain.json` | Normalization gain for a measured loudness and target | `test_radiobackend` | `LoudnessPolicyTests` |

The default station list isn't duplicated here: `contents/config/main.xml`
is the source of truth, `macos/scripts/sync-stations.sh` generates the Swift
copy, and a macOS test fails if the two drift apart.

Keep cases small and named; the `name` field shows up in test output.
