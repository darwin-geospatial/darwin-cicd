#!/usr/bin/env python3
"""
Self-test for batched GCS verification in cicd/utils/run_contract.py.

finalize/preflight used to run one `gsutil -q stat` (plus one `command -v gsutil`
probe) per asset, which kept a VM up 15-30 min after a ~400-asset training run.
They now probe gsutil once and verify exact gs:// URIs with one `gsutil ls` per
folder. This test mocks subprocess.run with an in-memory fake GCS and asserts:

  1. finalize on a mixed ~400-asset fixture gives exactly the same per-asset
     results and verification block as the old per-asset behaviour;
  2. the number of subprocess calls is O(folders), not O(assets);
  3. a folder whose listing fails falls back to per-asset stat (same result);
  4. a listing that times out reports the assets as unknown instead of hanging.

No network, no real gsutil.

Usage:  python3 cicd/tests/test_run_contract_batch.py <cicd_root>
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

# Rough real-world cost of one gsutil invocation on a VM (python startup + auth + RPC).
EST_SEC_PER_GSUTIL_CALL = 2.5


def check(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        msg = f"FAILED: {label}"
        if detail:
            msg += f" - {detail}"
        raise AssertionError(msg)
    print(f"  ok: {label}")


def load_module(cicd_root: Path):
    spec = importlib.util.spec_from_file_location("run_contract_under_test", cicd_root / "utils" / "run_contract.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class FakeGCS:
    """Minimal stand-in for subprocess.run covering the gsutil calls run_contract makes."""

    def __init__(self, objects, failing_folders=(), timeout_folders=()):
        self.objects = set(objects)
        self.failing_folders = set(failing_folders)
        self.timeout_folders = set(timeout_folders)
        self.calls = []

    def count(self, kind: str) -> int:
        return sum(1 for c in self.calls if c[0] == kind)

    def __call__(self, cmd, *args, **kwargs):
        cmd = list(cmd)
        if cmd[:2] == ["bash", "-lc"] and cmd[2].startswith("command -v"):
            self.calls.append(("probe", cmd[2]))
            return SimpleNamespace(returncode=0, stdout="/usr/bin/gsutil\n", stderr="")
        if cmd[:3] == ["gsutil", "-q", "stat"]:
            self.calls.append(("stat", cmd[3]))
            return SimpleNamespace(returncode=0 if cmd[3] in self.objects else 1, stdout="", stderr="")
        if cmd[:2] == ["gsutil", "ls"] and len(cmd) == 3:
            folder = cmd[2]
            self.calls.append(("ls", folder))
            base = folder.rstrip("/")
            if base in self.timeout_folders:
                raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout"))
            if base in self.failing_folders:
                return SimpleNamespace(returncode=1, stdout="", stderr="AccessDeniedException: 403 denied")
            prefix = base + "/"
            lines = set()
            for obj in self.objects:
                if obj.startswith(prefix):
                    rest = obj[len(prefix):]
                    lines.add(obj if "/" not in rest else prefix + rest.split("/", 1)[0] + "/")
            if not lines:
                return SimpleNamespace(
                    returncode=1, stdout="", stderr="CommandException: One or more URLs matched no objects."
                )
            return SimpleNamespace(returncode=0, stdout="\n".join(sorted(lines)) + "\n", stderr="")
        raise AssertionError(f"unexpected subprocess call: {cmd}")


def build_fixture(tmp: Path):
    """~400 assets: 8 big folders (mixed present/missing), a nested subfolder, an empty folder,
    a folder whose listing fails, a single-asset folder, a wildcard uri, plus local paths."""
    bucket = "gs://train-bucket/run-001"
    assets = []
    objects = set()

    for f in range(8):
        folder = f"{bucket}/tile_{f:02d}"
        for i in range(48):
            uri = f"{folder}/part_{i:03d}.tif"
            assets.append({"asset_id": f"tile_{f:02d}/part_{i:03d}", "kind": "cog", "role": "output",
                           "required": i % 5 != 0, "uri": uri})
            if (f * 48 + i) % 7 != 3:  # roughly 1 in 7 missing
                objects.add(uri)
        objects.add(f"{folder}/unexpected_extra.tif")
        objects.add(f"{folder}/sub/deeper.tif")  # appears as a sub-prefix in ls, must not confuse membership

    for i in range(4):  # nested subfolder assets
        uri = f"{bucket}/tile_00/sub/n_{i}.tif"
        assets.append({"asset_id": f"nested/n_{i}", "kind": "cog", "role": "output", "uri": uri})
        if i % 2 == 0:
            objects.add(uri)

    for i in range(3):  # empty folder: ls says "matched no objects"
        assets.append({"asset_id": f"empty/{i}", "kind": "cog", "role": "output",
                       "uri": f"{bucket}/empty_folder/x_{i}.tif"})

    failing = f"{bucket}/denied"
    for i in range(3):  # listing fails -> must fall back to stat
        uri = f"{failing}/d_{i}.tif"
        assets.append({"asset_id": f"denied/{i}", "kind": "cog", "role": "output", "uri": uri})
        if i != 1:
            objects.add(uri)

    single = f"{bucket}/single/only.json"
    objects.add(single)
    assets.append({"asset_id": "single/only", "kind": "manifest", "role": "output", "uri": single})

    # double slashes and trailing slash get normalized exactly as before
    assets.append({"asset_id": "messy/uri", "kind": "cog", "role": "output",
                   "uri": f"{bucket}//tile_01//part_001.tif/"})

    wild = f"{bucket}/tile_02/part_00*.tif"
    assets.append({"asset_id": "wild/uri", "kind": "cog", "role": "output", "uri": wild})

    present_local = tmp / "local_present.txt"
    present_local.write_text("x")
    assets.append({"asset_id": "local/present", "kind": "log", "role": "output", "local_path": str(present_local)})
    assets.append({"asset_id": "local/missing", "kind": "log", "role": "output",
                   "local_path": str(tmp / "local_missing.txt")})

    # a few inputs so preflight is exercised too
    for i in range(3):
        uri = f"{bucket}/inputs/in_{i}.tif"
        assets.append({"asset_id": f"input/{i}", "kind": "cog", "role": "input", "uri": uri})
        if i != 2:
            objects.add(uri)

    return assets, objects, failing


def init_contract(mod, tmp: Path, name: str, assets) -> Path:
    contract_file = tmp / name / "_run_contract.json"
    contract_file.parent.mkdir(parents=True)
    init_json = tmp / name / "init.json"
    init_json.write_text(json.dumps({"expected_assets": assets, "config": {}}))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = mod.main(["init", "--contract-file", str(contract_file), "--job-id", "batchtest",
                       "--run-id", "run-001", "--init-json-file", str(init_json)])
    assert rc == 0
    return contract_file


def run_finalize(mod, fake: FakeGCS, contract_file: Path, *, legacy: bool) -> dict:
    """legacy=True reproduces the old code path: no prefetch and an uncached gsutil probe per call."""
    mod._command_exists.cache_clear()
    mod._GCS_EXISTS_CACHE.clear()
    orig_run = mod.subprocess.run
    orig_prefetch = mod._prefetch_gcs_uri_existence
    orig_probe = mod._command_exists
    mod.subprocess.run = fake
    if legacy:
        mod._prefetch_gcs_uri_existence = lambda assets: None
        mod._command_exists = orig_probe.__wrapped__
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = mod.main(["preflight", "--contract-file", str(contract_file)])
            assert rc == 0
            rc = mod.main(["finalize", "--contract-file", str(contract_file), "--contract-scope", "run"])
            assert rc == 0
    finally:
        mod.subprocess.run = orig_run
        mod._prefetch_gcs_uri_existence = orig_prefetch
        mod._command_exists = orig_probe
    return json.loads(contract_file.read_text())


def comparable(contract: dict) -> dict:
    keys = ("asset_id", "exists", "exists_reason", "status", "matched_outputs", "corrupt")
    assets = sorted(({k: a.get(k) for k in keys} for a in contract["assets"]), key=lambda a: a["asset_id"])
    verification = {k: v for k, v in contract["verification"].items() if k != "finished_at"}
    preflight = {k: v for k, v in contract["preflight"].items() if k != "checked_at"}
    tasks = sorted(({"task_id": t["task_id"], "status": t["status"]} for t in contract["tasks"]),
                   key=lambda t: t["task_id"])
    return {"assets": assets, "verification": verification, "preflight": preflight, "tasks": tasks,
            "run_status": contract["run"]["status"]}


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: test_run_contract_batch.py <cicd_root>", file=sys.stderr)
        return 1
    cicd_root = Path(sys.argv[1]).resolve()
    mod = load_module(cicd_root)
    tmp = Path(tempfile.mkdtemp(prefix="rc_batch_selftest_"))
    try:
        return _run_tests(mod, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run_tests(mod, tmp: Path) -> int:
    assets, objects, failing = build_fixture(tmp)
    n_assets = len(assets)
    gcs_folders = {a["uri"].rstrip("/").rsplit("/", 1)[0] for a in assets if a.get("uri")}
    check(f"fixture has ~400 assets ({n_assets})", n_assets >= 400)

    old_file = init_contract(mod, tmp, "legacy", copy.deepcopy(assets))
    new_file = init_contract(mod, tmp, "batched", copy.deepcopy(assets))

    old_fake = FakeGCS(objects, failing_folders={failing})
    new_fake = FakeGCS(objects, failing_folders={failing})
    old = comparable(run_finalize(mod, old_fake, old_file, legacy=True))
    new = comparable(run_finalize(mod, new_fake, new_file, legacy=False))

    # 1. identical verification result
    check("per-asset results identical to old behaviour", old["assets"] == new["assets"],
          json.dumps([(o, n) for o, n in zip(old["assets"], new["assets"]) if o != n][:3]))
    check("verification block identical", old["verification"] == new["verification"])
    check("preflight block identical", old["preflight"] == new["preflight"])
    check("task statuses and run status identical",
          old["tasks"] == new["tasks"] and old["run_status"] == new["run_status"])
    statuses = {a["status"] for a in new["assets"]}
    check("fixture is mixed (ok and missing present)", {"ok", "missing"} <= statuses, str(statuses))
    by_id = {a["asset_id"]: a for a in new["assets"]}
    check("denied-folder fallback: present asset ok", by_id["denied/0"]["status"] == "ok")
    check("denied-folder fallback: absent asset missing", by_id["denied/1"]["status"] == "missing")
    check("local paths unchanged", by_id["local/present"]["status"] == "ok"
          and by_id["local/missing"]["status"] == "missing")

    # 2. O(folders) subprocess calls, not O(assets)
    old_calls, new_calls = len(old_fake.calls), len(new_fake.calls)
    print(f"  info: {n_assets} assets, {len(gcs_folders)} gcs folders; "
          f"subprocess calls old={old_calls} new={new_calls} "
          f"(probe={new_fake.count('probe')} ls={new_fake.count('ls')} stat={new_fake.count('stat')})")
    check("gsutil probed once per process", new_fake.count("probe") <= 2)  # preflight + finalize each probe once
    # bound: one ls per folder per command (preflight + finalize) + stats for the
    # single-asset/wildcard/denied-fallback cases + the two probes
    fallback_stats = 3 + 1 + 1  # denied folder assets, single-asset folder, wildcard uri
    bound = 2 * len(gcs_folders) + fallback_stats + 2
    check(f"subprocess calls O(folders): {new_calls} <= {bound}", new_calls <= bound)
    check("old behaviour was O(assets)", old_calls >= n_assets)
    est_new = new_calls * EST_SEC_PER_GSUTIL_CALL
    est_old = old_calls * EST_SEC_PER_GSUTIL_CALL
    print(f"  info: est. wall time at {EST_SEC_PER_GSUTIL_CALL}s/gsutil call: old~{est_old / 60:.1f} min, "
          f"new~{est_new:.0f} s")
    check("estimated finalize+preflight under 2 min", est_new < 120)

    # 3. listing timeout -> unknown, never hang, and no per-asset fallback storm
    to_folder = sorted(f for f in gcs_folders if f.endswith("tile_03"))[0]
    to_file = init_contract(mod, tmp, "timeout", copy.deepcopy(assets))
    to_fake = FakeGCS(objects, failing_folders={failing}, timeout_folders={to_folder})
    to = comparable(run_finalize(mod, to_fake, to_file, legacy=False))
    to_assets = [a for a in to["assets"] if a["asset_id"].startswith("tile_03/")]
    check("timed-out folder assets are unknown",
          all(a["exists"] is None and a["exists_reason"] == "gsutil_timeout" for a in to_assets))
    check("timed-out folder not re-checked asset by asset",
          not any(c[0] == "stat" and c[1].startswith(to_folder + "/") for c in to_fake.calls))

    print("All run_contract batch-verification self-tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
