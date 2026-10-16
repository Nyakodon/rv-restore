import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import rv_restore as rr  # noqa: E402

LUA = shutil.which("lua5.4") or shutil.which("lua")


def make_zip(with_dll=True, extra=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        if with_dll:
            z.writestr("dwmapi.dll", b"proxy")
            z.writestr("ue4ss/UE4SS.dll", b"core")
        z.writestr("ue4ss/UE4SS-settings.ini", b"default")
        z.writestr("ue4ss/Mods/mods.txt", b"Keybinds : 1\n")
        for k, v in (extra or {}).items():
            z.writestr(k, v)
    return buf.getvalue()


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.game = Path(self.tmp.name) / "Ride"
        self.w = self.game / "Ride" / "Binaries" / "Win64"
        self.w.mkdir(parents=True)
        self.logs = []

    def tearDown(self):
        self.tmp.cleanup()

    def inst(self, **kw):
        kw.setdefault("running", lambda: False)
        kw.setdefault("download", make_zip)
        rr.install(self.game, log=self.logs.append, **kw)

    def test_fresh_install(self):
        self.inst()
        self.assertEqual((self.w / "dwmapi.dll").read_bytes(), b"proxy")
        mod = self.w / "ue4ss" / "Mods" / "RVRestore"
        for f in ("enabled.txt", "Scripts/main.lua", "Scripts/rvr_logic.lua", "Scripts/rvr_config.lua"):
            self.assertTrue((mod / f).exists(), f)
        self.assertIn('WINEDLLOVERRIDES="dwmapi=n,b" %command%', "\n".join(self.logs))

    def test_refuses_while_game_runs(self):
        with self.assertRaises(rr.InstallError):
            self.inst(running=lambda: True)
        self.assertEqual(list(self.w.iterdir()), [])

    def test_reuses_existing_ue4ss_and_keeps_settings(self):
        (self.w / "ue4ss").mkdir()
        (self.w / "dwmapi.dll").write_bytes(b"mine")
        (self.w / "ue4ss" / "UE4SS.dll").write_bytes(b"mine")
        (self.w / "ue4ss" / "UE4SS-settings.ini").write_bytes(b"my-settings")
        self.inst(download=lambda: (_ for _ in ()).throw(AssertionError("must not download")))
        self.assertEqual((self.w / "dwmapi.dll").read_bytes(), b"mine")
        self.assertEqual((self.w / "ue4ss" / "UE4SS-settings.ini").read_bytes(), b"my-settings")

    def test_settings_survive_update(self):
        self.inst()
        cfg = self.w / "ue4ss" / "Mods" / "RVRestore" / "Scripts" / "rvr_config.lua"
        cfg.write_text("return { settle_seconds = 99 }")
        (cfg.parent / "rvr_logic.lua").write_text("stale")
        self.inst()
        self.assertEqual(cfg.read_text(), "return { settle_seconds = 99 }")
        self.assertNotEqual((cfg.parent / "rvr_logic.lua").read_text(), "stale")

    def test_bad_or_malicious_zip(self):
        with self.assertRaises(rr.InstallError):
            self.inst(download=lambda: make_zip(with_dll=False))
        with self.assertRaises(rr.InstallError):
            self.inst(download=lambda: make_zip(extra={"../escape.txt": b"x"}))
        self.assertFalse((Path(self.tmp.name) / "escape.txt").exists())

    def test_not_a_game_folder(self):
        with self.assertRaises(rr.InstallError):
            rr.install(Path(self.tmp.name) / "nope", running=lambda: False, log=self.logs.append)

    def test_coexists_with_the_independent_wheel_mod(self):
        other = self.w / "ue4ss" / "Mods" / "RVWheel"
        (other / "Scripts").mkdir(parents=True)
        (other / "Scripts" / "rvw_logic.lua").write_text("wheel code")
        (other / "Scripts" / "rvw_config.lua").write_text("wheel settings")
        self.inst()                                                           # install next to it
        self.assertEqual((other / "Scripts" / "rvw_logic.lua").read_text(), "wheel code")
        self.assertEqual((other / "Scripts" / "rvw_config.lua").read_text(), "wheel settings")
        rr.uninstall(self.game, everything=True, running=lambda: False, log=self.logs.append)
        self.assertFalse((self.w / "ue4ss" / "Mods" / "RVRestore").exists())
        self.assertTrue((self.w / "dwmapi.dll").exists(), "UE4SS must stay: RVWheel still needs it")
        self.assertTrue((other / "Scripts" / "rvw_logic.lua").exists())
        self.assertIn("kept UE4SS", "\n".join(self.logs))

    def test_uninstall_all_removes_ue4ss_when_nothing_else_uses_it(self):
        self.inst()
        rr.uninstall(self.game, running=lambda: False, log=self.logs.append)
        self.assertFalse((self.w / "ue4ss" / "Mods" / "RVRestore").exists())
        self.assertTrue((self.w / "dwmapi.dll").exists())                     # plain uninstall keeps UE4SS
        rr.uninstall(self.game, everything=True, running=lambda: False, log=self.logs.append)
        self.assertFalse((self.w / "dwmapi.dll").exists())
        self.assertFalse((self.w / "ue4ss").exists())
        with self.assertRaises(rr.InstallError):
            rr.uninstall(self.game, running=lambda: True, log=self.logs.append)

    def test_download_picks_the_release_zip(self):
        zdata = make_zip()
        api = json.dumps({"assets": [
            {"name": "zDEV-UE4SS_v3.0.1-1.zip", "browser_download_url": "http://x/dev"},
            {"name": "zCustomGameConfigs.zip", "browser_download_url": "http://x/cfg"},
            {"name": "UE4SS_v3.0.1-1176-gabc.zip", "browser_download_url": "http://x/good"}]}).encode()
        urls = []

        class R(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): return False

        def opener(req, timeout=0):
            urls.append(req.full_url)
            return R(api if "api.github.com" in req.full_url else zdata)

        self.assertEqual(rr.download_ue4ss(opener), zdata)
        self.assertEqual(urls[-1], "http://x/good")

    def test_game_detection(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / "1").mkdir(); (p / "1" / "cmdline").write_bytes(b"bash")
            self.assertFalse(rr.game_running(p))
            (p / "2").mkdir(); (p / "2" / "cmdline").write_bytes(b"Z:\\x\\Ride-Win64-Shipping.exe\0Ride")
            self.assertTrue(rr.game_running(p))
            steam = p / "Steam"; (steam / "steamapps").mkdir(parents=True)
            lib = p / "lib"; (lib / "steamapps" / "common" / "Ride" / "Ride" / "Binaries" / "Win64").mkdir(parents=True)
            (steam / "steamapps" / "libraryfolders.vdf").write_text(f'"x"{{ "0"{{ "path" "{lib}" }} }}')
            self.assertEqual(rr.find_game(steam), lib / "steamapps" / "common" / "Ride")


@unittest.skipUnless(LUA, "no lua interpreter installed")
class LuaTests(unittest.TestCase):
    def test_mod_logic(self):
        r = subprocess.run([LUA, str(ROOT / "tests/lua/test_restore.lua"), str(ROOT / "mod/RVRestore/Scripts")],
                           capture_output=True, text=True, cwd=ROOT, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("0 failed", r.stdout)

    def test_mod_is_self_contained(self):
        src = "".join(p.read_text() for p in (ROOT / "mod/RVRestore/Scripts").glob("*.lua"))
        for forbidden in ("rvw_", "RVWheel", "/dev/shm", "rv-wheel"):
            self.assertNotIn(forbidden, src, f"RVRestore must not depend on the wheel mod ({forbidden})")


if __name__ == "__main__":
    unittest.main()
