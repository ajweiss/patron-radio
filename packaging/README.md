# Packaging

Sources of truth for the distribution packages. The AUR and COPR consume
release tags from GitHub, so a release must be tagged (`vX.Y`) before either
package can build.

## Release checklist

1. Bump the version in `CMakeLists.txt` (`project(PatronRadio VERSION X.Y)`)
   and `metadata.json` (`"Version"`), and in `aur/PKGBUILD` (`pkgver`) and
   `fedora/patron-radio.spec` (`Version:` + a new `%changelog` entry), and
   `macos/Resources/Info.plist` (`CFBundleShortVersionString`).
2. Commit, then tag and push:
   ```bash
   git tag -s vX.Y -m "Patron Radio X.Y"
   git push origin main vX.Y
   ```
3. Update `aur/PKGBUILD` checksums (`updpkgsums`) and publish to the AUR
   (see below).
4. Build the SRPM and submit to COPR (see below).

## AUR (`plasma6-applets-patron-radio`)

Test locally, then push to the AUR package repo (separate from this repo):

```bash
cd packaging/aur
updpkgsums                      # fill in sha256sums from the release tarball
makepkg -sfc                    # clean build + tests
namcap PKGBUILD *.pkg.tar.zst   # lint (optional)

# First-time setup: create the package repo (requires an AUR account with
# your SSH key registered)
git clone ssh://aur@aur.archlinux.org/plasma6-applets-patron-radio.git aur-repo
cp PKGBUILD aur-repo/ && cd aur-repo
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Update to X.Y"
git push
```

## Fedora COPR

The spec downloads its source from the GitHub tag. Build the SRPM in a
Fedora container (works from any distro), then submit it:

```bash
podman run --rm -v "$PWD":/work -w /work registry.fedoraproject.org/fedora:42 bash -c '
  dnf install -y rpmdevtools &&
  spectool -g -C . packaging/fedora/patron-radio.spec &&
  rpmbuild -bs packaging/fedora/patron-radio.spec \
    --define "_sourcedir /work" --define "_srcrpmdir /work"
'

# First-time setup: get an API token from https://copr.fedorainfracloud.org/api
# into ~/.config/copr, then create the project once:
copr-cli create patron-radio \
  --chroot fedora-42-x86_64 --chroot fedora-43-x86_64 \
  --chroot fedora-rawhide-x86_64

copr-cli build patron-radio patron-radio-*.src.rpm
```

Users then install with:
```bash
sudo dnf copr enable <copr-user>/patron-radio && sudo dnf install patron-radio
```

## Not yet covered

openSUSE (OBS) and Debian/Ubuntu packaging are still to do. The Fedora spec
is a reasonable starting point for an OBS RPM; Debian needs a `debian/`
directory (control/rules/changelog).

## macOS

The macOS companion app isn't packaged through the AUR or COPR. Build a
signed, notarized `Patron Radio.app` from `macos/` as described in
[macos/README.md](../macos/README.md#build--run) and attach it to the
GitHub release.
