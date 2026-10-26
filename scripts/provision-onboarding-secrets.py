"""Copy missing canonical governance secrets to one enrolled repository."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

OWNER = "f5-sales-demo"
SECRETS = ("REPO_SETTINGS_TOKEN", "REPO_SYNC_TOKEN")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
SECRET_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class ProvisionError(Exception):
    """A failure whose message never contains credential or API response data."""

    INVALID_NAME = "Invalid repository name"
    INVALID_MANIFEST = "Invalid canonical enrollment manifest"
    NOT_ENROLLED = "Target must be enrolled with the canonical governance role"
    INVENTORY_FAILED = "GitHub secret inventory failed"
    INVALID_INVENTORY = "Invalid GitHub secret inventory"
    DUPLICATE_INVENTORY = "Duplicate GitHub secret inventory"
    SOURCE_UNAVAILABLE = "Canonical governance source credentials are unavailable"
    WRITE_FAILED = "GitHub secret write failed"
    WRITE_UNCONFIRMED = "Required secrets are absent after provisioning"
    CLI_UNAVAILABLE = "GitHub CLI unavailable"


def github_cli() -> str:
    """Resolve the installed CLI before transporting validated arguments."""
    executable = shutil.which("gh")
    if executable is None:
        raise ProvisionError(ProvisionError.CLI_UNAVAILABLE)
    return executable


def selected_repository(root: Path, name: str) -> str:
    """Resolve an enrolled target and the exact canonical governance role."""
    if not NAME.fullmatch(name):
        raise ProvisionError(ProvisionError.INVALID_NAME)
    try:
        config = root / ".github/config"
        inventory = json.loads((config / "downstream-repos.json").read_text())
        settings = json.loads((config / "repo-settings.json").read_text())
        manifest = settings["secrets_manifest"]
        roles = manifest["repo_roles"].get(name, manifest["repo_roles"]["_default"])
        canonical = manifest["roles"]["governance"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise ProvisionError(ProvisionError.INVALID_MANIFEST) from error
    if (
        not isinstance(inventory, list)
        or not inventory
        or any(
            not isinstance(item, str) or not NAME.fullmatch(item) for item in inventory
        )
        or len(set(inventory)) != len(inventory)
        or name not in inventory
        or not isinstance(roles, list)
        or "governance" not in roles
        or canonical != list(SECRETS)
    ):
        raise ProvisionError(ProvisionError.NOT_ENROLLED)
    return f"{OWNER}/{name}"


def inventory(repository: str) -> set[str]:
    """Read only secret names; never emit raw CLI output or errors."""
    result = subprocess.run(  # noqa: S603 - argv target is validated against enrollment.
        [github_cli(), "secret", "list", "--repo", repository, "--json", "name"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise ProvisionError(ProvisionError.INVENTORY_FAILED)
    try:
        rows = json.loads(result.stdout)
    except ValueError as error:
        raise ProvisionError(ProvisionError.INVALID_INVENTORY) from error
    if not isinstance(rows, list) or any(
        not isinstance(row, dict)
        or set(row) != {"name"}
        or not isinstance(row["name"], str)
        or not SECRET_NAME.fullmatch(row["name"])
        for row in rows
    ):
        raise ProvisionError(ProvisionError.INVALID_INVENTORY)
    names = [row["name"] for row in rows]
    if len(set(names)) != len(names):
        raise ProvisionError(ProvisionError.DUPLICATE_INVENTORY)
    return set(names)


def provision(root: Path, name: str, *, dry_run: bool) -> dict[str, object]:
    """Preview or set missing secrets; existing values remain untouched."""
    repository = selected_repository(root, name)
    values = {key: os.environ.get(key, "") for key in SECRETS}
    if not all(values.values()) or os.environ.get("GH_TOKEN") != values[SECRETS[0]]:
        raise ProvisionError(ProvisionError.SOURCE_UNAVAILABLE)
    present = inventory(repository)
    missing = [key for key in SECRETS if key not in present]
    if not dry_run:
        for key in missing:
            result = subprocess.run(  # noqa: S603 - argv target is validated against enrollment.
                [github_cli(), "secret", "set", key, "--repo", repository],
                input=values[key],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode:
                raise ProvisionError(ProvisionError.WRITE_FAILED)
        if missing and not set(SECRETS).issubset(inventory(repository)):
            raise ProvisionError(ProvisionError.WRITE_UNCONFIRMED)
    return {
        "repository": repository,
        "mode": "preview" if dry_run else "apply",
        "required_secret_names": list(SECRETS),
        "missing_before": missing,
        "written_secret_names": missing if not dry_run else [],
        "result": "READY" if dry_run else "VERIFIED",
    }


def main() -> int:
    """Run from the immutable docs-control checkout used by the workflow."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--dry-run", choices=("true", "false"), default="true")
    args = parser.parse_args()
    try:
        result = provision(
            Path(__file__).resolve().parents[1],
            args.repository,
            dry_run=args.dry_run == "true",
        )
    except (ProvisionError, OSError) as error:
        message = (
            str(error)
            if isinstance(error, ProvisionError)
            else "GitHub CLI unavailable"
        )
        print(json.dumps({"result": "FAILED", "error": message}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
