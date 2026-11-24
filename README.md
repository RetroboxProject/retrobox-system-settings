# retrobox-system-settings

What turns a machine into a [Retrobox](https://github.com/RetroboxProject/retrobox-core) console, with Retrobox as its only interface, in one of two sessions, plus [the machine's settings](#system-settings-console-mode) that EmulationStation changes in console mode:

- the **labwc** session (Wayland), for **minimal systems** (Debian netinstall, Arch, ...): the machine boots on a TTY, where a systemd service starts [labwc](https://labwc.github.io) and Retrobox runs inside it. No desktop, no display manager, no autologin. Most of this README is about it.
- the **Openbox** session (X11), for a **display manager** that logs the console's user into it, as nx-debian's image does with lightdm: see [Openbox session](#openbox-session). It used to be *retrobox-labwc*; running `install.sh` again moves an install of it to the new names (`retrobox-session-labwc.service`, `~/.local/share/retrobox-session-labwc`, `~/.config/retrobox-session-labwc`, the polkit rule `50-retrobox-console.rules`), keeping its TTY and on-quit choice; a session still running goes on until the next boot.

It is a single installer: it installs no packages, it checks what the system must already have and sets up the rest (your home, plus one service and one polkit rule through `sudo`).

The session is an ordinary service, so you can manage it from anywhere, ssh included:

```bash
systemctl stop retrobox-session-labwc      # bare system: the TTY gets its login prompt back
systemctl start retrobox-session-labwc     # the gaming session again
systemctl restart retrobox-session-labwc   # start over (e.g. after a keyboard change)
```

- **Win+P** switches the display output (internal panel ⇄ external screen).
- **Win+Shift+R** restarts the session (it re-reads the system keyboard), **Win+Shift+E** exits labwc and ends it.
- The mouse pointer is parked in the bottom-right corner when the session starts (see [Mouse pointer](#mouse-pointer)). The volume keys (5% a press, capped at 100%, no distorted boost; through `retrobox-overlay --volume` when the overlay is installed, which can show the volume, else `wpctl` or `pactl`), **Print** (Retrobox screenshot), **Alt+Tab**, **Alt+F4** and **Win+T** (terminal) work as usual.

Retrobox ending closes labwc; unless the machine is set to power off, the service ends and the TTY shows its login prompt.

## Requirements

Installed by you, with your package manager (`./install.sh --check --tty N` tells you which):

| | Debian | Arch |
|---|---|---|
| labwc | `labwc` | `labwc` |
| pipewire-pulse | `pipewire-pulse` | `pipewire-pulse` |
| a terminal | `foot` (or `alacritty`) | `foot` |
| dbus-run-session | `dbus-bin` | `dbus` |
| user bus (recommended) | `dbus-user-session` | `dbus` |
| recommended | `wlr-randr wireplumber xwayland wlrctl pulseaudio-utils` | `wlr-randr wireplumber xorg-xwayland wlrctl libpulse` |

plus `retrobox-core`, systemd and PAM (`libpam-systemd` on Debian). For any TTY but 1, `chvt` (package `kbd`) is needed too.

## Install

```bash
git clone https://github.com/RetroboxProject/retrobox-system-settings && cd retrobox-system-settings
./install.sh --tty 1        # --check --tty 1 only checks; --force installs even if a check fails
```

Or, on Debian, with the packages of a [release](../../releases) (or `packaging/build-deb.sh`), which pull what the session needs through apt and put this tree in `/opt/retrobox` (the retrobox layout). The labwc package sets the session up by itself, for the user with uid 1000 on tty8 unless the machine's `retrobox.ini` says otherwise ([below](#the-package-sets-the-session-up-by-itself)):

```bash
sudo apt install ./retrobox-system-settings_*_all.deb ./retrobox-session-labwc_*_all.deb
```

| Package | What it has |
|---|---|
| `retrobox-system-settings` | what every console needs: `retrobox-system-settings`, `retrobox-polkit-rule`, the volume keys' `retrobox-volume` |
| `retrobox-session-labwc` | the labwc session and its installer (`retrobox-session-install`); it sets itself up on install (below) |
| `retrobox-session-openbox` | the Openbox session and its `/usr/share/xsessions/retrobox-openbox.desktop` |

### The package sets the session up by itself

Installing `retrobox-session-labwc` is enough: its `postinst` runs `install.sh --machine` (as root, with no password to ask), on every install, upgrade and `dpkg-reconfigure`. With no configuration at all the session is for **the user with uid 1000, on tty8**. The machine's own word is its `retrobox.ini` (`/etc/retrobox/retrobox.ini` or a drop-in of `/etc/retrobox/retrobox.ini.d/`; an example is in `share/examples/session-labwc.ini` and, installed, in `/usr/share/doc/retrobox-session-labwc/examples/`):

```ini
[advanced]
labwc_user = neon   # the user who plays: must exist, with a home, and not be root (else the user with uid 1000)
labwc_tty = 8       # the gaming TTY, 1-12 (else 8)
```

To change the TTY, edit `labwc_tty` and run `sudo dpkg-reconfigure retrobox-session-labwc` (or `sudo retrobox-session-install --machine`): systemd needs the TTY in the service, so the ini is read when the package is configured, not at every boot. The service, `~/.config/retrobox/retrobox.ini.d/50-labwc.ini` and the manifest follow, and the machine starts on the new TTY at the next boot. Only `/etc/retrobox` counts for this: the installer writes `labwc_tty` in the user's own `retrobox.ini.d`, and that must not outrank the machine.

- **Idempotent.** The same machine gives the same result: a service or rule that is already right is not rewritten, an edited unit or a damaged copy in the home is put back, and an upgrade refreshes the user's copy of this tree.
- **Reproducible.** Paths are the ones of the user's passwd entry (`~/.local/share/retrobox-session-labwc`, ...): the environment of whoever runs it, `XDG_*` included, is ignored.
- **Nobody to set up for** (no `labwc_user` and no user with uid 1000 yet): it says so and does nothing; set `labwc_user` and reconfigure. A user or a TTY that is wrong (no such user, root, out of range) fails the `configure` before anything is written, so a machine never looks configured when it is not.
- **Root writes `/etc`; the user writes the home.** The service, the polkit rule and the settings helper are written by root; the files of the user (the copy of the tree, labwc's config, `50-labwc.ini`) by that user, in a login shell, never by root in a home it does not own. What happens when Retrobox quits (`poweroff` the first time) is the user's `~/.config/retrobox-session-labwc/on_quit`, which a re-run keeps (`--on-quit` changes it).
- **Safe in a chroot.** It starts nothing and asks systemd nothing when it is not running: the service starts at the next boot (`systemctl start retrobox-session-labwc` on a live machine).
- **A machine with the old install** (`retrobox-labwc`) ends with one service: its service and polkit rule are removed by their fixed names and mark, and the user's files move to the new names.
- **Removal.** `apt remove` (`prerm`) takes away the service and the polkit rule, only if this installer wrote them; the home of the user stays (`install.sh --uninstall`, as that user, removes it).

`sudo tests/root-mode-test.sh` checks all of it with a throwaway user.

### What the installer sets up

The installer needs root for two files only (it asks for your password through `sudo`; `--no-system` skips both): `/etc/systemd/system/retrobox-session-labwc.service`, enabled at boot, and the polkit rule below (`--no-polkit` skips just the rule). The service takes the gaming TTY over from its getty (`Conflicts=getty@ttyN`), logs your user in through PAM (a real logind session, which labwc needs), switches to that VT (`chvt N`) and runs the session from a login shell, so your `PATH` is the one of your profile. When it ends, however it ends, the getty comes back. `./install.sh --check` prints the unit it would write.

Everything lands in your home:

- `~/.local/share/retrobox-session-labwc`: a copy of this tree (the checkout can go) and `retrobox-session-labwc` linked in `~/.local/bin`
- `~/.config/retrobox-session-labwc`: labwc's config for the session (`labwc -C`); your `~/.config/labwc` is never touched
- `~/.config/retrobox/retrobox.ini.d/50-labwc.ini`: `[advanced] labwc_tty`, and `[core] system_settings` (see [System settings](#system-settings-console-mode)); Retrobox's console mode is enabled by the session scripts, which pass `--console` to retrobox — it is not a config key

**The TTY is fixed once installed.** To change it: `~/.local/share/retrobox-session-labwc/install.sh --uninstall`, then install again. Running the installer again with the same TTY just updates.

`--uninstall` removes all of the above and the system part (service and rule). A session that is still running keeps running until `systemctl stop retrobox-session-labwc` or a reboot. An install of the previous version (login hook plus autologin drop-in) is migrated by simply running the installer again.

## Keyboard

The session always uses the system's keyboard: `/etc/default/keyboard` (Debian's `keyboard-configuration`), else `localectl`'s X11 keymap, read every time the session starts. Nothing is copied into labwc's config. To change it on Debian:

```bash
sudo dpkg-reconfigure keyboard-configuration
```

then press **Win+Shift+R** (or `systemctl restart retrobox-session-labwc`).

## System settings (console mode)

In console mode (`--console`, which the session scripts always pass), EmulationStation is the machine's only screen — it cannot be quit, its *Quit* menu offers restart, suspend and shut down — so its *System settings* offer the machine's **time zone**, **keyboard layout and variant** and **language**, as batocera's do. Retrobox doesn't set those itself: it runs `bin/retrobox-system-settings`, which `install.sh` links in `~/.local/bin` and points `[core] system_settings` at (the package also puts it in `/usr/bin`, where Retrobox finds it too):

```
retrobox-system-settings timezone get | set ZONE
retrobox-system-settings keyboard get | list-layouts | list-variants LAYOUT | set LAYOUT [VARIANT]
retrobox-system-settings locale get | list | set LANGUAGE
```

They are the system's own settings, set with systemd's `timedatectl` and `localectl`, so they end up where the distribution keeps them (`/etc/localtime`; `/etc/default/keyboard` on Debian, which the session reads, and which also sets the text console; `/etc/default/locale` or `/etc/locale.conf`) and are read back from there. The layouts and variants are XKB's (`/usr/share/X11/xkb/rules/evdev.lst`); a new layout keeps the model and options the system had. Debian doesn't let `localed` set the keyboard nor the language (its D-Bus policy, `systemd-localed-read-only.conf`, rejects `SetX11Keyboard` and `SetLocale`), so where there is a `/etc/default/keyboard` or a `/etc/default/locale` the program runs `libexec/retrobox-settings-helper` as root with `pkexec` instead: it only changes `XKBLAYOUT` and `XKBVARIANT` there, to a layout and variant XKB lists, or `LANG`, to a UTF-8 locale the system has. It has its own polkit action, `org.retroboxproject.system-settings.set`, which names a root-owned copy of it: the package's, or the one `install.sh` puts in `/usr/local/libexec/retrobox-system-settings/` (with the action in `/usr/share/polkit-1/actions/`; `--uninstall` removes both). It needs `pkexec` (`apt install pkexec`). A language is a locale's language and territory (`es_ES`), set as `LANG`; only the system's UTF-8 locales are offered (`localectl list-locales`), so on Debian a language must be generated first (add `es_ES.UTF-8 UTF-8` to `/etc/locale.gen` and run `sudo locale-gen`, or `sudo dpkg-reconfigure locales`). EmulationStation offers the ones it has a translation for and follows the system's language. A new time zone applies at once; a new keyboard layout or language when the session starts again, which EmulationStation offers. No password is asked: the polkit rule below lets your user do these three things. When it can't (no systemd, no rule), EmulationStation shows why.

### XDP DNS (DNS over TLS)

The *Network settings* also offer **XDP DNS** as a toggle (retrobox-emulationstation's patch 0021), the frontend of `bin/retrobox-xdp-dns`, linked and packaged like the program above:

```
retrobox-xdp-dns on | off | status
```

`on` writes systemd-resolved's drop-in `/etc/systemd/resolved.conf.d/26-putotebas.conf` — XDP's servers `85.208.114.51` and `2a0e:97c0:c40::51` (`dns.xdp.es`), `DNSOverTLS=yes`, `DNSSEC=allow-downgrade` — and restarts `systemd-resolved`; `off` removes the file and restarts it; `status` prints `on` or `off` (the file is there or not), which is what EmulationStation shows (no `retrobox-xdp-dns` on the machine, no toggle). The root part goes through `pkexec` and `retrobox-settings-helper` (the same polkit action, so the console's user needs no password), and the file's content is fixed in the helper: nothing of the caller's gets into it. NetworkManager is left alone and the two coexist: it keeps managing the links and handing their DHCP DNS to resolved per link; the drop-in only adds the global servers, so `off` puts everything back exactly as it was. `status` warns when `systemd-resolved` isn't running or `/etc/resolv.conf` isn't its stub (`127.0.0.53`), where the drop-in would change nothing.

## Openbox session

For a machine whose display manager logs the console's user in (no TTY service, no `install.sh`): install `retrobox-session-openbox` and choose its session, `retrobox-openbox` (lightdm: `autologin-session=retrobox-openbox`). `retrobox-openbox-session` then:

1. runs the executables of `/etc/retrobox/session.d/`, then `~/.config/retrobox-openbox/session.d/`, in name order: what the machine's own packages want done at every start (nx-debian puts EmulationStation's defaults for the Switch there). A failing one is logged and skipped.
2. starts Openbox with the first of `~/.config/retrobox-openbox/rc.xml`, `/etc/retrobox/openbox/rc.xml` and this tree's `share/openbox/rc.xml`, which only takes the volume keys (`retrobox-volume`) and the power key (left to logind) so that EmulationStation never sees them.
3. once Openbox is up, hides the mouse cursor (batocera's unclutter: the scripts `mouse-hide-x11` and `mouse-show-x11` in `libexec/` show and hide it with Debian's `unclutter-xfixes`), then starts the picom compositor (vsync, the overlay's translucency; no config file, so no shadows nor fades) and Retrobox. picom's backend is `[openbox] compositor` in `retrobox.ini`: `glx` (the default), `xrender`, `egl`, or `none` for no compositor. If Retrobox ends, Openbox stays up. Missing `unclutter-xfixes` is reported and left alone: the console runs with the cursor visible.

Its log is `~/.local/state/retrobox/logs/openbox-session.log`. With no `install.sh`, nothing writes the polkit rule: the machine writes it, with `retrobox-polkit-rule USER > /etc/polkit-1/rules.d/50-retrobox-console.rules` (power off, reboot, time zone, keyboard, language and the settings helper for that user). Retrobox finds `retrobox-system-settings` in `/usr/bin`.

## Mouse pointer

Two small standalone scripts in `libexec/` (they need only `wlrctl`, and `wlr-randr` for the second), meant to be run by labwc's autostart and by hooks of Retrobox or anything else in the session; copy them wherever you need them:

- `mouse-hide`: parks the pointer in the bottom-right corner. labwc's autostart runs it when the session starts.
- `mouse-show`: puts the pointer in the centre of the screen.

`wlrctl` can only move the pointer relatively, so `mouse-hide` sends it far past the corner (the compositor stops it at the edge) and `mouse-show` goes to the top-left corner and then back half the size of the screen, which it reads from `wlr-randr`.

For the Openbox session (X11), the same roles go through batocera's unclutter (Debian's `unclutter-xfixes`, the XFixes-based rewrite: there is no `unclutter-remote`): `mouse-hide-x11` kills a running `unclutter-xfixes` and starts a fresh one hidden at once (`--start-hidden --fork`), `mouse-show-x11` kills it (the X server undoes the hide of the client that died, so the cursor comes back); the session runs the hide when it starts. Both need only `unclutter-xfixes`; `mouse-show-x11` also runs with it absent (the cursor is visible then anyway).

## Headphones

`libexec/retrobox-audio-jack` (started by the session) keeps the audio card on its **analog duplex** profile while headphones are plugged into the jack and on **HDMI** while they are not (analog if there is no HDMI profile available). PipeWire reports the jack but keeps the analog profile available without headphones, so it never leaves it by itself. It reacts to the card events of the audio server (`pactl subscribe`) and needs `pactl`. It only acts when what it wants changes (headphones plugged or unplugged, an HDMI profile becoming available, the session starting): a profile chosen by hand meanwhile, such as from the overlay's audio page or pavucontrol, is left alone until the next change. Other profile names (`pactl list cards` shows them) go in `~/.config/retrobox-session-labwc/environment`:

```
RETROBOX_AUDIO_HEADPHONES_PROFILE=output:analog-stereo+input:analog-stereo
RETROBOX_AUDIO_HDMI_PROFILE=output:hdmi-stereo
```

## Resolution

The session runs at whatever the kernel command line forces, and at nothing else's say. To limit it to 1280x720 at 60 Hz, add `video=CONNECTOR:1280x720@60` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` (`sudo update-grub`, reboot); connector names are in `/sys/class/drm/card*-*/status` (e.g. `HDMI-A-2`). labwc's autostart applies that mode before Retrobox starts, and Win+P keeps it. Without a `video=`, the screen's preferred mode is used.

## Configuration

In any `retrobox.ini` layer (`/etc/retrobox`, `~/.config/retrobox`, their `retrobox.ini.d/`), only when the guess is wrong (outputs from `wlr-randr`):

```ini
[labwc]
internal_output = eDP-1         ; default: the first eDP/LVDS/DSI output
external_output = HDMI-A-1      ; default: the first other output
```

When Retrobox quits normally (exit status 0) the machine powers off; a crash, Win+Shift+E or a restart never do. That is the default of `./install.sh`; `--on-quit shell` just ends the service instead, so the TTY shows its login prompt (the choice lives in `~/.config/retrobox-session-labwc/on_quit`, and a re-run keeps it unless you give the option again).

`systemctl poweroff` and `reboot` (also the ones EmulationStation sends) need polkit to allow them. The installer writes `/etc/polkit-1/rules.d/50-retrobox-console.rules`, which lets your user power off and reboot from any session, start, stop and restart `retrobox-session-labwc.service`, and set the system's time zone, keyboard layout and language (on Debian, through `retrobox-settings-helper`) ([System settings](#system-settings-console-mode)) without a password (`--no-polkit` skips it, and then those need `sudo`; `--uninstall` removes it; it needs `polkitd` installed). If a reboot is already in progress when Retrobox exits, the power off does not replace it.

**D-Bus.** The session uses your user bus (`$XDG_RUNTIME_DIR/bus`, run by systemd's user manager), so portals, pipewire and wireplumber are one set shared with everything else you run, and the compositor's environment (`WAYLAND_DISPLAY`, ...) is handed to that bus while the session lasts. Without a user bus (no `dbus-user-session` on Debian) it falls back to a private one with `dbus-run-session`; `RETROBOX_LABWC_PRIVATE_BUS=1` forces that fallback.

The session log is `~/.local/state/retrobox/logs/labwc-session.log`; the service's own messages are in `journalctl -u retrobox-session-labwc`.

## Layout

```
install.sh    the installer: --check, install, --uninstall
bin/          retrobox-session-labwc, retrobox-openbox-session, retrobox-system-settings, retrobox-xdp-dns
libexec/      display switcher, audio jack, mouse-hide, mouse-show, mouse-hide-x11, mouse-show-x11,
              retrobox-common.sh (settings, keyboard), retrobox-openbox-autostart,
              retrobox-polkit-rule, retrobox-settings-helper, retrobox-volume
share/        labwc config templates, Openbox's rc.xml, the xsession entry, the polkit action
tests/        smoke-test.sh (stand-in commands, throwaway HOME)
packaging/    build-deb.sh (the three packages; .github/workflows/build.yml publishes them)
```

The packages put the tree in `/opt/retrobox` (like retrobox-core). What must
stay in /usr stays there: the `/usr/bin/` symlinks to `/opt/retrobox`, the xsession
entry (`/usr/share/xsessions`), the polkit action
(`/usr/share/polkit-1/actions`) and the docs (`/usr/share/doc`). Machine configuration
(session.d hooks, the machine's rc.xml) lives in `/etc/retrobox` and is not
shipped: it belongs to the machine, not to the package.

## License

GPLv2, like retrobox-core. See [LICENSE](LICENSE).
