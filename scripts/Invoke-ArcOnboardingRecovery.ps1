<#
.SYNOPSIS
    Layer-by-layer Azure Arc onboarding for Windows Server when the generated
    portal script fails.

.DESCRIPTION
    Proves each dependency independently and stops at the first real failure:

      1. TCP 443 to the Hybrid Identity Service endpoint
      2. Download the Azure Connected Machine Agent MSI
      3. Install the agent (quiet, with verbose MSI log)
      4. Confirm the himds service is running
      5. Confirm azcmagent responds
      6. Run azcmagent check (agent-driven network validation)
      7. Run azcmagent connect (optional, requires -Connect)
      8. Run azcmagent show

    Companion to the Cloudy Musings post "When Azure Arc Says 400 Bad Request,
    the Network Is Probably Fine".

.PARAMETER SubscriptionId
    Target subscription for the Arc resource. Required with -Connect.

.PARAMETER ResourceGroup
    Target resource group. Required with -Connect.

.PARAMETER Location
    Azure region (e.g. eastus2). Required with -Connect.

.PARAMETER TenantId
    Optional tenant ID passed to azcmagent connect.

.PARAMETER Tags
    Optional hashtable of tags applied to the Arc resource.

.PARAMETER Connect
    Run azcmagent connect after the agent is installed and validated.
    Without this switch the script stops after azcmagent check.

.PARAMETER UseDeviceCode
    Use device-code authentication for an interactive connect.

.PARAMETER SkipInstall
    Skip download and install if the agent is already present.

.EXAMPLE
    .\Invoke-ArcOnboardingRecovery.ps1

    Validates connectivity, downloads and installs the agent, and runs
    azcmagent check. Does not connect.

.EXAMPLE
    .\Invoke-ArcOnboardingRecovery.ps1 -Connect -UseDeviceCode `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -ResourceGroup "rg-arc-servers" -Location "eastus2"

.NOTES
    Run from an elevated PowerShell session on the target server.
    Requires PowerShell 5.1 or later.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$TenantId,
    [hashtable]$Tags,
    [switch]$Connect,
    [switch]$UseDeviceCode,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$HisEndpoint  = 'gbl.his.arc.azure.com'
$AgentUri     = 'https://aka.ms/AzureConnectedMachineAgent'
$MsiPath      = Join-Path $env:TEMP 'AzureConnectedMachineAgent.msi'
$MsiLogPath   = Join-Path $env:TEMP 'AzureConnectedMachineAgent.log'
$AgentExe     = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
$HimdsLog     = Join-Path $env:ProgramData 'AzureConnectedMachineAgent\Log\himds.log'

function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $Number, $Text) -ForegroundColor Cyan
}

function Write-Ok   { param([string]$Text) Write-Host ("    OK   {0}" -f $Text) -ForegroundColor Green }
function Write-Fail { param([string]$Text) Write-Host ("    FAIL {0}" -f $Text) -ForegroundColor Red }

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw "This script must run from an elevated PowerShell session."
}

if ($Connect -and (-not $SubscriptionId -or -not $ResourceGroup -or -not $Location)) {
    throw "-Connect requires -SubscriptionId, -ResourceGroup, and -Location."
}

# ---------------------------------------------------------------------------
# 1. TCP 443 to HIS endpoint
# ---------------------------------------------------------------------------
Write-Step 1 "Testing TCP 443 to $HisEndpoint"
$tnc = Test-NetConnection -ComputerName $HisEndpoint -Port 443 -WarningAction SilentlyContinue
if (-not $tnc.TcpTestSucceeded) {
    Write-Fail "Could not reach $HisEndpoint on 443. Resolved: $($tnc.RemoteAddress). This is a network problem."
    exit 1
}
Write-Ok "Reached $($tnc.RemoteAddress):443"

# ---------------------------------------------------------------------------
# 2-3. Download and install the agent
# ---------------------------------------------------------------------------
if ($SkipInstall -and (Test-Path $AgentExe)) {
    Write-Step 2 "Skipping download and install (agent already present)"
} else {
    Write-Step 2 "Downloading Connected Machine Agent from $AgentUri"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $AgentUri -OutFile $MsiPath
    } catch {
        Write-Fail "Download failed: $($_.Exception.Message)"
        Write-Host "    Outbound HTTPS to Microsoft download infrastructure is not working." -ForegroundColor Yellow
        exit 1
    }
    $size = [math]::Round((Get-Item $MsiPath).Length / 1MB, 1)
    Write-Ok "Saved $MsiPath ($size MB)"

    Write-Step 3 "Installing agent quietly (log: $MsiLogPath)"
    $proc = Start-Process -FilePath msiexec.exe `
        -ArgumentList "/i `"$MsiPath`" /qn /l*v `"$MsiLogPath`"" `
        -Wait -PassThru
    if ($proc.ExitCode -notin 0, 3010) {
        Write-Fail "msiexec exited with $($proc.ExitCode). Review $MsiLogPath"
        exit 1
    }
    Write-Ok "msiexec exit code $($proc.ExitCode)"
    if ($proc.ExitCode -eq 3010) {
        Write-Host "    A reboot is pending. Continuing, but reboot before relying on this machine." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 4. himds service
# ---------------------------------------------------------------------------
Write-Step 4 "Checking Azure Hybrid Instance Metadata Service (himds)"
$svc = Get-Service -Name himds -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Fail "himds service not found. The install did not complete. Review $MsiLogPath"
    exit 1
}
if ($svc.Status -ne 'Running') {
    Write-Host "    himds is $($svc.Status). Attempting to start." -ForegroundColor Yellow
    Start-Service himds
    $svc.Refresh()
}
if ($svc.Status -ne 'Running') {
    Write-Fail "himds would not start. Review $HimdsLog"
    exit 1
}
Write-Ok "himds is running"

# ---------------------------------------------------------------------------
# 5. azcmagent version
# ---------------------------------------------------------------------------
Write-Step 5 "Checking azcmagent binary"
if (-not (Test-Path $AgentExe)) {
    Write-Fail "azcmagent.exe not found at $AgentExe"
    exit 1
}
$version = & $AgentExe version 2>&1
Write-Ok ($version | Out-String).Trim()

# ---------------------------------------------------------------------------
# 6. azcmagent check
# ---------------------------------------------------------------------------
Write-Step 6 "Running azcmagent check (agent-driven endpoint validation)"
$checkArgs = @('check')
if ($Location) { $checkArgs += @('--location', $Location) }
& $AgentExe @checkArgs
if ($LASTEXITCODE -ne 0) {
    Write-Fail "azcmagent check reported failures. Fix those endpoints before connecting."
    Write-Host "    Do not reach for --ignore-network-check unless you are certain the check is wrong." -ForegroundColor Yellow
    exit 1
}
Write-Ok "All required endpoints reachable"

if (-not $Connect) {
    Write-Host ""
    Write-Host "Agent installed and validated. Re-run with -Connect to register the machine." -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------------------
# 7. azcmagent connect
# ---------------------------------------------------------------------------
Write-Step 7 "Connecting to Azure Arc"
$connectArgs = @(
    'connect',
    '--subscription-id', $SubscriptionId,
    '--resource-group',  $ResourceGroup,
    '--location',        $Location
)
if ($TenantId)      { $connectArgs += @('--tenant-id', $TenantId) }
if ($UseDeviceCode) { $connectArgs += '--use-device-code' }
if ($Tags) {
    $tagString = ($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
    $connectArgs += @('--tags', $tagString)
}

& $AgentExe @connectArgs
if ($LASTEXITCODE -ne 0) {
    Write-Fail "azcmagent connect failed with exit code $LASTEXITCODE"
    exit 1
}
Write-Ok "Connect completed"

# ---------------------------------------------------------------------------
# 8. azcmagent show
# ---------------------------------------------------------------------------
Write-Step 8 "Verifying connection state"
& $AgentExe show
Write-Host ""
Write-Host "Done. Confirm subscription, resource group, tenant, and region above match what you intended." -ForegroundColor Cyan
