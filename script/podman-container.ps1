param(
  [string]$Agent = 'claude',
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$AgentHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest',
  [switch]$AllowDnf,
  [switch]$NewSession,
  [string]$Session = '',
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'
if ($NewSession -and $Session) {
  throw '-NewSession and -Session are mutually exclusive'
}

# Re-exec into a child pwsh so the launcher invocation gets its own OS
# process. Bash launchers fork naturally (script runs in a subshell, $$
# is unique per launch); PowerShell .ps1 scripts run *inside* the
# calling shell, so $PID is the user's interactive pwsh and pid-based
# liveness keys on the shell instead of the launch — sessions never
# abandon while pwsh stays open. Forking gives the child a unique $PID
# (= bash's $$, the "sandbox pid") and makes ParentProcessId the user's
# interactive pwsh (= bash's $PPID, the "terminal pid"), restoring
# parity with the bash session-reclaim semantics.
#
# -NoProfile -NoLogo skips the user's $PROFILE so the child startup
# cost stays bounded. CRATE_LAUNCHER_FORKED is the recursion guard;
# it's cleared in the child after the gate so any nested launch
# (agent shells out to the launcher again) re-forks correctly.
if (-not $env:CRATE_LAUNCHER_FORKED) {
  $fwd = @()
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) {
      if ($v.IsPresent) { $fwd += "-$k" }
    }
    else {
      $fwd += "-$k"
      $fwd += [string]$v
    }
  }
  $env:CRATE_LAUNCHER_FORKED = '1'
  try {
    & pwsh -NoProfile -NoLogo -File $PSCommandPath @fwd
    $childExit = $LASTEXITCODE
  }
  finally {
    Remove-Item env:CRATE_LAUNCHER_FORKED -ErrorAction SilentlyContinue
  }
  # `return` (not `exit`) so a `.\script.ps1` invocation from an
  # interactive pwsh prompt doesn't terminate the user's shell on
  # success. On failure, surface as a throw — pwsh -File callers get
  # exit code 1 from $ErrorActionPreference='Stop'; interactive callers
  # see the error and keep their session.
  if ($childExit -ne 0) { throw "launcher exited with code $childExit" }
  return
}
Remove-Item env:CRATE_LAUNCHER_FORKED -ErrorAction SilentlyContinue

$LogLevel = $LogLevel.ToUpperInvariant()
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)
$agent = $Agent
. "$projectRoot\lib\Init-Launcher.ps1"
. "$projectRoot\lib\Build-Image.ps1"

$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optAgentHash = $AgentHash
$forcePull = $ForcePull.IsPresent
$optNewSession = $NewSession.IsPresent
$optSessionId = $Session

. $initLauncher
. $buildBaseImage

Write-Log I run launch "podman container run $imageTag ($agent)"

# ── Run ──
#
# System config assembly via podman -v stacking:
#   1. sessions/<id>/cr/ as the base of $crateDir (rw, persists per session)
#   2. rw/<f> per-file mounts shadow cr at <f> with host hardlinks
#   3. ro/<x>:ro per-file/per-subdir mounts shadow cr at <x>, read-only
#   4. .mask/ bind-mounted (read-only) over /var/workdir/<projectDir>/.system

$systemDirWsl = & $wslSrc $systemDir
$sessionDirWsl = & $wslSrc $sessionDir
$extraArgs = @('-v', "${sessionDirWsl}/cr:${crateDir}")
foreach ($f in $configFiles) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/rw/${f}:${crateDir}/${f}"
}
foreach ($f in $roFiles) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/ro/${f}:${crateDir}/${f}:ro"
}
foreach ($d in $roDirs) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/ro/${d}:${crateDir}/${d}:ro"
}
$extraArgs += '-v'
$extraArgs += "${systemDirWsl}/.mask:/var/workdir/${agentProjectDir}/.system:ro"
if ($AllowDnf) { $extraArgs += '--env', 'CRATE_ALLOW_DNF=1' }

Invoke-Must podman container run --interactive --tty --rm `
  '--userns=keep-id:uid=24368,gid=24368' `
  @selinuxOpt `
  -v "$(& $wslSrc $baseArchive):/tmp/base.tar.xz:ro" `
  -v "$(& $wslSrc $toolArchive):/tmp/tool.tar.xz:ro" `
  -v "$(& $wslSrc $agentArchive):/tmp/agent.tar.xz:ro" `
  -v "$(& $wslSrc $PWD.Path):/var/workdir" `
  --workdir /var/workdir `
  @extraArgs `
  $imageTag `
  --log-level $LogLevel
