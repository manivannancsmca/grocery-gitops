<#
.SYNOPSIS
    Deletes the local Kind cluster (and with it every volume on it). Backs up the Sealed Secrets key first.

.DESCRIPTION
    Kind keeps its volumes inside the node containers, so the Retain storage class protects data from mistakes
    inside the cluster, not from deleting the cluster itself. Recreate with bootstrap-kind.ps1.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ClusterName = 'grocery',
    [string] $SecretsDir = (Join-Path $HOME '.grocery-gitops')
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'backup-sealing-key.ps1') -Context "kind-$ClusterName" -SecretsDir $SecretsDir
if ($PSCmdlet.ShouldProcess("Kind cluster '$ClusterName' and all of its data", 'Delete')) {
    kind delete cluster --name $ClusterName
}
