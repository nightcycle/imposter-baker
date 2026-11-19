import hashlib
import contextlib
import importlib.util
import io
import itertools
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from subprocess import CalledProcessError, CompletedProcess
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
        for invalid in ("", "v", "main", "v01.1.0", "v0.1.1", "v0.v1.0", "v0.1.0-01", "v0.1.0;echo bad"):
            with self.subTest(tag=invalid), self.assertRaises(ValueError):
                release.validate(self.root, invalid)
        (self.root / "imposter-render/wally.toml").write_text('[package]\nversion="0.2.0"\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            release.validate(self.root, "v0.1.0")
        (self.root / "imposter-render/wally.toml").write_text('[package]\nversion="0.1.0"\n', encoding="utf-8")
        (self.root / "Cargo.lock").write_text('[[package]]\nname="imposter-baker"\nversion="0.0.1"\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            release.validate(self.root, "v0.1.0")

    def test_comparisons_ignore_all_leading_v_prefixes_on_either_side(self):
        for version in ("0.1.0", "0.1.0-preview.1"):
            for prefixes in itertools.product(("", "v", "Vv"), repeat=4):
                with self.subTest(version=version, prefixes=prefixes):
                    tag, cargo, wally_version, lock = [prefix + version for prefix in prefixes]
                    for name, value in (("Cargo.toml", cargo), ("imposter-render/wally.toml", wally_version)):
                        (self.root / name).write_text(f'[package]\nversion = "{value}"\n', encoding="utf-8")
                    (self.root / "Cargo.lock").write_text(
                        f'[[package]]\nname = "imposter-baker"\nversion = "{lock}"\n', encoding="utf-8"
                    )
                    self.assertEqual(release.validate(self.root, tag), version)

    def test_prerelease_identifiers_must_still_match_exactly(self):
        for name in ("Cargo.toml", "imposter-render/wally.toml"):
            (self.root / name).write_text('[package]\nversion = "0.1.0-preview.1"\n', encoding="utf-8")
        (self.root / "Cargo.lock").write_text(
            '[[package]]\nname = "imposter-baker"\nversion = "0.1.0-preview.1"\n', encoding="utf-8"
        )
        for tag in ("v0.1.0-preview.2", "0.1.0-preiew.1", "vv0.1.0-Preview.1", "0.1.0"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate(self.root, tag)

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
        for tag in ("0.1.0", "v0.1.0", "Vvv0.1.0"):
            with self.subTest(tag=tag):
                packaged = release.package(self.root, tag, "linux-x86_64", output)
                self.assertEqual(packaged.name, "imposter-baker-0.1.0-linux-x86_64.zip")
                self.assertEqual(packaged.read_bytes(), first)

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
        original = result.read_bytes()
        for tag in ("0.1.0", "v0.1.0", "Vvv0.1.0"):
            with self.subTest(tag=tag):
                self.assertEqual(release.checksums(directory, tag).read_bytes(), original)

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

    def release_artifacts(self, version="0.1.0"):
        directory = self.root / "dist"
        directory.mkdir(exist_ok=True)
        names = [f"imposter-baker-{version}-{platform}.zip" for platform in release.PLATFORMS]
        names.extend(("imposter-render.zip", "imposter-render.rbxm", "demo.rbxl"))
        for name in names:
            (directory / name).write_bytes(b"release artifact")
        return directory

    @patch.object(release.subprocess, "run")
    def test_publish_updates_both_draft_and_published_releases(self, run):
        directory = self.release_artifacts()
        for state in ('{"isDraft":true}', '{"isDraft":false}'):
            with self.subTest(state=state):
                run.reset_mock()
                run.side_effect = [CompletedProcess([], 0, state, ""), CompletedProcess([], 0), CompletedProcess([], 0)]
                release.publish(self.root, "v0.1.0", directory)
                commands = [call.args[0] for call in run.call_args_list]
                self.assertEqual([command[2] for command in commands], ["view", "upload", "edit"])
                self.assertEqual(commands[1][3], "v0.1.0")
                self.assertIn("--clobber", commands[1])
                self.assertEqual(
                    set(commands[1][4:-1]),
                    {str(path.resolve()) for path in directory.iterdir()},
                )
                self.assertEqual(len(commands[1][4:-1]), 9)
                self.assertIn("--draft=false", commands[2])
                self.assertIn("--prerelease=false", commands[2])
                self.assertIn("--latest=true", commands[2])
                self.assertNotIn("--title", commands[2])
                self.assertNotIn("--notes", commands[2])

    @patch.object(release.subprocess, "run")
    def test_publish_creates_missing_release_before_publishing(self, run):
        directory = self.release_artifacts()
        run.side_effect = [CompletedProcess([], 1, "", "release not found"), CompletedProcess([], 0), CompletedProcess([], 0)]
        release.publish(self.root, "0.1.0", directory)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual([command[2] for command in commands], ["view", "create", "edit"])
        self.assertIn("--draft", commands[1])
        self.assertIn("--verify-tag", commands[1])
        self.assertIn(str((directory / "SHA256SUMS").resolve()), commands[1])

    @patch.object(release.subprocess, "run")
    def test_publish_prerelease_does_not_mark_it_latest(self, run):
        version = "0.1.0-preview.1"
        for name in ("Cargo.toml", "imposter-render/wally.toml"):
            (self.root / name).write_text(f'[package]\nversion = "{version}"\n', encoding="utf-8")
        (self.root / "Cargo.lock").write_text(
            f'[[package]]\nname = "imposter-baker"\nversion = "{version}"\n', encoding="utf-8"
        )
        run.side_effect = [CompletedProcess([], 0, '{"isDraft":false}', ""), CompletedProcess([], 0), CompletedProcess([], 0)]
        release.publish(self.root, "Vv" + version, self.release_artifacts(version))
        edit = run.call_args.args[0]
        self.assertEqual(edit[3], "Vv" + version)
        self.assertIn("--prerelease=true", edit)
        self.assertIn("--latest=false", edit)

    @patch.object(release.subprocess, "run")
    def test_publish_upload_failure_stops_before_release_edit(self, run):
        directory = self.release_artifacts()
        run.side_effect = [CompletedProcess([], 0, '{"isDraft":false}', ""), CalledProcessError(1, ["gh", "release", "upload"])]
        with self.assertRaises(CalledProcessError):
            release.publish(self.root, "v0.1.0", directory)
        self.assertEqual(run.call_count, 2)
        self.assertTrue(run.call_args.kwargs["check"])

    @patch.object(release.subprocess, "run")
    def test_publish_rejects_incomplete_artifacts_before_contacting_github(self, run):
        directory = self.root / "dist"
        directory.mkdir()
        with self.assertRaises(ValueError):
            release.publish(self.root, "v0.1.0", directory)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
