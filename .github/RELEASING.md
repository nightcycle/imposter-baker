# CI and releases

## Validation

Pull requests and branch pushes run `.github/workflows/ci.yml`. It can also be run manually, or called by the release workflow for a specific tag. Checks include:

- Rust formatting, tests, and Clippy on Windows, Linux, and macOS.
- Rust 1.90 minimum-version compatibility with the committed lockfile.
- Strict Roblox Luau analysis, formatting, pure runtime tests, Wally packaging, and a Rojo model build.
- Release-script regression tests and Actionlint validation of the workflows.

Use **CI complete** as the required branch-protection status check. It fails if any prerequisite fails, is canceled, or is skipped. Branch protection itself must be configured in the repository settings.

Successful CI uploads the checked Wally ZIP and runtime RBXM as the `checked-runtime` artifact. Manual CI runs can enable `bake_demos` to fetch public Roblox assets, verify all four model bakes, and upload `demo-bakes`. The default checks do not download model assets. The real EditableMesh/EditableImage integration test still runs in Studio; hosted runners do not provide Studio.

Dependabot checks Cargo dependencies and GitHub Actions weekly and groups their update PRs. Dependency changes still pass through CI.

## Create a release

The CLI and runtime package currently share one version. Before tagging:

1. Set the version in both `Cargo.toml` and `imposter-render/wally.toml`.
2. Run `cargo check` to refresh the CLI entry in `Cargo.lock`.
3. Run the local checks, commit the version changes, and push the commit.
4. Create and push the matching tag:

   ```sh
   git tag -a v0.1.0 -m "Release 0.1.0"
   git push origin v0.1.0
   ```

The tagged commit must contain the release workflows and scripts. You can also choose **Actions → Release → Run workflow**, entering an existing version tag. Both entry points verify the exact tag commit, run full CI against that tag, then build native binaries for:

| Platform | Architecture |
| --- | --- |
| Windows | x86_64 |
| Linux | x86_64 and ARM64 |
| macOS | Intel and ARM64 |

Each ZIP contains the executable, license, and README at the archive root. Unix executable permissions are preserved. Filenames follow `imposter-baker-<version>-<platform>-<architecture>.zip` so Rokit can select the correct executable.

The release also includes `imposter-render.zip`, `imposter-render.rbxm`, and `SHA256SUMS`. Checksums are generated only after all seven binary/package artifacts are present. The workflow first creates or resumes a draft, attaches every asset, then publishes it. Retrying can replace assets on an unfinished draft; already-published release assets are never replaced by this workflow.

Tags such as `v0.2.0-rc.1` publish GitHub prereleases and do not change the latest stable release. Set the same prerelease version in both manifests and the lockfile. Automatic Wally publication is limited to stable versions.

GitHub releases use the repository's built-in `GITHUB_TOKEN`; no personal GitHub token is required for this step. The repository must allow Actions and the workflow's `contents: write` permission. No crates.io publication is configured.

## Wally registry publication

GitHub release attachments and the Wally registry are separate distribution channels. To enable automatic registry publication after a successful stable GitHub release:

1. Authenticate locally using `wally login --project-path imposter-render` with an account that can publish `nightcycle/imposter-render`.
2. Store that account's Wally authentication token as the Actions secret **`WALLY_AUTH_TOKEN`**. Obtain it from your local Wally authentication configuration; do not commit it or paste it into workflow source.
3. Set the repository Actions variable **`PUBLISH_WALLY`** to **`true`**.

With the variable unset, GitHub releases still publish normally and contain the Wally package ZIP. To publish a stable package independently or retry a failed registry upload, run **Actions → Publish Wally package → Run workflow** and enter its existing GitHub release tag. This manual workflow needs the secret but does not require `PUBLISH_WALLY=true`.

Both paths require an existing published GitHub release and matching manifest versions. Wally package versions are immutable; do not republish an already-published version. If Wally publication fails after the GitHub release succeeds, retry the Wally workflow rather than rerunning the GitHub release job.

The pinned Wally 0.3.2 CLI may return success exit status for an HTTP failure. `scripts/publish_wally.py` additionally requires its explicit publication confirmation and masks the supplied token from captured output.

## Local release tooling

Python 3.11+ is required for these helper scripts; CI pins Python 3.12.

```sh
python -m unittest discover -s test -p test_release.py
python scripts/release.py validate v0.1.0
cargo build --locked --release --target x86_64-pc-windows-msvc
python scripts/release.py package v0.1.0 windows-x86_64
```

To generate checksums after downloading every release asset into one directory:

```sh
python scripts/release.py checksums v0.1.0 artifacts
```

The package command validates both manifests and the lockfile, uses the selected target's executable, and normalizes archive timestamps. The checksum command rejects missing or unexpected files. Running these commands locally does not publish anything.
