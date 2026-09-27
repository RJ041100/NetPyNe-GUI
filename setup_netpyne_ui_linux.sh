#!/bin/bash
#
# setup_netpyne_ui_linux.sh
#
# End-to-end setup for NetPyNE-UI on Ubuntu/Debian, sized for ~60
# simultaneous users, encoding every fix worked through manually:
#   - Python 3.7 pinning (via deadsnakes)
#   - a yanked NEURON PyPI version
#   - missing npm / yarn / yalc tooling
#   - a sass / Node-14 engine conflict
#   - NetPyNE "development" branch using Python 3.8+ syntax (walrus operator)
#   - an unsupported loadModel() kwarg in netpyne_geppetto.py
#   - single shared-state backend -> per-user isolated sessions via a proxy
#
# Run as a normal user with sudo privileges, from the folder where you
# want NetPyNE-UI cloned (use a path with NO SPACES — a space in the
# parent folder name broke geppetto_ui.sh during testing).
#
#   chmod +x setup_netpyne_ui_linux.sh
#   ./setup_netpyne_ui_linux.sh
#
set -e

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/MetaCell/NetPyNE-UI.git"
REPO_DIR="NetPyNE-UI"
PYTHON_VERSION="3.7"
NODE_VERSION="14"
NEURON_FALLBACK_VERSION="8.2.6"   # newest NEURON build still compatible with
                                    # Python 3.7 as of writing this script —
                                    # if pip rejects it as yanked/missing too,
                                    # it'll print the versions that ARE
                                    # available; update this variable and re-run.
PROXY_PORT=8080                    # the single link you share with everyone
BACKEND_PORT_START=9001            # internal per-session ports (not exposed
                                    # directly — only PROXY_PORT needs a
                                    # firewall rule)
MAX_CONCURRENT_USERS=60
IDLE_TIMEOUT_MIN=60                # auto-stop a session after this much idle time

echo "=============================================================="
echo " NetPyNE-UI Linux setup (multi-user, target: $MAX_CONCURRENT_USERS concurrent)"
echo "=============================================================="

# ---------------------------------------------------------------------------
# 1. System packages: build tools, X11/Tk libs (NEURON), Python 3.7 via
#    deadsnakes (modern Ubuntu no longer ships 3.7 in default repos)
# ---------------------------------------------------------------------------
echo "-> Installing system packages..."
sudo apt update
sudo apt install -y \
    software-properties-common build-essential \
    libx11-dev libxext-dev curl git ufw

if ! command -v python3.7 &>/dev/null; then
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt update
    sudo apt install -y python3.7 python3.7-venv python3.7-dev
fi
echo "-> python3.7: $(python3.7 --version)"

# Confirm it's a shared-lib build (needed for NEURON's Python bindings)
SHARED=$(python3.7 -c "import sysconfig; print(sysconfig.get_config_var('Py_ENABLE_SHARED'))")
if [ "$SHARED" != "1" ]; then
    echo "WARNING: python3.7 was not built with --enable-shared (Py_ENABLE_SHARED=$SHARED)."
    echo "NEURON's Python bindings may fail to load. deadsnakes builds are normally"
    echo "shared already — if this warning appears, you may need to rebuild manually."
fi

# ---------------------------------------------------------------------------
# 2. Clone the repo
# ---------------------------------------------------------------------------
if [ ! -d "$REPO_DIR" ]; then
    echo "-> Cloning NetPyNE-UI..."
    git clone "$REPO_URL" "$REPO_DIR"
else
    echo "-> $REPO_DIR already exists, skipping clone."
fi
cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# 3. Fresh venv, explicitly from python3.7 (avoids the "wrong interpreter
#    silently picked up" issue we hit with conda/base layering)
# ---------------------------------------------------------------------------
echo "-> Creating fresh venv..."
rm -rf npenv
python3.7 -m venv npenv
source npenv/bin/activate

echo "-> Active python: $(which python)"
echo "-> Version: $(python --version)"
if [[ "$(python --version 2>&1)" != *"$PYTHON_VERSION"* ]]; then
    echo "ERROR: venv is not using Python $PYTHON_VERSION. Aborting."
    exit 1
fi

python -m pip install --upgrade pip

# ---------------------------------------------------------------------------
# 4. Patch the yanked NEURON pin
# ---------------------------------------------------------------------------
if grep -q "NEURON==8.2.2" requirements.txt 2>/dev/null; then
    echo "-> Patching yanked NEURON==8.2.2 pin -> NEURON==$NEURON_FALLBACK_VERSION"
    sed -i "s/NEURON==8.2.2/NEURON==$NEURON_FALLBACK_VERSION/" requirements.txt
fi
grep -rl "NEURON==8.2.2" . 2>/dev/null | xargs -r sed -i "s/NEURON==8.2.2/NEURON==$NEURON_FALLBACK_VERSION/"

# ---------------------------------------------------------------------------
# 5. nvm + Node 14 + yarn + yalc
# ---------------------------------------------------------------------------
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
    echo "-> Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install "$NODE_VERSION"
nvm use "$NODE_VERSION"
echo "-> node: $(node --version)"
echo "-> npm:  $(npm --version)"

npm install -g yarn yalc
echo "-> yarn: $(yarn --version)"
echo "-> yalc: $(yalc --version)"

# sass@1.104.1 demands Node >=20.19.0; we're intentionally on Node 14
yarn config set ignore-engines true

# ---------------------------------------------------------------------------
# 6. Run the installer WITHOUT --netpyne development / --geppetto development
#    (the development branch's network/conn.py uses a walrus operator,
#    a Python 3.8+ syntax feature -> hard SyntaxError under 3.7)
# ---------------------------------------------------------------------------
echo "-> Running installer (NEURON build, workspace clone, frontend webpack build — slow)..."
python utilities/install.py --no-test

# ---------------------------------------------------------------------------
# 7. Patch netpyne_geppetto.py: the installed stable NetPyNE's
#    sim.loadModel() doesn't accept ignoreMechAlreadyExistsError
# ---------------------------------------------------------------------------
GEPPETTO_FILE="netpyne_ui/netpyne_geppetto.py"
if grep -q "ignoreMechAlreadyExistsError" "$GEPPETTO_FILE" 2>/dev/null; then
    echo "-> Patching $GEPPETTO_FILE (removing unsupported kwarg)"
    sed -i 's/, ignoreMechAlreadyExistsError=True//' "$GEPPETTO_FILE"
fi

# ---------------------------------------------------------------------------
# 8. Install aiohttp for the session proxy
# ---------------------------------------------------------------------------
pip install aiohttp

# ---------------------------------------------------------------------------
# 9. Raise file-descriptor limits for this session/user.
#    At ~60 concurrent users, each with an HTTP + websocket connection
#    through the proxy plus its own backend's sockets, the default
#    ulimit -n (often 1024) can become a real ceiling. Bump it, and make
#    it persist for future logins too.
# ---------------------------------------------------------------------------
echo "-> Current file descriptor limit: $(ulimit -n)"
ulimit -n 65535 2>/dev/null || echo "   (could not raise in this shell; see persistent step below)"

LIMITS_LINE_SOFT="$USER soft nofile 65535"
LIMITS_LINE_HARD="$USER hard nofile 65535"
if ! grep -q "$USER soft nofile" /etc/security/limits.conf 2>/dev/null; then
    echo "-> Adding persistent nofile limits to /etc/security/limits.conf (requires sudo)"
    echo "$LIMITS_LINE_SOFT" | sudo tee -a /etc/security/limits.conf >/dev/null
    echo "$LIMITS_LINE_HARD" | sudo tee -a /etc/security/limits.conf >/dev/null
    echo "   NOTE: this takes effect on your NEXT login/shell, not the current one."
fi

# ---------------------------------------------------------------------------
# 10. Write out netpyne-multi.sh (per-session instance manager)
# ---------------------------------------------------------------------------
echo "-> Writing netpyne-multi.sh"
cat > netpyne-multi.sh << 'MULTIEOF'
#!/bin/bash
# netpyne-multi.sh — start/stop/list isolated NetPyNE-UI instances, one per session.
NETPYNE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_ACTIVATE="$NETPYNE_DIR/npenv/bin/activate"
STATE_DIR="$HOME/.netpyne-multi"
LOG_DIR="$STATE_DIR/logs"
PID_DIR="$STATE_DIR/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

start_instance() {
    local name="$1" port="$2"
    local pidfile="$PID_DIR/$name.pid" logfile="$LOG_DIR/$name.log"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        echo "already running (PID $(cat "$pidfile"))."
        return
    fi
    (
        cd "$NETPYNE_DIR" || exit 1
        source "$VENV_ACTIVATE"
        nohup python run.py --ip=127.0.0.1 --port="$port" > "$logfile" 2>&1 &
        echo $! > "$pidfile"
    )
    sleep 1
    if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        echo "OK: '$name' running on port $port (PID $(cat "$pidfile")), log: $logfile"
    else
        echo "FAILED: '$name' did not start — see $logfile"
    fi
}

stop_instance() {
    local name="$1" pidfile="$PID_DIR/$name.pid"
    [ -f "$pidfile" ] || { echo "No instance '$name'."; return; }
    local pid; pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null && echo "Stopped '$name' (PID $pid)." || echo "'$name' was not running."
    rm -f "$pidfile"
}

stop_all() {
    for pidfile in "$PID_DIR"/*.pid; do
        [ -e "$pidfile" ] || continue
        stop_instance "$(basename "$pidfile" .pid)"
    done
}

list_instances() {
    local any=0
    for pidfile in "$PID_DIR"/*.pid; do
        [ -e "$pidfile" ] || continue
        any=1
        local name pid
        name=$(basename "$pidfile" .pid); pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  - $name — PID $pid — RUNNING"
        else
            echo "  - $name — stale pidfile"
        fi
    done
    [ "$any" -eq 0 ] && echo "(none running)"
}

case "$1" in
    start)    start_instance "$2" "$3" ;;
    stop)     stop_instance "$2" ;;
    stop-all) stop_all ;;
    list)     list_instances ;;
    *) echo "Usage: $0 {start <name> <port>|stop <name>|stop-all|list}"; exit 1 ;;
esac
MULTIEOF
chmod +x netpyne-multi.sh

# ---------------------------------------------------------------------------
# 11. Write out session_proxy.py (single URL, spawns isolated backend per
#     new visitor, proxies HTTP + websocket, sized for MAX_CONCURRENT_USERS)
# ---------------------------------------------------------------------------
echo "-> Writing session_proxy.py"
cat > session_proxy.py << PROXYEOF
#!/usr/bin/env python3
"""
session_proxy.py — one public URL; every new visitor automatically gets
their own isolated NetPyNE-UI backend. Sized for up to $MAX_CONCURRENT_USERS
concurrent sessions — see MAX_SESSIONS below.
"""
import asyncio, subprocess, time, uuid, logging
from aiohttp import web, ClientSession, WSMsgType, ClientTimeout

PROXY_HOST = "0.0.0.0"
PROXY_PORT = $PROXY_PORT
BACKEND_PORT_START = $BACKEND_PORT_START
MAX_SESSIONS = $MAX_CONCURRENT_USERS
MANAGE_SCRIPT = "./netpyne-multi.sh"
BACKEND_STARTUP_TIMEOUT = 60
IDLE_TIMEOUT_MIN = $IDLE_TIMEOUT_MIN
COOKIE_NAME = "netpyne_session"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("session_proxy")

SESSIONS = {}
_next_port = BACKEND_PORT_START

def allocate_port():
    global _next_port
    port = _next_port
    _next_port += 1
    return port

async def wait_for_backend(port, timeout=BACKEND_STARTUP_TIMEOUT):
    deadline = time.time() + timeout
    async with ClientSession(timeout=ClientTimeout(total=3)) as session:
        while time.time() < deadline:
            try:
                async with session.get(f"http://127.0.0.1:{port}/") as resp:
                    if resp.status < 500:
                        return True
            except Exception:
                pass
            await asyncio.sleep(1)
    return False

async def spawn_backend(session_id):
    if len(SESSIONS) >= MAX_SESSIONS:
        log.warning("MAX_SESSIONS reached — refusing new session.")
        return None
    port = allocate_port()
    log.info(f"Spawning backend for {session_id[:8]} on port {port} ...")
    proc = subprocess.run([MANAGE_SCRIPT, "start", session_id, str(port)],
                           capture_output=True, text=True)
    log.info(proc.stdout.strip())
    if "FAILED" in proc.stdout:
        log.error(f"Failed to start backend for {session_id[:8]}: {proc.stdout}")
        return None
    if not await wait_for_backend(port):
        log.error(f"Backend for {session_id[:8]} did not come up in time.")
        return None
    log.info(f"Backend for {session_id[:8]} ready on port {port}.")
    return port

async def get_or_create_session(request):
    session_id = request.cookies.get(COOKIE_NAME)
    if session_id and session_id in SESSIONS:
        SESSIONS[session_id]["last_used"] = time.time()
        return session_id, SESSIONS[session_id]["port"], False
    session_id = str(uuid.uuid4())
    port = await spawn_backend(session_id)
    if port is None:
        return None, None, False
    SESSIONS[session_id] = {"port": port, "last_used": time.time()}
    return session_id, port, True

async def http_handler(request):
    session_id, port, is_new = await get_or_create_session(request)
    if port is None:
        return web.Response(status=503, text="Server is at capacity ($MAX_CONCURRENT_USERS sessions). Please try again shortly.")
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await ws_proxy(request, port, session_id, is_new)
    target_url = f"http://127.0.0.1:{port}{request.rel_url}"
    headers = {k: v for k, v in request.headers.items() if k.lower() != "host"}
    async with ClientSession(timeout=ClientTimeout(total=120)) as client:
        data = await request.read()
        async with client.request(request.method, target_url, headers=headers,
                                   data=data, allow_redirects=False) as backend_resp:
            body = await backend_resp.read()
            resp = web.Response(
                status=backend_resp.status, body=body,
                headers={k: v for k, v in backend_resp.headers.items()
                         if k.lower() not in ("content-length", "content-encoding", "transfer-encoding")})
            if is_new:
                resp.set_cookie(COOKIE_NAME, session_id, httponly=True, max_age=60*60*24)
            return resp

async def ws_proxy(request, port, session_id, is_new):
    ws_server = web.WebSocketResponse()
    await ws_server.prepare(request)
    if is_new:
        ws_server.set_cookie(COOKIE_NAME, session_id, httponly=True, max_age=60*60*24)
    target_url = f"ws://127.0.0.1:{port}{request.rel_url}"
    async with ClientSession() as client:
        async with client.ws_connect(target_url) as ws_client:
            async def forward(src, dst):
                async for msg in src:
                    if msg.type == WSMsgType.TEXT:
                        await dst.send_str(msg.data)
                    elif msg.type == WSMsgType.BINARY:
                        await dst.send_bytes(msg.data)
                    elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                        break
            await asyncio.gather(forward(ws_server, ws_client), forward(ws_client, ws_server))
    return ws_server

async def idle_reaper():
    if IDLE_TIMEOUT_MIN <= 0:
        return
    while True:
        await asyncio.sleep(60)
        cutoff = time.time() - IDLE_TIMEOUT_MIN * 60
        for session_id, info in list(SESSIONS.items()):
            if info["last_used"] < cutoff:
                log.info(f"Session {session_id[:8]} idle — stopping backend.")
                subprocess.run([MANAGE_SCRIPT, "stop", session_id])
                del SESSIONS[session_id]

async def on_startup(app):
    app["reaper_task"] = asyncio.create_task(idle_reaper())

def main():
    app = web.Application()
    app.router.add_route("*", "/{path:.*}", http_handler)
    app.on_startup.append(on_startup)
    log.info(f"Session proxy listening on http://{PROXY_HOST}:{PROXY_PORT}/  (capacity: {MAX_SESSIONS} sessions)")
    web.run_app(app, host=PROXY_HOST, port=PROXY_PORT)

if __name__ == "__main__":
    main()
PROXYEOF

# ---------------------------------------------------------------------------
# 12. Firewall: open ONLY the proxy port. Backend ports stay internal
#     (127.0.0.1-only in netpyne-multi.sh above), so they're never exposed
#     directly — only the proxy is reachable from the network.
# ---------------------------------------------------------------------------
echo "-> Opening firewall for proxy port $PROXY_PORT only..."
sudo ufw allow "$PROXY_PORT"/tcp || true

echo "=============================================================="
echo " Install complete."
echo "=============================================================="
echo
echo "IMPORTANT — read before inviting 60 people:"
echo "  Each active session is a full NEURON-backed Python process."
echo "  Check your headroom before assuming this box can truly sustain"
echo "  60 concurrent simulations:"
echo
echo "    nproc          # CPU cores available"
echo "    free -h        # RAM available"
echo
echo "  If resources are tight, lower MAX_CONCURRENT_USERS at the top of"
echo "  session_proxy.py and test with a smaller group first — the proxy"
echo "  will cleanly refuse new sessions past that cap (HTTP 503) rather"
echo "  than overloading the machine."
echo
echo "To start serving (leave this running):"
echo
echo "  cd $(pwd)"
echo "  source npenv/bin/activate"
echo "  python3 session_proxy.py"
echo
echo "Share ONE link with everyone — each visitor gets their own isolated"
echo "session automatically:"
echo
echo "  http://$(hostname -I | awk '{print $1}'):$PROXY_PORT/"
echo
echo "Useful commands while running:"
echo "  ./netpyne-multi.sh list        # see active per-user backends"
echo "  ./netpyne-multi.sh stop-all    # stop every backend"
echo
echo "Consider running session_proxy.py under 'screen', 'tmux', or a"
echo "systemd service so it survives you closing this terminal."
