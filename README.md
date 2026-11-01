# OmaEcosystem

![OmaEcosystem docked on the right of an Omarchy desktop](preview.png)

Your Android phone as part of the Omarchy desktop. Click the phone icon in the
bar and a phone-shaped dock slides in on the right showing the phone's live
screen at a real 5-inch size. You can use it with the mouse and keyboard
directly. One-click tiles underneath do the rest.

## Features

- **Live, controllable screen** (scrcpy over wireless ADB), pinned on every workspace
- **To phone**: copy the laptop clipboard to the phone. Copied files and images are sent as files
- **From phone**: copy the phone's clipboard to the laptop
- **Send files**: pick files and they go to the phone's `Download` folder. Name clashes get ` (1)`. You can also drop files onto the screen
- **Screenshot**: grab the phone screen to the clipboard and `~/Pictures/Phone`
- **Open link**: open the URL in the laptop clipboard on the phone
- **Hotspot**: wake the phone's hotspot over Bluetooth and join it (uses `phone-hotspot`)
- **Header**: battery, a live light, pull down notifications, lock the phone, undock
- **Nav keys**: back, home, recents

## Tests

```sh
python3 -m unittest discover -s tests   # no phone or Hyprland needed
```

## Requirements

`scrcpy`, `android-tools` (adb), `wl-clipboard`, `zenity`, and the
[phone-mirror](../phone-mirror) setup: its config at
`~/.config/phone-mirror/config` (`PHONE_ADDR`, `PHONE_SERIAL`, `PHONE_AUDIO`,
`PHONE_SCRCPY_ARGS`) and `phone-adb-keeper` to keep wireless ADB connected.

## First-time setup

If no phone is set up yet, the dock shows these steps on the phone screen itself.

1. On the phone: **Settings › About phone › Software information**, tap **Build number** 7 times.
2. **Settings › Developer options**, turn on **USB debugging**.
3. Plug the phone into the laptop with a **USB cable** and tap **Allow** on the
   "Allow USB debugging?" prompt (tick *Always allow*). Then press **Try again**.

**USB is recommended.** It is the fastest link with the least lag, and the
dock always picks USB when the cable is in. Wireless works too: turn on
**Wireless debugging** and run `adb pair` once, or with the phone-mirror
tools plug in once and run `phone-open --usb`. When the cable is unplugged the
mirror pauses, and **Reconnect** picks up the wireless link.

## Install

```sh
omarchy plugin add https://github.com/arbabmujtaba/omaecosystem.git --enable
```

A phone icon appears on the right of the bar. Click it to dock the phone.

From a local checkout instead: `make enable`.

## Remove

```sh
omarchy plugin remove io.github.arbabmujtaba.omaecosystem
```

Nothing is left running: closing the dock stops scrcpy and removes its
Hyprland window rule. The phone keeps a small helper file at
`/data/local/tmp/omaecosystem-server.jar`; remove it with
`adb shell rm /data/local/tmp/omaecosystem-server.jar` if you like.

Toggle from a keybinding:

```sh
omarchy-shell shell toggle io.github.arbabmujtaba.omaecosystem '{}'
```

## Settings

```sh
omarchy bar set io.github.arbabmujtaba.omaecosystem screenInches 5 --json      # 3-9, shrinks to fit
omarchy bar set io.github.arbabmujtaba.omaecosystem reserveSpace true --json   # tile windows beside it
omarchy bar set io.github.arbabmujtaba.omaecosystem phoneScreenOff true --json # phone display dark while docked
```

## How it works

The dock is a layer-shell surface with a transparent, click-through hole where
the screen is. `bin/omaecosystem mirror` runs scrcpy borderless and, through a
Hyprland window rule and a watch loop, keeps its window floating, pinned and
exactly under the hole, including after resizes and rotations. Closing the
dock stops scrcpy and removes the rule.

Clipboard actions start a short control-only scrcpy-server session (no video),
so setting the phone clipboard never pastes anything. Logs are in
`$XDG_RUNTIME_DIR/phone-mirror/omaecosystem.log`.
