#!/bin/bash
# Regenerate Sources/PatronRadioCore/DefaultStations.swift from the Plasma
# widget's config schema so both apps ship the same curated stations.
#   scripts/sync-stations.sh [path/to/widget-checkout]   (default: the enclosing repo)
set -euo pipefail
cd "$(dirname "$0")/.."
WIDGET=${1:-..}
python3 - "$WIDGET/contents/config/main.xml" Sources/PatronRadioCore/DefaultStations.swift <<'PY'
import json, re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
raw = re.search(r'<entry name="stationsJson" type="String">\s*<default>(.*?)</default>', xml, re.S).group(1)
stations = json.loads(raw)
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("// Generated from patron-radio/contents/config/main.xml (stationsJson default).\n"
            "// Keep in sync with the Plasma widget so both ship the same curated list.\n\n"
            "extension Station {\n    static let defaultStationsJSON = #\"\"\"\n"
            + json.dumps(stations, indent=2, ensure_ascii=False) + "\n\"\"\"#\n}\n")
print(f"{len(stations)} stations")
PY
