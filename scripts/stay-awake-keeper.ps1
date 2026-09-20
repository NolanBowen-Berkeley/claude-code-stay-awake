# Stay Awake for Claude Code: the Windows "keeper".
#
# The Windows counterpart of `caffeinate`: holds a power request through
# SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED [| ES_DISPLAY_REQUIRED])
# for as long as this process runs, and runs while its hold file exists.
# Started hidden by scripts/stay-awake-windows.sh; never run by hand.
#
#   Hold     path of the hold file; the keeper exits when it disappears
#   PidFile  where to write this process id (the shell side reads it back)
#   Watch    Windows pid to watch (like caffeinate -w); 0 = none (WSL passes 0)
#   MaxSecs  hard cap in seconds; 0 = none
#   Display  1 = also keep the display on (STAY_AWAKE_FLAGS contains -d)
param(
  [string]$Hold,
  [string]$PidFile,
  [int]$Watch = 0,
  [int]$MaxSecs = 0,
  [int]$Display = 0
)
$ErrorActionPreference = 'SilentlyContinue'

$sig = '[DllImport("kernel32.dll", SetLastError = true)] public static extern uint SetThreadExecutionState(uint esFlags);'
$pwr = Add-Type -MemberDefinition $sig -Name Native -Namespace ClaudeStayAwake -PassThru

$ES_CONTINUOUS       = [uint32]0x80000000
$ES_SYSTEM_REQUIRED  = [uint32]0x00000001
$ES_DISPLAY_REQUIRED = [uint32]0x00000002

$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED
if ($Display -ne 0) { $flags = $flags -bor $ES_DISPLAY_REQUIRED }
[void]$pwr::SetThreadExecutionState($flags)

# Only announce the pid once the request is held, so the shell side never sees
# a keeper that is not yet asserting.
[IO.File]::WriteAllText($PidFile, "$PID")

$elapsed = 0
while ((Test-Path -LiteralPath $Hold) -and (($MaxSecs -le 0) -or ($elapsed -lt $MaxSecs))) {
  if ($Watch -ne 0 -and -not (Get-Process -Id $Watch -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Seconds 3
  $elapsed += 3
}

[void]$pwr::SetThreadExecutionState($ES_CONTINUOUS)
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
