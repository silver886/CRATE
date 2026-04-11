param(
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$ClaudeHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest',
  [switch]$WithDnf
)
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir
. "$projectRoot\lib\Init-Launcher.ps1"
. "$projectRoot\lib\Build-Image.ps1"

$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optClaudeHash = $ClaudeHash
$forcePull = $ForcePull.IsPresent
. $initLauncher

# ── WSL distro ──

$distroSrc = (& $imageSrc) + [IO.File]::ReadAllText("$projectRoot\config\wsl.conf")
$archiveHash = & $sha256 "$baseArchive-$toolArchive-$claudeArchive-$distroSrc-$Image"
$workdirHash = & $sha256 $PWD.Path
$distroName = "claude-$workdirHash"
$distroDir = "$env:LocalAppData\$distroName"
$stampFile = "$distroDir\.archive-hash"

$distroExists = $false
wsl -d $distroName -- true 2>$null
if ($LASTEXITCODE -eq 0) { $distroExists = $true }

$needsImport = (-not $distroExists)
if ($distroExists) {
  if (-not [IO.File]::Exists($stampFile) -or [IO.File]::ReadAllText($stampFile).Trim() -ne $archiveHash) {
    $needsImport = $true
  }
}

if ($needsImport) {
  if ($distroExists) { wsl --unregister $distroName 2>$null }

  # Build base image and export as tarball for WSL import
  . $buildBaseImage
  $exportCtr = (Invoke-Must podman container create $imageTag true)
  try {
    Invoke-Must podman container export $exportCtr -o "$env:TEMP\claude-base.tar"
  }
  finally {
    podman container rm $exportCtr 2>$null
  }

  [IO.Directory]::CreateDirectory($distroDir) > $null
  try {
    Invoke-Must wsl --import $distroName $distroDir "$env:TEMP\claude-base.tar"
  }
  finally {
    [IO.File]::Delete("$env:TEMP\claude-base.tar")
  }

  # Extract tool archives and set up binaries (before disabling automount — needs /mnt/c/)
  $wslSetup = & $wslSrc "$projectRoot\bin\setup-tools.sh"
  $wslArchives = @()
  foreach ($archive in $baseArchive, $toolArchive, $claudeArchive) {
    $wslArchives += & $wslSrc $archive
  }
  Invoke-Must wsl -d $distroName -u root -- env CLAUDE_BIN_DIR=/home/claude/.local/bin sh $wslSetup @wslArchives

  # Write wsl.conf and terminate so it takes effect
  $wslConf = & $wslSrc "$projectRoot\config\wsl.conf"
  Invoke-Must wsl -d $distroName -u root -- cp $wslConf /etc/wsl.conf
  wsl --terminate $distroName 2>$null
  [IO.File]::WriteAllText($stampFile, $archiveHash)
}

# ── Mount and configure ──

$winWorkdir = $PWD.Path

Invoke-Must wsl -d $distroName -u root -- sh -c "
  mkdir -p /var/workdir &&
  mount -t drvfs '$($winWorkdir.Replace("'", "'\''"))' /var/workdir
"

# Bind-mount each config file to prevent atomic replace (EBUSY preserves inode)
foreach ($f in $configFiles) {
  Invoke-Must wsl -d $distroName -u root -- mount --bind "/var/workdir/.claude/$f" "/var/workdir/.claude/$f"
}

# ── Launch with cleanup ──

$envArgs = 'CLAUDE_CONFIG_DIR=/var/workdir/.claude'
if ($WithDnf) { $envArgs += ' CLAUDE_ENABLE_DNF=1' }

try {
  Invoke-Must wsl -d $distroName --cd /var/workdir -- sh -c "
    exec env $envArgs `$HOME/.local/bin/claude --dangerously-skip-permissions
  "
}
finally {
  wsl --terminate $distroName 2>$null
  wsl --unregister $distroName 2>$null
}
