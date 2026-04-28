# Build-Image.ps1 — build Podman base image if needed.
# Dot-sourced (not executed). Requires: $projectRoot
# Reads: $Image (base OS image name), $forcePull
#
# Sets: $imageTag (via $script:)
#
# Top-level surface is $buildBaseImage only — sha256 helper and the
# image-source enumeration are scoped inside it so dot-sourcing this
# file doesn't pollute the launcher scope.

$buildBaseImage = {
  $sha256 = {
    [BitConverter]::ToString(
      [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
    ).Replace('-', '').ToLower()
  }

  $imageSrc = {
    $files = @(
      "$projectRoot\Containerfile",
      "$projectRoot\.containerignore",
      "$projectRoot\lib\log.sh",
      "$projectRoot\bin\enable-dnf.sh",
      "$projectRoot\bin\setup-tools.sh",
      "$projectRoot\config\sudoers-enable-dnf.tmpl"
    )
    $sb = [Text.StringBuilder]::new(256)
    foreach ($f in $files) {
      [void]$sb.Append((& $sha256 (& $lfOnly ([IO.File]::ReadAllText($f)))))
    }
    $sb.ToString()
  }

  $script:imageTag = "crate-base-$(& $sha256 "$(& $imageSrc)-$Image")"
  podman image exists $script:imageTag 2>$null
  if ($LASTEXITCODE -eq 0 -and -not $forcePull) {
    Write-Log I image cache-hit $script:imageTag
    return
  }
  Write-Log I image build $script:imageTag
  $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $script:imageTag)
  if ($forcePull) { $buildArgs += '--no-cache' }
  if ($selinuxOpt) { $buildArgs += $selinuxOpt }
  $buildArgs += $projectRoot
  Invoke-Must podman @buildArgs
  Write-Log I image built $script:imageTag
}
