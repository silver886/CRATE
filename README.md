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

Optional: pass `--with-dnf` (POSIX) or `-WithDnf` (PowerShell) to enable `sudo dnf` inside the sandbox for installing extra packages during a session. Fedora-based images only.

## Sandbox backends

Four launcher scripts, same flags, same result — pick whichever matches your host:

| Script                        | Host          | Isolation                                                                         |
| ----------------------------- | ------------- | --------------------------------------------------------------------------------- |
| `script/podman-container.sh`  | Linux / macOS | Podman container, rootless, `--userns=keep-id`                                    |
| `script/podman-machine.sh`    | Linux / macOS | Fresh Podman VM per workdir, destroyed on exit                                    |
| `script/podman-container.ps1` | Windows       | Podman container via Podman Desktop / WSL backend                                 |
| `script/wsl.ps1`              | Windows       | Fresh WSL distro per workdir imported from the Podman image, unregistered on exit |

The Podman container scripts keep the sandbox process-scoped. The `podman-machine` and `wsl` scripts go further and throw away an entire VM/distro at the end of the session — heavier, but the strongest isolation the host can provide short of a separate machine.

## Usage

From the directory you want to expose to Claude:

```sh
# Linux/macOS — container
/path/to/claude-code-sandbox/script/podman-container.sh

# Linux/macOS — fresh VM per session
/path/to/claude-code-sandbox/script/podman-machine.sh

# Windows — container
& C:\path\to\claude-code-sandbox\script\podman-container.ps1

# Windows — fresh WSL distro per session
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
| `--with-dnf`      | `-WithDnf`      | Grant `claude` passwordless `sudo dnf` inside the sandbox       |

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

`Containerfile` builds a minimal Fedora image with a `claude` user, `sudo`, and a guarded `enable-dnf` helper. It does not bake any tooling in. Instead, its `ENTRYPOINT` invokes `bin/setup-tools.sh`, which extracts the three archives mounted at `/tmp/{base,tool,claude}.tar.xz` into `$HOME/.local/bin`, renames `claude` → `claude-bin` so the shell wrapper (`bin/claude-wrapper.sh`) can take over the `claude` name, and finally execs `claude --dangerously-skip-permissions`. The same script is used by the VM and WSL backends to set up the toolchain after archive injection.

This keeps the image itself small and stable — toolchain upgrades happen in the cache, not in the image.

### Credentials

`lib/ensure-credential.sh` / `lib/Ensure-Credential.ps1` run on the host before launching the sandbox. They:

1. Read `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude/.credentials.json`).
2. Test the access token against `https://api.anthropic.com/api/oauth/claude_cli/roles`.
3. On `401`, refresh it against `https://platform.claude.com/v1/oauth/token` using the client id and scope from `config/oauth.json`, and write the new token back.

If there is no credential file, you are told to run `claude` on the host once to authenticate.

`lib/init-config.sh` / `lib/Init-Config.ps1` then prepare `$PWD/.claude/` by hardlinking `.credentials.json`, `settings.json`, and `.claude.json` (whichever exist) to the real files after resolving any symlink chains.

Claude Code uses atomic file replacement (write temp + rename) to update config files. This creates a new inode, which would silently break hardlinks. All backends prevent this by making each config file a bind mount point — `rename()` and `unlink()` fail with `EBUSY`, forcing Claude Code's fallback to in-place `writeFileSync()` which preserves the shared inode.

- **Container scripts** achieve this via podman's per-file `-v` mounts.
- **Machine and WSL scripts** run `mount --bind` on each config file inside the sandbox after the directory mount is active.

### Lifecycle

- **Container scripts** — `podman run --rm` with the archives, the workdir, and each config file bind-mounted. Dies with the session.
- **podman-machine.sh** — hashes `$PWD` to derive a machine name, stops any other running machine (Podman only allows one), inits a fresh VM with `$PWD` virtiofs-mounted at `/var/workdir`, injects the three tool archives via SSH and runs `bin/setup-tools.sh` to extract them into `$HOME/.local/bin`, then opens an interactive SSH session running `claude`. An `EXIT` trap stops and removes the machine no matter how the session ends.
- **wsl.ps1** — hashes `$PWD` to derive a distro name, imports the Podman base image as a WSL tarball, runs `bin/setup-tools.sh` via `wsl -u root` to extract the archives into `$HOME/.local/bin`, installs `config/wsl.conf` to disable automount, Windows interop, and `PATH` append (cutting off host access), mounts the Windows workdir via `drvfs`, runs Claude, then unregisters the distro on exit. A stamp file (`.archive-hash`) is kept so repeated runs on the same workdir can reuse the distro unless the toolchain changed.

## Requirements

- **Linux/macOS:** `podman`, `curl`, `jq`, `tar`, `sha256sum` (or `shasum`). For `podman-machine.sh`, a working `podman machine` provider (qemu/applehv/hyperv).
- **Windows:** PowerShell 7+, `podman` (Podman Desktop is fine), `tar.exe` (ships with modern Windows), and WSL 2 for `wsl.ps1`.
- A prior `claude` login on the host so `~/.claude/.credentials.json` exists.

## Caveats

- `--dangerously-skip-permissions` is still dangerous *inside* the sandbox — the agent can freely trash `/var/workdir`, which is your real project directory. Commit or stash first if that matters to you.
- Only `linux/amd64` and `linux/arm64` tool archives are built.
