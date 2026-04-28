# CRATE

**CRATE Runs Agents in Temporary Environments.**

Run an AI coding agent — [Claude Code](https://github.com/anthropics/claude-code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), or [OpenAI Codex](https://github.com/openai/codex) — inside a disposable sandbox (a Podman container, a throwaway Podman VM, or a throwaway WSL distro) so the agent's "skip all permission prompts" mode can be used without giving it access to your host.

The current working directory is mounted into the sandbox at `/var/workdir` and becomes the agent's scratch space. Everything else on the host is invisible.

## Why

`claude --dangerously-skip-permissions`, `gemini --yolo`, and `codex --dangerously-bypass-approvals-and-sandbox` all skip tool-use prompts. That is convenient but gives the agent unrestricted shell access to whatever it can reach. Running it inside a fresh, short-lived sandbox contains the blast radius: the agent sees only the project directory you mounted and a minimal pre-baked toolchain, and the sandbox is discarded at exit.

## Supported agents

Selected with `--agent NAME` (default: `claude`). Each agent is defined declaratively in `agent/<name>/manifest.json` — no per-agent shell code.

| Agent | `--agent` value | Project dir | Host config dir |
|-------|-----------------|-------------|-----------------|
| Claude Code  | `claude` (default) | `.claude`  | `$CLAUDE_CONFIG_DIR` or `~/.claude`  |
| Gemini CLI   | `gemini`           | `.gemini`  | `~/.gemini`                          |
| OpenAI Codex | `codex`            | `.codex`   | `$CODEX_HOME` or `~/.codex`          |

## What you get inside the sandbox

A user `agent` with `$HOME/.local/bin` on `PATH` containing:

- `node` (Node.js LTS)
- `rg` (ripgrep)
- `micro` (editor, set as `$EDITOR`)
- `pnpm`
- `uv`, `uvx`
- The chosen agent under its native command name (`claude` / `gemini` / `codex`), implemented as a wrapper that execs the real binary with the agent's permission-skip flags and env vars baked in.

Optional: pass `--allow-dnf` (POSIX) or `-AllowDnf` (PowerShell) to enable `sudo dnf` inside the sandbox for installing extra packages during a session. This flag must be provided at sandbox startup; if omitted, the bootstrap permission is revoked before the agent starts to prevent autonomous privilege escalation. Requires a Fedora-based image (the default), which on the podman-machine backend means Fedora CoreOS 43+ (earlier FCOS releases lacked `/usr/bin/dnf`).

## Sandbox backends

Four launcher scripts, same flags, same result — pick whichever matches your host:

| Script                        | Host            | Isolation                                                                         |
| ----------------------------- | --------------- | --------------------------------------------------------------------------------- |
| `script/podman-container.sh`  | Linux / macOS   | Podman container, rootless, `--userns=keep-id`                                    |
| `script/podman-machine.sh`    | Linux / macOS   | Fresh Podman VM per session, destroyed on exit                                    |
| `script/podman-container.ps1` | Windows (WSL 2) | Podman container via Podman Desktop / WSL backend                                 |
| `script/wsl.ps1`              | Windows (WSL 2) | Fresh WSL distro per session imported from the Podman image, unregistered on exit |

## Usage

From the directory you want to expose to the agent:

```sh
# Linux / macOS — container (default agent: claude)
/path/to/crate/script/podman-container.sh

# Same, but pick a different agent
/path/to/crate/script/podman-container.sh --agent gemini
/path/to/crate/script/podman-container.sh --agent codex

# Linux / macOS — fresh VM per session
/path/to/crate/script/podman-machine.sh --agent claude

# Windows — container
& C:\path\to\crate\script\podman-container.ps1 -Agent gemini

# Windows — fresh WSL2 distro per session
& C:\path\to\crate\script\wsl.ps1 -Agent codex
```

All scripts accept:

| Flag (sh)         | Flag (ps1)      | Meaning                                                         |
| ----------------- | --------------- | --------------------------------------------------------------- |
| `--agent NAME`    | `-Agent NAME`   | Which agent to launch: `claude` (default), `gemini`, `codex`    |
| `--base-hash H`   | `-BaseHash H`   | Pin Tier-1 archive to a cached hash prefix (skip version fetch) |
| `--tool-hash H`   | `-ToolHash H`   | Pin Tier-2 archive                                              |
| `--agent-hash H`  | `-AgentHash H`  | Pin Tier-3 (agent) archive                                      |
| `--force-pull`    | `-ForcePull`    | Ignore caches, re-download and rebuild                          |
| `--image IMG`     | `-Image IMG`    | Override base OS container image (default `fedora:latest`). Container/WSL backends only — `podman-machine.sh` does not accept this flag because `podman machine init --image` expects a Podman machine image (qcow2/raw path or `stable`/`testing` stream label), not a container reference. Use `--machine-image` for that backend. |
| `--allow-dnf`     | `-AllowDnf`     | Grant `agent` passwordless `sudo dnf` inside the sandbox        |
| `--new-session`   | `-NewSession`   | Force a fresh session id, even when an abandoned session is reclaimable. Mutually exclusive with `--session`. |
| `--session ID`    | `-Session ID`   | Claim a specific session id (8 lowercase base36 chars). Fails if the named session is currently live. Use to resume a known-good session deterministically. |
| `--log-level LVL` | `-LogLevel LVL` | Logging threshold: `I` (verbose info), `W` (warn+error, default), `E` (error only). Default keeps successful launches quiet — pass `--log-level I` for full progress output. Forwarded to every child process via explicit `--log-level` args. |

`podman-machine.sh` additionally takes `--cpus`, `--memory`, `--disk-size`, `--machine-image` (forwarded to `podman machine init`) and `--stop-others` (stop any conflicting running machine automatically — see Caveats). `--machine-image` accepts what `podman machine init --image` accepts: a path/URL to a Podman machine disk image, or a stream label like `stable`/`testing`. Default is whatever `podman machine init` picks (Fedora CoreOS today).

## How it works

### Three-tier tool cache

`lib/tools.sh` and `lib/Tools.ps1` build three content-addressed `.tar.xz` archives under `$XDG_CACHE_HOME/crate/tools/` (or `%LOCALAPPDATA%\.cache\crate\tools\` on Windows). Compression is xz level 0 multi-threaded (`-0 -T0`) — `-0` is the smallest preset that still enables threaded LZMA2, trading a few MB of extra size for a ~5-10× pack speedup vs `-6`/`-9` while still beating gzip `-9` on ratio:

1. **base** — `node` + `rg` + `micro`. Hash keyed on each tool version. Shared across all agents.
2. **tool** — `pnpm` + `uv` + `uvx`. Hash keyed on their versions. Shared across all agents.
3. **`<agent>`** — the selected agent's binary (platform binary unpacked from npm, or a node-bundle shim that execs the main JS via `node`), plus the generic `agent-wrapper` under the agent's command name, plus a baked `agent-manifest.sh` that sources the agent's launch flags and env vars. Hash keyed on the agent name, npm version, arch, manifest contents, and wrapper source.

Archive filenames: `base-<hash>.tar.xz`, `tool-<hash>.tar.xz`, `<agent>-<hash>.tar.xz`. Cache is reusable across sessions; `--force-pull` rebuilds and `--{base,tool,agent}-hash` pins to an existing cached hash prefix so you can freeze a known-good toolchain without network access.

Tier 3 uses the same npm `optionalDependencies` platform-sub-package pattern that esbuild pioneered, so **all three agents share one fetch path**. Claude and Codex publish platform-specific tarballs containing an ELF binary; Gemini publishes a JS bundle consumed via `node`. The manifest's `executable.type` (`platform-binary` / `node-bundle`) selects the post-extract path; `tarballUrl` is a template with `{arch}`, `{triple}`, and `{version}` placeholders.

### Declarative agent manifests

Each agent's shape is described in `agent/<name>/manifest.json`:

- `projectDir` — per-agent staging dir (`.claude`, `.gemini`, `.codex`). The sandbox's system-scope config lives in `$PWD/<projectDir>/.system/`.
- `configDir` — where the agent reads its config on the host (respecting env-var overrides like `CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
- `files.rw` / `files.ro` / `files.roDirs` — which host files hardlink into the sandbox vs. copy read-only.
- `credential.strategy` — selects an OAuth refresh handler (`oauth-anthropic`, `oauth-google`, or `oauth-openai`), wired through `lib/cred/<strategy>.sh` and its PowerShell mirror.
- `credential.file` — the auth file under `configDir` that the strategy reads/refreshes (e.g. `.credentials.json`, `oauth_creds.json`, `auth.json`). Must also be listed in `files.rw` so the sandbox sees the refreshed tokens via the hardlink. Named explicitly so a `files.rw` reorder can't silently change which file gets refreshed.
- `executable` — npm package name, tarball URL template, bin/entry path inside the tarball.
- `launch.flags` / `launch.env` — baked into the tier-3 archive as `agent-manifest.sh`, sourced by the wrapper at startup.

Adding a fourth agent is a matter of dropping a new `agent/<name>/` directory with a manifest and a matching `lib/cred/<strategy>.sh` if the OAuth flow is new.

### Sandbox bootstrap

`Containerfile` builds a minimal Fedora image with an `agent` user, `sudo`, and a guarded `enable-dnf` helper. It does not bake any tooling or agent into the image. Instead, its `ENTRYPOINT` invokes `bin/setup-tools.sh`, which extracts the three archives mounted at `/tmp/{base,tool,agent}.tar.xz` into `$HOME/.local/bin` (with node-bundle `<agent>-pkg/` dirs relocated to `$HOME/.local/lib/`), sources the baked `agent-manifest.sh` to learn which agent to exec, and launches the wrapper. The same script is used by the VM and WSL2 backends to set up the toolchain after archive injection.

This keeps the image itself small, stable, and agent-agnostic — toolchain and agent upgrades happen in the cache, not in the image.

### Credentials and global config

`script/ensure-credential.sh` / `script/Ensure-Credential.ps1` are thin dispatchers that source the agent's OAuth strategy from `lib/cred/<strategy>.sh` (or `.ps1`). Each strategy reads the agent's auth file, refreshes if near expiry, and writes the updated tokens back in-place — so the hardlink in the rw/ bucket propagates the new tokens to the sandbox without needing to restart. They live under `script/` because they're useful as standalone CLIs too: run `script/ensure-credential.sh --agent claude` to refresh tokens without launching a sandbox.

| Agent | Auth file | Refresh endpoint | Strategy |
|-------|-----------|------------------|----------|
| Claude | `~/.claude/.credentials.json` | `platform.claude.com/v1/oauth/token` | `oauth-anthropic` |
| Gemini | `~/.gemini/oauth_creds.json`  | `oauth2.googleapis.com/token`        | `oauth-google`    |
| Codex  | `~/.codex/auth.json`          | `auth.openai.com/oauth/token`        | `oauth-openai`    |

All three strategies use the same shape: a live GET probe (Anthropic's `claude_cli/roles`, Google's `oauth2/v3/userinfo`, OpenAI's `auth.openai.com/oauth/userinfo`) — 200 = valid, 401 = refresh. This tolerates host-clock skew and avoids timestamp math. Codex's `tokens.id_token` is stored on disk as the raw JWT string (Codex parses the struct fields out of it at load time per `codex-rs/login/src/token_data.rs`), so we write the new JWT verbatim — no re-decoding.

If an auth file is missing, you are told to use the corresponding CLI (`claude`, `gemini`, or `codex`) on the host once to log in.

Gemini's refresh flow needs a `client_id` + `client_secret` pair to call Google's token endpoint. These are checked in at `agent/gemini/oauth.json` and copied verbatim from the upstream Gemini CLI distribution. They are **public OAuth client credentials**, not real secrets — per [RFC 8252](https://datatracker.ietf.org/doc/html/rfc8252) and Google's installed-app docs, the credentials identify the client application, not the user, and are intentionally embedded in the redistributable. They have no privileged scope on their own; user tokens are still required to access any user data. If Google ever rotates them upstream, mirror the new values here.

### Config staging

`lib/init-config.sh` / `lib/Init-Config.ps1` read the file lists from the selected manifest and stage them into the project, under `$PWD/<projectDir>/.system/`. The staging dir has four buckets:

- `ro/` — **copies** of read-only files and directories from the manifest's `files.ro` and `files.roDirs` (recursively). Wiped + re-copied on every launch, so any in-session tampering is undone and upstream deletions propagate. Even if the read-only mount were bypassed, writes cannot reach the host because the copies are independent inodes. Shared across sessions in the same workdir.
- `rw/` — **hardlinks** to writable files from the manifest's `files.rw`. They share an inode with the agent's config dir on the host, so in-place writes inside the sandbox propagate back immediately. Wiped + re-linked every launch (so removing or renaming a `files.rw` entry doesn't leave a stale hardlink — including stale credential aliases — pointing at host config). Shared across sessions in the same workdir.
- `sessions/<id>/cr/` — **per-session runtime state** created by the agent (history, locks, mutable settings). Each launch resolves a session id (see "Sessions" below); `cr/` for that id is bind-mounted as the base of the agent's config dir. Persists across launches and is not deleted on exit, so a crashed launch can be reclaimed by the next launch. No speculative subdirs are pre-created — the agent `mkdir`s whatever it needs on demand. The only entries we touch in `cr/` are mount-target placeholders for the per-file/per-subdir overlays.
- `sessions/<id>/owner` — KV-format metadata recorded at claim time, one `key=value` per line. Fields (newlines in values are collapsed to spaces):
  - `pid` — the launcher's pid; the human-readable handle for the owner.
  - `start` — the launcher's process start token (`/proc/<pid>/stat` field 22 on Linux, `ps -o lstart=` on macOS, `Process.StartTime.ToFileTimeUtc()` on Windows). Recorded so liveness can require **pid + start + cmd** all three — same identity tuple the VM/distro state markers use to defeat PID reuse.
  - `cmd` — the launcher's full command line, captured from `/proc/<pid>/cmdline` (POSIX) or `Win32_Process.CommandLine` (Windows). Used together with `pid` and `start` for liveness; a session is "alive" iff its recorded pid is currently running with the recorded start time and cmdline. Any of the three failing marks the session as abandoned.
  - `ppid`, `ppid_start`, `ppid_cmd` — parent process identity (the shell that launched). Same per-platform sourcing as `start`. Drive the 7-tier match ladder used for default-mode reclaim (see Sessions below).
  - `cwd`, `user`, `host` — the launch's working directory, username, and hostname. Together with the three `ppid*` fields these form the 6-field "context" the tier ladder scores against.
  - `created` — first-claim epoch (Unix seconds). Set when the session id is first claimed and **preserved verbatim across reclaim** so it stays the session's birth time. Used as the within-tier tiebreak: when multiple abandoned sessions match the same tier, the oldest `created` wins.
- `.mask/` — an empty dir, used purely as the bind source that masks `.system/` from project scope inside the sandbox. Shared across sessions.

**Inside the sandbox** the launchers assemble all four buckets at the agent's in-sandbox config dir. The path depends on whether the agent honors a config-dir env var:

| Agent | In-sandbox path | How the agent finds it |
|-------|-----------------|------------------------|
| Claude | `/usr/local/etc/crate/claude` | wrapper exports `CLAUDE_CONFIG_DIR` |
| Codex  | `/usr/local/etc/crate/codex`  | wrapper exports `CODEX_HOME` |
| Gemini | `/home/agent/.gemini`         | hard-coded default (no env var supported) |

The env-var route keeps `/home/agent` clean of agent-specific state and makes the sandbox path identical across the container (agent user) and podman-machine (core user) backends. Gemini doesn't expose a config-dir env var, so its staging is bind-mounted directly at the hard-coded `~/.gemini` path (rewritten to `/home/core/.gemini` on the VM backend).

Assembly is the same in both cases:

1. `sessions/<id>/cr/` is bind-mounted as the base of the target (rw — runtime writes land back in the resolved session's `cr/`)
2. each writable file in `rw/` is bind-mounted on top per-file, so the path becomes a mount point — `rename()`/`unlink()` give EBUSY and the agent's atomic-replace code path falls back to in-place `writeFileSync()`, which preserves the host hardlink and syncs changes immediately
3. each `ro/` file and subdir is bind-mounted on top read-only via `mount --bind` + `mount -o remount,bind,ro`
4. `.mask/` is bind-mounted (read-only) on top of `/var/workdir/<projectDir>/.system` so the system bucket is **invisible from project scope**: anything reading under `/var/workdir/<projectDir>/` sees an empty `.system/` while the agent's config dir continues to serve real content.

The atomic-rename → writeFileSync fallback matters because rename semantics differ across drvfs (WSL2), virtiofs (Podman machine), and overlayfs/bind mounts — EBUSY forces a code path that is portable everywhere.

### Sessions

Each launch resolves an 8-character base36 session id and uses it as both the backend identity (VM/distro name suffix) and the path under `<projectDir>/.system/sessions/<id>/`. This keeps same-agent concurrent launches in one workdir from sharing runtime state — each gets its own `cr/` for history, locks, and mutable settings.

Resolution modes (mutually exclusive flags):

| Mode | Flag | Behavior |
|------|------|----------|
| Default (reclaim) | *(none)* | Match every abandoned session in the workdir against the current launcher's identity on a **7-tier ladder** (see below). The most-specific tier wins; within a tier, the **oldest `created` timestamp** breaks ties. Tier 7 is the catch-all, so default mode always reclaims something when any abandoned session exists. |
| Force new | `--new-session` / `-NewSession` | Always generate a new id, never reclaim. |
| Explicit | `--session ID` / `-Session ID` | Claim a specific id regardless of identity match. Fails if that session is currently live — i.e. its recorded `pid` is still running and the process at that pid has the recorded `start` and `cmd`. |

#### Reclaim tiers

At launch time the launcher captures six identity fields — `ppid`, `ppid_start`, `ppid_cmd`, `cwd`, `user`, `host` — and scores each abandoned session's recorded fields against them. The fields are arranged on a stability ladder (most-stable → most-volatile: `host > user > cwd > ppid_cmd > ppid_start > ppid`); the rightmost mismatch determines the tier. Lower tier number = stronger match.

| Tier | What still matches | Typical scenario |
|------|--------------------|------------------|
| 1 | all six (exact) | re-run in the same shell instance / same tab |
| 2 | everything except `ppid` | parallel launches with otherwise-identical context |
| 3 | + `ppid_start` differs | closed the terminal tab, opened a new one running the same shell program |
| 4 | + `ppid_cmd` differs | switched shell program (bash → zsh) or terminal host (xterm → IDE terminal) |
| 5 | only `user` + `host` match | the project directory was moved/renamed under you (`.system/` traveled with it) |
| 6 | only `host` matches | another local user is reclaiming this session |
| 7 | nothing matches | reclaim across hosts (project on a network share, accessed from a different machine) |

Within a tier, the session whose **`created` timestamp is earliest** wins. Long-lived sessions accumulate more agent context (history, mutable settings) and are usually the "main thread of work" you want to resume; short-lived side trips lose the tiebreak.

> **Tiers 6 and 7 are intentional but cross-boundary.** A tier-6 reclaim attaches your launcher to a session's `cr/` runtime state that was written by a *different local user* — chat history and mutable agent config flow into your sandbox even though `rw/` / `ro/` config and credentials still come from your home directory. A tier-7 reclaim does the same across hosts, where binary references inside `cr/` may have been captured on a different OS or architecture. Both are useful on shared dev boxes and NFS-mounted projects (the original use cases that motivated keeping these tiers in the ladder), but if it's not what you want, pass `--new-session` to force a fresh id.

To list every session in the current workdir (alive and abandoned, all agents), run `script/list-sessions.sh` (POSIX) or `script/List-Sessions.ps1` (Windows); pass `--agent NAME` / `-Agent NAME` to filter, or `--columns id,agent,state,created,age,cwd` to surface the fields the tier ladder uses.

Session dirs are never deleted automatically. After a launch ends — whether cleanly or via crash/`kill -9` — its `cr/` contents stay on disk and `owner` holds the now-dead pid. To clean up accumulated session dirs, remove them under `<projectDir>/.system/sessions/` manually.

- **Container scripts** assemble everything directly via podman `-v` flag stacking — no in-container privileges required.
- **podman-machine.sh** mounts only the workdir into the VM, then runs `bin/setup-system-mounts.sh` as root over SSH to do steps 1–4.
- **wsl.ps1** mounts only the workdir via `drvfs`, then runs `bin/setup-system-mounts.sh` as root (baked into `/usr/local/libexec/crate/setup-system-mounts.sh` during the import block).

The agent itself is launched as the unprivileged user `agent` — sudo is used solely for the mount syscalls on the VM/WSL backends. The wrapper exports each agent's config-dir env var (baked into the tier-3 `agent-manifest.sh`) so the binary reads from `/usr/local/etc/crate/<agent>` — except for Gemini, which has no such env var and reads from the `~/.gemini` default mount.

> **Supported hosts:** Linux, macOS, and Windows.

The single `$PWD → /var/workdir` mount on the VM/WSL backends is what avoids the macOS vfkit virtio-fs bug where a `mount --bind` whose target sits under a `mount -o remount,ro,bind` virtio-fs parent makes `open()` return EACCES for non-root processes (containers/podman#24725, FB16008360). All binds in this layout have source and target on the same device.

> **Tip:** add `<projectDir>/.system/` to your project `.gitignore` (e.g. `.claude/.system/` when running Claude, `.gemini/.system/` for Gemini, `.codex/.system/` for Codex). That bucket contains your hardlinked credentials and per-project session history — none of it belongs in commits. The launcher warns if the relevant pattern is missing.

Concurrent runs in the same project do not collide: different agents have independent `.system/` directories, and same-agent parallel launches each get their own `sessions/<id>/cr/` (see the Sessions table above).

### Lifecycle

- **Container scripts** — `podman run --rm` with the three archives, the workdir, and the per-file/per-subdir `-v` mounts assembling the agent's config dir. Dies with the session; the project's `<projectDir>/.system/` (including the session's `cr/`) persists by design.
- **podman-machine.sh** — uses the resolved session id for the VM name (`crate-<agent>-<id>`, fits macOS Podman's 30-char cap), inits a fresh VM with a single `$PWD → /var/workdir` virtio-fs volume, runs `bin/setup-system-mounts.sh` over SSH (passing `--session-id`), injects the three tool archives, runs `bin/setup-tools.sh`, then execs the agent as `core`. An `EXIT` trap stops and removes the machine no matter how the session ends; the session's `cr/` on the host stays put.
- **wsl.ps1** — uses the resolved session id for the distro name (`crate-<agent>-<id>`), imports the Podman base image as a WSL tarball, runs `bin/setup-tools.sh` as `agent` (so `/home/agent/.local/{bin,lib}` stays writable by the runtime user — matching the container and podman-machine backends), bakes `setup-system-mounts.sh` into the distro at a stable path as root, installs `config/wsl.conf`, mounts the workdir via `drvfs`, runs the in-distro mount setup (with `--session-id`), and execs the agent. Every launch imports a fresh distro; a `finally` block unregisters it on exit so no distro state persists between sessions, while the session's `cr/` on the host stays put. Per-session naming means parallel launches in the same project do not race on a shared distro/VM identity.

## Requirements

- **Linux/macOS:** `podman`, `curl`, `jq`, `rg` (ripgrep), `tar` (GNU ≥ 1.22 or bsdtar), `xz` (XZ Utils ≥ 5.2 for `-T0` multi-threaded compression), `sha256sum` (or `shasum`). For `podman-machine.sh`, a working `podman machine` provider (qemu/applehv/hyperv).
- **Windows:** PowerShell 7+, `podman` (Podman Desktop is fine), `tar.exe` (ships with modern Windows — bsdtar with liblzma), and WSL2 for `wsl.ps1`.
- **Windows path requirements:** the working directory, the CRATE checkout, and `XDG_CACHE_HOME` (if set) must each live on a drive-letter path (e.g. `C:\…`). UNC paths (`\\server\share\…`, `\\wsl$\…`, `\\?\…`) are rejected up front — drvfs only auto-mounts drive letters into the WSL distro, so a UNC source path would not be reachable from inside the sandbox. Move the affected directory to a drive-letter location and rerun.
- A prior login on the host for the agent you plan to use, so its auth file exists (`~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`, or `~/.codex/auth.json`).

## Caveats

- The agent's permission-skip mode is still dangerous *inside* the sandbox — the agent can freely trash `/var/workdir`, which is your real project directory. Commit or stash first if that matters to you.
- Only `linux/amd64` and `linux/arm64` tool archives are built.
- `podman-machine.sh` refuses to launch when another podman machine is already running (Podman supports only one VM at a time) and prints which machine is in the way. Pass `--stop-others` to stop the conflicting machine automatically; the launcher does not restart anything on exit, so you'll need to `podman machine start <name>` your previous machine yourself afterward.
- The Gemini CLI has started moving OAuth tokens into the OS keychain on systems where one is available. This sandbox only understands the file-based `~/.gemini/oauth_creds.json` path; if your Gemini install stores tokens in the keychain instead, refresh will fail and you'll need to run `gemini` on the host first to populate the file.
