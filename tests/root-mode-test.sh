#!/usr/bin/env bash
# Test of the package's setup: install.sh --machine / --user as root, and the
# postinst/prerm of the retrobox-session-labwc package. It runs as root (it
# re-runs itself with sudo) and makes a throwaway user; stand-in commands and a
# fake systemd directory, so nothing outside throwaway paths changes.
#
#   sudo tests/root-mode-test.sh
# shellcheck disable=SC2015,SC2016  # "A && B || fail" is how the checks read
set -euo pipefail

[[ ${EUID} -eq 0 ]] || exec sudo -E "$0" "$@"

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
chmod 0755 "${WORK}"
TEST_USER="rbtest$$"
cleanup() {
  userdel -r "${TEST_USER}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

fail() { echo "ROOT-MODE TEST FAILED: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
expect_fail() { if "$@" >"${WORK}/out" 2>&1; then fail "should have failed: $*"; fi; }

# a world-readable copy of the tree: the user part runs as another user
REPO="${WORK}/repo"
mkdir -p "${REPO}"
cp -a "${SRC}/." "${REPO}/"
rm -rf "${REPO}/.git" "${REPO}/dist"
chmod -R a+rX "${REPO}"

useradd -m -s /bin/bash "${TEST_USER}"
HOME_DIR="$(getent passwd "${TEST_USER}" | cut -d: -f6)"
TEST_UID="$(id -u "${TEST_USER}")"

# --- stand-in commands and a fake systemd -------------------------------------------
STUBS="${WORK}/stubs"
mkdir -p "${WORK}/etc-retrobox/retrobox.ini.d" "${STUBS}" "${WORK}/core/bin" "${WORK}/units" "${WORK}/state" "${WORK}/systemd"
for cmd in labwc pipewire-pulse foot dbus-run-session wlr-randr wpctl Xwayland chvt pkcheck; do
  printf '#!/bin/sh\nexit 0\n' >"${STUBS}/${cmd}"
done
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/core/bin/retrobox-screenshot"
cat >"${STUBS}/systemctl" <<'SH'
#!/bin/sh
case "$1" in
  is-enabled) [ -e "${STUB_STATE}/enabled-$3" ] ;;
  enable) touch "${STUB_STATE}/enabled-$2" ;;
  disable) rm -f "${STUB_STATE}/enabled-$2" ;;
  daemon-reload) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod -R a+rx "${STUBS}" "${WORK}/core"
touch "${WORK}/units/pipewire-pulse.service"
printf 'XKBMODEL="pc105"\nXKBLAYOUT="es"\nXKBVARIANT=""\nXKBOPTIONS=""\n' >"${WORK}/keyboard"
printf 'ID=debian\n' >"${WORK}/os-release"
chmod a+r "${WORK}/keyboard" "${WORK}/os-release"

export PATH="${STUBS}:${PATH}"
export STUB_STATE="${WORK}/state"
export RETROBOX_SYSTEMD_DIR="${WORK}/systemd"
export RETROBOX_POLKIT_DIR="${WORK}/polkit"
export RETROBOX_POLKIT_ACTIONS_DIR="${WORK}/polkit-actions"
export RETROBOX_SETTINGS_HELPER="${WORK}/usr-local/libexec/retrobox-settings-helper"
export RETROBOX_USER_UNIT_DIRS="${WORK}/units"
export RETROBOX_KEYBOARD_FILE="${WORK}/keyboard"
export RETROBOX_OS_RELEASE="${WORK}/os-release"
export RETROBOX_ROOT="${WORK}/core"
export RETROBOX_SYSCONFDIR="${WORK}/etc-retrobox"
export RETROBOX_DEFAULT_UID=59999 # nobody is the user with uid 1000 here
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME RETROBOX_CONFIGDIR

# what the user's login shell sees (the service runs a login shell as well)
cat >"${HOME_DIR}/.profile" <<PROFILE
export PATH="${STUBS}:\${PATH}"
export STUB_STATE="${STUB_STATE}"
export RETROBOX_SYSTEMD_DIR="${RETROBOX_SYSTEMD_DIR}"
export RETROBOX_USER_UNIT_DIRS="${RETROBOX_USER_UNIT_DIRS}"
export RETROBOX_KEYBOARD_FILE="${RETROBOX_KEYBOARD_FILE}"
export RETROBOX_OS_RELEASE="${RETROBOX_OS_RELEASE}"
export RETROBOX_ROOT="${RETROBOX_ROOT}"
PROFILE
chown "${TEST_USER}:" "${HOME_DIR}/.profile"

INSTALL="${REPO}/install.sh"
UNIT="${RETROBOX_SYSTEMD_DIR}/retrobox-session-labwc.service"
RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-console.rules"
ENABLED="${STUB_STATE}/enabled-retrobox-session-labwc.service"
DATA="${HOME_DIR}/.local/share/retrobox-session-labwc"
CONFIG="${HOME_DIR}/.config/retrobox-session-labwc"
TTY_INI="${HOME_DIR}/.config/retrobox/retrobox.ini.d/50-labwc.ini"
MACHINE_INI="${RETROBOX_SYSCONFDIR}/retrobox.ini.d/60-session.ini"

machine() { "${INSTALL}" --machine "$@"; }
system_is_empty() { [[ -z "$(find "${RETROBOX_SYSTEMD_DIR}" "${STUB_STATE}" -mindepth 1 -print)" && ! -e "${RULE}" ]]; }
# the machine's own word: [advanced] with the lines given
write_ini() { { echo "[advanced]"; printf '%s\n' "$@"; } >"${MACHINE_INI}"; }
unit_tty() { sed -n 's/^TTYPath=\/dev\/tty//p' "${UNIT}"; }

# the state of the machine: the system part by content and age, the home by content
snapshot() {
  {
    sha256sum "${UNIT}" "${RULE}" "${RETROBOX_SETTINGS_HELPER}"
    stat -c '%Y %n' "${UNIT}" "${RULE}" "${RETROBOX_SETTINGS_HELPER}"
    ls "${ENABLED}"
    (cd "${HOME_DIR}" && find . -type f ! -name .install-manifest -print0 | sort -z | xargs -0 sha256sum)
    (cd "${HOME_DIR}" && find . -type l -printf '%p -> %l\n' | sort)
  }
}

# --- 1. nobody to set up for: it says so and does nothing -------------------------------
rm -f "${MACHINE_INI}"
machine >"${WORK}/out" 2>&1 || fail "--machine with nobody to set up for failed: $(cat "${WORK}/out")"
grep -q 'no user to set the labwc session up for' "${WORK}/out" || fail "no hint: $(cat "${WORK}/out")"
system_is_empty && [[ ! -e "${DATA}" ]] || fail "it wrote something with nobody to set up for"
"${INSTALL}" --uninstall >"${WORK}/out" 2>&1 || fail "uninstall with nothing installed failed"
pass "with nobody to set up for the package changes nothing (and says so)"

# --- 2. a user or a TTY that is wrong fails and changes nothing --------------------------
bad_ini() {
  local why="$1" pattern="$2"
  shift 2
  write_ini "$@"
  expect_fail machine
  grep -q "${pattern}" "${WORK}/out" || fail "${why}: wrong message: $(cat "${WORK}/out")"
  system_is_empty || fail "${why}: wrote to the system"
  [[ ! -e "${DATA}" ]] || fail "${why}: wrote to the home"
}
bad_ini "tty out of range" "between 1 and 12" "labwc_user = ${TEST_USER}" "labwc_tty = 13"
bad_ini "tty not a number" "between 1 and 12" "labwc_user = ${TEST_USER}" "labwc_tty = abc"
bad_ini "no such user" "no such user" "labwc_user = nobody-here-$$"
bad_ini "root" "not root" "labwc_user = root"
bad_ini "command in a value" "must be a user name" "labwc_user = \$(touch ${WORK}/pwned)"
[[ ! -e "${WORK}/pwned" ]] || fail "the ini was executed"
pass "a wrong user or TTY fails loudly, before anything is written, and is never executed"

# --- 3. defaults: the user with uid 1000, on tty8 ---------------------------------------
rm -f "${MACHINE_INI}"
RETROBOX_DEFAULT_UID="${TEST_UID}" XDG_DATA_HOME=/nonexistent-data XDG_CONFIG_HOME=/nonexistent-config \
  machine >"${WORK}/out" 2>&1 || fail "--machine with the defaults failed: $(cat "${WORK}/out")"
[[ ! -e /nonexistent-data && ! -e /nonexistent-config ]] || fail "the XDG variables of root were used"
grep -q "^User=${TEST_USER}\$" "${UNIT}" || fail "default user not used: $(cat "${UNIT}")"
[[ "$(unit_tty)" == 8 ]] && grep -q '^Conflicts=getty@tty8.service$' "${UNIT}" || fail "default TTY is not 8: $(cat "${UNIT}")"
grep -q "^ExecStart=/bin/bash -lc 'exec ${DATA}/bin/retrobox-session-labwc'\$" "${UNIT}" || fail "the unit does not run the user's copy"
[[ -e "${ENABLED}" ]] || fail "the service is not enabled at boot"
grep -q "${TEST_USER}" "${RULE}" || fail "polkit rule does not name the user"
[[ -x "${RETROBOX_SETTINGS_HELPER}" ]] || fail "settings helper not installed"
[[ -x "${DATA}/install.sh" && -f "${CONFIG}/rc.xml" && -f "${CONFIG}/autostart" ]] || fail "the user's files are missing"
grep -q 'labwc_tty = 8' "${TTY_INI}" || fail "tty not written for the user"
grep -q "^tty=8\$" "${DATA}/.install-manifest" && grep -q "^user=${TEST_USER}\$" "${DATA}/.install-manifest" || fail "manifest wrong"
[[ "$(cat "${CONFIG}/on_quit")" == "poweroff" ]] || fail "first install does not power off on quit"
stray="$(find "${HOME_DIR}" ! -user "${TEST_USER}" -print)"
[[ -z "${stray}" ]] || fail "root left files in the home of the user: ${stray}"
pass "no configuration: the user with uid 1000, tty8; service, rule and the user's files (owned by the user)"

# the machine names the user now: from here on it is not the uid that picks him
write_ini "labwc_user = ${TEST_USER}"

# --- 4. idempotent: the same input gives the same machine, and nothing is rewritten ------
snapshot >"${WORK}/before"
sleep 1.1
machine >"${WORK}/out" 2>&1 || fail "second run failed: $(cat "${WORK}/out")"
grep -q 'Already installed on tty8: updating' "${WORK}/out" || fail "second run does not know the install: $(cat "${WORK}/out")"
grep -q 'polkit rule already in place' "${WORK}/out" || fail "polkit rule rewritten"
snapshot >"${WORK}/after"
diff -u "${WORK}/before" "${WORK}/after" >&2 || fail "a second run changed the machine"
[[ -z "$(find "${HOME_DIR}" ! -user "${TEST_USER}" -print)" ]] || fail "second run left root's files"
pass "running again changes nothing (the system files are not even rewritten)"

# --- 5. drift is repaired ------------------------------------------------------------------
want="$(sha256sum <"${UNIT}")"
printf '# somebody edited this\n' >>"${UNIT}"
rm -f "${CONFIG}/rc.xml" "${DATA}/bin/retrobox-session-labwc"
machine >"${WORK}/out" 2>&1 || fail "run after drift failed: $(cat "${WORK}/out")"
[[ "$(sha256sum <"${UNIT}")" == "${want}" ]] || fail "the unit was not restored"
[[ -f "${CONFIG}/rc.xml" && -x "${DATA}/bin/retrobox-session-labwc" ]] || fail "the user's files were not restored"
pass "an edited unit and a damaged copy are put back"

# --- 6. the TTY follows the machine's ini --------------------------------------------------
# the user's own retrobox.ini says 2: only /etc/retrobox counts, and the 50-labwc.ini
# the installer wrote for the user (tty8) must not pin the machine either
mkdir -p "${HOME_DIR}/.config/retrobox"
printf '[advanced]\nlabwc_tty = 2\n' >"${HOME_DIR}/.config/retrobox/retrobox.ini"
chown -R "${TEST_USER}:" "${HOME_DIR}/.config/retrobox"
write_ini "labwc_user = ${TEST_USER}" "labwc_tty = 5"
machine >"${WORK}/out" 2>&1 || fail "moving to tty5 failed: $(cat "${WORK}/out")"
grep -q 'moving the session to tty5' "${WORK}/out" || fail "no word about the move: $(cat "${WORK}/out")"
[[ "$(unit_tty)" == 5 ]] && grep -q '^Conflicts=getty@tty5.service$' "${UNIT}" && grep -q '^Environment=RETROBOX_LABWC_TTY=5$' "${UNIT}" ||
  fail "the service did not move to tty5: $(cat "${UNIT}")"
! grep -q 'tty8' "${UNIT}" || fail "the unit still names tty8"
grep -q 'labwc_tty = 5' "${TTY_INI}" && grep -q '^tty=5$' "${DATA}/.install-manifest" || fail "the user's ini and the manifest did not follow"
[[ "$(find "${RETROBOX_SYSTEMD_DIR}" -name '*.service' | wc -l)" == 1 ]] || fail "more than one service after the move"
[[ -z "$(find "${HOME_DIR}" ! -user "${TEST_USER}" -print)" ]] || fail "the move left root's files"
machine --tty 3 >/dev/null 2>&1 || fail "--tty 3 failed"
[[ "$(unit_tty)" == 3 ]] || fail "--tty does not beat the ini"
rm -f "${HOME_DIR}/.config/retrobox/retrobox.ini"
write_ini "labwc_user = ${TEST_USER}" "labwc_tty = 8"
machine >/dev/null 2>&1 || fail "back to tty8 failed"
[[ "$(unit_tty)" == 8 ]] && grep -q 'labwc_tty = 8' "${TTY_INI}" || fail "back to tty8 did not stick"
pass "labwc_tty in /etc/retrobox moves the session (the user's own ini and the installer's 50-labwc.ini do not pin it; --tty beats it)"

# --- 7. on-quit: given, then kept -----------------------------------------------------------
machine --on-quit shell >/dev/null 2>&1 || fail "run with --on-quit failed"
[[ "$(cat "${CONFIG}/on_quit")" == "shell" ]] || fail "on-quit not applied"
machine >/dev/null 2>&1 || fail "run without --on-quit failed"
[[ "$(cat "${CONFIG}/on_quit")" == "shell" ]] || fail "a re-run did not keep the on-quit choice"
pass "--on-quit is applied and a re-run keeps it"

# --- 8. uninstall as root takes the system part away and leaves the home ---------------------
want_unit="$(sha256sum <"${UNIT}")"
(cd "${HOME_DIR}" && find . -type f ! -name .install-manifest -print0 | sort -z | xargs -0 sha256sum) >"${WORK}/home-before"
"${INSTALL}" --uninstall >"${WORK}/out" 2>&1 || fail "uninstall failed: $(cat "${WORK}/out")"
[[ ! -e "${UNIT}" && ! -e "${RULE}" && ! -e "${ENABLED}" ]] || fail "uninstall left the service or the rule"
(cd "${HOME_DIR}" && find . -type f ! -name .install-manifest -print0 | sort -z | xargs -0 sha256sum) >"${WORK}/home-after"
diff -u "${WORK}/home-before" "${WORK}/home-after" >&2 || fail "uninstall touched the home of the user"
printf '[Service]\nExecStart=/bin/true\n' >"${UNIT}"
"${INSTALL}" --uninstall >/dev/null 2>&1
[[ -f "${UNIT}" ]] || fail "uninstall deleted a unit it did not write"
rm -f "${UNIT}"
machine >/dev/null 2>&1 || fail "run after uninstall failed"
[[ "$(sha256sum <"${UNIT}")" == "${want_unit}" && -e "${ENABLED}" && -f "${RULE}" ]] || fail "run after uninstall did not rebuild the same system part"
pass "uninstall as root takes away the service and the rule only (never a unit that is not ours, never the home); --machine rebuilds them"

# --- 9. who may run what ----------------------------------------------------------------------
expect_fail "${INSTALL}" --tty 8
grep -q 'run it as the user who plays, not as root' "${WORK}/out" || fail "root without --machine or --user not refused"
expect_fail "${INSTALL}" --user "${TEST_USER}" --tty 8 --no-system
grep -q 'no sense as root' "${WORK}/out" || fail "--no-system as root not refused"
expect_fail "${INSTALL}" --machine --user "${TEST_USER}"
grep -q 'do not give --user' "${WORK}/out" || fail "--machine with --user not refused"
expect_fail runuser -u "${TEST_USER}" -- "${INSTALL}" --machine
grep -q -- '--machine is for root' "${WORK}/out" || fail "--machine as a user not refused: $(cat "${WORK}/out")"
expect_fail runuser -u "${TEST_USER}" -- "${INSTALL}" --user "${TEST_USER}" --tty 8
grep -q -- '--user is for root' "${WORK}/out" || fail "--user as a user not refused: $(cat "${WORK}/out")"
pass "--machine and --user are root's, and root does not install without one of them"

# --- 9b. a machine that has the old install (retrobox-labwc): one service at the end, never two ----
"${INSTALL}" --uninstall >/dev/null 2>&1
rm -rf "${DATA}" "${CONFIG}" "${HOME_DIR}/.config/retrobox"
OLD_DATA="${HOME_DIR}/.local/share/retrobox-labwc"
OLD_UNIT="${RETROBOX_SYSTEMD_DIR}/retrobox-labwc.service"
OLD_RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-labwc.rules"
OLD_ENABLED="${STUB_STATE}/enabled-retrobox-labwc.service"
mkdir -p "${OLD_DATA}" "${RETROBOX_POLKIT_DIR}"
printf 'tty=3\nuser=%s\nsystem_unit=%s\npolkit_rule=%s\n' "${TEST_USER}" "${OLD_UNIT}" "${OLD_RULE}" >"${OLD_DATA}/.install-manifest"
chown -R "${TEST_USER}:" "${HOME_DIR}/.local"
printf '# Written by retrobox-labwc: the labwc gaming session of %s on tty3.\n[Unit]\n' "${TEST_USER}" >"${OLD_UNIT}"
printf '// Written by retrobox-labwc\n' >"${OLD_RULE}"
touch "${OLD_ENABLED}"
machine >"${WORK}/out" 2>&1 || fail "run over the old install failed: $(cat "${WORK}/out")"
[[ ! -e "${OLD_UNIT}" && ! -e "${OLD_RULE}" && ! -e "${OLD_ENABLED}" ]] || fail "the old service or rule is still there"
[[ -f "${UNIT}" && -e "${ENABLED}" && -f "${RULE}" && "$(unit_tty)" == 8 ]] || fail "the new service was not set up on tty8"
[[ ! -e "${OLD_DATA}" && -f "${DATA}/.install-manifest" ]] || fail "the user's files were not moved to the new names"
grep -q '^tty=8$' "${DATA}/.install-manifest" || fail "manifest lost the tty"
grep -q 'Left in the system' "${WORK}/out" && fail "the user's part says it left what root took away"
[[ "$(find "${RETROBOX_SYSTEMD_DIR}" -name '*.service' | wc -l)" == 1 ]] || fail "more than one service"
pass "an install under the old names ends with one service, the new one (on the machine's TTY, even if the old one was another)"

# --- 10. the maintainer scripts of the .deb run the same thing ------------------------------
"${REPO}/packaging/build-deb.sh" 0.0.0-test "${WORK}/dist" >/dev/null
deb="${WORK}/dist/retrobox-session-labwc_0.0.0-test_all.deb"
dpkg-deb -e "${deb}" "${WORK}/ctl"
for script in postinst prerm; do
  [[ -x "${WORK}/ctl/${script}" ]] && sh -n "${WORK}/ctl/${script}" || fail "${script} missing or not valid sh"
  # the packages put the tree in /opt/retrobox: point it at the copy
  sed "s|/opt/retrobox|${REPO}|g" "${WORK}/ctl/${script}" >"${WORK}/${script}"
done
dpkg-deb -x "${deb}" "${WORK}/pkg"
[[ -x "${WORK}/pkg/opt/retrobox/install.sh" && ! -e "${WORK}/pkg/opt/retrobox/libexec/retrobox-session-apply" ]] || fail "the .deb lacks install.sh (or still ships the apply script)"
[[ -f "${WORK}/pkg/usr/share/doc/retrobox-session-labwc/examples/session-labwc.ini" ]] || fail "the .deb lacks the example ini"
grep '^Depends:' "${WORK}/ctl/control" | grep -q 'util-linux' || fail "the .deb does not depend on util-linux (runuser)"
grep '^Depends:' "${WORK}/ctl/control" | grep -q 'kbd' || fail "the .deb does not depend on kbd (chvt, for the default tty8)"
"${INSTALL}" --uninstall >/dev/null 2>&1
sh "${WORK}/postinst" abort-upgrade
system_is_empty || fail "postinst did something on abort-upgrade"
sh "${WORK}/postinst" configure >"${WORK}/out" 2>&1 || fail "postinst configure failed: $(cat "${WORK}/out")"
[[ -f "${UNIT}" && -e "${ENABLED}" ]] || fail "postinst configure did not set the session up"
sh "${WORK}/prerm" upgrade
[[ -f "${UNIT}" ]] || fail "prerm removed the service on an upgrade"
sh "${WORK}/prerm" remove >/dev/null 2>&1
[[ ! -e "${UNIT}" && ! -e "${RULE}" ]] || fail "prerm remove left the service or the rule"
write_ini "labwc_user = ${TEST_USER}" "labwc_tty = 99"
if sh "${WORK}/postinst" configure >/dev/null 2>&1; then fail "postinst accepted a wrong TTY"; fi
pass "the .deb's postinst sets the session up on configure, prerm takes the system part away on remove, and a wrong ini fails the configure"

echo "All root-mode tests passed."
