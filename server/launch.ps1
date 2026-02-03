#Requires -Version 5.1
<#
.SYNOPSIS
    True one-click launcher for SAM2 server on Windows.

.DESCRIPTION
    - (if needed) create venv under server\.venv
    - (if needed) install Python deps from server\requirements.txt (including SAM2 code)
    - (if needed) download the smallest SAM2.1 checkpoint for quick verification
    - run server\main.py

.EXAMPLE
    .\server\launch.ps1 --image C:\path\to\image.jpg --point 320 240

.EXAMPLE
    .\server\launch.ps1
    # uses synthetic image; prompts to select a local SAM2 model
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$MainPyArgs
)

$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$VENV_DIR = Join-Path $ROOT ".venv"
$REQ_FILE = Join-Path $ROOT "requirements.txt"

function Find-Python {
    # Try python3.11, python3.12, then python
    $candidates = @("python3.11", "python3.12", "python3", "python")
    foreach ($py in $candidates) {
        $cmd = Get-Command $py -ErrorAction SilentlyContinue
        if ($cmd) {
            # Verify it's Python 3.x
            $version = & $py --version 2>&1
            if ($version -match "Python 3\.") {
                return $py
            }
        }
    }
    Write-Error "Error: Python 3 not found. Install Python 3.11+ first."
    exit 1
}

function Test-GitInstalled {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Error: git not found. It's required to install SAM2 from GitHub."
        exit 1
    }
}

function Ensure-Venv {
    if (Test-Path $VENV_DIR) {
        return
    }
    $pybin = Find-Python
    Write-Host "Creating venv at $VENV_DIR (using $pybin) ..."
    & $pybin -m venv $VENV_DIR
}

function Get-VenvPython {
    return Join-Path $VENV_DIR "Scripts\python.exe"
}

function Test-DepsInstalled {
    $venvPython = Get-VenvPython
    $testScript = @"
import sys
try:
    import numpy
    import PIL
    import torch
    import sam2
    import fastapi
    import uvicorn
    # Also check CUDA is available
    if not torch.cuda.is_available():
        sys.exit(1)
    sys.exit(0)
except ImportError:
    sys.exit(1)
"@
    & $venvPython -c $testScript 2>$null
    return $LASTEXITCODE -eq 0
}

function Ensure-Deps {
    $venvPython = Get-VenvPython

    # Upgrade pip tooling
    Write-Host "Upgrading pip..."
    & $venvPython -m pip install -U pip setuptools wheel | Out-Null

    # Fast check: if imports work and CUDA available, skip pip install
    if (Test-DepsInstalled) {
        Write-Host "Dependencies already installed with CUDA support."
        return
    }

    # Install PyTorch with CUDA 11.8 first
    Write-Host "Installing PyTorch with CUDA 11.8 support..."
    & $venvPython -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118

    # Install other dependencies (excluding torch/torchvision which are already installed)
    Write-Host "Installing other Python dependencies from $REQ_FILE ..."
    $env:SAM2_BUILD_CUDA = "0"
    $env:SAM2_BUILD_ALLOW_ERRORS = "1"
    & $venvPython -m pip install -r $REQ_FILE
}

function Ensure-Sam2TinyModel {
    $outDir = Join-Path $ROOT "models\sam2"
    $ckpt = Join-Path $outDir "sam2.1_hiera_tiny.pt"
    $expectedSize = 38800000  # ~38MB

    # Check if file exists and is roughly the right size
    if ((Test-Path $ckpt) -and ((Get-Item $ckpt).Length -gt $expectedSize)) {
        return
    }

    # Remove incomplete download if exists
    if (Test-Path $ckpt) {
        Remove-Item $ckpt -Force
    }

    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $url = "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt"
    Write-Host "Downloading SAM2.1 tiny model (smallest; for quick verification) ..."
    Write-Host "Tip: later you can run 'python server\manage_model.py' to download larger models."

    # Use .NET WebClient for reliable large file download
    $webClient = New-Object System.Net.WebClient
    try {
        $webClient.DownloadFile($url, $ckpt)
    } finally {
        $webClient.Dispose()
    }

    $fileInfo = Get-Item $ckpt
    Write-Host "Downloaded: $ckpt ($([math]::Round($fileInfo.Length / 1MB, 2)) MB)"

    if ($fileInfo.Length -lt $expectedSize) {
        Write-Error "Download incomplete. Expected ~38MB, got $([math]::Round($fileInfo.Length / 1MB, 2)) MB"
        exit 1
    }
}

# Main execution
Test-GitInstalled
Ensure-Venv
Ensure-Deps
Ensure-Sam2TinyModel

# Run the server
$venvPython = Get-VenvPython
$mainPy = Join-Path $ROOT "main.py"

if ($MainPyArgs) {
    & $venvPython $mainPy @MainPyArgs
} else {
    & $venvPython $mainPy
}
