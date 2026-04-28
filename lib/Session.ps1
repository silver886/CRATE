# Session.ps1 — small read-side helpers for the per-session `owner` KV
# file plus the process-introspection primitives the launcher and the
# listing tool both need. Mirror of lib/session.sh. Dot-sourced (not
# executed) by:
#
#   lib/Init-Launcher.ps1     — uses these for ctx capture, liveness,
#                               and reclaim matching during launch
#   script/List-Sessions.ps1  — uses $ownerGet and pid-aliveness to
#                               render the listing
#
# Anything specific to *claiming* a session (locking, atomic write,
# matching against the current launcher's ctx) lives in
# Init-Launcher.ps1 alongside the resolver — it's not reusable.

# True iff $p names a currently running process. Replaces the
# `Get-Process -ErrorAction SilentlyContinue` pattern with a direct
# call to System.Diagnostics.Process.GetProcessById, which is the same
# work without the cmdlet pipeline overhead. Throws ArgumentException
# when the pid is gone — that's the only failure path we care about,
# any other exception is a real fault and bubbles up.
$pidAlive = { param([int]$p)
  if ($p -le 0) { return $false }
  try {
    [void][Diagnostics.Process]::GetProcessById($p)
    return $true
  }
  catch [ArgumentException] {
    return $false
  }
}

# Read just the first line of a file. The launcher's owner.pid (and
# wsl.ps1's *.distro state files) are single-line — using
# Get-Content/Select-Object loads through the pipeline; StreamReader
# reads exactly one line and stops. Returns $null on missing/error.
$readFirstLine = { param([string]$Path)
  if (-not [IO.File]::Exists($Path)) { return $null }
  $sr = $null
  try {
    $sr = [IO.StreamReader]::new($Path)
    return $sr.ReadLine()
  }
  catch {
    return $null
  }
  finally {
    if ($sr) { $sr.Dispose() }
  }
}

# Read the cmdline of an arbitrary pid. Empty if the pid is gone or
# unreadable. Win32_Process is the kernel-level command line and
# matches what we capture for our own pid via the same call. The .ps1
# backends are Windows-only, so Win32_Process is always available.
$pidCmdline = { param([int]$p)
  if ($p -le 0) { return '' }
  try {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
    if ($cim -and $cim.CommandLine) { return [string]$cim.CommandLine }
  }
  catch {}
  return ''
}

# Process start-time, stable for the lifetime of the process and
# unique vs PID reuse. ToFileTimeUtc gives a stable string-ifiable
# 64-bit integer that matches across re-reads of the same process.
$pidStart = { param([int]$p)
  if ($p -le 0) { return '' }
  try {
    return [string][Diagnostics.Process]::GetProcessById($p).StartTime.ToFileTimeUtc()
  }
  catch {
    return ''
  }
}

# Read a single field from an `owner` KV file. Splits on the FIRST
# `=`, returning '' if file or key is missing.
#
# ReadAllLines, NOT ReadLines: ReadLines returns a lazy enumerator that
# keeps a StreamReader open until fully consumed. PowerShell's foreach
# does not reliably Dispose() the enumerator on early `return`, so the
# inner `return` below would leak the file handle until GC. The very
# next call into [IO.File]::Move(tmp, $Path, $true) in $writeOwnerFile
# then trips ACCESS_DENIED on Windows — overwrite-Move requires
# deleting the existing target, which the leaked reader (FileShare.Read,
# no Delete) blocks. ReadAllLines slurps the whole file synchronously
# and closes it before we return.
$ownerGet = { param([string]$Path, [string]$Key)
  if (-not [IO.File]::Exists($Path)) { return '' }
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $eq = $line.IndexOf('=')
    if ($eq -le 0) { continue }
    if ($line.Substring(0, $eq) -eq $Key) {
      return $line.Substring($eq + 1)
    }
  }
  return ''
}

# True iff pid is alive AND its start-time matches the recorded one
# AND its cmdline matches the recorded one. The 3-field tuple
# (pid + start + cmd) is unique per process lifetime — same identity
# the VM/distro state markers already use to defeat PID reuse.
# Cmdline alone collides on long-uptime hosts where the OS pid space
# wraps and a recycled pid happens to be running the same launcher
# command; start (Process.StartTime.ToFileTimeUtc) disambiguates.
#
# Backwards-compat fallbacks for legacy owner files:
#   - empty $expectedStart → fall back to pid + cmdline
#   - empty $expectedCmd   → fall back to pid-only
$ownerAlive = { param([int]$p, [string]$expectedStart, [string]$expectedCmd)
  if (-not (& $pidAlive $p)) { return $false }
  if ($expectedStart) {
    $curStart = & $pidStart $p
    if ($curStart -ne $expectedStart) { return $false }
  }
  if (-not $expectedCmd) { return $true }
  $cur = & $pidCmdline $p
  return ($cur -eq $expectedCmd)
}
