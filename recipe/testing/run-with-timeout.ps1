# Run a command with a wall-clock limit; kill its process tree and exit 124 on timeout.
# Usage: run-with-timeout.ps1 <seconds> <command> [args...]
$TimeoutSec = [int]$args[0]
$Command = @($args[1..($args.Length - 1)])

$exe = (Get-Command $Command[0] -ErrorAction Stop).Source
$argList = @()
if ($Command.Length -gt 1) {
    $argList = $Command[1..($Command.Length - 1)] | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
}

if ($argList.Count -gt 0) {
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru
} else {
    $proc = Start-Process -FilePath $exe -NoNewWindow -PassThru
}
$null = $proc.Handle

if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    Write-Host "TIMEOUT after $TimeoutSec s: $($Command -join ' ')"
    & taskkill /T /F /PID $proc.Id | Out-Null
    exit 124
}
$proc.WaitForExit()
exit $proc.ExitCode
