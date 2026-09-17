#!/usr/bin/env python3
"""
Generic run-contract utility for CI/CD pipelines.

Writes a single `_run_contract.json` per output folder (or per run).
Pipeline-agnostic — works from local shells, Cloud Build, VMs, and Cloud Run.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from string import Template
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Tuple

SCHEMA_VERSION = 1


def _utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _safe_slug(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value)).strip("._-")
    return slug or "run"


def _atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def _atomic_write_json(path: Path, payload: Any) -> None:
    _atomic_write_text(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _load_json_file(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _command_exists(cmd: str) -> bool:
    return subprocess.run(["bash", "-lc", f"command -v {cmd}"], capture_output=True).returncode == 0


def _normalize_local_path(path: str) -> str:
    try:
        return str(Path(path).expanduser().resolve())
    except Exception:
        return str(Path(path).expanduser())


def _normalize_gs_uri(uri: str) -> str:
    value = str(uri).strip()
    if not value.startswith("gs://"):
        return value
    prefix, _, rest = value.partition("gs://")
    del prefix
    while "//" in rest:
        rest = rest.replace("//", "/")
    return "gs://" + rest.rstrip("/")


def _infer_runtime_kind() -> str:
    if os.getenv("K_SERVICE") or os.getenv("CLOUD_RUN_JOB"):
        return "cloud_run"
    if os.getenv("BUILD_ID") and os.getenv("PROJECT_ID"):
        return "cloud_build"
    if os.getenv("VM_NAME"):
        return "vm"
    return "local"


def _runtime_metadata() -> Dict[str, Any]:
    kind = _infer_runtime_kind()
    meta: Dict[str, Any] = {
        "runtime": kind,
        "project_id": os.getenv("PROJECT_ID"),
        "build_id": os.getenv("BUILD_ID"),
        # Prefer a REAL commit hash; skip image-tag sentinels (SHORT_SHA is often "latest"/"local").
        "commit_sha": next(
            (v for v in (os.getenv("COMMIT_SHA"), os.getenv("GIT_COMMIT"), os.getenv("SHORT_SHA"))
             if v and v not in ("latest", "local", "unknown", "__GIT_COMMIT__")),
            None,
        ),
        "vm_name": os.getenv("VM_NAME"),
        "vm_zone": os.getenv("VM_ZONE"),
        "cloudbuild_yaml": os.getenv("CLOUDBUILD_YAML"),
    }

    if kind == "cloud_run":
        meta.update(
            {
                "service": os.getenv("K_SERVICE"),
                "revision": os.getenv("K_REVISION"),
                "configuration": os.getenv("K_CONFIGURATION"),
                "cloud_run_job": os.getenv("CLOUD_RUN_JOB"),
                "cloud_run_execution": os.getenv("CLOUD_RUN_EXECUTION"),
                "cloud_run_task_index": os.getenv("CLOUD_RUN_TASK_INDEX"),
            }
        )
    return meta


def _default_run_id(job_id: str) -> str:
    candidates = [
        os.getenv("RUN_CONTRACT_RUN_ID", "").strip(),
        os.getenv("SDM_RUN_ID", "").strip(),
        os.getenv("BUILD_ID", "").strip(),
        os.getenv("CLOUD_RUN_EXECUTION", "").strip(),
    ]
    for candidate in candidates:
        if candidate:
            return _safe_slug(candidate)

    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    digest = hashlib.sha1(job_id.encode("utf-8")).hexdigest()[:8]
    return f"{ts}_{digest}"


def _parse_bool(raw: str | None, default: bool = False) -> bool:
    if raw is None:
        return bool(default)
    value = str(raw).strip().lower()
    if value in {"1", "true", "yes", "y", "on"}:
        return True
    if value in {"0", "false", "no", "n", "off"}:
        return False
    return bool(default)


def _parse_vars(pairs: Iterable[str]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            raise ValueError(f"Invalid --var value {pair!r}; expected KEY=VALUE")
        key, value = pair.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"Invalid --var value {pair!r}; empty key")
        out[key] = value
    return out


def _to_string_context(source: Mapping[str, Any]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for key, value in source.items():
        if value is None:
            continue
        out[str(key)] = str(value)
    return out


def _apply_templates(value: Any, context: Mapping[str, str]) -> Any:
    if isinstance(value, str):
        rendered = Template(value).safe_substitute(context)
        # Also support {VAR} style placeholders for convenience.
        for key, ctx_value in context.items():
            rendered = rendered.replace("{" + key + "}", str(ctx_value))
        return rendered
    if isinstance(value, list):
        return [_apply_templates(v, context) for v in value]
    if isinstance(value, tuple):
        return tuple(_apply_templates(v, context) for v in value)
    if isinstance(value, dict):
        return {k: _apply_templates(v, context) for k, v in value.items()}
    return value


def _load_job_definition(spec_path: Path | None, job_id: str) -> Tuple[Dict[str, Any], str]:
    if spec_path is None:
        return ({"job_id": job_id, "tasks": []}, job_id)

    root = _load_json_file(spec_path)
    if not isinstance(root, dict):
        raise ValueError(f"Spec file must be a JSON object: {spec_path}")

    resolved_job_id = job_id
    if "jobs" in root:
        jobs = root.get("jobs")
        if not isinstance(jobs, dict):
            raise ValueError(f"Spec key 'jobs' must be an object: {spec_path}")
        if resolved_job_id in jobs:
            job_def = jobs[resolved_job_id]
        elif not resolved_job_id and len(jobs) == 1:
            resolved_job_id = next(iter(jobs.keys()))
            job_def = jobs[resolved_job_id]
        else:
            available = ", ".join(sorted(jobs.keys()))
            raise ValueError(
                f"Job id {resolved_job_id!r} not found in {spec_path}. Available jobs: [{available}]"
            )
    else:
        job_def = root
        if not resolved_job_id:
            resolved_job_id = str(job_def.get("job_id") or job_def.get("name") or "job")

    if not isinstance(job_def, dict):
        raise ValueError(f"Resolved job definition must be an object: {spec_path}")

    return dict(job_def), str(resolved_job_id)


def _normalize_tasks_and_assets(
    *,
    job_id: str,
    run_id: str,
    now_iso: str,
    job_def: Mapping[str, Any],
    expected_assets_override: List[Mapping[str, Any]] | None,
    expected_inputs_override: List[Mapping[str, Any]] | None = None,
    context: Mapping[str, str],
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    tasks_raw = list(job_def.get("tasks") or [])

    if expected_assets_override is not None or expected_inputs_override is not None:
        tasks_raw = [
            {
                "task_id": str(job_def.get("default_task_id") or job_id),
                "labels": dict(job_def.get("default_labels") or {}),
                "expected_assets": list(expected_assets_override or job_def.get("expected_assets") or []),
                "expected_inputs": list(expected_inputs_override or job_def.get("expected_inputs") or []),
            }
        ]

    if not tasks_raw:
        if job_def.get("expected_assets") or job_def.get("expected_inputs"):
            tasks_raw = [
                {
                    "task_id": str(job_def.get("default_task_id") or job_id),
                    "labels": dict(job_def.get("default_labels") or {}),
                    "expected_assets": list(job_def.get("expected_assets") or []),
                    "expected_inputs": list(job_def.get("expected_inputs") or []),
                }
            ]
        else:
            tasks_raw = [
                {
                    "task_id": str(job_def.get("default_task_id") or job_id),
                    "labels": dict(job_def.get("default_labels") or {}),
                    "expected_assets": [],
                    "expected_inputs": [],
                }
            ]

    tasks: List[Dict[str, Any]] = []
    assets: List[Dict[str, Any]] = []
    seen_tasks: set[str] = set()
    seen_assets: set[str] = set()

    for task_index, task_raw in enumerate(tasks_raw, start=1):
        if not isinstance(task_raw, dict):
            raise ValueError(f"Task definition #{task_index} must be an object")

        task_id_raw = task_raw.get("task_id") or f"{job_id}/task_{task_index}"
        task_id = str(_apply_templates(str(task_id_raw), context))
        if not task_id:
            raise ValueError(f"Task definition #{task_index} resolved to empty task_id")
        if task_id in seen_tasks:
            raise ValueError(f"Duplicate task_id in contract definition: {task_id}")
        seen_tasks.add(task_id)

        labels = _apply_templates(dict(task_raw.get("labels") or {}), context)
        task_record = {
            "task_id": task_id,
            "labels": labels,
            "status": "expected",
            "created_at": now_iso,
            "started_at": None,
            "finished_at": None,
            "error": None,
            "asset_ids": [],
        }
        tasks.append(task_record)

        # Build combined list: (asset_raw, role) for outputs and inputs
        role_tagged: List[Tuple[Mapping[str, Any], str]] = []
        for a in list(task_raw.get("expected_assets") or []):
            role_tagged.append((a, "output"))
        for a in list(task_raw.get("expected_inputs") or []):
            role_tagged.append((a, "input"))

        for asset_index, (asset_raw, role) in enumerate(role_tagged, start=1):
            if not isinstance(asset_raw, dict):
                raise ValueError(
                    f"Expected {role} asset #{asset_index} in task {task_id!r} must be an object"
                )

            default_suffix = "asset" if role == "output" else "input"
            asset_id_raw = asset_raw.get("asset_id") or f"{task_id}/{default_suffix}_{asset_index}"
            asset_id = str(_apply_templates(str(asset_id_raw), context))
            if asset_id in seen_assets:
                raise ValueError(f"Duplicate asset_id in contract definition: {asset_id}")
            seen_assets.add(asset_id)

            uri = asset_raw.get("uri")
            local_path = asset_raw.get("local_path")
            local_glob = asset_raw.get("local_glob")
            gcs_glob = asset_raw.get("gcs_glob")

            asset_record = {
                "asset_id": asset_id,
                "task_id": task_id,
                "role": role,
                "kind": str(asset_raw.get("kind") or "output"),
                "required": bool(asset_raw.get("required", True)),
                "uri": _apply_templates(uri, context) if uri is not None else None,
                "local_path": _apply_templates(local_path, context)
                if local_path is not None
                else None,
                "local_glob": _apply_templates(local_glob, context)
                if local_glob is not None
                else None,
                "gcs_glob": _apply_templates(gcs_glob, context) if gcs_glob is not None else None,
                "extra": _apply_templates(dict(asset_raw.get("extra") or {}), context),
                "expected": True,
                "produced": False,
                "status": "expected",
                "created_at": now_iso,
                "exists": None,
                "exists_reason": None,
                "corrupt": None,
                "corrupt_reason": None,
                "error": None,
            }
            task_record["asset_ids"].append(asset_id)
            assets.append(asset_record)

    tasks.sort(key=lambda rec: str(rec["task_id"]))
    assets.sort(key=lambda rec: str(rec["asset_id"]))

    return tasks, assets


def _new_contract(
    *,
    contract_file: Path,
    run_dir: Path,
    job_id: str,
    run_id: str,
    pipeline_title: str | None,
    output_location: str | None,
    runtime_meta: Mapping[str, Any],
    config_json: Any,
    inputs_json: Any,
    run_metadata_json: Any,
    tasks: List[Dict[str, Any]],
    assets: List[Dict[str, Any]],
    spec_file: Path | None,
) -> Dict[str, Any]:
    now_iso = _utc_now_iso()

    run_meta: Dict[str, Any] = {
        "run_id": run_id,
        "job_id": job_id,
        "pipeline_title": pipeline_title or job_id,
        "status": "STARTED",
        "started_at": now_iso,
        "completed_at": None,
        "runtime": dict(runtime_meta),
        "output_location": output_location,
    }

    if run_metadata_json is not None:
        if not isinstance(run_metadata_json, dict):
            raise ValueError("--run-metadata-json must be a JSON object")
        run_meta["extra"] = run_metadata_json

    contract: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "run": run_meta,
        "configuration": config_json if config_json is not None else {},
        "input_data": inputs_json if inputs_json is not None else {},
        "tasks": tasks,
        "assets": assets,
        "verification": {},
        "paths": {
            "run_dir": str(run_dir),
            "contract_json": str(contract_file),
            "spec_file": str(spec_file) if spec_file else None,
        },
    }

    return contract


def _load_contract(contract_file: Path) -> Dict[str, Any]:
    data = _load_json_file(contract_file)
    if not isinstance(data, dict):
        raise ValueError(f"Contract must be a JSON object: {contract_file}")

    data.setdefault("tasks", [])
    data.setdefault("assets", [])
    data.setdefault("verification", {})
    data.setdefault("paths", {})
    data.setdefault("run", {})

    if not isinstance(data["tasks"], list):
        raise ValueError("Contract key 'tasks' must be a list")
    if not isinstance(data["assets"], list):
        raise ValueError("Contract key 'assets' must be a list")

    # Backward compat: ensure every asset has a role field
    for asset in data["assets"]:
        asset.setdefault("role", "output")

    return data


def _task_index(contract: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {str(task.get("task_id")): task for task in contract.get("tasks", [])}


def _asset_index(contract: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {str(asset.get("asset_id")): asset for asset in contract.get("assets", [])}


def _write_contract(contract: Mapping[str, Any]) -> None:
    """Write _run_contract.json to disk."""
    paths = contract.get("paths", {})
    contract_json = Path(str(paths.get("contract_json") or "_run_contract.json"))
    _atomic_write_json(contract_json, contract)


def _ensure_task(contract: MutableMapping[str, Any], task_id: str) -> Dict[str, Any]:
    tasks = contract.setdefault("tasks", [])
    assert isinstance(tasks, list)
    for task in tasks:
        if str(task.get("task_id")) == task_id:
            return task

    now_iso = _utc_now_iso()
    task = {
        "task_id": task_id,
        "labels": {},
        "status": "running",
        "created_at": now_iso,
        "started_at": now_iso,
        "finished_at": None,
        "error": None,
        "asset_ids": [],
    }
    tasks.append(task)
    return task


def _ensure_asset(contract: MutableMapping[str, Any], asset_id: str, task_id: str) -> Dict[str, Any]:
    assets = contract.setdefault("assets", [])
    assert isinstance(assets, list)
    for asset in assets:
        if str(asset.get("asset_id")) == asset_id:
            return asset

    now_iso = _utc_now_iso()
    asset = {
        "asset_id": asset_id,
        "task_id": task_id,
        "role": "output",
        "kind": "output",
        "required": True,
        "uri": None,
        "local_path": None,
        "local_glob": None,
        "gcs_glob": None,
        "extra": {},
        "expected": False,
        "produced": True,
        "status": "produced",
        "created_at": now_iso,
        "exists": None,
        "exists_reason": None,
        "corrupt": None,
        "corrupt_reason": None,
        "error": None,
    }
    assets.append(asset)
    return asset


def _set_task_status(
    contract: MutableMapping[str, Any],
    *,
    task_id: str,
    status: str,
    error: Mapping[str, Any] | None = None,
) -> None:
    task = _ensure_task(contract, task_id)
    now_iso = _utc_now_iso()
    if status == "running" and not task.get("started_at"):
        task["started_at"] = now_iso
    if status in {"succeeded", "failed", "succeeded_with_missing_outputs", "succeeded_with_corrupt_outputs", "succeeded_with_unverified_outputs"}:
        task["finished_at"] = now_iso
    task["status"] = status
    if error is not None:
        task["error"] = dict(error)

    if status == "failed":
        asset_ids = list(task.get("asset_ids") or [])
        assets = _asset_index(contract)
        for aid in asset_ids:
            asset = assets.get(str(aid))
            if asset is None:
                continue
            asset["status"] = "failed"
            if error is not None:
                asset["error"] = dict(error)


def _gsutil_ls(pattern: str) -> Tuple[List[str] | None, str]:
    if not _command_exists("gsutil"):
        return (None, "gsutil_unavailable")

    cmd = ["gsutil", "ls", "-r", pattern]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip().replace("\n", " ")
        if "matched no objects" in stderr.lower():
            return ([], "gcs_glob")
        return (None, f"gsutil_ls_failed:{stderr or proc.returncode}")

    out: List[str] = []
    for line in (proc.stdout or "").splitlines():
        item = line.strip()
        if not item or not item.startswith("gs://"):
            continue
        if item.endswith("/"):
            continue
        out.append(_normalize_gs_uri(item))

    return (sorted(set(out)), "gcs_glob")


def _gsutil_exists(uri: str) -> Tuple[bool | None, str]:
    if not _command_exists("gsutil"):
        return (None, "gsutil_unavailable")

    proc = subprocess.run(["gsutil", "-q", "stat", uri], capture_output=True, text=True)
    if proc.returncode == 0:
        return (True, "gcs_uri")
    return (False, "gcs_uri")


def _asset_exists(asset: Mapping[str, Any]) -> Tuple[bool | None, str, List[str]]:
    local_path = asset.get("local_path")
    uri = asset.get("uri")
    local_glob = asset.get("local_glob")
    gcs_glob = asset.get("gcs_glob")

    if local_path:
        resolved = _normalize_local_path(str(local_path))
        exists = Path(resolved).exists()
        return (exists, "local_path", [resolved] if exists else [])

    if uri and str(uri).startswith("gs://"):
        normalized_uri = _normalize_gs_uri(str(uri))
        exists, reason = _gsutil_exists(normalized_uri)
        return (exists, reason, [normalized_uri] if exists else [])

    if local_glob:
        matches = sorted(
            {
                _normalize_local_path(path)
                for path in glob.glob(str(local_glob), recursive=True)
                if Path(path).is_file()
            }
        )
        return (bool(matches), "local_glob", matches)

    if gcs_glob:
        matches, reason = _gsutil_ls(str(gcs_glob))
        if matches is None:
            return (None, reason, [])
        return (bool(matches), reason, matches)

    return (None, "no_location", [])


def _read_json_from_asset(asset: Mapping[str, Any], *, max_bytes: int = 2_000_000) -> Dict[str, Any] | None:
    local_path = asset.get("local_path")
    uri = asset.get("uri")

    if local_path:
        path = Path(str(local_path))
        if not path.exists() or not path.is_file():
            return None
        try:
            if path.stat().st_size > max_bytes:
                return None
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return None

    if uri and str(uri).startswith("gs://"):
        if not _command_exists("gsutil"):
            return None
        proc = subprocess.run(["gsutil", "cat", str(uri)], capture_output=True)
        if proc.returncode != 0:
            return None
        data = proc.stdout or b""
        if len(data) > max_bytes:
            return None
        try:
            return json.loads(data.decode("utf-8", errors="replace"))
        except Exception:
            return None

    return None


def _scan_local_files(paths: Iterable[str]) -> List[str]:
    out: set[str] = set()
    for raw in paths:
        if not raw:
            continue
        root = Path(str(raw)).expanduser()
        if not root.exists():
            continue
        if root.is_file():
            out.add(_normalize_local_path(str(root)))
            continue
        for file_path in root.rglob("*"):
            if file_path.is_file():
                out.add(_normalize_local_path(str(file_path)))
    return sorted(out)


def _scan_gcs_files(prefixes: Iterable[str]) -> List[str]:
    out: set[str] = set()
    if not prefixes:
        return []
    if not _command_exists("gsutil"):
        return []

    for raw in prefixes:
        if not raw:
            continue
        prefix = _normalize_gs_uri(str(raw))
        pattern = prefix if any(ch in prefix for ch in ["*", "?", "[", "]"]) else prefix.rstrip("/") + "/**"
        found, _reason = _gsutil_ls(pattern)
        if found is None:
            continue
        for item in found:
            out.add(_normalize_gs_uri(item))
    return sorted(out)


def _upload_contract_to_gcs(local_path: Path, gcs_dest: str) -> Tuple[bool, str | None]:
    """Upload a single _run_contract.json to a GCS path."""
    if not gcs_dest.startswith("gs://"):
        return (False, "gcs_dest must start with gs://")
    if not _command_exists("gsutil"):
        return (False, "gsutil not available")
    proc = subprocess.run(
        ["gsutil", "cp", str(local_path), gcs_dest],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip().replace("\n", " ")
        return (False, f"failed upload to {gcs_dest}: {stderr or proc.returncode}")
    return (True, None)


def _gcs_folder(asset: Mapping[str, Any]) -> str | None:
    """Extract the GCS folder from an asset's uri or gcs_glob. Returns None if no GCS location."""
    uri = asset.get("uri")
    if uri and str(uri).startswith("gs://"):
        normalized = _normalize_gs_uri(str(uri))
        idx = normalized.rfind("/")
        return normalized[:idx] if idx > len("gs://") else None

    gcs_glob = asset.get("gcs_glob")
    if gcs_glob and str(gcs_glob).startswith("gs://"):
        normalized = _normalize_gs_uri(str(gcs_glob))
        parts = normalized.split("/")
        folder_parts: list[str] = []
        for part in parts:
            if any(ch in part for ch in ["*", "?", "[", "]"]):
                break
            folder_parts.append(part)
        if len(folder_parts) > 2:
            return "/".join(folder_parts).rstrip("/")

    return None


def _group_assets_by_folder(assets: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """Group assets by their GCS folder. Assets without a GCS location are excluded."""
    groups: Dict[str, List[Dict[str, Any]]] = {}
    for asset in assets:
        folder = _gcs_folder(asset)
        if folder is not None:
            groups.setdefault(folder, []).append(asset)
    return groups


def _build_folder_contract(
    full_contract: Mapping[str, Any],
    folder_uri: str,
    folder_assets: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Build a filtered contract scoped to a single GCS folder."""
    folder_asset_ids = {str(a.get("asset_id") or "") for a in folder_assets}
    relevant_task_ids = {str(a.get("task_id") or "") for a in folder_assets}

    filtered_tasks: List[Dict[str, Any]] = []
    for task in full_contract.get("tasks", []):
        if str(task.get("task_id") or "") not in relevant_task_ids:
            continue
        task_copy = dict(task)
        task_copy["asset_ids"] = sorted(
            aid for aid in (task.get("asset_ids") or []) if str(aid) in folder_asset_ids
        )
        filtered_tasks.append(task_copy)

    asset_status_counts: Dict[str, int] = {}
    for asset in folder_assets:
        st = str(asset.get("status") or "unknown")
        asset_status_counts[st] = asset_status_counts.get(st, 0) + 1

    task_status_counts: Dict[str, int] = {}
    for task in filtered_tasks:
        st = str(task.get("status") or "unknown")
        task_status_counts[st] = task_status_counts.get(st, 0) + 1

    return {
        "schema_version": full_contract.get("schema_version", SCHEMA_VERSION),
        "run": dict(full_contract.get("run", {})),
        "configuration": dict(full_contract.get("configuration", {})),
        "input_data": dict(full_contract.get("input_data", {})),
        "tasks": filtered_tasks,
        "assets": list(folder_assets),
        "verification": {
            "finished_at": full_contract.get("verification", {}).get("finished_at"),
            "asset_status_counts": asset_status_counts,
            "task_status_counts": task_status_counts,
            "scope": "folder",
            "folder_uri": folder_uri,
        },
        "paths": {"scope": "folder", "folder_uri": folder_uri},
    }


def _cmd_init(args: argparse.Namespace) -> int:
    runtime_meta = _runtime_metadata()
    job_id = str(args.job_id or os.getenv("RUN_CONTRACT_JOB_ID", "")).strip()
    if not job_id:
        raise ValueError("--job-id is required (or set RUN_CONTRACT_JOB_ID)")

    run_id = str(args.run_id or "").strip() or _default_run_id(job_id)
    run_id = _safe_slug(run_id)
    job_slug = _safe_slug(job_id)

    run_dir = Path(args.run_dir) if args.run_dir else Path("run_contracts") / job_slug / run_id
    run_dir = run_dir.expanduser().resolve()
    contract_file = (
        Path(args.contract_file).expanduser().resolve()
        if args.contract_file
        else run_dir / "_run_contract.json"
    )

    spec_file = Path(args.spec_file).expanduser().resolve() if args.spec_file else None
    expected_assets_override: List[Mapping[str, Any]] | None = None
    expected_inputs_override: List[Mapping[str, Any]] | None = None

    if args.expected_assets_file:
        expected_assets_override = _load_json_file(Path(args.expected_assets_file).expanduser())
        if not isinstance(expected_assets_override, list):
            raise ValueError("--expected-assets-file must be a JSON array")

    if args.expected_inputs_file:
        expected_inputs_override = _load_json_file(Path(args.expected_inputs_file).expanduser())
        if not isinstance(expected_inputs_override, list):
            raise ValueError("--expected-inputs-file must be a JSON array")

    vars_map: Dict[str, Any] = {}
    vars_map.update(runtime_meta)
    vars_map.update(
        {
            "job_id": job_id,
            "JOB_ID": job_id,
            "run_id": run_id,
            "RUN_ID": run_id,
            "run_dir": str(run_dir),
            "RUN_DIR": str(run_dir),
            "contract_file": str(contract_file),
            "CONTRACT_FILE": str(contract_file),
            "output_location": args.output_location or "",
            "OUTPUT_LOCATION": args.output_location or "",
        }
    )

    if args.vars_file:
        vars_from_file = _load_json_file(Path(args.vars_file).expanduser())
        if not isinstance(vars_from_file, dict):
            raise ValueError("--vars-file must be a JSON object")
        vars_map.update(vars_from_file)

    vars_map.update(_parse_vars(args.var or []))

    template_ctx = _to_string_context(vars_map)

    job_def, resolved_job_id = _load_job_definition(spec_file, job_id)
    if resolved_job_id != job_id:
        job_id = resolved_job_id

    now_iso = _utc_now_iso()
    tasks, assets = _normalize_tasks_and_assets(
        job_id=job_id,
        run_id=run_id,
        now_iso=now_iso,
        job_def=job_def,
        expected_assets_override=expected_assets_override,
        expected_inputs_override=expected_inputs_override,
        context=template_ctx,
    )

    # --init-json-file: single file with all init data (preferred)
    # Keys: config, inputs, expected_assets, run_metadata
    # Individual --*-json-file flags override keys from --init-json-file.
    _init_bundle: Dict[str, Any] = {}
    if getattr(args, "init_json_file", None):
        _init_bundle = _load_json_file(Path(args.init_json_file).expanduser())
        if not isinstance(_init_bundle, dict):
            raise ValueError("--init-json-file must be a JSON object")
        # Apply expected_assets/expected_inputs from bundle if not already set
        if expected_assets_override is None and "expected_assets" in _init_bundle:
            ea = _init_bundle["expected_assets"]
            if not isinstance(ea, list):
                raise ValueError("init-json-file 'expected_assets' must be a JSON array")
            expected_assets_override = ea
            # Re-normalize tasks/assets with the override
            tasks, assets = _normalize_tasks_and_assets(
                job_id=job_id, run_id=run_id, now_iso=now_iso,
                job_def=job_def, expected_assets_override=expected_assets_override,
                expected_inputs_override=expected_inputs_override, context=template_ctx,
            )
        if expected_inputs_override is None and "expected_inputs" in _init_bundle:
            ei = _init_bundle["expected_inputs"]
            if not isinstance(ei, list):
                raise ValueError("init-json-file 'expected_inputs' must be a JSON array")
            expected_inputs_override = ei
            tasks, assets = _normalize_tasks_and_assets(
                job_id=job_id, run_id=run_id, now_iso=now_iso,
                job_def=job_def, expected_assets_override=expected_assets_override,
                expected_inputs_override=expected_inputs_override, context=template_ctx,
            )

    config_json = _load_json_file(Path(args.config_json_file).expanduser()) if args.config_json_file else _init_bundle.get("config", {})
    inputs_json = _load_json_file(Path(args.inputs_json_file).expanduser()) if args.inputs_json_file else _init_bundle.get("inputs", {})
    run_metadata_json = _load_json_file(Path(args.run_metadata_json_file).expanduser()) if args.run_metadata_json_file else _init_bundle.get("run_metadata")

    contract = _new_contract(
        contract_file=contract_file,
        run_dir=run_dir,
        job_id=job_id,
        run_id=run_id,
        pipeline_title=args.pipeline_title,
        output_location=args.output_location,
        runtime_meta=runtime_meta,
        config_json=config_json,
        inputs_json=inputs_json,
        run_metadata_json=run_metadata_json,
        tasks=tasks,
        assets=assets,
        spec_file=spec_file,
    )

    _write_contract(contract)

    if args.upload_gcs_dir:
        gcs_dest = args.upload_gcs_dir.rstrip("/") + "/_run_contract.json"
        ok_upload, err = _upload_contract_to_gcs(contract_file, gcs_dest)
        if ok_upload:
            print(f"  uploaded: {gcs_dest}")
        else:
            print(f"WARNING: GCS upload failed: {err}", file=sys.stderr)

    input_count = sum(1 for a in assets if a.get("role") == "input")
    output_count = sum(1 for a in assets if a.get("role") == "output")

    print(f"run_contract init: {contract_file}")
    print(f"run_id={run_id}")
    print(f"tasks={len(tasks)} assets={len(assets)} (inputs={input_count} outputs={output_count})")
    return 0


def _cmd_record_produced(args: argparse.Namespace) -> int:
    contract_file = Path(args.contract_file).expanduser().resolve()
    contract = _load_contract(contract_file)

    task_id = str(args.task_id).strip()
    if not task_id:
        raise ValueError("--task-id is required")

    task = _ensure_task(contract, task_id)
    if not task.get("started_at"):
        task["started_at"] = _utc_now_iso()
    if task.get("status") in {"expected", None, ""}:
        task["status"] = "running"

    seed = args.uri or args.local_path or args.local_glob or args.gcs_glob or f"{task_id}:{_utc_now_iso()}"
    asset_id = str(args.asset_id or f"{task_id}/produced/{hashlib.sha1(seed.encode('utf-8')).hexdigest()[:12]}")

    asset = _ensure_asset(contract, asset_id, task_id)
    asset["task_id"] = task_id
    asset["kind"] = str(args.kind or asset.get("kind") or "output")
    asset["required"] = bool(_parse_bool(args.required, default=bool(asset.get("required", True))))
    asset["uri"] = args.uri or asset.get("uri")
    asset["local_path"] = args.local_path or asset.get("local_path")
    asset["local_glob"] = args.local_glob or asset.get("local_glob")
    asset["gcs_glob"] = args.gcs_glob or asset.get("gcs_glob")
    asset["expected"] = bool(asset.get("expected", False))
    asset["produced"] = True
    asset["status"] = "produced"

    if args.extra_json_file:
        extra = _load_json_file(Path(args.extra_json_file).expanduser())
        if not isinstance(extra, dict):
            raise ValueError("--extra-json-file must be a JSON object")
        merged = dict(asset.get("extra") or {})
        merged.update(extra)
        asset["extra"] = merged

    task_asset_ids = list(task.get("asset_ids") or [])
    if asset_id not in task_asset_ids:
        task_asset_ids.append(asset_id)
    task["asset_ids"] = sorted(set(task_asset_ids))

    _write_contract(contract)
    print(f"run_contract record-produced: task={task_id} asset={asset_id}")
    return 0


def _cmd_mark_task(args: argparse.Namespace, *, status: str) -> int:
    contract_file = Path(args.contract_file).expanduser().resolve()
    contract = _load_contract(contract_file)

    error = None
    if args.error_json_file:
        error = _load_json_file(Path(args.error_json_file).expanduser())
        if not isinstance(error, dict):
            raise ValueError("--error-json-file must be a JSON object")

    _set_task_status(contract, task_id=str(args.task_id), status=status, error=error)
    _write_contract(contract)
    print(f"run_contract mark-task-{status}: task={args.task_id}")
    return 0


def _cmd_preflight(args: argparse.Namespace) -> int:
    contract_file = Path(args.contract_file).expanduser().resolve()
    contract = _load_contract(contract_file)

    assets = contract.get("assets", [])
    input_assets = [a for a in assets if a.get("role") == "input"]

    now_iso = _utc_now_iso()
    missing_required: List[str] = []
    missing_optional: List[str] = []
    ok_count = 0

    for asset in input_assets:
        exists, exists_reason, matched = _asset_exists(asset)
        asset["exists"] = exists
        asset["exists_reason"] = exists_reason
        if matched:
            asset["matched_outputs"] = matched[:200]

        aid = str(asset.get("asset_id") or "")
        required = bool(asset.get("required", True))

        if exists is True:
            asset["status"] = "ok"
            ok_count += 1
            tag = "[OK]     "
            loc = asset.get("uri") or asset.get("local_path") or asset.get("local_glob") or asset.get("gcs_glob") or ""
            print(f"  {tag} {aid:<30s} {loc}")
        elif exists is False:
            asset["status"] = "missing"
            if required:
                missing_required.append(aid)
            else:
                missing_optional.append(aid)
            req_label = "(required)" if required else "(optional)"
            loc = asset.get("uri") or asset.get("local_path") or asset.get("local_glob") or asset.get("gcs_glob") or ""
            print(f"  [MISSING] {aid:<30s} {loc}  {req_label}")
        else:
            asset["status"] = "unknown"
            loc = asset.get("uri") or asset.get("local_path") or asset.get("local_glob") or asset.get("gcs_glob") or ""
            print(f"  [UNKNOWN] {aid:<30s} {loc}")

    contract["preflight"] = {
        "checked_at": now_iso,
        "total_inputs": len(input_assets),
        "ok": ok_count,
        "missing_required": missing_required,
        "missing_required_count": len(missing_required),
        "missing_optional": missing_optional,
        "missing_optional_count": len(missing_optional),
    }

    _write_contract(contract)

    if args.upload_gcs_dir:
        contract_path = Path(str(contract.get("paths", {}).get("contract_json") or contract_file))
        gcs_dest = args.upload_gcs_dir.rstrip("/") + "/_run_contract.json"
        ok_upload, err = _upload_contract_to_gcs(contract_path, gcs_dest)
        if not ok_upload:
            print(f"WARNING: GCS upload failed: {err}", file=sys.stderr)

    print(f"run_contract preflight: {contract_file}")
    print(
        f"total_inputs={len(input_assets)} ok={ok_count} "
        f"missing_required={len(missing_required)} missing_optional={len(missing_optional)}"
    )

    if args.strict and missing_required:
        return 2

    return 0


def _cmd_finalize(args: argparse.Namespace) -> int:
    contract_file = Path(args.contract_file).expanduser().resolve()
    contract = _load_contract(contract_file)

    audit_corruption = _parse_bool(args.audit_corruption, default=True)
    now_iso = _utc_now_iso()

    tasks = contract.get("tasks", [])
    assets = contract.get("assets", [])
    task_map = _task_index(contract)
    asset_map = _asset_index(contract)

    # Ensure task references are consistent.
    for task in tasks:
        task.setdefault("asset_ids", [])
    for asset in assets:
        tid = str(asset.get("task_id") or "")
        aid = str(asset.get("asset_id") or "")
        if not tid:
            tid = "unassigned"
            asset["task_id"] = tid
        if tid not in task_map:
            task_map[tid] = _ensure_task(contract, tid)
        asset_ids = list(task_map[tid].get("asset_ids") or [])
        if aid and aid not in asset_ids:
            asset_ids.append(aid)
            task_map[tid]["asset_ids"] = sorted(set(asset_ids))

    known_existing_locations: set[str] = set()
    missing_required: List[str] = []
    corrupt_required: List[str] = []
    unknown_required: List[str] = []

    for asset in assets:
        exists, exists_reason, matched = _asset_exists(asset)
        asset["exists"] = exists
        asset["exists_reason"] = exists_reason
        if matched:
            asset["matched_outputs"] = matched[:200]

        corrupt = None
        corrupt_reason = None
        if audit_corruption and exists is True and str(asset.get("kind") or "") == "metadata":
            meta = _read_json_from_asset(asset)
            if isinstance(meta, dict):
                if "corrupt" in meta:
                    corrupt = bool(meta.get("corrupt"))
                    corrupt_reason = "metadata.corrupt"
                elif "success" in meta:
                    corrupt = not bool(meta.get("success"))
                    corrupt_reason = "metadata.success"

        asset["corrupt"] = corrupt
        asset["corrupt_reason"] = corrupt_reason

        if asset.get("error"):
            status = "failed"
        elif exists is False and (
            asset.get("uri") or asset.get("local_path") or asset.get("local_glob") or asset.get("gcs_glob")
        ):
            status = "missing"
        elif corrupt is True:
            status = "corrupt"
        elif exists is True:
            status = "ok"
        elif exists is None and (
            asset.get("uri") or asset.get("local_path") or asset.get("local_glob") or asset.get("gcs_glob")
        ):
            status = "unknown"
        else:
            status = "produced" if asset.get("produced") else "expected"
        asset["status"] = status

        if exists is True:
            if asset.get("local_path"):
                known_existing_locations.add(_normalize_local_path(str(asset["local_path"])))
            if asset.get("uri"):
                known_existing_locations.add(_normalize_gs_uri(str(asset["uri"])))
            for item in matched:
                if str(item).startswith("gs://"):
                    known_existing_locations.add(_normalize_gs_uri(str(item)))
                else:
                    known_existing_locations.add(_normalize_local_path(str(item)))

        if bool(asset.get("required", True)):
            aid = str(asset.get("asset_id") or "")
            if status in {"missing", "failed"}:
                missing_required.append(aid)
            elif status == "corrupt":
                corrupt_required.append(aid)
            elif status == "unknown":
                unknown_required.append(aid)

    discovered_local = _scan_local_files(args.scan_local_dir or [])
    discovered_gcs = _scan_gcs_files(args.scan_gcs_prefix or [])
    discovered_all: set[str] = set(discovered_local + discovered_gcs)

    unexpected_outputs = sorted(discovered_all - known_existing_locations)

    task_status_counts: Dict[str, int] = {}
    for task in tasks:
        task_asset_ids = list(task.get("asset_ids") or [])
        required_assets = [
            asset_map.get(str(aid))
            for aid in task_asset_ids
            if isinstance(asset_map.get(str(aid)), dict)
            and bool(asset_map.get(str(aid), {}).get("required", True))
        ]

        existing_status = str(task.get("status") or "")
        if existing_status == "failed":
            final_status = "failed"
        else:
            required_statuses = [str(asset.get("status") or "unknown") for asset in required_assets]
            if required_statuses:
                if any(status == "failed" for status in required_statuses):
                    final_status = "failed"
                elif any(status == "missing" for status in required_statuses):
                    final_status = "succeeded_with_missing_outputs"
                elif any(status == "corrupt" for status in required_statuses):
                    final_status = "succeeded_with_corrupt_outputs"
                elif any(status == "unknown" for status in required_statuses):
                    final_status = "succeeded_with_unverified_outputs"
                elif all(status == "ok" for status in required_statuses):
                    final_status = "succeeded"
                else:
                    final_status = existing_status or "unknown"
            else:
                if existing_status in {"", "expected", "running", "produced"}:
                    final_status = "succeeded"
                else:
                    final_status = existing_status or "unknown"

        task["status"] = final_status
        task["finished_at"] = task.get("finished_at") or now_iso
        task_status_counts[final_status] = task_status_counts.get(final_status, 0) + 1

    asset_status_counts: Dict[str, int] = {}
    input_asset_status_counts: Dict[str, int] = {}
    output_asset_status_counts: Dict[str, int] = {}
    missing_required_input_ids: List[str] = []
    for asset in assets:
        st = str(asset.get("status") or "unknown")
        asset_status_counts[st] = asset_status_counts.get(st, 0) + 1
        role = str(asset.get("role") or "output")
        if role == "input":
            input_asset_status_counts[st] = input_asset_status_counts.get(st, 0) + 1
            if st in {"missing", "failed"} and bool(asset.get("required", True)):
                missing_required_input_ids.append(str(asset.get("asset_id") or ""))
        else:
            output_asset_status_counts[st] = output_asset_status_counts.get(st, 0) + 1

    verification: Dict[str, Any] = {
        "finished_at": now_iso,
        "expected_assets_count": sum(1 for asset in assets if bool(asset.get("expected"))),
        "produced_assets_count": sum(1 for asset in assets if bool(asset.get("produced"))),
        "required_assets_count": sum(1 for asset in assets if bool(asset.get("required", True))),
        "asset_status_counts": asset_status_counts,
        "input_asset_status_counts": input_asset_status_counts,
        "output_asset_status_counts": output_asset_status_counts,
        "task_status_counts": task_status_counts,
        "missing_required_asset_ids": sorted(set(missing_required)),
        "missing_required_input_ids": sorted(set(missing_required_input_ids)),
        "corrupt_required_asset_ids": sorted(set(corrupt_required)),
        "unverified_required_asset_ids": sorted(set(unknown_required)),
        "unexpected_outputs": unexpected_outputs,
        "unexpected_outputs_count": len(unexpected_outputs),
    }

    if args.verification_json_file:
        extra = _load_json_file(Path(args.verification_json_file).expanduser())
        if not isinstance(extra, dict):
            raise ValueError("--verification-json-file must be a JSON object")
        verification.update(extra)

    run_meta = contract.setdefault("run", {})
    run_status = str(args.status or "").strip()
    if not run_status:
        if task_status_counts.get("failed", 0) > 0:
            run_status = "FAILED"
        elif missing_required or corrupt_required:
            run_status = "FINISHED_WITH_ISSUES"
        elif unknown_required:
            run_status = "FINISHED_WITH_UNVERIFIED_OUTPUTS"
        else:
            run_status = "FINISHED"

    run_meta["status"] = run_status
    run_meta["completed_at"] = now_iso
    if args.output_location:
        run_meta["output_location"] = args.output_location

    contract["verification"] = verification
    _write_contract(contract)

    # ---- Upload contracts to GCS ----
    scope = str(getattr(args, "contract_scope", "folder") or "folder").strip().lower()
    output_location = str(args.output_location or contract.get("run", {}).get("output_location") or "").strip()
    contract_local = Path(str(contract.get("paths", {}).get("contract_json") or contract_file))

    folder_uploads: List[Dict[str, Any]] = []

    if scope == "folder" and output_location.startswith("gs://"):
        # Per-folder: group assets by GCS folder, build filtered contract per folder, upload each.
        folder_groups = _group_assets_by_folder(assets)
        if folder_groups:
            tmp_dir = Path(tempfile.mkdtemp(prefix="run_contract_folders_"))
            for folder_uri, folder_assets in sorted(folder_groups.items()):
                folder_contract = _build_folder_contract(contract, folder_uri, folder_assets)
                folder_file = tmp_dir / hashlib.sha1(folder_uri.encode()).hexdigest()[:12] / "_run_contract.json"
                _atomic_write_json(folder_file, folder_contract)
                gcs_dest = folder_uri.rstrip("/") + "/_run_contract.json"
                ok, err = _upload_contract_to_gcs(folder_file, gcs_dest)
                folder_uploads.append({
                    "folder_uri": folder_uri,
                    "gcs_dest": gcs_dest,
                    "asset_count": len(folder_assets),
                    "success": bool(ok),
                    "error": err,
                })
                if ok:
                    print(f"  uploaded: {gcs_dest} ({len(folder_assets)} assets)")
                else:
                    print(f"  FAILED:   {gcs_dest}: {err}", file=sys.stderr)
        else:
            # No GCS assets found — fallback to single contract at output root.
            gcs_dest = output_location.rstrip("/") + "/_run_contract.json"
            ok, err = _upload_contract_to_gcs(contract_local, gcs_dest)
            folder_uploads.append({
                "folder_uri": output_location,
                "gcs_dest": gcs_dest,
                "asset_count": len(assets),
                "success": bool(ok),
                "error": err,
            })
            if ok:
                print(f"  uploaded: {gcs_dest}")
            else:
                print(f"  FAILED:   {gcs_dest}: {err}", file=sys.stderr)
    elif scope == "run" and output_location.startswith("gs://"):
        # Single contract at output root.
        gcs_dest = output_location.rstrip("/") + "/_run_contract.json"
        ok, err = _upload_contract_to_gcs(contract_local, gcs_dest)
        folder_uploads.append({
            "folder_uri": output_location,
            "gcs_dest": gcs_dest,
            "asset_count": len(assets),
            "success": bool(ok),
            "error": err,
        })
        if ok:
            print(f"  uploaded: {gcs_dest}")
        else:
            print(f"  FAILED:   {gcs_dest}: {err}", file=sys.stderr)

    if folder_uploads:
        verification["folder_uploads"] = folder_uploads
        contract["verification"] = verification
        _write_contract(contract)

    print(f"run_contract finalize: {contract_file}")
    print(
        "required_missing="
        f"{len(verification.get('missing_required_asset_ids') or [])} "
        "required_corrupt="
        f"{len(verification.get('corrupt_required_asset_ids') or [])} "
        "required_unverified="
        f"{len(verification.get('unverified_required_asset_ids') or [])}"
    )
    if input_asset_status_counts:
        print(f"input_assets={input_asset_status_counts}")
    if output_asset_status_counts:
        print(f"output_assets={output_asset_status_counts}")

    if args.strict:
        if (
            verification.get("missing_required_asset_ids")
            or verification.get("corrupt_required_asset_ids")
            or verification.get("unverified_required_asset_ids")
            or task_status_counts.get("failed", 0) > 0
        ):
            return 2

    return 0


def _format_env(values: Mapping[str, str], fmt: str) -> str:
    if fmt == "json":
        return json.dumps(values, indent=2, sort_keys=True)
    if fmt == "set-env-vars":
        items = [f"{key}={value}" for key, value in values.items() if value != ""]
        return ",".join(items)
    if fmt == "shell":
        return "\n".join(f"export {key}={json.dumps(value)}" for key, value in values.items())
    # dotenv default
    return "\n".join(f"{key}={value}" for key, value in values.items())


def _gsutil_stat(uri: str) -> Tuple[bool, int | None]:
    """Check existence and size of a GCS URI in a single call.

    Returns (exists, size_bytes).
    """
    if not _command_exists("gsutil"):
        return (False, None)
    proc = subprocess.run(["gsutil", "stat", uri], capture_output=True, text=True)
    if proc.returncode != 0:
        return (False, None)
    size_bytes = None
    for line in (proc.stdout or "").splitlines():
        stripped = line.strip()
        if stripped.lower().startswith("content-length:"):
            try:
                size_bytes = int(stripped.split(":", 1)[1].strip())
            except (ValueError, IndexError):
                pass
    return (True, size_bytes)


def _format_size(size_bytes: int | None) -> str:
    """Human-readable file size."""
    if size_bytes is None:
        return "unknown"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(size_bytes) < 1024:
            return f"{size_bytes:.1f} {unit}" if unit != "B" else f"{size_bytes} B"
        size_bytes = size_bytes / 1024
    return f"{size_bytes:.1f} PB"


def _download_gcs_contract(uri: str) -> Dict[str, Any] | None:
    """Download a _run_contract.json from GCS and parse it."""
    if not _command_exists("gsutil"):
        return None
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        proc = subprocess.run(
            ["gsutil", "cp", uri, tmp_path], capture_output=True, text=True
        )
        if proc.returncode != 0:
            return None
        return json.loads(Path(tmp_path).read_text(encoding="utf-8"))
    except Exception:
        return None
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def _cmd_verify(args: argparse.Namespace) -> int:
    gcs_folder = _normalize_gs_uri(str(args.gcs_folder)).rstrip("/")
    report_file = Path("./verification_report.json").resolve()

    print(f"run_contract verify: scanning {gcs_folder}/ ...")
    all_files = _scan_gcs_files([gcs_folder])
    contract_uris = [f for f in all_files if f.endswith("_run_contract.json")]

    if not contract_uris:
        print(f"No _run_contract.json files found under {gcs_folder}/")
        return 0

    print(f"Found {len(contract_uris)} contract(s). Verifying assets ...")

    all_assets: List[Dict[str, Any]] = []
    total_ok = 0
    total_missing = 0
    total_size = 0

    for contract_uri in contract_uris:
        contract = _download_gcs_contract(contract_uri)
        if contract is None:
            print(f"  WARN: could not read {contract_uri}", file=sys.stderr)
            continue

        assets = contract.get("assets", [])
        gcs_assets = [a for a in assets if a.get("uri", "").startswith("gs://")]
        for i, asset in enumerate(gcs_assets, 1):
            normalized = _normalize_gs_uri(str(asset["uri"]))
            exists, size_bytes = _gsutil_stat(normalized)

            if exists:
                total_ok += 1
                if size_bytes is not None:
                    total_size += size_bytes
                print(f"  [{i}/{len(gcs_assets)}] OK  {_format_size(size_bytes):>10s}  {normalized}")
            else:
                total_missing += 1
                print(f"  [{i}/{len(gcs_assets)}] MISSING          {normalized}")

            all_assets.append({
                "asset_id": asset.get("asset_id"),
                "uri": normalized,
                "exists": exists,
                "size_bytes": size_bytes,
                "size_human": _format_size(size_bytes),
                "status": "ok" if exists else "missing",
                "required": asset.get("required", True),
                "kind": asset.get("kind"),
                "contract_source": contract_uri,
            })

    total_assets = total_ok + total_missing
    report = {
        "gcs_folder": gcs_folder,
        "contracts_found": len(contract_uris),
        "total_assets": total_assets,
        "total_ok": total_ok,
        "total_missing": total_missing,
        "total_size_bytes": total_size,
        "total_size_human": _format_size(total_size),
        "all_ok": total_missing == 0,
        "assets": all_assets,
    }

    report_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print("")
    if total_missing == 0:
        print(f"All {total_assets} assets verified across {len(contract_uris)} contract(s). "
              f"Total size: {_format_size(total_size)}.")
    else:
        print(f"{total_missing} of {total_assets} assets missing across {len(contract_uris)} contract(s).")
    print(f"Report: {report_file}")

    return 0


def _cmd_extract_retry_scope(args: argparse.Namespace) -> int:
    """Read a prior contract, verify assets on GCS, output retry scope JSON."""
    output_file = Path(args.output_file)

    # ---- Load contract ----
    contract: Dict[str, Any] | None = None
    source_label = ""
    if args.gcs_contract:
        source_label = _normalize_gs_uri(str(args.gcs_contract))
        print(f"run_contract extract-retry-scope: downloading {source_label}")
        contract = _download_gcs_contract(source_label)
        if contract is None:
            raise ValueError(f"Could not download contract from {source_label}")
    elif args.contract_file:
        source_label = str(Path(args.contract_file).resolve())
        print(f"run_contract extract-retry-scope: reading {source_label}")
        contract = json.loads(Path(args.contract_file).read_text(encoding="utf-8"))
    else:
        raise ValueError("Either --contract-file or --gcs-contract is required")

    assets = contract.get("assets", [])
    required_output_assets = [
        a for a in assets
        if a.get("role") == "output"
        and a.get("required", False)
        and a.get("uri", "").startswith("gs://")
    ]

    print(f"  total assets: {len(assets)}, required output assets to verify: {len(required_output_assets)}")

    # ---- Verify each required output asset on GCS ----
    missing_by_task: Dict[str, List[str]] = {}
    ok_by_task: Dict[str, List[str]] = {}
    all_task_ids: set[str] = set()

    for i, asset in enumerate(required_output_assets, 1):
        asset_id = asset.get("asset_id", "")
        uri = _normalize_gs_uri(str(asset["uri"]))

        # Extract task_id: first 4 segments of asset_id
        parts = asset_id.split("/")
        task_id = "/".join(parts[:4]) if len(parts) >= 4 else asset_id
        all_task_ids.add(task_id)

        exists, _ = _gsutil_stat(uri)
        if exists:
            ok_by_task.setdefault(task_id, []).append(asset_id)
            print(f"  [{i}/{len(required_output_assets)}] OK      {uri}")
        else:
            missing_by_task.setdefault(task_id, []).append(asset_id)
            print(f"  [{i}/{len(required_output_assets)}] MISSING {uri}")

    # ---- Determine retry scope ----
    retry_task_ids = sorted(missing_by_task.keys())
    completed_task_ids = sorted(all_task_ids - set(retry_task_ids))

    scope = {
        "source_contract": source_label,
        "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "total_tasks": len(all_task_ids),
        "completed_tasks": len(completed_task_ids),
        "retry_tasks": len(retry_task_ids),
        "retry_task_ids": retry_task_ids,
    }

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(scope, indent=2) + "\n", encoding="utf-8")

    print(f"\n  total_tasks={len(all_task_ids)} completed={len(completed_task_ids)} retry={len(retry_task_ids)}")
    print(f"  Retry scope written to {output_file}")

    return 0


def _cmd_cloud_run_env(args: argparse.Namespace) -> int:
    job_id = str(args.job_id or os.getenv("RUN_CONTRACT_JOB_ID", "")).strip()
    if not job_id:
        raise ValueError("--job-id is required (or set RUN_CONTRACT_JOB_ID)")

    run_dir = args.run_dir or f"/tmp/run_contracts/{_safe_slug(job_id)}"
    contract_file = args.contract_file or f"{run_dir.rstrip('/')}/_run_contract.json"

    values: Dict[str, str] = {
        "RUN_CONTRACT_ENABLED": "true",
        "RUN_CONTRACT_JOB_ID": job_id,
        "RUN_CONTRACT_RUN_DIR": run_dir,
        "RUN_CONTRACT_FILE": contract_file,
        "RUN_CONTRACT_SPEC_FILE": args.spec_file or "",
        "RUN_CONTRACT_GCS_DIR": args.gcs_run_dir or "",
        "RUN_CONTRACT_RUN_ID_ENV": "CLOUD_RUN_EXECUTION",
    }

    rendered = _format_env(values, args.format)
    if args.output_file:
        _atomic_write_text(Path(args.output_file).expanduser(), rendered + "\n")
        print(f"run_contract cloud-run-env: wrote {args.output_file}")
    else:
        print(rendered)

    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run contract utility (pipeline-agnostic)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="Initialize run contract")
    p_init.add_argument("--contract-file", help="Path to _run_contract.json")
    p_init.add_argument("--run-dir", help="Run directory (default: run_contracts/<job>/<run_id>)")
    p_init.add_argument("--job-id", help="Job identifier")
    p_init.add_argument("--run-id", help="Run identifier (default: BUILD_ID/SDM_RUN_ID/timestamp)")
    p_init.add_argument("--pipeline-title", help="Human-readable pipeline title")
    p_init.add_argument("--output-location", help="Primary output root/path")
    p_init.add_argument("--spec-file", help="JSON job expectations file")
    p_init.add_argument("--expected-assets-file", help="JSON array of expected output assets")
    p_init.add_argument("--expected-inputs-file", help="JSON array of expected input assets")
    p_init.add_argument("--init-json-file", help="Single JSON file with keys: config, inputs, expected_assets, run_metadata (replaces individual --*-json-file flags)")
    p_init.add_argument("--config-json-file", help="File containing JSON object for configuration")
    p_init.add_argument("--inputs-json-file", help="File containing JSON object for input data")
    p_init.add_argument("--run-metadata-json-file", help="File containing JSON object merged into run.extra")
    p_init.add_argument("--vars-file", help="JSON object of template variables")
    p_init.add_argument("--var", action="append", help="Template variable KEY=VALUE (repeatable)")
    p_init.add_argument("--upload-gcs-dir", help="Upload contract to gs:// path after init")
    p_init.set_defaults(func=_cmd_init)

    p_pre = sub.add_parser("preflight", help="Verify all input assets exist before processing")
    p_pre.add_argument("--contract-file", required=True, help="Path to _run_contract.json")
    p_pre.add_argument("--strict", action="store_true", help="Exit 2 if any required inputs are missing")
    p_pre.add_argument("--upload-gcs-dir", help="Upload contract to gs:// path after preflight")
    p_pre.set_defaults(func=_cmd_preflight)

    p_prod = sub.add_parser("record-produced", help="Upsert a produced asset")
    p_prod.add_argument("--contract-file", required=True)
    p_prod.add_argument("--task-id", required=True)
    p_prod.add_argument("--asset-id", help="Asset id (optional; deterministic hash if omitted)")
    p_prod.add_argument("--kind", help="Asset kind (default: output)")
    p_prod.add_argument("--required", help="true|false (default: keep existing or true)")
    p_prod.add_argument("--uri", help="gs:// URI")
    p_prod.add_argument("--local-path", help="Local file path")
    p_prod.add_argument("--local-glob", help="Local glob pattern")
    p_prod.add_argument("--gcs-glob", help="GCS glob pattern")
    p_prod.add_argument("--extra-json-file", help="File containing JSON object merged into asset.extra")
    p_prod.set_defaults(func=_cmd_record_produced)

    p_running = sub.add_parser("mark-task-running", help="Mark task as running")
    p_running.add_argument("--contract-file", required=True)
    p_running.add_argument("--task-id", required=True)
    p_running.add_argument("--error-json-file", help="File containing optional JSON error object")
    p_running.set_defaults(func=lambda a: _cmd_mark_task(a, status="running"))

    p_success = sub.add_parser("mark-task-succeeded", help="Mark task as succeeded")
    p_success.add_argument("--contract-file", required=True)
    p_success.add_argument("--task-id", required=True)
    p_success.add_argument("--error-json-file", help="File containing optional JSON error object")
    p_success.set_defaults(func=lambda a: _cmd_mark_task(a, status="succeeded"))

    p_failed = sub.add_parser("mark-task-failed", help="Mark task as failed")
    p_failed.add_argument("--contract-file", required=True)
    p_failed.add_argument("--task-id", required=True)
    p_failed.add_argument("--error-json-file", help="File containing JSON error object")
    p_failed.set_defaults(func=lambda a: _cmd_mark_task(a, status="failed"))

    p_finalize = sub.add_parser("finalize", help="Finalize run contract with expected-vs-actual audits")
    p_finalize.add_argument("--contract-file", required=True)
    p_finalize.add_argument("--status", help="Override final run status")
    p_finalize.add_argument("--output-location", help="Override run.output_location")
    p_finalize.add_argument("--verification-json-file", help="File containing JSON object merged into verification")
    p_finalize.add_argument("--audit-corruption", help="true|false (default: true)")
    p_finalize.add_argument("--scan-local-dir", action="append", help="Directory to scan for actual outputs")
    p_finalize.add_argument("--scan-gcs-prefix", action="append", help="GCS prefix to scan for actual outputs")
    p_finalize.add_argument("--contract-scope", choices=["run", "folder"], default="folder",
                            help="Upload scope: 'folder' writes per-folder contracts (default), 'run' writes one at output root")
    p_finalize.add_argument("--strict", action="store_true", help="Exit 2 if required outputs are missing/corrupt/unverified")
    p_finalize.set_defaults(func=_cmd_finalize)

    p_verify = sub.add_parser("verify", help="Discover contracts under a GCS folder and verify all asset URIs exist")
    p_verify.add_argument("gcs_folder", help="gs:// folder to scan recursively for _run_contract.json files")
    p_verify.set_defaults(func=_cmd_verify)

    p_retry = sub.add_parser("extract-retry-scope",
                              help="Read a prior contract, verify assets on GCS, and output a retry scope JSON")
    p_retry.add_argument("--contract-file", help="Path to a local _run_contract.json")
    p_retry.add_argument("--gcs-contract", help="gs:// URI of a _run_contract.json to download")
    p_retry.add_argument("--output-file", required=True, help="Path to write the retry scope JSON")
    p_retry.set_defaults(func=_cmd_extract_retry_scope)

    p_cre = sub.add_parser("cloud-run-env", help="Generate Cloud Run env values for run-contract wiring")
    p_cre.add_argument("--job-id", help="Job identifier")
    p_cre.add_argument("--run-dir", help="Run contract base dir in container")
    p_cre.add_argument("--contract-file", help="Contract JSON path in container")
    p_cre.add_argument("--spec-file", help="Spec JSON path in container")
    p_cre.add_argument("--gcs-run-dir", help="Optional gs:// path for report uploads")
    p_cre.add_argument("--format", choices=["dotenv", "shell", "set-env-vars", "json"], default="dotenv")
    p_cre.add_argument("--output-file", help="Optional file to write output")
    p_cre.set_defaults(func=_cmd_cloud_run_env)

    return parser


def main(argv: List[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        handler = getattr(args, "func")
        return int(handler(args))
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
