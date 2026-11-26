#!/usr/bin/env bash
# Test of retrobox-update against a fake GitHub API served over http on
# localhost (which packages it takes, the lists of /etc/retrobox/releases.d,
# checksums), and retrobox-system-settings update with a stand-in pkexec.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UPDATE="${ROOT}/bin/retrobox-update"
SETTINGS="${ROOT}/bin/retrobox-system-settings"

for tool in curl jq dpkg-deb python3 apt-get; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "skipped: no ${tool}"; exit 0; }
done

# retrobox-update runs itself through sudo when it is not root, and sudo drops
# the environment that points it at the fake GitHub API: it would update the
# real system. So the whole test runs as root, with the caller's PATH and no
# trace of the sudo it came through.
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # (retrobox-update refuses --download-only from a sudo it can tell by SUDO_USER)
    exec sudo -n env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND \
      "PATH=${PATH}" "${BASH_SOURCE[0]}" "$@"
  fi
  echo "skipped: needs root, or sudo without a password"
  exit 0
fi

fail() {
  echo "UPDATE TEST FAILED: $*" >&2
  exit 1
}
pass() { echo "ok - $*"; }

WORK="$(mktemp -d)"
server=""
cleanup() {
  [[ -z "${server}" ]] || kill "${server}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

SITE="${WORK}/site"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
BASE="http://127.0.0.1:${PORT}"

# mkdeb NAME VERSION FILE: a one-file package
mkdeb() {
  local dir
  dir="$(mktemp -d "${WORK}/deb.XXXXXX")"
  mkdir -p "${dir}/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@invalid>\nDescription: t\n' \
    "$1" "$2" >"${dir}/DEBIAN/control"
  dpkg-deb --build "${dir}" "$3" >/dev/null
}

# release REPO TAG ASSET...: REPO's only release (its packages and SHA256SUMS)
release() {
  local repo="$1" tag="$2" asset assets="[]"
  shift 2
  mkdir -p "${SITE}/dl/${repo}" "${SITE}/repos/${repo}"
  for asset in "$@"; do
    local name="${asset%%_*}" version="${asset#*_}"
    mkdeb "${name}" "${version%_*}" "${SITE}/dl/${repo}/${asset}"
  done
  (cd "${SITE}/dl/${repo}" && sha256sum -- *.deb >SHA256SUMS)
  for asset in "$@" SHA256SUMS; do
    assets="$(jq -c --arg n "${asset}" --arg u "${BASE}/dl/${repo}/${asset}" \
      '. + [{name: $n, browser_download_url: $u, updated_at: "2026-11-25T00:00:00Z"}]' <<<"${assets}")"
  done
  jq -n --arg tag "${tag}" --argjson assets "${assets}" \
    '[{tag_name: $tag, prerelease: false, draft: false, assets: $assets}]' >"${SITE}/repos/${repo}/releases"
}

release RetroboxProject/retrobox-core v2.0 retrobox-core_2.0_all.deb
release RetroboxProject/retrobox-overlay v1.5 retrobox-overlay_1.5_arm64.deb retrobox-overlay_1.5_amd64.deb
(cd "${SITE}" && exec python3 -m http.server "${PORT}" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
for _ in $(seq 1 50); do curl -fs "${BASE}/repos/RetroboxProject/retrobox-core/releases" >/dev/null && break; sleep 0.1; done

SYSCONF="${WORK}/etc-retrobox"
mkdir -p "${SYSCONF}"
printf 'retrobox-core 1.0\n' >"${WORK}/installed"
run_update() {
  RETROBOX_GITHUB_API="${BASE}" RETROBOX_SYSCONFDIR="${SYSCONF}" RETROBOX_UPDATE_ARCH=arm64 \
    RETROBOX_UPDATE_TAG_RE='debian13|trixie' RETROBOX_UPDATE_INSTALLED="${WORK}/installed" \
    RETROBOX_UPDATE_STATE_DIR="${WORK}/state" "${UPDATE}" "$@"
}

# --- 1. the shipped list: only what is installed, if newer -------------------------------
out="$(run_update --download-only "${WORK}/dl1" 2>"${WORK}/log1")" || fail "download: $(cat "${WORK}/log1")"
[[ "${out}" == "${WORK}/dl1/RetroboxProject_retrobox-core/retrobox-core_2.0_all.deb" ]] || fail "packages: ${out}"
grep -q 'retrobox-core 1.0 -> 2.0' "${WORK}/log1" || fail "no upgrade logged: $(cat "${WORK}/log1")"
grep -q 'retrobox-overlay.*none of its packages is installed' "${WORK}/log1" || fail "overlay not skipped: $(cat "${WORK}/log1")"
pass "retrobox-update takes the newer releases of the installed packages only"

# --- 2. a list of /etc/retrobox/releases.d replaces the shipped one ----------------------
mkdir -p "${SYSCONF}/releases.d"
printf 'RetroboxProject/retrobox-overlay retrobox-overlay\n' >"${SYSCONF}/releases.d/retrobox.list"
out="$(run_update --download-only "${WORK}/dl2" 2>"${WORK}/log2")" || fail "download: $(cat "${WORK}/log2")"
[[ "${out}" == "${WORK}/dl2/RetroboxProject_retrobox-overlay/retrobox-overlay_1.5_arm64.deb" ]] || fail "packages: ${out}"
! grep -q retrobox-core "${WORK}/log2" || fail "the shipped list was read too"
pass "a list of /etc/retrobox/releases.d replaces the shipped one, and its named packages come in"
rm -rf "${SYSCONF}/releases.d"

# --- 3. a broken checksum stops everything ------------------------------------------------
printf '%064d  retrobox-core_2.0_all.deb\n' 0 >"${SITE}/dl/RetroboxProject/retrobox-core/SHA256SUMS"
if run_update --download-only "${WORK}/dl3" >/dev/null 2>"${WORK}/log3"; then
  fail "a package that does not match its SHA256SUMS was taken"
fi
grep -q 'does not match the SHA256SUMS' "${WORK}/log3" || fail "mismatch not said: $(cat "${WORK}/log3")"
pass "a package that does not match its release's SHA256SUMS stops the update"

# --- 4. retrobox-system-settings update -------------------------------------------------------
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
cat >"${STUBS}/pkexec" <<SH
#!/bin/sh
echo "pkexec \$*" >>"${WORK}/pkexec.log"
[ -z "\${DENY:-}" ] || exit 127
shift
echo "updating..."
exec "\$@"
SH
cat >"${WORK}/fake-update" <<'SH'
#!/bin/sh
echo "fake update $*"
SH
chmod +x "${STUBS}/pkexec" "${WORK}/fake-update"
settings() { PATH="${STUBS}:${PATH}" RETROBOX_UPDATERS="${UPDATERS}" "${SETTINGS}" "$@"; }
UPDATERS="${WORK}/none ${WORK}/fake-update"
settings update available || fail "update not available"
out="$(settings update run --allow-prereleases)" || fail "update run: ${out}"
[[ "${out}" == $'updating...\nfake update --allow-prereleases' ]] || fail "output: ${out}"
grep -qx "pkexec --disable-internal-agent ${WORK}/fake-update --allow-prereleases" "${WORK}/pkexec.log" || fail "pkexec: $(cat "${WORK}/pkexec.log")"
out="$(DENY=1 settings update run)" && fail "a refusal must fail"
[[ "${out}" == "Error: cannot update: not authorized"* ]] || fail "refusal: ${out}"
UPDATERS="${WORK}/none"
settings update available && fail "available without retrobox-update"
out="$(settings update run)" && fail "no updater must fail"
[[ "${out}" == "Error: cannot update: retrobox-update is not installed"* ]] || fail "missing: ${out}"
pass "retrobox-system-settings update runs retrobox-update through pkexec, and says why it can't"

echo "All update tests passed."
