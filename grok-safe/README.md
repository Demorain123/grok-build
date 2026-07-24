# grok-safe

`grok-safe` is a thin, replayable privacy-hardening layer for the upstream Grok Build source tree.

The design goal is deliberately conservative:

- keep upstream Grok Build source unchanged in Git history;
- keep hardening as a small patch plus auditable wrapper scripts;
- build the hardened binary only in a temporary detached worktree;
- fail closed on known **non-inference egress** paths;
- stop and require review when upstream changes security-sensitive code;
- make updates a risk-gated rebase + patch + compile cycle instead of a long-lived source fork.

## Threat model

This layer addresses the class of behavior disclosed against pre-open-source Grok Build, where repository/session artifacts could be transmitted over a storage channel independently of the model request.

It does **not** make a cloud coding model local. Content intentionally supplied to the selected model still has to reach that inference provider. It also does not magically sandbox tools that you explicitly trust: MCP servers, hooks, plugins, shell commands, web tools and custom model endpoints can have their own network access.

The hardened policy therefore distinguishes:

```text
Required / intentional path
  prompt + model context -> selected inference provider       ALLOWED

Non-inference persistence / auxiliary paths
  /v1/storage, GCS, S3, signed multipart artifacts            BLOCKED
  code.grok.com remote session writeback/share backend        BLOCKED
  product telemetry / Mixpanel                                BLOCKED
  internal + external OTLP export                             BLOCKED
  feedback network submission                                 BLOCKED
  in-app binary replacement/update                            BLOCKED
```

## Architecture

```text
upstream Grok Build source (kept clean)
        |
        | detached temporary worktree
        v
0001-disable-cloud-storage-uploads.patch
        |
        +-- shared storage dispatcher fail-closed
        +-- StorageClient loopback defense
        +-- local-only session persistence
        +-- code.grok.com backend loopback defense
        +-- telemetry / OTLP / feedback fail-closed
        +-- in-app updater fail-closed
        |
        v
cargo check + release build
        |
        v
grok-safe.exe
        |
        +-- isolated GROK_HOME by default
        +-- inherited telemetry/trace endpoints scrubbed
        +-- Claude/Cursor compatibility discovery off by default
        +-- project extension preflight before startup
        +-- provenance + SHA256 emitted with the build
```

The Rust patch is intentionally below configuration precedence. Even if an upstream remote setting, `config.toml`, managed config, or `requirements.toml` would normally enable one of the blocked auxiliary paths, the hardened production binary still rejects it unless a deliberately named `GROK_SAFE_UNSAFE_*` escape hatch is set.

Tests keep upstream telemetry behavior through `cfg!(test)` so upstream unit tests can exercise their normal telemetry code; production hardened binaries default to blocked.

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

instead of `%USERPROFILE%\.grok`, so native Grok hooks, plugins, MCP credentials and session state are isolated from the official installation.

### Extension safety

Before starting Grok, `run.ps1` executes `preflight.ps1`. High-risk project extension surfaces such as project hooks/plugins/MCP declarations stop startup until you explicitly review and allow them:

```powershell
.\grok-safe\scripts\run.ps1 -AllowProjectExtensions
```

Upstream Claude/Cursor compatibility can auto-discover settings outside `GROK_HOME`, so the wrapper disables those compatibility cells by default. Enable them only for a run where you intentionally want and trust those external sources:

```powershell
.\grok-safe\scripts\run.ps1 -AllowVendorCompatibility
```

These overrides do **not** re-enable the hidden storage/session-sync/telemetry channels blocked by the Rust patch.

## Syncing upstream

To inspect and replay the thin safety layer on top of official `upstream/main`:

```powershell
.\grok-safe\scripts\sync-upstream.ps1
```

The sync script is transactional:

1. fetch official `upstream/main` and tags;
2. diff the new upstream range before rebasing;
3. stop before rebase if upload, remote-sync, telemetry, updater, auth-adjacent or dependency/toolchain files changed;
4. after manual review, rerun with:

```powershell
.\grok-safe\scripts\sync-upstream.ps1 -ReviewedRiskyChanges
```

5. rebase;
6. run the full static audit;
7. automatically abort/roll back to the exact pre-sync commit if rebase or post-sync audit fails.

A failed security check must never be treated as a successful update.

## Build provenance

`build.ps1` refuses dirty trees and non-safety branches, applies the patch in a detached worktree, checks every modified crate, links the Windows release, and emits:

```text
grok-safe/dist/
  grok-safe.exe
  grok-safe.exe.sha256
  SOURCE_COMMIT.txt
  PATCH_SHA256.txt
  BUILD_INFO.json
```

`BUILD_INFO.json` records the exact safety branch commit, patch hash, binary hash, Rust/Cargo versions and the blocked-by-default policy.

## Security invariants

A build called `grok-safe` should satisfy all of these:

1. The hardening patch applies cleanly to the exact source commit being built.
2. Shared `upload_bytes`, `upload_bytes_signed`, `upload_file`, and `upload_stream` fail closed before backend selection.
3. Direct `StorageClient` construction cannot reach the real storage proxy in safe mode.
4. Session storage is forced to local and `code.grok.com` writeback is independently redirected to loopback.
5. Product telemetry, Mixpanel, internal OTLP, external OTLP and feedback network submission are blocked in the production binary.
6. The in-app updater cannot replace the hardened executable.
7. New public cloud-upload helpers or direct S3 bypasses stop the audit.
8. Security-sensitive upstream changes stop automatic sync before rebase until explicitly reviewed.
9. Claude/Cursor compatibility discovery is off by default and project extension surfaces are preflighted.
10. Windows CI must run static audit, apply the patch, compile all patched crates and link the hardened executable.

## Deliberate unsafe escape hatches

The Rust patch exposes narrowly scoped escape hatches only for controlled comparison/testing:

```text
GROK_SAFE_UNSAFE_ALLOW_STORAGE_UPLOADS=1
GROK_SAFE_UNSAFE_ALLOW_REMOTE_SYNC=1
GROK_SAFE_UNSAFE_ALLOW_AUX_EGRESS=1
GROK_SAFE_UNSAFE_ALLOW_SELF_UPDATE=1
```

`run.ps1` always forces all four back to `0`. Do not place them in persistent user/system environment variables and do not use them for normal work.

## What remains allowed

Core inference and authentication remain allowed. Official enterprise documentation identifies `cli-chat-proxy.grok.com` (inference/settings) and `auth.x.ai` (OAuth/OIDC) as core hosts, while `code.grok.com` is an additional remote-session feature that can be blocked without breaking core inference.

A file that you let the coding agent read can still be included in the model request. Use a restricted working directory, permission rules/sandboxing, secret hygiene and reviewed extensions in addition to this wrapper.

## Status

This is a hardening project, not an independent security certification. The security model is intentionally fail-closed for the known non-inference paths above, but every upstream change to a security-sensitive area still requires review. A new binary should not be distributed until the Windows guardrail workflow has passed for the exact commit being released.
