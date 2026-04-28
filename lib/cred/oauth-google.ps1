# oauth-google.ps1 — Google OAuth refresh strategy (Gemini CLI).
# Dot-sourced by Ensure-Credential.ps1. Defines Invoke-CredCheck.
#
# Live-probe: hit the Google userinfo endpoint with the access token in
# a Bearer header. 200 = valid, 401 = expired (refresh). Mirrors the
# Anthropic strategy — no timestamp math.

function Invoke-CredCheck {
  param(
    [Parameter(Mandatory)][string]$CredPath,
    [Parameter(Mandatory)][string]$OauthJsonPath
  )
  $credText = [IO.File]::ReadAllText($CredPath)
  $credNode = [Text.Json.Nodes.JsonNode]::Parse($credText)

  $accessToken = $null
  try { $accessToken = [string]$credNode['access_token'] } catch {}
  if (-not $accessToken) {
    Write-Log E cred fail 'no OAuth credentials; run "gemini" to authenticate'
    throw 'no OAuth credentials'
  }

  # HttpClient owned by this function — never leaks across the call
  # boundary. Validates the token (and refreshes on 401) on the same
  # connection pool, disposed before return.
  $http = [Net.Http.HttpClient]::new()
  $http.DefaultRequestHeaders.UserAgent.ParseAdd($crateUserAgent)
  try {
    $testReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://www.googleapis.com/oauth2/v3/userinfo')
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
    try { $refreshToken = [string]$credNode['refresh_token'] } catch {}
    if (-not $refreshToken) {
      Write-Log E cred fail 'token expired and no refresh token; run "gemini" to re-authenticate'
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
      Write-Log E cred fail "OAuth refresh failed (HTTP $($refreshRes.StatusCode)); run 'gemini' to re-authenticate"
      throw "OAuth refresh failed"
    }

    $refreshJson = [Text.Json.JsonDocument]::Parse($refreshRes.Content.ReadAsStringAsync().Result)
    $r = $refreshJson.RootElement
    $newAccess = $r.GetProperty('access_token').GetString()
    # Google omits expires_in on some refresh responses; fall back to the
    # documented 1h default so expiry_date stays sensible.
    $expiresIn = try { $r.GetProperty('expires_in').GetInt64() } catch { 3600 }
    $newId = try { $r.GetProperty('id_token').GetString() } catch { $null }
    $refreshJson.Dispose()

    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $credNode['access_token'] = [Text.Json.Nodes.JsonValue]::Create($newAccess)
    $credNode['expiry_date'] = [Text.Json.Nodes.JsonValue]::Create($nowMs + $expiresIn * 1000)
    if ($newId) { $credNode['id_token'] = [Text.Json.Nodes.JsonValue]::Create($newId) }

    # See oauth-anthropic.ps1 for why we use Write-CredInPlace instead
    # of WriteAllText or IO.File.Move.
    Write-CredInPlace -Path $CredPath -Content $credNode.ToJsonString()
    Write-Log I cred ok "refreshed (expires in ${expiresIn}s)"
  }
  finally { $http.Dispose() }
}
