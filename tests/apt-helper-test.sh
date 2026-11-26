#!/usr/bin/env bash
# retrobox-apt only lets the commands of the installers through, and the
# sudoers rule is valid. Needs no root: it only simulates (apt-get -s).
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APT="${HERE}/libexec/retrobox-apt"
failed=0
ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; failed=1; }

for argument in "install -s -y ./x.deb" "install -s -y foo/bar" "install -s -y -oDebug::x=1" \
    "install -s --allow-unauthenticated bash" "install -s -y" "remove bash" "update -o x=y" "" \
    "install -s -y ;id" "install -s -y a&b"; do
    # shellcheck disable=SC2086  # the words are the case
    if "${APT}" ${argument} >/dev/null 2>&1; then
        bad "refused: ${argument:-(nothing)}"
    else
        ok "refused: ${argument:-(nothing)}"
    fi
done
if command -v apt-get >/dev/null 2>&1; then
    if "${APT}" install -s -y bash >/dev/null 2>&1; then
        ok "a simulated install of a plain name goes through"
    else
        bad "a simulated install of a plain name goes through"
    fi
fi
if ! command -v visudo >/dev/null 2>&1; then
    printf 'skip - visudo is not installed\n'
elif visudo -cf "${HERE}/share/sudoers.d/retrobox-nopasswd" >/dev/null 2>&1 &&
    visudo -cf "${HERE}/share/sudoers.d/retrobox-pwfeedback" >/dev/null 2>&1; then
    ok "the sudoers files are valid"
else
    bad "the sudoers files are valid"
fi
if grep -q 'GITHUB_TOKEN' "${HERE}/bin/retrobox-update"; then
    bad "retrobox-update asks for no token"
else
    ok "retrobox-update asks for no token"
fi
exit "${failed}"
