# oauth-openai.ps1 — OpenAI Codex PKCE public-client refresh strategy.
# Dot-sourced by Ensure-Credential.ps1. Defines Invoke-CredCheck.
#
# Live-probe: hit auth.openai.com/oauth/userinfo with the access token
# in a Bearer header. 200 = valid, 401 = expired (refresh). Mirrors the
# Anthropic / Google strategies — no timestamp math.
#
# id_token is stored on disk as the raw JWT string. Codex's token_data
# custom serde parses the struct fields out of the JWT on load (see
# codex-rs/login/src/token_data.rs), so we don't decode it here.

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

  # HttpClient owned by this function — never leaks across the call
  # boundary. Validates the token (and refreshes on 401) on the same
  # connection pool, disposed before return.
  $http = [Net.Http.HttpClient]::new()
  $http.DefaultRequestHeaders.UserAgent.ParseAdd($crateUserAgent)
  try {
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
