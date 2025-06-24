# Nockchain Launcher

This is a clean terminal UI to build, run, and monitor your Nockchain miners. It handles wallets, builds, updates, systemd services, and provides real-time system stats. Designed to be accessible for all experience levels.

---

## Requirements

- Ubuntu/Debian-based OS (or any Linux with `bash` and `systemd`)
- `make`, `screen`, and standard build tools
- Optional: `fzf` (used for interactive menus, installed automatically if missing)

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

## Key Features and Capabilities

- Builds Nockchain client from source
- Generates or detects your wallet (.env)
- Launches multiple miners based on system capacity
- Full systemd integration (auto-restart, logs, service isolation)
- Interactive menus using fzf
- Color-coded miner uptime and sync monitoring
- Live system stats: CPU load, memory, uptime
- Export state.jam from any miner via safe duplication
- Customizable peer topology: isolated, central, mesh, or manual
- Configurable miner flags through launch.cfg
- Detects and handles software updates automatically

---

## Systemd Basics

Each miner runs as a systemd service (named `nockchain-miner1`, `nockchain-miner2`, etc.). Here's how to manage them:

### Check service status
```bash
systemctl status nockchain-miner1
```

### View logs (live)
```bash
tail -f ~/nockchain/miner1/miner1.log
```

### Stop a miner
```bash
sudo systemctl stop nockchain-miner1
```

### Start a miner
```bash
sudo systemctl start nockchain-miner1
```

### Restart a miner
```bash
sudo systemctl restart nockchain-miner1
```

---

## Exporting a `state.jam`

To generate a snapshot of your miner state:

1. Select "Export state.jam" from the main menu.
2. Choose the source miner.
3. A safe duplicate of the miner will be created.
4. The exported file is saved to:

```bash
~/nockchain/state.jam
```

It will be auto used by all miner starting or restarting.

---

## Editing Configuration

All miner setup is saved in:

```bash
~/launch.cfg
```

Each `[minerX]` block includes:

- `MINING_KEY`
- `BIND_FLAG`, `PEER_FLAG`, `MAX_ESTABLISHED_FLAG`
- `STATE_FLAG`

You can safely edit this file to customize peers, ports, and state behavior.

---

## Useful Paths

| Purpose           | Path                                  |
|-------------------|----------------------------------------|
| Launcher Script   | `~/nockchain_launcher.sh`             |
| Miner Logs        | `~/nockchain/minerX/minerX.log`       |
| Config File       | `~/launch.cfg`                        |
| State Export      | `~/nockchain/state.jam`               |
| Build Logs        | `~/nockchain/build.log`               |

---

## Pro Tips

- Run this to inspect running miner commands:
  ```bash
  ps -eo pid,ppid,cmd | grep nockchain
  ```
- `fzf` menus make stopping/restarting miners intuitive
- You can run the launcher again anytime, it won't overwrite existing miners unless you ask it to

---

Maintained by [jobless0x](https://github.com/jobless0x), feel free to fork or contribute.
