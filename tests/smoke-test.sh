#!/usr/bin/env bash
# Smoke test for install.sh and the session script, with stand-in commands
# (no labwc, no systemd, no root needed). Everything happens in a throwaway
# HOME.
#
#   tests/smoke-test.sh
# shellcheck disable=SC2015,SC2016  # "A && B || fail" is how the checks read
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
expect_fail() { if "$@" >"${WORK}/out" 2>&1; then fail "should have failed: $*"; fi; }

export HOME="${WORK}/home"
mkdir -p "${HOME}"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME RETROBOX_CONFIGDIR
export XDG_RUNTIME_DIR="${WORK}/run"
mkdir -p "${XDG_RUNTIME_DIR}"
export RETROBOX_SYSCONFDIR="${WORK}/etc-retrobox"
export RETROBOX_KEYBOARD_FILE="${WORK}/keyboard"
export RETROBOX_OS_RELEASE="${WORK}/os-release"
printf 'ID=debian\n' >"${RETROBOX_OS_RELEASE}"
printf 'XKBMODEL="pc105"\nXKBLAYOUT="es"\nXKBVARIANT=""\nXKBOPTIONS="grp:alt_shift_toggle"\n' >"${RETROBOX_KEYBOARD_FILE}"

# --- stand-in commands -------------------------------------------------------------
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
for cmd in labwc pipewire-pulse foot dbus-run-session wlr-randr wpctl Xwayland chvt retrobox; do
  printf '#!/bin/sh\nexit 0\n' >"${STUBS}/${cmd}"
done
mkdir -p "${WORK}/core/bin"
mv "${STUBS}/retrobox" "${WORK}/core/bin/retrobox"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox-screenshot"
# A fake systemd: units are the base ExecStart plus whatever drop-ins are in
# RETROBOX_SYSTEMD_DIR; "enabled" is a marker file. sudo just runs the command.
export RETROBOX_SYSTEMD_DIR="${WORK}/systemd"
export STUB_STATE="${WORK}/state"
export RETROBOX_POLKIT_DIR="${WORK}/polkit"
export RETROBOX_POLKIT_ACTIONS_DIR="${WORK}/polkit-actions"
export RETROBOX_SETTINGS_HELPER="${WORK}/usr-local/libexec/retrobox-settings-helper"
POLICY="${RETROBOX_POLKIT_ACTIONS_DIR}/org.retroboxproject.system-settings.policy"
mkdir -p "${RETROBOX_SYSTEMD_DIR}" "${STUB_STATE}"
cat >"${STUBS}/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  cat)
    tty="${2#getty@tty}"; tty="${tty%.service}"
    echo "ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear %I \$TERM"
    cat "${RETROBOX_SYSTEMD_DIR}/getty@tty${tty}.service.d/"*.conf 2>/dev/null
    exit 0 ;;
  is-enabled) [ -e "${STUB_STATE}/enabled-$3" ] ;;
  enable) touch "${STUB_STATE}/enabled-$2" ;;
  disable) rm -f "${STUB_STATE}/enabled-$2" ;;
  daemon-reload) exit 0 ;;
  poweroff) touch "${STUB_STATE}/poweroff" ;;
  list-jobs) [ -e "${STUB_STATE}/reboot-pending" ] && echo "1 reboot.target start waiting" ; exit 0 ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nexec "$@"\n' >"${STUBS}/sudo"
chmod +x "${STUBS}"/* "${WORK}/core/bin/"*
export RETROBOX_ROOT="${WORK}/core"
BASE_PATH="${PATH}"
# systemd user units: pipewire-pulse's is only there once the package is
export RETROBOX_USER_UNIT_DIRS="${WORK}/units"
mkdir -p "${WORK}/units"

install_sh() { "${ROOT}/install.sh" "$@"; }

# --- 1. nothing installed: the check fails and says what to install -----------------
mkdir -p "${WORK}/bare"
for need in sed awk grep cat date mkdir rm cp mv ln tail head tr cut id readlink realpath dirname mktemp getent rmdir touch pgrep pkill sleep tty env; do
  ln -sf "$(PATH="${BASE_PATH}" command -v "${need}")" "${WORK}/bare/${need}"
done
PATH="${WORK}/bare" expect_fail "$(command -v bash)" "${ROOT}/install.sh" --check --tty 8; cat "${WORK}/out" >&2
grep -q 'labwc is not installed' "${WORK}/out" || fail "missing labwc not reported"
grep -q 'sudo apt install labwc pipewire-pulse foot dbus-bin' "${WORK}/out" || fail "install hint wrong: $(cat "${WORK}/out")"
PATH="${STUBS}:${BASE_PATH}"
pass "missing dependencies are reported with an apt hint"

# --- 1b. the pipewire-pulse command alone is not enough (Arch's pipewire package has it) ---
expect_fail install_sh --check --tty 8
grep -q 'pipewire-pulse is not installed' "${WORK}/out" || fail "pipewire-pulse without its unit accepted"
touch "${WORK}/units/pipewire-pulse.service"
pass "pipewire-pulse needs its systemd unit, not just the command"

# --- 2. the check of the service: read-only, with the way to fix it ------------------------
UNIT="${RETROBOX_SYSTEMD_DIR}/retrobox-session-labwc.service"
expect_fail install_sh --check --tty 8
grep -q 'retrobox-session-labwc.service is not installed' "${WORK}/out" || fail "missing service not reported"
grep -q 'Conflicts=getty@tty8.service' "${WORK}/out" && grep -q 'PAMName=login' "${WORK}/out" || fail "no hint with the service"
[[ -z "$(ls -A "${RETROBOX_SYSTEMD_DIR}")" ]] || fail "--check wrote to the system"
expect_fail install_sh --no-system --tty 8
grep -q 'service is not set up and --no-system' "${WORK}/out" || fail "--no-system did not refuse"
pass "the service check is read-only and prints the way to set it up by hand"

# --- 3. install (writes the service through sudo) --------------------------------------------
printf '# my profile\nexport FOO=1' >"${HOME}/.profile" # no trailing newline on purpose
expect_fail install_sh # no --tty the first time
[[ ! -e "${HOME}/.local/share/retrobox-session-labwc" ]] || fail "--no-system left files behind"
install_sh --tty 8 >"${WORK}/out" 2>&1 || fail "install failed: $(cat "${WORK}/out")"
DATA="${HOME}/.local/share/retrobox-session-labwc"
grep -q "^User=$(id -un)\$" "${UNIT}" && grep -q '^TTYPath=/dev/tty8$' "${UNIT}" && grep -q '^Conflicts=getty@tty8.service$' "${UNIT}" || fail "unit wrong: $(cat "${UNIT}")"
grep -q '^Environment=RETROBOX_LABWC_TTY=8$' "${UNIT}" && grep -q "^ExecStart=/bin/bash -lc 'exec ${DATA}/bin/retrobox-session-labwc'\$" "${UNIT}" || fail "unit does not run the session: $(cat "${UNIT}")"
grep -q '^ExecStopPost=+-/bin/sh -c .*list-jobs.*retrobox-session-labwc.service +(start|restart).* --no-block start getty@tty8.service.$' "${UNIT}" && grep -q '^ExecStartPre=+-.*chvt 8$' "${UNIT}" || fail "unit does not give the tty back: $(cat "${UNIT}")"
[[ -e "${STUB_STATE}/enabled-retrobox-session-labwc.service" ]] || fail "service not enabled at boot"
install_sh --check --tty 8 >/dev/null 2>&1 || fail "check fails after the install"
[[ -x "${DATA}/install.sh" && -x "${DATA}/bin/retrobox-session-labwc" ]] || fail "tree not copied"
grep -q 'labwc_tty = 8' "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" || fail "tty not written"
grep -q "${DATA}/libexec/retrobox-switch-display" "${HOME}/.config/retrobox-session-labwc/autostart" || fail "autostart not rendered"
grep -q "<command>foot</command>" "${HOME}/.config/retrobox-session-labwc/rc.xml" || fail "terminal not rendered"
grep -q "${WORK}/core/bin/retrobox-screenshot" "${HOME}/.config/retrobox-session-labwc/rc.xml" || fail "screenshot not rendered"
grep -q '@DEFAULT_AUDIO_SOURCE@' "${HOME}/.config/retrobox-session-labwc/rc.xml" || fail "wpctl placeholder was clobbered"
! grep -q 'go2tty\|exit-tty' "${HOME}/.config/retrobox-session-labwc/rc.xml" || fail "leftovers in rc.xml"
[[ "$(cat "${HOME}/.profile")" == $'# my profile\nexport FOO=1' ]] || fail "the profile was touched"
RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-console.rules"
grep -q "subject.user != \"$(id -un)\"" "${RULE}" && grep -q 'login1.reboot' "${RULE}" && grep -q 'login1.power-off' "${RULE}" || fail "polkit rule wrong"
grep -q 'manage-units' "${RULE}" && grep -q 'action.lookup("unit") == "retrobox-session-labwc.service"' "${RULE}" || fail "polkit rule does not cover the service"
grep -q 'timedate1.set-timezone' "${RULE}" && grep -q 'locale1.set-keyboard' "${RULE}" && grep -q 'locale1.set-locale' "${RULE}" \
  || fail "polkit rule does not cover the time zone, keyboard and language"
grep -q '"org.retroboxproject.system-settings.set"' "${RULE}" || fail "polkit rule does not cover the settings helper"
cmp -s "${ROOT}/libexec/retrobox-settings-helper" "${RETROBOX_SETTINGS_HELPER}" || fail "settings helper not installed"
grep -q "exec.path\">${RETROBOX_SETTINGS_HELPER}<" "${POLICY}" && grep -q 'id="org.retroboxproject.system-settings.set"' "${POLICY}" \
  || fail "settings helper's polkit action wrong: $(cat "${POLICY}")"
grep -q "^system_settings = ${DATA}/bin/retrobox-system-settings\$" "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" || fail "[core] system_settings not written"
grep -qx 'console_mode = true' "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" || fail "console mode not turned on"
[[ "$(readlink -- "${HOME}/.local/bin/retrobox-system-settings")" == "${DATA}/bin/retrobox-system-settings" ]] || fail "retrobox-system-settings not linked"
pass "install renders the service and the config; the profile stays untouched"

# --- 4. the TTY is locked once installed -----------------------------------------------
expect_fail install_sh --tty 2
grep -q 'already installed on tty8' "${WORK}/out" || fail "tty change not refused: $(cat "${WORK}/out")"
install_sh --tty 08 >/dev/null 2>&1 || fail "re-install on the same tty refused"
"${DATA}/install.sh" >/dev/null 2>&1 || fail "re-install without --tty from the installed copy failed"
grep -q 'system_unit=' "${DATA}/.install-manifest" && grep -q 'polkit_rule=' "${DATA}/.install-manifest" || fail "re-install lost the manifest notes"
pass "the TTY cannot change without uninstall; re-install is idempotent"

# --- 5. uninstall undoes the system part and leaves the profile as it was ------------------
"${DATA}/install.sh" --uninstall >/dev/null 2>&1 || fail "uninstall failed"
[[ ! -e "${DATA}" && ! -e "${HOME}/.config/retrobox-session-labwc" && ! -e "${HOME}/.config/retrobox/retrobox.ini.d/50-labwc.ini" ]] || fail "files left"
[[ "$(cat "${HOME}/.profile")" == $'# my profile\nexport FOO=1' ]] || fail "profile not restored: $(cat "${HOME}/.profile")"
[[ ! -e "${UNIT}" && ! -e "${STUB_STATE}/enabled-retrobox-session-labwc.service" ]] || fail "service not removed"
[[ ! -e "${RULE}" ]] || fail "polkit rule not removed"
[[ ! -e "${POLICY}" && ! -e "${RETROBOX_SETTINGS_HELPER}" ]] || fail "settings helper or its action not removed"
pass "uninstall removes the service, the rule and the settings helper, and restores the profile"

# --- 5b. an install of the previous version (login hook + autologin drop-in) is migrated ---
OLD="${RETROBOX_SYSTEMD_DIR}/getty@tty8.service.d/retrobox-labwc.conf"
mkdir -p "$(dirname "${OLD}")" "${HOME}/.local/share/retrobox-labwc"
printf '# Written by retrobox-labwc: old\n[Service]\nExecStart=\n' >"${OLD}"
touch "${STUB_STATE}/enabled-getty@tty8.service"
printf 'tty=8\nuser=%s\nsystem_dropin=%s\ngetty_enabled=1\n' "$(id -un)" "${OLD}" >"${HOME}/.local/share/retrobox-labwc/.install-manifest"
printf '# my profile\n# >>> retrobox-labwc (managed by its install.sh; removed by --uninstall) >>>\n. hook\n# <<< retrobox-labwc <<<\n' >"${HOME}/.profile"
install_sh >/dev/null 2>&1 || fail "migration install failed"
[[ ! -e "${OLD}" && ! -e "${STUB_STATE}/enabled-getty@tty8.service" ]] || fail "old autologin drop-in left"
! grep -q 'retrobox-labwc' "${HOME}/.profile" && grep -q '^# my profile$' "${HOME}/.profile" || fail "old login hook left: $(cat "${HOME}/.profile")"
[[ -f "${UNIT}" ]] && ! grep -q 'system_dropin' "${HOME}/.local/share/retrobox-session-labwc/.install-manifest" || fail "migration did not switch to the service"
"${HOME}/.local/share/retrobox-session-labwc/install.sh" --uninstall >/dev/null 2>&1
pass "an install with the login hook and the autologin drop-in is migrated to the service"

# --- 5c. an install of retrobox-labwc (the old names) moves to the new ones ---
OLD_DATA="${HOME}/.local/share/retrobox-labwc"
OLD_UNIT="${RETROBOX_SYSTEMD_DIR}/retrobox-labwc.service"
OLD_RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-labwc.rules"
mkdir -p "${OLD_DATA}" "${HOME}/.config/retrobox-labwc" "${RETROBOX_POLKIT_DIR}" "${HOME}/.local/bin"
printf '# Written by retrobox-labwc: the labwc gaming session\n[Service]\n' >"${OLD_UNIT}"
printf '// Written by retrobox-labwc: old rule\n' >"${OLD_RULE}"
touch "${STUB_STATE}/enabled-retrobox-labwc.service"
printf 'tty=5\nuser=%s\nsystem_unit=%s\npolkit_rule=%s\n' "$(id -un)" "${OLD_UNIT}" "${OLD_RULE}" >"${OLD_DATA}/.install-manifest"
printf 'shell\n' >"${HOME}/.config/retrobox-labwc/on_quit"
ln -sfn "${OLD_DATA}/bin/retrobox-labwc-session" "${HOME}/.local/bin/retrobox-labwc-session"
install_sh >/dev/null 2>&1 || fail "the move to the new names failed"
[[ ! -e "${OLD_UNIT}" && ! -e "${OLD_RULE}" && ! -e "${STUB_STATE}/enabled-retrobox-labwc.service" ]] || fail "old service or rule left"
[[ ! -e "${OLD_DATA}" && ! -e "${HOME}/.config/retrobox-labwc" && ! -L "${HOME}/.local/bin/retrobox-labwc-session" ]] || fail "old copy, config or link left"
grep -q 'TTYPath=/dev/tty5' "${UNIT}" && [[ -f "${RETROBOX_POLKIT_DIR}/50-retrobox-console.rules" ]] || fail "not installed under the new names on tty5"
[[ "$(cat "${HOME}/.config/retrobox-session-labwc/on_quit")" == "shell" ]] || fail "the on-quit choice was not kept"
grep -qx "system_unit=${UNIT}" "${HOME}/.local/share/retrobox-session-labwc/.install-manifest" && ! grep -q 'retrobox-labwc.service\|50-retrobox-labwc' "${HOME}/.local/share/retrobox-session-labwc/.install-manifest" || fail "manifest still names the old files"
"${HOME}/.local/share/retrobox-session-labwc/install.sh" --uninstall >/dev/null 2>&1
[[ ! -e "${UNIT}" && ! -e "${RETROBOX_POLKIT_DIR}/50-retrobox-console.rules" ]] || fail "uninstall after the move left files"
pass "an install of retrobox-labwc moves to the new names, keeping its TTY and on-quit choice"

# --- 7. keyboard: read from the system, at every start -----------------------------------
# shellcheck source=libexec/retrobox-common.sh
source "${ROOT}/libexec/retrobox-common.sh"
export_keyboard_env
[[ "${XKB_DEFAULT_LAYOUT}|${XKB_DEFAULT_MODEL}|${XKB_DEFAULT_OPTIONS}" == "es|pc105|grp:alt_shift_toggle" ]] || fail "keyboard env wrong"
[[ -z "${XKB_DEFAULT_VARIANT+x}" ]] || fail "empty variant exported"
printf 'XKBLAYOUT=de\nXKBVARIANT=nodeadkeys\n' >"${RETROBOX_KEYBOARD_FILE}"
export_keyboard_env
[[ "${XKB_DEFAULT_LAYOUT}|${XKB_DEFAULT_VARIANT}" == "de|nodeadkeys" && -z "${XKB_DEFAULT_MODEL+x}" ]] || fail "keyboard change not picked up"
pass "keyboard layout follows the system file"

# --- 8. the session: starts labwc + retrobox, passes the keyboard, restarts on request ------
printf 'XKBLAYOUT="es"\n' >"${RETROBOX_KEYBOARD_FILE}"
install_sh --tty 8 --on-quit shell >/dev/null 2>&1
[[ "$(cat "${HOME}/.config/retrobox-session-labwc/on_quit")" == "shell" ]] || fail "--on-quit shell not written"
RUNS="${WORK}/runs"
: >"${RUNS}"
# dbus-run-session -- CMD...
printf '#!/bin/sh\necho private-bus >>"%s"\nshift\nexec "$@"\n' "${RUNS}" >"${STUBS}/dbus-run-session"
# labwc [-C DIR]: runs the autostart like labwc does, records its keyboard, lives until killed
cat >"${STUBS}/labwc" <<SH
#!/bin/sh
[ "\$1" = "-C" ] && dir="\$2"
echo "labwc layout=\$XKB_DEFAULT_LAYOUT dir=\$dir" >>"${RUNS}"
printf 'WAYLAND_DISPLAY=wayland-test\n' >"\${RETROBOX_LABWC_ENV_FILE}"
trap 'kill \$pid 2>/dev/null; exit 0' TERM
sleep 30 &
pid=\$!
wait
SH
# retrobox: first run waits (so the test can restart), later runs end by themselves
cat >"${WORK}/core/bin/retrobox" <<SH
#!/bin/sh
echo "retrobox display=\$WAYLAND_DISPLAY" >>"${RUNS}"
n=\$(grep -c '^retrobox' "${RUNS}")
if [ "\$n" -ge 2 ]; then exit 0; fi
exec sleep 30
SH
chmod +x "${STUBS}"/* "${WORK}/core/bin/retrobox"
export RETROBOX_LABWC_LOG="${WORK}/session.log"
"${HOME}/.local/bin/retrobox-session-labwc" -f &
SESSION=$!
for _ in $(seq 1 100); do grep -q '^retrobox' "${RUNS}" && break; sleep 0.1; done
grep -q 'labwc layout=es dir=.*/retrobox-session-labwc' "${RUNS}" || fail "labwc not started with the keyboard and config dir: $(cat "${RUNS}" "${RETROBOX_LABWC_LOG}")"
grep -q 'retrobox display=wayland-test' "${RUNS}" || fail "retrobox did not get labwc's environment"
printf 'XKBLAYOUT="fr"\n' >"${RETROBOX_KEYBOARD_FILE}"
"${HOME}/.local/bin/retrobox-session-labwc" --restart || fail "--restart failed"
for _ in $(seq 1 150); do kill -0 "${SESSION}" 2>/dev/null || break; sleep 0.1; done
wait "${SESSION}" || fail "session exited with an error"
[[ "$(grep -c '^labwc' "${RUNS}")" == 2 ]] || fail "session did not restart: $(cat "${RUNS}")"
grep -q 'labwc layout=fr' "${RUNS}" || fail "restart did not pick up the new keyboard: $(cat "${RUNS}")"
pgrep -u "$(id -u)" -f "sleep 30" >/dev/null && pkill -u "$(id -u)" -f "sleep 30" || true
pass "the session starts, restarts on request and re-reads the keyboard"

# --- 8b. a stop request (systemctl stop) closes labwc and retrobox promptly --------------
printf '#!/bin/sh\necho "retrobox display=\$WAYLAND_DISPLAY" >>"%s"\nexec sleep 30\n' "${RUNS}" >"${WORK}/core/bin/retrobox"
chmod +x "${WORK}/core/bin/retrobox"
: >"${RUNS}"
"${HOME}/.local/bin/retrobox-session-labwc" -f &
SESSION=$!
for _ in $(seq 1 100); do grep -q '^retrobox' "${RUNS}" && break; sleep 0.1; done
kill -TERM "${SESSION}"
for _ in $(seq 1 80); do kill -0 "${SESSION}" 2>/dev/null || break; sleep 0.1; done
! kill -0 "${SESSION}" 2>/dev/null || fail "the session did not stop on SIGTERM within 8s"
wait "${SESSION}" 2>/dev/null || true
! pgrep -u "$(id -u)" -x labwc >/dev/null || fail "labwc left behind after a stop request"
pass "SIGTERM stops the whole session promptly"

# --- 8c. the user's own bus is used when it exists; a private one is the fallback ------------
printf '#!/bin/sh\necho "bus=$DBUS_SESSION_BUS_ADDRESS user=${RETROBOX_LABWC_USER_BUS:-}" >>"%s"\nexit 0\n' "${RUNS}" >"${WORK}/core/bin/retrobox"
chmod +x "${WORK}/core/bin/retrobox"
: >"${RUNS}"
"${HOME}/.local/bin/retrobox-session-labwc" -f || fail "session without a user bus failed"
grep -q '^private-bus$' "${RUNS}" && grep -q 'user=$' "${RUNS}" || fail "no private bus without a user bus: $(cat "${RUNS}")"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${XDG_RUNTIME_DIR}/bus"
: >"${RUNS}"
"${HOME}/.local/bin/retrobox-session-labwc" -f || fail "session on the user bus failed"
grep -q "bus=unix:path=${XDG_RUNTIME_DIR}/bus user=1" "${RUNS}" && ! grep -q '^private-bus$' "${RUNS}" || fail "user bus not used: $(cat "${RUNS}")"
: >"${RUNS}"
RETROBOX_LABWC_PRIVATE_BUS=1 "${HOME}/.local/bin/retrobox-session-labwc" -f || fail "forced private bus failed"
grep -q '^private-bus$' "${RUNS}" || fail "RETROBOX_LABWC_PRIVATE_BUS ignored"
rm -f "${XDG_RUNTIME_DIR}/bus"
pass "the session uses the user bus when there is one, dbus-run-session otherwise"

# --- 8d. retrobox-audio-jack: analog duplex with headphones, HDMI without --------------------
# A stand-in pactl whose "list cards" comes from a file; set-card-profile is recorded.
printf '#!/bin/sh\ncase "$1" in\n  info) exit 0 ;;\n  list) cat "%s/cards.txt" ;;\n  set-card-profile) echo "$2 $3" >"%s/profile-set" ;;\nesac\n' "${STUB_STATE}" "${STUB_STATE}" >"${STUBS}/pactl"
chmod +x "${STUBS}/pactl"
# cards HEADPHONES(available|not available) ACTIVE HDMI(yes|no)
cards() {
  printf 'Card #46\n\tName: alsa_card.pci-0000_00_03.0\n\tProfiles:\n' >"${STUB_STATE}/cards.txt"
  {
    printf '\t\toutput:analog-stereo+input:analog-stereo: Duplex (sinks: 1, sources: 1, priority: 6565, available: yes)\n'
    printf '\t\toutput:hdmi-stereo: HDMI (sinks: 1, sources: 0, priority: 5900, available: %s)\n' "$3"
    printf '\t\toutput:hdmi-stereo+input:analog-stereo: HDMI y entrada (sinks: 1, sources: 1, priority: 5965, available: %s)\n' "$3"
    printf '\t\toff: Off (sinks: 0, sources: 0, priority: 0, available: yes)\n'
    printf '\tActive Profile: %s\n\tPorts:\n' "$2"
    printf '\t\tanalog-output-headphones: Auriculares (type: Headphones, priority: 9900, availability group: Legacy 3, %s)\n' "$1"
  } >>"${STUB_STATE}/cards.txt"
  rm -f "${STUB_STATE}/profile-set"
}
JACK="${ROOT}/libexec/retrobox-audio-jack"
ANALOG="output:analog-stereo+input:analog-stereo"
cards "not available" "${ANALOG}" yes
"${JACK}" --once 2>/dev/null
[[ "$(cat "${STUB_STATE}/profile-set")" == "alsa_card.pci-0000_00_03.0 output:hdmi-stereo+input:analog-stereo" ]] || fail "no HDMI profile without headphones: $(cat "${STUB_STATE}/profile-set" 2>&1)"
cards "available" "output:hdmi-stereo+input:analog-stereo" yes
"${JACK}" --once 2>/dev/null
[[ "$(cat "${STUB_STATE}/profile-set")" == "alsa_card.pci-0000_00_03.0 ${ANALOG}" ]] || fail "no analog profile with headphones"
cards "not available" "${ANALOG}" no
"${JACK}" --once 2>/dev/null
[[ ! -e "${STUB_STATE}/profile-set" ]] || fail "left analog without an HDMI profile available"
cards "available" "${ANALOG}" yes
"${JACK}" --once 2>/dev/null
[[ ! -e "${STUB_STATE}/profile-set" ]] || fail "changed a profile that was already right"
cards "not available" "${ANALOG}" yes
RETROBOX_AUDIO_HDMI_PROFILE=output:hdmi-stereo "${JACK}" --once 2>/dev/null
[[ "$(cat "${STUB_STATE}/profile-set")" == "alsa_card.pci-0000_00_03.0 output:hdmi-stereo" ]] || fail "RETROBOX_AUDIO_HDMI_PROFILE ignored"
grep -q 'retrobox-audio-jack' "${HOME}/.config/retrobox-session-labwc/autostart" || fail "audio jack script not in the autostart"
pass "the audio profile follows the headphone jack: analog duplex with them, HDMI without"

# --- 9. on_quit = poweroff: only a normal quit of retrobox powers off ---------------------
[[ ! -e "${STUB_STATE}/poweroff" ]] || fail "powered off without being asked"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox"
install_sh --tty 8 >/dev/null 2>&1 # a re-run keeps the choice
[[ "$(cat "${HOME}/.config/retrobox-session-labwc/on_quit")" == "shell" ]] || fail "re-run changed on_quit"
install_sh --tty 8 --on-quit poweroff >/dev/null 2>&1
[[ "$(cat "${HOME}/.config/retrobox-session-labwc/on_quit")" == "poweroff" ]] || fail "--on-quit poweroff not written"
"${HOME}/.local/bin/retrobox-session-labwc" -f || fail "session failed"
[[ -e "${STUB_STATE}/poweroff" ]] || fail "no poweroff after a normal quit"
rm -f "${STUB_STATE}/poweroff"
printf '#!/bin/sh\nexit 3\n' >"${WORK}/core/bin/retrobox"
"${HOME}/.local/bin/retrobox-session-labwc" -f || true
[[ ! -e "${STUB_STATE}/poweroff" ]] || fail "powered off after a crash"
pass "a normal quit powers off when on_quit says so, never after a failure"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox"
touch "${STUB_STATE}/reboot-pending"
"${HOME}/.local/bin/retrobox-session-labwc" -f || fail "session failed"
[[ ! -e "${STUB_STATE}/poweroff" ]] || fail "poweroff replaced a reboot already in progress"
rm -f "${STUB_STATE}/reboot-pending"
pass "a reboot requested by retrobox is not overridden by the poweroff"
expect_fail install_sh --on-quit reboot
"${HOME}/.local/share/retrobox-session-labwc/install.sh" --uninstall >/dev/null 2>&1
install_sh --tty 8 --no-polkit >/dev/null 2>&1 || fail "install --no-polkit failed"
[[ ! -e "${RULE}" ]] || fail "--no-polkit still wrote the rule"
pass "--no-polkit skips the rule"
rm -rf "${HOME}/.config/retrobox-session-labwc" "${HOME}/.local/share/retrobox-session-labwc"
install_sh --tty 8 >/dev/null 2>&1
[[ "$(cat "${HOME}/.config/retrobox-session-labwc/on_quit")" == "poweroff" ]] || fail "first install must default to poweroff"
pass "the first install powers off on quit by default"

# --- 10. the resolution is the kernel command line's video=, nothing else -----------------
RANDR_LOG="${WORK}/randr.log"
cat >"${STUBS}/wlr-randr" <<SH
#!/bin/sh
if [ \$# -eq 0 ]; then
  printf 'HDMI-A-2 "LG"\\n  Enabled: yes\\n'
else
  echo "\$*" >>"${RANDR_LOG}"
fi
SH
chmod +x "${STUBS}/wlr-randr"
DISPLAY_SH="${ROOT}/libexec/retrobox-switch-display"
randr_with() { # randr_with CMDLINE ARG: what wlr-randr was asked to do
  : >"${RANDR_LOG}"
  printf '%s\n' "$1" >"${WORK}/cmdline"
  RETROBOX_CMDLINE_FILE="${WORK}/cmdline" "${DISPLAY_SH}" "$2" >/dev/null 2>&1 || true
  cat "${RANDR_LOG}"
}
[[ "$(randr_with 'quiet video=HDMI-A-2:1280x720@60' mode)" == "--output HDMI-A-2 --mode 1280x720@60Hz" ]] || fail "video= not applied"
[[ -z "$(randr_with 'quiet video=HDMI-A-1:1280x720@60' mode)" ]] || fail "video= of another connector applied"
[[ -z "$(randr_with 'quiet video=efifb:off' mode)" ]] || fail "a non-mode video= applied"
[[ "$(randr_with 'video=HDMI-A-2:1280x720' mode)" == "--output HDMI-A-2 --mode 1280x720" ]] || fail "video= without refresh"
[[ "$(randr_with 'video=1280x720@50 video=HDMI-A-2:1024x768@60e' mode)" == "--output HDMI-A-2 --mode 1024x768@60Hz" ]] || fail "last video= must win, flags ignored"
[[ "$(randr_with 'video=1280x720-32@50' mode)" == "--output HDMI-A-2 --mode 1280x720@50Hz" ]] || fail "video= without connector"
[[ "$(randr_with 'quiet video=HDMI-A-2:1280x720@60' toggle)" == "--output HDMI-A-2 --on --mode 1280x720@60Hz --pos 0,0" ]] || fail "toggle ignores video="
[[ "$(randr_with 'quiet' toggle)" == "--output HDMI-A-2 --on --preferred --pos 0,0" ]] || fail "no video=: preferred mode expected"
grep -q 'retrobox-switch-display mode' "${HOME}/.config/retrobox-session-labwc/autostart" || fail "autostart does not apply the mode first"
pass "the resolution follows video= on the kernel command line, and only that"

# --- 11. mouse-hide / mouse-show ----------------------------------------------------------
WLRCTL_LOG="${WORK}/wlrctl.log"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "${WLRCTL_LOG}" >"${STUBS}/wlrctl"
chmod +x "${STUBS}/wlrctl"
fake_randr() { # fake_randr MODE POSITION SCALE TRANSFORM: one enabled output, one disabled
  cat >"${STUBS}/wlr-randr" <<SH
#!/bin/sh
cat <<'OUT'
DP-1 "off"
  Enabled: no
  Modes:
    3840x2160 px, 60.000000 Hz (preferred, current)
  Position: 0,0
  Scale: 1.000000
  Transform: normal
HDMI-A-2 "LG"
  Enabled: yes
  Modes:
    1920x1080 px, 60.000000 Hz (preferred)
    $1 px, 60.000000 Hz (current)
  Position: $2
  Transform: $4
  Scale: $3
OUT
SH
  chmod +x "${STUBS}/wlr-randr"
}
: >"${WLRCTL_LOG}"
"${ROOT}/libexec/mouse-hide" || fail "mouse-hide failed"
[[ "$(cat "${WLRCTL_LOG}")" == "pointer move 32767 32767" ]] || fail "mouse-hide wrong: $(cat "${WLRCTL_LOG}")"
centre_of() { : >"${WLRCTL_LOG}"; fake_randr "$@"; "${ROOT}/libexec/mouse-show" || fail "mouse-show failed"; tail -n1 "${WLRCTL_LOG}"; }
[[ "$(centre_of 1280x720 0,0 1.000000 normal)" == "pointer move 640 360" ]] || fail "centre of 1280x720"
[[ "$(head -n1 "${WLRCTL_LOG}")" == "pointer move -32767 -32767" ]] || fail "mouse-show must start from the corner"
[[ "$(centre_of 1920x1080 0,0 2.000000 normal)" == "pointer move 480 270" ]] || fail "scale ignored"
[[ "$(centre_of 1920x1080 0,0 1.000000 90)" == "pointer move 540 960" ]] || fail "rotation ignored"
[[ "$(centre_of 1280x720 1920,0 1.000000 normal)" == "pointer move 2560 360" ]] || fail "position ignored"
PATH="${WORK}/bare" expect_fail "$(command -v bash)" "${ROOT}/libexec/mouse-hide"
grep -q 'wlrctl is not installed' "${WORK}/out" || fail "missing wlrctl not reported"
grep -q 'libexec/mouse-hide' "${HOME}/.config/retrobox-session-labwc/autostart" || fail "autostart does not run mouse-hide"
pass "mouse-hide parks the pointer in the corner, mouse-show centres it"

# --- 12. retrobox-system-settings: the system's time zone and keyboard ----------------------
SETTINGS="${ROOT}/bin/retrobox-system-settings"
SYS="${WORK}/system-settings"
mkdir -p "${SYS}/bin" "${SYS}/zoneinfo/Europe"
: >"${SYS}/zoneinfo/Europe/Madrid"
cat >"${SYS}/evdev.lst" <<'LST'
! model
  pc105           Generic 105-key PC
! layout
  us              English (US)
  es              Spanish
! variant
  dvorak          us: English (Dvorak)
  winkeys         es: Spanish (Windows)
! option
  grp             Switching to another layout
LST
printf 'XKBMODEL="pc105"\nXKBLAYOUT="es"\nXKBVARIANT=""\nXKBOPTIONS="grp:alt_shift_toggle"\n' >"${SYS}/keyboard"
printf 'LANG="es_ES.UTF-8"\n' >"${SYS}/locale"
# timedatectl and localectl log their arguments; $DENY makes them refuse like polkit
for tool in timedatectl localectl; do
  cat >"${SYS}/bin/${tool}" <<'SH'
#!/bin/sh
echo "${0##*/} $*" >>"${SYS_LOG}"
case "$*" in
  show*) echo "Europe/Madrid"; exit 0 ;;
  status) exit 0 ;;
  list-locales) printf 'C.UTF-8\nen_US.UTF-8\nes_ES.utf8\nde_DE\nca_ES.UTF-8@valencia\n'; exit 0 ;;
esac
[ -z "${DENY:-}" ] || { echo "Access denied: Interactive authentication required." >&2; exit 1; }
SH
  chmod +x "${SYS}/bin/${tool}"
done
# pkexec runs the helper as it is (the test's user); $DENY makes it refuse like polkit
cat >"${SYS}/bin/pkexec" <<'SH'
#!/bin/sh
echo "pkexec $*" >>"${SYS_LOG}"
[ -z "${DENY:-}" ] || { echo "Error executing command as another user: Not authorized" >&2; exit 127; }
shift
exec "$@"
SH
chmod +x "${SYS}/bin/pkexec"
settings() {
  SYS_LOG="${SYS}/log" PATH="${SYS}/bin:${PATH}" RETROBOX_ZONEINFO="${SYS}/zoneinfo" \
    RETROBOX_XKB_RULES="${SYS}/evdev.lst" RETROBOX_KEYBOARD_FILE="${KBFILE:-${SYS}/keyboard}" \
    RETROBOX_SETTINGS_HELPERS="${HELPERS:-${ROOT}/libexec/retrobox-settings-helper}" \
    RETROBOX_LOCALE_DEFAULT="${LOCALE_DEFAULT:-${SYS}/none}" RETROBOX_LOCALE_FILE="${SYS}/default-locale" \
    RETROBOX_LOCALE_FILES="${LOCALES:-${SYS}/locale}" "${SETTINGS}" "$@"
}
export SYS_LOG="${SYS}/log"
[[ "$(settings timezone get)" == "Europe/Madrid" ]] || fail "timezone get"
settings timezone set Europe/Madrid || fail "timezone set"
grep -qx 'timedatectl --no-ask-password set-timezone Europe/Madrid' "${SYS}/log" || fail "timedatectl not called: $(cat "${SYS}/log")"
[[ "$(settings timezone set Europe/Nowhere)" == "Error: unknown time zone 'Europe/Nowhere'" ]] || fail "unknown zone accepted"
[[ "$(settings keyboard list-layouts)" == $'us English (US)\nes Spanish' ]] || fail "layouts: $(settings keyboard list-layouts)"
[[ "$(settings keyboard list-variants es)" == "winkeys Spanish (Windows)" ]] || fail "variants of es"
[[ "$(settings keyboard get)" == "es none" ]] || fail "keyboard get: $(settings keyboard get)"
# Debian (there is a /etc/default/keyboard): retrobox-settings-helper through pkexec
settings keyboard set es winkeys || fail "keyboard set"
grep -qx "pkexec --disable-internal-agent ${ROOT}/libexec/retrobox-settings-helper keyboard es winkeys" "${SYS}/log" || fail "pkexec wrong: $(cat "${SYS}/log")"
[[ "$(cat "${SYS}/keyboard")" == $'XKBMODEL="pc105"\nXKBLAYOUT="es"\nXKBVARIANT="winkeys"\nXKBOPTIONS="grp:alt_shift_toggle"' ]] || fail "keyboard file: $(cat "${SYS}/keyboard")"
[[ "$(settings keyboard get)" == "es winkeys" ]] || fail "keyboard get after set"
settings keyboard set us none || fail "keyboard set without variant"
grep -qx 'XKBVARIANT=""' "${SYS}/keyboard" && grep -qx 'XKBLAYOUT="us"' "${SYS}/keyboard" || fail "no variant: $(cat "${SYS}/keyboard")"
[[ "$(settings keyboard set es dvorak)" == "Error: the keyboard layout 'es' has no variant 'dvorak'" ]] || fail "wrong variant accepted"
[[ "$(RETROBOX_KEYBOARD_FILE="${SYS}/keyboard" RETROBOX_XKB_RULES="${SYS}/evdev.lst" "${ROOT}/libexec/retrobox-settings-helper" keyboard 'es"; rm -rf /')" == "Error: unknown keyboard layout 'es\"; rm -rf /'" ]] || fail "the helper takes a bad layout"
out="$(DENY=1 settings keyboard set us)" && fail "a refusal must fail"
[[ "${out}" == "Error: cannot change the keyboard layout: Error executing command as another user: Not authorized (is the polkit rule of install.sh in place?)" ]] || fail "refusal not explained: ${out}"
out="$(HELPERS="${SYS}/none" settings keyboard set us)" && fail "no helper must fail"
[[ "${out}" == "Error: cannot change the keyboard layout: retrobox-settings-helper is not installed"* ]] || fail "missing helper not explained: ${out}"
# elsewhere (no /etc/default/keyboard): localed
KBFILE="${SYS}/none" settings keyboard set es winkeys || fail "keyboard set through localed"
grep -q '^localectl --no-ask-password set-x11-keymap es .*winkeys' "${SYS}/log" || fail "localectl wrong: $(cat "${SYS}/log")"
out="$(DENY=1 KBFILE="${SYS}/none" settings keyboard set us)" && fail "a refusal must fail"
[[ "${out}" == "Error: cannot change the keyboard layout: Access denied: Interactive authentication required. (is the polkit rule of install.sh in place?)" ]] || fail "refusal not explained: ${out}"
[[ "$(settings locale list)" == $'en_US en_US.UTF-8\nes_ES es_ES.utf8' ]] || fail "locales: $(settings locale list)"
[[ "$(settings locale get)" == "es_ES" ]] || fail "locale get: $(settings locale get)"
[[ "$(LOCALES="${SYS}/none" settings locale get)" == "en_US" ]] || fail "locale get without a locale"
settings locale set es_ES || fail "locale set"
grep -qx 'localectl --no-ask-password set-locale LANG=es_ES.utf8' "${SYS}/log" || fail "set-locale wrong: $(cat "${SYS}/log")"
[[ "$(settings locale set de_DE)" == "Error: the system has no locale for 'de_DE'"* ]] || fail "missing locale accepted"
[[ "$(settings locale set ../x)" == "Error: unknown language '../x'" ]] || fail "bad language accepted"
# Debian (there is a /etc/default/locale, here a link): the helper, through pkexec
printf '#!/bin/sh\nprintf "C.utf8\\nen_US.utf8\\nes_ES.utf8\\n"\n' >"${SYS}/bin/locale"
chmod +x "${SYS}/bin/locale"
printf '#  File generated by update-locale\n' >"${SYS}/locale.conf"
ln -s locale.conf "${SYS}/default-locale"
LOCALE_DEFAULT="${SYS}/default-locale" settings locale set es_ES || fail "locale set through the helper"
grep -qx "pkexec --disable-internal-agent ${ROOT}/libexec/retrobox-settings-helper locale es_ES" "${SYS}/log" || fail "pkexec wrong: $(cat "${SYS}/log")"
[[ -L "${SYS}/default-locale" ]] && grep -qx 'LANG="es_ES.UTF-8"' "${SYS}/locale.conf" || fail "locale file: $(cat "${SYS}/locale.conf")"
out="$(PATH="${SYS}/bin:${PATH}" RETROBOX_LOCALE_FILE="${SYS}/default-locale" "${ROOT}/libexec/retrobox-settings-helper" locale de_DE)" && fail "the helper takes a missing locale"
[[ "${out}" == "Error: the system has no locale for 'de_DE'"* ]] || fail "missing locale not explained: ${out}"
pass "retrobox-system-settings reads and sets the system's time zone, keyboard (Debian's file or localed) and language, and says why it can't"

# --- 13. the Openbox session: session.d hooks, the rc.xml, picom and Retrobox -----------------
OB="${WORK}/openbox"
mkdir -p "${OB}/bin" "${OB}/etc/session.d" "${OB}/etc/openbox" "${OB}/run"
cat >"${OB}/bin/openbox" <<'SH'
#!/bin/sh
echo "openbox $*" >>"${OB_LOG}"
# Openbox runs its --startup command
while [ $# -gt 0 ]; do [ "$1" = --startup ] && exec "$2"; shift; done
SH
printf '#!/bin/sh\necho "picom $*" >>"${OB_LOG}"\n' >"${OB}/bin/picom"
printf '#!/bin/sh\necho "retrobox $*" >>"${OB_LOG}"\n' >"${OB}/bin/retrobox"
printf '#!/bin/sh\necho "unclutter-xfixes $*" >>"${OB_LOG}"\n' >"${OB}/bin/unclutter-xfixes"
printf '#!/bin/sh\necho "pkill $*" >>"${OB_LOG}"\n' >"${OB}/bin/pkill"
printf '#!/bin/sh\necho "hook 10" >>"${OB_LOG}"\n' >"${OB}/etc/session.d/10-first"
printf '#!/bin/sh\necho "hook 20" >>"${OB_LOG}"; exit 3\n' >"${OB}/etc/session.d/20-fails"
printf 'not run: not executable\n' >"${OB}/etc/session.d/30-text"
chmod +x "${OB}/bin/"* "${OB}/etc/session.d/10-first" "${OB}/etc/session.d/20-fails"
export OB_LOG="${OB}/log"
openbox_session() {
  : >"${OB_LOG}"
  PATH="${OB}/bin:${PATH}" RETROBOX_SYSCONFDIR="${OB}/etc" XDG_RUNTIME_DIR="${OB}/run" \
    "${ROOT}/bin/retrobox-openbox-session"
  wait 2>/dev/null || true
  sleep 0.2 # Retrobox runs in the background
}
openbox_session || fail "the Openbox session failed: $(cat "${HOME}/.local/state/retrobox/logs/openbox-session.log")"
[[ "$(head -n 2 "${OB_LOG}")" == $'hook 10\nhook 20' ]] || fail "session.d hooks: $(cat "${OB_LOG}")"
grep -q "^openbox --config-file ${OB}/run/retrobox-openbox-rc.xml --startup ${ROOT}/libexec/retrobox-openbox-autostart\$" "${OB_LOG}" || fail "openbox not started right: $(cat "${OB_LOG}")"
grep -q "${ROOT}/libexec/retrobox-volume up" "${OB}/run/retrobox-openbox-rc.xml" || fail "@LIBEXEC@ not filled in"
grep -qx 'picom -b --config /dev/null --backend glx --vsync' "${OB_LOG}" && grep -qx 'retrobox ' "${OB_LOG}" || fail "autostart: $(cat "${OB_LOG}")"
grep -qx 'unclutter-xfixes --start-hidden --fork' "${OB_LOG}" || fail "the mouse cursor is not hidden at session start: $(cat "${OB_LOG}")"
: >"${OB_LOG}"
PATH="${OB}/bin:${PATH}" "${ROOT}/libexec/mouse-hide-x11" || fail "mouse-hide-x11 failed"
grep -qx 'unclutter-xfixes --start-hidden --fork' "${OB_LOG}" || fail "mouse-hide-x11 restarts unclutter hidden: $(cat "${OB_LOG}")"
: >"${OB_LOG}"
PATH="${OB}/bin:${PATH}" "${ROOT}/libexec/mouse-show-x11" || fail "mouse-show-x11 failed"
grep -qx 'pkill -x unclutter-xfixes' "${OB_LOG}" || fail "mouse-show-x11 kills unclutter: $(cat "${OB_LOG}")"
grep -q '20-fails failed (status 3), going on' "${HOME}/.local/state/retrobox/logs/openbox-session.log" || fail "a failing hook is not reported"
printf '<openbox_config/>\n' >"${OB}/etc/openbox/rc.xml"
printf '[openbox]\ncompositor = none\n' >"${OB}/etc/retrobox.ini"
openbox_session || fail "the Openbox session failed with the machine's rc.xml"
grep -q "^openbox --config-file ${OB}/etc/openbox/rc.xml " "${OB_LOG}" || fail "the machine's rc.xml not used"
! grep -q '^picom' "${OB_LOG}" || fail "[openbox] compositor = none still runs picom"
rm -f "${OB}/etc/retrobox.ini"
rm -f "${OB}/bin/unclutter-xfixes"
openbox_session || fail "the Openbox session failed without unclutter"
grep -q 'mouse cursor: hide failed' "${HOME}/.local/state/retrobox/logs/openbox-session.log" \
  || fail "missing unclutter is not reported: $(cat "${HOME}/.local/state/retrobox/logs/openbox-session.log")"
grep -qx 'retrobox ' "${OB_LOG}" || fail "Retrobox did not run without unclutter"
mkdir -p "${WORK}/bare-x11"
for need in env bash; do
  ln -sf "$(PATH="${BASE_PATH}" command -v "${need}")" "${WORK}/bare-x11/${need}"
done
expect_fail env PATH="${WORK}/bare-x11" "${ROOT}/libexec/mouse-hide-x11"
pass "the Openbox session runs session.d, picks its rc.xml, then picom and Retrobox; the mouse is hidden at start"

# --- 14. retrobox-polkit-rule: the same rule for any session ---------------------------------------
"${ROOT}/libexec/retrobox-polkit-rule" retrobox >"${WORK}/rule" || fail "retrobox-polkit-rule failed"
grep -q 'subject.user != "retrobox"' "${WORK}/rule" && grep -q 'timedate1.set-timezone' "${WORK}/rule" && grep -q 'login1.power-off' "${WORK}/rule" || fail "rule wrong: $(cat "${WORK}/rule")"
! grep -q 'manage-units' "${WORK}/rule" || fail "a unit in a rule without --unit"
expect_fail "${ROOT}/libexec/retrobox-polkit-rule" 'bad"user'
pass "retrobox-polkit-rule prints the console's rule, with the unit only when given"

echo "All smoke tests passed."
