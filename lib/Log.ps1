# Log.ps1 — structured logger for launcher and lib scripts. Dot-sourced
# (not executed). Provides Write-Log with a fixed-width 5-column format
# matching lib/log.sh exactly:
#
#   <TS>                     <LVL> <STAGE>          <EVENT>        <MSG>
#   2026-04-14T15:04:05.123Z I     tools.base       cache-hit      base-2e029a8…
#
# Columns (fixed width on every line, regardless of host or runtime):
#   TS       — RFC 3339 UTC timestamp with millisecond precision
#              (yyyy-MM-ddTHH:mm:ss.fffZ, always 24 chars)
#   LVL      — single char: I | W | E (validated)
#   STAGE    — area (cred, config, tools.base, image, distro, …) padded 16
#   EVENT    — verb padded 14
#   MSG      — free-form trailing string
#
# I is dim, W yellow, E red. Output goes to the host stream.

# Threshold filtering reads `$script:LogLevel` from the dot-source
# caller's script scope. The launcher (or Ensure-Credential.ps1 when
# run standalone) sets $script:LogLevel from its -LogLevel param.
# This avoids touching $env:, which is process-wide in PowerShell
# and would pollute the caller's pwsh session after the script exits.
#
# LOG_LEVEL is NEVER injected as an env var (--env / env VAR=…).
# Every process boundary uses an explicit --log-level arg:
#
#   Ensure-Credential.ps1  & ./lib/Ensure-Credential.ps1 -LogLevel $script:LogLevel
#   podman container       setup-tools.sh parses --log-level from CMD tail
#   wsl -u root            sh $wslSetup --log-level $LogLevel …
#   sudo (in sandbox)      enable-dnf.sh --log-level $LOG_LEVEL
#
# Levels:
#   I   show everything (verbose; opt-in)
#   W   show warnings + errors (default; quiet on success)
#   E   show errors only

# ── ANSI color setup ──
#
# Match lib/log.sh exactly so launchers look identical regardless of
# which side they run on. Each column gets its own hue so the eye
# can scan vertically:
#   TS    gray    (90)        — recedes; only read when correlating
#   LVL   bold per-level      — I cyan, W yellow, E red, all bold so
#                               error rows pop in a wall of text
#   STAGE green   (32)        — "where it happened"
#   EVENT magenta (35)        — "what happened"
#   MSG   default             — terminal default color
#
# Probed once at module load. Disabled when:
#   - $env:NO_COLOR is set (https://no-color.org/), or
#   - stderr is redirected to a file/pipe (not a console)
# In the disabled case the format degrades to the original uncolored
# fixed-width layout — no escape bytes leak into captured output.
if (-not $env:NO_COLOR -and -not [Console]::IsErrorRedirected) {
  $script:LogColor = @{
    Reset = "`e[0m"
    TS    = "`e[90m"
    Stage = "`e[32m"
    Event = "`e[35m"
    I     = "`e[1;36m"
    W     = "`e[1;33m"
    E     = "`e[1;31m"
  }
}
else {
  $script:LogColor = @{
    Reset = ''
    TS    = ''
    Stage = ''
    Event = ''
    I     = ''
    W     = ''
    E     = ''
  }
}

function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet('I', 'W', 'E')][string]$Level,
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Event,
    [string]$Msg = ''
  )
  # Normalize: [ValidateSet] and PS `switch` are case-insensitive, and
  # hashtable key lookup (for $c[$Level]) is also case-insensitive by
  # default — so 'i'/'w'/'e' work today by accident. Force uppercase
  # here so we don't rely on those defaults if the hashtable is ever
  # rebuilt with an ordinal comparer.
  $Level = $Level.ToUpperInvariant()
  $normLogLevel = if ($script:LogLevel) { $script:LogLevel.ToUpperInvariant() } else { 'W' }
  $threshold = switch ($normLogLevel) { 'I' { 1 } 'E' { 3 } default { 2 } }
  $msgLevel = switch ($Level) { 'W' { 2 } 'E' { 3 } default { 1 } }
  if ($msgLevel -lt $threshold) { return }
  $ts = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $c = $script:LogColor
  # The {-N} format specifiers pad the *visible* Stage/Event text to
  # 16/14 chars BEFORE the trailing reset escape, so column alignment
  # is preserved while invisible escape bytes ride along outside the
  # padding window. Same trick used in lib/log.sh.
  $line = '{0}{1}{2} {3}{4}{2} {5}{6,-16}{2} {7}{8,-14}{2} {9}' -f `
    $c.TS, $ts, $c.Reset, $c[$Level], $Level, $c.Stage, $Stage, $c.Event, $Event, $Msg
  # Use [Console]::Error directly rather than Write-Host so that logs
  # emitted from a Start-ThreadJob runspace stream live to the
  # parent's terminal. Write-Host writes to the Information stream,
  # which ThreadJob captures and only releases on Receive-Job — that
  # would defer all tier-build logs until after parallel completion.
  # [Console]::Error.WriteLine is a single write(2)/WriteFile, atomic
  # at the line boundary across threads in the same process.
  [Console]::Error.WriteLine($line)
}
