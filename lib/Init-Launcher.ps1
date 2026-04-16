# Init-Launcher.ps1 — shared launcher initialization.
# Dot-sourced (not executed). Requires: $projectRoot
#
# Sources Init-Config.ps1 and Tools.ps1, then provides $initLauncher
# which runs credential check, config init, arch detection, and
# tool archive build.
#
# Also provides:
#   Invoke-Must — run a native command and throw if its exit code is
#                 non-zero. Stdout is passed through to the caller.
#   $wslSrc     — convert a Windows path to a WSL absolute path
#
# Caller must set $optBaseHash, $optToolHash, $optClaudeHash, $forcePull
# before invoking $initLauncher.

function Invoke-Must {
  $cmd = $args[0]
  $cmdArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
  & $cmd @cmdArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed (exit $LASTEXITCODE): $cmd $($cmdArgs -join ' ')"
  }
}

# Log.ps1 first so every downstream lib can call Write-Log.
. "$projectRoot\lib\Log.ps1"
. "$projectRoot\lib\Init-Config.ps1"
. "$projectRoot\lib\Tools.ps1"

# Pure-PS equivalent of `wsl wslpath -a` for drive-letter paths.
# `wsl wslpath` would spawn wsl.exe per call (~100–300 ms each on
# Windows), and the launcher hits this in a tight loop while building
# `-v` mount args. The translation rule for drvfs is deterministic:
#   C:\foo\bar  →  /mnt/c/foo/bar
# We only ever pass drive-letter paths (project root, $HOME-anchored
# cache, baked-in script paths). UNC and \\wsl$ paths never appear.
$wslSrc = { param($p)
  $abs = [IO.Path]::GetFullPath($p)
  # Validate: must be a drive-letter path (C:\…). UNC paths (\\server\…,
  # \\wsl$\…) would silently produce nonsense like /mnt/\/server/… and
  # bind the wrong location. Fail loud instead.
  if ($abs.Length -lt 3 -or $abs[1] -ne ':') {
    throw "wslSrc: non-drive-letter path not supported: $abs"
  }
  '/mnt/' + $abs.Substring(0, 1).ToLower() + $abs.Substring(2).Replace('\', '/')
}

$initLauncher = {
  Write-Log I launcher start "claude-code-sandbox $($MyInvocation.ScriptName)"
  # Pass -LogLevel explicitly. Ensure-Credential.ps1 runs in its own
  # script scope (invoked via &) and would otherwise default to W.
  & "$projectRoot\lib\Ensure-Credential.ps1" -LogLevel $script:LogLevel
  . $initConfigDir
  . $detectArch
  . $buildToolArchives
}
