#!/usr/bin/env python3
"""rv-restore: install / remove the RVRestore mod for "RV There Yet?" (Linux / Proton).

  ./rv_restore.py install      install UE4SS (if missing) + the mod into the game folder (game must be closed)
  ./rv_restore.py uninstall    remove the mod   (--all also removes UE4SS)

Standalone: needs only Python 3 (no other packages). See README.md.
"""
from __future__ import annotations

import argparse
import io
import json
import re
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable

MOD = "RVRestore"
SIBLING_MODS = ("RVWheel",)    # independent mods that may share this UE4SS: never touched, but they keep it alive
SOURCE = Path(__file__).resolve().parent / "mod" / MOD
UE4SS_API = "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest"
LAUNCH_OPTION = 'WINEDLLOVERRIDES="dwmapi=n,b" %command%'


class InstallError(Exception):
    pass


def steam_libraries(steam_root: Path | None = None) -> list[Path]:
    roots = [steam_root] if steam_root else [Path.home() / ".local/share/Steam", Path.home() / ".steam/steam"]
    out: list[Path] = []
    for root in roots:
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            out += [Path(m) for m in re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(errors="replace"))]
        if (root / "steamapps").is_dir():
            out.append(root)
    return list(dict.fromkeys(out))


def find_game(steam_root: Path | None = None) -> Path | None:
    for lib in steam_libraries(steam_root):
        cand = lib / "steamapps" / "common" / "Ride"
        if (cand / "Ride" / "Binaries" / "Win64").is_dir():
            return cand
    return None


def game_running(proc: Path = Path("/proc")) -> bool:
    for cmd in proc.glob("[0-9]*/cmdline"):
        try:
            if b"Ride-Win64-Shipping" in cmd.read_bytes():
                return True
        except OSError:
            continue
    return False


def win64(game_dir: Path) -> Path:
    w = game_dir / "Ride" / "Binaries" / "Win64"
    if not w.is_dir():
        raise InstallError(f"{game_dir} does not look like the game folder (no Ride/Binaries/Win64)")
    return w


def download_ue4ss(opener: Callable = urllib.request.urlopen) -> bytes:
    """Latest UE4SS experimental build (the stable v3.0.1 predates Unreal 5.6 support)."""
    def get(url: str, timeout: int):
        return opener(urllib.request.Request(url, headers={"User-Agent": "rv-restore"}), timeout=timeout)
    with get(UE4SS_API, 30) as r:
        release = json.load(r)
    for a in release.get("assets", []):
        if re.fullmatch(r"UE4SS_v[\w.\-]+\.zip", a["name"]) and not a["name"].startswith("zDEV"):
            with get(a["browser_download_url"], 120) as r:
                return r.read()
    raise InstallError("no UE4SS zip found in the experimental-latest release; pass --ue4ss-zip")


def extract_ue4ss(data: bytes, dest: Path) -> int:
    n = 0
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        if "dwmapi.dll" not in names or not any(x.startswith("ue4ss/UE4SS.dll") for x in names):
            raise InstallError("that zip does not look like a UE4SS release (no dwmapi.dll / ue4ss/UE4SS.dll)")
        root = dest.resolve()
        for info in z.infolist():
            target = (dest / info.filename).resolve()
            if root not in target.parents and target != root:
                raise InstallError(f"unsafe path in zip: {info.filename}")
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if target.name in ("UE4SS-settings.ini", "mods.txt", "mods.json") and target.exists():
                continue                      # never overwrite the user's UE4SS settings / mod list
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(info))
            n += 1
    return n


def install(game_dir: Path, ue4ss_zip: Path | None = None, running: Callable[[], bool] = game_running,
            download: Callable[[], bytes] = download_ue4ss, force: bool = False, log=print) -> None:
    w = win64(game_dir)
    if running() and not force:
        raise InstallError("the game is running - close it first")
    if not SOURCE.is_dir():
        raise InstallError(f"mod sources not found at {SOURCE}")
    if (w / "dwmapi.dll").exists() and (w / "ue4ss" / "UE4SS.dll").exists():
        log("UE4SS already present - leaving it as is")
    else:
        log("UE4SS not found in the game folder, installing it ...")
        log(f"  installed UE4SS ({extract_ue4ss(ue4ss_zip.read_bytes() if ue4ss_zip else download(), w)} files)")
    dest = w / "ue4ss" / "Mods" / MOD
    kept = {p.name: p.read_bytes() for p in dest.glob("Scripts/*_config.lua")} if dest.exists() else {}
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(SOURCE, dest)
    for name, data in kept.items():           # keep the user's edited settings across updates
        (dest / "Scripts" / name).write_bytes(data)
    log(f"installed the {MOD} mod into {dest}")
    log("")
    log("One manual step: in Steam, right-click the game -> Properties -> Launch Options, and set:")
    log(f"    {LAUNCH_OPTION}")
    log("(Skip it if you already set it for another UE4SS mod.)  Then just play.")


def uninstall(game_dir: Path, everything: bool = False, running: Callable[[], bool] = game_running,
              force: bool = False, log=print) -> None:
    w = win64(game_dir)
    if running() and not force:
        raise InstallError("the game is running - close it first")
    dest = w / "ue4ss" / "Mods" / MOD
    if dest.exists():
        shutil.rmtree(dest)
        log(f"removed {dest}")
    if everything:
        in_use = [m for m in SIBLING_MODS if (w / "ue4ss" / "Mods" / m).exists()]
        if in_use:
            log(f"kept UE4SS: still used by {', '.join(in_use)}")
            return
        for p in (w / "dwmapi.dll", w / "ue4ss"):
            shutil.rmtree(p) if p.is_dir() else p.unlink(missing_ok=True)
        log("removed UE4SS; you can also clear the Steam launch option")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("install", help="install UE4SS (if missing) + the mod")
    i.add_argument("--game-dir", help="path to .../steamapps/common/Ride (default: found via Steam)")
    i.add_argument("--ue4ss-zip", help="use this UE4SS zip instead of downloading the latest experimental build")
    i.add_argument("--force", action="store_true", help="even if the game appears to be running")
    u = sub.add_parser("uninstall", help="remove the mod")
    u.add_argument("--game-dir")
    u.add_argument("--all", action="store_true", help="also remove UE4SS")
    u.add_argument("--force", action="store_true")
    args = ap.parse_args(argv)
    try:
        game = Path(args.game_dir) if args.game_dir else find_game()
        if game is None:
            raise InstallError("could not find the game in your Steam libraries; pass --game-dir <.../steamapps/common/Ride>")
        if args.cmd == "install":
            install(game, Path(args.ue4ss_zip) if args.ue4ss_zip else None, force=args.force)
        else:
            uninstall(game, everything=args.all, force=args.force)
    except InstallError as ex:
        print(f"error: {ex}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
