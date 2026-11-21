#!/usr/bin/env bash
# Builds the Debian packages of this tree, all in /usr/share/retrobox-system-settings:
#
#   retrobox-system-settings   what every console needs: retrobox-system-settings
#                              (time zone, keyboard), retrobox-polkit-rule,
#                              retrobox-volume and the shared helpers
#   retrobox-session-labwc     the labwc session on a TTY (a systemd service set
#                              up per user: retrobox-session-install --tty N)
#   retrobox-session-openbox   the Openbox (X11) session for a display manager
#                              (/usr/share/xsessions/retrobox-openbox.desktop)
#
#   packaging/build-deb.sh [VERSION] [OUTPUT_DIR]
#
# VERSION defaults to the latest tag (v1.2 -> 1.2), else 0.0.0; OUTPUT_DIR to
# dist/. Neither session starts by itself: the labwc one belongs to a user and
# a TTY (its install.sh), the Openbox one to the display manager's settings.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="${1:-$(git -C "${ROOT}" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
OUT="${2:-${ROOT}/dist}"
[[ "${VERSION}" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || { echo "build-deb: bad version '${VERSION}'" >&2; exit 1; }
readonly SHARE_PATH="usr/share/retrobox-system-settings"
readonly HOMEPAGE="https://github.com/RetroboxProject/retrobox-system-settings"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# new_package NAME: an empty package tree, printed
new_package() {
  local stage="${WORK}/$1"
  mkdir -p "${stage}/DEBIAN" "${stage}/${SHARE_PATH}" "${stage}/usr/bin" "${stage}/usr/share/doc/$1"
  chmod 0755 "${stage}"
  cp "${ROOT}/LICENSE" "${stage}/usr/share/doc/$1/copyright"
  printf '%s\n' "${stage}"
}

# add STAGE PATH...: files or folders of this tree, at the same place under SHARE_PATH
add() {
  local stage="$1" item
  shift
  for item in "$@"; do
    mkdir -p "${stage}/${SHARE_PATH}/$(dirname -- "${item}")"
    cp -a "${ROOT}/${item}" "${stage}/${SHARE_PATH}/${item}"
  done
}

# command STAGE NAME TARGET: /usr/bin/NAME -> SHARE_PATH/TARGET
command_link() {
  ln -s "../share/retrobox-system-settings/$3" "$1/usr/bin/$2"
}

# control STAGE NAME DEPENDS RECOMMENDS DESCRIPTION...
control() {
  local stage="$1" name="$2" depends="$3" recommends="$4"
  shift 4
  {
    printf 'Package: %s\nVersion: %s\nArchitecture: all\n' "${name}" "${VERSION}"
    printf 'Maintainer: RetroboxProject <%s>\nSection: games\nPriority: optional\n' "${HOMEPAGE}"
    printf 'Depends: %s\n' "${depends}"
    [[ -z "${recommends}" ]] || printf 'Recommends: %s\n' "${recommends}"
    printf 'Homepage: %s\nDescription: %s\n' "${HOMEPAGE}" "$1"
    shift
    printf ' %s\n' "$@"
  } >"${stage}/DEBIAN/control"
}

build() {
  mkdir -p "${OUT}"
  dpkg-deb --root-owner-group --build "$1" "${OUT}/$2_${VERSION}_all.deb" >/dev/null
  echo "${OUT}/$2_${VERSION}_all.deb"
}

## retrobox-system-settings
stage="$(new_package retrobox-system-settings)"
add "${stage}" bin/retrobox-system-settings libexec/retrobox-polkit-rule libexec/retrobox-volume \
  libexec/retrobox-labwc-common.sh
cp "${ROOT}/README.md" "${stage}/usr/share/doc/retrobox-system-settings/"
command_link "${stage}" retrobox-system-settings bin/retrobox-system-settings
command_link "${stage}" retrobox-polkit-rule libexec/retrobox-polkit-rule
control "${stage}" retrobox-system-settings "bash, systemd" \
  "retrobox-core, polkitd, xkb-data, tzdata, wireplumber | pulseaudio-utils" \
  "Retrobox as the machine's only interface: common part" \
  "What every Retrobox console needs, whichever its session:" \
  "retrobox-system-settings, which sets the system's time zone and keyboard" \
  "layout from EmulationStation's console mode, and retrobox-polkit-rule, the" \
  "polkit rule that lets the console's user do that, power off and reboot."
build "${stage}" retrobox-system-settings

## retrobox-session-labwc
stage="$(new_package retrobox-session-labwc)"
add "${stage}" install.sh bin/retrobox-labwc-session libexec/mouse-hide libexec/mouse-show \
  libexec/retrobox-audio-jack libexec/retrobox-switch-display share/labwc
command_link "${stage}" retrobox-session-install install.sh
control "${stage}" retrobox-session-labwc \
  "retrobox-system-settings (= ${VERSION}), libpam-systemd, labwc, pipewire-pulse, foot | alacritty, dbus-bin" \
  "dbus-user-session, wlr-randr, wlrctl, xwayland, pulseaudio-utils, kbd" \
  "Retrobox as the machine's only interface: labwc session" \
  "A labwc (Wayland) session started at boot on a TTY by a systemd service," \
  "for minimal systems with no display manager. The user who plays sets it" \
  "up with: retrobox-session-install --tty N"
build "${stage}" retrobox-session-labwc

## retrobox-session-openbox
stage="$(new_package retrobox-session-openbox)"
add "${stage}" bin/retrobox-openbox-session libexec/retrobox-openbox-autostart share/openbox
mkdir -p "${stage}/usr/share/xsessions"
cp "${ROOT}/share/xsessions/retrobox-openbox.desktop" "${stage}/usr/share/xsessions/"
command_link "${stage}" retrobox-openbox-session bin/retrobox-openbox-session
control "${stage}" retrobox-session-openbox \
  "retrobox-system-settings (= ${VERSION}), openbox" "picom, pulseaudio-utils" \
  "Retrobox as the machine's only interface: Openbox session" \
  "An Openbox (X11) session for a display manager (retrobox-openbox), with" \
  "the picom compositor and Retrobox; a machine adds its own steps in" \
  "/etc/retrobox-system-settings/session.d and its own rc.xml."
build "${stage}" retrobox-session-openbox
