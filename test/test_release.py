import hashlib
import contextlib
import importlib.util
import io
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_script("release")
wally = load_script("publish_wally")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "imposter-render").mkdir()
        for name in ("Cargo.toml", "imposter-render/wally.toml"):
            (self.root / name).write_text('[package]\nversion = "0.1.0"\n', encoding="utf-8")
        (self.root / "Cargo.lock").write_text('[[package]]\nname = "imposter-baker"\nversion = "0.1.0"\n', encoding="utf-8")

    def test_tag_must_match_both_manifests_and_lockfile(self):
        self.assertEqual(release.validate(self.root, "v0.1.0"), "0.1.0")
        for invalid in ("main", "0.1.0", "v01.1.0", "v0.1.1", "v0.1.0-01", "v0.1.0;echo bad"):
            with self.subTest(tag=invalid), self.assertRaises(ValueError):
                release.validate(self.root, invalid)
        (self.root / "imposter-render/wally.toml").write_text('[package]\nversion="0.2.0"\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            release.validate(self.root, "v0.1.0")
        (self.root / "imposter-render/wally.toml").write_text('[package]\nversion="0.1.0"\n', encoding="utf-8")
        (self.root / "Cargo.lock").write_text('[[package]]\nname="imposter-baker"\nversion="0.0.1"\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            release.validate(self.root, "v0.1.0")

    def test_archive_is_reproducible_and_preserves_unix_executable_permission(self):
        binary = self.root / "target/x86_64-unknown-linux-gnu/release/imposter-baker"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"test executable")
        (self.root / "LICENSE").write_text("license", encoding="utf-8")
        (self.root / "README.md").write_text("readme", encoding="utf-8")
        output = self.root / "dist"
        path = release.package(self.root, "v0.1.0", "linux-x86_64", output)
        first = path.read_bytes()
        with zipfile.ZipFile(path) as archive:
            self.assertEqual(set(archive.namelist()), {"imposter-baker", "LICENSE", "README.md"})
            self.assertEqual(archive.read("imposter-baker"), b"test executable")
            mode = archive.getinfo("imposter-baker").external_attr >> 16
            self.assertTrue(mode & stat.S_IXUSR)
        os.utime(binary, (1_700_000_000, 1_700_000_000))
        self.assertEqual(release.package(self.root, "v0.1.0", "linux-x86_64", output).read_bytes(), first)

    def test_checksums_require_the_complete_asset_set(self):
        directory = self.root / "dist"
        directory.mkdir()
        with self.assertRaises(ValueError):
            release.checksums(directory, "v0.1.0")
        for platform in release.PLATFORMS:
            (directory / f"imposter-baker-0.1.0-{platform}.zip").write_bytes(b"zip")
        (directory / "imposter-render.zip").write_bytes(b"wally")
        (directory / "imposter-render.rbxm").write_bytes(b"model")
        (directory / "demo.rbxl").write_bytes(b"place")
        result = release.checksums(directory, "v0.1.0")
        for line in result.read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((directory / name).read_bytes()).hexdigest())
        self.assertEqual(len(result.read_text().splitlines()), 8)
        self.assertEqual(release.checksums(directory, "v0.1.0").read_bytes(), result.read_bytes())

    @patch.dict(os.environ, {"WALLY_AUTH_TOKEN": "test-token"})
    @patch.object(wally.subprocess, "run")
    def test_wally_zero_exit_http_failure_is_rejected(self, run):
        run.side_effect = [CompletedProcess([], 0, "", ""), CompletedProcess([], 0, "Error: 403 Forbidden\n", "")]
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            wally.publish()

    @patch.dict(os.environ, {"WALLY_AUTH_TOKEN": "test-token"})
    @patch.object(wally.subprocess, "run")
    def test_wally_confirmed_publication_succeeds(self, run):
        run.side_effect = [CompletedProcess([], 0, "", ""), CompletedProcess([], 0, "Package published successfully!\n", "")]
        with contextlib.redirect_stdout(io.StringIO()):
            wally.publish()

    @patch.dict(os.environ, {}, clear=True)
    @patch.object(wally.subprocess, "run")
    def test_missing_wally_secret_fails_before_authentication(self, run):
        with self.assertRaises(RuntimeError):
            wally.publish()
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
