#!/usr/bin/env python3
"""Deterministic Finder-downloadable ZIP; no macOS build or account needed."""
from __future__ import annotations

import hashlib
import stat
import subprocess
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "dist" / "MP3-Shelf-One-Click-Installer.zip"
SCRIPT = HERE / "one-click-installer.command"
DOC = HERE / "one-click-README.md"


def build() -> Path:
    script = SCRIPT.read_bytes()
    assert script.startswith(b"#!/bin/bash\n"), "Installer needs a Bash shebang"
    validation = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    if validation.returncode:
        raise RuntimeError(f"Bash syntax validation failed: {validation.stderr}")
    readme = (
        "MP3 SHELF — ONE-CLICK MAC INSTALLER\n\n"
        "1. Unzip this file on your Mac.\n"
        "2. Double-click 'Install MP3 Shelf.command' in Finder.\n"
        "3. Click Install and answer the secure account prompts as needed.\n\n"
        "There are NO Terminal commands to type. Terminal opens automatically\n"
        "for installation progress, browser sign-in and private credential entry.\n\n"
        "IMPORTANT: This installer is not Apple Developer ID signed/notarized.\n"
        "If macOS blocks opening it, attempt to open once, then go to\n"
        "System Settings > Privacy & Security > Open Anyway for this file.\n"
        "Do not disable Gatekeeper globally.\n\n"
        "Prerequisites: Full Xcode, an Internet connection, a DeepSeek Console\n"
        "API key, Cloudflare login if needed, and two narrow GitHub tokens for\n"
        "independent draft-PR publishing and QA status updates.\n\n"
        "The setup installs to ~/MP3ShelfAgents, reuses the existing Cloudflare\n"
        "Free Worker/D1, and leaves all five agent jobs PAUSED by default.\n"
        "No DeepSeek model requests, GitHub Actions or production merges are\n"
        "performed by the installer.\n\n"
        "Source and detailed documentation:\n"
        "https://github.com/jonnyt123/mp3-shelf/blob/"
        "agent/mp3-deepseek-low-cost-worker/tools/deepseek-agents/mac/"
        "one-click-README.md\n"
    ).encode("utf8")
    manifest = (
        f"Install MP3 Shelf.command  SHA-256  {hashlib.sha256(script).hexdigest()}\n"
        f"README - Open First.txt  SHA-256  {hashlib.sha256(readme).hexdigest()}\n"
    ).encode("ascii")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    payloads = [
        ("Install MP3 Shelf.command", script, 0o755),
        ("README - Open First.txt", readme, 0o644),
        ("CHECKSUMS.txt", manifest, 0o644),
    ]
    with zipfile.ZipFile(OUT, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as target:
        for name, data, mode in payloads:
            info = zipfile.ZipInfo(name)
            info.date_time = (2026, 11, 2, 0, 0, 0)
            info.create_system = 3
            info.external_attr = ((stat.S_IFREG | mode) << 16)
            info.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(info, data)
    with zipfile.ZipFile(OUT, "r") as verify:
        assert verify.testzip() is None
        assert all(verify.read(name) == contents for name, contents, _ in payloads)
        assert (verify.getinfo("Install MP3 Shelf.command").external_attr >> 16) & 0o111
    print(f"Created {OUT} ({OUT.stat().st_size} bytes)")
    print(f"Package SHA-256: {hashlib.sha256(OUT.read_bytes()).hexdigest()}")
    return OUT


if __name__ == "__main__":
    build()
