param(
  [ValidateSet("demo", "source")]
  [string]$Mode = "demo"
)

$ErrorActionPreference = "Stop"

if ($Mode -eq "demo") {
  Write-Host "Starting Juice Shop demo mode on http://localhost:3000 ..."
  docker compose --profile demo up -d
  exit $LASTEXITCODE
}

Write-Host "Starting Juice Shop source-image mode on http://localhost:3001 ..."
docker compose --profile source up -d --build
exit $LASTEXITCODE
