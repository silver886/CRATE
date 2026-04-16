param(
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$ClaudeHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest',
  [switch]$AllowDnf,
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'

# Normalize to uppercase. [ValidateSet] accepts any case (PS
# validation is case-insensitive), but we forward the literal
# value as `--log-level <x>` to setup-tools.sh inside the
# container, and the sh-side `case` is case-SENSITIVE. A stray
# `-LogLevel i` would otherwise silently fall through to the
# default W threshold and hide I-level logs from enable-dnf,
# setup-system-mounts, claude-wrapper, etc.
$LogLevel = $LogLevel.ToUpperInvariant()

# Script-scoped LogLevel for Write-Log to read. No env var write,
# no caller pollution — dies with the script.
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)
. "$projectRoot\lib\Init-Launcher.ps1"
. "$projectRoot\lib\Build-Image.ps1"

$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optClaudeHash = $ClaudeHash
$forcePull = $ForcePull.IsPresent

. $initLauncher
. $buildBaseImage

Write-Log I run launch "podman container run $imageTag"

# ── Run ──
#
# System config assembly via podman -v stacking (no in-container privileges):
#   1. cr/ as the base of /etc/claude-code-sandbox (rw, persists per project)
#   2. rw/<f>      per-file mounts shadow cr at <f> with host hardlinks
#                  (mount-point gives EBUSY → in-place write → host sync)
#   3. ro/<x>:ro   per-file/per-subdir mounts shadow cr at <x>, read-only
#   4. .mask/      bind-mounted (read-only) over /var/workdir/.claude/.system
#                  to mask system scope from project scope.

$systemDirWsl = & $wslSrc $systemDir
$extraArgs = @(
  '--env', 'CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox',
  '-v', "${systemDirWsl}/cr:/etc/claude-code-sandbox"
)
foreach ($f in $configFiles) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/rw/${f}:/etc/claude-code-sandbox/${f}"
}
foreach ($f in $roFiles) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/ro/${f}:/etc/claude-code-sandbox/${f}:ro"
}
foreach ($d in $roDirs) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/ro/${d}:/etc/claude-code-sandbox/${d}:ro"
}
$extraArgs += '-v'
$extraArgs += "${systemDirWsl}/.mask:/var/workdir/.claude/.system:ro"
if ($AllowDnf) { $extraArgs += '--env', 'CLAUDE_ENABLE_DNF=1' }

# --log-level appended after the image tag as CMD args. The
# Containerfile ENTRYPOINT is setup-tools.sh, which parses the
# flag from its tail args and forwards it to claude-wrapper.sh
# (the renamed `claude`). No LOG_LEVEL env var crosses the
# container boundary.
Invoke-Must podman container run --interactive --tty --rm `
  '--userns=keep-id:uid=1000,gid=1000' `
  -v "$(& $wslSrc $baseArchive):/tmp/base.tar.xz:ro" `
  -v "$(& $wslSrc $toolArchive):/tmp/tool.tar.xz:ro" `
  -v "$(& $wslSrc $claudeArchive):/tmp/claude.tar.xz:ro" `
  -v "$(& $wslSrc $PWD.Path):/var/workdir" `
  --workdir /var/workdir `
  @extraArgs `
  $imageTag `
  --log-level $LogLevel
