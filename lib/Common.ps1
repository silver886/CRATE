# Common.ps1 — cross-cutting constants and helpers shared between
# launcher init (lib/Init-Launcher.ps1 chain → Tools.ps1) and the
# credential dispatcher (script/Ensure-Credential.ps1 →
# lib/cred/oauth-*.ps1). Dot-sourced; no side effects beyond defining
# script-scope names.

# Collapse CRLF line endings to LF in a string. Use whenever a string
# is about to cross into a shell — sh -c "..." command args, file
# contents destined for sh, here-strings sent over wsl/ssh — so the
# launch doesn't silently break when the script's own source file has
# CRLF line endings (a Windows checkout with `core.autocrlf=true` is
# the common trigger; sh chokes on `\r` at end-of-line with
# `$'\r': command not found` halfway through a multi-line block).
#
# Targets only the `\r\n` pair, NOT bare `\r`: the bug we're guarding
# against is line-end CR from autocrlf, and inline `\r` may be
# legitimate content (terminal escape sequences, embedded payload
# bytes). Stripping every `\r` would corrupt those.
#
# Centralised here so the EOL guarantee is owned by the script, not by
# the file's on-disk form.
$lfOnly = { param([string]$s) ($s -replace "`r`n", "`n") }

# User-Agent for every HTTP call we make. One literal so the value
# can't drift between the cred refresh path and the build-archive
# fetcher (and across runspace boundaries — Tools.ps1 forwards this to
# its tier-builder thread jobs via $vars). Mirrored by CRATE_USER_AGENT
# in lib/common.sh.
#
# Anthropic intentionally opts out (lib/cred/oauth-anthropic.ps1 does
# NOT set this header) — its OAuth endpoints rate-limit non-empty
# curl-style UAs harder than empty.
$crateUserAgent = 'crate/1.0'

# In-place credential write that preserves hardlinks/junctions/bind
# mounts pointing at $Path. Used by lib/cred/oauth-*.ps1 instead of
# [IO.File]::WriteAllText, which truncates the file BEFORE writing
# (FileMode.Create == O_TRUNC) and leaves the live cred JSON empty
# during the write window.
#
# Strategy: stage the new payload in a tmp sibling first, then open
# the live file with FileMode.OpenOrCreate (NO truncate) and
# overwrite from offset 0; SetLength trims any old tail when the new
# payload is shorter than the old; Flush($true) issues fsync. The
# corruption window is narrower than WriteAllText because the file
# never starts the operation empty — old content stays intact until
# each byte is overwritten — and the new payload is fully built in
# the tmp file before we touch the live inode.
function Write-CredInPlace {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Content
  )
  $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
  $dir = [IO.Path]::GetDirectoryName($Path)
  $tmp = [IO.Path]::Combine($dir, ".cred.$([Guid]::NewGuid().ToString('N')).tmp")
  try {
    [IO.File]::WriteAllBytes($tmp, $bytes)
    # Read-back guards against silent EIO short-write — cheap because
    # cred JSONs are < 8 KB.
    $check = [IO.File]::ReadAllBytes($tmp)
    if ($check.Length -ne $bytes.Length) {
      throw "tmp short-write: $($check.Length) of $($bytes.Length) bytes"
    }
    # Validate the staged payload parses as JSON before touching the
    # live file. Mirrors the `jq empty` guard in lib/common.sh's
    # cred_inplace_write — without this, a malformed refresh response
    # would clobber the live credentials and leave the agent unable
    # to authenticate on next launch.
    try {
      $null = [Text.Json.JsonDocument]::Parse($Content)
    }
    catch {
      throw "refreshed credentials failed JSON parse; live file untouched: $_"
    }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
      $fs.Position = 0
      $fs.Write($bytes, 0, $bytes.Length)
      $fs.SetLength($bytes.Length)
      $fs.Flush($true)
    }
    finally { $fs.Dispose() }
  }
  finally {
    if ([IO.File]::Exists($tmp)) {
      try { [IO.File]::Delete($tmp) } catch {}
    }
  }
}
