# Nockchain Launcher

This is a clean terminal UI to build, run, and monitor your Nockchain miners. It handles wallets, builds, updates, tmux sessions, and provides real-time system stats. Designed to be accessible for all experience levels.

---

## Requirements

- Ubuntu/Debian-based OS (or any Linux with bash)
- `make`, `screen`, `tmux`, and standard build tools

---

## Quick Start

### 1. (Optional) Update your system and install curl (only once)
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install curl -y
```

### 2. Download the launcher script
```bash
curl -O https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/nockchain_launcher.sh
chmod +x nockchain_launcher.sh
```

### 3. Run the launcher
```bash
./nockchain_launcher.sh
```

That’s it, follow the menu to set up or launch miners.

---

## What It Does

- Detects wallet or lets you generate one
- Builds Nockchain client from source
- Lets you launch as many miners as your machine can handle
- Real-time stats: CPU load, RAM, uptime
- Color-coded miner uptime (🟡 <5m | 🔵 <30m | 🟢 stable)
- Restart or stop miners with an interactive menu
- Auto-detects updates (via Git)
- Tmux integration: clean sessions, auto-recovery

---

## Tmux Basics

Each miner runs in its own tmux session (named `miner1`, `miner2`, etc.). Here's how to work with them:

### Reattach to a miner session
```bash
tmux attach -t miner1
```

### List all miner sessions
```bash
tmux ls
```

### Detach from a session (leave it running in the background)
Press **Ctrl + B**, then **D**

### Gracefully stop a node inside a session
Press **Ctrl + C**

### Stop (kill) a miner session
```bash
tmux kill-session -t miner1
```

---

Maintained by [jobless0x](https://github.com/jobless0x)
