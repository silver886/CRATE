# oauth-antigravity.ps1 — Google OAuth refresh strategy for the
# antigravity-cli agent. Dot-sourced by Ensure-Credential.ps1. Defines
# Invoke-CredCheck. Mirror of lib/cred/oauth-antigravity.sh.
#
# antigravity-cli stores credentials in a nested shape distinct from
# Gemini's flat google-auth-library object, so it needs its own strategy:
#
#   { "token": { "access_token", "token_type", "refresh_token",
#                "expiry" (RFC3339 string) },
#     "auth_method": "consumer" }
#
# Live-probe: hit the Google v2 userinfo endpoint with the access token
# in a Bearer header. 200 = valid, 401 = expired (refresh). The
# access_token is an opaque `ya29.` token (not a JWT) and the RFC3339
# `expiry` string isn't parsed — the live probe tolerates clock skew and
# catches server-side revocation. Same approach as oauth-google.ps1.

function Invoke-CredCheck {
  param(
    [Parameter(Mandatory)][string]$CredPath,
    [Parameter(Mandatory)][string]$OauthJsonPath
  )
  $credText = [IO.File]::ReadAllText($CredPath)
  $credNode = [Text.Json.Nodes.JsonNode]::Parse($credText)

  $accessToken = $null
  try { $accessToken = [string]$credNode['token']['access_token'] } catch {}
  if (-not $accessToken) {
    Write-Log E cred fail 'no OAuth credentials; run "antigravity" to authenticate'
    throw 'no OAuth credentials'
  }

  # HttpClient owned by this function — never leaks across the call
  # boundary. Validates the token (and refreshes on 401) on the same
  # connection pool, disposed before return.
  $http = [Net.Http.HttpClient]::new()
  $http.DefaultRequestHeaders.UserAgent.ParseAdd($crateUserAgent)
  try {
    $testReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://www.googleapis.com/oauth2/v2/userinfo')
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
    $refreshToken = $null
    try { $refreshToken = [string]$credNode['token']['refresh_token'] } catch {}
    if (-not $refreshToken) {
      Write-Log E cred fail 'token expired and no refresh token; run "antigravity" to re-authenticate'
      throw 'no refresh token'
    }

    $oauthDoc = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($OauthJsonPath))
    $endpoint = $oauthDoc.RootElement.GetProperty('token_endpoint').GetString()
    $clientId = $oauthDoc.RootElement.GetProperty('client_id').GetString()
    $clientSecret = $oauthDoc.RootElement.GetProperty('client_secret').GetString()
    $oauthDoc.Dispose()

    $form = [Collections.Generic.List[Collections.Generic.KeyValuePair[string, string]]]::new()
    $form.Add([Collections.Generic.KeyValuePair[string, string]]::new('grant_type', 'refresh_token'))
    $form.Add([Collections.Generic.KeyValuePair[string, string]]::new('refresh_token', $refreshToken))
    $form.Add([Collections.Generic.KeyValuePair[string, string]]::new('client_id', $clientId))
    $form.Add([Collections.Generic.KeyValuePair[string, string]]::new('client_secret', $clientSecret))
    $formContent = [Net.Http.FormUrlEncodedContent]::new($form)

    $refreshRes = $http.PostAsync($endpoint, $formContent).Result
    if (-not $refreshRes.IsSuccessStatusCode) {
      Write-Log E cred fail "OAuth refresh failed (HTTP $($refreshRes.StatusCode)); run 'antigravity' to re-authenticate"
      throw "OAuth refresh failed"
    }

    $refreshJson = [Text.Json.JsonDocument]::Parse($refreshRes.Content.ReadAsStringAsync().Result)
    $r = $refreshJson.RootElement
    $newAccess = $r.GetProperty('access_token').GetString()
    # Google omits expires_in on some refresh responses; fall back to the
    # documented 1h default so the written expiry stays sensible.
    $expiresIn = try { $r.GetProperty('expires_in').GetInt64() } catch { 3600 }
    $newRefresh = try { $r.GetProperty('refresh_token').GetString() } catch { $null }
    $refreshJson.Dispose()

    # antigravity stores expiry as an RFC3339 timestamp. Write it as UTC
    # 'Z' — Go's time.Parse(RFC3339[Nano]) accepts it. Byte-format parity
    # with lib/cred/oauth-antigravity.sh's jq todateiso8601 (seconds
    # precision, no fractional).
    $expiry = [DateTimeOffset]::UtcNow.AddSeconds($expiresIn).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $credNode['token']['access_token'] = [Text.Json.Nodes.JsonValue]::Create($newAccess)
    $credNode['token']['expiry'] = [Text.Json.Nodes.JsonValue]::Create($expiry)
    if ($newRefresh) { $credNode['token']['refresh_token'] = [Text.Json.Nodes.JsonValue]::Create($newRefresh) }

    # See oauth-anthropic.ps1 for why we use Write-CredInPlace instead of
    # WriteAllText or IO.File.Move.
    Write-CredInPlace -Path $CredPath -Content $credNode.ToJsonString()
    Write-Log I cred ok "refreshed (expires in ${expiresIn}s)"
  }
  finally { $http.Dispose() }
}
