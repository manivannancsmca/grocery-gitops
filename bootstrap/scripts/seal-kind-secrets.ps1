<#
.SYNOPSIS
    Creates the Kind environment's secrets with random values and writes them into the repository as SealedSecrets.

.DESCRIPTION
    Only SealedSecrets (encrypted with the cluster's public key) are written into the repository; only the Sealed
    Secrets controller in the cluster can decrypt them. The plain values are kept outside Git in
    %USERPROFILE%\.grocery-gitops\kind-secrets.json, so re-running the script re-uses them (MySQL users and the
    services always agree) and a recreated cluster gets the same passwords.

    Writes (namespace / secret -> file):
      grocery-infra / mysql-root               infrastructure/mysql/overlays/kind/mysql-root.sealed.yaml
      grocery-infra / mysql-users              infrastructure/mysql/overlays/kind/mysql-users.sealed.yaml
      grocery / <service>-db                   services/<service>/overlays/kind/db.sealed.yaml
      grocery / identity-service-admin         services/identity-service/overlays/kind/admin.sealed.yaml

    Existing sealed files are left alone unless -Force is given (sealing again produces different ciphertext, which
    would be a meaningless Git change). The public certificate is saved to bootstrap/kind/sealed-secrets-cert.pem, so
    anyone can seal a value for this cluster without cluster access:
      kubeseal --cert bootstrap/kind/sealed-secrets-cert.pem --format yaml < secret.yaml > secret.sealed.yaml

.EXAMPLE
    .\bootstrap\scripts\seal-kind-secrets.ps1
#>
[CmdletBinding()]
param(
    [string] $Context = 'kind-grocery',
    [string] $SecretsDir = (Join-Path $HOME '.grocery-gitops'),
    [switch] $Force
)
$ErrorActionPreference = 'Continue'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$kubeseal = (Get-Command kubeseal -ErrorAction SilentlyContinue).Source
if (-not $kubeseal) { $kubeseal = Join-Path $env:LOCALAPPDATA 'Programs\kubeseal\kubeseal.exe' }
if (-not (Test-Path $kubeseal)) { throw 'kubeseal not found (PATH or %LOCALAPPDATA%\Programs\kubeseal)' }

function New-RandomPassword {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'x')
}

# service -> MySQL user (the SQL in grocery-ai-app infrastructure/local/mysql/init creates these users)
$dbUsers = [ordered]@{
    'identity-service'        = 'identity_user'
    'customer-service'        = 'customer_user'
    'vendor-service'          = 'vendor_user'
    'restaurant-service'      = 'restaurant_user'
    'catalog-command-service' = 'catalog_user'
    'inventory-service'       = 'inventory_user'
    'pricing-service'         = 'pricing_user'
    'order-service'           = 'order_user'
    'payment-service'         = 'payment_user'
    'delivery-service'        = 'delivery_user'
    'notification-service'    = 'notification_user'
    'review-service'          = 'review_user'
    'ai-orchestrator-service' = 'ai_user'
    'reporting-service'       = 'reporting_user'
}
$otherUsers = 'debezium', 'monitoring_user'

# ------------------------------------------------------------------------------------------- plain values (local)
New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
$valuesFile = Join-Path $SecretsDir 'kind-secrets.json'
$values = @{}
if (Test-Path $valuesFile) {
    (Get-Content $valuesFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $values[$_.Name] = $_.Value }
}
$keys = @('MYSQL_ROOT_PASSWORD', 'BOOTSTRAP_ADMIN_PASSWORD') +
    @($dbUsers.Values | ForEach-Object { "$($_.ToUpper())_PASSWORD" }) +
    @($otherUsers | ForEach-Object { "$($_.ToUpper())_PASSWORD" })
$changed = $false
foreach ($key in $keys) {
    if (-not $values[$key]) { $values[$key] = New-RandomPassword; $changed = $true }
}
if (-not $values['BOOTSTRAP_ADMIN_EMAIL']) { $values['BOOTSTRAP_ADMIN_EMAIL'] = 'admin@grocery.local'; $changed = $true }
if ($changed) {
    $values | ConvertTo-Json | Set-Content -Path $valuesFile -Encoding utf8
    Write-Host "Plain values saved to $valuesFile (outside Git)."
}

# ----------------------------------------------------------------------------------------------- certificate
$cert = Join-Path $Root 'bootstrap\kind\sealed-secrets-cert.pem'
& $kubeseal --context $Context --controller-namespace kube-system --controller-name sealed-secrets-controller `
    --fetch-cert | Set-Content -Path $cert -Encoding ascii
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the Sealed Secrets certificate (is the controller running?)' }

# Seals one Secret (namespace, name, key/value map) into a file, unless it exists already.
function Write-SealedSecret([string] $Namespace, [string] $Name, [hashtable] $Data, [string] $RelativePath) {
    $file = Join-Path $Root $RelativePath
    if ((Test-Path $file) -and -not $Force) { Write-Host "  keep   $RelativePath"; return }
    $secret = [ordered]@{
        apiVersion = 'v1'; kind = 'Secret'
        metadata   = [ordered]@{ name = $Name; namespace = $Namespace }
        type       = 'Opaque'
        stringData = $Data
    }
    $json = $secret | ConvertTo-Json -Depth 5
    $sealed = $json | & $kubeseal --cert $cert --format yaml
    if ($LASTEXITCODE -ne 0 -or -not $sealed) { throw "kubeseal failed for $Namespace/$Name" }
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $header = "# SealedSecret $Namespace/$Name - generated by bootstrap/scripts/seal-kind-secrets.ps1; decryptable only by the Kind cluster's controller."
    (@($header) + $sealed) | Set-Content -Path $file -Encoding utf8
    Write-Host "  sealed $RelativePath"
}

Write-Host 'Sealing secrets for the Kind cluster:'
Write-SealedSecret 'grocery-infra' 'mysql-root' @{ MYSQL_ROOT_PASSWORD = $values['MYSQL_ROOT_PASSWORD'] } `
    'infrastructure\mysql\overlays\kind\mysql-root.sealed.yaml'

$userPasswords = @{}
foreach ($user in @($dbUsers.Values) + $otherUsers) {
    $key = "$($user.ToUpper())_PASSWORD"
    $userPasswords[$key] = $values[$key]
}
Write-SealedSecret 'grocery-infra' 'mysql-users' $userPasswords 'infrastructure\mysql\overlays\kind\mysql-users.sealed.yaml'

foreach ($service in $dbUsers.Keys) {
    $key = "$($dbUsers[$service].ToUpper())_PASSWORD"
    Write-SealedSecret 'grocery' "$service-db" @{ DB_PASSWORD = $values[$key] } "services\$service\overlays\kind\db.sealed.yaml"
}
Write-SealedSecret 'grocery' 'identity-service-admin' @{
    BOOTSTRAP_ADMIN_EMAIL    = $values['BOOTSTRAP_ADMIN_EMAIL']
    BOOTSTRAP_ADMIN_PASSWORD = $values['BOOTSTRAP_ADMIN_PASSWORD']
} 'services\identity-service\overlays\kind\admin.sealed.yaml'

Write-Host "Done. The bootstrap admin is $($values['BOOTSTRAP_ADMIN_EMAIL']); its password is in $valuesFile."
