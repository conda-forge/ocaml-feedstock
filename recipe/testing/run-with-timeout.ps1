# Run a command with a wall-clock limit; kill its process tree and exit 124 on timeout.
# On timeout, thread states and cdb stacks of the process tree are logged first.
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
    $pids = @($proc.Id)
    $queue = @($proc.Id)
    try {
        $all = @(Get-CimInstance Win32_Process)
        while ($queue.Count -gt 0) {
            $cur = $queue[0]
            $queue = @($queue | Select-Object -Skip 1)
            $kids = @($all | Where-Object { $_.ParentProcessId -eq $cur } | ForEach-Object { [int]$_.ProcessId })
            foreach ($k in $kids) {
                if ($pids -notcontains $k) { $pids += $k; $queue += $k }
            }
        }
    } catch {
        Write-Host "TIMEOUT-DIAG process enumeration failed: $_"
    }
    foreach ($p in $pids) {
        try {
            $pr = Get-Process -Id $p -ErrorAction Stop
            Write-Host "TIMEOUT-DIAG process $($pr.ProcessName) pid $p"
            foreach ($t in $pr.Threads) {
                Write-Host "TIMEOUT-DIAG   thread $($t.Id) state $($t.ThreadState) wait $($t.WaitReason)"
            }
        } catch {
            Write-Host "TIMEOUT-DIAG pid $p gone: $_"
        }
    }
    $dbgRoots = @("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers", "${env:ProgramFiles}\Windows Kits\10\Debuggers")
    $archs = @('arm64', 'x64')
    if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') { $archs = @('x64', 'arm64') }
    $cdb = $null
    foreach ($root in $dbgRoots) {
        foreach ($a in $archs) {
            $cand = Join-Path $root "$a\cdb.exe"
            if (-not $cdb -and (Test-Path $cand)) { $cdb = $cand }
        }
    }
    if (-not $cdb) {
        $gc = Get-Command cdb.exe -ErrorAction SilentlyContinue
        if ($gc) { $cdb = $gc.Source }
    }
    if ($cdb) {
        foreach ($p in $pids) {
            Write-Host "TIMEOUT-DIAG cdb stacks for pid $p"
            try {
                & $cdb -pv -p $p -c "lm; ~* k 40; ub @`$ip L40; u @`$ip L8; q" 2>&1 | ForEach-Object { Write-Host "TIMEOUT-DIAG $_" }
            } catch {
                Write-Host "TIMEOUT-DIAG cdb failed for pid ${p}: $_"
            }
        }
    } else {
        Write-Host "TIMEOUT-DIAG cdb.exe not found, no stack dump"
    }
    & taskkill /T /F /PID $proc.Id | Out-Null
    exit 124
}
$proc.WaitForExit()
exit $proc.ExitCode
