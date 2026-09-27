#!/bin/bash
#
# setup_netpyne_ui_mac.sh  —  NetPyNE-UI on macOS (Intel or Apple Silicon)
#
# Encodes every fix found the hard way:
#
#   * Python must be x86_64. NEURON has never shipped a cp37 arm64 wheel, so on
#     Apple Silicon an arm64 Python 3.7 gives "No matching distribution found"
#     for EVERY NEURON version. We use python.org's 3.7.9 framework build, which
#     is x86_64 on both architectures, instead of compiling via pyenv.
#   * Node 14 has no darwin-arm64 binary (arm64 builds start at v16). nvm's
#     fallback is to compile from source, which cannot succeed: Node 14's
#     bundled zlib #defines fdopen, colliding with the modern macOS SDK's
#     stdio.h. We drop the darwin-x64 tarball into nvm's directory by hand.
#   * pip MUST be upgraded before requirements.txt. install.py shells out to
#     bare `pip`, and pip 20's non-backtracking resolver dies on the
#     neuromllite -> modelspec -> cattrs>=23.2.3 chain (cattrs 23 needs 3.8+).
#     Modern pip backtracks to modelspec 0.3.2 / cattrs 1.0.0 on its own.
#   * NEURON==8.2.2 was yanked from PyPI; 8.2.6 is the last 3.7-compatible build.
#   * sass demands Node >=20, so yarn needs ignore-engines under Node 14.
#   * NetPyNE's "development" branch uses a walrus operator -> SyntaxError on
#     3.7, so we never pass --netpyne development.
#   * Stable NetPyNE's sim.loadModel() has no ignoreMechAlreadyExistsError kwarg.
#   * MPLBACKEND=Agg, or a GUI matplotlib backend aborts inside the kernel.
#
# Usage, from the directory where you want NetPyNE-UI cloned:
#   chmod +x setup_netpyne_ui_mac.sh && ./setup_netpyne_ui_mac.sh
#
# Safe to re-run. Every step checks before acting; only the venv is rebuilt.

set -euo pipefail

REPO_URL="https://github.com/MetaCell/NetPyNE-UI.git"
REPO_DIR="NetPyNE-UI"
PY_VERSION="3.7.9"
PY_PKG_URL="https://www.python.org/ftp/python/${PY_VERSION}/python-${PY_VERSION}-macosx10.9.pkg"
PY_BIN="/Library/Frameworks/Python.framework/Versions/3.7/bin/python3.7"
NODE_VERSION="14.21.3"
NODE_DIR="$HOME/.nvm/versions/node/v${NODE_VERSION}"
NEURON_VERSION="8.2.6"

die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "=== $* ==="; }

# Never run this from inside an existing clone — that is how a nested
# NetPyNE-UI/NetPyNE-UI directory gets created.
if [ -f "./run.py" ] && [ -d "./netpyne_ui" ]; then
    die "You are inside a NetPyNE-UI clone. Run this from the PARENT directory."
fi

ARCH="$(uname -m)"
echo "=============================================================="
echo " NetPyNE-UI macOS setup   (arch: $ARCH)"
echo "=============================================================="

# --------------------------------------------------------------------------
step "1. Xcode Command Line Tools"
# --------------------------------------------------------------------------
if ! xcode-select -p &>/dev/null; then
    echo "-> Installing (a GUI prompt will appear)..."
    xcode-select --install || true
    die "Re-run this script once the Command Line Tools install finishes."
fi
echo "-> Present."

# --------------------------------------------------------------------------
step "2. Rosetta 2 (Apple Silicon only)"
# --------------------------------------------------------------------------
# The entire stack below is x86_64: Python, NEURON, Node. Rosetta runs it.
if [ "$ARCH" = "arm64" ]; then
    if /usr/bin/pgrep -q oahd 2>/dev/null; then
        echo "-> Already installed."
    else
        echo "-> Installing Rosetta 2..."
        softwareupdate --install-rosetta --agree-to-license \
            || die "Rosetta install failed. Run it manually, then re-run this script."
    fi
else
    echo "-> Intel Mac, not needed."
fi

# --------------------------------------------------------------------------
step "3. git"
# --------------------------------------------------------------------------
command -v git &>/dev/null || die "git not found. Install Xcode CLT or Homebrew git."
echo "-> $(git --version)"

# --------------------------------------------------------------------------
step "4. Python 3.7.9 (x86_64 framework build)"
# --------------------------------------------------------------------------
# Deliberately NOT pyenv: a pyenv build on Apple Silicon produces an arm64
# interpreter, and no arm64 cp37 NEURON wheel exists on PyPI.
if [ -x "$PY_BIN" ]; then
    echo "-> Already installed at $PY_BIN"
else
    echo "-> Downloading python-${PY_VERSION}-macosx10.9.pkg ..."
    TMP_PKG="$(mktemp -d)/python.pkg"
    curl -fL# -o "$TMP_PKG" "$PY_PKG_URL" || die "Download failed: $PY_PKG_URL"
    echo "-> Installing (sudo password required)..."
    sudo installer -pkg "$TMP_PKG" -target / || die "Python installer failed."
    CERTS="/Applications/Python 3.7/Install Certificates.command"
    [ -f "$CERTS" ] && "$CERTS" >/dev/null 2>&1 || true
fi

[ -x "$PY_BIN" ] || die "Expected python at $PY_BIN but it is not there."

PY_ARCH="$("$PY_BIN" -c 'import platform; print(platform.machine())')"
echo "-> $("$PY_BIN" --version 2>&1)  (arch: $PY_ARCH)"
[ "$PY_ARCH" = "x86_64" ] || die "Python reports $PY_ARCH, need x86_64. NEURON has no cp37 arm64 wheel."

# --------------------------------------------------------------------------
step "5. nvm + Node ${NODE_VERSION} (darwin-x64 binary, installed by hand)"
# --------------------------------------------------------------------------
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "-> Installing nvm..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

if [ -x "$NODE_DIR/bin/node" ]; then
    echo "-> Node ${NODE_VERSION} already present."
else
    # Do NOT use `nvm install 14` here. It probes for darwin-arm64, gets a 404,
    # then falls back to a source build that cannot compile on a modern SDK.
    echo "-> Downloading node-v${NODE_VERSION}-darwin-x64 ..."
    rm -rf "$HOME/.nvm/.cache/src/node-v${NODE_VERSION}"
    TMP_NODE="$(mktemp -d)"
    curl -fL# -o "$TMP_NODE/node.tar.gz" \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-x64.tar.gz" \
        || die "Node download failed."
    tar -xzf "$TMP_NODE/node.tar.gz" -C "$TMP_NODE"
    mkdir -p "$HOME/.nvm/versions/node"
    mv "$TMP_NODE/node-v${NODE_VERSION}-darwin-x64" "$NODE_DIR"
fi

nvm use "$NODE_VERSION" >/dev/null || die "nvm could not activate Node ${NODE_VERSION}."
echo "-> node $(node --version) / npm $(npm --version)"

command -v yarn &>/dev/null || npm install -g yarn --silent
command -v yalc &>/dev/null || npm install -g yalc --silent
echo "-> yarn $(yarn --version) / yalc $(yalc --version)"

# sass@1.104+ demands Node >=20.19 and aborts the install under Node 14.
yarn config set ignore-engines true >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
step "6. Clone repository"
# --------------------------------------------------------------------------
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
else
    echo "-> $REPO_DIR already exists, skipping clone."
fi
cd "$REPO_DIR"
REPO_PATH="$(pwd)"

# A nested clone from a previous mis-run confuses the frontend build.
if [ -d "$REPO_DIR" ]; then
    echo "-> WARNING: nested $REPO_DIR/$REPO_DIR found (left by an earlier run)."
    echo "   Remove it if the build behaves oddly:  rm -rf '$REPO_PATH/$REPO_DIR'"
fi

# --------------------------------------------------------------------------
step "7. Fresh venv from the x86_64 interpreter"
# --------------------------------------------------------------------------
rm -rf npenv
"$PY_BIN" -m venv npenv
# shellcheck disable=SC1091
source npenv/bin/activate

VENV_ARCH="$(python -c 'import platform; print(platform.machine())')"
echo "-> $(python --version 2>&1) at $(which python)  (arch: $VENV_ARCH)"
[ "$VENV_ARCH" = "x86_64" ] || die "venv is $VENV_ARCH, expected x86_64."

# THE critical ordering fix: modern pip before any requirements resolution.
echo "-> Upgrading pip (old resolver cannot solve this dependency tree)..."
python -m pip install --upgrade pip --quiet
echo "-> pip $(pip --version | awk '{print $2}')"

# --------------------------------------------------------------------------
step "8. Patch the yanked NEURON pin"
# --------------------------------------------------------------------------
if grep -rq "NEURON==8.2.2" . 2>/dev/null; then
    echo "-> NEURON==8.2.2 (yanked) -> NEURON==${NEURON_VERSION}"
    grep -rl "NEURON==8.2.2" . --exclude-dir=npenv --exclude-dir=.git 2>/dev/null \
        | xargs -I{} sed -i '' "s/NEURON==8.2.2/NEURON==${NEURON_VERSION}/" {} || true
else
    echo "-> No 8.2.2 pin found, nothing to patch."
fi

# --------------------------------------------------------------------------
step "9. Python dependencies"
# --------------------------------------------------------------------------
# Done explicitly here, with good pip, so install.py's own bare-`pip` call
# later finds everything already satisfied and becomes a no-op.
echo "-> Installing requirements.txt (several minutes)..."
pip install -r requirements.txt

echo "-> Verifying NEURON imports..."
python -c "from neuron import h; print('   NEURON', h.nrnversion())" \
    || die "NEURON installed but will not import. Check architecture with:
       file npenv/lib/python3.7/site-packages/neuron/.data/lib/libnrniv.dylib"
python -c "import netpyne; print('   netpyne', netpyne.__version__)"

# --------------------------------------------------------------------------
step "10. Installer + frontend build"
# --------------------------------------------------------------------------
# --netpyne development is deliberately omitted: that branch's walrus
# operator in network/conn.py is a hard SyntaxError under Python 3.7.
echo "-> Running install.py (long: workspace clone + webpack build)..."
python utilities/install.py --no-test

# --------------------------------------------------------------------------
step "11. Patch unsupported kwarg"
# --------------------------------------------------------------------------
GEPPETTO_FILE="netpyne_ui/netpyne_geppetto.py"
if grep -q "ignoreMechAlreadyExistsError" "$GEPPETTO_FILE" 2>/dev/null; then
    echo "-> Removing ignoreMechAlreadyExistsError (absent from stable NetPyNE)."
    sed -i '' 's/, ignoreMechAlreadyExistsError=True//' "$GEPPETTO_FILE"
else
    echo "-> Not present, nothing to patch."
fi

# --------------------------------------------------------------------------
step "12. Write launcher"
# --------------------------------------------------------------------------
cat > start_netpyne_ui.sh <<LAUNCHER
#!/bin/bash
# Generated by setup_netpyne_ui_mac.sh
set -e
cd "\$(dirname "\$0")"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh" && nvm use ${NODE_VERSION} >/dev/null
source npenv/bin/activate
# Agg keeps matplotlib headless; a GUI backend aborts inside the Jupyter kernel.
export MPLBACKEND=Agg
exec python run.py --ip=0.0.0.0 --port=8081
LAUNCHER
chmod +x start_netpyne_ui.sh

echo ""
echo "=============================================================="
echo " Done."
echo "=============================================================="
cat <<EOF

Start it:

  cd "$REPO_PATH"
  ./start_netpyne_ui.sh

Then open  http://localhost:8081/

Before sharing on your LAN, set a password — this runs arbitrary code:

  source npenv/bin/activate && jupyter notebook password

Find your LAN address:

  ipconfig getifaddr en0     # Wi-Fi
  ipconfig getifaddr en1     # Ethernet

macOS will ask to allow incoming connections the first time; click Allow.

If the kernel dies ("Python quit unexpectedly"), the crash report names the
faulting library — that is the piece of information worth reading:

  ls -t ~/Library/Logs/DiagnosticReports/*.ips | head -1

EOF
