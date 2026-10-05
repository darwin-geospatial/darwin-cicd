# Debug Mode — reuse ONE VM, never rebuild to change code (Level-1 MLOps)

> **Iron rule:** a **code-only change MUST NEVER trigger an image rebuild**, and iterating on
> code MUST NEVER require rebooting / recreating a VM. Whole rebuilds cost ~15 min per iteration;
> for a one-line edit that is unacceptable. This is Level-1 MLOps and is enforced by convention
> across every VM pipeline that consumes this submodule.

## The two separations

1. **Deps vs code.** The Docker image carries **dependencies only**. Application code is
   **mounted at runtime** from a GCS "code-stage" over the image's `/app` (`docker run -v …:ro`).
   Rebuild the image **only when dependencies change**.
   - Code-only change → stage `*.py` to `gs://…/code_stage/${BUILD_ID}`, VM mounts it. **No rebuild.**
   - Dep change → rebuild `:latest` once, then go back to code-mount.

2. **Run vs VM lifetime.** A VM does not have to die at the end of a run. In **debug mode** it
   stays RUNNING so the next iteration is a `docker run` on the same box — no reboot, no reprovision.

## `startup_common.sh` primitives

`vm_setup_cleanup_trap()` (installed by `vm_startup_main`) reads two env/placeholder knobs,
resolved in `vm_startup_main` from the per-VM `vm_config_{idx}.env`:

| Knob | Values | Effect |
|------|--------|--------|
| `VM_ON_COMPLETE` / `__VM_ON_COMPLETE__` | `shutdown` (default) \| `keep-alive` | On **success**, hold the VM RUNNING for `VM_DEBUG_TTL` hours instead of shutting down. |
| `VM_ON_FAILURE` / `__VM_ON_FAILURE__` | `shutdown` (default) \| `keep-alive` | On **failure**, hold the VM RUNNING for SSH debugging. |
| `VM_DEBUG_TTL` / `__VM_DEBUG_TTL__` | hours (default `4`) | Safety-net auto-shutdown so a forgotten debug VM can't run for days. |

When held, the trap kills the idle watchdog and schedules a delayed `shutdown`, then `sleep infinity`.

> The reserved GPU is released only when the VM actually shuts down. **Shut a debug VM down when
> you're done** (`sudo shutdown -h now`) so the reservation is freed.

## The iteration loop (project side)

1. **Launch once** with `_VM_ON_COMPLETE: 'keep-alive'`. The VM runs, then stays RUNNING.
2. The VM writes the exact run command (with a **code-resync prefix**) to `/opt/darwin/rerun.sh`.
   The live run executes that same file, so it is the single source of truth for the next rerun.
3. **Edit code locally**, then run the project's rerun helper (e.g.
   `cloudbuild-builds/builders/agent_vm_rerun.sh`). It: pushes the current working-tree `.py` to the
   VM's code-stage bucket → starts the VM if stopped → SSHes in and runs `/opt/darwin/rerun.sh`,
   which re-syncs the mounted code and re-runs docker. **Seconds, not 15 minutes.**

## Wiring a pipeline for debug mode

```yaml
substitutions:
  _BUILD_CODE_IMAGE: 'false'     # skip the rebuild; mount current code over :latest
  _VM_ON_COMPLETE:   'keep-alive'
  _VM_DEBUG_TTL:     '6'
```

```bash
# in the create-vm step's vm_config_{idx}.env writer:
echo "VM_ON_COMPLETE=${_VM_ON_COMPLETE}"
echo "VM_DEBUG_TTL=${_VM_DEBUG_TTL}"
```

`create_multi_vms.sh` applies these as `__VM_ON_COMPLETE__` / `__VM_DEBUG_TTL__` sed replacements
onto the concatenated startup script, exactly like every other `vm_config` key.
