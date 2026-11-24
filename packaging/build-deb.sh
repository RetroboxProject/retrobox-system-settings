#!/usr/bin/env bash
# Builds the Debian packages of this tree, all in /opt/retrobox:
#
#   retrobox-system-settings   what every console needs: retrobox-system-settings
#                              (time zone, keyboard), retrobox-polkit-rule,
#                              retrobox-volume and the shared helpers
#   retrobox-session-labwc     the labwc session on a TTY (a systemd service set
#                              up per user: retrobox-session-install --tty N)
#   retrobox-session-openbox   the Openbox (X11) session for a display manager
#                              (/usr/share/xsessions/retrobox-openbox.desktop)
#
# The tree lives in /opt/retrobox (the retrobox layout); only what must be in
# /usr does so: the /usr/bin symlinks and the .desktop file and the polkit
# action, which the session and the desktop manager look up in /usr. The
# machine's configuration (session.d, the Openbox rc.xml) goes in
# /etc/retrobox, and is not shipped here.
#
#   packaging/build-deb.sh [VERSION] [OUTPUT_DIR]
#
# VERSION defaults to the latest tag (v1.2 -> 1.2), else 0.0.0; OUTPUT_DIR to
# dist/. The labwc session sets itself up: its postinst runs install.sh
# --machine (every install, upgrade and dpkg-reconfigure; running it again
# changes nothing), which reads the machine's retrobox.ini under /etc/retrobox
# ([advanced] labwc_user, else the user with uid 1000; labwc_tty, else 8), and
# its prerm takes the service away. The Openbox one belongs to the display
# manager's settings, so it needs nothing.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="${1:-$(git -C "${ROOT}" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
OUT="${2:-${ROOT}/dist}"
[[ "${VERSION}" =~ ^[0-9][0-9A-Za-z.+~-]*$ ]] || { echo "build-deb: bad version '${VERSION}'" >&2; exit 1; }
readonly RETROBOX_PATH="opt/retrobox"
readonly HOMEPAGE="https://github.com/RetroboxProject/retrobox-system-settings"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# new_package NAME: an empty package tree, printed
new_package() {
  local stage="${WORK}/$1"
  mkdir -p "${stage}/DEBIAN" "${stage}/${RETROBOX_PATH}" "${stage}/usr/bin" "${stage}/usr/share/doc/$1"
  chmod 0755 "${stage}"
  cp "${ROOT}/LICENSE" "${stage}/usr/share/doc/$1/copyright"
  printf '%s\n' "${stage}"
}

# add STAGE PATH...: files or folders of this tree, at the same place under RETROBOX_PATH
add() {
  local stage="$1" item
  shift
  for item in "$@"; do
    mkdir -p "${stage}/${RETROBOX_PATH}/$(dirname -- "${item}")"
    cp -a "${ROOT}/${item}" "${stage}/${RETROBOX_PATH}/${item}"
  done
}

# command STAGE NAME TARGET: /usr/bin/NAME -> /opt/retrobox/TARGET (the tree lives in RETROBOX_PATH, thus absolute)
command_link() {
  ln -s "/opt/retrobox/$3" "$1/usr/bin/$2"
}

# maintainer_script STAGE NAME: DEBIAN/NAME, its text on stdin
maintainer_script() {
  cat >"$1/DEBIAN/$2"
  chmod 0755 "$1/DEBIAN/$2"
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
add "${stage}" bin/retrobox-system-settings bin/retrobox-xdp-dns libexec/retrobox-polkit-rule \
  libexec/retrobox-volume libexec/retrobox-common.sh libexec/retrobox-settings-helper
# the polkit action of retrobox-settings-helper (Debian's keyboard and language, with pkexec)
mkdir -p "${stage}/usr/share/polkit-1/actions"
sed -e "s|@HELPER@|/${RETROBOX_PATH}/libexec/retrobox-settings-helper|" \
  -e "s|@MARK@|Installed by the retrobox-system-settings package|" \
  "${ROOT}/share/polkit/org.retroboxproject.system-settings.policy.in" \
  >"${stage}/usr/share/polkit-1/actions/org.retroboxproject.system-settings.policy"
cp "${ROOT}/README.md" "${stage}/usr/share/doc/retrobox-system-settings/"
command_link "${stage}" retrobox-system-settings bin/retrobox-system-settings
command_link "${stage}" retrobox-xdp-dns bin/retrobox-xdp-dns
command_link "${stage}" retrobox-polkit-rule libexec/retrobox-polkit-rule
control "${stage}" retrobox-system-settings "bash, systemd" \
  "retrobox-core, polkitd, pkexec, xkb-data, tzdata, wireplumber | pulseaudio-utils" \
  "Retrobox as the machine's only interface: common part" \
  "What every Retrobox console needs, whichever its session:" \
  "retrobox-system-settings, which sets the system's time zone and keyboard" \
  "layout from EmulationStation's console mode, retrobox-xdp-dns, XDP's DNS" \
  "over TLS on and off (its network settings' toggle), and retrobox-polkit-rule," \
  "the polkit rule that lets the console's user do that, power off and reboot."
build "${stage}" retrobox-system-settings

## retrobox-session-labwc
stage="$(new_package retrobox-session-labwc)"
add "${stage}" install.sh bin/retrobox-session-labwc libexec/mouse-hide libexec/mouse-show \
  libexec/retrobox-audio-jack libexec/retrobox-switch-display share/labwc
mkdir -p "${stage}/usr/share/doc/retrobox-session-labwc/examples"
cp "${ROOT}/share/examples/session-labwc.ini" "${stage}/usr/share/doc/retrobox-session-labwc/examples/"
command_link "${stage}" retrobox-session-install install.sh
maintainer_script "${stage}" postinst <<'SCRIPT'
#!/bin/sh
# Sets the labwc session up for the machine (user and TTY from retrobox.ini
# under /etc/retrobox, else the user with uid 1000 and tty 8); idempotent.
# What cannot be set up fails here, so a machine never looks configured
# when it is not.
set -e
if [ "$1" = configure ]; then
    /opt/retrobox/install.sh --machine
fi
exit 0
SCRIPT
maintainer_script "${stage}" prerm <<'SCRIPT'
#!/bin/sh
# Takes away what the postinst set up in the system (the service and the
# polkit rule). The files in the user's home are the user's: they stay.
set -e
case "$1" in
remove | deconfigure)
    /opt/retrobox/install.sh --uninstall || true
    ;;
esac
exit 0
SCRIPT
control "${stage}" retrobox-session-labwc \
  "retrobox-system-settings (= ${VERSION}), libpam-systemd, util-linux, kbd, labwc, pipewire-pulse, foot | alacritty, dbus-bin" \
  "dbus-user-session, wlr-randr, wlrctl, xwayland, pulseaudio-utils" \
  "Retrobox as the machine's only interface: labwc session" \
  "A labwc (Wayland) session started at boot on a TTY by a systemd service," \
  "for minimal systems with no display manager. The package sets it up by" \
  "itself, on install, upgrade and dpkg-reconfigure: for the user with uid" \
  "1000 on tty8, or the user and TTY (labwc_user, labwc_tty) of the" \
  "[advanced] section of /etc/retrobox/retrobox.ini."
build "${stage}" retrobox-session-labwc

## retrobox-session-openbox
stage="$(new_package retrobox-session-openbox)"
add "${stage}" bin/retrobox-openbox-session libexec/retrobox-openbox-autostart \
  libexec/mouse-hide-x11 libexec/mouse-show-x11 share/openbox
mkdir -p "${stage}/usr/share/xsessions"
cp "${ROOT}/share/xsessions/retrobox-openbox.desktop" "${stage}/usr/share/xsessions/"
command_link "${stage}" retrobox-openbox-session bin/retrobox-openbox-session
control "${stage}" retrobox-session-openbox \
  "retrobox-system-settings (= ${VERSION}), openbox, unclutter-xfixes" \
  "picom, pulseaudio-utils" \
  "Retrobox as the machine's only interface: Openbox session" \
  "An Openbox (X11) session for a display manager (retrobox-openbox), with" \
  "the picom compositor and Retrobox; a machine adds its own steps in" \
  "/etc/retrobox/session.d and its own rc.xml."
build "${stage}" retrobox-session-openbox
