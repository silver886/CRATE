# oauth-openai.ps1 — OpenAI Codex PKCE public-client refresh strategy.
# Dot-sourced by Ensure-Credential.ps1. Defines Invoke-CredCheck.
#
# Validity check is two-stage: first decode the access_token AND id_token
# JWTs and refresh pre-emptively when EITHER one is absent or its `exp`
# claim is at/past expiry (Codex itself validates both on load); else live-probe
# auth.openai.com/oauth/userinfo with the access token in a Bearer header
# (200 = valid, 401 = expired → refresh). The probe still runs when both
# JWTs are unexpired, to catch server-side revocation that `exp` alone
# can't see. Mirrors lib/cred/oauth-openai.sh.
#
# id_token is stored on disk as the raw JWT string. Codex's token_data
# custom serde parses the struct fields out of the JWT on load (see
# codex-rs/login/src/token_data.rs), so we don't decode it here.

# Extract the `exp` (Unix seconds) claim from a JWT, or $null when the
# string is not a well-formed JWT carrying a numeric exp. Mirror of
# _jwt_exp in lib/cred/oauth-openai.sh: take the payload (2nd dot-
# segment), translate base64url '-_' → '+/', re-pad to a multiple of 4,
# base64-decode, and read .exp. Any malformed input is swallowed and
# returns $null so the caller falls back to the live userinfo probe.
function Get-JwtExp {
  param([string]$Jwt)
  if (-not $Jwt) { return $null }
  $parts = $Jwt.Split('.')
  if ($parts.Length -lt 2 -or -not $parts[1]) { return $null }
  $p = $parts[1].Replace('-', '+').Replace('_', '/')
  switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
  try {
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
    $doc = [Text.Json.JsonDocument]::Parse($payload)
    try {
      foreach ($prop in $doc.RootElement.EnumerateObject()) {
        if ($prop.Name -eq 'exp' -and
            $prop.Value.ValueKind -eq [Text.Json.JsonValueKind]::Number) {
          return $prop.Value.GetInt64()
        }
      }
    }
    finally { $doc.Dispose() }
  }
  catch { return $null }
  return $null
}

function Invoke-CredCheck {
  param(
    [Parameter(Mandatory)][string]$CredPath,
    [Parameter(Mandatory)][string]$OauthJsonPath
  )
  $credText = [IO.File]::ReadAllText($CredPath)
  $credNode = [Text.Json.Nodes.JsonNode]::Parse($credText)

  $accessToken = $null
  try { $accessToken = [string]$credNode['tokens']['access_token'] } catch {}
  if (-not $accessToken) {
    Write-Log E cred fail 'no OAuth credentials; run "codex login" to authenticate'
    throw 'no OAuth credentials'
  }

  # Codex treats BOTH tokens as expiry-bearing: the access_token
  # authorizes API calls and the id_token carries identity claims Codex
  # validates from the JWT on load. Mirror that — refresh pre-emptively
  # when EITHER JWT's own `exp` is at/past expiry, instead of relying on
  # the userinfo probe, which authenticates only the access_token and
  # can't see a stale id_token at all. Refreshing on an elapsed exp skips
  # a guaranteed-401 round-trip and the brief window where host/server
  # clock skew lets a dying token still probe 200; 60s of slack refreshes
  # marginally early rather than handing the agent a token that expires
  # mid-request. An ABSENT token also forces a refresh — Codex needs both,
  # so a missing one is an incomplete pair to repopulate. A token that is
  # present but carries no decodable numeric exp (opaque / missing claim)
  # is left to the live probe instead; if neither token triggers a
  # refresh, that probe runs unchanged.
  $idToken = $null
  try { $idToken = [string]$credNode['tokens']['id_token'] } catch {}
  $needRefresh = $false
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  foreach ($jwtPair in @(
      @{ Name = 'access_token'; Token = $accessToken },
      @{ Name = 'id_token'; Token = $idToken })) {
    if (-not $jwtPair.Token) {
      Write-Log I cred refresh "$($jwtPair.Name) missing; refreshing"
      $needRefresh = $true
      continue
    }
    $exp = Get-JwtExp $jwtPair.Token
    if ($null -eq $exp) { continue }
    if ($now -ge ($exp - 60)) {
      Write-Log I cred refresh "$($jwtPair.Name) jwt exp $($exp - $now)s away (<=60s); refreshing"
      $needRefresh = $true
    }
  }

  # HttpClient owned by this function — never leaks across the call
  # boundary. Validates the token (and refreshes on 401) on the same
  # connection pool, disposed before return.
  $http = [Net.Http.HttpClient]::new()
  $http.DefaultRequestHeaders.UserAgent.ParseAdd($crateUserAgent)
  try {
    if (-not $needRefresh) {
      $testReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://auth.openai.com/oauth/userinfo')
      $testReq.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $accessToken)
      $testRes = $http.SendAsync($testReq).Result

      if ($testRes.StatusCode -eq [Net.HttpStatusCode]::OK) {
        Write-Log I cred ok 'access token valid'
        return
      }
      if ($testRes.StatusCode -ne [Net.HttpStatusCode]::Unauthorized) {
        Write-Log E cred fail "credential check failed (HTTP $($testRes.StatusCode))"
        throw "credential check failed (HTTP $($testRes.StatusCode))"
      }

      Write-Log I cred refresh 'access token expired (HTTP 401)'
    }

    $refreshToken = $null
    try { $refreshToken = [string]$credNode['tokens']['refresh_token'] } catch {}
    if (-not $refreshToken) {
      Write-Log E cred fail 'token expired and no refresh token; run "codex login" to re-authenticate'
      throw 'no refresh token'
    }

    $oauthDoc = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($OauthJsonPath))
    $endpoint = $oauthDoc.RootElement.GetProperty('token_endpoint').GetString()
    $clientId = $oauthDoc.RootElement.GetProperty('client_id').GetString()
    $oauthDoc.Dispose()

    $bodyJson = [Text.Json.Nodes.JsonObject]::new()
    $bodyJson.Add('grant_type', [Text.Json.Nodes.JsonValue]::Create('refresh_token'))
    $bodyJson.Add('refresh_token', [Text.Json.Nodes.JsonValue]::Create($refreshToken))
    $bodyJson.Add('client_id', [Text.Json.Nodes.JsonValue]::Create($clientId))

    $refreshRes = $http.PostAsync(
      $endpoint,
      [Net.Http.StringContent]::new($bodyJson.ToJsonString(), [Text.Encoding]::UTF8, 'application/json')
    ).Result
    if (-not $refreshRes.IsSuccessStatusCode) {
      Write-Log E cred fail "OAuth refresh failed (HTTP $($refreshRes.StatusCode)); run 'codex login' to re-authenticate"
      throw "OAuth refresh failed"
    }

    $refreshJson = [Text.Json.JsonDocument]::Parse($refreshRes.Content.ReadAsStringAsync().Result)
    $r = $refreshJson.RootElement
    $newAccess = $r.GetProperty('access_token').GetString()
    $newId = $r.GetProperty('id_token').GetString()
    $newRefresh = try { $r.GetProperty('refresh_token').GetString() } catch { $null }
    $refreshJson.Dispose()

    $credNode['tokens']['access_token'] = [Text.Json.Nodes.JsonValue]::Create($newAccess)
    $credNode['tokens']['id_token'] = [Text.Json.Nodes.JsonValue]::Create($newId)
    if ($newRefresh) { $credNode['tokens']['refresh_token'] = [Text.Json.Nodes.JsonValue]::Create($newRefresh) }
    $credNode['last_refresh'] = [Text.Json.Nodes.JsonValue]::Create(
      [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    )

    # See oauth-anthropic.ps1 for why we use Write-CredInPlace instead
    # of WriteAllText or IO.File.Move.
    Write-CredInPlace -Path $CredPath -Content $credNode.ToJsonString()
    Write-Log I cred ok 'refreshed'
  }
  finally { $http.Dispose() }
}
