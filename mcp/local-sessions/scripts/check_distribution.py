"""Build first. Inspect artifacts and test the installed wheel without model calls."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import venv
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = {f"session_bridge/{p.name}" for p in (ROOT / "session_bridge").glob("*.py")}
DOCS = {str(p.relative_to(ROOT)) for p in (ROOT / "docs").glob("*.md")}
TESTS = {str(p.relative_to(ROOT)) for p in (ROOT / "tests").glob("*.py")}
SDIST = PACKAGE | DOCS | TESTS | {
    "README.md", "LICENSE", "SECURITY.md", "AGENTS.md", "pyproject.toml",
    "MANIFEST.in", "scripts/check_distribution.py", "PKG-INFO", "setup.cfg",
}
EGG_FILES = {"PKG-INFO", "SOURCES.txt", "dependency_links.txt", "entry_points.txt",
             "requires.txt", "top_level.txt"}
DIST_FILES = {"METADATA", "WHEEL", "entry_points.txt", "top_level.txt", "RECORD", "licenses/LICENSE"}


def check_sdist(path):
    with tarfile.open(path) as archive:
        members = archive.getmembers()
        for member in members:
            relative = "/".join(member.name.split("/")[1:])
            if not relative or member.isdir():
                continue
            assert member.isfile(), f"Non-regular member: {relative}"
            allowed = relative in SDIST
            if relative.startswith("local_session_bridge.egg-info/"):
                allowed = relative.split("/", 1)[1] in EGG_FILES
            assert allowed, f"Unexpected sdist file: {relative}"


def check_wheel(path):
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            allowed = name in PACKAGE
            if ".dist-info/" in name:
                prefix, rest = name.split(".dist-info/", 1)
                allowed = prefix.startswith("local_session_bridge-") and rest in DIST_FILES
            assert allowed, f"Unexpected wheel file: {name}"


def main():
    wheels = list((ROOT / "dist").glob("*.whl"))
    sources = list((ROOT / "dist").glob("*.tar.gz"))
    assert len(wheels) == len(sources) == 1, "Expected exactly one wheel and one sdist"
    check_wheel(wheels[0])
    check_sdist(sources[0])
    with tempfile.TemporaryDirectory(prefix="bridge-package-check-") as tmp:
        root = Path(tmp)
        venv.EnvBuilder(with_pip=True, system_site_packages=True).create(root / "venv")
        python = root / "venv/bin/python"
        subprocess.run([str(python), "-m", "pip", "install", "--no-deps", str(wheels[0])], check=True)
        shutil.copytree(ROOT / "tests", root / "tests", ignore=shutil.ignore_patterns("__pycache__"))
        env = dict(os.environ)
        env.pop("PYTHONPATH", None)
        env["CODEX_HOME"] = str(root / "empty-config")
        env["SESSION_BRIDGE_HOME"] = str(root / "unused-default-state")
        subprocess.run([str(python), "-c",
            "import pathlib, session_bridge; p=pathlib.Path(session_bridge.__file__).resolve(); "
            "assert 'site-packages' in p.parts, p; print('Installed package:', p)"],
            cwd=root, env=env, check=True)
        subprocess.run([str(python), "-m", "unittest", "discover", "-s", "tests", "-v"],
                       cwd=root, env=env, check=True)
    print("Distribution allowlists and installed-wheel tests passed")


if __name__ == "__main__":
    main()
