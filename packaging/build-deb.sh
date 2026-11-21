#!/usr/bin/env bash
# Builds retrobox-system-settings_<version>_all.deb: this tree in
# /usr/share/retrobox-system-settings, with apt pulling what the session needs.
#
#   packaging/build-deb.sh [VERSION] [OUTPUT_DIR]
#
# VERSION defaults to the latest tag (v1.2 -> 1.2), else 0.0.0; OUTPUT_DIR to
# dist/. The package installs no session by itself: the session belongs to a
# user and a TTY, so after installing it, that user runs
#   retrobox-session-install --tty N
# (install.sh), which sets up their home, the service and the polkit rule as
# before; retrobox-system-settings is also in /usr/bin for everyone.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="${1:-$(git -C "${ROOT}" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
OUT="${2:-${ROOT}/dist}"
[[ "${VERSION}" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || { echo "build-deb: bad version '${VERSION}'" >&2; exit 1; }

STAGE="$(mktemp -d)"
chmod 0755 "${STAGE}"
trap 'rm -rf "${STAGE}"' EXIT
SHARE="${STAGE}/usr/share/retrobox-system-settings"
mkdir -p "${SHARE}" "${STAGE}/usr/bin" "${STAGE}/usr/share/doc/retrobox-system-settings" "${STAGE}/DEBIAN"
cp -a "${ROOT}/install.sh" "${ROOT}/bin" "${ROOT}/libexec" "${ROOT}/share" "${SHARE}/"
ln -s ../share/retrobox-system-settings/bin/retrobox-system-settings "${STAGE}/usr/bin/retrobox-system-settings"
ln -s ../share/retrobox-system-settings/install.sh "${STAGE}/usr/bin/retrobox-session-install"
cp "${ROOT}/README.md" "${STAGE}/usr/share/doc/retrobox-system-settings/"
cp "${ROOT}/LICENSE" "${STAGE}/usr/share/doc/retrobox-system-settings/copyright"

cat >"${STAGE}/DEBIAN/control" <<CONTROL
Package: retrobox-system-settings
Version: ${VERSION}
Architecture: all
Maintainer: RetroboxProject <https://github.com/RetroboxProject>
Section: games
Priority: optional
Depends: bash, systemd, libpam-systemd, labwc, pipewire-pulse, foot | alacritty, dbus-bin
Recommends: retrobox-core, dbus-user-session, polkitd, wireplumber, wlr-randr, wlrctl, xwayland, pulseaudio-utils, kbd, xkb-data, tzdata
Homepage: https://github.com/RetroboxProject/retrobox-system-settings
Description: Retrobox as the machine's only interface
 Turns a minimal system into a Retrobox console: a labwc session started at
 boot on a TTY by a systemd service (set up per user with
 retrobox-session-install), and retrobox-system-settings, which sets the
 system's time zone and keyboard layout from EmulationStation's console mode.
CONTROL

mkdir -p "${OUT}"
dpkg-deb --root-owner-group --build "${STAGE}" "${OUT}/retrobox-system-settings_${VERSION}_all.deb" >/dev/null
echo "${OUT}/retrobox-system-settings_${VERSION}_all.deb"
