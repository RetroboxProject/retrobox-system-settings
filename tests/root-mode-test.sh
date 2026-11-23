#!/usr/bin/env bash
# Test of the package's setup: retrobox-session-apply, install.sh --user and
# the postinst/prerm of the retrobox-session-labwc package. It runs as root
# (it re-runs itself with sudo) and makes a throwaway user; stand-in commands
# and a fake systemd directory, so nothing outside throwaway paths changes.
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

# --- stand-in commands and a fake systemd -------------------------------------------
STUBS="${WORK}/stubs"
mkdir -p "${WORK}/etc-retrobox" "${STUBS}" "${WORK}/core/bin" "${WORK}/units" "${WORK}/state" "${WORK}/systemd"
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

APPLY="${REPO}/libexec/retrobox-session-apply"
UNIT="${RETROBOX_SYSTEMD_DIR}/retrobox-session-labwc.service"
RULE="${RETROBOX_POLKIT_DIR}/50-retrobox-console.rules"
ENABLED="${STUB_STATE}/enabled-retrobox-session-labwc.service"
DATA="${HOME_DIR}/.local/share/retrobox-session-labwc"
CONFIG="${HOME_DIR}/.config/retrobox-session-labwc"
CONF="${RETROBOX_SYSCONFDIR}/session-labwc.conf"

system_is_empty() { [[ -z "$(find "${RETROBOX_SYSTEMD_DIR}" "${STUB_STATE}" -mindepth 1 -print)" && ! -e "${RULE}" ]]; }
write_conf() { printf '%s\n' "$@" >"${CONF}"; }

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

# --- 1. no declaration, no session ---------------------------------------------------------
rm -f "${CONF}"
"${APPLY}" >"${WORK}/out" 2>&1 || fail "apply without a file failed: $(cat "${WORK}/out")"
grep -q 'the labwc session is not set up' "${WORK}/out" || fail "no hint without a file"
system_is_empty || fail "apply without a file wrote to the system"
[[ ! -e "${DATA}" ]] || fail "apply without a file wrote to the home"
"${APPLY}" remove >"${WORK}/out" 2>&1 || fail "remove with nothing installed failed"
pass "without /etc/.../session-labwc.conf the package changes nothing"

# --- 2. a declaration that is wrong fails and changes nothing -----------------------------
bad_conf() {
  local why="$1" pattern="$2"
  shift 2
  write_conf "$@"
  expect_fail "${APPLY}"
  grep -q "${pattern}" "${WORK}/out" || fail "${why}: wrong message: $(cat "${WORK}/out")"
  system_is_empty || fail "${why}: wrote to the system"
  [[ ! -e "${DATA}" ]] || fail "${why}: wrote to the home"
}
bad_conf "unknown key" "not a RETROBOX_USER" "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=8" "RETROBOX_SUDO=1"
bad_conf "no user" "RETROBOX_USER is missing" "RETROBOX_TTY=8"
bad_conf "no tty" "RETROBOX_TTY is missing" "RETROBOX_USER=${TEST_USER}"
bad_conf "tty out of range" "between 1 and 12" "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=13"
bad_conf "bad on-quit" "poweroff or shell" "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=8" "RETROBOX_ON_QUIT=reboot"
bad_conf "command in a value" "not a RETROBOX_USER" "RETROBOX_USER=\$(touch ${WORK}/pwned)" "RETROBOX_TTY=8"
[[ ! -e "${WORK}/pwned" ]] || fail "the file was executed"
bad_conf "no such user" "no such user" "RETROBOX_USER=nobody-here-$$" "RETROBOX_TTY=8"
bad_conf "root" "not root" "RETROBOX_USER=root" "RETROBOX_TTY=8"
pass "a wrong declaration fails loudly, before anything is written, and is never executed"

# --- 3. the declaration brings the machine to its state ----------------------------------
write_conf "# the machine" "RETROBOX_USER=${TEST_USER}   # who plays" "RETROBOX_TTY=8"
XDG_DATA_HOME=/nonexistent-data XDG_CONFIG_HOME=/nonexistent-config "${APPLY}" >"${WORK}/out" 2>&1 ||
  fail "apply failed: $(cat "${WORK}/out")"
[[ ! -e /nonexistent-data && ! -e /nonexistent-config ]] || fail "the XDG variables of root were used"
grep -q "^User=${TEST_USER}\$" "${UNIT}" && grep -q '^TTYPath=/dev/tty8$' "${UNIT}" && grep -q '^Conflicts=getty@tty8.service$' "${UNIT}" ||
  fail "unit wrong: $(cat "${UNIT}")"
grep -q "^ExecStart=/bin/bash -lc 'exec ${DATA}/bin/retrobox-session-labwc'\$" "${UNIT}" || fail "the unit does not run the user's copy"
[[ -e "${ENABLED}" ]] || fail "the service is not enabled at boot"
grep -q "${TEST_USER}" "${RULE}" || fail "polkit rule does not name the user"
[[ -x "${RETROBOX_SETTINGS_HELPER}" ]] || fail "settings helper not installed"
[[ -x "${DATA}/install.sh" && -f "${CONFIG}/rc.xml" && -f "${CONFIG}/autostart" ]] || fail "the user's files are missing"
grep -q 'labwc_tty = 8' "${HOME_DIR}/.config/retrobox/retrobox.ini.d/50-labwc.ini" || fail "tty not written"
grep -q "^tty=8\$" "${DATA}/.install-manifest" && grep -q "^user=${TEST_USER}\$" "${DATA}/.install-manifest" || fail "manifest wrong"
[[ "$(cat "${CONFIG}/on_quit")" == "poweroff" ]] || fail "first install does not power off on quit"
stray="$(find "${HOME_DIR}" ! -user "${TEST_USER}" -print)"
[[ -z "${stray}" ]] || fail "root left files in the home of the user: ${stray}"
pass "the declaration sets up the service, the rule and the files of the user (owned by the user)"

# --- 4. idempotent: the same input gives the same machine, and nothing is rewritten ------
snapshot >"${WORK}/before"
sleep 1.1
"${APPLY}" >"${WORK}/out" 2>&1 || fail "second apply failed: $(cat "${WORK}/out")"
grep -q 'Already installed on tty8: updating' "${WORK}/out" || fail "second run does not know the install: $(cat "${WORK}/out")"
grep -q 'polkit rule already in place' "${WORK}/out" || fail "polkit rule rewritten"
snapshot >"${WORK}/after"
diff -u "${WORK}/before" "${WORK}/after" >&2 || fail "a second apply changed the machine"
[[ -z "$(find "${HOME_DIR}" ! -user "${TEST_USER}" -print)" ]] || fail "second run left root's files"
pass "applying again changes nothing (the system files are not even rewritten)"

# --- 5. drift is repaired ------------------------------------------------------------------
want="$(sha256sum <"${UNIT}")"
printf '# somebody edited this\n' >>"${UNIT}"
rm -f "${CONFIG}/rc.xml" "${DATA}/bin/retrobox-session-labwc"
"${APPLY}" >"${WORK}/out" 2>&1 || fail "apply after drift failed: $(cat "${WORK}/out")"
[[ "$(sha256sum <"${UNIT}")" == "${want}" ]] || fail "the unit was not restored"
[[ -f "${CONFIG}/rc.xml" && -x "${DATA}/bin/retrobox-session-labwc" ]] || fail "the user's files were not restored"
pass "an edited unit and a damaged copy are put back"

# --- 6. the TTY cannot change behind the user's back: refused before /etc is touched -----
snapshot >"${WORK}/before"
write_conf "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=5"
expect_fail "${APPLY}"
grep -q 'already installed on tty8' "${WORK}/out" || fail "tty change not refused: $(cat "${WORK}/out")"
[[ "$(ls "${RETROBOX_SYSTEMD_DIR}")" == "retrobox-session-labwc.service" ]] && grep -q '^TTYPath=/dev/tty8$' "${UNIT}" || fail "the refused change touched /etc"
snapshot >"${WORK}/after"
diff -u "${WORK}/before" "${WORK}/after" >&2 || fail "the refused change touched the machine"
pass "a different TTY is refused before anything changes"

# --- 7. on-quit: given, then kept -----------------------------------------------------------
write_conf "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=8" "RETROBOX_ON_QUIT=shell"
"${APPLY}" >/dev/null 2>&1 || fail "apply with on-quit failed"
[[ "$(cat "${CONFIG}/on_quit")" == "shell" ]] || fail "on-quit not applied"
write_conf "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=8"
"${APPLY}" >/dev/null 2>&1 || fail "apply without on-quit failed"
[[ "$(cat "${CONFIG}/on_quit")" == "shell" ]] || fail "a re-run did not keep the on-quit choice"
pass "RETROBOX_ON_QUIT is applied and a re-run keeps it"

# --- 8. remove takes the system part away and leaves the home -------------------------------
write_conf "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=8"
"${APPLY}" >/dev/null 2>&1
want_unit="$(sha256sum <"${UNIT}")"
(cd "${HOME_DIR}" && find . -type f ! -name .install-manifest -print0 | sort -z | xargs -0 sha256sum) >"${WORK}/home-before"
"${APPLY}" remove >"${WORK}/out" 2>&1 || fail "remove failed: $(cat "${WORK}/out")"
[[ ! -e "${UNIT}" && ! -e "${RULE}" && ! -e "${ENABLED}" ]] || fail "remove left the service or the rule"
(cd "${HOME_DIR}" && find . -type f ! -name .install-manifest -print0 | sort -z | xargs -0 sha256sum) >"${WORK}/home-after"
diff -u "${WORK}/home-before" "${WORK}/home-after" >&2 || fail "remove touched the home of the user"
printf '[Service]\nExecStart=/bin/true\n' >"${UNIT}"
"${APPLY}" remove >/dev/null 2>&1
[[ -f "${UNIT}" ]] || fail "remove deleted a unit it did not write"
rm -f "${UNIT}"
"${APPLY}" >/dev/null 2>&1 || fail "apply after remove failed"
[[ "$(sha256sum <"${UNIT}")" == "${want_unit}" && -e "${ENABLED}" && -f "${RULE}" ]] || fail "apply after remove did not rebuild the same system part"
pass "remove takes away the service and the rule only (never a unit that is not ours, never the home); apply rebuilds them"

# --- 9. who may run what ----------------------------------------------------------------------
expect_fail "${REPO}/install.sh" --tty 8
grep -q 'run it as the user who plays, not as root' "${WORK}/out" || fail "root without --user not refused"
expect_fail "${REPO}/install.sh" --user "${TEST_USER}" --tty 8 --no-system
grep -q 'no sense as root' "${WORK}/out" || fail "--no-system as root not refused"
expect_fail runuser -u "${TEST_USER}" -- "${REPO}/install.sh" --user "${TEST_USER}" --tty 8
grep -q -- '--user is for root' "${WORK}/out" || fail "--user as a user not refused: $(cat "${WORK}/out")"
expect_fail runuser -u "${TEST_USER}" -- "${APPLY}"
grep -q 'run it as root' "${WORK}/out" || fail "apply as a user not refused"
pass "--user is root's, and root does not install without it"

# --- 9b. a machine that has the old install (retrobox-labwc): one service at the end, never two ----
"${APPLY}" remove >/dev/null 2>&1
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
write_conf "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=8"
expect_fail "${APPLY}"
grep -q 'already installed on tty3' "${WORK}/out" || fail "the old install's TTY was not honoured: $(cat "${WORK}/out")"
[[ -f "${OLD_UNIT}" && -f "${OLD_RULE}" && -e "${OLD_ENABLED}" && ! -e "${UNIT}" && ! -e "${ENABLED}" ]] || fail "a refused change touched the old install"
printf 'tty=8\nuser=%s\nsystem_unit=%s\npolkit_rule=%s\n' "${TEST_USER}" "${OLD_UNIT}" "${OLD_RULE}" >"${OLD_DATA}/.install-manifest"
chown "${TEST_USER}:" "${OLD_DATA}/.install-manifest"
"${APPLY}" >"${WORK}/out" 2>&1 || fail "apply over the old install failed: $(cat "${WORK}/out")"
[[ ! -e "${OLD_UNIT}" && ! -e "${OLD_RULE}" && ! -e "${OLD_ENABLED}" ]] || fail "the old service or rule is still there"
[[ -f "${UNIT}" && -e "${ENABLED}" && -f "${RULE}" ]] || fail "the new service was not set up"
[[ ! -e "${OLD_DATA}" && -f "${DATA}/.install-manifest" ]] || fail "the user's files were not moved to the new names"
grep -q '^tty=8$' "${DATA}/.install-manifest" || fail "manifest lost the tty"
grep -q 'Left in the system' "${WORK}/out" && fail "the user's part says it left what root took away"
[[ "$(find "${RETROBOX_SYSTEMD_DIR}" -name '*.service' | wc -l)" == 1 ]] || fail "more than one service"
pass "an install under the old names ends with one service, the new one (and its TTY is honoured first)"

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
[[ "$(readlink "${WORK}/pkg/usr/bin/retrobox-session-apply")" == /opt/retrobox/libexec/retrobox-session-apply && -x "${WORK}/pkg/opt/retrobox/libexec/retrobox-session-apply" && -f "${WORK}/pkg/usr/share/doc/retrobox-session-labwc/examples/session-labwc.conf" ]] || fail "the .deb lacks the command or the example"
grep -q 'util-linux' "${WORK}/ctl/control" || fail "the .deb does not depend on util-linux (runuser)"
"${APPLY}" remove >/dev/null 2>&1
sh "${WORK}/postinst" abort-upgrade
system_is_empty || fail "postinst did something on abort-upgrade"
sh "${WORK}/postinst" configure >"${WORK}/out" 2>&1 || fail "postinst configure failed: $(cat "${WORK}/out")"
[[ -f "${UNIT}" && -e "${ENABLED}" ]] || fail "postinst configure did not set the session up"
sh "${WORK}/prerm" upgrade
[[ -f "${UNIT}" ]] || fail "prerm removed the service on an upgrade"
sh "${WORK}/prerm" remove >/dev/null 2>&1
[[ ! -e "${UNIT}" && ! -e "${RULE}" ]] || fail "prerm remove left the service or the rule"
write_conf "RETROBOX_USER=${TEST_USER}" "RETROBOX_TTY=99"
if sh "${WORK}/postinst" configure >/dev/null 2>&1; then fail "postinst accepted a wrong declaration"; fi
pass "the .deb's postinst applies the declaration on configure, prerm takes the system part away on remove, and a wrong file fails the configure"

echo "All root-mode tests passed."
