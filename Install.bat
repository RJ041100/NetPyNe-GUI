: << 'BATCH'
@echo off
REM ============================================================
REM  run_netpyne.bat  (polyglot batch/bash OS-detecting launcher)
REM
REM  ONE file for all platforms:
REM    - Windows: double-click this file.
REM    - macOS/Linux: run `bash run_netpyne.bat` in Terminal.
REM
REM  On raw Windows (no Git Bash yet), this batch section runs
REM  first: it installs Git Bash / WSL2 / Docker Desktop if
REM  missing, then re-launches THIS SAME FILE under Git Bash.
REM
REM  Once bash is reading the file (natively on Mac/Linux, or via
REM  Git Bash after the Windows bootstrap above), it skips this
REM  entire batch section — hidden inside a bash heredoc — and
REM  runs the OS-detection dispatcher near the bottom, which picks
REM  the correct platform-specific script to hand off to:
REM
REM    Darwin (macOS)      -> setup_netpyne_ui_mac.sh
REM    Linux               -> setup_netpyne_ui_linux.sh
REM    Windows (Git Bash)  -> run_netpyne_docker_windows.sh
REM
REM  All of those scripts must sit in the SAME FOLDER as this file.
REM ============================================================

setlocal enabledelayedexpansion

REM --- 0. Self-elevate to Administrator if not already ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges - a UAC prompt will appear...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ==============================================================
echo  NetPyNE-UI - Windows prerequisite check
echo ==============================================================

where winget >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: "winget" was not found on this system.
    echo Install/update "App Installer" from the Microsoft Store, then re-run:
    echo   https://apps.microsoft.com/detail/9nblggh4nns1
    pause
    exit /b 1
)
echo winget is available.

set GITBASH_PATH=C:\Program Files\Git\bin\bash.exe
if exist "%GITBASH_PATH%" (
    echo Git Bash: already installed.
) else (
    echo Git Bash not found - installing Git for Windows via winget...
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    if not exist "%GITBASH_PATH%" (
        echo ERROR: Git Bash still not found. Install manually: https://git-scm.com/download/win
        pause
        exit /b 1
    )
    echo Git Bash installed successfully.
)

echo.
echo Checking WSL...
wsl --status >nul 2>&1
if errorlevel 1 (
    echo WSL not found - installing ^(may require a restart^)...
    wsl --install --no-distribution
    echo If Windows asks you to RESTART, please do so, then double-click this file again.
    pause
    exit /b 0
) else (
    echo WSL: already installed.
    wsl --set-default-version 2 >nul 2>&1
)

set DOCKER_EXE=C:\Program Files\Docker\Docker\Docker Desktop.exe
if exist "%DOCKER_EXE%" (
    echo Docker Desktop: already installed.
) else (
    echo Docker Desktop not found - installing via winget...
    winget install --id Docker.DockerDesktop -e --source winget --accept-package-agreements --accept-source-agreements
    if not exist "%DOCKER_EXE%" (
        echo ERROR: Docker Desktop still not found. Install manually: https://www.docker.com/products/docker-desktop/
        pause
        exit /b 1
    )
    echo Docker Desktop was just installed. Launch it once, complete its
    echo first-run setup, then double-click this file again.
    pause
    exit /b 0
)

echo.
echo Checking Docker Desktop is running...
docker info >nul 2>&1
if errorlevel 1 (
    echo Starting Docker Desktop...
    start "" "%DOCKER_EXE%"
    set /a count=0
    :waitdocker
    timeout /t 2 >nul
    docker info >nul 2>&1
    if errorlevel 1 (
        set /a count+=2
        if !count! GEQ 90 (
            echo ERROR: Docker did not become ready in time. Open it manually and re-run this file.
            pause
            exit /b 1
        )
        goto waitdocker
    )
)
echo Docker is running.

echo.
echo ==============================================================
echo  Prerequisites satisfied. Handing off to Git Bash for OS detection...
echo ==============================================================
"%GITBASH_PATH%" "%~f0"

pause
exit /b
BATCH

# ============================================================
# From here down, only bash ever reads this file — cmd.exe never
# reaches this point (it already exited above), and everything
# above (including the "BATCH" marker) was swallowed by the
# heredoc as inert text.
#
# This section runs identically whether it's:
#   - native bash on macOS
#   - native bash on Linux
#   - Git Bash on Windows (arriving here via the bootstrap above)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================="
echo " NetPyNE-UI — detecting operating system..."
echo "=============================================================="

OS_NAME="$(uname -s)"
echo "-> uname reports: $OS_NAME"

run_target() {
    local script_name="$1"
    local label="$2"

    if [ ! -f "$script_name" ]; then
        echo
        echo "ERROR: Detected $label, but '$script_name' was not found"
        echo "in this folder: $SCRIPT_DIR"
        echo
        echo "Make sure '$script_name' is saved in the SAME FOLDER as this"
        echo "launcher file, then run this launcher again."
        exit 1
    fi

    chmod +x "$script_name"
    echo "-> Detected: $label"
    echo "-> Handing off to: $script_name"
    echo "--------------------------------------------------------------"
    exec ./"$script_name"
}

case "$OS_NAME" in
    Darwin)
        run_target "setup_netpyne_ui_mac.sh" "macOS"
        ;;
    Linux)
        run_target "setup_netpyne_ui_linux.sh" "Linux"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        run_target "run_netpyne_docker_windows.sh" "Windows (via Git Bash)"
        ;;
    *)
        echo
        echo "ERROR: Unrecognized OS ('$OS_NAME')."
        echo "This launcher supports macOS, Linux, and Windows (via Git Bash) only."
        exit 1
        ;;
esac
