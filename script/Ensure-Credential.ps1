param(
  [Parameter(Mandatory)][string]$Agent,
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'

$LogLevel = $LogLevel.ToUpperInvariant()
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)
. "$projectRoot\lib\Log.ps1"
. "$projectRoot\lib\Common.ps1"
. "$projectRoot\lib\Agent.ps1"

$agent = $Agent
Invoke-AgentLoad

$strategy = Get-AgentField '.credential.strategy'
# Allowlist before path construction: a hostile manifest could otherwise
# path-traverse out of lib/cred/ via credential.strategy (e.g.
# '..\..\evil') and trigger arbitrary host-side code execution when the
# dispatcher dot-sources $strategySrc below — well before any sandboxing
# runs.
if ($strategy -notin @('oauth-anthropic', 'oauth-google', 'oauth-openai')) {
  Write-Log E cred fail "unknown credential strategy: $strategy (allowed: oauth-anthropic, oauth-google, oauth-openai)"
  throw "unknown credential strategy: $strategy"
}
$strategySrc = [IO.Path]::Combine($projectRoot, 'lib', 'cred', "$strategy.ps1")
if (-not [IO.File]::Exists($strategySrc)) {
  Write-Log E cred fail "credential strategy file missing: $strategySrc"
  throw "credential strategy file missing: $strategySrc"
}

# The auth file the refresh strategy operates on is named explicitly by
# the manifest's `credential.file` (NOT positional in files.rw, which a
# manifest reorder would silently break). It must also appear in
# files.rw so the rest of the launcher (init-config staging) hardlinks
# it into the sandbox.
$credFile = Get-AgentField '.credential.file'
if (-not $credFile) {
  Write-Log E cred fail "manifest has no credential.file"
  throw "no credential.file"
}
$rwList = Get-AgentList '.files.rw'
if ($rwList -notcontains $credFile) {
  Write-Log E cred fail "credential.file '$credFile' must also be listed in files.rw"
  throw "credential.file not in files.rw"
}
$credPath = [IO.Path]::Combine($agentConfigDir, $credFile)
$agentOauthJson = [IO.Path]::Combine($agentDir, 'oauth.json')

Write-Log I cred check "$credPath ($strategy)"
if (-not [IO.File]::Exists($credPath)) {
  Write-Log E cred fail "credentials file not found: $credPath; use the $agentBinary CLI to log in on the host"
  throw "credentials file not found"
}

. $strategySrc
Invoke-CredCheck -CredPath $credPath -OauthJsonPath $agentOauthJson
