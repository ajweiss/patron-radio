#! /usr/bin/env bash
#
# Translation message extraction for the Patron Radio plasmoid.
#
# Runs under KDE's translation infrastructure (scripty sets $XGETTEXT and
# $podir) and also standalone — just run ./Messages.sh to regenerate the
# template in po/. Translatable strings come from the QML, the C++ backend,
# and the plugin Name/Description in metadata.json.
set -e

DOMAIN="plasma_applet_com.signal11.patronradio"
podir=${podir:-po}
mkdir -p "$podir"

XGETTEXT=${XGETTEXT:-"xgettext --from-code=UTF-8 -C --kde \
  -ci18n -ki18n:1 -ki18nc:1c,2 -ki18np:1,2 -ki18ncp:1c,2,3 \
  -ki18nd:2 -ki18ndc:2c,3 -ki18ndp:2,3 -ki18ndcp:2c,3,4 \
  -ktr2i18n:1 -kI18N_NOOP:1 -kI18NC_NOOP:1c,2"}

# Fold the translatable metadata.json fields (plugin Name/Description) into a
# throwaway C++ unit so they end up in the catalog with everything else.
tmp_meta="rc_metadata.cpp"
python3 - <<'PY' > "$tmp_meta"
import json
kp = json.load(open("metadata.json")).get("KPlugin", {})
for ctx, key in (("Name", "Name"), ("Comment", "Description")):
    val = kp.get(key, "")
    if val:
        print('i18nc(%s, %s);' % (json.dumps(ctx), json.dumps(val)))
PY

# shellcheck disable=SC2086
$XGETTEXT \
  --package-name="Patron Radio" \
  --msgid-bugs-address="https://github.com/ajweiss/patron-radio/issues" \
  -o "$podir/$DOMAIN.pot" \
  "$tmp_meta" \
  $(find contents src \( -name '*.qml' -o -name '*.cpp' \) | sort)

rm -f "$tmp_meta"
echo "Wrote $podir/$DOMAIN.pot"
