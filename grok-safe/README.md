# grok-safe

`grok-safe` is a thin privacy-hardening layer for the upstream Grok Build source tree.

The design goal is deliberately conservative:

- keep upstream Grok Build source unchanged in Git history;
- keep the hardening as a small, reviewable patch;
- build the hardened binary in a temporary worktree;
- default to **blocking non-inference cloud-storage uploads**;
- make upstream updates a rebase + patch/audit cycle instead of a long-lived source fork.

## Threat model

This layer addresses the class of behavior disclosed against pre-open-source Grok Build 0.2.93, where a separate storage channel could transmit repository/session artifacts independently of the model request.

It does **not** make a cloud coding model local. Content intentionally supplied to the model (for example a file the agent reads and includes in a `/v1/responses` request) still has to reach the selected inference provider. The purpose here is to block the additional cloud-storage/session-trace path (`/v1/storage`, direct GCS/S3 upload helpers, signed multipart storage uploads) unless it is deliberately re-enabled for controlled testing.

## Architecture

```text
upstream Grok Build source (kept clean)
        |
        | temporary worktree
        v
0001-disable-cloud-storage-uploads.patch
        |
        v
cargo build
        |
        v
grok-safe.exe
        |
        +-- isolated GROK_HOME by default
        +-- storage upload override forced OFF
        +-- external OTLP telemetry disabled by launcher
```

The patch has two layers:

1. `xai-file-utils/src/gcs.rs` blocks the shared high-level GCS/S3 upload entry points before any backend is selected.
2. `xai-file-utils/src/storage_client.rs` redirects direct `StorageClient` proxy construction to loopback as defense in depth, so an overlooked/future direct storage client cannot reach the real `/v1/storage` endpoint.

The only escape hatch is the intentionally scary environment variable:

```text
GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS=1
```

The normal `run.ps1` launcher always forces this back to `0`.

## Windows quick start

From the repository root in PowerShell 7:

```powershell
.\grok-safe\scripts\audit.ps1
.\grok-safe\scripts\build.ps1
.\grok-safe\scripts\run.ps1
```

Pass ordinary Grok arguments after `--`:

```powershell
.\grok-safe\scripts\run.ps1 -- -p "Explain this repo"
```

By default the launcher uses:

```text
%USERPROFILE%\.grok-safe
```

instead of `%USERPROFILE%\.grok`, so hooks, plugins, MCP credentials and session state are isolated from the official installation. Set `GROK_SAFE_HOME` to choose another directory.

## Syncing upstream

The safety branch is intended to contain only `grok-safe/` and related audit automation. To catch up with official Grok Build:

```powershell
.\grok-safe\scripts\sync-upstream.ps1
```

The script fetches `xai-org/grok-build`, rebases the current safety branch onto `upstream/main`, then runs the static audit and `git apply --check` for the hardening patch.

If upstream changes the upload subsystem, the patch or audit should fail loudly instead of silently producing an unreviewed binary.

## Security invariants

A release called `grok-safe` should satisfy all of these:

1. The hardening patch applies cleanly to the exact upstream commit being built.
2. Shared `upload_bytes`, `upload_bytes_signed`, `upload_file`, and `upload_stream` entry points fail closed before backend selection.
3. Direct `StorageClient` proxy construction cannot target the upstream storage proxy while safe mode is active.
4. New public upload entry points in `xai-file-utils/src/gcs.rs` fail the audit until manually reviewed.
5. Direct S3 upload calls outside the shared GCS dispatcher fail the audit.
6. The launcher uses an isolated home and disables external OTLP telemetry by default.

## What remains allowed

Core inference traffic remains allowed. Otherwise Grok Build could not use Grok 4.5 or another cloud model.

This means a file that you explicitly let the coding agent read may still be serialized into the model request. Use Grok Build permission rules, a restricted working directory, and secret hygiene in addition to this wrapper.

## Status

This is an initial hardening layer, not an independent security certification. Re-run the audit after every upstream sync and review any newly introduced network/upload code before distributing a new binary.
