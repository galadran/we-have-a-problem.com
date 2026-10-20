#Requires -Version 5.1
<#
.SYNOPSIS
Blocks the eMudhra intermediates published in the 2026-10-20 advisory.
.DESCRIPTION
The incident advisory reports Microsoft's revocation rollout began on 2026-10-20.
This script is only needed to expedite protection before the automatic block arrives.
No manual action is needed once that protection is in place.
This mitigation is not recommended for enterprise-managed devices.
Your IT department will manage the rollout; contact them before applying local changes.
Microsoft documents automatic certificate trust list updates here:
https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/certificate-trust#automatic-certificate-trust-list-updates
Validates all 16 DER SHA-256 fingerprints before changing LocalMachine\Disallowed.
Does not delete roots. Applications with independent trust stores need their own updates.
Run elevated. Use -WhatIf to validate downloads without changing certificate stores.
Source: https://emudhra.we-have-a-problem.com/impacted-intermediates.json
.EXAMPLE
.\Block-EmudhraCompromisedCA.ps1 -WhatIf
.EXAMPLE
.\Block-EmudhraCompromisedCA.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Warning 'This mitigation is not recommended for enterprise-managed devices. Your IT department will manage the rollout; contact them before applying local changes.'
$expected = @(
    '42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493'
    '45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE'
    '98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B'
    '5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699'
    'E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838'
    '579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512'
    '0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19'
    '62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72'
    'CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F'
    '7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489'
    '432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3'
    'FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F'
    '9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4'
    'A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8'
    '4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1'
    '84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD'
)
$entries = Invoke-RestMethod -Uri 'https://emudhra.we-have-a-problem.com/impacted-intermediates.json' -TimeoutSec 60 -MaximumRedirection 0 -ErrorAction Stop
$entries = @($entries)
if ($entries.Count -ne $expected.Count) { throw 'Manifest changed: review the advisory before updating this script.' }

$certificates = [System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]]::new()
$seen = @{}
$sha = [System.Security.Cryptography.SHA256]::Create()
$store = $null
try {
    foreach ($entry in $entries) {
        $base64 = $entry.pem.Replace('-----BEGIN CERTIFICATE-----', '').Replace('-----END CERTIFICATE-----', '') -replace '\s', ''
        $der = [Convert]::FromBase64String($base64)
        $hash = [BitConverter]::ToString($sha.ComputeHash($der)).Replace('-', '')
        if ($hash -notin $expected -or $seen.ContainsKey($hash)) {
            throw "Unexpected or duplicate certificate SHA-256: $hash"
        }
        $seen[$hash] = $true
        $certificates.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der))
    }
    Write-Information 'Validated all 16 pinned certificate fingerprints.' -InformationAction Continue
    if (-not $WhatIfPreference) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
            if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'Run this script from an elevated PowerShell terminal.'
            }
        }
        finally { $identity.Dispose() }
    }
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('Disallowed', 'LocalMachine')
    $mode = [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly
    if (-not $WhatIfPreference) { $mode = [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite }
    $store.Open($mode)
    foreach ($cert in $certificates) {
        $existing = $store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false)
        if ($existing.Count -gt 0) {
            Write-Information "Already blocked: $($cert.Subject) [$($cert.Thumbprint)]" -InformationAction Continue
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("LocalMachine\Disallowed: $($cert.Subject) [$($cert.Thumbprint)]", 'Block certificate')) { continue }
        $store.Add($cert)
        if ($store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count -eq 0) {
            throw "Failed to verify installed block: $($cert.Thumbprint). Earlier blocks remain installed."
        }
        Write-Information "Blocked and verified: $($cert.Subject) [$($cert.Thumbprint)]" -InformationAction Continue
    }
}
finally {
    if ($null -ne $store) { $store.Dispose() }
    foreach ($cert in $certificates) { $cert.Dispose() }
    $sha.Dispose()
}
Write-Warning 'Update Windows, browsers and independent CA bundles too. This mitigation applies to clients using the Windows operating system certificate trust stores and chain validation (including Schannel TLS and Authenticode). It adds blocks to Untrusted Certificates without modifying Trusted Root Certification Authorities.'
