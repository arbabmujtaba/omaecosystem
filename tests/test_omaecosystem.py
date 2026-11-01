"""Compatibility tests for OmaEcosystem that need no phone and no Hyprland.

    python3 -m unittest discover -s tests

adb, hyprctl and friends are faked, so these check how the helper behaves on
other machines (USB vs wireless, unauthorized phones, missing tools, other
phone shapes, other configs) and that the dock fits common laptop screens.
"""

import importlib.machinery
import importlib.util
import json
import math
import os
import re
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
loader = importlib.machinery.SourceFileLoader("omaeco", os.path.join(ROOT, "bin", "omaecosystem"))
spec = importlib.util.spec_from_loader("omaeco", loader)
eco = importlib.util.module_from_spec(spec)
loader.exec_module(eco)


def done(stdout="", rc=0, stderr=""):
    return subprocess.CompletedProcess([], rc, stdout.encode(), stderr.encode())


class Devices(unittest.TestCase):
    def devices(self, listing, want=""):
        with mock.patch.object(eco, "out", return_value="List of devices attached\n" + listing):
            return eco.ready_serial(want)

    def test_usb_preferred_over_wireless(self):
        self.assertEqual(self.devices("10.0.0.5:5555\tdevice\nR5CW1234\tdevice\n"), "R5CW1234")

    def test_wireless_used_when_no_usb(self):
        self.assertEqual(self.devices("10.0.0.5:5555\tdevice\n"), "10.0.0.5:5555")
        self.assertEqual(self.devices("adb-XYZ._adb-tls-connect._tcp\tdevice\n"), "adb-XYZ._adb-tls-connect._tcp")

    def test_pinned_serial(self):
        self.assertEqual(self.devices("AAA\tdevice\nBBB\tdevice\n", want="BBB"), "BBB")

    def test_offline_ignored(self):
        self.assertEqual(self.devices("AAA\toffline\n"), "")

    def test_unauthorized_explains_prompt(self):
        with self.assertRaises(eco.DockError) as cm:
            self.devices("AAA\tunauthorized\n")
        self.assertEqual(cm.exception.code, "unauthorized")

    def test_no_adb_is_missing_tool(self):
        with mock.patch.object(eco.shutil, "which", return_value=None):
            with self.assertRaises(eco.DockError) as cm:
                eco.connect({"serial": "", "addr": ""})
        self.assertEqual(cm.exception.code, "missing-tool")

    def test_no_phone_is_no_device(self):
        with mock.patch.object(eco.shutil, "which", return_value="/usr/bin/adb"), \
             mock.patch.object(eco, "run", return_value=done()), \
             mock.patch.object(eco, "ready_serial", return_value=""), \
             mock.patch.object(eco, "candidates", return_value=[]), \
             mock.patch.object(eco.time, "sleep"):
            with self.assertRaises(eco.DockError) as cm:
                eco.connect({"serial": "", "addr": ""})
        self.assertEqual(cm.exception.code, "no-device")


class DeviceInfo(unittest.TestCase):
    def info(self, text):
        with mock.patch.object(eco, "adb", return_value=done(text)):
            return eco.device_info("SER")

    def test_override_size_wins_and_battery(self):
        d = self.info("Physical size: 1440x3088\nOverride size: 1080x2316\n@@\nMy Phone\n@@\nSM-S918B\n@@\n"
                      "  AC powered: false\n  USB powered: true\n  status: 2\n  level: 77\n")
        self.assertEqual((d["width"], d["height"], d["battery"], d["charging"]), (1080, 2316, 77, True))
        self.assertEqual(d["name"], "My Phone")
        self.assertEqual(d["link"], "usb")

    def test_name_falls_back_to_model(self):
        d = self.info("Physical size: 1080x2400\n@@\nnull\n@@\nPixel 8\n@@\n")
        self.assertEqual((d["name"], d["battery"]), ("Pixel 8", -1))

    def test_adb_failure(self):
        with mock.patch.object(eco, "adb", return_value=done(rc=1)):
            with self.assertRaises(eco.DockError):
                eco.device_info("SER")


class Config(unittest.TestCase):
    def test_reads_phone_mirror_config(self):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write('PHONE_ADDR=10.1.1.1:5555\nPHONE_AUDIO=1\nPHONE_SCRCPY_ARGS=(--max-fps=60 "--window-title=x y")\n')
        try:
            with mock.patch.object(eco, "CONFIG_PATH", f.name):
                cfg = eco.load_config()
        finally:
            os.unlink(f.name)
        self.assertEqual(cfg["addr"], "10.1.1.1:5555")
        self.assertTrue(cfg["audio"])
        self.assertEqual(cfg["scrcpy_args"], ["--max-fps=60", "--window-title=x y"])

    def test_missing_config_gives_defaults(self):
        with mock.patch.object(eco, "CONFIG_PATH", "/nonexistent/config"):
            cfg = eco.load_config()
        self.assertEqual(cfg, {"serial": "", "addr": "", "audio": False, "bt_mac": "", "wifi": "",
                               "hotspot_wait": 40, "scrcpy_args": []})


class Hyprland(unittest.TestCase):
    def test_find_layer_on_second_monitor(self):
        layers = {"eDP-1": {"levels": {"2": [{"namespace": "omarchy-bar", "x": 0, "y": 0}]}},
                  "HDMI-A-1": {"levels": {"2": [{"namespace": "omaecosystem", "x": 3000, "y": 40}]}}}
        with mock.patch.object(eco, "hyprctl_json", return_value=layers):
            self.assertEqual(eco.find_layer("omaecosystem"), (3000, 40, "HDMI-A-1"))

    def test_named_workspace(self):
        mons = [{"name": "eDP-1", "activeWorkspace": {"id": -98, "name": "chat"}}]
        with mock.patch.object(eco, "hyprctl_json", return_value=mons):
            self.assertEqual(eco.workspace_for("eDP-1"), "name:chat")

    def test_lua_falls_back_to_legacy_dispatch(self):
        calls = []

        def fake(cmd, timeout=10, **kw):
            calls.append(cmd)
            return done("error: unknown", rc=1) if len(calls) == 1 else done("ok")
        with mock.patch.object(eco, "run", side_effect=fake):
            eco.dispatch("hl.dsp.window.pin({})", "pin", "address:0x1")
        self.assertEqual(calls[1], ["hyprctl", "dispatch", "pin", "address:0x1"])

    def test_rule_is_valid_lua_shape(self):
        seen = []
        with mock.patch.object(eco, "run", side_effect=lambda cmd, **kw: seen.append(cmd) or done("ok")):
            eco.set_rule(100, 50, 273, 580, "3")
        lua = seen[0][2]
        self.assertIn("size = { 273, 580 }", lua)
        self.assertIn('workspace = "3 silent"', lua)
        self.assertEqual(lua.count("{"), lua.count("}"))


class Files(unittest.TestCase):
    def test_unique_names(self):
        taken = {"a.txt", "a (1).txt", ".bashrc"}
        self.assertEqual(eco.unique_name("a.txt", taken), "a (2).txt")
        self.assertEqual(eco.unique_name("b.txt", taken), "b.txt")
        self.assertEqual(eco.unique_name(".bashrc", taken), ".bashrc (1)")

    def test_push_uses_no_shell_for_names(self):
        calls = []

        def fake_run(cmd, timeout=10, **kw):
            calls.append(cmd)
            return done()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "it's $(rm -rf) 'x'.txt")
            open(path, "w").close()
            with mock.patch.object(eco, "run", side_effect=fake_run), \
                 mock.patch.object(eco, "adb", return_value=done("")) as adb, \
                 mock.patch.object(eco, "emit"):
                eco.push_files("SER", [path])
        push = [c for c in calls if "push" in c][0]
        self.assertEqual(push[-1], "/sdcard/Download/it's $(rm -rf) 'x'.txt")
        scan = adb.call_args_list[-1].args[-1]
        self.assertNotIn("$(", scan.split(" -d ", 1)[1].replace("'", ""))  # URL-encoded and quoted

    def test_link_validation(self):
        self.assertTrue(eco.URL_RE.match("https://example.com/a?b=c"))
        self.assertTrue(eco.URL_RE.match("www.example.com"))
        self.assertFalse(eco.URL_RE.match("hello world"))
        self.assertFalse(eco.URL_RE.match("javascript:alert(1)"))


def dock_fit(screen_w, screen_h, physical_mm_w, phone_ratio=2.144, inches=5.0, bar=32, space=1.0):
    """Mirror of Dock.qml's geometry, in logical pixels."""
    s = lambda v: round(v * space)
    ppmm = screen_w / physical_mm_w if physical_mm_w else 96 / 25.4
    if not 1.5 <= ppmm <= 40:
        ppmm = 96 / 25.4
    gap = 6
    pad, header, body_gap, bezel = s(14), s(30), s(10), s(8)
    nav, tile, toast, row_gap, tile_gap = s(32), s(58), s(16), s(8), s(7)
    chrome = pad + header + body_gap + 2 * bezel + s(2) + nav + row_gap + (2 * tile + tile_gap) + row_gap + toast + pad
    available = screen_h - bar - 2 * gap
    wanted = inches * 25.4 * phone_ratio / math.sqrt(1 + phone_ratio ** 2) * ppmm
    hole_h = math.floor(max(240, min(wanted, available - chrome)))
    hole_w = round(hole_h / phone_ratio)
    card_w = max(hole_w + 2 * bezel + 2 * pad, s(250))
    return hole_w, hole_h, card_w, chrome + hole_h, available


class Geometry(unittest.TestCase):
    LAPTOPS = {
        # name: logical width, logical height, panel width in mm
        "MacBook Pro 14 @2x": (1512, 982, 302),
        "ThinkPad 14 1080p": (1920, 1080, 309),
        "XPS 13 @1.5 (2560x1600)": (1707, 1067, 286),
        "Framework 13 @1.5": (1504, 1003, 285),
        "Budget 15.6 1366x768": (1366, 768, 344),
        "Old 11.6 1366x768": (1366, 768, 256),
        "Unknown panel size": (1920, 1080, 0),
    }

    def test_fits_every_laptop(self):
        for name, (w, h, mm) in self.LAPTOPS.items():
            for ratio in (2.0, 2.144, 2.222):  # 18:9, S23 Ultra, 20:9
                with self.subTest(laptop=name, ratio=ratio):
                    hole_w, hole_h, card_w, card_h, available = dock_fit(w, h, mm, ratio)
                    self.assertLessEqual(card_h, available, "dock taller than the screen")
                    self.assertLess(card_w, w * 0.4, "dock takes too much width")
                    self.assertGreaterEqual(hole_h, 240)

    def test_five_inches_is_real_size_when_it_fits(self):
        hole_w, hole_h, *_ = dock_fit(1512, 982, 302)
        diagonal_mm = math.hypot(hole_w, hole_h) / (1512 / 302)
        self.assertAlmostEqual(diagonal_mm / 25.4, 5.0, delta=0.05)


class FakeSystem:
    """Answers run()/out() by command prefix, records every call."""

    def __init__(self, answers):
        self.answers = answers  # list of (prefix tuple, CompletedProcess or callable)
        self.calls = []

    def run(self, cmd, timeout=10, check=False, **kw):
        self.calls.append(list(cmd))
        for prefix, answer in self.answers:
            if tuple(cmd[:len(prefix)]) == tuple(prefix):
                return answer(cmd) if callable(answer) else answer
        return done(rc=1)

    def out(self, cmd, timeout=10):
        return self.run(cmd, timeout).stdout.decode()

    def ran(self, *prefix):
        return [c for c in self.calls if tuple(c[:len(prefix)]) == prefix]

    def patch(self):
        return mock.patch.multiple(eco, run=self.run, out=self.out)


NM_PROFILES = [
    (("nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"),
     done("Home:802-11-wireless\nWired connection 1:802-3-ethernet\nCafe\\: 5G:802-11-wireless\n"
          "Pixel hotspot:802-11-wireless\n")),
    (("nmcli", "-g", "802-11-wireless.ssid", "connection", "show", "Home"), done("HomeNet\n")),
    (("nmcli", "-g", "802-11-wireless.ssid", "connection", "show", "Cafe: 5G"), done("Cafe\\:5G\n")),
    (("nmcli", "-g", "802-11-wireless.ssid", "connection", "show", "Pixel hotspot"), done("Pixel 8 Pro\n")),
]


class Terse(unittest.TestCase):
    def test_escaped_colons(self):
        self.assertEqual(eco.split_terse("Cafe\\: 5G:802-11-wireless"), ["Cafe: 5G", "802-11-wireless"])
        self.assertEqual(eco.split_terse("yes:"), ["yes", ""])
        self.assertEqual(eco.split_terse("a\\\\b:c"), ["a\\b", "c"])


class HotspotSetup(unittest.TestCase):
    """How the hotspot finds the phone on machines set up differently from ours."""

    PAIRED = done("Device AA:BB:CC:00:11:22 Galaxy A54\nDevice 11:22:33:44:55:66 WH-1000XM5\n"
                  "Device 66:55:44:33:22:11 Pixel 8 Pro\n")

    def bt(self, explicit="", cfg=None, cache=None, paired=None):
        fake = FakeSystem([(("bluetoothctl", "devices", "Paired"), paired or self.PAIRED)])
        with fake.patch():
            return eco.resolve_bt_mac(explicit, cfg or {}, cache or {})

    def test_bluetooth_found_by_device_name(self):
        self.assertEqual(self.bt(cache={"name": "Galaxy A54"}), "AA:BB:CC:00:11:22")

    def test_bluetooth_found_by_model_case_insensitive(self):
        self.assertEqual(self.bt(cache={"name": "Work phone", "model": "pixel 8 PRO"}), "66:55:44:33:22:11")

    def test_explicit_mac_wins_and_is_normalised(self):
        self.assertEqual(self.bt(explicit=" de:ad:be:ef:00:01 ", cache={"name": "Galaxy A54"}), "DE:AD:BE:EF:00:01")

    def test_config_then_cache(self):
        self.assertEqual(self.bt(cfg={"bt_mac": "01:02:03:04:05:06"}, cache={"bt_mac": "0A:0B:0C:0D:0E:0F"}),
                         "01:02:03:04:05:06")
        self.assertEqual(self.bt(cache={"bt_mac": "0a:0b:0c:0d:0e:0f"}), "0A:0B:0C:0D:0E:0F")

    def test_garbage_mac_falls_through(self):
        self.assertEqual(self.bt(explicit="phone", cache={"name": "Galaxy A54"}), "AA:BB:CC:00:11:22")

    def test_not_paired_explains_setup(self):
        with self.assertRaises(eco.DockError) as cm:
            self.bt(cache={"name": "OnePlus 12"})
        self.assertEqual(cm.exception.code, "hotspot-setup")
        self.assertIn("OnePlus 12", str(cm.exception))

    def test_never_docked_explains_setup(self):
        with self.assertRaises(eco.DockError) as cm:
            self.bt(cache={})
        self.assertEqual(cm.exception.code, "hotspot-setup")

    def test_two_paired_with_same_name_is_not_guessed(self):
        twins = done("Device AA:AA:AA:AA:AA:AA Phone\nDevice BB:BB:BB:BB:BB:BB Phone\n")
        with self.assertRaises(eco.DockError):
            self.bt(cache={"name": "Phone"}, paired=twins)

    def wifi(self, explicit="", cfg=None, cache=None):
        fake = FakeSystem(NM_PROFILES)
        with fake.patch():
            return eco.resolve_wifi(explicit, cfg or {}, cache or {})

    def test_wifi_by_connection_name(self):
        self.assertEqual(self.wifi("Pixel hotspot"), ("Pixel hotspot", "Pixel 8 Pro"))

    def test_wifi_by_ssid_learned_from_phone(self):
        self.assertEqual(self.wifi(cache={"hotspot": "Pixel 8 Pro"}), ("Pixel hotspot", "Pixel 8 Pro"))

    def test_wifi_ssid_with_colon(self):
        self.assertEqual(self.wifi("Cafe:5G"), ("Cafe: 5G", "Cafe:5G"))

    def test_wifi_not_saved_yet(self):
        self.assertEqual(self.wifi(cache={"hotspot": "Galaxy A54 5G"}), ("", "Galaxy A54 5G"))

    def test_wifi_unknown_explains_setup(self):
        with self.assertRaises(eco.DockError) as cm:
            self.wifi()
        self.assertEqual(cm.exception.code, "hotspot-setup")

    def test_setting_beats_config_beats_cache(self):
        self.assertEqual(self.wifi("Home", {"wifi": "Pixel hotspot"}, {"hotspot": "x"})[0], "Home")
        self.assertEqual(self.wifi("", {"wifi": "Pixel hotspot"}, {"hotspot": "HomeNet"})[0], "Pixel hotspot")


class HotspotRun(unittest.TestCase):
    """The whole hotspot command against a faked laptop."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.tmp.name, "device.json")
        with open(self.cache, "w") as f:
            json.dump({"name": "Pixel 8 Pro", "hotspot": "Pixel 8 Pro"}, f)
        self.events = []
        self.patches = [mock.patch.object(eco, "CACHE_PATH", self.cache),
                        mock.patch.object(eco, "CACHE_DIR", self.tmp.name),
                        mock.patch.object(eco, "CONFIG_PATH", "/nonexistent/config"),
                        mock.patch.object(eco, "emit", side_effect=self.events.append),
                        mock.patch.object(eco.shutil, "which", side_effect=lambda t: "/usr/bin/" + t),
                        mock.patch.object(eco.time, "sleep")]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.tmp.cleanup()

    def system(self, active="", visible="", knock_rc=0, up_rc=0, wifi_dev="wlan0:wifi\n"):
        state = {"active": active}

        def up(cmd):
            if up_rc == 0:
                state["active"] = "Pixel 8 Pro"
            return done(rc=up_rc)
        return FakeSystem(NM_PROFILES + [
            (("nmcli", "-t", "-f", "DEVICE,TYPE", "device"), done("lo:loopback\n" + wifi_dev)),
            (("nmcli", "-t", "-f", "ACTIVE,SSID"), lambda c: done(f"yes:{state['active']}\n" if state["active"] else "")),
            (("nmcli", "-t", "-f", "SSID"), done(visible)),
            (("nmcli", "connection", "up"), up),
            (("nmcli",), done()),
            (("bluetoothctl", "devices", "Paired"), done("Device 66:55:44:33:22:11 Pixel 8 Pro\n")),
            (("bluetoothctl", "power", "on"), done()),
            (("bluetoothctl", "info"), done("\tConnected: no\n")),
            (("gdbus",), done(rc=knock_rc)),
        ])

    def run_hotspot(self, fake, **kw):
        args = mock.Mock(bt_mac=kw.get("bt_mac", ""), wifi=kw.get("wifi", ""))
        with fake.patch():
            return eco.cmd_hotspot(args)

    def test_already_on_hotspot_does_nothing(self):
        fake = self.system(active="Pixel 8 Pro")
        self.assertEqual(self.run_hotspot(fake), 0)
        self.assertFalse(fake.ran("gdbus"))
        self.assertTrue(self.events[-1]["ok"])

    def test_wakes_phone_and_joins(self):
        fake = self.system(visible="HomeNet\nPixel 8 Pro\n")
        self.assertEqual(self.run_hotspot(fake), 0)
        self.assertEqual(fake.ran("nmcli", "connection", "up")[0][3], "Pixel hotspot")
        knock = fake.ran("gdbus")[0]
        self.assertIn("/org/bluez/", knock[knock.index("-o") + 1])
        self.assertTrue(knock[knock.index("-o") + 1].endswith("/dev_66_55_44_33_22_11"))
        self.assertIn(eco.AVRCP_UUID, knock)
        self.assertEqual(self.events[-1], {"ok": True, "message": "Laptop is on Pixel 8 Pro"})
        with open(self.cache) as f:
            self.assertEqual(json.load(f)["bt_mac"], "66:55:44:33:22:11")  # learned for next time

    def test_phone_out_of_bluetooth_range(self):
        fake = self.system(knock_rc=1)
        with self.assertRaises(eco.DockError) as cm:
            self.run_hotspot(fake)
        self.assertIn("Bluetooth", str(cm.exception))
        self.assertEqual(len(fake.ran("gdbus")), 3)

    def test_hotspot_never_appears(self):
        fake = self.system(visible="HomeNet\n")
        clock = iter(range(0, 10000, 5))
        with mock.patch.object(eco.time, "monotonic", side_effect=lambda: next(clock)):
            with self.assertRaises(eco.DockError) as cm:
                self.run_hotspot(fake)
        self.assertIn("did not appear", str(cm.exception))

    def test_first_time_without_saved_password(self):
        with open(self.cache, "w") as f:
            json.dump({"name": "Pixel 8 Pro", "hotspot": "Galaxy A54 5G"}, f)
        fake = self.system(visible="Galaxy A54 5G\n")
        with self.assertRaises(eco.DockError) as cm:
            self.run_hotspot(fake)
        self.assertEqual(cm.exception.code, "hotspot-setup")
        self.assertIn("Wi-Fi menu", str(cm.exception))
        self.assertFalse(fake.ran("nmcli", "device", "wifi", "connect"))  # never guesses a password

    def test_desktop_without_wifi(self):
        fake = self.system(wifi_dev="")
        with self.assertRaises(eco.DockError) as cm:
            self.run_hotspot(fake)
        self.assertIn("no Wi-Fi", str(cm.exception))

    def test_missing_bluez(self):
        with mock.patch.object(eco.shutil, "which", side_effect=lambda t: None if t == "bluetoothctl" else "/x"):
            with self.assertRaises(eco.DockError) as cm:
                self.run_hotspot(self.system())
        self.assertEqual(cm.exception.code, "missing-tool")


class Keeper(unittest.TestCase):
    """The background wireless keeper on different setups."""

    def system(self, devices, tcp_port="", tcpip_rc=0, connect_ok=False, kdeconnect="", hotspot=""):
        state = {"devices": devices}

        def connect(cmd):
            if connect_ok:
                state["devices"] = state["devices"] + "192.168.1.20:5555\tdevice\n"
                return done("connected to " + cmd[-1])
            return done("failed to connect to " + cmd[-1])
        return FakeSystem([
            (("adb", "devices"), lambda c: done("List of devices attached\n" + state["devices"])),
            (("adb", "connect"), connect),
            (("adb", "mdns", "services"), done("")),
            (("ip", "-4", "route"), done("default via 192.168.1.20 dev wlan0\n")),
            (("adb", "-s"), lambda c: done(tcp_port + "\n") if "getprop" in c[-1] else done(rc=tcpip_rc)),
            (("kdeconnect-cli",), done(kdeconnect)),
            (("nmcli", "-t", "-f", "DEVICE,TYPE", "device"), done("wlan0:wifi\n")),
            (("nmcli", "-t", "-f", "ACTIVE,SSID"), done(f"yes:{hotspot}\n" if hotspot else "")),
            (("notify-send",), done()),
            (("adb", "disconnect"), done()),
        ])

    def step(self, fake, cfg=None, state=None, mirror=False, cache=None, tools=("kdeconnect-cli", "nmcli", "notify-send")):
        cfg = {"serial": "", "addr": "", **(cfg or {})}
        with fake.patch(), \
             mock.patch.object(eco, "mirror_running", return_value=mirror), \
             mock.patch.object(eco, "read_cache", return_value=cache or {}), \
             mock.patch.object(eco, "log"), \
             mock.patch.object(eco.time, "sleep"), \
             mock.patch.object(eco.shutil, "which", side_effect=lambda t: "/usr/bin/" + t if t in tools else None):
            return eco.keeper_step(cfg, state if state is not None else {})

    def test_wireless_up_is_left_alone(self):
        fake = self.system("192.168.1.20:5555\tdevice\n")
        self.assertEqual(self.step(fake), "ready")
        self.assertFalse(fake.ran("adb", "connect"))

    def test_pinned_usb_serial_still_sees_wireless(self):
        fake = self.system("192.168.1.20:5555\tdevice\n")
        self.assertEqual(self.step(fake, cfg={"serial": "R5CW1234"}), "ready")

    def test_reconnects_after_wifi_blip(self):
        self.assertEqual(self.step(self.system("", connect_ok=True)), "connected")

    def test_usb_phone_switched_to_wireless(self):
        fake = self.system("R5CW1234\tdevice\n", tcp_port="")
        fake.answers.insert(0, (("adb", "connect"), lambda c: (
            done("connected to " + c[-1]) if fake.ran("adb", "-s", "R5CW1234", "tcpip") else done("failed"))))
        orig = fake.answers[1]
        fake.answers[1] = (("adb", "devices"), lambda c: done(
            "List of devices attached\nR5CW1234\tdevice\n"
            + ("192.168.1.20:5555\tdevice\n" if fake.ran("adb", "-s", "R5CW1234", "tcpip") else "")))
        del orig
        self.assertEqual(self.step(fake), "armed")
        self.assertEqual(fake.ran("adb", "-s", "R5CW1234", "tcpip"), [["adb", "-s", "R5CW1234", "tcpip", "5555"]])
        self.assertTrue(fake.ran("notify-send"))

    def test_usb_mirror_is_never_cut(self):
        fake = self.system("R5CW1234\tdevice\n", tcp_port="")
        self.assertEqual(self.step(fake, mirror=True), "deferred")
        self.assertFalse(fake.ran("adb", "-s", "R5CW1234", "tcpip"))

    def test_already_in_tcp_mode_skips_adbd_restart(self):
        fake = self.system("R5CW1234\tdevice\n", tcp_port="5555")
        self.step(fake)
        self.assertFalse(fake.ran("adb", "-s", "R5CW1234", "tcpip"))

    def test_rebooted_phone_nags_once_after_grace(self):
        fake = self.system("", kdeconnect="abc123\n")
        state = {}
        clock = iter([0, 5, 25, 30, 35])
        with mock.patch.object(eco.time, "monotonic", side_effect=lambda: next(clock)):
            self.assertEqual(self.step(fake, state=state), "waiting")   # t=0, grace starts
            self.assertEqual(self.step(fake, state=state), "waiting")   # t=5, still quiet
            self.assertFalse(fake.ran("notify-send"))
            self.step(fake, state=state)                                # t=25, nag
            self.assertEqual(len(fake.ran("notify-send")), 1)
            self.assertEqual(self.step(fake, state=state), "idle")      # warned: quiet now
        self.assertEqual(len(fake.ran("notify-send")), 1)

    def test_no_kdeconnect_uses_hotspot_to_spot_phone(self):
        fake = self.system("", hotspot="Pixel 8 Pro")
        self.assertEqual(self.step(fake, cache={"hotspot": "Pixel 8 Pro"}, tools=("nmcli",)), "waiting")

    def test_nothing_around_is_idle_and_quiet(self):
        fake = self.system("")
        self.assertEqual(self.step(fake, tools=()), "idle")
        self.assertFalse(fake.ran("notify-send"))

    def test_keeper_without_adb_exits_cleanly(self):
        events = []
        with mock.patch.object(eco.shutil, "which", return_value=None), \
             mock.patch.object(eco, "emit", side_effect=events.append):
            self.assertEqual(eco.cmd_keeper(mock.Mock(once=True)), 0)
        self.assertEqual(events[0]["state"], "off")

    def test_second_keeper_backs_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = os.path.join(tmp, "keeper.lock")
            import fcntl
            holder = open(lock, "w")
            fcntl.flock(holder, fcntl.LOCK_EX)
            events = []
            with mock.patch.object(eco, "STATE_DIR", tmp), mock.patch.object(eco, "LOCK_PATH", lock), \
                 mock.patch.object(eco.shutil, "which", return_value="/usr/bin/adb"), \
                 mock.patch.object(eco, "emit", side_effect=events.append):
                self.assertEqual(eco.cmd_keeper(mock.Mock(once=True)), 0)
            holder.close()
        self.assertEqual(events[0]["message"], "another keeper is running")


class Cache(unittest.TestCase):
    def test_merge_keeps_learned_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "device.json")
            with mock.patch.object(eco, "CACHE_PATH", path), mock.patch.object(eco, "CACHE_DIR", tmp):
                eco.write_cache({"name": "Pixel", "bt_mac": "AA:BB:CC:DD:EE:FF"})
                eco.write_cache({"name": "Pixel 8", "hotspot": "", "bt_mac": None})  # older Android: no SSID
                self.assertEqual(eco.read_cache(), {"name": "Pixel 8", "bt_mac": "AA:BB:CC:DD:EE:FF"})

    def test_corrupt_or_old_cache(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not json")
        try:
            with mock.patch.object(eco, "CACHE_PATH", f.name):
                self.assertEqual(eco.read_cache(), {})
        finally:
            os.unlink(f.name)


class OlderPhones(unittest.TestCase):
    def info(self, text):
        with mock.patch.object(eco, "adb", return_value=done(text)):
            return eco.device_info("SER")

    def test_hotspot_name_read(self):
        d = self.info("Physical size: 1080x2400\n@@\nPixel 8 Pro\n@@\nPixel 8 Pro\n@@\n  level: 50\n@@\n"
                      'mCurrentSoftApConfiguration: ssid = "Pixel 8 Pro"')
        self.assertEqual(d["hotspot"], "Pixel 8 Pro")

    def test_no_hotspot_section(self):
        d = self.info("Physical size: 720x1600\n@@\nnull\n@@\nMoto G\n@@\n  level: 9\n")
        self.assertEqual((d["hotspot"], d["name"], d["battery"]), ("", "Moto G", 9))


class OldConfigs(unittest.TestCase):
    def load(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write(text)
        try:
            with mock.patch.object(eco, "CONFIG_PATH", f.name):
                return eco.load_config()
        finally:
            os.unlink(f.name)

    def test_phone_mirror_hotspot_settings(self):
        cfg = self.load("PHONE_BT_MAC=aa:bb:cc:dd:ee:ff   # phone\nPHONE_WIFI='My hotspot'\nPHONE_HOTSPOT_WAIT=90\n")
        self.assertEqual((cfg["bt_mac"], cfg["wifi"], cfg["hotspot_wait"]), ("AA:BB:CC:DD:EE:FF", "My hotspot", 90))

    def test_bad_wait_values(self):
        self.assertEqual(self.load("PHONE_HOTSPOT_WAIT=soon\n")["hotspot_wait"], 40)
        self.assertEqual(self.load("PHONE_HOTSPOT_WAIT=1\n")["hotspot_wait"], 5)
        self.assertEqual(self.load("PHONE_HOTSPOT_WAIT=99999\n")["hotspot_wait"], 300)

    def test_broken_config_still_gives_defaults(self):
        cfg = self.load("this is not bash (\nPHONE_ADDR=10.0.0.2:5555\n")
        self.assertEqual(cfg["bt_mac"], "")
        self.assertEqual(cfg["hotspot_wait"], 40)


class Markup(unittest.TestCase):
    """Clipboard text, file names and the phone's name are untrusted. Qt's
    default AutoText renders them as HTML, so `<img src=http://…>` in copied
    text would make the shell fetch that URL. Every Text must be plain."""

    def test_every_text_is_plain(self):
        for name in ("Dock.qml", "BarWidget.qml"):
            with open(os.path.join(ROOT, name)) as f:
                lines = f.read().splitlines()
            for i, line in enumerate(lines):
                if re.match(r"^\s*(Text|Label|TextEdit|TextArea)\s*\{", line):
                    depth, block = 0, []
                    for l in lines[i:]:
                        block.append(l)
                        depth += l.count("{") - l.count("}")
                        if depth <= 0:
                            break
                    own = [l for l in block if l.startswith(re.match(r"^\s*", line).group(0) + "  ")
                           and not l.startswith(re.match(r"^\s*", line).group(0) + "    ")]
                    self.assertTrue(any("textFormat: Text.PlainText" in l for l in own),
                                    f"{name}:{i + 1} Text without textFormat: Text.PlainText")

    def test_no_html_rendering_anywhere(self):
        for name in ("Dock.qml", "BarWidget.qml"):
            with open(os.path.join(ROOT, name)) as f:
                text = f.read()
            for bad in ("Text.RichText", "Text.StyledText", "Text.AutoText", "Text.MarkdownText"):
                self.assertNotIn(bad, text, f"{bad} in {name}")


class Manifest(unittest.TestCase):
    def test_settings_match_dock(self):
        with open(os.path.join(ROOT, "manifest.json")) as f:
            bw = json.load(f)["barWidget"]
        with open(os.path.join(ROOT, "Dock.qml")) as f:
            dock = f.read()
        keys = [s["key"] for s in bw["schema"]]
        self.assertEqual(sorted(keys), sorted(bw["defaults"]))
        for s in bw["schema"]:
            self.assertEqual(bw["defaults"][s["key"]], s["defaultValue"], s["key"])
            self.assertIn(f'setting("{s["key"]}"', dock, s["key"])

    def test_no_privileged_or_service_commands(self):
        """The marketplace baseline flags sudo/pkexec/systemctl for manual review."""
        for name in ("bin/omaecosystem", "Dock.qml", "BarWidget.qml", "README.md", "Makefile", "manifest.json"):
            with open(os.path.join(ROOT, name)) as f:
                text = f.read()
            for word in ("sudo", "pkexec", "systemctl", "systemd-run"):
                self.assertNotRegex(text, r"\b" + word + r"\b", f"{word} in {name}")

    def test_manifest_matches_files(self):
        with open(os.path.join(ROOT, "manifest.json")) as f:
            m = json.load(f)
        self.assertEqual(m["schemaVersion"], 1)
        self.assertFalse(m["id"].startswith("omarchy."))
        for entry in m["entryPoints"].values():
            self.assertTrue(os.path.isfile(os.path.join(ROOT, entry)), entry)
        with open(os.path.join(ROOT, "Dock.qml")) as f:
            self.assertIn('"' + m["id"] + '"', f.read())


if __name__ == "__main__":
    unittest.main()
