# Azure Arc Onboarding Kit

Author: Shannon Eldridge-Kuehn

Copywright: September 18, 2026

Companion repo for the Cloudy Musings post [**When Azure Arc Says 400 Bad Request, the Network Is Probably Fine**](https://www.shankuehn.io/post/when-azure-arc-says-400-bad-request-the-network-is-probably-fine).

When the portal-generated Azure Arc onboarding script fails on a Windows Server, these scripts prove each dependency one layer at a time instead of guessing at the firewall.

## What is in here

| Path | Purpose |
|------|---------|
| `scripts/Invoke-ArcOnboardingRecovery.ps1` | Full recovery flow: TCP check, download, install, service check, `azcmagent check`, optional `connect` and `show`. Stops on the first failed step. |
| `scripts/Test-ArcConnectivity.ps1` | Read-only DNS and TCP 443 test against the core Arc endpoints. Makes no changes. |
| `docs/troubleshooting-flow.md` | The eight-step flow in plain text for copying into a runbook. |

## Quick start

Run from an elevated PowerShell session on the target server.

Validate only, install nothing:

```powershell
.\scripts\Test-ArcConnectivity.ps1 -Region eastus2
```

Install and validate the agent, stop before connecting:

```powershell
.\scripts\Invoke-ArcOnboardingRecovery.ps1
```

Install, validate, and connect interactively with device code:

```powershell
.\scripts\Invoke-ArcOnboardingRecovery.ps1 -Connect -UseDeviceCode `
    -SubscriptionId "<SUBSCRIPTION-ID>" `
    -ResourceGroup  "<RESOURCE-GROUP>" `
    -Location       "<AZURE-REGION>"
```

Add `-TenantId` and `-Tags @{ env = 'prod'; owner = 'platform' }` as needed. For fleet onboarding, use a dedicated Arc onboarding service principal rather than an interactive login, and pass its credentials through the standard `azcmagent connect` parameters.

## Try this first

If the portal-generated onboarding script fails with an HTTP status code (a 400 on the `/log` telemetry POST is the common one) and the error text uses the Windows PowerShell 5.1 format, rerun the unchanged script under PowerShell 7:

```powershell
pwsh -ExecutionPolicy Bypass -File .\OnboardingScript.ps1
```

The 5.1 HttpWebRequest stack and the PowerShell 7 HttpClient stack build POSTs differently, and the HIS endpoint has been seen rejecting the 5.1 version. If the script runs clean under `pwsh`, nothing else in this repo is needed. If the failure survives, or `pwsh` is not available on the server, use the scripts below.

## The one idea behind all of this

An HTTP `400 Bad Request` from `gbl.his.arc.azure.com` means the request reached Azure and Azure answered. DNS, routing, TCP 443, and TLS all worked. That eliminates the network as the first suspect. Prove the layers below before touching firewall rules, and once `azcmagent` is installed, let `azcmagent check` tell you which endpoint is actually blocked.

Do not solve a failed `azcmagent check` with `--ignore-network-check`. If the check fails for a real reason, Arc will not work after onboarding either.

## Reference

- [Connected Machine agent network requirements](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
- [azcmagent CLI reference](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent)
- [Troubleshoot the Connected Machine agent](https://learn.microsoft.com/azure/azure-arc/servers/troubleshoot-agent-onboard)

## License

MIT
