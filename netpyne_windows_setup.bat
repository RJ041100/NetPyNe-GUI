: << 'BATCH'
@echo off
REM ============================================================
REM  netpyne_windows_setup.bat  (polyglot batch/bash file)
REM
REM  Double-click this file. It is read TWICE, by two different
REM  interpreters, and each one only sees its own half:
REM
REM    1. Windows runs it as a .bat file (this section). It
REM       checks for and installs Git Bash, WSL2, and Docker
REM       Desktop using native Windows tools (winget), then
REM       re-launches THIS SAME FILE using Git Bash.
REM
REM    2. Git Bash then reads the file again. The trick at the
REM       very top of this file (": << 'BATCH'") is a bash
REM       heredoc that swallows this entire batch section as
REM       inert text, so bash skips straight to the real bash
REM       script below the "BATCH" marker further down, which
REM       does the actual Docker pull/build/run work.
REM
REM  You never need to touch two separate files — everything
REM  needed lives in this one.
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

REM --- 1. Confirm winget is available ---
where winget >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: "winget" was not found on this system.
    echo winget ships with modern Windows 10/11 as part of "App Installer".
    echo Install/update it from the Microsoft Store, then re-run this file:
    echo   https://apps.microsoft.com/detail/9nblggh4nns1
    pause
    exit /b 1
)
echo winget is available.

REM --- 2. Git for Windows (provides Git Bash) ---
set GITBASH_PATH=C:\Program Files\Git\bin\bash.exe
if exist "%GITBASH_PATH%" (
    echo Git Bash: already installed.
) else (
    echo Git Bash not found - installing Git for Windows via winget...
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    if not exist "%GITBASH_PATH%" (
        echo.
        echo ERROR: Git Bash still not found after install attempt.
        echo Install manually from https://git-scm.com/download/win and re-run this file.
        pause
        exit /b 1
    )
    echo Git Bash installed successfully.
)

REM --- 3. WSL2 (Docker Desktop's backend on Windows) ---
echo.
echo Checking WSL...
wsl --status >nul 2>&1
if errorlevel 1 (
    echo WSL not found or not fully set up - installing ^(this can take a
    echo few minutes and MAY require a restart^)...
    wsl --install --no-distribution
    echo.
    echo ==============================================================
    echo  WSL was just installed. If Windows asks you to RESTART, please
    echo  do so, then double-click THIS FILE again to continue.
    echo ==============================================================
    pause
    exit /b 0
) else (
    echo WSL: already installed.
    wsl --set-default-version 2 >nul 2>&1
)

REM --- 4. Docker Desktop ---
set DOCKER_EXE=C:\Program Files\Docker\Docker\Docker Desktop.exe
if exist "%DOCKER_EXE%" (
    echo Docker Desktop: already installed.
) else (
    echo Docker Desktop not found - installing via winget...
    winget install --id Docker.DockerDesktop -e --source winget --accept-package-agreements --accept-source-agreements
    if not exist "%DOCKER_EXE%" (
        echo.
        echo ERROR: Docker Desktop still not found after install attempt.
        echo Install manually from https://www.docker.com/products/docker-desktop/
        echo and re-run this file.
        pause
        exit /b 1
    )
    echo.
    echo ==============================================================
    echo  Docker Desktop was just installed. Please:
    echo    1. Launch it once manually from the Start Menu
    echo    2. Complete its first-run setup ^(accept terms, let it use WSL2^)
    echo    3. Then double-click THIS FILE again to continue
    echo ==============================================================
    pause
    exit /b 0
)

REM --- 5. Make sure Docker Desktop is actually running ---
echo.
echo Checking Docker Desktop is running...
docker info >nul 2>&1
if errorlevel 1 (
    echo Starting Docker Desktop...
    start "" "%DOCKER_EXE%"
    echo Waiting for Docker to be ready ^(up to 90s^)...
    set /a count=0
    :waitdocker
    timeout /t 2 >nul
    docker info >nul 2>&1
    if errorlevel 1 (
        set /a count+=2
        if !count! GEQ 90 (
            echo.
            echo ERROR: Docker did not become ready in time.
            echo Open Docker Desktop manually, wait for "Engine running", then re-run this file.
            pause
            exit /b 1
        )
        goto waitdocker
    )
)
echo Docker is running.

REM --- 6. All prerequisites satisfied - re-invoke THIS SAME FILE under
REM        Git Bash. Bash will skip this whole batch section (it's
REM        hidden inside the heredoc below) and run the real script
REM        starting at the "BATCH" marker.
echo.
echo ==============================================================
echo  All prerequisites satisfied. Continuing setup in Git Bash...
echo ==============================================================
echo.

"%GITBASH_PATH%" "%~f0"

pause
exit /b
BATCH

# ============================================================
# From here down, this file is read ONLY by bash (Windows/cmd.exe
# never reaches this point — it already exited above). Everything
# above this line, including the "BATCH" marker itself, was
# swallowed by the "<< 'BATCH'" heredoc and never executed as bash.
# ============================================================

set -e

IMAGE_NAME="metacell/netpyne-ui"
LOCAL_IMAGE_TAG="netpyne-ui:local"
CONTAINER_NAME="netpyne-ui"
HOST_PORT=8888
CONTAINER_PORT=8888
REPO_URL="https://github.com/MetaCell/NetPyNE-UI.git"
NEURON_FALLBACK_VERSION="8.2.6"

WORKSPACE_WIN="$USERPROFILE\\netpyne-workspace"
WORKSPACE_BASH="$(cygpath -u "$WORKSPACE_WIN" 2>/dev/null || echo "$HOME/netpyne-workspace")"

echo "=============================================================="
echo " NetPyNE-UI — Docker setup (running in Git Bash)"
echo "=============================================================="

# ---------------------------------------------------------------------------
# Safety net: prerequisites were already checked/installed by the batch
# half of this file above. This just confirms they actually took effect
# before we go further.
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker CLI still not found. Something went wrong in the"
    echo "prerequisite install step above. Try re-running this file, or"
    echo "install Docker Desktop manually: https://www.docker.com/products/docker-desktop/"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon isn't responding. Open Docker Desktop manually,"
    echo "wait for 'Engine running', then re-run this file."
    exit 1
fi
echo "-> Docker is installed and running."

# ---------------------------------------------------------------------------
# Clean up any previous container with the same name
# ---------------------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "-> Removing existing '$CONTAINER_NAME' container so we start fresh..."
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Prepare the workspace folder (persists your models outside the container)
# ---------------------------------------------------------------------------
mkdir -p "$WORKSPACE_BASH"
echo "-> Workspace folder: $WORKSPACE_BASH  (Windows path: $WORKSPACE_WIN)"

# ---------------------------------------------------------------------------
# Try the pre-built image first; fall back to building from source with
# the same NEURON-pin patch we needed during manual installs
# ---------------------------------------------------------------------------
IMAGE_TO_RUN=""

echo "-> Attempting to pull pre-built image: $IMAGE_NAME ..."
if docker pull "$IMAGE_NAME" 2>/dev/null; then
    echo "-> Pre-built image pulled successfully."
    IMAGE_TO_RUN="$IMAGE_NAME"
else
    echo "-> Pre-built image unavailable or pull failed."
    echo "-> Falling back to building from source (this WILL take a while)..."

    WORKDIR="$HOME/netpyne-ui-docker-build"
    rm -rf "$WORKDIR"
    git clone "$REPO_URL" "$WORKDIR"
    cd "$WORKDIR"

    if grep -rl "NEURON==8.2.2" . &>/dev/null; then
        echo "-> Patching yanked NEURON==8.2.2 pin -> NEURON==$NEURON_FALLBACK_VERSION"
        grep -rl "NEURON==8.2.2" . | xargs sed -i "s/NEURON==8.2.2/NEURON==$NEURON_FALLBACK_VERSION/"
    fi

    echo "-> Building local image (tag: $LOCAL_IMAGE_TAG)..."
    docker build -t "$LOCAL_IMAGE_TAG" .
    IMAGE_TO_RUN="$LOCAL_IMAGE_TAG"
    cd - >/dev/null
fi

# ---------------------------------------------------------------------------
# Run the container
# ---------------------------------------------------------------------------
echo "-> Starting container '$CONTAINER_NAME' from image '$IMAGE_TO_RUN' ..."
docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    -v "${WORKSPACE_BASH}:/home/jovyan/workspace" \
    --restart unless-stopped \
    "$IMAGE_TO_RUN"

# ---------------------------------------------------------------------------
# Wait for it to actually respond before declaring success
# ---------------------------------------------------------------------------
echo "-> Waiting for the GUI to come up..."
READY=0
for i in $(seq 1 60); do
    if curl -sf "http://localhost:${HOST_PORT}/" -o /dev/null; then
        READY=1
        break
    fi
    sleep 2
done

echo "=============================================================="
if [ "$READY" -eq 1 ]; then
    echo " NetPyNE-UI is running."
    echo "=============================================================="
    echo
    echo "  Open in your browser:  http://localhost:${HOST_PORT}/"
    echo
    start "http://localhost:${HOST_PORT}/" 2>/dev/null || true
else
    echo " Container started, but didn't respond within the timeout."
    echo "=============================================================="
    echo
    echo "Check the logs to see what's happening:"
    echo "  docker logs $CONTAINER_NAME"
fi

echo
echo "Useful commands:"
echo "  docker logs -f $CONTAINER_NAME      # follow logs"
echo "  docker stop $CONTAINER_NAME         # stop it"
echo "  docker start $CONTAINER_NAME        # start it again later"
echo "  docker rm -f $CONTAINER_NAME        # remove it entirely"
echo
echo "Your NetPyNE workspace/model files are saved on your Windows machine at:"
echo "  $WORKSPACE_WIN"
echo
echo "To let OTHER people on your network reach this, they open:"
echo "  http://<this-PC-LAN-IP>:${HOST_PORT}/"
echo "Find your LAN IP with:  ipconfig   (look for 'IPv4 Address')"
echo "You may also need to allow this port through Windows Defender Firewall"
echo "the first time an external connection is attempted."
