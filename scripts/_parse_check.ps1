$path = Join-Path $PSScriptRoot "start-hermes.ps1"
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { $_.ToString() }; exit 1 }
Write-Host OK
