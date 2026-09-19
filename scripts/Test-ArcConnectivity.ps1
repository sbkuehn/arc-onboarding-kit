<#
.SYNOPSIS
    Read-only connectivity check for the core Azure Arc endpoints.

.DESCRIPTION
    Tests DNS resolution and TCP 443 for the endpoints the Connected Machine
    Agent needs before and after installation. Makes no changes to the machine.

    Use this when you want evidence before opening a ticket with the network
    team. Once azcmagent is installed, prefer "azcmagent check", which knows
    the full endpoint list for the features you have enabled.

.PARAMETER Region
    Optional Azure region short name (e.g. eastus2). Adds the regional HIS
    and guest configuration endpoints to the test list.

.NOTES
    Author: Shannon Eldridge-Kuehn
    Created: September 2026

.EXAMPLE
    .\Test-ArcConnectivity.ps1 -Region eastus2
#>
[CmdletBinding()]
param(
    [string]$Region
)

$endpoints = @(
    'login.microsoftonline.com',
    'login.microsoft.com',
    'pas.windows.net',
    'management.azure.com',
    'gbl.his.arc.azure.com',
    'guestnotificationservice.azure.com',
    'download.microsoft.com',
    'packages.microsoft.com'
)

if ($Region) {
    $endpoints += "$Region.his.arc.azure.com"
    $endpoints += "agentserviceapi.guestconfiguration.azure.com"
}

$results = foreach ($host_ in $endpoints) {
    $dns = $null
    try {
        $dns = (Resolve-DnsName -Name $host_ -Type A -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1).IPAddress
    } catch { }

    $tcp = $false
    if ($dns) {
        $tnc = Test-NetConnection -ComputerName $host_ -Port 443 -WarningAction SilentlyContinue
        $tcp = $tnc.TcpTestSucceeded
    }

    [pscustomobject]@{
        Endpoint = $host_
        Resolved = if ($dns) { $dns } else { 'NO' }
        Tcp443   = if ($tcp) { 'OK' } else { 'FAIL' }
    }
}

$results | Format-Table -AutoSize

$failed = $results | Where-Object { $_.Tcp443 -eq 'FAIL' }
if ($failed) {
    Write-Host ""
    Write-Host "One or more endpoints failed. Those are network problems." -ForegroundColor Yellow
    Write-Host "Remember: an HTTP 400 from an endpoint that resolves and connects is not a network problem." -ForegroundColor Yellow
    exit 1
}

Write-Host "All core endpoints resolve and accept connections on 443." -ForegroundColor Green
