"""Validate versions and assemble Rokit-compatible release assets (Python 3.11+)."""

import argparse
import hashlib
import re
import stat
import tomllib
import zipfile
from pathlib import Path

PLATFORMS = {
    "windows-x86_64": ("x86_64-pc-windows-msvc", ".exe"),
    "linux-x86_64": ("x86_64-unknown-linux-gnu", ""),
    "linux-aarch64": ("aarch64-unknown-linux-gnu", ""),
    "macos-x86_64": ("x86_64-apple-darwin", ""),
    "macos-aarch64": ("aarch64-apple-darwin", ""),
}
TAG_PATTERN = re.compile(
    r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
)


def validate(root: Path, tag: str) -> str:
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("release tag must be vMAJOR.MINOR.PATCH with an optional SemVer prerelease")
    version = tag[1:]
    for filename in ("Cargo.toml", "imposter-render/wally.toml"):
        manifest = tomllib.loads((root / filename).read_text(encoding="utf-8"))
        if manifest["package"]["version"] != version:
            raise ValueError(f"{filename} version must match {tag}")
    lock = tomllib.loads((root / "Cargo.lock").read_text(encoding="utf-8"))
    versions = [p["version"] for p in lock["package"] if p["name"] == "imposter-baker"]
    if versions != [version]:
        raise ValueError("Cargo.lock must contain the matching imposter-baker version; run cargo check")
    return version


def package(root: Path, tag: str, platform: str, output: Path) -> Path:
    version = validate(root, tag)
    target, extension = PLATFORMS[platform]
    name = "imposter-baker" + extension
    binary = root / "target" / target / "release" / name
    files = {name: binary, "LICENSE": root / "LICENSE", "README.md": root / "README.md"}
    for source in files.values():
        if not source.is_file():
            raise ValueError(f"missing release input: {source}")
    output.mkdir(parents=True, exist_ok=True)
    path = output / f"imposter-baker-{version}-{platform}.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for archive_name, source in files.items():
            entry = zipfile.ZipInfo(archive_name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = 0o755 if archive_name == name else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, source.read_bytes())
    return path


def checksums(directory: Path, tag: str) -> Path:
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("invalid release tag")
    version = tag[1:]
    expected = {f"imposter-baker-{version}-{p}.zip" for p in PLATFORMS}
    expected.update(("imposter-render.zip", "imposter-render.rbxm", "demo.rbxl"))
    actual = {p.name for p in directory.iterdir() if p.is_file() and p.name != "SHA256SUMS"}
    if actual != expected:
        raise ValueError(f"unexpected release assets: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
    lines = []
    for name in sorted(expected):
        with (directory / name).open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        lines.append(f"{digest}  {name}\n")
    path = directory / "SHA256SUMS"
    path.write_text("".join(lines), encoding="utf-8", newline="\n")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("validate")
    check.add_argument("tag")
    pack = commands.add_parser("package")
    pack.add_argument("tag")
    pack.add_argument("platform", choices=PLATFORMS)
    pack.add_argument("--output", type=Path, default=Path("dist"))
    sums = commands.add_parser("checksums")
    sums.add_argument("tag")
    sums.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            print(validate(args.root, args.tag))
        elif args.command == "package":
            print(package(args.root, args.tag, args.platform, args.output))
        else:
            print(checksums(args.directory, args.tag))
    except (ValueError, OSError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
