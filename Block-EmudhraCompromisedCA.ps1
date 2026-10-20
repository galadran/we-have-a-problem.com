#Requires -Version 5.1
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
Import-Module PKI

$file = [IO.Path]::GetTempFileName()
try {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://emudhra.we-have-a-problem.com/impacted-intermediates.json' -OutFile $file
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne 'F67B3ABE9B4879F4E91874ED041BECCD71257F1DB41C588C724CCF12AA90C59E') {
        throw 'Manifest SHA-256 mismatch. No certificates were imported. Review the advisory before updating the pinned hash.'
    }
    $certificates = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($certificate in $certificates) {
        $base64 = $certificate.pem -replace '-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s', ''
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($base64))
        Import-Certificate -FilePath $file -CertStoreLocation Cert:\LocalMachine\Disallowed
    }
}
finally {
    Remove-Item -LiteralPath $file
}
