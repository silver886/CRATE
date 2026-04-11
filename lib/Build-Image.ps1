# Build-Image.ps1 — build Podman base image if needed.
# Dot-sourced (not executed). Requires: $projectRoot, $sha256 (from Tools.ps1)
# Reads: $Image (base OS image name), $forcePull
#
# $buildBaseImage: ensures the base container image exists.
# Sets: $imageTag

$imageSrc = {
  [IO.File]::ReadAllText("$projectRoot\Containerfile") +
  [IO.File]::ReadAllText("$projectRoot\bin\enable-dnf.sh") +
  [IO.File]::ReadAllText("$projectRoot\bin\setup-tools.sh") +
  [IO.File]::ReadAllText("$projectRoot\config\sudoers-claude-enable-dnf")
}

$buildBaseImage = {
  $script:imageTag = "claude-base-$(& $sha256 "$(& $imageSrc)-$Image")"
  podman image exists $script:imageTag 2>$null
  if ($LASTEXITCODE -ne 0 -or $forcePull) {
    $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $script:imageTag)
    if ($forcePull) { $buildArgs += '--no-cache' }
    $buildArgs += $projectRoot
    Invoke-Must podman @buildArgs
  }
}
