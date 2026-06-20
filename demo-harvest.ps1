# Chog Vault — Demo Harvest launcher (Windows PowerShell)
#
# Starts the autonomous-agent loop + the price oscillator side-by-side in a
# fresh PowerShell window, so this terminal and the live web app stay usable
# during judging.
#
# Honest framing: the agent's decision logic is real and autonomous. Real MON
# is flat over a short demo, so this script INJECTS volatility around the
# live Pyth Beta MON/USD price via owner-signed setPrice. Every rebalance the
# agent fires is a real on-chain tx + LogBook entry. Rebalancing nets positive
# only when swings beat the 0.3% AMM fee AND the price mean-reverts.
#
# Usage:
#   .\demo-harvest.ps1                    # unbounded — live judging mode
#   .\demo-harvest.ps1 -Cycles 12         # bounded — 12 ticks then stop
#   .\demo-harvest.ps1 -Amp 0.25          # ±25% amplitude
#   .\demo-harvest.ps1 -Wave triangle     # triangle wave instead of sine
#   .\demo-harvest.ps1 -Period 8000       # 8s between ticks

param(
    [int]    $Cycles = 0,
    [double] $Amp    = 0.20,
    [int]    $Period = 12000,
    [ValidateSet("sine","triangle")]
    [string] $Wave   = "sine",
    # Optional priceE8 center override. Empty = read live Pyth at start.
    # Use this if the vault is depth-stranded vs live Pyth (e.g. "219916859" = $2.20).
    [string] $Center = ""
)

$repoRoot = $PSScriptRoot
$agentDir = Join-Path $repoRoot "agent"

if (-not (Test-Path (Join-Path $agentDir "package.json"))) {
    Write-Host "ERROR: agent/ not found at $agentDir" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $agentDir ".env"))) {
    Write-Host "ERROR: agent/.env is missing — AGENT_PK and DEPLOYER_PK must be set" -ForegroundColor Red
    exit 1
}

$cyclesDisplay = if ($Cycles -le 0) { "unbounded (live)" } else { "$Cycles" }

Write-Host ""
Write-Host "Chog Vault - Demo Harvest" -ForegroundColor Magenta
Write-Host "  agent dir : $agentDir"
Write-Host "  CYCLES    : $cyclesDisplay"
Write-Host "  AMP       : $Amp"
Write-Host "  PERIOD    : $Period ms"
Write-Host "  WAVE      : $Wave"
if ($Center -ne "") {
    Write-Host "  CENTER    : $Center  override - not live Pyth"
} else {
    Write-Host "  CENTER    : live Pyth read at start"
}
Write-Host ""
Write-Host "Launching in a new PowerShell window..." -ForegroundColor Gray

# Build the command string for the child window. Backticks escape `$ so PS sets
# env in the CHILD shell, not interpolated here. Single quotes around values
# keep them as literals there.
$envCmd = "`$env:CYCLES = '$Cycles'; `$env:AMP = '$Amp'; `$env:PERIOD = '$Period'; `$env:WAVE = '$Wave'; `$env:CENTER = '$Center'"
$cdCmd  = "Set-Location '$agentDir'"
$runCmd = "npm run demo:harvest"
$full   = "$envCmd; $cdCmd; Write-Host 'Chog Vault demo harvest running...' -ForegroundColor Magenta; $runCmd"

Start-Process powershell.exe -ArgumentList @(
    "-NoExit",
    "-Command", $full
)

Write-Host "Launched. Watch the Agent tab at https://chog-vault.vercel.app" -ForegroundColor Green
Write-Host "  the new window streams both the [tick] (agent) and [vol] (price oscillator) logs."
Write-Host "  close the new window (or Ctrl+C inside it) to stop the demo."
