"""Publish with pinned Wally 0.3.2, whose publish command can exit 0 on HTTP errors."""

import os
import subprocess


def publish() -> None:
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
    except (RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from None
