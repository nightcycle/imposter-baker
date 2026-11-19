"""Publish with pinned Wally 0.3.2, whose publish command can exit 0 on HTTP errors."""

import os
import base64
import json
import subprocess
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def is_published(project: Path = Path("imposter-render")) -> bool:
    package = tomllib.loads((project / "wally.toml").read_text(encoding="utf-8"))["package"]
    registry = urllib.parse.urlparse(package["registry"])
    repository = registry.path.strip("/").removesuffix(".git")
    if registry.scheme != "https" or registry.netloc != "github.com" or len(repository.split("/")) != 2:
        raise RuntimeError("The release publisher expects a GitHub-hosted Wally registry index")
    name = package["name"]
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/contents/{urllib.parse.quote(name, safe='/')}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "imposter-baker-release"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            document = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise RuntimeError(f"Cannot check Wally registry: HTTP {error.code}") from None
    entries = base64.b64decode(document["content"]).decode("utf-8").splitlines()
    version = package["version"].strip().lstrip("vV")
    for line in entries:
        if line.strip():
            published = json.loads(line)["package"]
            if published["name"] == name and published["version"].strip().lstrip("vV") == version:
                return True
    return False


def publish() -> None:
    if is_published():
        print("This Wally package version is already published; nothing to upload.")
        return
    token = os.environ.get("WALLY_AUTH_TOKEN")
    if not token:
        raise RuntimeError("Set the WALLY_AUTH_TOKEN Actions secret before publishing")
    login = subprocess.run(
        ["wally", "login", "--project-path", "imposter-render", "--token", token],
        capture_output=True, text=True, check=False,
    )
    if login.returncode != 0:
        # Do not include the login command or its arguments in an error message.
        raise RuntimeError("Wally authentication failed")
    result = subprocess.run(
        ["wally", "publish", "--project-path", "imposter-render"],
        capture_output=True, text=True, check=False,
    )
    print(result.stdout.replace(token, "[REDACTED]"), end="")
    print(result.stderr.replace(token, "[REDACTED]"), end="")
    if result.returncode != 0 or "Package published successfully!" not in result.stdout:
        raise RuntimeError("Wally did not confirm publication; inspect the registry response above")


if __name__ == "__main__":
    try:
        publish()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error)) from None
