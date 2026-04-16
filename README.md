# Claude Code Sandbox

Run [Claude Code](https://github.com/anthropics/claude-code) inside a disposable sandbox — a Podman container, a throwaway Podman VM, or a throwaway WSL distro — so `--dangerously-skip-permissions` can be used without giving the agent access to your host.

The current working directory is mounted into the sandbox at `/var/workdir` and becomes Claude's scratch space. Everything else on the host is invisible.

## Why

`claude --dangerously-skip-permissions` skips all tool-use prompts. That is convenient but gives the agent unrestricted shell access to whatever it can reach. Running it inside a fresh, short-lived sandbox contains the blast radius: the agent sees only the project directory you mounted and a minimal pre-baked toolchain, and the sandbox is discarded at exit.

## What you get inside the sandbox

A user `claude` with `$HOME/.local/bin` on `PATH` containing:

- `node` (Node.js LTS)
- `rg` (ripgrep)
- `micro` (editor, set as `$EDITOR`)
- `pnpm`
- `uv`, `uvx`
- `claude` → wrapper that execs the real Claude Code binary (`claude-bin`) with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1`

Optional: pass `--allow-dnf` (POSIX) or `-AllowDnf` (PowerShell) to enable `sudo dnf` inside the sandbox for installing extra packages during a session. This flag must be provided at sandbox startup; if omitted, the bootstrap permission is revoked before the agent starts to prevent autonomous privilege escalation. Requires a Fedora-based image (the default).

## Sandbox backends

Four launcher scripts, same flags, same result — pick whichever matches your host:

| Script                        | Host            | Isolation                                                                         |
| ----------------------------- | --------------- | --------------------------------------------------------------------------------- |
| `script/podman-container.sh`  | Linux / macOS   | Podman container, rootless, `--userns=keep-id`                                    |
| `script/podman-machine.sh`    | Linux / macOS   | Fresh Podman VM per workdir, destroyed on exit                                    |
| `script/podman-container.ps1` | Windows (WSL 2) | Podman container via Podman Desktop / WSL backend                                 |
| `script/wsl.ps1`              | Windows (WSL 2) | Fresh WSL distro per workdir imported from the Podman image, unregistered on exit |

Supported hosts are Linux, macOS, and Windows (WSL 2).

The Podman container scripts keep the sandbox process-scoped. The `podman-machine` and `wsl` scripts go further and throw away an entire VM/distro at the end of the session — heavier, but the strongest isolation the host can provide short of a separate machine.

## Usage

From the directory you want to expose to Claude:

```sh
# Linux / macOS — container (requires a running 'podman machine' on macOS)
/path/to/claude-code-sandbox/script/podman-container.sh

# Linux / macOS — fresh VM per session
/path/to/claude-code-sandbox/script/podman-machine.sh

# Windows — container
& C:\path\to\claude-code-sandbox\script\podman-container.ps1

# Windows — fresh WSL2 distro per session
& C:\path\to\claude-code-sandbox\script\wsl.ps1
```

All scripts accept:

| Flag (sh)         | Flag (ps1)      | Meaning                                                         |
| ----------------- | --------------- | --------------------------------------------------------------- |
| `--base-hash H`   | `-BaseHash H`   | Pin Tier-1 archive to a cached hash prefix (skip version fetch) |
| `--tool-hash H`   | `-ToolHash H`   | Pin Tier-2 archive                                              |
| `--claude-hash H` | `-ClaudeHash H` | Pin Tier-3 archive                                              |
| `--force-pull`    | `-ForcePull`    | Ignore caches, re-download and rebuild                          |
| `--image IMG`     | `-Image IMG`    | Override base OS image (default `fedora:latest`)                |
| `--allow-dnf`     | `-AllowDnf`     | Grant `claude` passwordless `sudo dnf` inside the sandbox       |
| `--log-level LVL` | `-LogLevel LVL` | Logging threshold: `I` (verbose info), `W` (warn+error, default), `E` (error only). Default keeps successful launches quiet — pass `--log-level I` for full progress output. Forwarded to every child process via explicit `--log-level` args — sandbox setup, in-container claude, etc. |

`podman-machine.sh` additionally takes `--cpus`, `--memory`, `--disk-size` and forwards them to `podman machine init`.

## How it works

### Three-tier tool cache

`lib/tools.sh` and `lib/Tools.ps1` build three content-addressed `.tar.xz` archives under `$XDG_CACHE_HOME/claude-code-sandbox/tools/` (or `%LOCALAPPDATA%\.cache\…` on Windows):

1. **base** — `node` + `rg` + `micro` + `claude-wrapper`. Hash keyed on each tool version plus the wrapper's contents.
2. **tool** — `pnpm` + `uv` + `uvx`. Hash keyed on their versions.
3. **claude** — the Claude Code binary. Hash keyed on its version.

Latest versions are discovered in parallel from nodejs.org, GitHub releases, npm, and PyPI. The Claude binary is fetched from its public GCS release bucket. Archives are reused across sessions; `--force-pull` rebuilds them and `--{base,tool,claude}-hash` pins to an existing cached hash prefix so you can freeze a known-good toolchain without network access.

Splitting into three tiers means a new Claude Code release only invalidates Tier 3 (a ~single-file archive), not the whole toolchain.

### Sandbox bootstrap

`Containerfile` builds a minimal Fedora image with a `claude` user, `sudo`, and a guarded `enable-dnf` helper. It does not bake any tooling in. Instead, its `ENTRYPOINT` invokes `bin/setup-tools.sh`, which extracts the three archives mounted at `/tmp/{base,tool,claude}.tar.xz` into `$HOME/.local/bin`, renames `claude` → `claude-bin` so the shell wrapper (`bin/claude-wrapper.sh`) can take over the `claude` name, and finally execs `claude --dangerously-skip-permissions`. The same script is used by the VM and WSL2 backends to set up the toolchain after archive injection.

This keeps the image itself small and stable — toolchain upgrades happen in the cache, not in the image.

### Credentials and global config

`lib/ensure-credential.sh` / `lib/Ensure-Credential.ps1` run on the host before launching the sandbox. They:

1. Read `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude/.credentials.json`).
2. Test the access token against `https://api.anthropic.com/api/oauth/claude_cli/roles`.
3. On `401`, refresh it against `https://platform.claude.com/v1/oauth/token` using the client id and scope from `config/oauth.json`, and write the new token back.

If there is no credential file, you are told to run `claude` on the host once to authenticate.

`lib/init-config.sh` / `lib/Init-Config.ps1` then stage a curated subset of `~/.claude/` into the project itself, under `$PWD/.claude/.system/`. The staging dir has four buckets:

- `ro/` — **copies** of read-only files: `CLAUDE.md`, `keybindings.json`, `rules/`, `commands/`, `agents/`, `output-styles/`, `skills/*/`. The whole `ro/` dir is wiped + re-copied on every launch, so any in-session tampering is undone and upstream deletions in `~/.claude/` propagate. Even if the read-only mount were bypassed, writes cannot reach the host because the copies are independent inodes.
- `rw/` — **hardlinks** to writable files: `.credentials.json`, `settings.json`, `.claude.json`. They share an inode with `~/.claude/`, so in-place writes inside the sandbox propagate back immediately. Refreshed with `ln -f` every launch.
- `cr/` — **created at runtime by Claude**: persists across launches as per-project session history. No speculative subdirs are pre-created — Claude `mkdir`s whatever it needs (`projects/`, `shell-snapshots/`, `tasks/`, `.claude.json.backup`, …) on demand under the cr/-as-base bind mount. The only entries we touch in `cr/` are mount-target placeholders for the per-file/per-subdir overlays.
- `.mask/` — an empty dir, used purely as the bind source that masks `.system/` from project scope inside the sandbox.

**Inside the sandbox** every launcher sets `CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox` and assembles all four buckets there:

1. `cr/` is bind-mounted as the base of `/etc/claude-code-sandbox` (rw — Claude's runtime writes land back in the project's `cr/`)
2. each writable file in `rw/` is bind-mounted on top per-file, so the path becomes a mount point — `rename()`/`unlink()` give EBUSY and Claude Code's atomic-replace falls back to in-place `writeFileSync()`, which preserves the host hardlink and syncs changes immediately
3. each `ro/` file and subdir is bind-mounted on top read-only via `mount --bind` + `mount -o remount,bind,ro`
4. `.mask/` is bind-mounted (read-only) on top of `/var/workdir/.claude/.system` so the system bucket is **invisible from project scope**: anything reading under `/var/workdir/.claude/` sees an empty `.system/` while `/etc/claude-code-sandbox` continues to serve real content (the bind mounts captured the host inodes before the mask was applied). We use a bind of an empty dir instead of `--tmpfs` because podman `--tmpfs` over a path nested inside another `-v` mount has been observed to silently no-op on some podman/WSL2 combinations.

The atomic-rename → writeFileSync fallback matters because rename semantics differ across drvfs (WSL2), virtiofs (Podman machine), and overlayfs/bind mounts — EBUSY forces a code path that is portable everywhere.

- **Container scripts** assemble everything directly via podman `-v` flag stacking — no in-container privileges required. The 3 writable files are passed as `-v $SYSTEM_DIR/rw/<file>:/etc/claude-code-sandbox/<file>`.
- **podman-machine.sh** mounts only the workdir into the VM, then runs `bin/setup-system-mounts.sh` as root over SSH to do steps 1–4. Same script, same `rw/` source.
- **wsl.ps1** mounts only the workdir via `drvfs`, then runs `bin/setup-system-mounts.sh` as root (the script is baked into `/usr/local/libexec/claude-code-sandbox/setup-system-mounts.sh` during the import block — `wsl.conf` disables `/mnt/c` automount once installed, so subsequent launches can't reach the host file). Same script, same overlay logic.

Claude itself is launched as an unprivileged user (`core` on the VM, `claude` in the container/distro) — sudo is used solely for the mount syscalls.

> **Supported hosts:** Linux, macOS, and Windows.

The single `$PWD → /var/workdir` mount on the VM/WSL2 backends is what avoids the macOS Apple vfkit virtio-fs bug where a `mount --bind` whose target sits under a `mount -o remount,ro,bind` virtio-fs parent makes `open()` return EACCES for non-root processes (containers/podman#24725, FB16008360). All binds in the new layout have source and target on the same device.

> **Tip:** add `.claude/.system/` to your project `.gitignore`. The bucket contains your hardlinked `~/.claude/.credentials.json` (OAuth token) and per-project session history — none of it belongs in commits.

### Lifecycle

- **Container scripts** — `podman run --rm` with the archives, the workdir, the per-file/per-subdir `-v` mounts assembling `/etc/claude-code-sandbox`, and a `-v $PWD/.claude/.system/.mask:/var/workdir/.claude/.system:ro` bind masking `.system/` from project scope. Dies with the session; nothing on host to clean up (the project's `.claude/.system/` persists by design).
- **podman-machine.sh** — hashes `$PWD` to derive a machine name, stops any other running machine (Podman only allows one), inits a fresh VM with a single `$PWD → /var/workdir` virtio-fs volume. After start, pipes `bin/setup-system-mounts.sh` in over SSH and runs it as root to assemble `/etc/claude-code-sandbox` (and bind the `.mask/` over `.system/`). Then injects the three tool archives, runs `bin/setup-tools.sh`, and opens an interactive `ssh -tt` session running `claude` as `core`. An `EXIT` trap stops and removes the machine no matter how the session ends.
- **wsl.ps1** — hashes `$PWD` to derive a distro name, imports the Podman base image as a WSL tarball, runs `bin/setup-tools.sh` via `wsl -u root` to extract the archives into `$HOME/.local/bin`, **bakes `bin/setup-system-mounts.sh` into the distro at `/usr/local/libexec/claude-code-sandbox/setup-system-mounts.sh`** (must happen here while `/mnt/c` is still automounted), installs `config/wsl.conf` to disable automount and Windows interop, then on every launch mounts the Windows workdir via `drvfs` and runs the in-distro `setup-system-mounts.sh` as root to assemble `/etc/claude-code-sandbox`, then runs Claude and unregisters the distro on exit. A stamp file (`.archive-hash`) — keyed on the tool archives, the base image, `wsl.conf`, **and `setup-system-mounts.sh`** — is kept so repeated runs on the same workdir can reuse the distro unless any of those change.

## Requirements

- **Linux/macOS:** `podman`, `curl`, `jq`, `tar`, `sha256sum` (or `shasum`). For `podman-machine.sh`, a working `podman machine` provider (qemu/applehv/hyperv).
- **Windows:** PowerShell 7+, `podman` (Podman Desktop is fine), `tar.exe` (ships with modern Windows), and WSL2 for `wsl.ps1`.
- A prior `claude` login on the host so `~/.claude/.credentials.json` exists.

## Caveats

- `--dangerously-skip-permissions` is still dangerous *inside* the sandbox — the agent can freely trash `/var/workdir`, which is your real project directory. Commit or stash first if that matters to you.
- Only `linux/amd64` and `linux/arm64` tool archives are built.
- `podman-machine.sh` stops every other running podman machine on launch (Podman supports only one VM at a time) and does not restart them on exit — you'll need to `podman machine start <name>` your previous machine yourself afterward.
