#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD_BLUE="\e[1;34m"
DIM="\e[2m"
RESET="\e[0m"

set -euo pipefail
trap 'exit_code=$?; [[ $exit_code -eq 130 ]] && exit 130; [[ $exit_code -ne 0 ]] && echo -e "${RED}(FATAL ERROR) Script exited unexpectedly with code $exit_code on line $LINENO.${RESET}"; caller 0' ERR



# Systemd service generator for miners
generate_systemd_service() {
  local miner_id=$1
  local miner_dir="$HOME/nockchain/miner$miner_id"
  local service_name="nockchain-miner$miner_id"
  local service_file="/etc/systemd/system/${service_name}.service"
  # Extract MINER_KEY for this miner from config before writing the unit file
  MINER_KEY=$(awk -v section="[miner$miner_id]" '
    $0 == section {found=1; next}
    /^\[.*\]/ {found=0}
    found && /^MINING_KEY=/ {
      sub(/^MINING_KEY=/, "")
      print
      exit
    }
  ' "$CONFIG_FILE")
  local abs_dir="$HOME/nockchain/miner$miner_id"
  local abs_script="$(realpath "$SCRIPT_DIR/run_miner.sh")"
  local actual_user
  actual_user=$(whoami)
  sudo bash -c "cat > '$service_file'" <<EOF
[Unit]
Description=nockchain-miner$miner_id
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
StartLimitIntervalSec=0
WorkingDirectory=$abs_dir
User=root
Environment="MINING_KEY=$MINER_KEY"
Environment="RUST_LOG=info"
MemoryMax=20G
MemorySwapMax=5G
ExecStart=/bin/bash $abs_script $miner_id

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
}

start_miner_service() {
  local miner_id=$1
  echo -e ""
  echo -e "${CYAN}🔧 Launching miner$miner_id via systemd...${RESET}"

  if systemctl is-active --quiet nockchain-miner$miner_id; then
    echo -e "${CYAN}🔄 miner$miner_id is already running. Skipping start.${RESET}"
    return
  fi

  sudo systemctl start nockchain-miner$miner_id
  if systemctl is-active --quiet nockchain-miner$miner_id; then
    echo -e "${GREEN}  ✅ miner$miner_id is now running.${RESET}"
  else
    echo -e "${RED}  ❌ Failed to launch miner$miner_id.${RESET}"
  fi
  if ! systemctl is-active --quiet nockchain-miner$miner_id; then
    echo -e "${RED}    ❌ miner$miner_id failed to start. Check logs:${RESET}"
    echo -e "${CYAN}      journalctl -u nockchain-miner$miner_id -e${RESET}"
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
REMOTE_VERSION=$(curl -fsSL https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/NOCKCHAIN_LAUNCHER_VERSION 2>/dev/null | tr -d '[:space:]')
REMOTE_VERSION=${REMOTE_VERSION:-"(offline)"}

#
# Begin main launcher loop that displays the menu and handles user input
# Check for interactive terminal (TTY) before entering the loop
if [[ ! -t 0 ]]; then
  echo -e "${RED}❌ ERROR: Script must be run in an interactive terminal (TTY). Exiting.${RESET}"
  exit 1
fi
while true; do
clear

echo -e "${RED}"
cat <<'EOF'
    _   _            _        _           _
   | \ | | ___   ___| | _____| |__   __ _(_)_ __
   |  \| |/ _ \ / __| |/ / __| '_ \ / _` | | '_ \
   | |\  | (_) | (__|   < (__| | | | (_| | | | | |
   |_| \_|\___/ \___|_|\_\___|_| |_|\__,_|_|_| |_|
EOF
echo -e "${RESET}"

echo -e "${YELLOW}:: Powered by Jobless ::${RESET}"

# Display launcher ASCII art, branding, and welcome text
echo -e "${DIM}Welcome to the Nockchain Node Manager.${RESET}"

# Extract network height from all miner logs (for dashboard)
NETWORK_HEIGHT="--"
all_blocks=()
for miner_dir in "$HOME/nockchain"/miner*; do
  [[ -d "$miner_dir" ]] || continue
  log_file="$miner_dir/$(basename "$miner_dir").log"
  if [[ -f "$log_file" && -r "$log_file" ]]; then
    heard_block=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K[0-9]+\.[0-9]+' || true)
    validated_block=$(grep -a 'added to validated blocks at' "$log_file" | tail -n 5 | grep -oP 'at\s+\K[0-9]+\.[0-9]+' || true)
    combined=$(printf "%s\n%s\n" "$heard_block" "$validated_block" | sort -V | tail -n 1)
    [[ -n "$combined" ]] && all_blocks+=("$combined")
  fi
done
if [[ ${#all_blocks[@]} -gt 0 ]]; then
  NETWORK_HEIGHT=$(printf "%s\n" "${all_blocks[@]}" | sort -V | tail -n 1)
fi

echo -e "${DIM}Install, configure, and monitor multiple Nockchain miners with ease.${RESET}"
echo ""

RUNNING_MINERS=0
for i in $(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" 2>/dev/null | sed 's/.*miner//;s/[^0-9]//g' | sort -n); do
  if systemctl is-active --quiet nockchain-miner$i 2>/dev/null; then
    ((RUNNING_MINERS=RUNNING_MINERS+1))
  fi
done
if [[ -d "$HOME/nockchain" ]]; then
  MINER_FOLDERS=$(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" 2>/dev/null | wc -l)
else
  MINER_FOLDERS=0
fi

if (( RUNNING_MINERS > 0 )); then
  echo -e "${GREEN}🟢 $RUNNING_MINERS active miners${RESET} ${DIM}($MINER_FOLDERS total miners)${RESET}"
else
  echo -e "${RED}🔴 No miners running${RESET} ${DIM}($MINER_FOLDERS total miners)${RESET}"
fi

# Show hourly backup service status
if systemctl is-active --quiet nockchain-statejam-backup.timer; then
  echo -e "${GREEN}🟢 Hourly state.jam backup is ACTIVE.${RESET}"
else
  echo -e "${RED}🔴 Hourly state.jam backup is NOT active.${RESET}"
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
# (Hourly backup service status now shown above with miner status)

echo -e "\e[31m::════════════════════════════════════════════════════════\e[0m"
echo ""

# Two-column layout for Setup and System Utilities
printf "${CYAN}%-40s%-40s${RESET}\n" "Setup:" "System Utilities:"
printf "${BOLD_BLUE}%-40s%-40s${RESET}\n" \
  "1) Install Nockchain from scratch"     "21) Run system diagnostics" \
  "2) Update nockchain to latest version" "22) Monitor resource usage (htop)" \
  "3) Update nockchain-wallet only"       "" \
  "4) Update launcher script"             "" \
  "5) Export or download state.jam file"  "" \
  "6) Hourly state.jam backup service"      ""

# Full-width layout for Miner Operations
echo -e ""
echo -e "${CYAN}Miner Operations:${RESET}"
echo -e "${BOLD_BLUE}11) Monitor miner status (live view)${RESET}"
echo -e "${BOLD_BLUE}12) Stream miner logs (tail -f)${RESET}"
echo -e "${BOLD_BLUE}13) Launch miner(s)${RESET}"
echo -e "${BOLD_BLUE}14) Restart miner(s)${RESET}"
echo -e "${BOLD_BLUE}15) Stop miner(s)${RESET}"

echo -e ""
echo -ne "${BOLD_BLUE}Select an option from the menu above (or press Enter to exit): ${RESET}"
echo -e ""
echo -e "${DIM}Tip: Use ${BOLD_BLUE}systemctl status nockchain-minerX${DIM} to check miner status, and ${BOLD_BLUE}tail -f ~/nockchain/minerX/minerX.log{DIM} to view logs. Use ${BOLD_BLUE}sudo systemctl stop nockchain-minerX${DIM} to stop a miner.${RESET}"
read USER_CHOICE

# Define important paths for binaries and logs
BINARY_PATH="$HOME/nockchain/target/release/nockchain"
LOG_PATH="$HOME/nockchain/build.log"

if [[ -z "$USER_CHOICE" ]]; then
  echo -e "${CYAN}Exiting launcher. Goodbye!${RESET}"
  exit 0
fi

case "$USER_CHOICE" in
  6)
    clear
    # Toggle systemd timer for periodic state.jam backup
    BACKUP_SERVICE_FILE="/etc/systemd/system/nockchain-statejam-backup.service"
    BACKUP_TIMER_FILE="/etc/systemd/system/nockchain-statejam-backup.timer"
    BACKUP_SCRIPT="$HOME/nockchain/export_latest_state_jam.sh"

    echo -e "${CYAN}🔄 Checking status of periodic state.jam backup service...${RESET}"
    if systemctl is-active --quiet nockchain-statejam-backup.service; then
      echo -e "${GREEN}🟢 statejam backup service is running.${RESET}"
    else
      echo -e "${RED}🔴 statejam backup service is not running.${RESET}"
      echo -e "${DIM}The timer is enabled but the service has not executed yet or is between runs.${RESET}"
    fi
    if systemctl is-enabled --quiet nockchain-statejam-backup.timer 2>/dev/null; then
      echo -e "${GREEN}✅ Periodic backup is currently ENABLED.${RESET}"
      echo -e "${DIM}To check timer status: systemctl list-timers --all | grep nockchain-statejam-backup${RESET}"
      echo -e "${DIM}To check recent logs: journalctl -u nockchain-statejam-backup.service --since \"2 hours ago\"${RESET}"
      echo ""
      echo -e "${YELLOW}Do you want to disable it? (y/n)${RESET}"
      while true; do
        read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" DISABLE_BACKUP
        [[ "$DISABLE_BACKUP" =~ ^[YyNn]$ ]] && break
        echo -e "${RED}❌ Please enter y or n.${RESET}"
      done
      if [[ "$DISABLE_BACKUP" =~ ^[Yy]$ ]]; then
        sudo systemctl stop nockchain-statejam-backup.timer
        sudo systemctl disable nockchain-statejam-backup.timer
        echo -e "${GREEN}✅ Periodic state.jam backup DISABLED.${RESET}"
      else
        echo -e "${CYAN}Backup service remains enabled.${RESET}"
      fi
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    else
      echo -e "${RED}❌ Periodic backup is currently DISABLED.${RESET}"
      echo -e "${YELLOW}Do you want to enable it? (y/n)${RESET}"
      while true; do
        read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" ENABLE_BACKUP
        [[ "$ENABLE_BACKUP" =~ ^[YyNn]$ ]] && break
        echo -e "${RED}❌ Please enter y or n.${RESET}"
      done
      if [[ ! "$ENABLE_BACKUP" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Backup service remains disabled.${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      fi
      # Write export_latest_state_jam.sh with improved logic (Option 5 style)
      if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        cat > "$BACKUP_SCRIPT" <<'EOS'
#!/bin/bash
# export_latest_state_jam.sh
# Finds the miner with the highest block and safely exports a fresh state.jam
set -euo pipefail

SRC=""
HIGHEST=0
HIGHEST_BLOCK=""

for d in "$HOME/nockchain"/miner*; do
  [[ -d "$d" ]] || continue
  log="$d/$(basename "$d").log"
  if [[ -f "$log" ]]; then
    blk=$(grep -a 'added to validated blocks at' "$log" 2>/dev/null | tail -n 1 | grep -oP 'at\s+\K[0-9]+\.[0-9]+')
    if [[ "$blk" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
      num=$((10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]}))
      if (( num > HIGHEST )); then
        HIGHEST=$num
        HIGHEST_BLOCK=$blk
        SRC="$d"
      fi
    fi
  fi
done

if [[ -z "$SRC" ]]; then
  echo "[$(date)] ❌ No suitable miner folder found." >> "$HOME/nockchain/statejam_backup.log"
  exit 1
fi

TMP="$HOME/nockchain/miner-export"
OUT="$HOME/nockchain/state.jam"
rm -rf "$TMP"
cp -a "$SRC" "$TMP"

cd "$TMP"
"$HOME/nockchain/target/release/nockchain" --export-state-jam "$OUT" >> "$HOME/nockchain/statejam_backup.log" 2>&1
cd "$HOME/nockchain"
rm -rf "$TMP"

echo "[$(date)] ✅ Exported fresh state.jam from block $HIGHEST_BLOCK to $OUT" >> "$HOME/nockchain/statejam_backup.log"
EOS
        chmod +x "$BACKUP_SCRIPT"
      fi
      # Write systemd service file
      sudo bash -c "cat > '$BACKUP_SERVICE_FILE'" <<EOS
[Unit]
Description=Export latest state.jam from all miners to ~/nockchain/state.jam
After=network-online.target

[Service]
Type=oneshot
User=$USER
ExecStart=$BACKUP_SCRIPT
EOS
      # Write systemd timer file
      sudo bash -c "cat > '$BACKUP_TIMER_FILE'" <<EOS
[Unit]
Description=Run state.jam export every hour

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOS
      sudo systemctl daemon-reload
      sudo systemctl enable --now nockchain-statejam-backup.timer
      echo -e "${GREEN}✅ Periodic state.jam backup ENABLED (every hour).${RESET}"
      echo -e "${CYAN}Backup script: ${DIM}$BACKUP_SCRIPT${RESET}"
      echo -e "${CYAN}Backup location: ${DIM}~/nockchain/state.jam${RESET}"
      echo -e "${CYAN}To check timer status: ${DIM}systemctl status nockchain-statejam-backup.timer${RESET}"
      echo -e "${CYAN}To check backup logs: ${DIM}journalctl -u nockchain-statejam-backup.service -e${RESET}"
      echo -e "${CYAN}To check next/last run: ${DIM}systemctl list-timers --all | grep nockchain-statejam-backup${RESET}"
      echo -e "${CYAN}To check execution logs: ${DIM}journalctl -u nockchain-statejam-backup.service --since \"2 hours ago\"${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi
    ;;
  5)
    clear

    miner_dirs=$(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" | sort -V)

    if [[ -z "$miner_dirs" ]]; then
      echo -e "${RED}❌ No miner directories found.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to menu...'
      continue
    fi

    if ! command -v fzf &> /dev/null; then
      echo -e "${YELLOW}fzf not found. Installing fzf...${RESET}"
      sudo apt-get update && sudo apt-get install -y fzf
      echo -e "${GREEN}fzf installed successfully.${RESET}"
    fi

    # Check latest Google Drive block (re-used for menu display)
    # Try to use gdown's Python API for robustness if available, else fallback to CLI
    GD_FILE_LIST=""
    GDFOLDER="https://drive.google.com/drive/folders/1aEYZwmg4isTuYXWFn9gKPl92-pYndwUw"
    # Use a temp file for the log, in case fallback is needed
    TMP_DRIVE_LIST_LOG="/tmp/gdown_list_menu.log"
    if python3 -c 'import gdown' 2>/dev/null; then
      GD_FILE_LIST=$(python3 -c "
import gdown, sys
try:
    files = gdown._list_folder('$GDFOLDER')
    for f in files:
        if f['name'].endswith('.jam'):
            print(f[\"id\"], f[\"name\"])
except Exception as e:
    sys.exit(0)
" 2>/dev/null || true)
    fi
    if [[ -z "$GD_FILE_LIST" ]]; then
      # fallback to gdown CLI, robust parsing, output errors to log file
      GD_FILE_LIST=$(gdown --folder "$GDFOLDER" --list-only 2>"$TMP_DRIVE_LIST_LOG" | grep '.jam' | awk '{print $1, $(NF)}' || true)
    fi
    # Default to empty string for GD_LATEST_BLOCK
    GD_LATEST_BLOCK=""
    if [[ -n "$GD_FILE_LIST" ]]; then
      # Remove .jam suffix, extract numbers, sort numerically, pick the highest
      GD_LATEST_BLOCK=$(echo "$GD_FILE_LIST" | awk '{print $2}' | sed 's/[^0-9]*//g' | sort -n | tail -n 1)
      [[ -z "$GD_LATEST_BLOCK" ]] && GD_LATEST_BLOCK="unknown"
    else
      GD_LATEST_BLOCK="unknown"
    fi
    # Fallback if still empty
    [[ -z "$GD_LATEST_BLOCK" ]] && GD_LATEST_BLOCK="unknown"

    # Build formatted fzf menu showing miner name and latest block height, with status icon
    declare -a menu_entries=()
    declare -A miner_dirs_map

    # Fetch latest commit message that modified state.jam
    GITHUB_COMMIT_MSG=$(curl -fsSL "https://api.github.com/repos/jobless0x/nockchain-launcher/commits?path=state.jam" \
      | grep -m 1 '"message":' \
      | grep -oE 'block [0-9]+\.[0-9]+' \
      | head -n 1)

    if [[ "$GITHUB_COMMIT_MSG" =~ block[[:space:]]+([0-9]+\.[0-9]+) ]]; then
      BLOCK_COMMIT_VERSION="${BASH_REMATCH[1]}"
    else
      BLOCK_COMMIT_VERSION="unknown"
    fi
    GITHUB_COMMIT_DISPLAY="📦 Download latest state.jam from GitHub (block $BLOCK_COMMIT_VERSION)"
    GD_COMMIT_DISPLAY="📥 Download latest state.jam from Google Drive (official)"

    for dir in $miner_dirs; do
      miner_id=$(basename "$dir" | grep -o '[0-9]\+')
      log_path="$dir/miner${miner_id}.log"
      miner_name="miner${miner_id}"
      latest_block="--"
      if [[ -f "$log_path" ]]; then
        latest_block=$(grep -a 'added to validated blocks at' "$log_path" 2>/dev/null | tail -n 1 | grep -oP 'at\s+\K[0-9]+\.[0-9]+' || echo "--")
      fi
      # Determine systemd status for this miner
      if systemctl is-active --quiet "nockchain-${miner_name}"; then
        status_icon="🟢"
      else
        status_icon="🔴"
      fi
      label="$(printf "%s %b%-8s%b %b[Block: %s]%b" "$status_icon" "${BOLD_BLUE}" "$miner_name" "${RESET}" "${DIM}" "$latest_block" "${RESET}")"
      menu_entries+=("$label")
      miner_dirs_map["$miner_name"]="$dir"
    done
    menu_entries=("↩️  Cancel and return to menu" "$GD_COMMIT_DISPLAY" "$GITHUB_COMMIT_DISPLAY" "${menu_entries[@]}")

    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --prompt="Select miner to export from: " \
      --pointer="👉" --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse ↑ ↓ arrows to navigate. ENTER to confirm.\n')

    if [[ "$selected" == *"Google Drive"* ]]; then
      echo -e "${CYAN}📦 Step 1/4: Verifying required tools...${RESET}"
      echo -e "${DIM}Checking for: wget, gdown, pip3...${RESET}"
      for tool in wget gdown pip3; do
        if command -v "$tool" &>/dev/null; then
          echo -e "${GREEN}✔ $tool found${RESET}"
        else
          echo -e "${YELLOW}⚠ $tool not found. Installing...${RESET}"
        fi
      done
      # Step 1: Try gdrive CLI, else fallback to scraping Google Drive folder page and use gdown
      TMP_CLONE="$HOME/nockchain/tmp_drive_download"
      rm -rf "$TMP_CLONE"
      mkdir -p "$TMP_CLONE"

      GDRIVE_FOLDER_ID="1aEYZwmg4isTuYXWFn9gKPl92-pYndwUw"
      GDRIVE_FOLDER_URL="https://drive.google.com/drive/folders/$GDRIVE_FOLDER_ID"

      use_gdrive_cli=0
      if command -v gdrive &>/dev/null; then
        GDRIVE_BIN="$(command -v gdrive)"
        if [[ -x "$GDRIVE_BIN" ]] && "$GDRIVE_BIN" version &>/dev/null; then
          use_gdrive_cli=1
        fi
      fi

      if [[ "$use_gdrive_cli" == "1" ]]; then
        echo ""
        echo -e "${CYAN}📥 Step 1/4: Listing files from Google Drive with gdrive CLI...${RESET}"
        GDRIVE_LIST_OUTPUT=$("$GDRIVE_BIN" list --no-header --query "'$GDRIVE_FOLDER_ID' in parents" --name-width 0 | grep '.jam' | awk '{print $1, $NF}')
        if [[ -z "$GDRIVE_LIST_OUTPUT" ]]; then
          echo -e "${RED}❌ Could not list files from Google Drive using gdrive CLI. Falling back to scraping method.${RESET}"
          use_gdrive_cli=0
        fi
      fi

      if [[ "$use_gdrive_cli" == "1" ]]; then
        LATEST_FILE_ID=$(echo "$GDRIVE_LIST_OUTPUT" | awk '{gsub(".jam","",$2); print $1, $2}' | sort -k2 -n | tail -n 1 | awk '{print $1}')
        LATEST_FILE_NAME=$(echo "$GDRIVE_LIST_OUTPUT" | awk '{gsub(".jam","",$2); print $1, $2}' | sort -k2 -n | tail -n 1 | awk '{print $2 ".jam"}')
        LATEST_BLOCK=$(echo "$LATEST_FILE_NAME" | grep -oE '[0-9]+')

        echo ""
        echo -e "${CYAN}📥 Step 2/4: Downloading $LATEST_FILE_NAME (block $LATEST_BLOCK) using gdrive...${RESET}"
        "$GDRIVE_BIN" download "$LATEST_FILE_ID" --path "$TMP_CLONE" --force
        if [[ ! -f "$TMP_CLONE/$LATEST_FILE_NAME" ]]; then
          echo -e "${RED}❌ Download failed via gdrive. Exiting.${RESET}"
          rm -rf "$TMP_CLONE"
          read -n 1 -s
          continue
        fi
        mv "$TMP_CLONE/$LATEST_FILE_NAME" "$TMP_CLONE/state.jam"
        echo ""
        echo -e "${CYAN}📦 Step 3/4: Moving state.jam to ~/nockchain and cleaning up...${RESET}"
        mv "$TMP_CLONE/state.jam" "$HOME/nockchain/state.jam"
        rm -rf "$TMP_CLONE"
        echo -e "${GREEN}✅ state.jam downloaded and saved to ${CYAN}$HOME/nockchain/state.jam${GREEN}.${RESET}"
        read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
        continue
      fi

      # Fallback: Scrape Google Drive folder page and use gdown
      echo ""
      echo -e "${CYAN}📥 Step 2/4: Creating temp folder and scraping Google Drive folder page...${RESET}"
      # Install wget and gdown if needed
      if ! command -v wget &>/dev/null; then
        echo -e "${YELLOW}wget not found. Installing...${RESET}"
        sudo apt-get update && sudo apt-get install -y wget
      fi
      if ! command -v gdown &>/dev/null; then
        echo -e "${YELLOW}gdown not found. Installing via pip...${RESET}"
        if ! command -v pip3 &>/dev/null; then
          sudo apt-get update && sudo apt-get install -y python3-pip
        fi
        pip3 install --user gdown
        export PATH="$HOME/.local/bin:$PATH"
      fi

      # --- BEGIN PATCH: Improved fallback Google Drive scraping logic ---
      # 📥 Step 1/4: Download the folder page with a proper User-Agent
      FOLDER_URL="https://drive.google.com/drive/folders/1aEYZwmg4isTuYXWFn9gKPl92-pYndwUw"
      mkdir -p "$TMP_CLONE"
      wget -qO "$TMP_CLONE/folder.html" --header="User-Agent: Mozilla/5.0" "$FOLDER_URL"
      # Wait for folder.html to exist and be non-empty, up to 2.5 seconds
      for i in {1..5}; do
        [[ -s "$TMP_CLONE/folder.html" ]] && break
        sleep 0.5
      done
      if [[ ! -s "$TMP_CLONE/folder.html" ]]; then
        echo -e "${RED}❌ Failed to download or save folder.html properly.${RESET}"
        rm -rf "$TMP_CLONE"
        read -n 1 -s
        continue
      fi

      # 📥 Step 2/4: Diagnostic extraction of .jam files and their IDs using Python+BeautifulSoup for robust parsing
      echo -e "${DIM}Parsing folder.html for .jam entries (Python+BeautifulSoup)...${RESET}"
      pip3 install -q beautifulsoup4
      python3 - <<EOF
import os
from bs4 import BeautifulSoup

tmp_clone = os.environ.get("TMP_CLONE", os.path.expanduser("~/nockchain/tmp_drive_download"))
with open(f"{tmp_clone}/folder.html") as f:
    soup = BeautifulSoup(f, "html.parser")

ids = []
jams = []
for div in soup.find_all("div"):
    if div.has_attr("data-id") and div["data-id"] != "_gd":
        ids.append(div["data-id"])
    if div.has_attr("data-tooltip") and "Binary:" in div["data-tooltip"] and ".jam" in div["data-tooltip"]:
        name = div["data-tooltip"].split("Binary:")[-1].strip()
        if name.endswith(".jam"):
            jams.append(name)

pairs = list(zip(ids, jams))

with open(f"{tmp_clone}/jam_files.txt", "w") as out:
    for id_, name in pairs:
        out.write(f"{id_}\t{name}\n")
EOF
      if [[ ! -s "$TMP_CLONE/jam_files.txt" ]]; then
        echo -e "${RED}❌ Could not extract any .jam files from folder.html.${RESET}"
        read -n 1 -s
        continue
      fi
      echo -e "${DIM}Found $(wc -l < "$TMP_CLONE/jam_files.txt") .jam file(s).${RESET}"
      echo -e "${DIM}Discovered .jam files with IDs:${RESET}"
      while IFS=$'\t' read -r id name; do
        # echo "[DEBUG] raw line: $id $name"
        [[ -z "$id" || -z "$name" || "$name" != *.jam ]] && continue
        block=$(echo "$name" | grep -oE '[0-9]+')
        echo -e "${CYAN}- $name${RESET} ${DIM}(block $block, id=$id)${RESET}"
      done < "$TMP_CLONE/jam_files.txt"
      # Extract full metadata list and pick true latest based on numeric block
      latest_block=-1
      latest_id=""
      latest_name=""
      while IFS=$'\t' read -r id name; do
        block=$(echo "$name" | grep -oE '[0-9]+')
        [[ -z "$id" || -z "$name" || -z "$block" ]] && continue
        if (( block > latest_block )); then
          latest_block=$block
          latest_id=$id
          latest_name=$name
        fi
      done < "$TMP_CLONE/jam_files.txt"
      # echo "[DEBUG] selected latest_name='$latest_name', latest_block='$latest_block', latest_id='$latest_id'"
      if [[ -z "$latest_id" || -z "$latest_name" || "$latest_block" -lt 0 ]]; then
        echo -e "${RED}❌ Could not extract latest .jam file correctly. Aborting.${RESET}"
        rm -rf "$TMP_CLONE"
        read -n 1 -s
        continue
      fi
      echo -e "${DIM}Selected latest .jam file: ${CYAN}$latest_name${DIM} (ID: $latest_id, Block: $latest_block)${RESET}"
      echo ""
      echo -e "${CYAN}📥 Step 3/4: Downloading state.jam (block $latest_block) using gdown...${RESET}"
      gdown --id "$latest_id" -O "$TMP_CLONE/state.jam"
      if [[ ! -f "$TMP_CLONE/state.jam" ]]; then
        echo -e "${RED}❌ Download failed via gdown. Exiting.${RESET}"
        rm -rf "$TMP_CLONE"
        read -n 1 -s
        continue
      fi
      echo ""
      echo -e "${CYAN}📦 Step 4/4: Moving state.jam to ~/nockchain and cleaning up...${RESET}"
      mv "$TMP_CLONE/state.jam" "$HOME/nockchain/state.jam"
      rm -rf "$TMP_CLONE"
      echo -e "${GREEN}✅ state.jam downloaded and saved to ${CYAN}$HOME/nockchain/state.jam${GREEN} (block $latest_block).${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi

    if [[ "$selected" == *"Download latest state.jam from GitHub"* ]]; then
      echo -e "${CYAN}📥 Step 1/3: Create temp folder, Initializing Git and GIT LFS...${RESET}"
      TMP_CLONE="$HOME/nockchain/tmp_launcher_clone"
      rm -rf "$TMP_CLONE"

      # Ensure git and git-lfs are installed (auto-install if missing)
      for tool in git git-lfs; do
        if ! command -v $tool &>/dev/null; then
          echo -e "${YELLOW}⚠️ '$tool' not found. Installing...${RESET}"
          sudo apt-get update && sudo apt-get install -y "$tool"
        fi
      done

      echo ""
      echo -e "${CYAN}📥 Step 2/4: Cloning launcher repo into temp folder...${RESET}"
      if GIT_LFS_SKIP_SMUDGE=1 git clone --progress https://github.com/jobless0x/nockchain-launcher.git "$TMP_CLONE"; then
        echo -e "${GREEN}✅ Repo cloned successfully.${RESET}"
        
        echo ""
        echo -e "${CYAN}⏳ Step 3/4: Downloading state.jam [block $BLOCK_COMMIT_VERSION], this may take a while...${RESET}"
      else
        echo -e "${RED}❌ Failed to clone repo. Exiting.${RESET}"
        read -n 1 -s
        continue
      fi

      cd "$TMP_CLONE"
      trap 'echo -e "${RED}✖️  Interrupted. Cleaning up...${RESET}"; rm -rf "$TMP_CLONE"; exit 130' INT
      git lfs install --skip-repo &>/dev/null
      if command -v pv &>/dev/null; then
        echo -e "${CYAN}🔄 Downloading state.jam via Git LFS...${RESET}"
        git lfs pull --include="state.jam" 2>&1 | grep --line-buffered -v 'Downloading LFS objects:' | pv -lep -s 1100000000 -N "state.jam" > /dev/null
        echo -e "${GREEN}✅ Download complete.${RESET}"
      else
        echo -e "${CYAN}🔄 Downloading state.jam...${RESET}"
        git lfs pull --include="state.jam"
        echo -e "${GREEN}✅ Download complete.${RESET}"
      fi
      trap - INT

      if [[ ! -f "state.jam" ]]; then
        echo -e "${RED}❌ state.jam not found after LFS pull. Exiting.${RESET}"
        read -n 1 -s
        continue
      fi

      echo ""
      echo -e "${CYAN}📦 Step 4/4: Moving state.jam to ~/nockchain and cleaning up...${RESET}"
      mv "state.jam" "$HOME/nockchain/state.jam"
      rm -rf "$TMP_CLONE"

      echo -e "${GREEN}✅ state.jam downloaded and saved to ${CYAN}$HOME/nockchain/state.jam${GREEN}.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi

    selected_miner=$(echo "$selected" | grep -Eo 'miner[0-9]+' | head -n 1 || true)

    if [[ -z "$selected_miner" || -z "${miner_dirs_map[$selected_miner]:-}" ]]; then
      echo -e "${YELLOW}No valid selection made. Returning to menu...${RESET}"
      continue
    fi

    select_dir="${miner_dirs_map[$selected_miner]}"
    miner_name=$(basename "$select_dir")
    export_dir="$HOME/nockchain/miner-export"
    state_output="$HOME/nockchain/state.jam"

    echo -e "${CYAN}Creating temporary copy of $miner_name for safe export...${RESET}"
    rm -rf "$export_dir"
    cp -a "$select_dir" "$export_dir"

    echo -e "${CYAN}Exporting state.jam to $state_output...${RESET}"
    echo -e "${DIM}Log will be saved to ~/nockchain/export.log${RESET}"
    cd "$export_dir"
    echo -e "${CYAN}Running export process...${RESET}"
    "$HOME/nockchain/target/release/nockchain" --export-state-jam "$state_output" 2>&1 | tee "$HOME/nockchain/export.log"
    cd "$HOME/nockchain"
    rm -rf "$export_dir"

    echo -e "${GREEN}✅ Exported state.jam from duplicate of ${CYAN}$selected_miner${GREEN} to ${CYAN}$state_output${GREEN}.${RESET}"
    echo -e "${DIM}To view detailed export logs: tail -n 20 ~/nockchain/export.log${RESET}"
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  21)
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
  13)
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
    # Write run_miner.sh for systemd
    RUN_MINER_SCRIPT="$SCRIPT_DIR/run_miner.sh"
cat > "$RUN_MINER_SCRIPT" <<'EOS'
#!/bin/bash
set -eux
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

id=${1:-0}
if [[ -z "$id" || "$id" -lt 1 || "$id" -gt 999 ]]; then
  echo "Invalid miner ID: $id"
  exit 1
fi

DIR="$HOME/nockchain/miner$id"
mkdir -p "$DIR"
cd "$DIR"
rm -f .socket/nockchain_npc.sock || true
STATE_FLAG=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^STATE_FLAG=/ {
    sub(/^STATE_FLAG=/, "")
    print
    exit
  }
' "$SCRIPT_DIR/launch.cfg")

# --- BEGIN PATCHED BLOCK ---
BIND_FLAG=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^BIND_FLAG=/ {
    sub(/^BIND_FLAG=/, "")
    print
    exit
  }
' "$SCRIPT_DIR/launch.cfg")

MAX_ESTABLISHED=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^MAX_ESTABLISHED_FLAG=/ {
    sub(/^MAX_ESTABLISHED_FLAG=/, "")
    print
    exit
  }
' "$SCRIPT_DIR/launch.cfg")
# --- END PATCHED BLOCK ---

export MINIMAL_LOG_FORMAT=true
export RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info

LOGFILE="miner${id}.log"
if [ -e "$LOGFILE" ]; then
  DT=$(date +"%Y%m%d_%H%M%S")
  mv "$LOGFILE" miner${id}-$DT.log
fi

## --- BEGIN PATCHED BLOCK: Updated conditional command construction ---
CMD=("$HOME/nockchain/target/release/nockchain" --mine --mining-pubkey "$MINING_KEY")
if [[ -n "$BIND_FLAG" && "$BIND_FLAG" != "--bind" ]]; then
  CMD+=($BIND_FLAG)
fi
[[ -n "$MAX_ESTABLISHED" ]] && CMD+=($MAX_ESTABLISHED)
[[ -n "$STATE_FLAG" ]] && CMD+=($STATE_FLAG)
"${CMD[@]}" 2>&1 | tee "$LOGFILE"
## --- END PATCHED BLOCK ---
EOS
    chmod +x "$RUN_MINER_SCRIPT"
    echo -e "${GREEN}✅ run_miner.sh is ready.${RESET}"

    # Prompt for use of existing config if present
    if [[ -f "$CONFIG_FILE" ]]; then
      echo ""
      echo -e "${BOLD_BLUE}${CYAN}⚙️  Miner Configuration${RESET}"
      echo -e "${DIM}──────────────────────────────────────────────${RESET}"
      cat "$CONFIG_FILE"
      echo -e "${DIM}──────────────────────────────────────────────${RESET}"
      echo ""
      echo -e "${YELLOW}Do you want to keep this existing configuration?${RESET}"
      echo ""
      echo -e "${CYAN}1) Use existing configuration${RESET}"
      echo -e "${CYAN}2) Create new configuration${RESET}"
      echo ""
      while true; do
        read -rp "$(echo -e "${BOLD_BLUE}> Enter choice [1/2]: ${RESET}")" USE_EXISTING_CFG
        [[ "$USE_EXISTING_CFG" == "1" || "$USE_EXISTING_CFG" == "2" ]] && break
        echo -e "${RED}❌ Invalid input. Please enter 1 or 2.${RESET}"
      done
      if [[ "$USE_EXISTING_CFG" == "1" ]]; then
        # Automatically count number of miners in existing config
        NUM_MINERS=$(grep -c '^\[miner[0-9]\+\]' "$CONFIG_FILE")
        echo ""
        echo -e "${GREEN}✅ Using existing configuration.${RESET}"
        echo ""
        echo -e "${BOLD_BLUE}${CYAN}🔧 Launch Preview${RESET}"
        printf "  ${CYAN}%-10s %-22s %-22s${RESET}\n" "Miner" "Systemd Service" "Run Command"
        for i in $(seq 1 "$NUM_MINERS"); do
          MINER_DIR="$NCK_DIR/miner$i"
          SERVICE="nockchain-miner$i.service"
          RUN_CMD="cd $MINER_DIR && exec run_miner.sh $i"
          printf "  ${BOLD_BLUE}%-10s${RESET} %-22s %-22s\n" "miner$i" "$SERVICE" "$RUN_CMD"
        done
        echo ""
        echo -e "${YELLOW}Proceed? (y/n)${RESET}"
        echo ""
        while true; do
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_EXISTING_LAUNCH
          [[ "$CONFIRM_EXISTING_LAUNCH" =~ ^[YyNn]$ ]] && break
          echo -e "${RED}❌ Please enter y or n.${RESET}"
        done
        if [[ "$CONFIRM_EXISTING_LAUNCH" =~ ^[Yy]$ ]]; then
          echo ""
          echo -e "${GREEN}Proceeding with miner launch...${RESET}"
          for i in $(seq 1 "$NUM_MINERS"); do
            MINER_DIR="$NCK_DIR/miner$i"
            mkdir -p "$MINER_DIR"
            generate_systemd_service $i
            start_miner_service $i
          done
          echo ""
          echo -e "${GREEN}\e[1m🎉 Success:${RESET}${GREEN} Nockchain miners launched via systemd!${RESET}"
          echo ""
          echo -e "${CYAN}  Manage your miners with the following commands:${RESET}"
          echo -e "${CYAN}    - Status:   ${DIM}systemctl status nockchain-minerX${RESET}"
          echo -e "${CYAN}    - Logs:     ${DIM}tail -f ~/nockchain/minerX/minerX.log${RESET}"
          echo -e "${CYAN}    - Stop:     ${DIM}sudo systemctl stop nockchain-minerX${RESET}"
          echo -e "${CYAN}    - Start:    ${DIM}sudo systemctl start nockchain-minerX${RESET}"
          echo ""
          echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
          read -n 1 -s
          continue
        else
          echo ""
          echo -e "${CYAN}Returning to menu...${RESET}"
          continue
        fi
      else
        echo ""
        echo -e "${YELLOW}⚠️ Discarding existing configuration...${RESET}"
        rm -f "$CONFIG_FILE"
        echo ""
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
    echo ""
    echo -e "${CYAN}\e[1m▶ Configuring firewall...${RESET}"
    sudo ufw allow ssh >/dev/null 2>&1 || true
    sudo ufw allow 22 >/dev/null 2>&1 || true
    sudo ufw allow 3005/tcp >/dev/null 2>&1 || true
    sudo ufw allow 3006/tcp >/dev/null 2>&1 || true
    sudo ufw allow 3005/udp >/dev/null 2>&1 || true
    sudo ufw allow 3006/udp >/dev/null 2>&1 || true
    sudo ufw --force enable >/dev/null 2>&1 || echo -e "${YELLOW}Warning: Failed to enable UFW. Continuing script execution.${RESET}"
    echo -e "${GREEN}✅ Firewall configured.${RESET}"
    echo ""
    # Collect system specs and calculate optimal number of miners
    CPU_CORES=$(nproc)
    TOTAL_MEM=$(free -g | awk '/^Mem:/ {print $2}')
    echo ""
    while true; do
      echo -e "${YELLOW}How many miners do you want to run?${RESET}"
      echo -e "${DIM}Enter a number like 1, 3, 10... or type 'n' to cancel.${RESET}"
      echo ""
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" NUM_MINERS
      NUM_MINERS=$(echo "$NUM_MINERS" | tr -d '[:space:]')
      if [[ "$NUM_MINERS" =~ ^[Nn]$ ]]; then
        echo ""
        echo -e "${CYAN}Returning to menu...${RESET}"
        break
      elif [[ "$NUM_MINERS" =~ ^[0-9]+$ && "$NUM_MINERS" -ge 1 ]]; then
        # Prompt for max connections per miner
        echo ""
        echo -e "${YELLOW}Do you want to set a maximum number of connections per miner?${RESET}"
        echo -e "${DIM}32 is often a safe value. Leave empty to skip this option.${RESET}"
        echo ""
        read -rp "$(echo -e "${BOLD_BLUE}> Enter value or press enter: ${RESET}")" MAX_ESTABLISHED
        echo ""
        # Prompt for peer mode
        echo -e "${YELLOW}Select peer mode for these miners:${RESET}"
        echo ""
        echo -e "${CYAN}1) No peers (not recommended)${RESET}"
        echo -e "${CYAN}2) Central node (all miners peer with miner1 only)${RESET}"
        echo -e "${CYAN}3) Full mesh (all miners peer with each other)${RESET}"
        echo -e "${CYAN}4) Custom peers (manual entry per miner)${RESET}"
        echo ""
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
          echo -e "${YELLOW}Enter a base UDP port for miner communication (recommended: 40000):${RESET}"
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
        echo -e ""
        echo -e "${BOLD_BLUE}${CYAN}⚙️  Miner Configuration${RESET}"
        echo -e "${DIM}──────────────────────────────────────────────${RESET}"
        if [[ -f "$LAUNCH_CFG" ]]; then
          cat "$LAUNCH_CFG"
        else
          echo -e "${RED}❌ Configuration file not found.${RESET}"
        fi
        echo -e "${DIM}──────────────────────────────────────────────${RESET}"
        echo ""
        echo -e "${BOLD_BLUE}${CYAN}🔧 Launch Preview${RESET}"
        printf "  ${CYAN}%-10s %-22s %-22s${RESET}\n" "Miner" "Systemd Service" "Run Command"
        for i in $(seq 1 "$NUM_MINERS"); do
          MINER_NAME="miner$i"
          DIR="$HOME/nockchain/$MINER_NAME"
          SERVICE="nockchain-miner$i.service"
          RUN_CMD="cd $DIR && exec run_miner.sh $i"
          printf "  ${BOLD_BLUE}%-10s${RESET} %-22s %-22s\n" "$MINER_NAME" "$SERVICE" "$RUN_CMD"
        done
        echo ""
        echo -e "${YELLOW}Start nockchain miner(s)? (y/n)${RESET}"
        while true; do
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_LAUNCH
          [[ "$CONFIRM_LAUNCH" =~ ^[YyNn]$ ]] && break
          echo -e "${RED}❌ Please enter y or n.${RESET}"
        done
        if [[ "$CONFIRM_LAUNCH" =~ ^[Yy]$ ]]; then
          echo -e "${GREEN}Proceeding with miner launch...${RESET}"
          echo ""
          echo -e "${GREEN}📁 Configuration saved to: $CONFIG_FILE${RESET}"
          echo -e "${CYAN}🧠 Managed by: launch.cfg (edit this file to change peer mode, state file, or flags)${RESET}"
          for i in $(seq 1 "$NUM_MINERS"); do
            MINER_DIR="$NCK_DIR/miner$i"
            mkdir -p "$MINER_DIR"
            generate_systemd_service $i
            start_miner_service $i
          done
          echo ""
          echo -e "${GREEN}\e[1m🎉 Success:${RESET}${GREEN} Nockchain miners launched via systemd!${RESET}"
          echo ""
          echo -e "${CYAN}  Manage your miners with the following commands:${RESET}"
          echo -e "${CYAN}    - Status:   ${DIM}systemctl status nockchain-minerX${RESET}"
          echo -e "${CYAN}    - Logs:     ${DIM}tail -f ~/nockchain/minerX/minerX.log${RESET}"
          echo -e "${CYAN}    - Stop:     ${DIM}sudo systemctl stop nockchain-minerX${RESET}"
          echo -e "${CYAN}    - Start:    ${DIM}sudo systemctl start nockchain-minerX${RESET}"
          echo ""
          echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
          read -n 1 -s
          break
        else
          echo -e "${CYAN}Returning to miner count selection...${RESET}"
          continue
        fi
      else
        echo -e "${RED}❌ Invalid input. Please enter a positive number (e.g. 1, 3) or 'n' to cancel.${RESET}"
      fi
    done
    continue
    ;;
  14)
    clear
    all_miners=()
    for d in "$HOME/nockchain"/miner*; do
      [ -d "$d" ] || continue
      miner_num=$(basename "$d" | sed 's/[^0-9]//g')
      if systemctl is-active --quiet nockchain-miner$miner_num 2>/dev/null; then
        all_miners+=("🟢 miner$miner_num")
      else
        all_miners+=("❌ miner$miner_num")
      fi
    done
    IFS=$'\n' sorted_miners=($(printf "%s\n" "${all_miners[@]}" | sort -k2 -V))
    unset IFS
    if ! command -v fzf &> /dev/null; then
      echo -e "${YELLOW}fzf not found. Installing fzf...${RESET}"
      sudo apt-get update && sudo apt-get install -y fzf
      echo -e "${GREEN}fzf installed successfully.${RESET}"
    fi
    # Build styled menu_entries for restart
    declare -a menu_entries=()
    menu_entries+=("🔁 Restart all miners")
    menu_entries+=("↩️  Cancel and return to menu")
    for entry in "${sorted_miners[@]}"; do
      status_icon=$(echo "$entry" | awk '{print $1}')
      miner_label=$(echo "$entry" | awk '{print $2}')
      styled_entry="$(printf "%s %b%-8s%b" "$status_icon" "${BOLD_BLUE}" "$miner_label" "${RESET}")"
      menu_entries+=("$styled_entry")
    done
    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --multi --bind "space:toggle" \
      --prompt="Select miners to restart: " --pointer="👉" --marker="✓" \
      --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse SPACE to select miners.\nENTER will restart selected miners.\n')
    if [[ -z "$selected" || "$selected" == *"Cancel and return to menu"* ]]; then
      echo -e "${YELLOW}No selection made. Returning to menu...${RESET}"
      continue
    fi
    if echo "$selected" | grep -q "Restart all miners"; then
      TARGET_MINERS=$(printf "%s\n" "${sorted_miners[@]}" | sed 's/^[^ ]* //')
    else
      # Extract miner names from styled selection
      TARGET_MINERS=$(echo "$selected" | grep -Eo 'miner[0-9]+')
    fi
    echo -e "${YELLOW}You selected:${RESET}"
    for miner in $TARGET_MINERS; do
      echo -e "${CYAN}- $miner${RESET}"
    done
    echo -e "${YELLOW}Are you sure you want to restart these? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_RESTART
      [[ "$CONFIRM_RESTART" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    [[ ! "$CONFIRM_RESTART" =~ ^[Yy]$ ]] && echo -e "${CYAN}Returning to menu...${RESET}" && continue
    for miner in $TARGET_MINERS; do
      miner_num=$(echo "$miner" | grep -o '[0-9]\+')
      echo -e "${CYAN}Restarting $miner...${RESET}"
      sudo systemctl restart nockchain-miner$miner_num
      start_miner_service $miner_num
    done
    echo -e "${GREEN}✅ Selected miners have been restarted via systemd.${RESET}"
    echo -e "${CYAN}To check status: ${DIM}systemctl status nockchain-minerX${RESET}"
    echo -e "${CYAN}To view logs:    ${DIM}tail -f ~/nockchain/minerX/minerX.log${RESET}"
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  15)
    clear
    all_miners=()
    for d in "$HOME/nockchain"/miner*; do
      [ -d "$d" ] || continue
      miner_num=$(basename "$d" | sed 's/[^0-9]//g')
      if systemctl is-active --quiet nockchain-miner$miner_num 2>/dev/null; then
        all_miners+=("🟢 miner$miner_num")
      else
        all_miners+=("❌ miner$miner_num")
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
    # Build styled menu_entries for stop
    declare -a menu_entries=()
    menu_entries+=("🛑 Stop all running miners")
    menu_entries+=("↩️  Cancel and return to menu")
    for entry in "${running_miners[@]}"; do
      status_icon=$(echo "$entry" | awk '{print $1}')
      miner_label=$(echo "$entry" | awk '{print $2}')
      styled_entry="$(printf "%s %b%-8s%b" "$status_icon" "${BOLD_BLUE}" "$miner_label" "${RESET}")"
      menu_entries+=("$styled_entry")
    done
    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --multi --bind "space:toggle" \
      --prompt="Select miners to stop: " --pointer="👉" --marker="✓" \
      --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse SPACE to select miners.\nENTER will stop selected miners.\n')
    if [[ -z "$selected" || "$selected" == *"Cancel and return to menu"* ]]; then
      echo -e "${YELLOW}No selection made. Returning to menu...${RESET}"
      continue
    fi
    if echo "$selected" | grep -q "Stop all"; then
      TARGET_MINERS=$(printf "%s\n" "${sorted_miners[@]}" | grep '^🟢' | sed 's/^[^ ]* //')
    else
      TARGET_MINERS=$(echo "$selected" | grep -Eo 'miner[0-9]+')
    fi
    echo -e "${YELLOW}You selected:${RESET}"
    for miner in $TARGET_MINERS; do
      echo -e "${CYAN}- $miner${RESET}"
    done
    echo -e "${YELLOW}Are you sure you want to stop these? (y/n)${RESET}"
    while true; do
      read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" CONFIRM_STOP
      [[ "$CONFIRM_STOP" =~ ^[YyNn]$ ]] && break
      echo -e "${RED}❌ Please enter y or n.${RESET}"
    done
    [[ ! "$CONFIRM_STOP" =~ ^[Yy]$ ]] && echo -e "${CYAN}Returning to menu...${RESET}" && continue
    for miner in $TARGET_MINERS; do
      miner_num=$(echo "$miner" | grep -o '[0-9]\+')
      echo -e "${CYAN}Stopping $miner...${RESET}"
      sudo systemctl stop nockchain-miner$miner_num
    done
    echo -e "${GREEN}✅ Selected miners have been stopped via systemd.${RESET}"
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  11)
    clear
    # Calculate total system memory in GB for MEM % -> GB conversion (outside the loop, only once)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_GB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_MEM_KB/1024/1024 }")
    while true; do
      # Extract network height from all miner logs (live, every refresh)
      NETWORK_HEIGHT="--"
      all_blocks=()
      for miner_dir in "$HOME/nockchain"/miner*; do
        [[ -d "$miner_dir" ]] || continue
        log_file="$miner_dir/$(basename "$miner_dir").log"
        height=""
        if [[ -f "$log_file" && -r "$log_file" ]]; then
          heard_block=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K[0-9]+\.[0-9]+' || true)
          validated_block=$(grep -a 'added to validated blocks at' "$log_file" | tail -n 5 | grep -oP 'at\s+\K[0-9]+\.[0-9]+' || true)
          combined=$(printf "%s\n%s\n" "$heard_block" "$validated_block" | sort -V | tail -n 1)
          if [[ -n "$combined" ]]; then
            all_blocks+=("$combined")
          fi
        fi
      done
      if [[ ${#all_blocks[@]} -gt 0 ]]; then
        NETWORK_HEIGHT=$(printf "%s\n" "${all_blocks[@]}" | sort -V | tail -n 1)
      fi
      tput cup 0 0
      echo -e "${DIM}🖥️  Live Miner Monitor ${RESET}"
      echo ""
      echo -e "${DIM}Legend:${RESET} ${YELLOW}🟡 <5m${RESET} | ${CYAN}🔵 <30m${RESET} | ${GREEN}🟢 Stable >30m${RESET} | ${RED}❌ Inactive${RESET}"
      echo ""
      echo -e "${CYAN}📡 Network height: ${RESET}$NETWORK_HEIGHT"
      echo ""
      printf "   | %-9s | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-10s | %-9s\n" "Miner" "Uptime" "CPU (%)" "MEM (%)" "RAM (GB)" "Block" "Lag" "Status" "Peers"

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
        log_file="$miner_dir/${session}.log"

        if systemctl is-active --quiet nockchain-$session 2>/dev/null; then
          # Get the actual nockchain process PID for this miner using systemd
          miner_pid=$(systemctl show -p MainPID --value nockchain-$session)

          readable="--"
          if [[ -n "$miner_pid" && "$miner_pid" =~ ^[0-9]+$ && "$miner_pid" -gt 1 && -r "/proc/$miner_pid/stat" ]]; then
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

          # Validate miner_pid before using for metrics
          if [[ -z "$miner_pid" || ! "$miner_pid" =~ ^[0-9]+$ || "$miner_pid" -le 1 || ! -e "/proc/$miner_pid" ]]; then
            cpu="--"
            mem="--"
          else
            child_pid=""
            for cpid in $(pgrep -P "$miner_pid"); do
              cmdline=$(ps -p "$cpid" -o cmd=)
              if [[ "$cmdline" == *nockchain/target/release/nockchain* ]]; then
                child_pid="$cpid"
                break
              fi
            done
            if [[ -n "$child_pid" && -e "/proc/$child_pid" ]]; then
              cpu_mem=$(ps -p "$child_pid" -o %cpu,%mem --no-headers)
              cpu=$(echo "$cpu_mem" | awk '{print $1}')
              mem=$(echo "$cpu_mem" | awk '{print $2}')
            else
              cpu="--"
              mem="--"
            fi
          fi

          # Read memory usage in kB directly from /proc/<pid>/status (VmRSS)
          if [[ -n "$child_pid" && -e "/proc/$child_pid/status" ]]; then
            mem_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$child_pid/status")
            mem_gb=$(awk "BEGIN { printf \"%.1f\", $mem_kb / 1024 / 1024 }")
          else
            mem_gb="--"
          fi

          if [[ -f "$log_file" ]]; then
            latest_block=$(grep -a 'added to validated blocks at' "$log_file" 2>/dev/null | tail -n 1 | grep -oP 'at\s+\K[0-9]+\.[0-9]+' || echo "--")
          else
            latest_block="--"
          fi

          # Peer count: robust extraction with fallback default value
          if [[ -f "$log_file" ]]; then
            last_line=$(tac "$log_file" | sed 's/\x1b\[[0-9;]*m//g' | grep -a 'connected_peers=' | grep -a 'connected_peers=[0-9]\+' | head -n 1 || echo "")
            extracted=$(echo "$last_line" | sed -n 's/.*connected_peers=\([0-9]\+\).*/\1/p' || echo "")
            if [[ "$extracted" =~ ^[0-9]+$ ]]; then
              peer_count="$extracted"
            else
              peer_count="--"
            fi
          else
            peer_count="--"
          fi

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

          # Print with MEM % and GB as separate columns, fix Status/Peers columns alignment and format string/argument count
          lag_display="$(echo -e "$lag_color$lag_status$RESET")"
          printf "%b | %-9s | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-10s | %-9s\n" "$color" "$session" "$readable" "$cpu%" "$mem%" "$mem_gb" "$latest_block" "$lag" "$lag_display" "$peer_count"
        else
          # Show default values for inactive/broken miners (10 columns)
          printf "${DIM}❌ | %-9s | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-10s | %-9s${RESET}\n" "$session" "--" "--" "--" "--" "--" "--" "inactive" "--"
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
  22)
    clear
    if ! command -v htop &> /dev/null; then
      echo -e "${YELLOW}htop is not installed. Installing now...${RESET}"
      sudo apt-get update && sudo apt-get install -y htop
    fi
    htop || true
    read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
    continue
    ;;

  12)
    clear
    miner_dirs=$(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" | sort -V)

    if [[ -z "$miner_dirs" ]]; then
      echo -e "${RED}❌ No miner directories found.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to menu...'
      continue
    fi

    if ! command -v fzf &> /dev/null; then
      echo -e "${YELLOW}fzf not found. Installing fzf...${RESET}"
      sudo apt-get update && sudo apt-get install -y fzf
      echo -e "${GREEN}fzf installed successfully.${RESET}"
    fi

    # Improved fzf-based miner log menu with status indicators and formatting
    declare -a menu_entries=()
    declare -A miner_logs

    # Collect miner info into array of lines: "miner_id|log_path|status"
    miner_info_lines=()
    for dir in $miner_dirs; do
      miner_id=$(basename "$dir" | grep -o '[0-9]\+')
      log_path="$dir/miner${miner_id}.log"
      service_name="nockchain-miner$miner_id"
      if systemctl is-active --quiet "$service_name"; then
        status_icon="🟢"
      else
        status_icon="🔴"
      fi
      miner_info_lines+=("$miner_id|$log_path|$status_icon")
      miner_logs["miner$miner_id"]="$log_path"
    done

    # Sort by miner number
    IFS=$'\n' sorted_info=($(printf "%s\n" "${miner_info_lines[@]}" | sort -t'|' -k1,1n))
    unset IFS

    # Build menu entries with formatting
    for info in "${sorted_info[@]}"; do
      miner_id=$(echo "$info" | cut -d'|' -f1)
      log_path=$(echo "$info" | cut -d'|' -f2)
      status_icon=$(echo "$info" | cut -d'|' -f3)
      label="$(printf "%s %b%-8s%b %b[%s]%b" "$status_icon" "${BOLD_BLUE}" "miner$miner_id" "${RESET}" "${DIM}" "$log_path" "${RESET}")"
      menu_entries+=("$label")
    done

    # Add Show all at the top and Cancel directly after, then the miners
    menu_entries=("📡 Show all miner logs combined (live)" "↩️  Cancel and return to menu" "${menu_entries[@]}")

    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --prompt="Select miner: " \
      --pointer="👉" --marker="✓" \
      --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse ↑ ↓ arrows or type to search. ENTER to confirm.\n')
    plain_selected=$(echo -e "$selected" | sed 's/\x1b\[[0-9;]*m//g')
    selected_miner=$(echo "$plain_selected" | grep -Eo 'miner[0-9]+' | head -n 1 || true)
    selected_miner=$(echo "$selected_miner" | tr -d '\n\r')

    if [[ -z "$selected" || "$selected" == *"Cancel and return to menu"* ]]; then
      echo -e "${YELLOW}Returning to menu...${RESET}"
      continue
    elif [[ "$selected" == *"Show all miner logs"* ]]; then
      echo -e "${CYAN}Streaming combined logs from all miners...${RESET}"
      echo -e "${DIM}Press Ctrl+C to return to menu.${RESET}"
      temp_log_script=$(mktemp)
      cat > "$temp_log_script" <<'EOL'
#!/bin/bash
trap "exit 0" INT
tail -f $(find "$HOME/nockchain" -maxdepth 1 -type d -name "miner*" -exec bash -c 'for d; do echo "$d/$(basename "$d").log"; done' _ {} +)
EOL
      chmod +x "$temp_log_script"
      bash "$temp_log_script"
      echo -e "${YELLOW}Log stream ended. Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      rm -f "$temp_log_script"
      continue
    fi

    # Extract miner name from selection (match e.g. "minerX")
    miner_log=""
    [[ -z "$selected_miner" || -z "${miner_logs[$selected_miner]:-}" ]] && {
      echo -e "${RED}❌ Invalid selection. No log file found for: $selected_miner${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to menu...'
      continue
    }
    miner_log="${miner_logs[$selected_miner]}"

    if [[ ! -f "$miner_log" ]]; then
      echo -e "${RED}❌ Log file not found: ${DIM}${miner_log}${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to menu...'
      continue
    fi
    echo -e "${CYAN}Streaming logs for $selected_miner...${RESET}"
    echo -e "${DIM}Press Ctrl+C to return to menu.${RESET}"
    temp_log_script=$(mktemp)
    cat > "$temp_log_script" <<EOL
#!/bin/bash
trap "echo -e '\n${YELLOW}Log stream ended. Press any key to return to the main menu...${RESET}'; read -n 1 -s; exit 0" INT
tail -f "$miner_log"
EOL
    chmod +x "$temp_log_script"
    bash "$temp_log_script"
    rm -f "$temp_log_script"
    continue
    ;;
  *)
    echo -e "${RED}Invalid option selected. Returning to menu...${RESET}"
    sleep 1
    continue
    ;;
esac

done

#
# Function: export_latest_state_jam
# (For use in backup service or manual invocation)
export_latest_state_jam() {
  latest_state_file=""
  highest_block=-1
  for dir in "$HOME/nockchain"/miner*; do
    [ -d "$dir" ] || continue
    state_file="$dir/state.jam"
    if [[ -f "$state_file" ]]; then
      block=$(strings "$state_file" | grep -oE 'block [0-9]+' | grep -oE '[0-9]+' | head -n 1)
      if [[ "$block" =~ ^[0-9]+$ ]] && (( block > highest_block )); then
        highest_block=$block
        latest_state_file="$state_file"
      fi
    fi
  done
  if [[ -n "$latest_state_file" && -f "$latest_state_file" ]]; then
    cp "$latest_state_file" "$HOME/nockchain/state_backup.jam"
    echo "[$(date)] Copied state.jam (block $highest_block) to ~/nockchain/state_backup.jam"
  else
    echo "[$(date)] No valid state.jam found for backup."
  fi
}