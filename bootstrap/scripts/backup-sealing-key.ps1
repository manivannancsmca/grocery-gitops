<#
.SYNOPSIS
    Backs up the Sealed Secrets private key(s) of the cluster to %USERPROFILE%\.grocery-gitops\sealed-secrets-key.yaml.

.DESCRIPTION
    SealedSecrets in Git can only be decrypted by the key of the cluster that sealed them. Recreating the Kind
    cluster creates a new key unless this backup is restored first (bootstrap-kind.ps1 does that automatically).
    The file decrypts every secret in the repository: keep it out of Git and out of shared folders.
    Existing backups are not overwritten unless -Force is given.
#>
[CmdletBinding()]
param(
    [string] $Context = 'kind-grocery',
    [string] $SecretsDir = (Join-Path $HOME '.grocery-gitops'),
    [switch] $Force
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $SecretsDir 'sealed-secrets-key.yaml'
if ((Test-Path $file) -and -not $Force) {
    Write-Host "Sealed Secrets key backup already exists: $file"
    return
}
$yaml = & kubectl get secret --context $Context -n kube-system `
    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml
if ($LASTEXITCODE -ne 0 -or -not ($yaml -match 'tls.key')) {
    Write-Warning 'No Sealed Secrets key found yet (is the controller running?). Run this script again later.'
    return
}
New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
$yaml | Set-Content -Path $file -Encoding utf8
Write-Host "Sealed Secrets key backed up to $file"
