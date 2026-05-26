#!/usr/bin/env python3
"""
Interactive wrapper that gathers all variables required by the CycleCloud
Terraform stack, writes a tfvars file under
``terraform/environments/<name>.tfvars.hcl``, then runs ``terraform init``
and ``terraform plan``.

Auth: defaults to whatever ``az login`` / ``az account set`` is currently
active. The wrapper exports the active subscription and tenant as
``ARM_SUBSCRIPTION_ID`` / ``ARM_TENANT_ID`` for the terraform child
process so the azurerm provider uses Azure CLI auth.

Usage:

    python scripts/pre-build/deploy.py                   # full interactive
    python scripts/pre-build/deploy.py --answers a.json  # answers file as defaults
    python scripts/pre-build/deploy.py --answers a.json --non-interactive
    python scripts/pre-build/deploy.py --skip-plan       # only init
    python scripts/pre-build/deploy.py --skip-terraform  # write tfvars only

Stdlib only. Tested on Python 3.9+.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
TERRAFORM_DIR = REPO_ROOT / "terraform"
ENVIRONMENTS_DIR = TERRAFORM_DIR / "environments"


# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,19}$")
ENV_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,49}$")
IPV4_RE = re.compile(r"^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$")
GUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
VNET_ID_RE = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+"
    r"/providers/Microsoft\.Network/virtualNetworks/[^/]+$"
)
LAW_ID_RE = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+"
    r"/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$"
)
CIDR_RE = re.compile(r"^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$")


def validate_application_name(v: str) -> Optional[str]:
    if v == "" or NAME_RE.match(v):
        return None
    return "Must be empty or 2-20 chars of [a-z0-9-] starting with a letter."


def validate_env_name(v: str) -> Optional[str]:
    if ENV_RE.match(v):
        return None
    return "Must be 1-50 chars of [a-z0-9._-] starting with [a-z0-9]."


def validate_cidr_list(raw: str) -> Optional[str]:
    items = [x.strip() for x in raw.split(",") if x.strip()]
    for item in items:
        if not CIDR_RE.match(item):
            return f"'{item}' is not a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
    return None if items else "At least one CIDR is required."


def validate_ip_list(raw: str) -> Optional[str]:
    if not raw.strip():
        return None
    for item in [x.strip() for x in raw.split(",") if x.strip()]:
        if not IPV4_RE.match(item):
            return f"'{item}' is not a valid IPv4 address or CIDR."
    return None


def validate_guid(v: str) -> Optional[str]:
    return None if GUID_RE.match(v) else "Must be a GUID."


def validate_vnet_id(v: str) -> Optional[str]:
    return None if VNET_ID_RE.match(v) else (
        "Must be a full /subscriptions/.../providers/Microsoft.Network"
        "/virtualNetworks/... resource ID."
    )


def validate_law_id(v: str) -> Optional[str]:
    return None if LAW_ID_RE.match(v) else (
        "Must be a full /subscriptions/.../providers/Microsoft."
        "OperationalInsights/workspaces/... resource ID."
    )


# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------


@dataclass
class Context:
    interactive: bool
    answers: dict = field(default_factory=dict)


def _path_get(d: dict, dotted: str) -> Any:
    cur: Any = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def prompt(
    ctx: Context,
    key: str,
    label: str,
    *,
    default: Any = None,
    choices: Optional[list[str]] = None,
    validator: Optional[Callable[[str], Optional[str]]] = None,
    allow_empty: bool = False,
    cast: Callable[[str], Any] = str,
) -> Any:
    """Get one value from answers file / interactive prompt."""
    preset = _path_get(ctx.answers, key)
    if preset is not None:
        if choices and preset not in choices:
            raise SystemExit(
                f"answers[{key}] = {preset!r} is not one of {choices!r}"
            )
        return preset

    if not ctx.interactive:
        if default is not None or allow_empty:
            return default
        raise SystemExit(
            f"--non-interactive set but answers file is missing required key {key!r}"
        )

    suffix = ""
    if choices:
        suffix += f" [{'/'.join(choices)}]"
    if default is not None and default != "":
        suffix += f" (default: {default})"
    elif allow_empty:
        suffix += " (optional)"

    while True:
        raw = input(f"  {label}{suffix}: ").strip()
        if raw == "":
            if default is not None:
                return default
            if allow_empty:
                return None
            print("    -> required.")
            continue
        if choices and raw not in choices:
            print(f"    -> must be one of: {', '.join(choices)}")
            continue
        if validator is not None:
            err = validator(raw)
            if err:
                print(f"    -> {err}")
                continue
        try:
            return cast(raw)
        except Exception as e:  # noqa: BLE001
            print(f"    -> invalid value: {e}")


def confirm(ctx: Context, key: str, label: str, *, default: bool = True) -> bool:
    preset = _path_get(ctx.answers, key)
    if isinstance(preset, bool):
        return preset
    if not ctx.interactive:
        return default
    suffix = "Y/n" if default else "y/N"
    while True:
        raw = input(f"  {label} [{suffix}]: ").strip().lower()
        if raw == "":
            return default
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("    -> please answer y or n.")


def section(title: str) -> None:
    print(f"\n=== {title} ===")


# ---------------------------------------------------------------------------
# Azure CLI integration
# ---------------------------------------------------------------------------


@dataclass
class AzAccount:
    subscription_id: str
    subscription_name: str
    tenant_id: str
    user_name: str


def check_az_cli() -> AzAccount:
    if shutil.which("az") is None:
        raise SystemExit(
            "Azure CLI ('az') not found on PATH. Install it and run 'az login'."
        )
    try:
        out = subprocess.check_output(
            ["az", "account", "show", "-o", "json"],
            stderr=subprocess.STDOUT,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        raise SystemExit(
            "'az account show' failed. Run 'az login' first.\n\n"
            f"{e.output.strip() if e.output else ''}"
        )
    data = json.loads(out)
    return AzAccount(
        subscription_id=data["id"],
        subscription_name=data.get("name", ""),
        tenant_id=data["tenantId"],
        user_name=(data.get("user") or {}).get("name", "<unknown>"),
    )


def check_terraform() -> str:
    tf = shutil.which("terraform")
    if tf is None:
        raise SystemExit("'terraform' not found on PATH.")
    try:
        out = subprocess.check_output([tf, "version"], text=True).splitlines()[0]
    except subprocess.CalledProcessError as e:
        raise SystemExit(f"'terraform version' failed: {e}")
    return out


# ---------------------------------------------------------------------------
# HCL emitter
# ---------------------------------------------------------------------------


def hcl_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def hcl_value(v: Any, indent: int = 0) -> str:
    pad = "  " * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if v is None:
        return "null"
    if isinstance(v, str):
        return hcl_string(v)
    if isinstance(v, list):
        if not v:
            return "[]"
        inner = ", ".join(hcl_value(x, indent) for x in v)
        return f"[{inner}]"
    if isinstance(v, dict):
        if not v:
            return "{}"
        lines = ["{"]
        for k, val in v.items():
            lines.append(f"{pad}  {k} = {hcl_value(val, indent + 1)}")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    raise TypeError(f"Cannot serialize {type(v).__name__} to HCL")


def render_tfvars(values: dict) -> str:
    """Render a tfvars.hcl file from the collected values."""
    out = [
        "# Generated by scripts/pre-build/deploy.py - safe to edit by hand.",
        "",
    ]
    # Stable, human-friendly ordering.
    order = [
        "application_name",
        "location",
        "vm_admin_username",
        "vnet_address_space",
        "allowed_ip_addresses",
        "deployment_mode",
        "access_mode",
        "hub",
        "tags",
    ]
    for key in order:
        if key not in values:
            continue
        v = values[key]
        if v is None:
            continue
        if key in ("hub", "tags") and isinstance(v, dict) and not v:
            continue
        out.append(f"{key} = {hcl_value(v)}")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------


def run_wizard(ctx: Context, az: AzAccount) -> dict:
    values: dict = {}

    section("Environment file")
    env_name = prompt(
        ctx,
        "env_name",
        "Environment name (used for the tfvars filename)",
        default="dev",
        validator=validate_env_name,
    )

    section("Naming and location")
    values["application_name"] = prompt(
        ctx,
        "application_name",
        "application_name (leading naming token; empty = random_pet)",
        default="",
        allow_empty=True,
        validator=validate_application_name,
    ) or ""
    values["location"] = prompt(
        ctx, "location", "Azure region", default="southcentralus"
    )
    values["vm_admin_username"] = prompt(
        ctx,
        "vm_admin_username",
        "CycleCloud VM admin username",
        default="cyclecloudadmin",
    )

    section("Network")
    values["vnet_address_space"] = prompt(
        ctx,
        "vnet_address_space",
        "VNet address space (comma-separated CIDRs)",
        default="10.150.0.0/16",
        validator=validate_cidr_list,
        cast=lambda s: [x.strip() for x in s.split(",") if x.strip()],
    )

    section("Topology")
    values["deployment_mode"] = prompt(
        ctx,
        "deployment_mode",
        "deployment_mode",
        default="standalone",
        choices=["standalone", "spoke"],
    )

    is_spoke = values["deployment_mode"] == "spoke"

    section("Access mode")
    access_choices = ["public_ip", "bastion", "private_ip"]
    access_default = "private_ip" if is_spoke else "public_ip"
    while True:
        am = prompt(
            ctx,
            "access_mode",
            "access_mode",
            default=access_default,
            choices=access_choices,
        )
        if am == "private_ip" and not is_spoke:
            print(
                "    -> access_mode = 'private_ip' requires deployment_mode = 'spoke'."
            )
            if not ctx.interactive:
                raise SystemExit(2)
            # let user re-pick
            ctx.answers.pop("access_mode", None)
            continue
        values["access_mode"] = am
        break

    if values["access_mode"] == "public_ip":
        section("Operator IP allow-list")
        print(
            "  In public_ip mode the operator IP is auto-detected via ipify\n"
            "  and merged into the allow-list. You only need to add extra\n"
            "  teammate IPs / CIDRs here. Comma-separated, leave empty for none."
        )
        extra = prompt(
            ctx,
            "allowed_ip_addresses",
            "allowed_ip_addresses",
            default="",
            allow_empty=True,
            validator=validate_ip_list,
            cast=lambda s: [x.strip() for x in s.split(",") if x.strip()],
        )
        if extra:
            values["allowed_ip_addresses"] = extra

    if is_spoke:
        section("Hub (landing zone)")
        hub: dict = {}
        hub["subscription_id"] = prompt(
            ctx,
            "hub.subscription_id",
            "Hub subscription ID (GUID)",
            validator=validate_guid,
        )
        tenant = prompt(
            ctx,
            "hub.tenant_id",
            "Hub tenant ID (only if hub is in a different tenant)",
            default="",
            allow_empty=True,
            validator=lambda v: None if v == "" else validate_guid(v),
        )
        if tenant:
            hub["tenant_id"] = tenant

        vnet: dict = {}
        vnet["id"] = prompt(
            ctx,
            "hub.virtual_network.id",
            "Hub VNet resource ID",
            validator=validate_vnet_id,
        )
        vnet["allow_forwarded_traffic"] = confirm(
            ctx,
            "hub.virtual_network.allow_forwarded_traffic",
            "Allow forwarded traffic on peering?",
            default=True,
        )
        vnet["use_remote_gateways"] = confirm(
            ctx,
            "hub.virtual_network.use_remote_gateways",
            "Use hub remote gateways (ExpressRoute / VPN)?",
            default=False,
        )
        vnet["create_reverse_peering"] = confirm(
            ctx,
            "hub.virtual_network.create_reverse_peering",
            "Create hub->spoke peering from this stack (needs RBAC on hub VNet)?",
            default=True,
        )
        hub["virtual_network"] = vnet

        hub["monitoring"] = {
            "log_analytics_workspace_id": prompt(
                ctx,
                "hub.monitoring.log_analytics_workspace_id",
                "Hub Log Analytics workspace resource ID",
                validator=validate_law_id,
            )
        }
        values["hub"] = hub

    section("Tags")
    tags_preset = _path_get(ctx.answers, "tags")
    if isinstance(tags_preset, dict):
        values["tags"] = tags_preset
    elif ctx.interactive and confirm(
        ctx, "_override_tags", "Override default tag map?", default=False
    ):
        print("  Enter tags as comma-separated key=value pairs (e.g. owner=alice,env=dev):")
        raw = input("    tags: ").strip()
        tags = {}
        for pair in [p for p in raw.split(",") if p.strip()]:
            if "=" not in pair:
                print(f"    -> ignoring malformed pair: {pair}")
                continue
            k, v = pair.split("=", 1)
            tags[k.strip()] = v.strip()
        if tags:
            values["tags"] = tags

    return env_name, values


# ---------------------------------------------------------------------------
# Terraform driver
# ---------------------------------------------------------------------------


def write_tfvars(env_name: str, values: dict) -> Path:
    ENVIRONMENTS_DIR.mkdir(parents=True, exist_ok=True)
    target = ENVIRONMENTS_DIR / f"{env_name}.tfvars.hcl"
    target.write_text(render_tfvars(values))
    return target


def run_terraform(args: list[str], env: dict, *, label: str) -> None:
    print(f"\n$ terraform {' '.join(args)}")
    result = subprocess.run(
        ["terraform", *args],
        cwd=str(TERRAFORM_DIR),
        env=env,
    )
    if result.returncode != 0:
        raise SystemExit(f"terraform {label} failed (exit {result.returncode}).")


def build_tf_env(az: AzAccount) -> dict:
    env = os.environ.copy()
    env["ARM_SUBSCRIPTION_ID"] = az.subscription_id
    env["ARM_TENANT_ID"] = az.tenant_id
    env.setdefault("ARM_USE_CLI", "true")
    return env


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[1] if __doc__ else None,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--answers",
        type=Path,
        help="JSON file with pre-filled answers (overrides interactive defaults).",
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Fail if any required value is missing from the answers file.",
    )
    parser.add_argument(
        "--skip-az-check",
        action="store_true",
        help="Skip the 'az account show' check (useful for offline dry runs).",
    )
    parser.add_argument(
        "--skip-terraform",
        action="store_true",
        help="Only write the tfvars file; do not invoke terraform.",
    )
    parser.add_argument(
        "--skip-plan",
        action="store_true",
        help="Run 'terraform init' but skip 'terraform plan'.",
    )
    parser.add_argument(
        "--out-plan",
        default=None,
        help="Path (relative to terraform/) to write the plan file. "
        "Default: <env_name>.tfplan",
    )
    args = parser.parse_args(argv)

    print("CycleCloud Terraform pre-build wizard")
    print("-" * 40)

    if args.answers:
        if not args.answers.is_file():
            raise SystemExit(f"answers file not found: {args.answers}")
        answers = json.loads(args.answers.read_text())
        if not isinstance(answers, dict):
            raise SystemExit("answers file must contain a JSON object at the top level.")
    else:
        answers = {}

    ctx = Context(interactive=not args.non_interactive, answers=answers)

    if args.skip_az_check:
        az = AzAccount(
            subscription_id=os.environ.get("ARM_SUBSCRIPTION_ID", ""),
            subscription_name="(skipped)",
            tenant_id=os.environ.get("ARM_TENANT_ID", ""),
            user_name="(skipped)",
        )
        print("Skipping az CLI check (--skip-az-check).")
    else:
        az = check_az_cli()
        print(f"Azure CLI signed in as : {az.user_name}")
        print(f"  subscription         : {az.subscription_name} ({az.subscription_id})")
        print(f"  tenant               : {az.tenant_id}")
        if ctx.interactive and not confirm(
            ctx, "_confirm_subscription",
            "Use this subscription for the deployment?",
            default=True,
        ):
            raise SystemExit(
                "Aborted. Run 'az account set --subscription <id>' and re-run."
            )

    if not args.skip_terraform:
        print(f"Terraform              : {check_terraform()}")

    env_name, values = run_wizard(ctx, az)

    target = write_tfvars(env_name, values)
    print(f"\nWrote {target.relative_to(REPO_ROOT)}")

    if args.skip_terraform:
        print("\n--skip-terraform: not running init/plan. Done.")
        return 0

    tf_env = build_tf_env(az)
    run_terraform(["init", "-input=false"], tf_env, label="init")

    if args.skip_plan:
        print("\n--skip-plan: stopping after init.")
        return 0

    out_plan = args.out_plan or f"{env_name}.tfplan"
    rel_tfvars = os.path.relpath(target, TERRAFORM_DIR)
    run_terraform(
        [
            "plan",
            "-input=false",
            f"-var-file={rel_tfvars}",
            f"-out={out_plan}",
        ],
        tf_env,
        label="plan",
    )

    print(
        "\nDone. To apply, review the plan and then run:\n"
        f"  cd terraform && terraform apply '{out_plan}'\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
