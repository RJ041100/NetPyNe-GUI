# NetPyNE-UI — Hosting Scripts

Scripts to install and run [NetPyNE-UI](https://github.com/MetaCell/NetPyNE-UI) on macOS, Linux, or Windows.

## Main file — start here

**`Install.sh`** is the only file you need to run. It automatically detects your operating system and hands off to the correct platform-specific script below — you don't need to figure out which one applies to you. 

  ## For Windows systems user should sign in to docker setup once installed by the script.  

### Run it

```bash
bash Install.sh
```

Works the same way on **macOS**, **Linux**, and **Windows** (via Git Bash — if Git Bash, WSL2, or Docker Desktop aren't installed yet on Windows, `Install.sh` installs them automatically before continuing).

On Windows, you can alternatively just **double-click `Install.sh`** if it's saved with a `.bat` extension on your system — either way runs the exact same setup.

---

## Platform scripts (called automatically by Install.sh)

| Script | OS | What it does |
|---|---|---|
| `setup_netpyne_ui_mac.sh` | macOS | Installs Python 3.7, NEURON, and Node tooling via Homebrew/pyenv, then builds and runs NetPyNE-UI natively. |
| `setup_netpyne_ui_linux.sh` | Linux | Same native install as macOS, but via apt/deadsnakes, plus optional multi-user hosting for several people at once. |
| `run_netpyne_docker_windows.sh` | Windows | Runs NetPyNE-UI in a Docker container — pulls a pre-built image, or builds one locally if that's unavailable. |

You never need to run these directly — `Install.sh` picks the right one for you automatically.

---

## Notes

- All scripts must stay in the same folder as `Install.sh`.
- The first run may take a while (installing Python/Node/NEURON dependencies); later runs are much faster.
- Once installed, each script prints the local URL to open the GUI, plus instructions for letting others on your network access it.
"# NetPyNe-GUI" 
