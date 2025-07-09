#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD_BLUE="\e[1;34m"
DIM="\e[2m"
RESET="\e[0m"

# Settings file
SETTINGS_FILE="$HOME/.nockchain_launcher.conf"
if [[ -f "$SETTINGS_FILE" ]]; then
  source "$SETTINGS_FILE"
else
  NOCKCHAIN_USER="$(whoami)"
  NOCKCHAIN_HOME="$HOME/nockchain"
  NOCKCHAIN_BIN="$NOCKCHAIN_HOME/target/release/nockchain"
  cat >"$SETTINGS_FILE" <<EOF
NOCKCHAIN_USER="$NOCKCHAIN_USER"
NOCKCHAIN_HOME="$NOCKCHAIN_HOME"
NOCKCHAIN_BIN="$NOCKCHAIN_BIN"
EOF
fi

# Helper to add 's' to a value if it's not '--'
add_s() {
  local val="$1"
  [[ "$val" == "--" ]] && echo "$val" || echo "${val}s"
}

# Pad a string to length, stripping color codes for length calculation
pad_plain() {
  local text="$1"
  local width="$2"
  local plain=$(echo -e "$text" | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')
  local n=${#plain}
  if ((n < width)); then
    printf "%s%*s" "$text" $((width - n)) ""
  else
    echo -n "$text"
  fi
}

# Block normalization helper
normalize_block() {
  local block="$1"
  if [[ "$block" =~ ^[0-9]{1,3}(\.[0-9]{3})*$ ]]; then
    echo "$block" | tr -d '.'
  else
    echo ""
  fi
}

# Helper: Ensure fzf is installed
ensure_fzf_installed() {
  if ! command -v fzf &>/dev/null; then
    echo -e "${YELLOW}fzf not found. Installing fzf...${RESET}"
    sudo apt-get update && sudo apt-get install -y fzf
    echo -e "${GREEN}fzf installed successfully.${RESET}"
  fi
}

# Helper: Ensure the nockchain binary exists before proceeding
require_nockchain() {
  if [[ ! -f "$NOCKCHAIN_BIN" ]]; then
    echo -e "${RED}❌ Nockchain binary not found.${RESET}"
    echo -e "${YELLOW}Please install it first using Option 1.${RESET}"
    read -n 1 -s -r -p $'\nPress any key to return to the menu...'
    return 1
  fi
  return 0
}

# Helper: Ensure the nockchain binary is executable (fix permissions if needed)
ensure_nockchain_executable() {
  if [[ -f "$NOCKCHAIN_BIN" && ! -x "$NOCKCHAIN_BIN" ]]; then
    echo -e "${YELLOW}Fixing permissions: making nockchain binary executable...${RESET}"
    chmod +x "$NOCKCHAIN_BIN"
  fi
}

# Generic y/n prompt helper
confirm_yes_no() {
  local prompt="$1"
  while true; do
    read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}$prompt (y/n): ")" answer
    case "$answer" in
    [Yy]) return 0 ;;
    [Nn]) return 1 ;;
    *) echo -e "${RED}❌ Please enter y or n.${RESET}" ;;
    esac
  done
}

# Systemd service status checker
check_service_status() {
  local service_name="$1"
  if systemctl is-active --quiet "$service_name"; then
    echo "active"
    return 0
  else
    echo "inactive"
    return 1
  fi
}

# Screen session killer
safe_kill_screen() {
  local session="$1"
  if screen -ls | grep -q "$session"; then
    echo -e "${YELLOW}Killing existing screen session: $session...${RESET}"
    screen -S "$session" -X quit
  fi
}

# Extract latest validated block from a miner log
extract_latest_block() {
  local log_file="$1"
  if [[ -f "$log_file" && -r "$log_file" ]]; then
    grep -a 'added to validated blocks at' "$log_file" 2>/dev/null |
      tail -n 1 | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || echo "--"
  else
    echo "--"
  fi
}

# FZF menu entry formatter
styled_menu_entry() {
  local status="$1" miner="$2" block="$3"
  printf "%s %b%-8s%b ${DIM}[Block: %s]%b" "$status" "${BOLD_BLUE}" "$miner" "${RESET}" "$block" "${RESET}"
}

set -euo pipefail
trap 'exit_code=$?; [[ $exit_code -eq 130 ]] && exit 130; [[ $exit_code -ne 0 ]] && echo -e "${RED}(FATAL ERROR) Script exited unexpectedly with code $exit_code on line $LINENO.${RESET}"; caller 0' ERR

# Systemd service generator for miners
generate_systemd_service() {
  local miner_id=$1
  local miner_dir="$NOCKCHAIN_HOME/miner$miner_id"
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
    ' "$CONFIG_FILE" | tr -d '\000')
  local abs_dir="$NOCKCHAIN_HOME/miner$miner_id"
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
User=$NOCKCHAIN_USER
Environment="MINING_KEY=$MINER_KEY"
Environment="RUST_LOG=info"
Environment="NOCKCHAIN_HOME=$NOCKCHAIN_HOME"
Environment="NOCKCHAIN_BIN=$NOCKCHAIN_BIN"
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

  # Ensure the nockchain binary is executable before starting the miner
  ensure_nockchain_executable

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

restart_miner_session() {
  local miner_dir="$1"
  local miner_id
  miner_id=$(basename "$miner_dir")
  local service_name="nockchain-${miner_id}.service"

  echo -e ""
  echo -e "${CYAN}🔄 Restarting $miner_id via systemd...${RESET}"

  sudo systemctl restart "$service_name"
  if systemctl is-active --quiet "$service_name"; then
    echo -e "${GREEN}✅ $miner_id is now running.${RESET}"
  else
    echo -e "${YELLOW}ℹ️  Skipped: $miner_id has no systemd service or failed to start.${RESET}"
  fi
}

update_proof_durations() {
  local miner=$1
  local log_file="$NOCKCHAIN_HOME/$miner/$miner.log"
  local proof_csv="$NOCKCHAIN_HOME/$miner/${miner}_proof_log.csv"

  # Ensure CSV exists and has header
  if [[ ! -f "$proof_csv" ]]; then
    echo "start_time,finish_time,block,comp_time" >"$proof_csv"
    sync "$proof_csv"
    avg_comp=$(tail -n +2 "$proof_csv" | awk -F, '{print $2","$4}' | sort | tail -n 50 | awk -F, '{sum+=$2; count++} END {if(count>0) printf("%.1f", sum/count); else print "--"}')
  fi

  # Bootstrap: scan all finished-proof lines, clean ANSI codes, and filter for lines with block/timestamp
  mapfile -t fp_lines < <(
    LC_ALL=C tr -d '\000' <"$log_file" |
      grep -a 'finished-proof' |
      sed 's/\x1B\[[0-9;]*m//g'
  )

  # Determine if we should skip the bulk loop (if CSV exists and last entry is newer than 1 hour)
  skip_bulk=0
  if [[ -f "$proof_csv" ]]; then
    last_ts=$(tail -n 1 "$proof_csv" | awk -F, '{print $2}')
    if [[ -n "$last_ts" ]]; then
      last_ts_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if ((now_epoch - last_ts_epoch < 3600)); then
        skip_bulk=1
      fi
    fi
  fi

  if [[ "$skip_bulk" -eq 0 ]]; then
    valid_count=0
    total_checked=0
    for ((idx = ${#fp_lines[@]} - 1; idx >= 0 && valid_count < 50; idx--)); do
      fp_line="${fp_lines[idx]}"
      block=$(echo "$fp_line" | tr -d '\000' | sed 's/\x1B\[[0-9;]*m//g' | grep -oP '\[.*\]' | grep -oP '([0-9]+\.){4,}[0-9]+' | tr -d '\000' | head -n 1)
      finish_time=$(echo "$fp_line" | tr -d '\000' | grep -oP '\(\K[0-9]{2}:[0-9]{2}:[0-9]{2}')
      if [[ -z "$block" || -z "$finish_time" ]]; then
        ((total_checked++))
        continue
      fi
      # Find mining-on line for this block
      mline=$(strings "$log_file" | grep "mining-on" | grep "$block" | tail -n 1)
      if [[ -z "$mline" ]]; then
        block_hex=$(echo -n "$block" | xxd -p)
        xxd -p "$log_file" | tr -d '\n' >/tmp/${miner}.hex
        offset=$(grep -ob "$block_hex" /tmp/${miner}.hex | cut -d: -f1 | head -n 1)
        if [[ -n "$offset" ]]; then
          start=$((offset - 2000))
          [[ "$start" -lt 0 ]] && start=0
          dd if=/tmp/${miner}.hex bs=1 skip=$start count=3000 2>/dev/null | xxd -r -p >/tmp/${miner}_pre.log
          mline=$(tr -d '\000' </tmp/${miner}_pre.log | grep -a 'mining-on' | tail -n 1)
        fi
      fi
      start_time=$(echo "$mline" | tr -d '\000' | sed 's/\x1B\[[0-9;]*m//g' | awk '/mining-on/ { match($0, /\([0-9]{2}:[0-9]{2}:[0-9]{2}\)/); if (RSTART > 0) print substr($0, RSTART+1, RLENGTH-2); exit }')
      if [[ -z "$start_time" ]]; then
        ((total_checked++))
        continue
      fi
      comp=$(($(date -d "$finish_time" +%s) - $(date -d "$start_time" +%s)))
      # Check for duplicate: block and finish_time
      if grep -Fq ",$finish_time,$block," <(tail -n +2 "$proof_csv"); then
        :
      else
        echo "$start_time,$finish_time,$block,$comp" >>"$proof_csv"
        sync "$proof_csv"
      fi
      ((total_checked++))
      if [[ -n "$block" && -n "$start_time" && -n "$finish_time" ]]; then
        ((valid_count++))
      fi
    done
  fi

  # Process latest finished-proof line (repeat logic for most recent entry)
  last_comp="--"
  fp_line=$(LC_ALL=C tr -d '\000' <"$log_file" | grep -a 'finished-proof' | sed 's/\x1B\[[0-9;]*m//g' | tail -n 1)
  block=$(echo "$fp_line" | tr -d '\000' | sed 's/\x1B\[[0-9;]*m//g' | grep -oE '[0-9]+(\.[0-9]+){4,}' | tr -d '\000' | head -n 1)
  finish_time=$(echo "$fp_line" | tr -d '\000' | grep -oP '\(\K[0-9]{2}:[0-9]{2}:[0-9]{2}')
  if [[ -n "$block" && -n "$finish_time" ]]; then
    mline=$(strings "$log_file" | grep "mining-on" | grep "$block" | tail -n 1 | tr -d '\000')
    if [[ -z "$mline" ]]; then
      block_hex=$(echo -n "$block" | xxd -p)
      xxd -p "$log_file" | tr -d '\n' >/tmp/${miner}.hex
      offset=$(grep -ob "$block_hex" /tmp/${miner}.hex | cut -d: -f1 | head -n 1 | tr -d '\000')
      if [[ -n "$offset" ]]; then
        start=$((offset - 2000))
        [[ "$start" -lt 0 ]] && start=0
        dd if=/tmp/${miner}.hex bs=1 skip=$start count=3000 2>/dev/null | xxd -r -p >/tmp/${miner}_pre.log
        mline=$(grep -a 'mining-on' /tmp/${miner}_pre.log | tail -n 1 | tr -d '\000')
      fi
    fi
    start_time=$(echo "$mline" | tr -d '\000' | sed 's/\x1B\[[0-9;]*m//g' | awk '/mining-on/ { match($0, /\([0-9]{2}:[0-9]{2}:[0-9]{2}\)/); if (RSTART > 0) print substr($0, RSTART+1, RLENGTH-2); exit }')
    if [[ -n "$start_time" ]]; then
      comp=$(($(date -d "$finish_time" +%s) - $(date -d "$start_time" +%s)))
      # Check for duplicate before appending
      if ! grep -Fq ",$finish_time,$block," <(tail -n +2 "$proof_csv"); then
        echo "$start_time,$finish_time,$block,$comp" >>"$proof_csv"
        sync "$proof_csv"
      fi
      last_comp="$comp"
    fi
  fi

  # Calculate average comp_time of last 50 entries sorted by finish_time
  avg_comp="--"
  if [[ -f "$proof_csv" ]]; then
    avg_comp=$(tail -n +2 "$proof_csv" | awk -F, '{print $2","$4}' | sort | tail -n 50 | awk -F, '{sum+=$2; count++} END {if(count>0) printf("%.1f", sum/count); else print "--"}')
  fi

  echo "${last_comp}|${avg_comp}"
}

get_block_deltas() {
  local miner=$1
  local log_file="$NOCKCHAIN_HOME/$miner/$miner.log"
  local block_csv="$NOCKCHAIN_HOME/$miner/${miner}_block_log.csv"
  local last_blk="--"
  local avg_blk="--"

  # Ensure CSV exists and has header
  if [[ ! -f "$block_csv" ]]; then
    echo "timestamp,block" >"$block_csv"
    sync "$block_csv"
  fi

  # Determine if we should skip the bulk loop (if CSV exists and last entry is newer than 1 hour)
  skip_bulk=0
  if [[ -f "$block_csv" ]]; then
    last_ts=$(tail -n 1 "$block_csv" | awk -F, '{print $1}')
    if [[ -n "$last_ts" ]]; then
      last_ts_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if ((now_epoch - last_ts_epoch < 3600)); then
        skip_bulk=1
      fi
    fi
  fi

  # Parse log for lines containing only 'added to validated blocks at' with timestamp and block
  mapfile -t validated_block_lines < <(
    grep -a 'added to validated blocks at' "$log_file" | tail -n 200
  )

  # Only run the bulk parsing loop if skip_bulk is not set
  if [[ "$skip_bulk" -eq 0 ]]; then
    local -a entries=()
    local count=0
    for ((idx = ${#validated_block_lines[@]} - 1; idx >= 0 && count < 50; idx--)); do
      local line="${validated_block_lines[idx]}"
      # Extract timestamp in (HH:MM:SS)
      local ts=$(echo "$line" | grep -oP '\(\K[0-9]{2}:[0-9]{2}:[0-9]{2}')
      local blk
      blk=$(echo "$line" | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)')
      if [[ -z "$ts" || -z "$blk" ]]; then
        continue
      fi
      # Avoid duplicates: only append if this (ts,blk) is not already present
      today=$(date +%Y-%m-%d)
      if [[ "$ts" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        full_ts="$today $ts"
      else
        full_ts="$ts"
      fi
      if ! grep -q "^$full_ts,$blk\$" "$block_csv"; then
        echo "$full_ts,$blk" >>"$block_csv"
        # Deduplicate: preserve the header, sort and dedupe only data lines
        header=$(head -n 1 "$block_csv")
        tail -n +2 "$block_csv" | awk -F, '!seen[$2]++' | sort -t, -k2,2V >"$block_csv.sorted"
        echo "$header" >"$block_csv"
        cat "$block_csv.sorted" >>"$block_csv"
        rm -f "$block_csv.sorted"
        sync "$block_csv"
      fi
      entries+=("$full_ts,$blk")
      ((count++))
    done
  fi

  # Always check the very latest 'added to validated blocks at' log line and add if new
  latest_log_line=$(grep -a 'added to validated blocks at' "$log_file" | tail -n 1)
  if [[ -n "$latest_log_line" ]]; then
    latest_ts=$(echo "$latest_log_line" | grep -oP '\(\K[0-9]{2}:[0-9]{2}:[0-9]{2}')
    latest_blk=$(echo "$latest_log_line" | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)')
    if [[ -n "$latest_ts" && -n "$latest_blk" ]]; then
      today=$(date +%Y-%m-%d)
      if [[ "$latest_ts" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        full_ts="$today $latest_ts"
      else
        full_ts="$latest_ts"
      fi
      # Only add if not already present (avoid duplicates)
      if ! grep -q "^$full_ts,$latest_blk\$" "$block_csv"; then
        echo "$full_ts,$latest_blk" >>"$block_csv"
        # Deduplicate as in bulk section
        header=$(head -n 1 "$block_csv")
        tail -n +2 "$block_csv" | awk -F, '!seen[$2]++' | sort -t, -k2,2V >"$block_csv.sorted"
        echo "$header" >"$block_csv"
        cat "$block_csv.sorted" >>"$block_csv"
        rm -f "$block_csv.sorted"
        sync "$block_csv"
      fi
    fi
  fi

  # Now, read all valid entries from CSV, sorted oldest to newest, and only last 20
  mapfile -t csv_entries < <(tail -n +2 "$block_csv" | tail -n 20 | sort)
  local n_csv=${#csv_entries[@]}
  if ((n_csv == 0)); then
    echo "${last_blk}|${avg_blk}"
    return
  fi

  # Find the entry with the highest block number (ignoring order) and use its timestamp
  local max_blk_numeric=0
  local ts_for_max_blk=""
  for entry in "${csv_entries[@]}"; do
    ts=$(echo "$entry" | cut -d, -f1)
    blk=$(echo "$entry" | cut -d, -f2)
    blk_numeric=$(echo "$blk" | tr -d '.' | sed 's/^0*//')
    if [[ "$blk_numeric" =~ ^[0-9]+$ ]] && ((blk_numeric > max_blk_numeric)); then
      max_blk_numeric=$blk_numeric
      ts_for_max_blk="$ts"
    fi
  done

  # Calculate last_blk: seconds since highest block in CSV
  if [[ -n "$ts_for_max_blk" ]]; then
    local now_epoch=$(date +%s)
    local last_epoch=$(date -d "$ts_for_max_blk" +%s 2>/dev/null || echo "")
    if [[ -n "$last_epoch" ]]; then
      last_blk=$((now_epoch - last_epoch))
    fi
  fi

  # Calculate avg_blk: average interval between consecutive timestamps
  if ((n_csv > 1)); then
    local prev_epoch=""
    local sum=0
    local deltas=0
    for entry in "${csv_entries[@]}"; do
      local ts=$(echo "$entry" | cut -d, -f1)
      local epoch=$(date -d "$ts" +%s 2>/dev/null || echo "")
      if [[ -n "$prev_epoch" && -n "$epoch" ]]; then
        local delta=$((epoch - prev_epoch))
        if ((delta > 0)); then
          sum=$((sum + delta))
          ((deltas++))
        fi
      fi
      prev_epoch=$epoch
    done
    if ((deltas > 0)); then
      avg_blk=$(awk -v s="$sum" -v c="$deltas" 'BEGIN { if(c>0) printf("%.1f", s/c); else print "--" }')
    fi
  fi
  echo "${last_blk}|${avg_blk}"
}

get_latest_statejam_block() {
  local block="--"
  local mins="--"
  # Grab latest block from backup log and journalctl, pick the highest
  block=$(
    {
      cat "$NOCKCHAIN_HOME/statejam_backup.log" 2>/dev/null
      journalctl -u nockchain-statejam-backup.service --no-pager -o cat 2>/dev/null
    } |
      grep -a 'Exported state.jam from block' |
      sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g' |
      grep -oP 'block\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' |
      sort -V | tail -n 1
  )
  [[ -z "$block" ]] && block="--"
  # Calculate next save
  if pgrep -f export_latest_state_jam.sh >/dev/null 2>&1; then
    mins="running"
  else
    now_min=$(date +%M)
    if [[ "$now_min" =~ ^[0-9]+$ ]]; then
      mins=$((60 - 10#$now_min))
      [[ "$mins" -eq 60 ]] && mins=0
    fi
  fi
  echo "$block|$mins"
}

NCK_DIR="$NOCKCHAIN_HOME"
NCK_BIN="$NOCKCHAIN_BIN"

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
  echo -e "${DIM}Welcome to the Nockchain Node Manager.${RESET}"

  # Extract network height from all miner logs (for dashboard)
  NETWORK_HEIGHT="--"
  all_blocks=()
  for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
    [[ -d "$miner_dir" ]] || continue
    miner_label=$(basename "$miner_dir" | sed -nE 's/^(miner[0-9]+)$/\1/p')
    [[ -z "$miner_label" ]] && continue
    log_file="$miner_dir/${miner_label}.log"

    if [[ -f "$log_file" && -r "$log_file" ]]; then
      heard_block=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || true)
      validated_block=$(grep -a 'added to validated blocks at' "$log_file" | tail -n 5 | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || true)
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
  for i in $(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner[0-9]*" 2>/dev/null | sed -nE 's/^.*\/(miner[0-9]+)$/\1/p' | sed -nE 's/^miner([0-9]+)$/\1/p' | sort -n); do
    if [[ "$(check_service_status "nockchain-miner$i")" == "active" ]]; then
      ((RUNNING_MINERS = RUNNING_MINERS + 1))
    fi
  done
  if [[ -d "$NOCKCHAIN_HOME" ]]; then
    MINER_FOLDERS=$(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner[0-9]*" 2>/dev/null | wc -l)
  else
    MINER_FOLDERS=0
  fi

  if ((RUNNING_MINERS > 0)); then
    echo -e "${GREEN}🟢 $RUNNING_MINERS active miners${RESET} ${DIM}($MINER_FOLDERS total miners)${RESET}"
  else
    echo -e "${RED}🔴 No miners running${RESET} ${DIM}($MINER_FOLDERS total miners)${RESET}"
  fi

  # Show live state.jam status using new get_statejam_status
  output=$(get_latest_statejam_block | tr '|' ' ' 2>/dev/null || echo "-- --")
  read latest_statejam_blk latest_statejam_mins <<<"$output"
  blk_disp="${latest_statejam_blk:---}"
  min_disp="${latest_statejam_mins:---}"

  if systemctl is-active --quiet nockchain-statejam-backup.timer; then
    echo -e "${GREEN}🟢 state.jam: block $blk_disp, next in ${min_disp}m${RESET}"
  else
    echo -e "${RED}🔴 state.jam: backup inactive${RESET}"
  fi

  # Display current version of node and launcher, and update status
  echo ""
  VERSION="(not installed)"
  NODE_STATUS="${YELLOW}Not installed${RESET}"

  if [[ -d "$NOCKCHAIN_HOME" && -d "$NOCKCHAIN_HOME/.git" ]]; then
    cd "$NOCKCHAIN_HOME"
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

  if [[ -d "$NOCKCHAIN_HOME" ]]; then
    if [[ -f "$NOCKCHAIN_HOME/.env" ]]; then
      if grep -q "^MINING_PUBKEY=" "$NOCKCHAIN_HOME/.env"; then
        MINING_KEY_DISPLAY=$(grep "^MINING_PUBKEY=" "$NOCKCHAIN_HOME/.env" 2>/dev/null | cut -d= -f2)
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
    "1) Install Nockchain from scratch" "21) Run system diagnostics" \
    "2) Update nockchain to latest version" "22) Monitor resource usage (htop)" \
    "3) Update nockchain-wallet only" "23) Edit launcher settings" \
    "4) Update launcher script" "" \
    "5) Export or download state.jam file" "" \
    "6) Manage periodic state.jam backup" ""

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
  echo -e "${DIM}Tip: Use ${BOLD_BLUE}systemctl status nockchain-minerX${DIM} to check miner status, and ${BOLD_BLUE}tail -f $NOCKCHAIN_HOME/minerX/minerX.log${DIM} to view logs. Use ${BOLD_BLUE}sudo systemctl stop nockchain-minerX${DIM} to stop a miner.${RESET}"
  read USER_CHOICE

  # Define important paths for binaries and logs
  BINARY_PATH="$NOCKCHAIN_BIN"
  LOG_PATH="$NOCKCHAIN_HOME/build.log"

  if [[ -z "$USER_CHOICE" ]]; then
    echo -e "${CYAN}Exiting launcher. Goodbye!${RESET}"
    exit 0
  fi

  case "$USER_CHOICE" in
  23)
    clear
    while true; do
      echo -e "${CYAN}Edit Launcher Settings${RESET}"
      echo ""
      echo -e "${YELLOW}Current settings:${RESET}"
      echo -e "  NOCKCHAIN_USER: ${GREEN}$NOCKCHAIN_USER${RESET}"
      echo -e "  NOCKCHAIN_HOME: ${GREEN}$NOCKCHAIN_HOME${RESET}"
      echo -e "  NOCKCHAIN_BIN:  ${GREEN}$NOCKCHAIN_BIN${RESET}"
      echo ""
      menu_entries=(
        "↩️  Cancel and return to main menu"
        "Edit NOCKCHAIN_BIN   [current: $NOCKCHAIN_BIN]"
        "Edit NOCKCHAIN_HOME  [current: $NOCKCHAIN_HOME]"
        "Edit NOCKCHAIN_USER  [current: $NOCKCHAIN_USER]"
      )
      selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --prompt="Select parameter to edit: " \
        --pointer="👉" --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
        --header=$'\nUse ↑ ↓ arrows to select. ENTER to confirm.\n')
      [[ -z "$selected" || "$selected" == "↩️  Cancel and return to main menu" ]] && break

      if [[ "$selected" == *"NOCKCHAIN_USER"* ]]; then
        read -rp "Enter new NOCKCHAIN_USER (current: $NOCKCHAIN_USER, press Enter to keep): " new_user
        if [[ -n "$new_user" ]]; then
          NOCKCHAIN_USER="$new_user"
          echo -e "${GREEN}NOCKCHAIN_USER updated to '$NOCKCHAIN_USER'!${RESET}"
        else
          echo -e "${YELLOW}No change made.${RESET}"
        fi
      elif [[ "$selected" == *"NOCKCHAIN_HOME"* ]]; then
        read -rp "Enter new NOCKCHAIN_HOME (current: $NOCKCHAIN_HOME, press Enter to keep): " new_home
        if [[ -n "$new_home" ]]; then
          NOCKCHAIN_HOME="$new_home"
          echo -e "${GREEN}NOCKCHAIN_HOME updated to '$NOCKCHAIN_HOME'!${RESET}"
        else
          echo -e "${YELLOW}No change made.${RESET}"
        fi
      elif [[ "$selected" == *"NOCKCHAIN_BIN"* ]]; then
        read -rp "Enter new NOCKCHAIN_BIN (current: $NOCKCHAIN_BIN, press Enter to keep): " new_bin
        if [[ -n "$new_bin" ]]; then
          NOCKCHAIN_BIN="$new_bin"
          echo -e "${GREEN}NOCKCHAIN_BIN updated to '$NOCKCHAIN_BIN'!${RESET}"
        else
          echo -e "${YELLOW}No change made.${RESET}"
        fi
      fi

      # Always update settings file after any change
      cat >"$SETTINGS_FILE" <<EOF
NOCKCHAIN_USER="$NOCKCHAIN_USER"
NOCKCHAIN_HOME="$NOCKCHAIN_HOME"
NOCKCHAIN_BIN="$NOCKCHAIN_BIN"
EOF
      source "$SETTINGS_FILE"
      sleep 1
      clear
    done
    continue
    ;;
  6)
    clear
    require_nockchain || continue
    # Toggle systemd timer for periodic state.jam backup
    BACKUP_SERVICE_FILE="/etc/systemd/system/nockchain-statejam-backup.service"
    BACKUP_TIMER_FILE="/etc/systemd/system/nockchain-statejam-backup.timer"
    BACKUP_SCRIPT="$NOCKCHAIN_HOME/export_latest_state_jam.sh"
    # Ensure fzf is installed
    ensure_fzf_installed
    # Present fzf menu: start/stop/restart/cancel (with improved entries)
    menu_entries=("↩️  Cancel and return to main menu" "🟢 Start backup service" "🔄 Restart backup service" "🔴 Stop backup service")
    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --prompt="Choose action for backup service: " \
      --pointer="👉" --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse ↑ ↓ arrows to select. ENTER to confirm.\nUseful commands:\n  - systemctl status nockchain-statejam-backup.timer\n  - journalctl -u nockchain-statejam-backup.service -e\n')
    [[ -z "$selected" ]] && selected="↩️  Cancel and return to main menu"
    if [[ "$selected" == "↩️  Cancel and return to main menu" ]]; then
      continue
    fi
    # Helper: Create backup script, always overwrite
    create_backup_script() {
      echo "[INFO] Overwriting backup script at $BACKUP_SCRIPT..."
      cat >"$BACKUP_SCRIPT" <<'EOS'
#!/bin/bash
source "$HOME/.nockchain_launcher.conf"
set -euo pipefail

normalize_block() {
  local block="$1"
  if [[ "$block" =~ ^[0-9]{1,3}(\.[0-9]{3})*$ ]]; then
    echo "$block" | tr -d '.'
  else
    echo ""
  fi
}

SRC=""
HIGHEST=0
HIGHEST_BLOCK=""

for d in "$NOCKCHAIN_HOME"/miner[0-9]*; do
  [[ -d "$d" ]] || continue
  miner_name=$(basename "$d" | sed -nE 's/^(miner[0-9]+)$/\1/p')
  [[ -z "$miner_name" ]] && continue
  log="$d/$miner_name.log"
  if [[ -f "$log" ]]; then
    raw_line=$(grep -a 'added to validated blocks at' "$log" 2>/dev/null | tail -n 1 || true)
    blk=$(echo "$raw_line" | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || true)
    # --- BEGIN logging block per miner ---
    if [[ -n "$blk" ]]; then
      echo -e "🟢 Detected $(basename "$d") at block $blk"
    else
      echo -e "⚠️ No valid block found in $(basename "$d")"
    fi
    # --- END logging block per miner ---
    if [[ -n "$blk" ]]; then
      num=$(normalize_block "$blk")
      if (( num > HIGHEST )); then
        HIGHEST=$num
        HIGHEST_BLOCK=$blk
        SRC="$d"
      fi
    fi
  fi
done

if [[ -z "$SRC" ]]; then
  echo "[$(date)] ❌ No suitable miner folder found."
  exit 1
fi

TMP="$NOCKCHAIN_HOME/miner-export"
OUT="$NOCKCHAIN_HOME/state.jam"

# Styled user output
GREEN="\e[32m"
CYAN="\e[36m"
BOLD_BLUE="\e[1;34m"
DIM="\e[2m"
RESET="\e[0m"

echo -e ""
echo -e "${DIM}🔍 Found miner with highest block:${RESET} ${CYAN}$(basename "$SRC")${RESET} at block ${BOLD_BLUE}$HIGHEST_BLOCK${RESET}"
echo -e "${DIM}📁 Creating temporary clone at:${RESET} ${CYAN}$TMP${RESET}"
rm -rf "$TMP"
cp -a "$SRC" "$TMP"

cd "$TMP"
echo -e "${DIM}🧠 Running export-state-jam command...${RESET}"
"$NOCKCHAIN_BIN" --export-state-jam "$OUT"
cd "$NOCKCHAIN_HOME"

echo -e ""
echo -e "${DIM}🧹 Cleaning up temporary folder...${RESET}"
rm -rf "$TMP"

echo -e "${GREEN}✅ Exported state.jam from block ${BOLD_BLUE}$HIGHEST_BLOCK${GREEN} to ${CYAN}$OUT${RESET}"
echo "Exported state.jam from block $HIGHEST_BLOCK at $(date '+%Y-%m-%d %H:%M:%S')" >> "$NOCKCHAIN_HOME/statejam_backup.log"

EOS
      chmod +x "$BACKUP_SCRIPT"
      if [[ ! -x "$BACKUP_SCRIPT" ]]; then
        chmod +x "$BACKUP_SCRIPT"
      fi
    }
    # Helper: Write systemd service/timer
    create_backup_systemd_files() {
      sudo bash -c "cat > '$BACKUP_SERVICE_FILE'" <<EOS
[Unit]
Description=Export latest state.jam from all miners to $NOCKCHAIN_HOME/state.jam
After=network-online.target

[Service]
Type=oneshot
User=$NOCKCHAIN_USER
ExecStart=$NOCKCHAIN_HOME/export_latest_state_jam.sh

[Install]
WantedBy=multi-user.target
EOS
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
    }
    # Helper: Enable and start timer
    enable_and_start_timer() {
      sudo systemctl enable --now nockchain-statejam-backup.timer
      if ! systemctl list-timers --all | grep -q "nockchain-statejam-backup.timer"; then
        echo -e "${RED}❌ Failed to enable backup timer.${RESET}"
        return 1
      fi
      return 0
    }
    # Helper: Stop and disable timer
    stop_and_disable_timer() {
      sudo systemctl stop nockchain-statejam-backup.timer
      sudo systemctl disable nockchain-statejam-backup.timer
    }
    # Helper: Dry run log streaming
    dry_run_and_stream_log() {
      echo -e "${CYAN}▶ Running backup script manually to verify setup...${RESET}"
      echo -e "${CYAN}▶ Output log: ${DIM}$NOCKCHAIN_HOME/statejam_backup.log${RESET}"
      rm -f "$NOCKCHAIN_HOME/statejam_backup.log"
      touch "$NOCKCHAIN_HOME/statejam_backup.log"

      echo -e ""
      "$BACKUP_SCRIPT" 2>&1 | tee -a "$NOCKCHAIN_HOME/statejam_backup.log"
      echo ""
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
    }
    # Handle selection
    if [[ "$selected" == "🟢 Start backup service" ]]; then
      clear
      echo -e "${CYAN}▶ Creating backup script...${RESET}"
      create_backup_script
      if [[ ! -f "$BACKUP_SCRIPT" || ! -x "$BACKUP_SCRIPT" ]]; then
        echo -e "${RED}❌ Export script was not created. Aborting.${RESET}"
        read -n 1 -s
        continue
      fi
      echo -e "${CYAN}▶ Writing systemd service and timer files...${RESET}"
      create_backup_systemd_files
      if enable_and_start_timer; then
        echo -e "${CYAN}▶ Starting backup timer service...${RESET}"
        echo -e ""
        echo -e "${CYAN}▶ Backup service setup complete.${RESET}"
        echo -e "${CYAN}▶ Service: statejam backup${RESET}"
        echo -e "${CYAN}▶ Status: ENABLED and scheduled every hour${RESET}"
        echo -e "${CYAN}▶ Backup script: ${DIM}$BACKUP_SCRIPT${RESET}"
        echo -e "${CYAN}▶ Target location: ${DIM}$NOCKCHAIN_HOME/state.jam${RESET}"
        echo -e ""
        echo -e "${CYAN}▶ Performing dry run to verify backup...${RESET}"
        dry_run_and_stream_log
      else
        echo -e "${RED}❌ Failed to enable/launch backup timer.${RESET}"
        read -n 1 -s
        continue
      fi
      continue
    elif [[ "$selected" == "🔴 Stop backup service" ]]; then
      clear
      echo -e "${CYAN}🛑 Stopping periodic state.jam backup service...${RESET}"
      stop_and_disable_timer
      echo -e "${GREEN}✅ Disabled nockchain-statejam-backup.timer${RESET}"
      echo -e "${GREEN}✅ Periodic state.jam backup is now DISABLED.${RESET}"
      echo ""
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    elif [[ "$selected" == "🔄 Restart backup service" ]]; then
      clear
      echo -e "${CYAN}▶ Stopping backup service if running...${RESET}"
      stop_and_disable_timer
      echo -e "${BOLD_BLUE}▶ Creating backup script...${RESET}"
      rm -f "$BACKUP_SCRIPT"
      create_backup_script
      if [[ ! -f "$BACKUP_SCRIPT" || ! -x "$BACKUP_SCRIPT" ]]; then
        echo -e "${RED}❌ Export script was not created. Aborting.${RESET}"
        read -n 1 -s
        continue
      fi
      echo -e "${CYAN}▶ Writing systemd service and timer files...${RESET}"
      rm -f "$BACKUP_SERVICE_FILE" "$BACKUP_TIMER_FILE"
      create_backup_systemd_files
      if enable_and_start_timer; then
        echo -e "${CYAN}▶ Starting backup timer service...${RESET}"
        echo -e ""
        echo -e "${CYAN}▶ Backup service setup complete.${RESET}"
        echo -e "${CYAN}▶ Service: statejam backup${RESET}"
        echo -e "${CYAN}▶ Status: ENABLED and scheduled every hour${RESET}"
        echo -e "${CYAN}▶ Backup script:${RESET} ${DIM}$BACKUP_SCRIPT${RESET}"
        echo -e "${CYAN}▶ Target location: ${DIM}$NOCKCHAIN_HOME/state.jam${RESET}"
        echo -e ""
        echo -e "${CYAN}▶ Performing dry run to verify backup...${RESET}"
        dry_run_and_stream_log
      else
        echo -e "${RED}❌ Failed to enable/launch backup timer.${RESET}"
        read -n 1 -s
        continue
      fi
      continue
    fi
    ;;
  5)
    clear
    require_nockchain || continue
    miner_dirs=$(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner[0-9]*" | sort -V)
    ensure_fzf_installed

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
    declare -A miner_blocks_map

    # Fetch latest commit message that modified state.jam (uses jq and grep for block version)
    GITHUB_COMMIT_MSG=$(curl -fsSL "https://api.github.com/repos/jobless0x/nockchain-launcher/commits?path=state.jam" 2>/dev/null |
      jq -r '.[0].commit.message' | grep -oE 'block [0-9]+\.[0-9]+')

    if [[ "$GITHUB_COMMIT_MSG" =~ block[[:space:]]+([0-9]+\.[0-9]+) ]]; then
      BLOCK_COMMIT_VERSION="${BASH_REMATCH[1]}"
    else
      BLOCK_COMMIT_VERSION="unknown"
    fi
    GITHUB_COMMIT_DISPLAY="📦 Download latest state.jam from GitHub (block $BLOCK_COMMIT_VERSION)"
    GD_COMMIT_DISPLAY="📥 Download latest state.jam from Google Drive (official)"

    for dir in $miner_dirs; do
      [[ -d "$dir" ]] || continue
      miner_name=$(basename "$dir" | sed -nE 's/^(miner[0-9]+)$/\1/p')
      [[ -z "$miner_name" ]] && continue
      log_path="$dir/${miner_name}.log"
      latest_block="--"
      if [[ -f "$log_path" ]]; then
        latest_block=$(extract_latest_block "$log_path")
      fi
      if systemctl is-active --quiet "nockchain-${miner_name}"; then
        status_icon="🟢"
      else
        status_icon="🔴"
      fi
      label="$(styled_menu_entry "$status_icon" "$miner_name" "$latest_block")"
      menu_entries+=("$label")
      miner_dirs_map["$miner_name"]="$dir"
      miner_blocks_map["$miner_name"]="$latest_block"
    done
    menu_entries=("↩️  Cancel and return to menu" "$GD_COMMIT_DISPLAY" "$GITHUB_COMMIT_DISPLAY" "${menu_entries[@]}")

    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --prompt="Select miner to export from: " \
      --pointer="👉" --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse ↑ ↓ arrows to navigate. ENTER to confirm.\n')

    if [[ "$selected" == *"Google Drive"* ]]; then
      clear
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
      TMP_CLONE="$NOCKCHAIN_HOME/tmp_drive_download"
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
        echo -e "${CYAN}📦 Step 3/4: Moving state.jam to $NOCKCHAIN_HOME and cleaning up...${RESET}"
        mv "$TMP_CLONE/state.jam" "$NOCKCHAIN_HOME/state.jam"
        rm -rf "$TMP_CLONE"
        echo -e "${GREEN}✅ state.jam downloaded and saved to ${CYAN}$NOCKCHAIN_HOME/state.jam${GREEN}.${RESET}"
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

tmp_clone = os.environ.get("TMP_CLONE", os.path.expanduser("$NOCKCHAIN_HOME/tmp_drive_download"))
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
      echo -e "${DIM}Found $(wc -l <"$TMP_CLONE/jam_files.txt") .jam file(s).${RESET}"
      echo -e "${DIM}Discovered .jam files with IDs:${RESET}"
      while IFS=$'\t' read -r id name; do
        # echo "[DEBUG] raw line: $id $name"
        [[ -z "$id" || -z "$name" || "$name" != *.jam ]] && continue
        block=$(echo "$name" | grep -oE '[0-9]+')
        echo -e "${CYAN}- $name${RESET} ${DIM}(block $block, id=$id)${RESET}"
      done <"$TMP_CLONE/jam_files.txt"
      # Extract full metadata list and pick true latest based on numeric block
      latest_block=-1
      latest_id=""
      latest_name=""
      while IFS=$'\t' read -r id name; do
        block=$(echo "$name" | grep -oE '[0-9]+')
        [[ -z "$id" || -z "$name" || -z "$block" ]] && continue
        if ((block > latest_block)); then
          latest_block=$block
          latest_id=$id
          latest_name=$name
        fi
      done <"$TMP_CLONE/jam_files.txt"
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
      echo -e "${CYAN}📦 Step 4/4: Moving state.jam to $NOCKCHAIN_HOME and cleaning up...${RESET}"
      mv "$TMP_CLONE/state.jam" "$NOCKCHAIN_HOME/state.jam"
      rm -rf "$TMP_CLONE"
      echo -e "${GREEN}✅ state.jam downloaded and saved to ${CYAN}$NOCKCHAIN_HOME/state.jam${GREEN} (block $latest_block).${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi

    if [[ "$selected" == *"Download latest state.jam from GitHub"* ]]; then
      clear
      echo -e "${CYAN}📥 Step 1/3: Create temp folder, Initializing Git and GIT LFS...${RESET}"
      TMP_CLONE="$NOCKCHAIN_HOME/tmp_launcher_clone"
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
        git lfs pull --include="state.jam" 2>&1 | grep --line-buffered -v 'Downloading LFS objects:' | pv -lep -s 1100000000 -N "state.jam" >/dev/null
        # Check LFS pull exit code
        if [[ $? -ne 0 ]]; then
          echo -e "${RED}❌ Failed to download state.jam from GitHub. LFS quota likely exceeded.${RESET}"
          echo -e "${YELLOW}You can try downloading from Google Drive instead (option 5 > Google Drive).${RESET}"
          echo -e "${CYAN}Press Enter to return to the main menu...${RESET}"
          read
          continue
        fi
        echo -e "${GREEN}✅ Download complete.${RESET}"
      else
        echo -e "${CYAN}🔄 Downloading state.jam...${RESET}"
        git lfs pull --include="state.jam"
        if [[ $? -ne 0 ]]; then
          echo -e "${RED}❌ Failed to download state.jam from GitHub. LFS quota likely exceeded.${RESET}"
          echo -e "${YELLOW}You can try downloading from Google Drive instead (option 5 > Google Drive).${RESET}"
          echo -e "${CYAN}Press Enter to return to the main menu...${RESET}"
          read
          continue
        fi
        echo -e "${GREEN}✅ Download complete.${RESET}"
      fi
      trap - INT

      if [[ ! -f "state.jam" ]]; then
        echo -e "${RED}❌ state.jam not found after LFS pull. Exiting.${RESET}"
        read -n 1 -s
        continue
      fi

      echo ""
      echo -e "${CYAN}📦 Step 4/4: Moving state.jam to $NOCKCHAIN_HOME and cleaning up...${RESET}"
      mv "state.jam" "$NOCKCHAIN_HOME/state.jam"
      rm -rf "$TMP_CLONE"

      echo -e "${GREEN}✅ state.jam downloaded and saved to ${CYAN}$NOCKCHAIN_HOME/state.jam${GREEN}.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi

    selected_miner=$(echo "$selected" | sed -nE 's/.*(miner[0-9]+).*/\1/p' | head -n 1 || true)
    if [[ -z "$selected_miner" || ! "$selected_miner" =~ ^miner[0-9]+$ || -z "${miner_dirs_map[$selected_miner]:-}" ]]; then
      echo -e "${YELLOW}No valid selection made. Returning to menu...${RESET}"
      continue
    fi

    clear
    select_dir="${miner_dirs_map[$selected_miner]}"
    miner_name=$(basename "$select_dir")
    export_dir="$NOCKCHAIN_HOME/miner-export"
    state_output="$NOCKCHAIN_HOME/state.jam"

    exported_block="${miner_blocks_map[$selected_miner]:-unknown}"

    echo -e "${CYAN}Creating temporary copy of $miner_name for safe export...${RESET}"
    rm -rf "$export_dir"
    cp -a "$select_dir" "$export_dir"

    echo -e "${CYAN}Exporting state.jam to $state_output...${RESET}"
    echo -e "${DIM}Log will be saved to $NOCKCHAIN_HOME/export.log${RESET}"
    cd "$export_dir"
    echo ""
    echo -e "${CYAN}Running export process...${RESET}"
    "$NOCKCHAIN_BIN" --export-state-jam "$state_output" 2>&1 | tee "$NOCKCHAIN_HOME/export.log"
    cd "$NOCKCHAIN_HOME"
    rm -rf "$export_dir"

    echo ""
    echo -e "${GREEN}✅ Exported state.jam from duplicate of ${CYAN}$selected_miner${GREEN} (block ${BOLD_BLUE}$exported_block${GREEN}) to ${CYAN}$state_output${GREEN}.${RESET}"
    echo -e "${DIM}To view detailed export logs: tail -n 20 $NOCKCHAIN_HOME/export.log${RESET}"
    echo ""
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
    [[ -x "$NOCKCHAIN_BIN" ]] && echo -e "${GREEN}✔ nockchain binary present${RESET}" || echo -e "${RED}❌ nockchain binary missing${RESET}"
    [[ -x "$HOME/.cargo/bin/nockchain-wallet" ]] && echo -e "${GREEN}✔ nockchain-wallet present${RESET}" || echo -e "${RED}❌ nockchain-wallet missing${RESET}"
    echo ""

    # Diagnostics: Validate .env presence and mining key definition
    echo -e "${CYAN}▶ .env & MINING_PUBKEY${RESET}"
    echo -e "${DIM}-----------------------${RESET}"
    if [[ -f "$NOCKCHAIN_HOME/.env" ]]; then
      echo -e "${GREEN}✔ .env file found${RESET}"
      if grep -q "^MINING_PUBKEY=" "$NOCKCHAIN_HOME/.env"; then
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
    miner_count=$(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner[0-9]*" 2>/dev/null | wc -l)
    if ((miner_count > 0)); then
      echo -e "${GREEN}✔ $miner_count miner folder(s) found${RESET}"
    else
      echo -e "${RED}❌ No miner folders found${RESET}"
    fi
    echo ""

    # Diagnostics: Compare local vs remote git commit hash
    echo -e "${CYAN}▶ Nockchain Repository${RESET}"
    echo -e "${DIM}----------------------${RESET}"
    if [[ ! -d "$NOCKCHAIN_HOME" ]]; then
      echo -e "${YELLOW}Nockchain is not installed yet.${RESET}"
    elif [[ ! -d "$NOCKCHAIN_HOME/.git" ]]; then
      echo -e "${YELLOW}Nockchain exists but is not a Git repository.${RESET}"
    elif git -C "$NOCKCHAIN_HOME" rev-parse &>/dev/null; then
      BRANCH=$(git -C "$NOCKCHAIN_HOME" rev-parse --abbrev-ref HEAD)
      REMOTE_URL=$(git -C "$NOCKCHAIN_HOME" config --get remote.origin.url)
      LOCAL_HASH=$(git -C "$NOCKCHAIN_HOME" rev-parse "$BRANCH")
      REMOTE_HASH=$(git -C "$NOCKCHAIN_HOME" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')

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
    confirm_yes_no "Are you sure you want to continue?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }

    # Handle sudo and root system preparation
    if [ "$(id -u)" -eq 0 ]; then
      echo -e "${YELLOW}>> Running as root. Updating system and installing sudo...${RESET}"
      apt-get update && apt-get upgrade -y

      if ! command -v sudo &>/dev/null; then
        apt-get install sudo -y
      fi
    fi

    if [ ! -f "$BINARY_PATH" ]; then
      echo -e "${YELLOW}>> Nockchain not built yet. Starting Phase 1 (Build)...${RESET}"

      echo -e "${CYAN}>> Installing system dependencies...${RESET}"
      sudo apt-get update && sudo apt-get upgrade -y
      sudo apt install -y curl iptables build-essential ufw screen git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libclang-dev llvm-dev

      if [[ ! -f "$HOME/.cargo/env" ]]; then
        echo -e "${YELLOW}⚠️  .cargo/env missing. Installing Rust using rustup...${RESET}"
        if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
          echo -e "${RED}❌ Rust installation failed. Aborting.${RESET}"
          exit 1
        fi
      fi

      if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
      else
        echo -e "${RED}❌ Rust environment setup failed. Aborting.${RESET}"
        exit 1
      fi

      echo -e "${CYAN}>> Cloning Nockchain repo and starting build...${RESET}"
      rm -rf "$NOCKCHAIN_HOME" "$HOME/.nockapp"
      git clone https://github.com/zorp-corp/nockchain "$NOCKCHAIN_HOME"
      cd "$NOCKCHAIN_HOME"
      cp .env_example .env

      safe_kill_screen "nockbuild"

      echo -e "${CYAN}>> Launching build in screen session 'nockbuild' and logging to build.log...${RESET}"
      screen -dmS nockbuild bash -c "cd \$NOCKCHAIN_HOME && { make install-hoonc && make build && make install-nockchain-wallet && make install-nockchain; } 2>&1 | tee \$NOCKCHAIN_HOME/build.log"

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
    confirm_yes_no "Continue?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }

    safe_kill_screen "nockupdate"

    MINING_KEY_DISPLAY=$(grep "^MINING_PUBKEY=" "$NOCKCHAIN_HOME/.env" | cut -d= -f2)
    echo -e "${CYAN}>> Launching update and miner restart in screen session 'nockupdate'...${RESET}"
    screen -dmS nockupdate bash -c "
      cd \$NOCKCHAIN_HOME && \
      git reset --hard HEAD && \
      git pull && \
      make install-nockchain && \
      export PATH=\"\$HOME/.cargo/bin:\$PATH\" && \
      if tmux ls 2>/dev/null | grep -q '^miner'; then
        echo '>> Killing tmux miner sessions...'
        tmux ls 2>/dev/null | grep '^miner' | cut -d: -f1 | xargs -r -n1 tmux kill-session -t
      fi && \
      for d in \$NOCKCHAIN_HOME/miner*; do
        bash \"$NOCKCHAIN_HOME_launcher.sh\" --restart-miner \"\$d\" \"$MINING_KEY_DISPLAY\"
      done
      echo 'Update and restart complete.'
      exec bash
    "
    echo ""
    echo -e "${GREEN}✅ Update and miner restart process started.${RESET}"
    echo -e "${CYAN}📺 Screen session: ${DIM}nockupdate${RESET}"
    echo ""
    echo -e "${YELLOW}▶ To monitor progress:${RESET}"
    echo -e "${DIM}   screen -r nockupdate${RESET}"
    echo ""
    echo -e "${YELLOW}▶ To exit the screen without stopping it:${RESET}"
    echo -e "${DIM}   Press Ctrl+A then D${RESET}"
    echo ""

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
    confirm_yes_no "Continue?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }

    safe_kill_screen "walletupdate"

    echo -e "${CYAN}>> Launching wallet update in screen session 'walletupdate'...${RESET}"
    screen -dmS walletupdate bash -c "
      cd \$NOCKCHAIN_HOME && \
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
    confirm_yes_no "Continue?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }

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
    require_nockchain || continue
    echo -e "${YELLOW}You are about to configure and launch one or more miners.${RESET}"
    confirm_yes_no "Do you want to continue with miner setup?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }
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
    cat >"$RUN_MINER_SCRIPT" <<'EOS'
#!/bin/bash
source "$HOME/.nockchain_launcher.conf"
set -eux
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

id=${1:-0}
if [[ -z "$id" || "$id" -lt 1 || "$id" -gt 999 ]]; then
  echo "Invalid miner ID: $id"
  exit 1
fi

DIR="$NOCKCHAIN_HOME/miner$id"
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

# --- BEGIN PATCH: Extract MINE_FLAG ---
MINE_FLAG=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^MINE_FLAG=/ {
    sub(/^MINE_FLAG=/, "")
    print
    exit
  }
' "$SCRIPT_DIR/launch.cfg")
# --- END PATCH: Extract MINE_FLAG ---

# --- BEGIN PATCH: Extract EXTRA_FLAGS ---
EXTRA_FLAGS=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^EXTRA_FLAGS=/ {
    sub(/^EXTRA_FLAGS=/, "")
    print
    exit
  }
' "$SCRIPT_DIR/launch.cfg")
# --- END PATCH: Extract EXTRA_FLAGS ---

export MINIMAL_LOG_FORMAT=true
export RUST_LOG=info,nockchain=info,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info

LOGFILE="miner${id}.log"
if [ -e "$LOGFILE" ]; then
  DT=$(date +"%Y%m%d_%H%M%S")
  mv "$LOGFILE" miner${id}-$DT.log
fi

## --- BEGIN PATCHED BLOCK: Updated conditional command construction ---
CMD=("$NOCKCHAIN_BIN")
[[ -n "$MINE_FLAG" ]] && CMD+=($MINE_FLAG)
CMD+=("--mining-pubkey" "$MINING_KEY")
if [[ -n "$BIND_FLAG" && "$BIND_FLAG" != "--bind" ]]; then
  CMD+=($BIND_FLAG)
fi
[[ -n "$MAX_ESTABLISHED" ]] && CMD+=($MAX_ESTABLISHED)
[[ -n "$EXTRA_FLAGS" ]] && CMD+=($EXTRA_FLAGS)
[[ -n "$STATE_FLAG" ]] && CMD+=($STATE_FLAG)
"${CMD[@]}" 2>&1 | tee "$LOGFILE"
## --- END PATCHED BLOCK ---
EOS
    chmod +x "$RUN_MINER_SCRIPT"
    echo -e "${GREEN}✅ run_miner.sh is ready.${RESET}"

    # --- CLI Hook: Allow external --restart-miner <path> <key> ---
    if [[ "${1:-}" == "--restart-miner" && -n "${2:-}" && -n "${3:-}" ]]; then
      MINING_KEY_DISPLAY="$3"
      restart_miner_session "$2"
      exit 0
    fi

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
          echo -e "${CYAN}    - Logs:     ${DIM}tail -f $NOCKCHAIN_HOME/minerX/minerX.log${RESET}"
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
    cd "$NOCKCHAIN_HOME"
    export PATH="$PATH:$(pwd)/target/release"
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "export PATH=\"\$PATH:$(pwd)/target/release\"" >>~/.bashrc
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
        # Prompt for sync-only mode for miner1 if central node
        if [[ "$PEER_MODE" == "2" ]]; then
          echo ""
          echo -e "${YELLOW}Do you want miner1 to run in sync-only mode (without mining)? (y/n)${RESET}"
          while true; do
            read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" SYNC_ONLY_MINER1
            [[ "$SYNC_ONLY_MINER1" =~ ^[YyNn]$ ]] && break
            echo -e "${RED}❌ Please enter y or n.${RESET}"
          done
        fi
        # Prompt for BASE_PORT if needed
        if [[ "$PEER_MODE" == "2" || "$PEER_MODE" == "3" ]]; then
          echo ""
          echo -e "${YELLOW}Enter a base UDP port for miner communication (recommended: 40000):${RESET}"
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" BASE_PORT_INPUT
          BASE_PORT_INPUT=$(echo "$BASE_PORT_INPUT" | tr -d '[:space:]')
          if [[ -z "$BASE_PORT_INPUT" ]]; then
            BASE_PORT=40000
          elif ! [[ "$BASE_PORT_INPUT" =~ ^[0-9]+$ ]] || ((BASE_PORT_INPUT < 1024 || BASE_PORT_INPUT > 65000)); then
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
            [[ "$i" == "1" && "$SYNC_ONLY_MINER1" =~ ^[Yy]$ ]] && echo "MINE_FLAG=" || echo "MINE_FLAG=--mine"
            echo "MINING_KEY=$MINING_KEY"
            echo "BIND_FLAG=${BIND_FLAG_MAP[$MINER_NAME]:-}"
            echo "PEER_FLAG=${PEER_FLAG_MAP[$MINER_NAME]:-}"
            echo "MAX_ESTABLISHED_FLAG=${MAX_ESTABLISHED_FLAG_MAP[$MINER_NAME]:-}"
            if [[ "$PEER_MODE" == "2" && "$i" -gt 1 ]]; then
              echo "EXTRA_FLAGS="
            else
              echo "EXTRA_FLAGS="
            fi
            echo "STATE_FLAG=--state-jam ../state.jam"
          done
        } >"$CONFIG_FILE"
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
          DIR="$NOCKCHAIN_HOME/$MINER_NAME"
          SERVICE="nockchain-miner$i.service"
          RUN_CMD="cd $DIR && exec run_miner.sh $i"
          printf "  ${BOLD_BLUE}%-10s${RESET} %-22s %-22s\n" "$MINER_NAME" "$SERVICE" "$RUN_CMD"
        done
        echo ""
        confirm_yes_no "Start nockchain miner(s)?" || {
          echo -e "${CYAN}Returning to menu...${RESET}"
          continue
        }
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
        echo -e "${CYAN}    - Logs:     ${DIM}tail -f $NOCKCHAIN_HOME/minerX/minerX.log${RESET}"
        echo -e "${CYAN}    - Stop:     ${DIM}sudo systemctl stop nockchain-minerX${RESET}"
        echo -e "${CYAN}    - Start:    ${DIM}sudo systemctl start nockchain-minerX${RESET}"
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
  14)
    clear
    require_nockchain || continue
    ensure_nockchain_executable
    ensure_fzf_installed
    all_miners=()
    for d in "$NOCKCHAIN_HOME"/miner[0-9]*; do
      [ -d "$d" ] || continue
      miner_label=$(basename "$d" | sed -nE 's/^(miner[0-9]+)$/\1/p')
      if [[ -z "$miner_label" ]]; then
        continue
      fi
      miner_num=$(echo "$miner_label" | sed -nE 's/^miner([0-9]+)$/\1/p')
      if [[ -z "$miner_num" ]]; then
        continue
      fi
      if [[ "$(check_service_status "nockchain-miner$miner_num")" == "active" ]]; then
        all_miners+=("🟢 $miner_label")
      else
        all_miners+=("❌ $miner_label")
      fi
    done
    IFS=$'\n' sorted_miners=($(printf "%s\n" "${all_miners[@]}" | sort -k2 -V))
    unset IFS
    # Check if there are any miner directories at all
    if [[ ${#sorted_miners[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No miner directories found. Nothing to restart.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
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
      TARGET_MINERS=$(printf "%s\n" "${sorted_miners[@]}" | sed -nE 's/^[^ ]* (miner[0-9]+)$/\1/p')
    else
      # Extract miner names from styled selection, but only allow full miner[0-9]+
      TARGET_MINERS=$(echo "$selected" | sed -nE 's/.*(miner[0-9]+).*/\1/p' | grep -E '^miner[0-9]+$')
    fi
    # Validate all selected miners
    if [[ -z "$TARGET_MINERS" ]]; then
      echo -e "${YELLOW}No miners selected. Nothing to restart.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi
    # Check all are valid
    for miner in $TARGET_MINERS; do
      if ! [[ "$miner" =~ ^miner[0-9]+$ ]]; then
        echo -e "${YELLOW}Invalid miner selection: $miner. Aborting.${RESET}"
        continue 2
      fi
    done
    clear
    echo -e "${YELLOW}You selected:${RESET}"
    for miner in $TARGET_MINERS; do
      echo -e "${CYAN}- $miner${RESET}"
    done
    confirm_yes_no "Are you sure you want to restart these?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }
    for miner in $TARGET_MINERS; do
      restart_miner_session "$NOCKCHAIN_HOME/$miner"
    done
    echo -e "${CYAN}To check status: ${DIM}systemctl status nockchain-minerX${RESET}"
    echo -e "${CYAN}To view logs:    ${DIM}tail -f $NOCKCHAIN_HOME/minerX/minerX.log${RESET}"
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue

    ;;
  15)
    clear
    ensure_fzf_installed
    all_miners=()
    for d in "$NOCKCHAIN_HOME"/miner[0-9]*; do
      [ -d "$d" ] || continue
      miner_label=$(basename "$d" | sed -nE 's/^(miner[0-9]+)$/\1/p')
      if [[ -z "$miner_label" ]]; then
        continue
      fi
      miner_num=$(echo "$miner_label" | sed -nE 's/^miner([0-9]+)$/\1/p')
      if [[ -z "$miner_num" ]]; then
        continue
      fi
      if [[ "$(check_service_status "nockchain-miner$miner_num")" == "active" ]]; then
        all_miners+=("🟢 $miner_label")
      else
        all_miners+=("❌ $miner_label")
      fi
    done
    IFS=$'\n' sorted_miners=($(printf "%s\n" "${all_miners[@]}" | sort -k2 -V))
    unset IFS
    running_miners=()
    for entry in "${sorted_miners[@]}"; do
      [[ "$entry" =~ ^🟢 ]] && running_miners+=("$entry")
    done
    # Check if there are any running miners at all
    if [[ ${#running_miners[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No running miners found. Nothing to stop.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi
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
      TARGET_MINERS=$(printf "%s\n" "${sorted_miners[@]}" | grep '^🟢' | sed -nE 's/^[^ ]* (miner[0-9]+)$/\1/p')
    else
      TARGET_MINERS=$(echo "$selected" | sed -nE 's/.*(miner[0-9]+).*/\1/p' | grep -E '^miner[0-9]+$')
    fi
    # Validate all selected miners
    if [[ -z "$TARGET_MINERS" ]]; then
      echo -e "${YELLOW}No miners selected. Nothing to stop.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi
    for miner in $TARGET_MINERS; do
      if ! [[ "$miner" =~ ^miner[0-9]+$ ]]; then
        echo -e "${YELLOW}Invalid miner selection: $miner. Aborting.${RESET}"
        continue 2
      fi
    done
    clear
    echo -e "${YELLOW}You selected:${RESET}"
    for miner in $TARGET_MINERS; do
      echo -e "${CYAN}- $miner${RESET}"
    done
    confirm_yes_no "Are you sure you want to stop these?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }
    for miner in $TARGET_MINERS; do
      miner_num=$(echo "$miner" | sed -nE 's/^miner([0-9]+)$/\1/p')
      echo -e "${CYAN}Stopping $miner...${RESET}"
      sudo systemctl stop nockchain-miner$miner_num
      # Check if stop was successful
      if [[ "$(check_service_status "nockchain-miner$miner_num")" != "active" ]]; then
        echo -e "${GREEN}  ✅ $miner stopped successfully.${RESET}"
      else
        echo -e "${RED}  ❌ Failed to stop $miner. Check logs with:${RESET} ${CYAN}journalctl -u nockchain-miner$miner_num -e${RESET}"
      fi
    done
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;
  11)
    clear
    # Check for miner directories before proceeding to live monitor
    miner_dirs=$(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner[0-9]*" 2>/dev/null)
    if [[ -z "$miner_dirs" ]]; then
      echo -e "${YELLOW}No miners found. Nothing to monitor.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi
    # Calculate total system memory in GB for MEM % -> GB conversion (outside the loop, only once)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_GB=$(awk "BEGIN { printf \"%.1f\", $TOTAL_MEM_KB/1024/1024 }")
    while true; do
      # Extract network height from all miner logs (live, every refresh)
      NETWORK_HEIGHT="--"
      all_blocks=()
      for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
        [[ -d "$miner_dir" ]] || continue
        miner_label=$(basename "$miner_dir" | sed -nE 's/^(miner[0-9]+)$/\1/p')
        [[ -z "$miner_label" ]] && continue
        log_file="$miner_dir/${miner_label}.log"
        height=""
        if [[ -f "$log_file" && -r "$log_file" ]]; then
          heard_block=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || true)
          validated_block=$(grep -a 'added to validated blocks at' "$log_file" | tail -n 5 | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || true)
          combined=$(printf "%s\n%s\n" "$heard_block" "$validated_block" | sort -V | tail -n 1)
          if [[ -n "$combined" ]]; then
            all_blocks+=("$combined")
          fi
        fi
      done
      if [[ ${#all_blocks[@]} -gt 0 ]]; then
        NETWORK_HEIGHT=$(printf "%s\n" "${all_blocks[@]}" | sort -V | tail -n 1)
      fi

      # Display latest state.jam export block and next save using get_latest_statejam_block
      read statejam_blk statejam_mins < <(get_latest_statejam_block | tr '|' ' ')
      blk_disp="${statejam_blk:---}"
      min_disp="${statejam_mins:---}"

      tput cup 0 0
      echo -e "${DIM}🖥️  Live Miner Monitor ${RESET}"
      echo ""
      echo -e "${CYAN}📡 Network height: ${RESET}$NETWORK_HEIGHT  |  ${CYAN}Saved state.jam: ${RESET}$blk_disp${DIM}  |  Next save in ${RESET}${YELLOW}${min_disp}${RESET}${DIM}m${RESET}"
      echo ""
      printf "   | %-9s | %-9s | %-9s | %-9s | %-9s | %-9s | %-5s | %-9s | %-6s | %-9s | %-9s | %-9s | %-9s\n" \
        "Miner" "Uptime" "CPU" "MEM" "RAM (GB)" "Block" "Lag" "Status" "Peers" "LastProof" "AvgProof" "BlkAge" "AvgBlk"

      all_miners=()
      for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
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

      # Color variables for peer display
      CYAN="\033[36m"
      BOLD_BLUE="\033[1;34m"
      DIM="\033[2m"
      MAGENTA="\033[35m"
      WHITE="\033[97m"
      RED="\033[31m"
      GREEN="\033[32m"
      YELLOW="\033[33m"
      RESET="\033[0m"

      for session in "${sorted_miners[@]}"; do
        session=$(echo "$session" | sed -nE 's/^(miner[0-9]+)$/\1/p')
        [[ -z "$session" ]] && continue
        miner_dir="$NOCKCHAIN_HOME/$session"
        log_file="$miner_dir/${session}.log"

        # --- INITIALIZE all variables ---
        lag="--"
        lag_int=0
        is_active=0
        icon="${DIM}${RED}❌${RESET}"
        readable="--"
        cpu="--"
        mem="--"
        mem_gb="--"
        latest_block="--"
        peer_count="--"
        last_comp="--"
        avg_comp="--"
        last_blk="--"
        avg_blk="--"
        status_raw="INACTIVE"

        mine_flag=$(awk -v section="[$session]" '
          $0 == section {found=1; next}
          /^\[.*\]/ {found=0}
          found && /^MINE_FLAG=/ {sub(/^MINE_FLAG=/, ""); print; exit}
        ' "$CONFIG_FILE")

        # --- Populate values ---
        proof_metrics=$(update_proof_durations "$session")
        IFS='|' read -r last_comp avg_comp <<<"$proof_metrics"
        last_comp=${last_comp:-"--"}
        avg_comp=${avg_comp:-"--"}

        block_metrics=$(get_block_deltas "$session")
        IFS='|' read -r last_blk avg_blk <<<"$block_metrics"
        last_blk=${last_blk:-"--"}
        avg_blk=${avg_blk:-"--"}

        avg_blk=$(echo "$avg_blk" | tr -d '\n\r')
        [[ -z "$avg_blk" ]] && avg_blk="--"

        if systemctl is-active --quiet nockchain-$session 2>/dev/null; then
          is_active=1
          icon="${GREEN}🟢${RESET}"

          miner_pid=$(systemctl show -p MainPID --value nockchain-$session)
          # Uptime
          if [[ -n "${miner_pid:-}" && "$miner_pid" =~ ^[0-9]+$ ]]; then
            if [[ "$miner_pid" -gt 1 && -r "/proc/$miner_pid/stat" ]]; then
              proc_start_ticks=$(awk '{print $22}' /proc/$miner_pid/stat)
              clk_tck=$(getconf CLK_TCK)
              boot_time=$(awk '/btime/ {print $2}' /proc/stat)
              start_time=$((boot_time + proc_start_ticks / clk_tck))
              now=$(date +%s)
              uptime_secs=$((now - start_time))
              hours=$((uptime_secs / 3600))
              minutes=$(((uptime_secs % 3600) / 60))
              readable="${minutes}m"
              ((hours > 0)) && readable="${hours}h ${minutes}m"
            fi
          fi

          # Uptime coloring (for icon, not name)
          if [[ "$readable" =~ ^([0-9]+)m$ ]]; then
            diff=${BASH_REMATCH[1]}
            diff=$((10#$diff))
            if ((diff < 5)); then
              icon="${YELLOW}🟡${RESET}"
            elif ((diff < 30)); then
              icon="${CYAN}🔵${RESET}"
            else
              icon="${GREEN}🟢${RESET}"
            fi
          elif [[ "$readable" =~ ^([0-9]+)h ]]; then
            icon="${GREEN}🟢${RESET}"
          else
            icon="${YELLOW}🟡${RESET}"
          fi

          # CPU/mem/child
          if [[ -z "$miner_pid" || ! "$miner_pid" =~ ^[0-9]+$ || "$miner_pid" -le 1 || ! -e "/proc/$miner_pid" ]]; then
            cpu="--"
            mem="--"
          else
            child_pid=""
            for cpid in $(pgrep -P "$miner_pid"); do
              cmdline=$(ps -p "$cpid" -o cmd=)
              if [[ "$cmdline" == *"$NOCKCHAIN_BIN"* ]] || [[ "$cmdline" == *"/nockchain"* ]] || [[ "$cmdline" == *" nockchain"* ]]; then
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
          if [[ -n "${child_pid:-}" && -e "/proc/$child_pid/status" ]]; then
            mem_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$child_pid/status")
            mem_gb=$(awk "BEGIN { printf \"%.1f\", $mem_kb / 1024 / 1024 }")
          else
            mem_gb="--"
          fi

          if [[ -f "$log_file" ]]; then
            latest_block=$(grep -a 'added to validated blocks at' "$log_file" 2>/dev/null | tail -n 1 | grep -oP 'at\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || echo "--")
          else
            latest_block="--"
          fi
          if [[ -f "$log_file" ]]; then
            last_line=$(tac "$log_file" | sed 's/\x1b\[[0-9;]*m//g' | grep -a 'connected_peers=' | grep -a 'connected_peers=[0-9]\+' | head -n 1 || echo "")
            extracted=$(echo "$last_line" | sed -n 's/.*connected_peers=\([0-9]\+\).*/\1/p' || echo "")
            if [[ "$extracted" =~ ^[0-9]+$ ]]; then
              peer_count="$extracted"
            fi
          fi

          lag="--"
          lag_int=0
          if [[ "$NETWORK_HEIGHT" =~ ^[0-9]+(\.[0-9]+)?$ && "$latest_block" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            lag_val=$(awk "BEGIN { print $NETWORK_HEIGHT - $latest_block }")
            lag_int=$(printf "%.0f" "$lag_val" 2>/dev/null)
            [[ "$lag_int" =~ ^-?[0-9]+$ ]] || lag_int=0
            ((lag_int < 0)) && lag_int=0
            lag="$lag_int"
          fi

          # Status
          if [[ -z "$mine_flag" ]]; then
            status_raw="SYNC-ONLY"
          elif [[ "$lag" =~ ^[0-9]+$ && "$lag_int" -eq 0 ]]; then
            status_raw="MINING"
          else
            status_raw="SYNCING"
          fi
        fi # end active

        # Miner name coloring
        session_padded=$(printf "%-9s" "$session")
        if [[ $is_active -eq 0 ]]; then
          session_display="${RED}${session_padded}${RESET}"
        else
          session_display="${GREEN}${session_padded}${RESET}"
        fi

        # --- BULLETPROOF COLUMN FORMATTING ---
        avg_blk="${avg_blk:0:9}"
        avg_comp="${avg_comp:0:12}"
        last_comp="${last_comp:0:12}"
        last_blk="${last_blk:0:9}"
        readable="${readable:0:9}"
        cpu="${cpu:0:9}"
        mem="${mem:0:9}"
        mem_gb="${mem_gb:0:9}"
        latest_block="${latest_block:0:9}"

        [[ -z "$readable" ]] && readable="--"
        [[ -z "$cpu" ]] && cpu="--"
        [[ -z "$mem" ]] && mem="--"
        [[ -z "$mem_gb" ]] && mem_gb="--"
        [[ -z "$latest_block" ]] && latest_block="--"
        [[ -z "$lag" ]] && lag="--"
        [[ -z "$peer_count" ]] && peer_count="--"
        [[ -z "$last_comp" ]] && last_comp="--"
        [[ -z "$avg_comp" ]] && avg_comp="--"
        [[ -z "$last_blk" ]] && last_blk="--"
        [[ -z "$avg_blk" ]] && avg_blk="--"
        [[ -z "$status_raw" ]] && status_raw="SYNCING"

        uptime_padded=$(printf "%-9s" "$readable")
        cpu_padded=$(printf "%-9s" "${cpu}%")
        mem_padded=$(printf "%-9s" "${mem}%")
        ram_padded=$(printf "%-9s" "$mem_gb")
        block_padded=$(printf "%-9s" "$latest_block")
        lag_padded=$(printf "%-5s" "$lag")
        status_padded=$(printf "%-9s" "$status_raw")
        peer_padded=$(printf "%-6s" "$peer_count")
        last_comp_padded=$(printf "%-9s" "$last_comp")
        avg_comp_padded=$(printf "%-9s" "$avg_comp")
        blk_age_padded=$(printf "%-9s" "$last_blk")
        avg_blk_padded=$(printf "%-9s" "$avg_blk")

        uptime_display="${BOLD_BLUE}${uptime_padded}${RESET}"
        if [[ "$cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (($(echo "$cpu <= 60" | bc -l))); then
          cpu_display="${GREEN}${cpu_padded}${RESET}"
        elif [[ "$cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (($(echo "$cpu <= 100" | bc -l))); then
          cpu_display="${YELLOW}${cpu_padded}${RESET}"
        elif [[ "$cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          cpu_display="${RED}${cpu_padded}${RESET}"
        else
          cpu_display="${cpu_padded}"
        fi
        if [[ "$mem" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (($(echo "$mem <= 20" | bc -l))); then
          mem_display="${CYAN}${mem_padded}${RESET}"
        elif [[ "$mem" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          mem_display="${MAGENTA}${mem_padded}${RESET}"
        else
          mem_display="${mem_padded}"
        fi
        ram_display="${DIM}${WHITE}${ram_padded}${RESET}"
        block_display="${CYAN}${block_padded}${RESET}"
        if [[ "$lag" =~ ^[0-9]+$ && "$lag" -gt 0 ]]; then
          lag_display="${RED}${lag_padded}${RESET}"
        else
          lag_display="${GREEN}${lag_padded}${RESET}"
        fi

        # Status color
        if [[ $is_active -eq 0 ]]; then
          status_display="${RED}${status_padded}${RESET}"
        elif [[ "$status_raw" == "MINING" ]]; then
          status_display="${GREEN}${status_padded}${RESET}"
        elif [[ "$status_raw" == "SYNC-ONLY" ]]; then
          status_display="${CYAN}${status_padded}${RESET}"
        else
          status_display="${YELLOW}${status_padded}${RESET}"
        fi

        # Peer count color
        peer_count_val="${peer_count:-0}"
        if [[ "$peer_count_val" =~ ^[0-9]+$ ]]; then
          if ((peer_count_val >= 32)); then
            peer_display="${GREEN}${peer_padded}${RESET}"
          elif ((peer_count_val >= 16)); then
            peer_display="${YELLOW}${peer_padded}${RESET}"
          else
            peer_display="${RED}${peer_padded}${RESET}"
          fi
        else
          peer_display="${RED}${peer_padded}${RESET}"
        fi

        # Prepare display variables for proof/block-age columns with 's' next to value, and pad for UI
        last_comp_s=$(add_s "$last_comp")
        avg_comp_s=$(add_s "$avg_comp")
        blk_age_s=$(add_s "$last_blk")
        avg_blk_s=$(add_s "$avg_blk")

        last_comp_colored="${YELLOW}${last_comp_s}${RESET}"
        avg_comp_colored="${BOLD_BLUE}${avg_comp_s}${RESET}"

        if [[ "$last_blk" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (($(echo "$last_blk >= 900" | bc -l))); then
          blk_age_colored="${RED}${blk_age_s}${RESET}"
        elif [[ "$last_blk" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (($(echo "$last_blk >= 300" | bc -l))); then
          blk_age_colored="${YELLOW}${blk_age_s}${RESET}"
        else
          blk_age_colored="${GREEN}${blk_age_s}${RESET}"
        fi
        avg_blk_colored="${DIM}${CYAN}${avg_blk_s}${RESET}"

        # Pad all columns to fixed width
        last_comp_display=$(pad_plain "$last_comp_colored" 9)
        avg_comp_display=$(pad_plain "$avg_comp_colored" 9)
        blk_age_display=$(pad_plain "$blk_age_colored" 9)
        avg_blk_display=$(pad_plain "$avg_blk_colored" 9)

        printf "%b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b\n" \
          "$icon" "$session_display" "$uptime_display" "$cpu_display" "$mem_display" "$ram_display" "$block_display" "$lag_display" "$status_display" "$peer_display" "$last_comp_display" "$avg_comp_display" "$blk_age_display" "$avg_blk_display"
      done

      echo ""
      echo -e "${DIM}Refreshing every 2s — press ${BOLD_BLUE}Enter${DIM} to exit.${RESET}"
      key=""
      if read -t 2 -s -r key 2>/dev/null; then
        [[ "$key" == "" ]] && break # Enter pressed
      fi
    done
    continue
    ;;
  22)
    clear
    if ! command -v htop &>/dev/null; then
      echo -e "${YELLOW}htop is not installed. Installing now...${RESET}"
      sudo apt-get update && sudo apt-get install -y htop
    fi
    htop || true
    read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
    continue
    ;;

  12)
    clear
    miner_dirs=$(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner*" | sort -V)

    if [[ -z "$miner_dirs" ]]; then
      echo -e "${RED}❌ No miner directories found.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to menu...'
      continue
    fi

    if ! command -v fzf &>/dev/null; then
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
      miner_name=$(basename "$dir" | sed -nE 's/^(miner[0-9]+)$/\1/p')
      [[ -z "$miner_name" ]] && continue
      log_path="$dir/${miner_name}.log"
      service_name="nockchain-$miner_name"
      if systemctl is-active --quiet "$service_name"; then
        status_icon="🟢"
      else
        status_icon="🔴"
      fi
      miner_info_lines+=("$miner_name|$log_path|$status_icon")
      miner_logs["$miner_name"]="$log_path"
    done

    # Sort by miner number
    IFS=$'\n' sorted_info=($(printf "%s\n" "${miner_info_lines[@]}" | sort -t'|' -k1,1n))
    unset IFS

    # Build menu entries with formatting
    for info in "${sorted_info[@]}"; do
      miner_id=$(echo "$info" | cut -d'|' -f1)
      log_path=$(echo "$info" | cut -d'|' -f2)
      status_icon=$(echo "$info" | cut -d'|' -f3)
      label="$(printf "%s %b%-8s%b %b[%s]%b" "$status_icon" "${BOLD_BLUE}" "$miner_id" "${RESET}" "${DIM}" "$log_path" "${RESET}")"
      menu_entries+=("$label")
    done

    # Add Show all at the top and Cancel directly after, then the miners
    menu_entries=("📡 Show all miner logs combined (live)" "↩️  Cancel and return to menu" "${menu_entries[@]}")

    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --prompt="Select miner: " \
      --pointer="👉" --marker="✓" \
      --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse ↑ ↓ arrows or type to search. ENTER to confirm.\n')
    plain_selected=$(echo -e "$selected" | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$plain_selected" == *"Show all miner logs"* ]]; then
      echo -e "${CYAN}Streaming combined logs from all miners...${RESET}"
      echo -e "${DIM}Press Ctrl+C to return to menu.${RESET}"
      temp_log_script=$(mktemp)
      cat >"$temp_log_script" <<'EOL'
#!/bin/bash
source "$HOME/.nockchain_launcher.conf"
trap "exit 0" INT
tail -f $(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner*" -exec bash -c '
  for d; do 
    f="$d/$(basename "$d").log"
    [[ -f "$f" ]] && echo "$f"
  done
' _ {} +)
EOL
      chmod +x "$temp_log_script"
      bash "$temp_log_script"
      echo -e "${YELLOW}Log stream ended. Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      rm -f "$temp_log_script"
      continue
    fi

    selected_miner=$(echo "$plain_selected" | sed -nE 's/.*(miner[0-9]+).*/\1/p')
    [[ ! "$selected_miner" =~ ^miner[0-9]+$ ]] && {
      echo -e "${RED}❌ Invalid selection. No miner selected.${RESET}"
      read -n 1 -s
      continue
    }
    selected_miner=$(echo "$selected_miner" | tr -d '\n\r')

    if [[ -z "$selected" || "$selected" == *"Cancel and return to menu"* ]]; then
      echo -e "${YELLOW}Returning to menu...${RESET}"
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
    cat >"$temp_log_script" <<EOL
#!/bin/bash
source "$HOME/.nockchain_launcher.conf"
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
  for dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
    miner_name=$(basename "$dir" | sed -nE 's/^(miner[0-9]+)$/\1/p')
    [[ -z "$miner_name" ]] && continue
    [ -d "$dir" ] || continue
    state_file="$dir/state.jam"
    if [[ -f "$state_file" ]]; then
      block=$(strings "$state_file" | grep -oE 'block [0-9]+' | grep -oE '[0-9]+' | head -n 1)
      if [[ "$block" =~ ^[0-9]+$ ]] && ((block > highest_block)); then
        highest_block=$block
        latest_state_file="$state_file"
      fi
    fi
  done
  if [[ -n "$latest_state_file" && -f "$latest_state_file" ]]; then
    cp "$latest_state_file" "$NOCKCHAIN_HOME/state_backup.jam"
    echo "[$(date)] Copied state.jam (block $highest_block) to $NOCKCHAIN_HOME/state_backup.jam"
  else
    echo "[$(date)] No valid state.jam found for backup."
  fi
}
