# grok-safe

`grok-safe` is a thin, replayable privacy-hardening layer for upstream Grok Build.

The goal is deliberately narrow: keep normal Grok Build behavior (models, MCP, hooks, plugins, skills, shell/web tools and user configuration) while failing closed on known **Grok-owned non-inference egress** paths that can persist, replicate, analyze, or upload local/session data independently of the model request.

## Threat model

This project addresses the class of behavior disclosed against pre-open-source Grok Build where repository/session artifacts could be transmitted through a storage path independently of the model inference request.

It does **not** make a cloud coding model local. Files intentionally read and included in model context can still leave the machine as part of inference. Explicit MCP servers, hooks, plugins, shell commands, web tools, remote sandboxes and custom model endpoints can also use the network by design.

```text
Normal / intentional behavior
  prompt + model context -> selected inference provider       ALLOWED
  native/user/project MCP servers                             ALLOWED
  hooks/plugins/skills/shell/web tools                        ALLOWED
  existing ~/.grok config and credentials                     ALLOWED

Grok-owned non-inference persistence / auxiliary paths
  /v1/storage, GCS, S3, signed/multipart artifacts            BLOCKED
  workspace/session artifact upload queue                     BLOCKED at shared upload layer
  code.grok.com remote session writeback/share backend        BLOCKED
  cli-chat-proxy cross-host SessionRegistry replication       BLOCKED
  product telemetry / Mixpanel                                BLOCKED
  Grok internal + external OTLP export                        BLOCKED
  feedback + session signals / per-turn analytics             BLOCKED
  remote memory embedding text -> /embeddings                 BLOCKED
  in-app binary replacement/update                            BLOCKED
```

## Architecture

The official source stays unchanged in Git history. Hardening lives in ordered patches plus wrapper/audit scripts and is applied only inside a temporary detached worktree during build:

```text
upstream-compatible source
        |
        v
0001 storage/writeback/telemetry/update
0002 feedback/session-signals/turn-deltas
0003 SessionRegistry cross-host replication
0004 remote memory embedding
        |
        v
Windows release build + smoke test
        |
        v
grok-safe.exe
```

`audit.ps1` and `audit-egress-boundaries.ps1` also stop builds when reviewed upload/network boundaries drift, including workspace upload/recovery paths.

## Windows quick start

From the repository root in PowerShell 7:

```powershell
.\grok-safe\scripts\audit.ps1
.\grok-safe\scripts\audit-egress-boundaries.ps1
.\grok-safe\scripts\build.ps1
```

A successful build ends with:

```text
Hardened build completed.
```

Launch through the wrapper, not the EXE directly:

```powershell
.\grok-safe\scripts\run.ps1
```

Pass ordinary Grok arguments after `--`:

```powershell
.\grok-safe\scripts\run.ps1 -- -p "Explain this repo"
.\grok-safe\scripts\run.ps1 -- inspect
.\grok-safe\scripts\run.ps1 -- mcp list
.\grok-safe\scripts\run.ps1 -- mcp doctor
```

### Normal MCP / extension behavior

Normal mode deliberately uses the same user home as official Grok:

```text
%USERPROFILE%\.grok
```

That means existing user-level MCP servers, model configuration, credentials, plugins and preferences continue to work. Project `.grok/config.toml` and project MCP configuration are also retained.

The preflight prints notices when it sees MCP/hooks/plugins so you know which explicit extension surfaces are present, but **MCP does not block startup by default**.

For an unusually sensitive test run you can opt into a separate home:

```powershell
.\grok-safe\scripts\run.ps1 -IsolatedHome
```

This uses `%USERPROFILE%\.grok-safe` (or `GROK_SAFE_HOME` when set).

You can also opt into stricter extension isolation:

```powershell
.\grok-safe\scripts\run.ps1 -StrictExtensionIsolation
```

Strict mode disables Claude/Cursor compatibility discovery for that run and can stop on executable project hook/plugin surfaces. After review, explicitly acknowledge them with `-AllowProjectExtensions`; `-AllowVendorCompatibility` keeps vendor compatibility enabled even during a strict run.

These extension switches never re-enable the hidden storage/session-sync/telemetry paths blocked by the Rust patches.

## Why the wrapper matters

`run.ps1`:

- verifies the built EXE against its SHA256/build manifest;
- forces the reviewed storage/session/analytics escape hatches to `0`;
- keeps session persistence local and disables the remote code-session backend;
- disables Grok-owned telemetry/feedback/OTLP configuration;
- **does not modify generic `OTEL_*` environment variables**, because MCP/hooks/shell child processes may legitimately depend on them;
- keeps normal MCP/hooks/plugins and the official Grok home by default.

Do not use `grok-safe/dist/grok-safe.exe` as the normal launch path; the wrapper is part of the policy boundary.

## Memory behavior

Upstream memory is experimental and disabled by default. When enabled, local memory and FTS search remain available. `grok-safe` declines construction of the remote embedding provider so memory chunks are not sent to a separate `/embeddings` endpoint; semantic vector search therefore falls back to local FTS behavior.

## Updating from upstream

Run:

```powershell
.\grok-safe\scripts\sync-upstream.ps1
```

The sync script:

1. fetches official `upstream/main` and tags;
2. checks which upstream paths changed;
3. stops before rebase when storage, workspace upload/recovery, remote session, registry, feedback, memory, telemetry, updater, HTTP, dependencies or toolchain boundaries changed;
4. after review, continue with:

```powershell
.\grok-safe\scripts\sync-upstream.ps1 -ReviewedRiskyChanges
```

5. rebases the thin safety layer;
6. reruns the security audits;
7. automatically resets to the exact pre-sync commit if post-rebase audit fails;
8. never pushes automatically.

## Build provenance

`build.ps1` refuses dirty trees and non-safety branches, applies every patch in lexical order, validates the patched source, links the Windows release, smoke-tests the binary, and emits:

```text
grok-safe/dist/
  grok-safe.exe
  grok-safe.exe.sha256
  SOURCE_COMMIT.txt
  PATCH_SHA256.json
  BUILD_INFO.json
```

The wrapper verifies the binary hash before launch. This detects accidental/stale replacement; it is not a substitute for independent code signing or an external security audit.

## Security invariants

A releasable build should satisfy all of these:

1. Every hardening patch applies to the exact reviewed source context.
2. Shared `upload_bytes`, `upload_bytes_signed`, `upload_file`, and `upload_stream` fail closed before backend selection.
3. Direct `StorageClient` construction cannot reach the real storage proxy in safe mode.
4. Remote session writeback and `code.grok.com` synchronization are disabled while local sessions remain available.
5. `SessionRegistryClient` cannot write cross-host replicas.
6. Product telemetry, Mixpanel, Grok OTLP, feedback/session signals and per-turn analytics are blocked.
7. Remote memory embedding text is blocked; local FTS memory remains available.
8. The in-app updater cannot replace the hardened executable.
9. Workspace upload/recovery continues to funnel through the guarded shared upload layer; new direct HTTP/cloud SDK sinks fail audit.
10. Normal MCP/hooks/plugins remain available by default; strict extension isolation is opt-in.
11. Generic child-process `OTEL_*` environment is not globally disabled by the wrapper.
12. Windows CI must pass static audits, build the final `xai-grok-pager-bin --release`, and smoke-test the produced EXE for the exact commit.

## Deliberate test escape hatches

The patches retain narrowly named `GROK_SAFE_UNSAFE_*` environment variables for controlled comparison/testing. `run.ps1` always forces them to `0`, so they are not part of normal use. Do not launch the EXE directly with those variables enabled.

## Status

This is a hardening project, not an independent security certification. A commit is not release-ready until the Windows guardrail workflow passes for that **exact commit**. Every upstream change to a security-sensitive area still requires review.
