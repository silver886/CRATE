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
  # Resolve junction/symlink aliases in $projectRoot before passing it
  # as the build context. On Windows, podman archives the context by
  # physical path; an alias path (junction or symlink) can fail
  # mid-tar — the practical reason for this resolve. ResolveLinkTarget
  # is .NET 6+ (PS 7+); when $projectRoot is itself a reparse point we
  # walk it, otherwise .FullName already gives a normalized path with
  # `.`/`..` collapsed. This does NOT walk parent components — if a
  # caller's working tree is reached through a junction'd ancestor,
  # invoke from the canonical path or set CRATE_BUILD_CTX explicitly.
  $rootItem = Get-Item -LiteralPath $projectRoot
  $buildCtx = if ($rootItem.LinkType) {
    $rootItem.ResolveLinkTarget($true).FullName
  }
  else {
    $rootItem.FullName
  }
  $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $script:imageTag)
  if ($forcePull) { $buildArgs += '--no-cache' }
  if ($selinuxOpt) { $buildArgs += $selinuxOpt }
  $buildArgs += '-f'
  $buildArgs += (Join-Path $buildCtx 'Containerfile')
  $buildArgs += $buildCtx
  Invoke-Must podman @buildArgs
  Write-Log I image built $script:imageTag
}
