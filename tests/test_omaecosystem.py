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
        self.assertEqual(cfg, {"serial": "", "addr": "", "audio": False, "scrcpy_args": []})


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


class Manifest(unittest.TestCase):
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
