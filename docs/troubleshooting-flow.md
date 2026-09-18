# Azure Arc onboarding recovery flow

Use when the generated onboarding script fails but the error is an HTTP status code rather than a DNS, TCP, or TLS failure.

0. Rerun the unchanged portal script under PowerShell 7 (`pwsh`). A 400 on the `/log` telemetry POST under Windows PowerShell 5.1 has been observed to disappear under 7. If that works, stop here.

1. Reach the port: `Test-NetConnection gbl.his.arc.azure.com -Port 443`
2. Retrieve the installer: `Invoke-WebRequest -UseBasicParsing -Uri https://aka.ms/AzureConnectedMachineAgent -OutFile $env:TEMP\AzureConnectedMachineAgent.msi`
3. Install the agent: `msiexec /i $env:TEMP\AzureConnectedMachineAgent.msi /qn /l*v $env:TEMP\AzureConnectedMachineAgent.log`
4. Confirm the service: `Get-Service himds`
5. Confirm the binary: `azcmagent version`
6. Validate endpoints: `azcmagent check`
7. Register the machine: `azcmagent connect --subscription-id ... --resource-group ... --location ...`
8. Verify state: `azcmagent show`

Stop at the first step that fails. Each step isolates a different layer:

| Step fails | Layer to investigate |
|-----------|----------------------|
| 1 | DNS, routing, firewall, proxy |
| 2 | Outbound HTTPS, TLS inspection, proxy allow list |
| 3 | Local machine (installer prerequisites, pending reboot, MSI log) |
| 4 | Service start, `%ProgramData%\AzureConnectedMachineAgent\Log\himds.log` |
| 6 | Specific Arc endpoint blocked; output names the destination |
| 7 | Identity and RBAC (service principal permissions, tenant, subscription) |
