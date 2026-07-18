# Redeploy HNTRMembership to Sepolia and print the new address.
# Prerequisites:
#   - Foundry installed (~/.foundry/bin/forge)
#   - hntr/.env filled: PRIVATE_KEY, SEPOLIA_RPC_URL, USDT_ADDRESS, USDC_ADDRESS,
#     TREASURY_WALLET, LEADERSHIP_WALLET, ACHIEVEMENT_WALLET, POOL_WALLET, COMPANY_WALLET
#   - COMPANY_WALLET must match the address of hntr-backend COMPANY_WALLET_PRIVATE_KEY
#   - Deployer wallet has Sepolia ETH

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$Forge = Join-Path $env:USERPROFILE ".foundry\bin\forge.exe"
if (-not (Test-Path $Forge)) {
  $Forge = "forge"
}

Write-Host "Building (skipping tests)..." -ForegroundColor Cyan
& $Forge build --skip test
if ($LASTEXITCODE -ne 0) { throw "forge build failed" }

Write-Host "`nBroadcasting DeployHNTRMembership to Sepolia..." -ForegroundColor Cyan
& $Forge script script/DeployHNTRMembership.s.sol:DeployHNTRMembership `
  --rpc-url $env:SEPOLIA_RPC_URL `
  --broadcast `
  --verify `
  -vvvv

if ($LASTEXITCODE -ne 0) {
  Write-Host "`nIf --verify failed but deploy succeeded, re-run verify alone or check ETHERSCAN_API_KEY." -ForegroundColor Yellow
}

$Latest = Join-Path $Root "broadcast\DeployHNTRMembership.s.sol\11155111\run-latest.json"
if (Test-Path $Latest) {
  $json = Get-Content $Latest -Raw | ConvertFrom-Json
  $created = @($json.transactions | Where-Object { $_.transactionType -eq "CREATE" })
  if ($created.Count -gt 0) {
    $addr = $created[-1].contractAddress
    Write-Host "`n=== New HNTRMembership ===" -ForegroundColor Green
    Write-Host "CONTRACT_ADDRESS=$addr"
    Write-Host "`nUpdate these files with the new address (+ deploy block from the forge log):"
    Write-Host "  - hntr-backend/.env  -> CONTRACT_ADDRESS / CONTRACT_DEPLOY_BLOCK"
    Write-Host "  - hntr-web-nextjs/.env.local -> NEXT_PUBLIC_CONTRACT_ADDRESS"
  }
}
