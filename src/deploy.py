"""Deploy Fabric item content from source control into a Fabric workspace.

Infrastructure (capacity, workspace, RBAC) is owned by Terraform. This script
owns item content only: it publishes everything under ``workspace/`` into the
target workspace and removes items that no longer exist in the repository.

Identity comes from ``DefaultAzureCredential``. In GitHub Actions that resolves
to the federated workload identity established by ``azure/login@v2``; locally it
resolves to ``az login``. No client secret is read, accepted or supported.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

import yaml
from azure.identity import DefaultAzureCredential
from fabric_cicd import (
    FabricWorkspace,
    change_log_level,
    publish_all_items,
    unpublish_all_orphan_items,
)

LOGGER = logging.getLogger("fabric-deploy")

VALID_ENVIRONMENTS = ("dev", "test", "prod")

#: Item types this repository is allowed to publish. Anything found under
#: ``workspace/`` that is not listed here is ignored by fabric-cicd, which keeps
#: an accidental commit of an unsupported item type from failing the release.
DEFAULT_ITEM_TYPES = (
    "Lakehouse",
    "Environment",
    "Notebook",
    "DataPipeline",
    "SemanticModel",
    "Report",
)

#: Publish order matters: a Notebook that attaches to a Lakehouse needs the
#: Lakehouse to exist first, and a Report needs its SemanticModel. fabric-cicd
#: honours the order of ``item_type_in_scope``.
GUID_PATTERN_LENGTH = 36


class DeploymentError(RuntimeError):
    """Raised when the deployment cannot proceed safely."""


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="deploy",
        description="Publish Fabric items from this repository to a Fabric workspace.",
    )
    parser.add_argument(
        "--environment",
        default=os.environ.get("FABRIC_ENVIRONMENT"),
        help="Target environment key. Must match a key used in parameter.yml. "
        "Defaults to the FABRIC_ENVIRONMENT environment variable.",
    )
    parser.add_argument(
        "--workspace-id",
        default=os.environ.get("FABRIC_WORKSPACE_ID"),
        help="Target Fabric workspace GUID, produced by the Terraform workspace_id "
        "output. Defaults to the FABRIC_WORKSPACE_ID environment variable.",
    )
    parser.add_argument(
        "--repository-directory",
        default=os.environ.get("FABRIC_REPOSITORY_DIRECTORY", "workspace"),
        help="Directory holding the Fabric item source and parameter.yml. "
        "Default: workspace",
    )
    parser.add_argument(
        "--item-types",
        nargs="+",
        default=list(DEFAULT_ITEM_TYPES),
        help="Item types in scope, in publish order. "
        f"Default: {' '.join(DEFAULT_ITEM_TYPES)}",
    )
    parser.add_argument(
        "--item-name-exclude-regex",
        default=os.environ.get("FABRIC_ITEM_EXCLUDE_REGEX"),
        help="Optional regex of item display names to skip, e.g. '^scratch_'.",
    )
    parser.add_argument(
        "--skip-unpublish",
        action="store_true",
        help="Publish only; leave items that were deleted from the repository in "
        "place. Use for a one-off recovery, never as the standing configuration.",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Resolve credentials and validate the repository layout and "
        "parameter.yml without calling the Fabric API.",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("FABRIC_LOG_LEVEL", "INFO"),
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
        help="Logging verbosity. Default: INFO",
    )
    return parser.parse_args(argv)


def validate_inputs(args: argparse.Namespace) -> Path:
    """Fail fast on the mistakes that otherwise surface as opaque API errors."""
    if not args.environment:
        raise DeploymentError(
            "--environment (or FABRIC_ENVIRONMENT) is required. "
            f"Expected one of: {', '.join(VALID_ENVIRONMENTS)}."
        )
    if args.environment not in VALID_ENVIRONMENTS:
        raise DeploymentError(
            f"Unknown environment '{args.environment}'. "
            f"Expected one of: {', '.join(VALID_ENVIRONMENTS)}."
        )

    if not args.workspace_id:
        raise DeploymentError(
            "--workspace-id (or FABRIC_WORKSPACE_ID) is required. It must come "
            "from the Terraform workspace_id output, never a hardcoded GUID."
        )
    if len(args.workspace_id) != GUID_PATTERN_LENGTH:
        raise DeploymentError(
            f"workspace-id '{args.workspace_id}' is not a GUID. Check that the "
            "Terraform output was passed through the job outputs correctly."
        )

    repo_dir = Path(args.repository_directory).resolve()
    if not repo_dir.is_dir():
        raise DeploymentError(f"Repository directory not found: {repo_dir}")

    return repo_dir


def validate_parameter_file(repo_dir: Path, environment: str) -> None:
    """Confirm every replacement rule covers the environment being deployed.

    A missing environment key is silently treated as "no replacement" by
    fabric-cicd, which promotes dev connection strings into prod. Catch it here.
    """
    parameter_file = repo_dir / "parameter.yml"
    if not parameter_file.is_file():
        LOGGER.warning(
            "No parameter.yml in %s. Items will be published verbatim with no "
            "environment-specific substitution.",
            repo_dir,
        )
        return

    with parameter_file.open(encoding="utf-8") as handle:
        parameters = yaml.safe_load(handle) or {}

    gaps: list[str] = []
    for section in ("find_replace", "key_value_replace", "spark_pool"):
        for index, rule in enumerate(parameters.get(section) or []):
            replace_value = rule.get("replace_value") or {}
            if environment not in replace_value:
                identifier = (
                    rule.get("find_value")
                    or rule.get("find_key")
                    or rule.get("instance_pool_id")
                    or f"index {index}"
                )
                gaps.append(f"{section}[{index}] ({identifier})")

    if gaps:
        raise DeploymentError(
            f"parameter.yml has no '{environment}' value for: {', '.join(gaps)}. "
            "Add the missing keys before deploying."
        )

    LOGGER.info("parameter.yml validated for environment '%s'.", environment)


def build_workspace(args: argparse.Namespace, repo_dir: Path) -> FabricWorkspace:
    LOGGER.info(
        "Targeting workspace %s (environment=%s) from %s",
        args.workspace_id,
        args.environment,
        repo_dir,
    )
    return FabricWorkspace(
        workspace_id=args.workspace_id,
        environment=args.environment,
        repository_directory=str(repo_dir),
        item_type_in_scope=list(args.item_types),
        token_credential=DefaultAzureCredential(exclude_interactive_browser_credential=False),
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)-8s %(name)s :: %(message)s",
    )
    change_log_level(args.log_level)

    try:
        repo_dir = validate_inputs(args)
        validate_parameter_file(repo_dir, args.environment)

        if args.validate_only:
            LOGGER.info("Validation passed. --validate-only set, nothing published.")
            return 0

        workspace = build_workspace(args, repo_dir)

        publish_kwargs = {}
        if args.item_name_exclude_regex:
            publish_kwargs["item_name_exclude_regex"] = args.item_name_exclude_regex

        LOGGER.info("Publishing items...")
        publish_all_items(workspace, **publish_kwargs)

        if args.skip_unpublish:
            LOGGER.warning(
                "--skip-unpublish set. Orphaned items remain in the workspace and "
                "the workspace no longer matches the repository."
            )
        else:
            LOGGER.info("Removing orphaned items...")
            unpublish_all_orphan_items(workspace, **publish_kwargs)

        LOGGER.info("Deployment to '%s' completed.", args.environment)
        return 0

    except DeploymentError as exc:
        LOGGER.error("%s", exc)
        return 2
    except Exception:  # noqa: BLE001 - surface the full trace to the workflow log
        LOGGER.exception("Deployment failed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
