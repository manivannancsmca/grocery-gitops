<#
.SYNOPSIS
    Creates the local Kind cluster and hands it to Argo CD (GitOps bootstrap). Safe to run again.

.DESCRIPTION
    The only imperative step of the whole setup. It:
      1. creates the Kind cluster "grocery" (bootstrap/kind/cluster.yaml) if it does not exist;
      2. restores the Sealed Secrets key from a local backup, so SealedSecrets committed to Git still decrypt;
      3. installs Argo CD with Helm, using the same chart version and values files the "argocd" Application uses;
      4. registers the GitOps repository with the read-only deploy key (never committed);
      5. applies the AppProjects and the root Application; from here Argo CD deploys everything else from Git;
      6. gives the local accounts "developer" and "release-manager" random passwords;
      7. waits for the platform Applications and backs up the Sealed Secrets key.

    Local secrets live in %USERPROFILE%\.grocery-gitops (outside every repository):
      argocd-deploy-key          SSH private key; its public half is a read-only deploy key on GitHub
      argocd-accounts.txt        passwords of the local Argo CD accounts
      sealed-secrets-key.yaml    backup of the Sealed Secrets private key (keep it safe; it decrypts every secret)

.EXAMPLE
    .\bootstrap\scripts\bootstrap-kind.ps1
#>
[CmdletBinding()]
param(
    [string] $ClusterName = 'grocery',
    [string] $SecretsDir = (Join-Path $HOME '.grocery-gitops'),
    [string] $RepoUrl = 'git@github.com:manivannancsmca/grocery-gitops.git',
    [int] $TimeoutMinutes = 20
)

# Windows PowerShell 5.1 turns a native tool's stderr output into errors, which would stop the script on harmless
# progress messages. So errors continue here, and every native call's exit code is checked explicitly instead.
$ErrorActionPreference = 'Continue'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ArgoChartVersion = '10.18.2'          # keep equal to app-of-apps/kind/platform/argocd.yaml
$Context = "kind-$ClusterName"

# Runs a native command and stops the script when it fails (PowerShell 5.1 does not do that by itself).
function Invoke-Native {
    param([Parameter(Mandatory)] [string] $Command, [Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE" }
}

function Write-Step([string] $Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

function New-RandomPassword {
    $bytes = New-Object byte[] 18
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'x')
}

# ------------------------------------------------------------------------------------------------------ preflight
Write-Step 'Checking tools and files'
foreach ($tool in 'docker', 'kind', 'kubectl', 'helm', 'argocd') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed or not on PATH" }
}
$deployKey = Join-Path $SecretsDir 'argocd-deploy-key'
if (-not (Test-Path $deployKey)) {
    throw "Deploy key not found: $deployKey. Create it with: ssh-keygen -t ed25519 -N '' -f `"$deployKey`" and add the .pub file as a read-only deploy key of the GitOps repository."
}
$dockerMemGiB = [math]::Round(([double](docker info --format '{{.MemTotal}}')) / 1GB, 1)
Write-Host "Docker memory: $dockerMemGiB GiB (the full platform needs about 13 GiB free; stop the Compose stack first)"

# --------------------------------------------------------------------------------------------------- 1. cluster
Write-Step "Kind cluster '$ClusterName'"
$clusters = @(kind get clusters 2>$null)
if ($clusters -contains $ClusterName) {
    Write-Host 'Already exists.'
} else {
    Invoke-Native kind create cluster --config (Join-Path $Root 'bootstrap\kind\cluster.yaml') --wait 180s
}
Invoke-Native kubectl config use-context $Context

# ------------------------------------------------------------------------------------------ 2. sealing key restore
$keyBackup = Join-Path $SecretsDir 'sealed-secrets-key.yaml'
if (Test-Path $keyBackup) {
    Write-Step 'Restoring the Sealed Secrets key from the local backup'
    Invoke-Native kubectl apply --context $Context -n kube-system -f $keyBackup
}

# ------------------------------------------------------------------------------------------------- 3. Argo CD
Write-Step "Argo CD (Helm chart argo-cd $ArgoChartVersion)"
Invoke-Native helm repo add argo https://argoproj.github.io/argo-helm --force-update
Invoke-Native helm upgrade --install argocd argo/argo-cd --kube-context $Context `
    --version $ArgoChartVersion --namespace argocd --create-namespace `
    -f (Join-Path $Root 'bootstrap\argocd\values-common.yaml') `
    -f (Join-Path $Root 'bootstrap\argocd\values-kind.yaml') `
    --wait --timeout 10m

# -------------------------------------------------------------------------------------- 4. repository credential
Write-Step 'Registering the GitOps repository (read-only deploy key)'
$secretYaml = & kubectl create secret generic repo-grocery-gitops --namespace argocd `
    --from-literal=type=git --from-literal=url=$RepoUrl --from-literal=name=grocery-gitops `
    --from-file=sshPrivateKey=$deployKey --dry-run=client -o yaml
if ($LASTEXITCODE -ne 0) { throw 'Could not render the repository secret' }
$secretYaml | kubectl apply --context $Context -f -
if ($LASTEXITCODE -ne 0) { throw 'Could not apply the repository secret' }
Invoke-Native kubectl label secret repo-grocery-gitops --context $Context -n argocd `
    argocd.argoproj.io/secret-type=repository --overwrite

# ----------------------------------------------------------------------------------- 5. projects + root app
Write-Step 'Applying Helm repositories, AppProjects and the root Application'
Invoke-Native kubectl apply --context $Context -k (Join-Path $Root 'bootstrap\argocd')
Invoke-Native kubectl apply --context $Context -k (Join-Path $Root 'projects\kind')
Invoke-Native kubectl apply --context $Context -f (Join-Path $Root 'roots\kind.yaml')

# ------------------------------------------------------------------------------------ 6. local account passwords
$accountsFile = Join-Path $SecretsDir 'argocd-accounts.txt'
if (-not (Test-Path $accountsFile)) {
    Write-Step 'Setting passwords for the local accounts developer and release-manager'
    $lines = @('# Argo CD local accounts on the Kind cluster (http://argocd.localtest.me). Not in Git.')
    $patch = @{ stringData = @{} }
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($account in 'developer', 'release-manager') {
        $password = New-RandomPassword
        $hash = (& argocd account bcrypt --password $password).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'argocd account bcrypt failed' }
        $patch.stringData["accounts.$account.password"] = $hash
        $patch.stringData["accounts.$account.passwordMtime"] = $now
        $lines += "$account = $password"
    }
    $patchFile = Join-Path $SecretsDir 'argocd-secret-patch.json'
    $patch | ConvertTo-Json -Compress | Set-Content -Path $patchFile -Encoding ascii -ErrorAction Stop
    try {
        Invoke-Native kubectl patch secret argocd-secret --context $Context -n argocd --type merge --patch-file $patchFile
    } finally {
        Remove-Item $patchFile -ErrorAction SilentlyContinue
    }
    $lines | Set-Content -Path $accountsFile -Encoding utf8 -ErrorAction Stop
    Write-Host "Saved to $accountsFile"
}

# ------------------------------------------------------------------------------------------ 7. wait for platform
Write-Step 'Waiting for the platform Applications to be Synced and Healthy'
$platformApps = 'cluster-base', 'sealed-secrets', 'metrics-server', 'envoy-gateway', 'gateway', 'argocd'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 10
    $rows = & kubectl get applications.argoproj.io --context $Context -n argocd `
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"\n"}{end}' 2>$null
    $state = @{}
    foreach ($row in $rows) { if ($row) { $p = $row.Split('|'); $state[$p[0]] = "$($p[1])/$($p[2])" } }
    $pending = @($platformApps | Where-Object { $state[$_] -ne 'Synced/Healthy' })
    Write-Host ("  " + (($platformApps | ForEach-Object { "$_=$(if ($state[$_]) { $state[$_] } else { 'missing' })" }) -join '  '))
} while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
if ($pending.Count -gt 0) {
    Write-Warning "Not ready after $TimeoutMinutes minutes: $($pending -join ', '). See docs/troubleshooting.md."
}

# ------------------------------------------------------------------------------------------ 8. sealing key backup
& (Join-Path $PSScriptRoot 'backup-sealing-key.ps1') -Context $Context -SecretsDir $SecretsDir

Write-Step 'Done'
Write-Host 'Argo CD UI : http://argocd.localtest.me'
Write-Host "  developer, release-manager : passwords in $accountsFile"
Write-Host '  admin (break-glass)        : argocd admin initial-password -n argocd'
Write-Host 'Argo CD CLI: argocd login argocd.localtest.me --grpc-web --plaintext --username developer'
