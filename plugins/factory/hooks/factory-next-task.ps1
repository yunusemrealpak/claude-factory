# Factory: the night run on Windows, as Task Scheduler starts it.
# Written by `factory-next schtasks`, with this machine's paths filled in;
# the scheduled task runs:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
#
# Task Scheduler, not the desktop app's scheduled tasks: `claude -p` started
# from here exits when its work is done. What this wrapper adds is what an
# unattended start needs and Task Scheduler does not give:
#   - .factory/STOP is honoured before anything starts;
#   - one run at a time: a lock file younger than the timeout means a run is
#     still going, and this start is skipped;
#   - a wall-clock timeout: a run that outlives it is stopped with its whole
#     process tree, so no claude.exe is left behind;
#   - everything goes to a log file under .factory/logs/.
$ErrorActionPreference = 'Stop'
$Root = '__ROOT__'
$Python = '__PYTHON__'
$Script = '__SCRIPT__'
$Claude = '__CLAUDE__'
$TimeoutMin = __TIMEOUT__

$Logs = Join-Path $Root '.factory\logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$Log = Join-Path $Logs "next-schtasks-$Stamp.log"
function Say([string]$m) { Add-Content -Path $Log -Value ("{0:u} {1}" -f (Get-Date), $m) }

if (Test-Path (Join-Path $Root '.factory\STOP')) { Say 'STOP is set: nothing started'; exit 0 }

$Locks = Join-Path $Root '.factory\locks'
New-Item -ItemType Directory -Force -Path $Locks | Out-Null
$Lock = Join-Path $Locks 'next-schtasks.lock'
if (Test-Path $Lock) {
  $age = ((Get-Date) - (Get-Item $Lock).LastWriteTime).TotalMinutes
  if ($age -lt $TimeoutMin) { Say ("a run started {0:N0} min ago still holds the lock: skipped" -f $age); exit 0 }
  Say ("a stale lock ({0:N0} min old) taken over" -f $age)
}
Set-Content -Path $Lock -Value $PID

try {
  $env:FACTORY_ROOT = $Root
  $env:FACTORY_CLAUDE = $Claude
  $out = "$Log.out"; $err = "$Log.err"
  Say "starting: $Python $Script launch"
  $p = Start-Process -FilePath $Python -ArgumentList @("`"$Script`"", 'launch') -WorkingDirectory $Root `
         -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  # Taking the handle now is what makes ExitCode readable after the wait.
  $null = $p.Handle
  if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
    Say "timed out after $TimeoutMin min: stopping the run and everything it started"
    & taskkill.exe /T /F /PID $p.Id | Out-Null
    exit 1
  }
  $p.WaitForExit()
  $code = $p.ExitCode
  if ($null -eq $code) { $code = 1 }
  if (Test-Path $out) { Get-Content -Path $out | ForEach-Object { Say "  $_" } }
  # 1 is also "nothing to do tonight" (NEXT WAIT): the line above says which.
  Say ("exit {0}" -f $code)
  exit $code
} catch {
  Say ("error: {0}" -f $_)
  exit 1
} finally {
  Remove-Item -Force -ErrorAction SilentlyContinue $Lock
}
