#!/bin/bash
set -e

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD_BLUE="\e[1;34m"
DIM="\e[2m"
RESET="\e[0m"

for dep in tmux screen; do
  if ! command -v "$dep" &>/dev/null; then
    echo -e "${RED}Error: Required dependency '$dep' is not installed.${RESET}"
    exit 1
  fi
done

if [[ -n "$TMUX" ]]; then
  echo -e "${RED}⚠️  Please exit tmux before running this script.${RESET}"
  exit 1
fi

start_miner_tmux() {
  local session=$1
  local dir=$2
  local key=$3

  if tmux has-session -t "$session" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Skipping $session: tmux session already exists.${RESET}"
    return
  fi

  cd "$dir"
  bash "$SCRIPT_DIR/start_miner.sh" "$dir" "$key"

  sleep 0.5

  if tmux has-session -t "$session" 2>/dev/null; then
    echo -e "${GREEN}✅ $session is running in tmux session '$session'.${RESET}"
  else
    echo -e "${RED}❌ Failed to launch $session. Tmux session not found.${RESET}"
  fi
}

# Calculate uptime of a running tmux miner session (formatted as h/m)
get_miner_uptime() {
  local session=$1
  if tmux has-session -t "$session" 2>/dev/null; then
    local start_ts=$(tmux display -p -t "$session" '#{start_time}' 2>/dev/null)
    local now_ts=$(date +%s)
    local diff=$((now_ts - start_ts))
    local hours=$((diff / 3600))
    local minutes=$(((diff % 3600) / 60))
    if (( hours > 0 )); then
      echo "${hours}h ${minutes}m"
    else
      echo "${minutes}m"
    fi
  else
    echo "not running"
  fi
}

NCK_DIR="$HOME/nockchain"
NCK_BIN="$NCK_DIR/target/release/nockchain"

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/launch.cfg"
LAUNCHER_VERSION_FILE="$(dirname "$SCRIPT_PATH")/NOCKCHAIN_LAUNCHER_VERSION"
if [[ -f "$LAUNCHER_VERSION_FILE" ]]; then
  LAUNCHER_VERSION=$(cat "$LAUNCHER_VERSION_FILE" | tr -d '[:space:]')
else
  LAUNCHER_VERSION="(unknown)"
fi
# Fetch remote version directly, do not overwrite local version file except during update
REMOTE_VERSION=$(curl -fsSL https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/NOCKCHAIN_LAUNCHER_VERSION | tr -d '[:space:]')

# Begin main launcher loop that displays the menu and handles user input
while true; do
clear

echo -e "${RED}"
cat <<'EOF'
                  _        _           _       
 _ __   ___   ___| | _____| |__   __ _(_)_ __  
| '_ \ / _ \ / __| |/ / __| '_ \ / _` | | '_ \ 
| | | | (_) | (__|   < (__| | | | (_| | | | | |
|_| |_|\___/ \___|_|\_\___|_| |_|\__,_|_|_| |_|
EOF

echo -e "${YELLOW}:: Powered by Jobless ::${RESET}"

# Display launcher ASCII art, branding, and welcome text
echo -e "${DIM}Welcome to the Nockchain Node Manager.${RESET}"

# Extract network height from all miner logs (for dashboard)
NETWORK_HEIGHT="--"
all_blocks=()
for miner_dir in "$HOME/nockchain"/miner*; do
  [[ -d "$miner_dir" ]] || continue
  log_file="$miner_dir/$(basename "$miner_dir").log"
  if [[ -f "$log_file" ]]; then
    height=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K[0-9]+\.[0-9]+' | sort -V | tail -n 1)
    [[ -n "$height" ]] && all_blocks+=("$height")
  fi
done
if [[ ${#all_blocks[@]} -gt 0 ]]; then
  NETWORK_HEIGHT=$(printf "%s\n" "${all_blocks[@]}" | sort -V | tail -n 1)
fi

echo -e "${DIM}Install, configure, and monitor multiple Nockchain miners with ease.${RESET}"
echo ""

RUNNING_MINERS=$(tmux ls 2>/dev/null | grep -c '^miner' || true)
RUNNING_MINERS=${RUNNING_MINERS:-0}
MINER_FOLDERS=$(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" 2>/dev/null | wc -l)
if (( RUNNING_MINERS > 0 )); then
  echo -e "${GREEN}🟢 $RUNNING_MINERS active miners${RESET} ${DIM}($MINER_FOLDERS total miners)${RESET}"
else
  echo -e "${RED}🔴 No miners running${RESET} ${DIM}($MINER_FOLDERS total miners)${RESET}"
fi

 # Display current version of node and launcher, and update status
echo ""
VERSION="(not installed)"
NODE_STATUS="${YELLOW}Not installed${RESET}"

if [[ -d "$HOME/nockchain" && -d "$HOME/nockchain/.git" ]]; then
  cd "$HOME/nockchain"
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    LOCAL_HASH=$(git rev-parse "$BRANCH")
    REMOTE_HASH=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
    VERSION=$(git describe --tags --always 2>/dev/null)
    NODE_STATUS="${GREEN}✅ Up to date${RESET}"
    [[ "$LOCAL_HASH" != "$REMOTE_HASH" ]] && NODE_STATUS="${RED}🔴 Update available${RESET}"
  else
    NODE_STATUS="${YELLOW}(git info unavailable)${RESET}"
  fi
fi

if [[ -z "$REMOTE_VERSION" ]]; then
  LAUNCHER_STATUS="${YELLOW}⚠️  Cannot check update (offline)${RESET}"
elif [[ "$LAUNCHER_VERSION" == "$REMOTE_VERSION" ]]; then
  LAUNCHER_STATUS="${GREEN}✅ Up-to-date${RESET}"
else
  LAUNCHER_STATUS="${RED}🔴 Update available${RESET}"
fi

 # Always display version block (with improved alignment)
printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Node:" "$VERSION" "$NODE_STATUS"
printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Launcher:" "$LAUNCHER_VERSION" "$LAUNCHER_STATUS"

if [[ -d "$HOME/nockchain" ]]; then
  if [[ -f "$HOME/nockchain/.env" ]]; then
    if grep -q "^MINING_PUBKEY=" "$HOME/nockchain/.env"; then
      MINING_KEY_DISPLAY=$(grep "^MINING_PUBKEY=" "$HOME/nockchain/.env" 2>/dev/null | cut -d= -f2)
      printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Public Key:" "$MINING_KEY_DISPLAY" ""
    else
      printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Public Key:" "${YELLOW}(not defined in .env)${RESET}" ""
    fi
  else
    printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Public Key:" "${YELLOW}(no .env file)${RESET}" ""
  fi
else
  printf "  ${CYAN}%-12s${RESET}%b\n" "Public Key:" "${YELLOW}(not available)${RESET}"
fi
printf "  ${CYAN}%-12s${RESET}%-20s\n" "Height:" "$NETWORK_HEIGHT"
echo ""

# Show live system metrics: CPU load, memory usage, uptime
CPU_LOAD=$(awk '{print $1}' /proc/loadavg)
RAM_USED=$(free -h | awk '/^Mem:/ {print $3}')
RAM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
printf "  ${CYAN}%-12s${RESET}%-20s\n" "CPU Load:" "$CPU_LOAD / $(nproc)"
printf "  ${CYAN}%-12s${RESET}%-20s\n" "RAM Used:" "$RAM_USED / $RAM_TOTAL"
printf "  ${CYAN}%-12s${RESET}%-20s\n" "Uptime:" "$(uptime -p)"

echo -e "${RED}
NOCKCHAIN NODE MANAGER
---------------------------------------${RESET}"

echo -e "${CYAN}Setup:${RESET}"
echo -e "${BOLD_BLUE}1) Install Nockchain from scratch${RESET}"
echo -e "${BOLD_BLUE}2) Update nockchain to latest version${RESET}"
echo -e "${BOLD_BLUE}3) Update nockchain-wallet only${RESET}"
echo -e "${BOLD_BLUE}4) Update launcher script${RESET}"

echo -e ""
echo -e "${CYAN}Miner Operations:${RESET}"
echo -e "${BOLD_BLUE}5) Launch miner(s)${RESET}"
echo -e "${BOLD_BLUE}6) Restart miner(s)${RESET}"
echo -e "${BOLD_BLUE}7) Stop miner(s)${RESET}"

echo -e ""
echo -e "${CYAN}System Utilities:${RESET}"
echo -e "${BOLD_BLUE}0) Run system diagnostics${RESET}"
echo -e "${BOLD_BLUE}8) Show running miner(s)${RESET}"
echo -e "${BOLD_BLUE}9) Monitor resource usage (htop)${RESET}"

echo -e ""
echo -ne "${BOLD_BLUE}Select an option from the menu above (or press Enter to exit): ${RESET}"
 # Display tips for controlling tmux and screen sessions
echo -e ""
echo -e "${DIM}Tip: Use ${BOLD_BLUE}tmux ls${DIM} to see running miners, ${BOLD_BLUE}tmux attach -t miner1${DIM} to enter a session, ${BOLD_BLUE}Ctrl+b then d${DIM} to detach tmux, ${BOLD_BLUE}screen -r nockbuild${DIM} to monitor build sessions, and ${BOLD_BLUE}Ctrl+a then d${DIM} to detach screen.${RESET}"
read USER_CHOICE

# Define important paths for binaries and logs
BINARY_PATH="$HOME/nockchain/target/release/nockchain"
LOG_PATH="$HOME/nockchain/build.log"

if [[ -z "$USER_CHOICE" ]]; then
  echo -e "${CYAN}Exiting launcher. Goodbye!${RESET}"
  exit 0
fi

case "$USER_CHOICE" in
  0)
    clear
    echo -e "${CYAN}System Diagnostics${RESET}"
    echo ""

    # Diagnostics: Verify required tools are installed
    echo -e "${CYAN}▶ Required Commands${RESET}"
    echo -e "${DIM}-------------------${RESET}"
    for cmd in tmux screen cargo git curl make; do
      if command -v "$cmd" &>/dev/null; then
        echo -e "${GREEN}✔ $cmd found${RESET}"
      else
        echo -e "${RED}❌ $cmd missing${RESET}"
      fi
    done
    echo ""

    # Diagnostics: Check for Nockchain and wallet binary presence
    echo -e "${CYAN}▶ Key Paths & Binaries${RESET}"
    echo -e "${DIM}----------------------${RESET}"
    [[ -x "$HOME/nockchain/target/release/nockchain" ]] && echo -e "${GREEN}✔ nockchain binary present${RESET}" || echo -e "${RED}❌ nockchain binary missing${RESET}"
    [[ -x "$HOME/.cargo/bin/nockchain-wallet" ]] && echo -e "${GREEN}✔ nockchain-wallet present${RESET}" || echo -e "${RED}❌ nockchain-wallet missing${RESET}"
    echo ""

    # Diagnostics: Validate .env presence and mining key definition
    echo -e "${CYAN}▶ .env & MINING_PUBKEY${RESET}"
    echo -e "${DIM}-----------------------${RESET}"
    if [[ -f "$HOME/nockchain/.env" ]]; then
      echo -e "${GREEN}✔ .env file found${RESET}"
      if grep -q "^MINING_PUBKEY=" "$HOME/nockchain/.env"; then
        echo -e "${GREEN}✔ MINING_PUBKEY is defined${RESET}"
      else
        echo -e "${RED}❌ MINING_PUBKEY not found in .env${RESET}"
      fi
    else
      echo -e "${RED}❌ .env file is missing${RESET}"
    fi
    echo ""

    # Diagnostics: Count miner directories in local nockchain path
    echo -e "${CYAN}▶ Miner Folders${RESET}"
    echo -e "${DIM}--------------${RESET}"
    miner_count=$(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" 2>/dev/null | wc -l)
    if (( miner_count > 0 )); then
      echo -e "${GREEN}✔ $miner_count miner folder(s) found${RESET}"
    else
      echo -e "${RED}❌ No miner folders found${RESET}"
    fi
    echo ""

    # Diagnostics: Compare local vs remote git commit hash
    echo -e "${CYAN}▶ Nockchain Repository${RESET}"
    echo -e "${DIM}----------------------${RESET}"
    if [[ ! -d "$HOME/nockchain" ]]; then
      echo -e "${YELLOW}Nockchain is not installed yet.${RESET}"
    elif [[ ! -d "$HOME/nockchain/.git" ]]; then
      echo -e "${YELLOW}Nockchain exists but is not a Git repository.${RESET}"
    elif git -C "$HOME/nockchain" rev-parse &>/dev/null; then
      BRANCH=$(git -C "$HOME/nockchain" rev-parse --abbrev-ref HEAD)
      REMOTE_URL=$(git -C "$HOME/nockchain" config --get remote.origin.url)
      LOCAL_HASH=$(git -C "$HOME/nockchain" rev-parse "$BRANCH")
      REMOTE_HASH=$(git -C "$HOME/nockchain" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')

      printf "${GREEN}✔ %-15s${CYAN}%s${RESET}\n" "Remote URL:" "$REMOTE_URL"
      printf "${GREEN}✔ %-15s${BOLD_BLUE}%s${RESET}\n" "Branch:" "$BRANCH"

      if [[ "$LOCAL_HASH" != "$REMOTE_HASH" ]]; then
        printf "${RED}❌ %-15s%s${RESET}\n" "Status:" "Update available"
      else
        printf "${GREEN}✔ %-15s%s\n" "Status:" "Repo is up to date with remote."
      fi
    else
      echo -e "${RED}❌ Git repo appears broken${RESET}"
    fi
    echo ""

    # Diagnostics: Verify internet access to GitHub
    echo -e "${CYAN}▶ Internet Check${RESET}"
    echo -e "${DIM}-----------------${RESET}"
    if curl -fsSL https://github.com >/dev/null 2>&1; then
      echo -e "${GREEN}✔ GitHub is reachable${RESET}"
    else
      echo -e "${RED}❌ Cannot reach GitHub${RESET}"
    fi

    echo ""
    # Diagnostics: Check launcher version sync against GitHub
    echo -e "${CYAN}▶ Launcher Update Check${RESET}"
    echo -e "${DIM}-----------------------${RESET}"
    printf "${GREEN}✔ %-15s${BOLD_BLUE}%s${RESET}\n" "Local:" "$LAUNCHER_VERSION"
    if [[ -z "$REMOTE_VERSION" ]]; then
      printf "${YELLOW}⚠ %-15s%s${RESET}\n" "Remote:" "Unavailable (offline or fetch error)"
    else
      printf "${GREEN}✔ %-15s${CYAN}%s${RESET}\n" "Remote:" "$REMOTE_VERSION"
      if [[ "$LAUNCHER_VERSION" == "$REMOTE_VERSION" ]]; then
        printf "${GREEN}✔ %-15s%s\n" "Status:" "Up to date"
      else
        printf "${RED}❌ %-15s%s${RESET}\n" "Status:" "Update available"
      fi
    fi
    echo ""

    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  1)
    clear

    echo -e "${YELLOW}⚠️  This will install Nockchain from scratch. This may overwrite existing files.${RESET}"
    echo -e "${YELLOW}Are you sure you want to continue? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_INSTALL
      [[ "$CONFIRM_INSTALL" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ ! "$CONFIRM_INSTALL" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    fi

    # Handle sudo and root system preparation
    if [ "$(id -u)" -eq 0 ]; then
      echo -e "${YELLOW}>> Running as root. Updating system and installing sudo...${RESET}"
      apt-get update && apt-get upgrade -y

      if ! command -v sudo &> /dev/null; then
        apt-get install sudo -y
      fi
    fi

    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${YELLOW}>> Nockchain not built yet. Starting Phase 1 (Build)...${RESET}"

        echo -e "${CYAN}>> Installing system dependencies...${RESET}"
        sudo apt-get update && sudo apt-get upgrade -y
        sudo apt install -y curl iptables build-essential ufw screen git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libclang-dev llvm-dev

        if ! command -v cargo &> /dev/null; then
            echo -e "${CYAN}>> Installing Rust...${RESET}"
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            source "$HOME/.cargo/env"
        fi

        echo -e "${CYAN}>> Cloning Nockchain repo and starting build...${RESET}"
        rm -rf nockchain .nockapp
        git clone https://github.com/zorp-corp/nockchain
        cd nockchain
        cp .env_example .env

        if screen -ls | grep -q "nockbuild"; then
          echo -e "${YELLOW}A screen session named 'nockbuild' already exists. Killing it...${RESET}"
          screen -S nockbuild -X quit
        fi

        echo -e "${CYAN}>> Launching build in screen session 'nockbuild' and logging to build.log...${RESET}"
        screen -dmS nockbuild bash -c "cd \$HOME/nockchain && make install-hoonc && make build && make install-nockchain-wallet && make install-nockchain | tee build.log"

        echo -e "${GREEN}>> Build started in screen session 'nockbuild'.${RESET}"
        echo -e "${YELLOW}>> To monitor build: ${DIM}screen -r nockbuild${RESET}"
        echo -e "${DIM}Tip: Press ${CYAN}Ctrl+A${DIM}, then ${CYAN}D${DIM} to detach from the screen without stopping the build.${RESET}"
        echo -e "${YELLOW}Would you like to attach to the build screen session now? (y/n)${RESET}"
        while true; do
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" ATTACH_BUILD
          [[ "$ATTACH_BUILD" =~ ^[YyNn]$ ]] && break
          echo -e "${RED}❌ Please enter y or n.${RESET}"
        done
        if [[ "$ATTACH_BUILD" =~ ^[Yy]$ ]]; then
          screen -r nockbuild
        else
          echo -e "${CYAN}Returning to main menu...${RESET}"
          read -n 1 -s -r -p $'\nPress any key to continue...'
        fi
        continue
    fi

    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  2)
    clear
    echo -e "${YELLOW}You are about to update Nockchain to the latest version from GitHub.${RESET}"
    echo -e "${YELLOW}Continue? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_UPDATE
      [[ "$CONFIRM_UPDATE" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ ! "$CONFIRM_UPDATE" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    fi

    if screen -ls | grep -q "nockupdate"; then
      echo -e "${YELLOW}A screen session named 'nockupdate' already exists. Killing it...${RESET}"
      screen -S nockupdate -X quit
    fi

    echo -e "${YELLOW}Detected the following public key in .env that will be used to restart miners after update:${RESET}"
    MINING_KEY_DISPLAY=$(grep "^MINING_PUBKEY=" "$HOME/nockchain/.env" | cut -d= -f2)
    echo -e "${CYAN}Public Key:${RESET} $MINING_KEY_DISPLAY"
    echo -e "${YELLOW}Do you want to automatically restart all miners after update using this key? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_RESTART_AFTER_UPDATE
      [[ "$CONFIRM_RESTART_AFTER_UPDATE" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ "$CONFIRM_RESTART_AFTER_UPDATE" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}>> Launching update and miner restart in screen session 'nockupdate'...${RESET}"
      screen -dmS nockupdate bash -c "
        cd \$HOME/nockchain && \
        git pull && \
        make install-nockchain && \
        export PATH=\"\$HOME/.cargo/bin:\$PATH\" && \
        echo '>> Killing existing miners...' && \
        tmux ls 2>/dev/null | grep '^miner' | cut -d: -f1 | xargs -r -n1 tmux kill-session -t && \
        for d in \$HOME/nockchain/miner*; do
          session=\$(basename \"\$d\")
          \"$HOME/nockchain/node_launcher.sh\" internal_start_miner_tmux \"\$session\" \"\$d\" \"$MINING_KEY_DISPLAY\" \"n\"
          echo \"✅ Restarted \$session\"
        done
        echo 'Update and restart complete.'
        exec bash
      "
      echo -e "${GREEN}>> Update and miner restart process started in screen session 'nockupdate'.${RESET}"
    else
      echo -e "${CYAN}>> Launching update in screen session 'nockupdate' (miners will NOT be restarted)...${RESET}"
      screen -dmS nockupdate bash -c "
        cd \$HOME/nockchain && \
        git pull && \
        make install-nockchain && \
        export PATH=\"\$HOME/.cargo/bin:\$PATH\" && \
        echo 'Update complete. Miners were not restarted.' && \
        exec bash
      "
      echo -e "${GREEN}>> Update process started in screen session 'nockupdate'. Miners will NOT be restarted.${RESET}"
    fi
    echo -e "${YELLOW}>> To monitor: ${DIM}screen -r nockupdate${RESET}"
    echo -e "${CYAN}To exit the screen session without stopping the update:${RESET}"
    echo -e "${DIM}Press Ctrl+A then D${RESET}"

    echo -e "${YELLOW}Do you want to attach to the 'nockupdate' screen session now? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" ATTACH_CHOICE
      [[ "$ATTACH_CHOICE" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ "$ATTACH_CHOICE" =~ ^[Yy]$ ]]; then
      screen -r nockupdate
    fi

    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  3)
    clear
    echo -e "${YELLOW}You are about to update only the Nockchain Wallet (nockchain-wallet).${RESET}"
    echo -e "${YELLOW}Continue? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_UPDATE_WALLET
      [[ "$CONFIRM_UPDATE_WALLET" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ ! "$CONFIRM_UPDATE_WALLET" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    fi

    if screen -ls | grep -q "walletupdate"; then
      echo -e "${YELLOW}A screen session named 'walletupdate' already exists. Killing it...${RESET}"
      screen -S walletupdate -X quit
    fi

    echo -e "${CYAN}>> Launching wallet update in screen session 'walletupdate'...${RESET}"
    screen -dmS walletupdate bash -c "
      cd \$HOME/nockchain && \
      git pull && \
      make install-nockchain-wallet && \
      export PATH=\"\$HOME/.cargo/bin:\$PATH\" && \
      echo 'Wallet update complete.' && \
      exec bash
    "
    echo -e "${GREEN}✅ Wallet update started in screen session 'walletupdate'.${RESET}"
    echo -e "${YELLOW}To monitor: ${DIM}screen -r walletupdate${RESET}"
    echo -e "${CYAN}To exit screen: ${DIM}Ctrl+A then D${RESET}"

    echo -e "${YELLOW}Do you want to attach to the 'walletupdate' screen session now? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" ATTACH_WALLET
      [[ "$ATTACH_WALLET" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ "$ATTACH_WALLET" =~ ^[Yy]$ ]]; then
      screen -r walletupdate
    fi

    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  4)
    clear
    echo -e "${YELLOW}You are about to update the launcher script to the latest version from GitHub.${RESET}"
    echo -e "${YELLOW}Continue? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_LAUNCHER_UPDATE
      [[ "$CONFIRM_LAUNCHER_UPDATE" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ ! "$CONFIRM_LAUNCHER_UPDATE" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    fi

    SCRIPT_PATH="$(realpath "$0")"
    TEMP_PATH="/tmp/nockchain_launcher.sh"
    TEMP_VERSION="/tmp/NOCKCHAIN_LAUNCHER_VERSION"

    echo -e "${CYAN}>> Downloading latest launcher script...${RESET}"
    if ! curl -fsSL https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/nockchain_launcher.sh -o "$TEMP_PATH"; then
      echo -e "${RED}❌ Failed to download the launcher script.${RESET}"
      continue
    fi

    echo -e "${CYAN}>> Downloading version file...${RESET}"
    if ! curl -fsSL https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/NOCKCHAIN_LAUNCHER_VERSION -o "$TEMP_VERSION"; then
      echo -e "${RED}❌ Failed to download the version file.${RESET}"
      continue
    fi

    echo -e "${CYAN}>> Replacing launcher and version file...${RESET}"
    cp "$TEMP_PATH" "$SCRIPT_PATH"
    cp "$TEMP_VERSION" "$LAUNCHER_VERSION_FILE"
    chmod +x "$SCRIPT_PATH"

    echo -e "${GREEN}✅ Launcher updated successfully.${RESET}"
    echo -e "${YELLOW}Press any key to restart the launcher with the updated version...${RESET}"
    read -n 1 -s
    exec "$SCRIPT_PATH"
    ;;
  5)
    clear
    echo -e "${YELLOW}You are about to configure and launch one or more miners.${RESET}"
    echo -e "${YELLOW}Do you want to continue with miner setup? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_LAUNCH
      [[ "$CONFIRM_LAUNCH" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    if [[ ! "$CONFIRM_LAUNCH" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    fi
    # Phase 2: Ensure Nockchain build exists before miner setup
    if [ -f "$BINARY_PATH" ]; then
        echo -e "${GREEN}✅ Build detected. Continuing to miner setup...${RESET}"
    else
        echo -e "${RED}!! ERROR: Build not completed or failed.${RESET}"
        echo -e "${YELLOW}>> Check build log: $LOG_PATH${RESET}"
        echo -e "${YELLOW}>> Resume screen: ${DIM}screen -r nockbuild${RESET}"
        continue
    fi
    # Always write start_miner.sh to ensure consistency
    START_SCRIPT="$SCRIPT_DIR/start_miner.sh"
    EXPECTED_LAUNCHER=$(cat <<'EOS'
#!/bin/bash
DIR="$1"
MINER_NAME=$(basename "$DIR")

CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launch.cfg"
get_config_value() {
  local section="$1"
  local key="$2"
  local file="$3"
  awk -F= -v section="[$section]" -v key="$key" '
    $0 == section { in_section=1; next }
    /^\[.*\]/     { in_section=0 }
    in_section && $1 ~ key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }
  ' "$file"
}

MINING_KEY=$(get_config_value "$MINER_NAME" "MINING_KEY" "$CONFIG_FILE")
BIND_FLAG=$(get_config_value "$MINER_NAME" "BIND_FLAG" "$CONFIG_FILE")
PEER_FLAG=$(get_config_value "$MINER_NAME" "PEER_FLAG" "$CONFIG_FILE")
MAX_ESTABLISHED_FLAG=$(get_config_value "$MINER_NAME" "MAX_ESTABLISHED_FLAG" "$CONFIG_FILE")
STATE_FLAG=$(get_config_value "$MINER_NAME" "STATE_FLAG" "$CONFIG_FILE")

LOG_FILE="$DIR/$MINER_NAME.log"

CMD=(
  "$HOME/nockchain/target/release/nockchain"
  --mine
  --mining-pubkey "$MINING_KEY"
)
[[ -n "$BIND_FLAG" ]] && CMD+=($BIND_FLAG)
[[ -n "$PEER_FLAG" ]] && CMD+=($PEER_FLAG)
[[ -n "$MAX_ESTABLISHED_FLAG" ]] && CMD+=($MAX_ESTABLISHED_FLAG)
[[ -n "$STATE_FLAG" ]] && CMD+=($STATE_FLAG)

FULL_CMD="cd \"$DIR\" && \
RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info \
MINIMAL_LOG_FORMAT=true ${CMD[*]} | tee \"$LOG_FILE\""
echo "Launching miner: $FULL_CMD"
tmux new-session -d -s "$MINER_NAME" "$FULL_CMD"
EOS
)
    echo -e "${CYAN}>> Generating/updating start_miner.sh...${RESET}"
    echo "$EXPECTED_LAUNCHER" > "$START_SCRIPT"
    chmod +x "$START_SCRIPT"
    echo -e "${GREEN}✅ start_miner.sh is ready.${RESET}"

    # Prompt for use of existing config if present
    if [[ -f "$CONFIG_FILE" ]]; then
      echo ""
      echo -e "${CYAN}📋 Existing Miner Configuration Detected (launch.cfg):${RESET}"
      echo -e "${DIM}---------------------------------------${RESET}"
      cat "$CONFIG_FILE"
      echo -e "${DIM}---------------------------------------${RESET}"
      echo -e "${YELLOW}Do you want to keep this existing configuration?${RESET}"
      echo -e "${CYAN}1) Use existing launch.cfg${RESET}"
      echo -e "${CYAN}2) Discard and create new configuration${RESET}"
      while true; do
        read -rp "$(echo -e "${BOLD_BLUE}> Enter choice [1/2]: ${RESET}")" USE_EXISTING_CFG
        [[ "$USE_EXISTING_CFG" == "1" || "$USE_EXISTING_CFG" == "2" ]] && break
        echo -e "${RED}❌ Invalid input. Please enter 1 or 2.${RESET}"
      done
      if [[ "$USE_EXISTING_CFG" == "1" ]]; then
        # Automatically count number of miners in existing config
        NUM_MINERS=$(grep -c '^\[miner[0-9]\+\]' "$CONFIG_FILE")
        echo -e "${CYAN}✅ Using existing launch.cfg.${RESET}"
        echo ""
        echo -e "${YELLOW}>> Launching configured miners...${RESET}"
        for i in $(seq 1 "$NUM_MINERS"); do
          (
            MINER_DIR="$NCK_DIR/miner$i"
            mkdir -p "$MINER_DIR"
            if tmux has-session -t miner$i 2>/dev/null; then
              echo -e "${YELLOW}⚠️  Skipping miner$i: tmux session already exists.${RESET}"
              exit
            fi
            echo -e "${CYAN}>> Starting miner$i in tmux...${RESET}"
            start_miner_tmux "miner$i" "$MINER_DIR" "$MINING_KEY"
          ) &
        done
        wait
        echo ""
        if tmux has-session -t "miner1" 2>/dev/null; then
          echo -e "${GREEN}🎉 Nockchain miners launched successfully!${RESET}"
        else
          echo -e "${RED}❌ Failed to launch miners. No tmux sessions detected.${RESET}"
        fi
        echo ""
        echo -e "${CYAN}Manage your miners with the following commands:${RESET}"
        echo -e "${CYAN}- List sessions:   ${DIM}tmux ls${RESET}"
        echo -e "${CYAN}- Attach session:  ${DIM}tmux attach -t minerX${RESET}"
        echo -e "${CYAN}- Detach:          ${DIM}Ctrl + b then d${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      else
        echo -e "${YELLOW}⚠️ Discarding existing configuration...${RESET}"
        rm -f "$CONFIG_FILE"
      fi
    fi
    cd "$HOME/nockchain"
    export PATH="$PATH:$(pwd)/target/release"
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "export PATH=\"\$PATH:$(pwd)/target/release\"" >> ~/.bashrc
    # Handle wallet import or generation if keys.export is not found
    if [[ -f "keys.export" ]]; then
      echo -e "${CYAN}>> Importing wallet from keys.export...${RESET}"
      nockchain-wallet import-keys --input keys.export
    else
      echo -e "${YELLOW}No wallet (keys.export) found.${RESET}"
      echo -e "${YELLOW}Do you want to generate a new wallet now? (y/n)${RESET}"
      while true; do
        read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CREATE_WALLET
        [[ "$CREATE_WALLET" =~ ^[YyNn]$ ]] && break
        echo -e "${RED}❌ Please enter y or n.${RESET}"
      done
      if [[ ! "$CREATE_WALLET" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Returning to menu...${RESET}"
        continue
      fi
      echo -e "${CYAN}>> Generating new wallet...${RESET}"
      nockchain-wallet keygen
      echo -e "${CYAN}>> Backing up keys to 'keys.export'...${RESET}"
      echo ""
      nockchain-wallet export-keys
    fi
    # Validate or request the user's mining public key
    if grep -q "^MINING_PUBKEY=" .env; then
      MINING_KEY=$(grep "^MINING_PUBKEY=" .env | cut -d= -f2)
    else
      echo -e "${YELLOW}Enter your PUBLIC KEY to use for mining:${RESET}"
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" MINING_KEY
      if [[ -z "$MINING_KEY" ]]; then
        echo -e "${RED}!! ERROR: Public key cannot be empty.${RESET}"
        continue
      fi
      sed -i "s/^MINING_PUBKEY=.*/MINING_PUBKEY=$MINING_KEY/" .env
    fi
    # Ask user to confirm or correct the public key before launch
    while true; do
      echo -e "${YELLOW}The following mining public key will be used:${RESET}"
      echo -e "${CYAN}$MINING_KEY${RESET}"
      echo -e "${YELLOW}Is this correct? (y/n)${RESET}"
      while true; do
        read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_KEY
        [[ "$CONFIRM_KEY" =~ ^[YyNn]$ ]] && break
        echo -e "${RED}❌ Please enter y or n.${RESET}"
      done
      if [[ "$CONFIRM_KEY" =~ ^[Yy]$ ]]; then
        break
      fi
      echo -e "${YELLOW}Please enter the correct mining public key:${RESET}"
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" MINING_KEY
      sed -i "s/^MINING_PUBKEY=.*/MINING_PUBKEY=$MINING_KEY/" .env
    done
    # Configure and enable required UFW firewall rules for Nockchain
    echo -e "${CYAN}>> Configuring firewall...${RESET}"
    sudo ufw allow ssh >/dev/null 2>&1 || true
    sudo ufw allow 22 >/dev/null 2>&1 || true
    sudo ufw allow 3005/tcp >/dev/null 2>&1 || true
    sudo ufw allow 3006/tcp >/dev/null 2>&1 || true
    sudo ufw allow 3005/udp >/dev/null 2>&1 || true
    sudo ufw allow 3006/udp >/dev/null 2>&1 || true
    sudo ufw --force enable >/dev/null 2>&1 || echo -e "${YELLOW}Warning: Failed to enable UFW. Continuing script execution.${RESET}"
    echo -e "${GREEN}✅ Firewall configured.${RESET}"
    # Collect system specs and calculate optimal number of miners
    CPU_CORES=$(nproc)
    TOTAL_MEM=$(free -g | awk '/^Mem:/ {print $2}')
    echo ""
    echo -e "${CYAN}📈 Miner Recommendation:${RESET}"
    echo -e "${CYAN}Recommended: 1 miner per 2 vCPUs and 8GB RAM${RESET}"
    RECOMMENDED_MINERS=$(( CPU_CORES / 2 < TOTAL_MEM / 8 ? CPU_CORES / 2 : TOTAL_MEM / 8 ))
    echo -e "${YELLOW}For this system, max recommended miners: ${RESET}${CYAN}$RECOMMENDED_MINERS${RESET}"
    echo ""
    while true; do
      echo -e "${YELLOW}How many miners do you want to run? (Enter a number like 1, 3, 10...) or 'n' to cancel:${RESET}"
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" NUM_MINERS
      NUM_MINERS=$(echo "$NUM_MINERS" | tr -d '[:space:]')
      if [[ "$NUM_MINERS" =~ ^[Nn]$ ]]; then
        echo -e "${CYAN}Returning to menu...${RESET}"
        break
      elif [[ "$NUM_MINERS" =~ ^[0-9]+$ && "$NUM_MINERS" -ge 1 ]]; then
        # Prompt for max connections per miner
        echo ""
        echo -e "${YELLOW}Do you want to set a maximum number of connections per miner?${RESET}"
        echo -e "${DIM}Hint: 32 is often a safe value. Leave empty to skip this option.${RESET}"
        read -rp "$(echo -e "${BOLD_BLUE}> Enter value (e.g., 32) or leave blank: ${RESET}")" MAX_ESTABLISHED
        echo ""
        # Prompt for peer mode
        echo ""
        echo -e "${YELLOW}Select peer mode for these miners:${RESET}"
        echo -e "${CYAN}1) No peers (isolated)${RESET}"
        echo -e "${CYAN}2) Central node (all miners peer with miner1 only)${RESET}"
        echo -e "${CYAN}3) Full mesh (all miners peer with each other)${RESET}"
        echo -e "${CYAN}4) Custom peers (manual entry per miner)${RESET}"
        while true; do
          read -rp "$(echo -e "${BOLD_BLUE}> Enter peer mode [1-4]: ${RESET}")" PEER_MODE
          if [[ "$PEER_MODE" =~ ^[1-4]$ ]]; then
            break
          else
            echo -e "${RED}❌ Invalid input. Enter 1, 2, 3, or 4.${RESET}"
          fi
        done
        # Prompt for BASE_PORT if needed
        if [[ "$PEER_MODE" == "2" || "$PEER_MODE" == "3" ]]; then
          echo -e "${YELLOW}Enter a base UDP port for miner communication (default: 40000):${RESET}"
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" BASE_PORT_INPUT
          BASE_PORT_INPUT=$(echo "$BASE_PORT_INPUT" | tr -d '[:space:]')
          if [[ -z "$BASE_PORT_INPUT" ]]; then
            BASE_PORT=40000
          elif ! [[ "$BASE_PORT_INPUT" =~ ^[0-9]+$ ]] || (( BASE_PORT_INPUT < 1024 || BASE_PORT_INPUT > 65000 )); then
            echo -e "${RED}❌ Invalid port. Using default 40000.${RESET}"
            BASE_PORT=40000
          else
            BASE_PORT=$BASE_PORT_INPUT
          fi
        else
          BASE_PORT=""
        fi
        declare -A CUSTOM_PEERS_MAP
        if [[ "$PEER_MODE" == "4" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            MINER_NAME="miner$i"
            declare -a UNIQUE_PEERS=()
            while true; do
              echo -e "${YELLOW}Enter custom peer string(s) for ${CYAN}$MINER_NAME${YELLOW}, space-separated. Press Enter to finish:${RESET}"
              read -rp "> " CUSTOM_PEERS

              valid=()
              invalid=()

              for peer in $CUSTOM_PEERS; do
                if [[ "$peer" =~ ^--peer\ /ip4/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/udp/[0-9]+/quic-v1$ ]]; then
                  duplicate=0
                  for up in "${UNIQUE_PEERS[@]}"; do
                    [[ "$peer" == "$up" ]] && duplicate=1 && break
                  done
                  if [[ $duplicate -eq 0 ]]; then
                    valid+=("$peer")
                    UNIQUE_PEERS+=("$peer")
                  fi
                else
                  invalid+=("$peer")
                fi
              done

              echo ""
              echo -e "${GREEN}✅ Accepted peers:${RESET}"
              for p in "${UNIQUE_PEERS[@]}"; do
                echo "  $p"
              done

              if [[ ${#invalid[@]} -gt 0 ]]; then
                echo ""
                echo -e "${RED}❌ Invalid format skipped:${RESET}"
                for p in "${invalid[@]}"; do
                  echo "  $p"
                done
              fi

              echo ""
              echo -e "${YELLOW}Press Enter to confirm this list, or type more peers:${RESET}"
              read -rp "> " CONTINUE_INPUT
              [[ -z "$CONTINUE_INPUT" ]] && break
            done

            if [[ ${#UNIQUE_PEERS[@]} -eq 0 ]]; then
              CUSTOM_PEERS_MAP["$MINER_NAME"]=""
            else
              CUSTOM_PEERS_MAP["$MINER_NAME"]="${UNIQUE_PEERS[*]}"
            fi
          done
        fi
        # Create launch.cfg before preview so it can be shown to the user
        LAUNCH_CFG="$SCRIPT_DIR/launch.cfg"
        # Compute PEER_FLAGs for all miners
        declare -A PEER_FLAG_MAP
        if [[ "$PEER_MODE" == "1" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            PEER_FLAG_MAP["miner$i"]=""
          done
        elif [[ "$PEER_MODE" == "2" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            if [[ "$i" == "1" ]]; then
              PEER_FLAG_MAP["miner$i"]=""
            else
              PEER_FLAG_MAP["miner$i"]="--peer /ip4/127.0.0.1/udp/$((BASE_PORT + 1))/quic-v1"
            fi
          done
        elif [[ "$PEER_MODE" == "3" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            peers=()
            for j in $(seq 1 "$NUM_MINERS"); do
              [[ "$j" == "$i" ]] && continue
              peers+=("--peer /ip4/127.0.0.1/udp/$((BASE_PORT + j))/quic-v1")
            done
            PEER_FLAG_MAP["miner$i"]="${peers[*]}"
          done
        elif [[ "$PEER_MODE" == "4" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            MINER_NAME="miner$i"
            PEER_FLAG_MAP["$MINER_NAME"]="${CUSTOM_PEERS_MAP[$MINER_NAME]}"
          done
        fi
        # Compute BIND_FLAGs for all miners, similar to PEER_FLAG_MAP logic
        declare -A BIND_FLAG_MAP
        if [[ "$PEER_MODE" == "2" || "$PEER_MODE" == "3" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            BIND_FLAG_MAP["miner$i"]="--bind /ip4/0.0.0.0/udp/$((BASE_PORT + i))/quic-v1"
          done
        fi
        # Compute MAX_ESTABLISHED_FLAG for all miners
        declare -A MAX_ESTABLISHED_FLAG_MAP
        for i in $(seq 1 "$NUM_MINERS"); do
          MINER_NAME="miner$i"
          if [[ -n "$MAX_ESTABLISHED" ]]; then
            MAX_ESTABLISHED_FLAG_MAP["$MINER_NAME"]="--max-established $MAX_ESTABLISHED"
          else
            MAX_ESTABLISHED_FLAG_MAP["$MINER_NAME"]=""
          fi
        done
        {
          # Write BASE_PORT if set
          [[ -n "$BASE_PORT" ]] && echo "BASE_PORT=$BASE_PORT"
          for i in $(seq 1 "$NUM_MINERS"); do
            MINER_NAME="miner$i"
            echo ""
            echo "[$MINER_NAME]"
            echo "MINING_KEY=$MINING_KEY"
            echo "BIND_FLAG=${BIND_FLAG_MAP[$MINER_NAME]:-}"
            echo "PEER_FLAG=${PEER_FLAG_MAP[$MINER_NAME]:-}"
            echo "MAX_ESTABLISHED_FLAG=${MAX_ESTABLISHED_FLAG_MAP[$MINER_NAME]:-}"
            echo "STATE_FLAG=--state-jam ../state.jam"
          done
        } > "$CONFIG_FILE"
        echo ""
        # Show the miners to be launched
        # Updated: Grouped, clearer miner command preview
        echo -e "${CYAN}📋 You are about to launch the following miners and their commands:${RESET}"
        echo ""
        if [[ -f "$LAUNCH_CFG" ]]; then
          for i in $(seq 1 "$NUM_MINERS"); do
            MINER_NAME="miner$i"
            DIR="$HOME/nockchain/$MINER_NAME"
            # Use the globally confirmed mining key since it's already known
            MINING_KEY="$MINING_KEY"
            BIND_FLAG=$(awk -v section="[$MINER_NAME]" '
              $0 == section {found=1; next}
              /^\[.*\]/ {found=0}
              found && /^BIND_FLAG=/ {
                sub(/^BIND_FLAG=/, "")
                print
                exit
              }
            ' "$LAUNCH_CFG")
            PEER_FLAG=$(awk -v section="[$MINER_NAME]" '
              $0 == section {found=1; next}
              /^\[.*\]/ {found=0}
              found && /^PEER_FLAG=/ {
                sub(/^PEER_FLAG=/, "")
                print
                exit
              }
            ' "$LAUNCH_CFG")
            MAX_ESTABLISHED_FLAG=$(awk -v section="[$MINER_NAME]" '
              $0 == section {found=1; next}
              /^\[.*\]/ {found=0}
              found && /^MAX_ESTABLISHED_FLAG=/ {
                sub(/^MAX_ESTABLISHED_FLAG=/, "")
                print
                exit
              }
            ' "$LAUNCH_CFG")
            STATE_FLAG=$(awk -v section="[$MINER_NAME]" '
              $0 == section {found=1; next}
              /^\[.*\]/ {found=0}
              found && /^STATE_FLAG=/ {
                sub(/^STATE_FLAG=/, "")
                print
                exit
              }
            ' "$LAUNCH_CFG")
            echo -e "${BOLD_BLUE}$MINER_NAME${RESET}"
            echo -e "${DIM}> tmux new-session -d -s $MINER_NAME \"cd $DIR && RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info MINIMAL_LOG_FORMAT=true \$HOME/nockchain/target/release/nockchain --mine --mining-pubkey $MINING_KEY $BIND_FLAG $PEER_FLAG $MAX_ESTABLISHED_FLAG $STATE_FLAG | tee $DIR/$MINER_NAME.log\"${RESET}"
            echo ""
          done
        else
          echo -e "${RED}❌ Configuration file not found.${RESET}"
        fi
        echo -e "${YELLOW}Proceed? (y/n)${RESET}"
        while true; do
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_LAUNCH
          [[ "$CONFIRM_LAUNCH" =~ ^[YyNn]$ ]] && break
          echo -e "${RED}❌ Please enter y or n.${RESET}"
        done
        if [[ ! "$CONFIRM_LAUNCH" =~ ^[Yy]$ ]]; then
          echo -e "${CYAN}Returning to miner count selection...${RESET}"
          continue
        fi
        echo -e "${GREEN}Created launch.cfg at $CONFIG_FILE${RESET}"
        echo ""
        echo -e "${YELLOW}All miner configuration is now managed by $SCRIPT_DIR/launch.cfg.${RESET}"
        echo -e "${CYAN}To adjust peer mode, use_state, or custom peers, edit $SCRIPT_DIR/launch.cfg.${RESET}"
        for i in $(seq 1 "$NUM_MINERS"); do
          (
            MINER_DIR="$NCK_DIR/miner$i"
            mkdir -p "$MINER_DIR"
            if tmux has-session -t miner$i 2>/dev/null; then
              echo -e "${YELLOW}⚠️  Skipping miner$i: tmux session already exists.${RESET}"
              exit
            fi
            echo -e "${CYAN}>> Starting miner$i in tmux...${RESET}"
            start_miner_tmux "miner$i" "$MINER_DIR" "$MINING_KEY"
          ) &
        done
        wait
        echo ""
        if tmux has-session -t "miner1" 2>/dev/null; then
          echo -e "${GREEN}🎉 Nockchain miners launched successfully!${RESET}"
        else
          echo -e "${RED}❌ Failed to launch miners. No tmux sessions detected.${RESET}"
        fi
        # Display post-launch instructions and tmux management tips
        echo ""
        echo -e "${CYAN}Manage your miners with the following commands:${RESET}"
        echo -e "${CYAN}- List sessions:   ${DIM}tmux ls${RESET}"
        echo -e "${CYAN}- Attach session:  ${DIM}tmux attach -t minerX${RESET}"
        echo -e "${CYAN}- Detach:          ${DIM}Ctrl + b then d${RESET}"
        echo ""
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        break
      else
        echo -e "${RED}❌ Invalid input. Please enter a positive number (e.g. 1, 3) or 'n' to cancel.${RESET}"
      fi
    done
    continue
    ;;
  6)
    clear
    all_miners=()
    for d in "$HOME/nockchain"/miner*; do
      [ -d "$d" ] || continue
      session=$(basename "$d")
      if tmux has-session -t "$session" 2>/dev/null; then
        all_miners+=("🟢 $session")
      else
        all_miners+=("❌ $session")
      fi
    done
    # Sort numerically by miner number, keep icons
    IFS=$'\n' sorted_miners=($(printf "%s\n" "${all_miners[@]}" | sort -k2 -V))
    unset IFS
    if ! command -v fzf &> /dev/null; then
      echo -e "${YELLOW}fzf not found. Installing fzf...${RESET}"
      sudo apt-get update && sudo apt-get install -y fzf
      echo -e "${GREEN}fzf installed successfully.${RESET}"
    fi
    menu=$(printf "%s\n" "↩️  Cancel and return to menu" "🔁 Restart all miners" "${sorted_miners[@]}")
    selected=$(echo "$menu" | fzf --multi --bind "space:toggle" --prompt="Select miners to restart: " --header=$'\n\nUse SPACE to select miners.\nENTER will restart (or start) selected miners.\n\n')
    if [[ -z "$selected" || "$selected" == *"Cancel and return to menu"* ]]; then
      echo -e "${YELLOW}No selection made. Returning to menu...${RESET}"
      continue
    fi
    if echo "$selected" | grep -q "Restart all miners"; then
      TARGET_SESSIONS=$(printf "%s\n" "${sorted_miners[@]}" | sed 's/^[^ ]* //')
    else
      TARGET_SESSIONS=$(echo "$selected" | grep -v "Restart all miners" | grep -v "Cancel and return to menu" | sed 's/^[^ ]* //')
    fi
    echo -e "${YELLOW}You selected:${RESET}"
    for session in $TARGET_SESSIONS; do
      echo -e "${CYAN}- $session${RESET}"
    done
    echo -e "${YELLOW}Are you sure you want to restart these? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_RESTART
      [[ "$CONFIRM_RESTART" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    [[ ! "$CONFIRM_RESTART" =~ ^[Yy]$ ]] && echo -e "${CYAN}Returning to menu...${RESET}" && continue
    for session in $TARGET_SESSIONS; do
      echo -e "${CYAN}Restarting $session...${RESET}"
      tmux kill-session -t "$session" 2>/dev/null || true
      miner_num=$(echo "$session" | grep -o '[0-9]\+')
      miner_dir="$HOME/nockchain/miner$miner_num"
      mkdir -p "$miner_dir"
      start_miner_tmux "$session" "$miner_dir" "$MINING_KEY"
    done
    echo -e "${GREEN}✅ Selected miners have been restarted.${RESET}"
    echo -e "${CYAN}To attach to a tmux session: ${DIM}tmux attach -t minerX${RESET}"
    echo -e "${CYAN}To detach from tmux: ${DIM}Ctrl + b then d${RESET}"
    echo -e "${CYAN}To list tmux sessions: ${DIM}tmux ls${RESET}"
    echo -e "${GREEN}✅ Current running miners:${RESET}"
    tmux ls | grep '^miner' | cut -d: -f1 | sort -V
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  7)
    clear
    all_miners=()
    for d in "$HOME/nockchain"/miner*; do
      [ -d "$d" ] || continue
      session=$(basename "$d")
      if tmux has-session -t "$session" 2>/dev/null; then
        all_miners+=("🟢 $session")
      else
        all_miners+=("❌ $session")
      fi
    done
    IFS=$'\n' sorted_miners=($(printf "%s\n" "${all_miners[@]}" | sort -k2 -V))
    unset IFS
    if ! command -v fzf &> /dev/null; then
      echo -e "${YELLOW}fzf not found. Installing fzf...${RESET}"
      sudo apt-get update && sudo apt-get install -y fzf
      echo -e "${GREEN}fzf installed successfully.${RESET}"
    fi
    running_miners=()
    for entry in "${sorted_miners[@]}"; do
      [[ "$entry" =~ ^🟢 ]] && running_miners+=("$entry")
    done
    menu=$(printf "%s\n" "↩️  Cancel and return to menu" "🛑 Stop all running miners" "${running_miners[@]}")
    selected=$(echo "$menu" | fzf --multi --bind "space:toggle" --prompt="Select miners to stop: " --header=$'\n\nUse SPACE to select miners.\nENTER will stop selected miners.\n\n')
    if [[ -z "$selected" || "$selected" == *"Cancel and return to menu"* ]]; then
      echo -e "${YELLOW}No selection made. Returning to menu...${RESET}"
      continue
    fi
    if echo "$selected" | grep -q "Stop all"; then
      TARGET_SESSIONS=$(printf "%s\n" "${sorted_miners[@]}" | grep '^🟢' | sed 's/^[^ ]* //')
    else
      TARGET_SESSIONS=$(echo "$selected" | grep '^🟢' | sed 's/^[^ ]* //')
    fi
    echo -e "${YELLOW}You selected:${RESET}"
    for session in $TARGET_SESSIONS; do
      echo -e "${CYAN}- $session${RESET}"
    done
    echo -e "${YELLOW}Are you sure you want to stop these? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_STOP
      [[ "$CONFIRM_STOP" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    [[ ! "$CONFIRM_STOP" =~ ^[Yy]$ ]] && echo -e "${CYAN}Returning to menu...${RESET}" && continue
    for session in $TARGET_SESSIONS; do
      echo -e "${CYAN}Stopping $session...${RESET}"
      tmux kill-session -t "$session"
    done
    echo -e "${GREEN}✅ Selected miners have been stopped.${RESET}"
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  8)
    clear
    while true; do
      # Extract network height from all miner logs (live, every refresh)
      NETWORK_HEIGHT="--"
      all_blocks=()
      for miner_dir in "$HOME/nockchain"/miner*; do
        [[ -d "$miner_dir" ]] || continue
        log_file="$miner_dir/$(basename "$miner_dir").log"
        if [[ -f "$log_file" ]]; then
          height=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K[0-9]+\.[0-9]+' | sort -V | tail -n 1)
          [[ -n "$height" ]] && all_blocks+=("$height")
        fi
      done
      if [[ ${#all_blocks[@]} -gt 0 ]]; then
        NETWORK_HEIGHT=$(printf "%s\n" "${all_blocks[@]}" | sort -V | tail -n 1)
      fi
      tput cup 0 0
      echo -e "${DIM}🖥️  Live Miner Monitor ${RESET}"
      echo ""
      echo -e "${DIM}Legend:${RESET} ${YELLOW}🟡 <5m${RESET} | ${CYAN}🔵 <30m${RESET} | ${GREEN}🟢 Stable >30m${RESET} | ${DIM}${RED}❌ Inactive${RESET}"
      echo ""
      echo -e "${CYAN}📡 Network height: ${RESET}$NETWORK_HEIGHT"
      echo ""
      printf "   | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-10s | %-5s\n" "Miner" "Uptime" "CPU (%)" "MEM (%)" "Block" "Lag" "Status" "Peers"

      all_miners=()
      for miner_dir in "$HOME/nockchain"/miner*; do
        [ -d "$miner_dir" ] || continue
        all_miners+=("$(basename "$miner_dir")")
      done
      IFS=$'\n' sorted_miners=($(printf "%s\n" "${all_miners[@]}" | sort -V))
      unset IFS
      if [[ ${#sorted_miners[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No miners found or unable to read data.${RESET}"
        echo -e "${YELLOW}Press Enter to return to menu...${RESET}"
        read
        break
      fi

      for session in "${sorted_miners[@]}"; do
        miner_dir="$HOME/nockchain/$session"
        log_file="$miner_dir/$session.log"

        if tmux has-session -t "$session" 2>/dev/null; then
          pane_pid=$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null)
          miner_pid=$(pgrep -P "$pane_pid" -f nockchain | head -n 1)

          readable="--"
          if [[ -n "$miner_pid" && -r "/proc/$miner_pid/stat" ]]; then
            proc_start_ticks=$(awk '{print $22}' /proc/$miner_pid/stat)
            clk_tck=$(getconf CLK_TCK)
            boot_time=$(awk '/btime/ {print $2}' /proc/stat)
            start_time=$((boot_time + proc_start_ticks / clk_tck))
            now=$(date +%s)
            uptime_secs=$((now - start_time))
            hours=$((uptime_secs / 3600))
            minutes=$(((uptime_secs % 3600) / 60))
            readable="${minutes}m"
            (( hours > 0 )) && readable="${hours}h ${minutes}m"
          fi

          if [[ "$readable" =~ ^([0-9]+)m$ ]]; then
            diff=${BASH_REMATCH[1]}
            if (( diff < 5 )); then
              color="${YELLOW}🟡"
            elif (( diff < 30 )); then
              color="${CYAN}🔵"
            else
              color="${GREEN}🟢"
            fi
          elif [[ "$readable" =~ ^([0-9]+)h ]]; then
            color="${GREEN}🟢"
          else
            color="${YELLOW}🟡"
          fi

          if [[ -n "$miner_pid" ]]; then
            cpu_mem=$(ps -p "$miner_pid" -o %cpu,%mem --no-headers)
            cpu=$(echo "$cpu_mem" | awk '{print $1}')
            mem=$(echo "$cpu_mem" | awk '{print $2}')
          else
            cpu="?"
            mem="?"
          fi

          if [[ -f "$log_file" ]]; then
            latest_block=$(grep -a 'added to validated blocks at' "$log_file" 2>/dev/null | tail -n 1 | grep -oP 'at\s+\K[0-9]+\.[0-9]+' || echo "--")
          else
            latest_block="--"
          fi

          # Peer count from tmux buffer
          peer_count=$(tmux capture-pane -p -t "$session" | grep 'connected_peers=' | tail -n 1 | grep -o 'connected_peers=[0-9]\+' | cut -d= -f2)
          [[ -z "$peer_count" ]] && peer_count="--"

          # Lag logic
          if [[ "$latest_block" =~ ^[0-9]+\.[0-9]+$ && "$NETWORK_HEIGHT" =~ ^[0-9]+\.[0-9]+$ ]]; then
            miner_block=$(echo "$latest_block" | awk -F. '{print ($1 * 1000 + $2)}')
            network_block=$(echo "$NETWORK_HEIGHT" | awk -F. '{print ($1 * 1000 + $2)}')
            lag_int=$((network_block - miner_block))
            (( lag_int < 0 )) && lag_int=0
            lag="$lag_int"
          else
            lag="--"
            lag_int=0
          fi

          if [[ "$lag" =~ ^[0-9]+$ && "$lag_int" -eq 0 ]]; then
            lag_status="⛏️ mining "
            lag_color="${GREEN}"
          else
            lag_status="⏳ syncing"
            lag_color="${YELLOW}"
          fi

          printf "%b | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-10b | %-5s\n" "$color" "$session" "$readable" "$cpu%" "$mem%" "$latest_block" "$lag" "$(echo -e "$lag_color$lag_status$RESET")" "$peer_count"
        else
          # Show default values for inactive/broken miners
          printf "${DIM}❌ | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-10s | %-5s${RESET}\n" "$session" "--" "--" "--" "--" "--" "inactive" "--"
        fi
      done

      echo ""
      echo -e "${DIM}Refreshing every 2s — press ${BOLD_BLUE}Enter${DIM} to exit.${RESET}"
      key=""
      if read -t 2 -s -r key 2>/dev/null; then
        [[ "$key" == "" ]] && break  # Enter pressed
      fi
    done
    continue
    ;;
  9)
    clear
    if ! command -v htop &> /dev/null; then
      echo -e "${YELLOW}htop is not installed. Installing now...${RESET}"
      sudo apt-get update && sudo apt-get install -y htop
    fi
    htop
    continue
    ;;
  *)
    echo -e "${RED}Invalid option selected. Returning to menu...${RESET}"
    sleep 1
    continue
    ;;
esac

done
