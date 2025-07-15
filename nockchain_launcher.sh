#!/bin/bash
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LAUNCH_CFG="$SCRIPT_DIR/launch.cfg"

# LAUNCHER_VERSION and REMOTE_VERSION
LAUNCHER_VERSION_FILE="$(dirname "$SCRIPT_PATH")/NOCKCHAIN_LAUNCHER_VERSION"
if [[ -f "$LAUNCHER_VERSION_FILE" ]]; then
  LAUNCHER_VERSION=$(cat "$LAUNCHER_VERSION_FILE" | tr -d '[:space:]')
else
  LAUNCHER_VERSION="(unknown)"
fi
# Fetch remote version directly
REMOTE_VERSION=$(curl -fsSL https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/NOCKCHAIN_LAUNCHER_VERSION 2>/dev/null | tr -d '[:space:]')
REMOTE_VERSION=${REMOTE_VERSION:-"(offline)"}

# Color variable definitions
WHITE="\033[97m"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BOLD_YELLOW="\033[1;33m"
CYAN="\e[36m"
BOLD_BLUE="\e[1;34m"
MAGENTA="\e[35m"
DIM="\e[2m"
RESET="\e[0m"
BOLD="\033[1m"

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
  # Remove all dots
  local undotted="${block//./}"
  # Only output if numeric (ignore hashes/base58)
  if [[ "$undotted" =~ ^[0-9]+$ ]]; then
    # Remove leading zeros
    echo "$((10#$undotted))"
  else
    echo ""
  fi
}

# Format a numeric block number as dotted, e.g. 14419 -> 14.419
format_block_dotted() {
  local num="$1"
  # Only works if input is numeric
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    local len=${#num}
    if ((len > 3)); then
      local main_part=${num:0:len-3}
      local tail_part=${num:len-3:3}
      echo "${main_part}.${tail_part}"
    else
      echo "$num"
    fi
  else
    echo "$num"
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
  local custom_message="${1:-}"
  if [[ ! -f "$NOCKCHAIN_BIN" ]]; then
    clear
    echo -e "${RED}❌ Nockchain binary not found!${RESET}"
    echo ""
    [[ -n "$custom_message" ]] && echo -e "${YELLOW}$custom_message${RESET}\n"
    echo -e "${CYAN}You must install or update the binary before continuing.${RESET}"
    echo ""
    echo -e "${YELLOW}- Use option ${BOLD}1${RESET}${YELLOW} in the main menu to perform a full install."
    echo -e "- Or option ${BOLD}2${RESET}${YELLOW} to update Nockchain if already installed.${RESET}"
    echo ""
    echo -e "${DIM}Tip: This check ensures your node is ready for all miner and state operations.${RESET}"
    echo ""
    read -r -p $'Press Enter to return to the main menu...'
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

# Extract latest validated block from a miner log (supports dotted, undotted, base58)
extract_latest_block() {
  local log_file="$1"
  if [[ -f "$log_file" && -r "$log_file" ]]; then
    # Get the last relevant log line
    local line
    line=$(grep -a 'added to validated blocks at' "$log_file" | tail -n 1 || true)
    # Extract the block number after 'at '
    blk=$(echo "$line" | awk -F 'at ' '{print $2}' | awk '{print $1}')
    if [[ -n "$blk" ]]; then
      echo "$blk"
      return
    fi
    echo "--"
  else
    echo "--"
  fi
}

extract_block_num_from_line() {
  local line="$1"
  # Try: "at <dotted/undotted number>"
  if [[ "$line" =~ at[[:space:]]([0-9]{1,3}(?:\.[0-9]{3})*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Try: "block <dotted/undotted number>"
  if [[ "$line" =~ block[[:space:]]([0-9]{1,3}(?:\.[0-9]{3})*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Try: "block <base58 string>"
  if [[ "$line" =~ block[[:space:]]([a-zA-Z0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
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
    ' "$LAUNCH_CFG" | tr -d '\000')
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
  local miner="$1"
  local log_file="$NOCKCHAIN_HOME/$miner/$miner.log"
  local proof_csv="$NOCKCHAIN_HOME/$miner/${miner}_proof_log.csv"
  local last_csv_line=""

  # Ensure miner directory exists
  [[ -d "$NOCKCHAIN_HOME/$miner" ]] || mkdir -p "$NOCKCHAIN_HOME/$miner"

  # If log file doesn't exist, return dashes
  [[ -f "$log_file" ]] || {
    echo "--|--|--"
    return
  }

  # Ensure CSV exists and has header
  if [[ ! -f "$proof_csv" ]]; then
    echo "thread,start_time,finish_time,duration_s" >"$proof_csv"
    sync "$proof_csv"
  fi

  # Determine last processed finish_time and thread from CSV (for incremental parsing)
  last_csv_line=$(tail -n 1 "$proof_csv" 2>/dev/null)
  last_finish_time=$(echo "$last_csv_line" | awk -F, '{print $3}')
  last_thread=$(echo "$last_csv_line" | awk -F, '{print $1}')

  # Holds the latest "starting mining attempt" time per thread
  declare -A thread_last_start_time

  # For very large logs, avoid O(n²) grep: process in one loop
  mapfile -t log_lines < <(sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' "$log_file" | tail -n 5000)

  for ((i = 0; i < ${#log_lines[@]}; ++i)); do
    line="${log_lines[i]}"
    # Early skip: ignore lines up to and including last processed finish_time/thread
    if [[ "$line" =~ didn\'t\ find\ block,\ starting\ new\ attempt.\ thread=([0-9]+) ]]; then
      this_thread="${BASH_REMATCH[1]}"
      if [[ "$line" =~ \(([0-9]{2}:[0-9]{2}:[0-9]{2})\) ]]; then
        this_finish="${BASH_REMATCH[1]}"
        if [[ "$this_thread" == "$last_thread" && "$this_finish" == "$last_finish_time" ]]; then
          found_last=1
        fi
      fi
      continue
    fi

    # After we've found last, only parse new
    if [[ "$line" =~ starting\ mining\ attempt\ on\ thread\ ([0-9]+) ]]; then
      thread="${BASH_REMATCH[1]}"
      if [[ "$line" =~ \(([0-9]{2}:[0-9]{2}:[0-9]{2})\) ]]; then
        thread_last_start_time["$thread"]="${BASH_REMATCH[1]}"
      fi
      continue
    fi

    if [[ "$line" =~ didn\'t\ find\ block,\ starting\ new\ attempt.\ thread=([0-9]+) ]]; then
      thread="${BASH_REMATCH[1]}"
      if [[ "$line" =~ \(([0-9]{2}:[0-9]{2}:[0-9]{2})\) ]]; then
        finish_time="${BASH_REMATCH[1]}"
        start_time="${thread_last_start_time[$thread]:-}"
        if [[ -n "$start_time" ]]; then
          start_epoch=$(date -d "$start_time" +%s 2>/dev/null)
          finish_epoch=$(date -d "$finish_time" +%s 2>/dev/null)
          if [[ -n "$start_epoch" && -n "$finish_epoch" && "$finish_epoch" -ge "$start_epoch" ]]; then
            duration=$((finish_epoch - start_epoch))
            if ! grep -q "^$thread,$start_time,$finish_time,$duration\$" "$proof_csv"; then
              echo "$thread,$start_time,$finish_time,$duration" >>"$proof_csv"
              sync "$proof_csv"
            fi
          fi
        fi
      fi
      continue
    fi
  done

  # Summarize for dashboard: exclude header
  last_duration="--"
  avg_duration="--"
  proofs_per_sec="--"

  nrows=$(wc -l <"$proof_csv" 2>/dev/null)
  if ((nrows > 1)); then
    # Last duration
    last_duration=$(tail -n 1 "$proof_csv" | awk -F, '{print $4}')

    # Average duration
    mapfile -t durations < <(tail -n 50 "$proof_csv" | awk -F, '{print $4}' | grep -E '^[0-9]+$')
    if [[ ${#durations[@]} -gt 0 ]]; then
      sum=0
      for d in "${durations[@]}"; do sum=$((sum + d)); done
      avg_duration=$(awk -v s="$sum" -v n="${#durations[@]}" 'BEGIN{printf "%.2f", s/n}')
    fi

    # Proofs/s over last 50 entries, using all start_times (regardless of thread)
    mapfile -t start_times < <(tail -n 50 "$proof_csv" | awk -F, '{print $2}' | grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2}$')
    count=${#start_times[@]}
    if ((count > 1)); then
      first_sec=$(date -d "${start_times[0]}" +%s 2>/dev/null)
      last_sec=$(date -d "${start_times[-1]}" +%s 2>/dev/null)
      duration_s=$((last_sec - first_sec))
      if ((duration_s > 0)); then
        proofs_per_sec=$(awk -v t="$count" -v d="$duration_s" 'BEGIN{printf "%.4f", t/d}')
      fi
    fi
  fi

  echo "${last_duration}|${avg_duration}|${proofs_per_sec}"
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
    sed 's/\x1B\[[0-9;]*m//g' "$log_file" | grep -a 'added to validated blocks at' | tail -n 200
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
      blk=$(extract_latest_block "$log_file")
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
  latest_log_line=$(sed 's/\x1B\[[0-9;]*m//g' "$log_file" | grep -a 'added to validated blocks at' | tail -n 1)
  if [[ -n "$latest_log_line" ]]; then
    latest_ts=$(echo "$latest_log_line" | grep -oP '\(\K[0-9]{2}:[0-9]{2}:[0-9]{2}')
    latest_blk=$(extract_latest_block "$log_file")
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

  # Always use normalized numeric block for comparisons.
  local max_blk_numeric=0
  local ts_for_max_blk=""
  for entry in "${csv_entries[@]}"; do
    ts=$(echo "$entry" | cut -d, -f1)
    blk=$(echo "$entry" | cut -d, -f2)
    # Always use normalized numeric block for comparisons.
    blk_numeric=$(normalize_block "$blk")
    if [[ -n "$blk_numeric" && "$blk_numeric" -gt "$max_blk_numeric" ]]; then
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
  # Grab latest block from backup log and journalctl, pick the highest (as dotted!)
  block=$(
    {
      tail -n 30 "$NOCKCHAIN_HOME/statejam_backup.log" 2>/dev/null
      journalctl -u nockchain-statejam-backup.service --no-pager -o cat -n 30 2>/dev/null
    } |
      grep -a 'Exported state.jam from block' |
      sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g' |
      # Extract *all* numeric groups (dotted/undotted) per line, join, pick the highest
      while read -r line; do
        # Try to find a block like "14.444" or "14444" in the line
        block_raw=$(echo "$line" | grep -oE '[0-9]{1,3}(\.[0-9]{3})+' | tail -n1)
        if [[ -z "$block_raw" ]]; then
          # Fallback to any number (undotted, but not short group)
          block_raw=$(echo "$line" | grep -oE '[0-9]{4,}' | tail -n1)
        fi
        if [[ -n "$block_raw" ]]; then
          # Normalize to numeric (undotted, e.g. 14.444 -> 14444)
          block_num="${block_raw//./}"
          echo "$block_num"
        fi
      done |
      sort -n | tail -n 1
  )
  # Display as dotted for output
  if [[ -n "$block" && "$block" =~ ^[0-9]+$ ]]; then
    block=$(format_block_dotted "$block")
  else
    block="--"
  fi
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

get_total_cpu_usage() {
  top -bn1 | grep "Cpu(s)" | tail -n 1 | awk '{print 100 - $8}' | xargs printf "%.1f"
}

get_total_mem_usage() {
  local mem_line
  mem_line=$(free -g | awk '/^Mem:/ {print $3, $2}')
  local used=$(echo "$mem_line" | awk '{print $1}')
  local total=$(echo "$mem_line" | awk '{print $2}')
  if [[ "$total" -gt 0 ]]; then
    local percent=$((100 * used / total))
    echo "$percent $used $total"
  else
    echo "-- -- --"
  fi
}

get_network_height() {
  local NETWORK_HEIGHT="--"
  local all_blocks=()
  for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
    [[ -d "$miner_dir" ]] || continue
    miner_label=$(basename "$miner_dir" | sed -nE 's/^(miner[0-9]+)$/\1/p')
    [[ -z "$miner_label" ]] && continue
    log_file="$miner_dir/${miner_label}.log"

    if [[ -f "$log_file" && -r "$log_file" ]]; then
      heard_block=$(grep -a 'heard block' "$log_file" | tail -n 5 | grep -oP 'height\s+\K([0-9]{1,3}(?:\.[0-9]{3})*)' || true)
      validated_block=$(extract_latest_block "$log_file")
      combined=$(printf "%s\n%s\n" "$heard_block" "$validated_block" | sort -V | tail -n 1)
      [[ -n "$combined" ]] && all_blocks+=("$combined")
    fi
  done
  # Always use normalized numeric block for comparisons.
  if [[ ${#all_blocks[@]} -gt 0 ]]; then
    NETWORK_HEIGHT="--"
    # Find max numeric block among all_blocks
    max_numeric=0
    for blk in "${all_blocks[@]}"; do
      num=$(normalize_block "$blk")
      if [[ -n "$num" && "$num" -gt "$max_numeric" ]]; then
        max_numeric="$num"
        NETWORK_HEIGHT="$blk"
      fi
    done
    # If nothing numeric, fallback to original string max (still sorted -V)
    if [[ "$NETWORK_HEIGHT" == "--" ]]; then
      NETWORK_HEIGHT=$(printf "%s\n" "${all_blocks[@]}" | sort -V | tail -n 1)
    fi
  fi
  echo "$NETWORK_HEIGHT"
}

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
  echo -e "${DIM}Install, configure, and monitor multiple Nockchain miners with ease.${RESET}"
  echo ""

  # Show running miners
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
    MINER_EMOJI="🟢"
  else
    MINER_EMOJI="🔴"
  fi
  echo -e "${MINER_EMOJI}  ${CYAN}Active Miners:${RESET} ${YELLOW}${RUNNING_MINERS}${RESET}   ${DIM}(${MINER_FOLDERS} total miners)${RESET}"

  # Show live system metrics: CPU load, memory usage, uptime
  TOTAL_CPU=$(get_total_cpu_usage)
  read TOTAL_MEM_PCT TOTAL_MEM_USED TOTAL_MEM_TOTAL < <(get_total_mem_usage)

  # Choose emoji based on CPU usage
  if (($(echo "$TOTAL_CPU < 60" | bc))); then
    CPU_EMOJI="🟢"
  elif (($(echo "$TOTAL_CPU < 90" | bc))); then
    CPU_EMOJI="🟡"
  else
    CPU_EMOJI="🔴"
  fi
  # Choose emoji based on Mem usage
  if [[ "$TOTAL_MEM_PCT" =~ ^[0-9]+$ ]]; then
    if ((TOTAL_MEM_PCT < 60)); then
      MEM_EMOJI="🟢"
    elif ((TOTAL_MEM_PCT < 90)); then
      MEM_EMOJI="🟡"
    else
      MEM_EMOJI="🔴"
    fi
  else
    MEM_EMOJI="⚪"
  fi

  echo -e "${CPU_EMOJI}  ${CYAN}Total CPU Usage:${RESET} ${YELLOW}${TOTAL_CPU}%${RESET}   |   ${MEM_EMOJI}  ${CYAN}Total Mem:${RESET} ${YELLOW}${TOTAL_MEM_PCT}%${RESET} (${YELLOW}${TOTAL_MEM_USED}${RESET}/${YELLOW}${TOTAL_MEM_TOTAL}${RESET} GB)"

  # Show live state.jam status using new get_statejam_status
  output=$(get_latest_statejam_block | tr '|' ' ' 2>/dev/null || echo "-- --")
  read latest_statejam_blk latest_statejam_mins <<<"$output"
  blk_disp="${latest_statejam_blk:---}"
  min_disp="${latest_statejam_mins:---}"

  if systemctl is-active --quiet nockchain-statejam-backup.timer; then
    STATEJAM_EMOJI="🟢"
    if [[ "$min_disp" == "running" ]]; then
      STATEJAM_STATUS="${CYAN}state.jam:${RESET} ${YELLOW}block $blk_disp${RESET}, ${YELLOW}backup running${RESET}"
    else
      STATEJAM_STATUS="${CYAN}state.jam:${RESET} ${YELLOW}block $blk_disp${RESET}, next in ${YELLOW}${min_disp}m${RESET}"
    fi
  else
    STATEJAM_EMOJI="🔴"
    STATEJAM_STATUS="${CYAN}state.jam:${RESET} ${RED}backup inactive${RESET}"
  fi
  echo -e "${STATEJAM_EMOJI}  ${STATEJAM_STATUS}"

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

  # Display version block
  printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Node:" "$VERSION" "$NODE_STATUS"
  printf "  ${CYAN}%-12s${RESET}%-18s %b\n" "Launcher:" "$LAUNCHER_VERSION" "$LAUNCHER_STATUS"

  # Display PubKey
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

  # Extract network height from all miner logs (for dashboard)
  NETWORK_HEIGHT=$(get_network_height)
  network_height_disp=$(format_block_dotted "$(normalize_block "$NETWORK_HEIGHT")")

  # Display height
  printf "  ${CYAN}%-12s${RESET}%-20s\n" "Height:" "$network_height_disp"

  # Display red line
  echo -e "\e[31m::════════════════════════════════════════════════════════\e[0m"
  echo ""

  # Two-column layout for Setup and System Utilities
  printf "${CYAN}%-40s%-40s${RESET}\n" "Setup:" "System Utilities:"
  printf "${BOLD_BLUE}%-40s%-40s${RESET}\n" \
    "1) Install Nockchain from scratch" "21) Run system diagnostics" \
    "2) Update nockchain to latest version" "22) Monitor resource usage (htop)" \
    "3) Update nockchain-wallet only" "23) Change user, home directory, or install path" \
    "4) Update launcher script" "24) Clear logs (select which logs to delete)" \
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
  LOG_PATH="$NOCKCHAIN_HOME/nockbuild.log"

  if [[ -z "$USER_CHOICE" ]]; then
    echo -e "${CYAN}Exiting launcher. Goodbye!${RESET}"
    exit 0
  fi

  case "$USER_CHOICE" in
  # ===== Main Menu Option 1 =====
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
      screen -dmS nockbuild bash -c "
        source \"$SETTINGS_FILE\";
        cd \$NOCKCHAIN_HOME && {
          make install-hoonc && \
          make build && \
          make install-nockchain-wallet && \
          make install-nockchain && \
        echo 'nockchain install completed.'
        } 2>&1 | tee \$NOCKCHAIN_HOME/nockbuild.log
        exec bash
      "

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

  # ===== Main Menu Option 2 =====
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
      source \"$SETTINGS_FILE\";
      cd \$NOCKCHAIN_HOME && {
        git reset --hard HEAD && \
        git pull && \
        make install-nockchain && \
        export PATH=\"\$HOME/.cargo/bin:\$PATH\" && \
        if tmux ls 2>/dev/null | grep -q '^miner'; then
          echo '>> Killing tmux miner sessions...'
          tmux ls 2>/dev/null | grep '^miner' | cut -d: -f1 | xargs -r -n1 tmux kill-session -t
        fi
        for d in \$NOCKCHAIN_HOME/miner*; do
          bash \"$SCRIPT_PATH\" --restart-miner \"\$d\" \"\$MINING_KEY_DISPLAY\"
        done
        echo 'Update and restart completed.'
      } 2>&1 | tee \$NOCKCHAIN_HOME/nockupdate.log
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

  # ===== Main Menu Option 3 =====
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
      source \"$SETTINGS_FILE\";
      cd \$NOCKCHAIN_HOME && {
        git pull && \
        make install-nockchain-wallet && \
        export PATH=\"\$HOME/.cargo/bin:\$PATH\" && \
        echo 'Wallet update completed.'
      } 2>&1 | tee \$NOCKCHAIN_HOME/walletupdate.log
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

  # ===== Main Menu Option 4 =====
  4)
    clear
    echo -e "${YELLOW}You are about to update the launcher script to the latest version from GitHub.${RESET}"
    confirm_yes_no "Continue?" || {
      echo -e "${CYAN}Returning to menu...${RESET}"
      continue
    }

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
    "$SCRIPT_PATH"
    exit 0
    ;;

  # ===== Main Menu Option 5 =====
  5)
    clear
    require_nockchain "You need a working nockchain build to export state.jam." || continue
    ensure_nockchain_executable
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
      latest_block_num="$(normalize_block "$latest_block")"
      latest_block_dot="$(format_block_dotted "$latest_block_num")"
      label="$(styled_menu_entry "$status_icon" "$miner_name" "$latest_block_dot")"
      menu_entries+=("$label")
      miner_dirs_map["$miner_name"]="$dir"
      miner_blocks_map["$miner_name"]="$latest_block"
    done

    # Get latest state.jam from Filebin
    TMP_FILEBIN_META="/tmp/statebin-uploads.txt"
    curl -fsSL "https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/statebin-uploads.txt" -o "$TMP_FILEBIN_META"
    # Parse latest Filebin block
    filebin_block_display=""
    if [[ -s "$TMP_FILEBIN_META" ]]; then
      # Get last .jam file
      last_filebin_filename=$(tail -n 1 "$TMP_FILEBIN_META" | awk -F'|' '{print $2}' | xargs)
      # Get block number
      block_numeric=$(echo "$last_filebin_filename" | grep -oE '[0-9]+')
      # Format as dotted block
      if [[ "$block_numeric" =~ ^[0-9]+$ ]]; then
        block_len=${#block_numeric}
        if ((block_len > 3)); then
          main_part=${block_numeric:0:block_len-3}
          tail_part=${block_numeric:block_len-3:3}
          block_dot="${main_part}.${tail_part}"
        else
          block_dot="${block_numeric}"
        fi
        filebin_block_display="(block $block_dot)"
      else
        filebin_block_display="(block ?)"
      fi
    else
      filebin_block_display="(block ?)"
    fi
    FILEBIN_COMMIT_DISPLAY="⬇️  Download latest state.jam from Filebin $filebin_block_display"
    menu_entries=("↩️  Cancel and return to menu" "🚀 AUTO detect the latest state.jam source" "$GD_COMMIT_DISPLAY" "$GITHUB_COMMIT_DISPLAY" "$FILEBIN_COMMIT_DISPLAY" "${menu_entries[@]}")

    selected=$(printf "%s\n" "${menu_entries[@]}" | fzf --ansi --prompt="Select miner to export from: " \
      --pointer="👉" --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nUse ↑ ↓ arrows to navigate. ENTER to confirm.\n')

    if [[ "$selected" == *"AUTO"* ]]; then
      clear
      echo -e "${CYAN}🔎 Auto-selecting best source for state.jam...${RESET}"

      # Re-fetch all latest block numbers
      # Google Drive
      TMP_CLONE="$NOCKCHAIN_HOME/tmp_drive_download"
      rm -rf "$TMP_CLONE"
      mkdir -p "$TMP_CLONE"
      GDRIVE_FOLDER_ID="1aEYZwmg4isTuYXWFn9gKPl92-pYndwUw"
      echo -e "${DIM}Checking Google Drive source...${RESET}"
      python3 - <<EOF >"$TMP_CLONE/jam_files.txt" 2>&1
import subprocess
import signal
import time

folder_id = "$GDRIVE_FOLDER_ID"
cmd = ["gdown", "--folder", folder_id]

process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(2)
process.send_signal(signal.SIGINT)
stdout, stderr = process.communicate(timeout=5)

output = (stdout + "\n" + stderr).strip().splitlines()
for line in output:
    if line.startswith("Processing file") and ".jam" in line:
        parts = line.split()
        file_id, file_name = parts[2], parts[3]
        print(f"{file_id}\t{file_name}")
EOF

      GD_BLOCK="--"
      GD_LATEST_ID=""
      GD_LATEST_BLOCK=""
      if [[ -s "$TMP_CLONE/jam_files.txt" ]]; then
        highest_gd_block=0
        while IFS=$'\t' read -r id name; do
          [[ -z "$id" || -z "$name" || "$name" != *.jam ]] && continue
          block=$(echo "$name" | grep -oE '[0-9]+' || echo "0")
          if [[ "$block" =~ ^[0-9]+$ ]] && ((block > highest_gd_block)); then
            highest_gd_block=$block
            GD_BLOCK="$block"
            GD_LATEST_ID="$id"
            GD_LATEST_BLOCK="$block"
          fi
        done <"$TMP_CLONE/jam_files.txt"
      else
        echo -e "${YELLOW}⚠ No .jam files found on Google Drive.${RESET}"
      fi
      rm -rf "$TMP_CLONE"

      # GitHub
      GITHUB_BLOCK="$BLOCK_COMMIT_VERSION"

      # Filebin
      TMP_FILEBIN_META="/tmp/statebin-Uploads.txt"
      echo -e "${DIM}Checking Filebin source...${RESET}"
      curl -fsSL "https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/statebin-uploads.txt" -o "$TMP_FILEBIN_META" || {
        echo -e "${YELLOW}⚠ Failed to fetch Filebin metadata (URL not found). Skipping Filebin.${RESET}"
        FILEBIN_BLOCK="--"
      }
      FILEBIN_BLOCK="--"
      if [[ -s "$TMP_FILEBIN_META" ]]; then
        last_filebin_filename=$(tail -n 1 "$TMP_FILEBIN_META" | awk -F'|' '{print $2}' | xargs)
        FILEBIN_BLOCK=$(echo "$last_filebin_filename" | grep -oE '[0-9]+' || echo "0")
      fi

      # Miner (local)
      MINER_BLOCK="--"
      highest_miner_block=0
      for d in "$NOCKCHAIN_HOME"/miner[0-9]*; do
        [[ -d "$d" ]] || continue
        miner_name=$(basename "$d" | sed -nE 's/^(miner[0-9]+)$/\1/p')
        [[ -z "$miner_name" ]] && continue
        log="$d/$miner_name.log"
        if [[ -f "$log" ]]; then
          blk="--"
          if [[ -n "$log" ]]; then
            blk=$(extract_latest_block "$log")
          fi
          num=$(echo "$blk" | tr -d '.')
          if [[ "$num" =~ ^[0-9]+$ ]] && ((num > highest_miner_block)); then
            highest_miner_block=$num
            MINER_BLOCK="$blk"
            MINER_LATEST_DIR="$d"
          fi
        fi
      done

      # Always use normalized numeric block for comparisons.
      gd_num=$(normalize_block "$GD_BLOCK")
      github_num=$(normalize_block "$GITHUB_BLOCK")
      filebin_num=$(normalize_block "$FILEBIN_BLOCK")
      miner_num=$(normalize_block "$MINER_BLOCK")

      [[ ! "$gd_num" =~ ^[0-9]+$ ]] && gd_num=0
      [[ ! "$github_num" =~ ^[0-9]+$ ]] && github_num=0
      [[ ! "$filebin_num" =~ ^[0-9]+$ ]] && filebin_num=0
      [[ ! "$miner_num" =~ ^[0-9]+$ ]] && miner_num=0

      # Decide best source
      max_num=$gd_num
      max_src="Google Drive"
      src_tag="gd"
      if ((github_num > max_num)); then
        max_num=$github_num
        max_src="GitHub"
        src_tag="gh"
      fi
      if ((filebin_num > max_num)); then
        max_num=$filebin_num
        max_src="Filebin"
        src_tag="fb"
      fi
      if ((miner_num > max_num)); then
        max_num=$miner_num
        max_src="Local Miner"
        src_tag="miner"
      fi

      echo -e ""
      echo -e "${CYAN}Summary of latest blocks:${RESET}"
      echo -e "  Google Drive:  ${YELLOW}$(format_block_dotted "$GD_BLOCK")${RESET}"
      echo -e "  GitHub:        ${YELLOW}$(format_block_dotted "$GITHUB_BLOCK")${RESET}"
      echo -e "  Filebin:       ${YELLOW}$(format_block_dotted "$FILEBIN_BLOCK")${RESET}"
      echo -e "  Local Miner:   ${YELLOW}$(format_block_dotted "$MINER_BLOCK")${RESET} (${CYAN}$(basename "$MINER_LATEST_DIR")${RESET})"
      echo -e ""
      if [[ "$src_tag" == "miner" ]]; then
        miner_name="$(basename "$MINER_LATEST_DIR")"
        echo -e "${BOLD_BLUE}Most recent block is ${YELLOW}$(format_block_dotted "$max_num")${BOLD_BLUE} from ${GREEN}Local Miner (${CYAN}${miner_name}${GREEN})${RESET}."
      else
        echo -e "${BOLD_BLUE}Most recent block is ${YELLOW}$(format_block_dotted "$max_num")${BOLD_BLUE} from ${GREEN}$max_src${RESET}."
      fi
      echo -e ""

      # Ask for confirmation
      if [[ "$src_tag" == "miner" ]]; then
        miner_name="$(basename "$MINER_LATEST_DIR")"
        confirm_yes_no "Proceed to fetch state.jam from Local Miner (${miner_name} block $(format_block_dotted "$max_num"))?"
      else
        confirm_yes_no "Proceed to fetch state.jam from $max_src (block $(format_block_dotted "$max_num"))?"
      fi || {
        echo -e "${CYAN}Returning to menu...${RESET}"
        continue
      }

      # Set selected for all sources
      if [[ "$src_tag" == "gd" ]]; then
        selected="$GD_COMMIT_DISPLAY"
      elif [[ "$src_tag" == "gh" ]]; then
        selected="$GITHUB_COMMIT_DISPLAY"
      elif [[ "$src_tag" == "fb" ]]; then
        selected="$FILEBIN_COMMIT_DISPLAY"
      elif [[ "$src_tag" == "miner" ]]; then
        selected="Local Miner block $MINER_BLOCK"
      else
        echo -e "${RED}Unknown source, aborting.${RESET}"
        read -n 1 -s
        continue
      fi
    fi

    if [[ "$selected" == "Local Miner block"* ]]; then
      clear
      export_dir="$NOCKCHAIN_HOME/miner-export"
      state_output="$NOCKCHAIN_HOME/state.jam"
      best_dir="$MINER_LATEST_DIR"
      if [[ -z "$best_dir" ]]; then
        echo -e "${RED}❌ Could not find local miner folder with block $MINER_BLOCK. Aborting.${RESET}"
        read -n 1 -s
        continue
      fi
      echo -e "${CYAN}Creating temporary copy of miner with latest block...${RESET}"
      rm -rf "$export_dir"
      cp -a "$best_dir" "$export_dir"
      echo -e "${CYAN}Exporting state.jam to $state_output...${RESET}"
      cd "$export_dir"
      "$NOCKCHAIN_BIN" --export-state-jam "$state_output" 2>&1 | tee "$NOCKCHAIN_HOME/export.log"
      cd "$NOCKCHAIN_HOME"
      rm -rf "$export_dir"
      echo ""
      echo -e "${GREEN}✅ Exported state.jam from duplicate of ${CYAN}$(basename "$best_dir")${GREEN} (block ${BOLD_BLUE}$MINER_BLOCK${GREEN}) to ${CYAN}$state_output${GREEN}.${RESET}"
      echo -e "${DIM}To view detailed export logs: tail -n 20 $NOCKCHAIN_HOME/export.log${RESET}"
      echo ""
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    if [[ "$selected" == *"Filebin"* ]]; then
      clear
      # Fetch Filebin metadata
      TMP_FILEBIN_META="/tmp/statebin-uploads.txt"
      FILEBIN_META_URL="https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/statebin-uploads.txt"
      curl -fsSL "$FILEBIN_META_URL" -o "$TMP_FILEBIN_META"
      # Clean the metadata file: remove blank lines and trailing commas
      sed -i '/^$/d; s/,$//' "$TMP_FILEBIN_META"
      if [[ ! -s "$TMP_FILEBIN_META" ]]; then
        echo -e "${RED}Error: Failed to download statebin-uploads.txt or file is empty${RESET}"
        read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
        continue
      fi

      # Parse Filebin meta using pipe-based parsing for robustness
      FILEBIN_META_URL="https://raw.githubusercontent.com/jobless0x/nockchain-launcher/main/statebin-uploads.txt"
      jam_file_time=$(curl -fsSL "$FILEBIN_META_URL" | sed 's/\r//g; /^$/d; s/ *| */|/g' | awk -F'|' '{ gsub(/.jam/, "", $2); gsub(/[^0-9]/, "", $2); block=$2; time=$1 } END { print block, time }')

      # Extract block number and timestamp
      block=$(echo "$jam_file_time" | awk '{print $1}')
      timestamp=$(echo "$jam_file_time" | cut -d' ' -f2-)
      filebin_filename=""
      filebin_upload_time=""
      if [[ -n "$block" && -n "$timestamp" ]]; then
        filebin_filename="${block}.jam"
        filebin_upload_time="$timestamp"
      fi

      # Also extract last line for URL and extra info
      RAW_LINE=$(tail -n 1 "$TMP_FILEBIN_META")
      PARSED_LINE=$(echo "$RAW_LINE" | tr -d '\000' | tr -cd '\11\12\15\40-\176' | sed 's/^[ \t]*//;s/[ \t]*$//')
      CLEANED_LINE=$(echo "$PARSED_LINE" | tr -d '\000')
      IFS='|' read filebin_dt filebin_filename_raw filebin_url <<<"$CLEANED_LINE"
      filebin_dt=$(echo "$filebin_dt" | xargs)
      filebin_filename_raw=$(echo "$filebin_filename_raw" | xargs)
      filebin_url=$(echo "$filebin_url" | xargs)
      filebin_url=$(echo "$filebin_url" | tr -d '\r\n' | sed 's/[[:space:]]*$//')

      # Get numeric and dotted block for display
      filebin_block_numeric=$(echo "$block" | grep -oE '[0-9]+' | head -n 1)
      filebin_block_dot=""
      if [[ "$filebin_block_numeric" =~ ^[0-9]+$ ]]; then
        block_len=${#filebin_block_numeric}
        if ((block_len > 3)); then
          main_part=${filebin_block_numeric:0:block_len-3}
          tail_part=${filebin_block_numeric:block_len-3:3}
          filebin_block_dot="${main_part}.${tail_part}"
        else
          filebin_block_dot="${filebin_block_numeric}"
        fi
      else
        filebin_block_dot="?"
      fi

      echo -e "${CYAN}Latest Filebin snapshot:${RESET}"
      echo -e "  Block:   ${YELLOW}$filebin_block_dot${RESET}"
      echo -e "  File:    ${YELLOW}$filebin_filename${RESET}"
      echo -e "  Uploaded:${YELLOW}$timestamp${RESET}"
      echo -e "  URL:     ${CYAN}$filebin_url${RESET}"

      # Parse upload time
      filebin_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)

      # Sanity checks
      if [[ -z "$filebin_url" ]]; then
        echo -e "${RED}Error: Missing URL in statebin-uploads.txt${RESET}"
        tail -n 1 "$TMP_FILEBIN_META"
        read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
        continue
      fi
      if ! echo "$filebin_url" | grep -qE '^https?://'; then
        echo -e "${RED}Error: URL ($filebin_url) does not match expected pattern${RESET}"
        read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
        continue
      fi

      # Block version sanity check
      latest_ref_block="$filebin_block_numeric"
      if [[ -s "$TMP_FILEBIN_META" ]]; then
        latest_ref_block=$(tr -d '\000' <"$TMP_FILEBIN_META" | awk -F'|' '
          {
            fn = $2
            gsub(/^[ \t]+|[ \t]+$/, "", fn)
            blk = fn
            if (match(fn, /[0-9]+/)) {
              blk = substr(fn, RSTART, RLENGTH)
              blk += 0
              if (blk > max) max = blk
            }
          }
          END { print max }
        ')
      fi
      if [[ -z "$latest_ref_block" ]]; then
        latest_ref_block="$filebin_block_numeric"
      fi
      latest_ref_block_int=$(echo "$latest_ref_block" | grep -oE '[0-9]+' | head -n 1)
      if [[ -n "$filebin_block_numeric" && -n "$latest_ref_block_int" && "$filebin_block_numeric" =~ ^[0-9]+$ && "$latest_ref_block_int" =~ ^[0-9]+$ ]]; then
        if ((filebin_block_numeric < latest_ref_block_int)); then
          echo -e ""
          echo -e "${RED}❌ Filebin snapshot is older than latest block recorded in statebin-uploads.txt ($latest_ref_block). Aborting for safety.${RESET}"
          read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
          continue
        fi
      fi

      echo -e ""
      # Confirm & download
      confirm_yes_no "Download and overwrite state.jam with this Filebin snapshot?" || {
        echo -e "${CYAN}Returning to menu...${RESET}"
        continue
      }

      echo -e ""
      echo -e "${CYAN}Downloading state.jam from Filebin...${RESET}"
      # Try wget for download
      if command -v wget &>/dev/null; then
        wget --no-check-certificate --content-disposition -O "$NOCKCHAIN_HOME/state.jam" "$filebin_url"
        download_success=$?
      else
        download_success=1
      fi

      # Fallback to curl
      if [[ $download_success -ne 0 || ! -s "$NOCKCHAIN_HOME/state.jam" ]]; then
        curl -L --compressed -A "Mozilla/5.0" -o "$NOCKCHAIN_HOME/state.jam" "$filebin_url"
      fi

      # Sanity check: valid file
      min_size_kb=5000
      actual_size_kb=$(du -k "$NOCKCHAIN_HOME/state.jam" | awk '{print $1}')
      file_head=$(head -c 32 "$NOCKCHAIN_HOME/state.jam")
      if [[ ! -s "$NOCKCHAIN_HOME/state.jam" || "$file_head" =~ "<!doctype html>" || "$actual_size_kb" -lt "$min_size_kb" ]]; then
        echo -e "${RED}❌ Download failed or invalid file${RESET}"
        rm -f "$NOCKCHAIN_HOME/state.jam"
        read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
        continue
      fi

      echo -e "${GREEN}✅ state.jam downloaded and saved as ${CYAN}$NOCKCHAIN_HOME/state.jam${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the main menu...'
      continue
    fi

    if [[ "$selected" == *"Google Drive"* ]]; then
      clear
      echo -e "${CYAN}📦 Step 1/4: Verifying required tools...${RESET}"
      echo -e "${DIM}Checking for: wget, gdown, pip3, python3...${RESET}"
      for tool in wget gdown pip3 python3; do
        if command -v "$tool" &>/dev/null; then
          echo -e "${GREEN}✔ $tool found${RESET}"
        else
          echo -e "${YELLOW}⚠ $tool not found. Installing...${RESET}"
          if [[ "$tool" == "gdown" ]]; then
            sudo apt-get update && sudo apt-get install -y python3-pip
            pip3 install --user --force-reinstall gdown
          elif [[ "$tool" == "wget" ]]; then
            sudo apt-get update && sudo apt-get install -y wget
          elif [[ "$tool" == "pip3" ]]; then
            sudo apt-get update && sudo apt-get install -y python3-pip
          elif [[ "$tool" == "python3" ]]; then
            sudo apt-get update && sudo apt-get install -y python3
          fi
        fi
      done

      # Ensure PATH includes user-installed binaries
      export PATH="$HOME/.local/bin:$PATH"

      # Debug gdown version and path
      gdown_version=$(gdown --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
      echo -e "${DIM}gdown version: $gdown_version at $(which gdown)${RESET}"

      # Step 2: List files using Python and gdown
      TMP_CLONE="$NOCKCHAIN_HOME/tmp_drive_download"
      rm -rf "$TMP_CLONE"
      mkdir -p "$TMP_CLONE"

      GDRIVE_FOLDER_ID="1aEYZwmg4isTuYXWFn9gKPl92-pYndwUw"
      GDRIVE_FOLDER_URL="https://drive.google.com/drive/folders/$GDRIVE_FOLDER_ID"

      echo ""
      echo -e "${CYAN}📥 Step 2/4: Listing files from Google Drive folder using gdown...${RESET}"
      echo -e "${DIM}Fetching file list from Google Drive folder...${RESET}"
      rm -rf /root/State\ Jams/* # Clean up partial downloads
      python3 - <<EOF >"$TMP_CLONE/jam_files.txt" 2>&1
import subprocess
import signal
import time

folder_id = "$GDRIVE_FOLDER_ID"
cmd = ["gdown", "--folder", folder_id]

process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(1.5)
process.send_signal(signal.SIGINT)
stdout, stderr = process.communicate(timeout=5)

output = (stdout + "\n" + stderr).strip().splitlines()
for line in output:
    if line.startswith("Processing file") and ".jam" in line:
        parts = line.split()
        file_id, file_name = parts[2], parts[3]
        print(f"{file_id}\t{file_name}")
EOF

      if [[ ! -s "$TMP_CLONE/jam_files.txt" ]]; then
        echo -e "${RED}❌ Could not extract any .jam files from Google Drive folder.${RESET}"
        echo "DEBUG: Content of jam_files.txt:"
        cat "$TMP_CLONE/jam_files.txt"
        rm -rf "$TMP_CLONE"
        read -n 1 -s
        continue
      fi

      echo -e "${DIM}Found $(wc -l <"$TMP_CLONE/jam_files.txt") .jam file(s).${RESET}"
      echo -e "${DIM}Discovered .jam files with IDs:${RESET}"
      while IFS=$'\t' read -r id name; do
        [[ -z "$id" || -z "$name" || "$name" != *.jam ]] && continue
        block=$(echo "$name" | grep -oE '[0-9]+' || echo "0")
        echo -e "${CYAN}- $name${RESET} ${DIM}(block $block, id=$id)${RESET}"
      done <"$TMP_CLONE/jam_files.txt"

      # Extract latest .jam file
      latest_block=-1
      latest_id=""
      latest_name=""
      while IFS=$'\t' read -r id name; do
        block=$(echo "$name" | grep -oE '[0-9]+' || echo "0")
        [[ -z "$id" || -z "$name" || -z "$block" ]] && continue
        if ((block > latest_block)); then
          latest_block=$block
          latest_id=$id
          latest_name=$name
        fi
      done <"$TMP_CLONE/jam_files.txt"

      if [[ -z "$latest_id" || -z "$latest_name" || "$latest_block" -lt 0 ]]; then
        echo -e "${RED}❌ Could not extract latest .jam file correctly. Aborting.${RESET}"
        echo "DEBUG: Content of jam_files.txt:"
        cat "$TMP_CLONE/jam_files.txt"
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

  # ===== Main Menu Option 6 =====
  6)
    clear
    require_nockchain || continue
    ensure_nockchain_executable
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

# Extract latest validated block from a miner log (supports dotted, undotted, base58)
extract_latest_block() {
  local log_file="$1"
  if [[ -f "$log_file" && -r "$log_file" ]]; then
    # Get the last relevant log line
    local line
    line=$(tail -n 500 "$log_file" 2>/dev/null | grep -a 'added to validated blocks at' | tail -n 1 || true)
    # Extract the block number after 'at '
    blk=$(echo "$line" | awk -F 'at ' '{print $2}' | awk '{print $1}')
    if [[ -n "$blk" ]]; then
      echo "$blk"
      return
    fi
    echo "--"
  else
    echo "--"
  fi
}

extract_block_num_from_line() {
  local line="$1"
  # Try: "at <dotted/undotted number>"
  if [[ "$line" =~ at[[:space:]]([0-9]{1,3}(?:\.[0-9]{3})*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Try: "block <dotted/undotted number>"
  if [[ "$line" =~ block[[:space:]]([0-9]{1,3}(?:\.[0-9]{3})*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Try: "block <base58 string>"
  if [[ "$line" =~ block[[:space:]]([a-zA-Z0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
}

# Block normalization helper
normalize_block() {
  local block="$1"
  # Remove all dots
  local undotted="${block//./}"
  # Only output if numeric (ignore hashes/base58)
  if [[ "$undotted" =~ ^[0-9]+$ ]]; then
    # Remove leading zeros
    echo "$((10#$undotted))"
  else
    echo ""
  fi
}

# Format a numeric block number as dotted, e.g. 14419 -> 14.419
format_block_dotted() {
  local num="$1"
  # Only works if input is numeric
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    local len=${#num}
    if ((len > 3)); then
      local main_part=${num:0:len-3}
      local tail_part=${num:len-3:3}
      echo "${main_part}.${tail_part}"
    else
      echo "$num"
    fi
  else
    echo "$num"
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
  blk="--"
  if [[ -f "$log" && -r "$log" ]]; then
    blk=$(extract_latest_block "$log")
  fi

  blk_num="$(normalize_block "$blk")"
  blk_dot="$(format_block_dotted "$blk_num")"
  # Pad miner name to 8 chars
  if [[ -n "$blk_num" && "$blk_num" != "--" ]]; then
    printf "🟢 %-8s detected at block %s\n" "$miner_name" "$blk_dot"
    # ** THIS IS THE KEY: Compare and update highest **
    if [[ "$blk_num" =~ ^[0-9]+$ ]] && (( blk_num > HIGHEST )); then
      SRC="$d"
      HIGHEST="$blk_num"
      HIGHEST_BLOCK="$blk_dot"
    fi
  else
    printf "⚠️ %-8s No valid block found\n" "$miner_name"
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

  # ===== Main Menu Option 11 =====
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
      # Print Live Miner Monitor
      tput cup 0 0
      echo -e "${DIM}🖥️  Live Miner Monitor ${RESET}"

      # Extract network height from all miner logs (live, every refresh, OPTIMIZED)
      NETWORK_HEIGHT=$(get_network_height)
      NETWORK_HEIGHT_NUM=$(normalize_block "$NETWORK_HEIGHT")
      NETWORK_HEIGHT_DOT=$(format_block_dotted "$NETWORK_HEIGHT_NUM")

      # State.jam status line
      output=$(get_latest_statejam_block | tr '|' ' ' 2>/dev/null || echo "-- --")
      read statejam_blk statejam_mins <<<"$output"
      blk_disp="${statejam_blk:---}"
      min_disp="${statejam_mins:---}"

      # Colorized state.jam status
      if systemctl is-active --quiet nockchain-statejam-backup.timer; then
        if [[ "$min_disp" == "running" ]]; then
          STATEJAM_STATUS="${CYAN}state.jam:${RESET} ${YELLOW}block $blk_disp${RESET}, ${YELLOW}backup running${RESET}"
        else
          STATEJAM_STATUS="${CYAN}state.jam:${RESET} ${YELLOW}block $blk_disp${RESET}, next in ${YELLOW}${min_disp}m${RESET}"
        fi
      else
        STATEJAM_STATUS="${CYAN}state.jam:${RESET} ${RED}backup inactive${RESET}"
      fi

      # Print Network height and state.jam status
      echo ""
      echo -e "${CYAN}📡 Network height: ${YELLOW}$NETWORK_HEIGHT_DOT${RESET}  |  $STATEJAM_STATUS"

      # Display total CPU and MEM usage
      TOTAL_CPU=$(get_total_cpu_usage)
      read TOTAL_MEM_PCT TOTAL_MEM_USED TOTAL_MEM_TOTAL < <(get_total_mem_usage)

      # Print total CPU and MEM usage
      echo ""
      printf "${CYAN}🧮 Total CPU Usage:${RESET} ${YELLOW}%-6s%%${RESET} | ${CYAN}Total Mem:${RESET} ${YELLOW}%s%%${RESET} (${YELLOW}%s${RESET}/${YELLOW}%s${RESET} GB)\n" \
        "$TOTAL_CPU" "$TOTAL_MEM_PCT" "$TOTAL_MEM_USED" "$TOTAL_MEM_TOTAL"
      echo ""
      printf "   | %-9s | %-9s | %-6s | %-6s | %-9s | %-9s | %-5s | %-9s | %-6s | %-9s | %-9s | %-9s | %-9s | %-9s\n" \
        "Miner" "Uptime" "CPU" "MEM" "RAM (GB)" "Block" "Lag" "Status" "Peers" "LastProof" "AvgProof" "Proofs/s" "BlkAge" "AvgBlk"

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
        ' "$LAUNCH_CFG")

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

          # Uptime coloring
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
            # Extract last validated block (dotted, undotted, or hash)
            blk="--"
            if [[ -f "$log_file" && -r "$log_file" ]]; then
              blk=$(extract_latest_block "$log_file")
              # echo "[DEBUG] extract_latest_block for $session at $(date +'%Y-%m-%d %H:%M:%S.%3N')" >>/tmp/launcher_monitor_timing.log
            fi
            blk_num="$(normalize_block "$blk")"
            # echo "[DEBUG] normalize_block for $session at $(date +'%Y-%m-%d %H:%M:%S.%3N')" >>/tmp/launcher_monitor_timing.log
            if [[ -n "$blk_num" && "$blk_num" != "" ]]; then
              latest_block="$(format_block_dotted "$blk_num")"
              # echo "[DEBUG] format_block_dotted for $session at $(date +'%Y-%m-%d %H:%M:%S.%3N')" >>/tmp/launcher_monitor_timing.log
            else
              latest_block="--"
            fi
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
          NETWORK_HEIGHT_NUM="$(normalize_block "$NETWORK_HEIGHT")"
          LATEST_BLOCK_NUM="$(normalize_block "$latest_block")"
          if [[ "$NETWORK_HEIGHT_NUM" =~ ^[0-9]+$ && "$LATEST_BLOCK_NUM" =~ ^[0-9]+$ ]]; then
            lag_val=$((NETWORK_HEIGHT_NUM - LATEST_BLOCK_NUM))
            ((lag_val < 0)) && lag_val=0
            lag="$lag_val"
          fi

          # Status
          if [[ -z "$mine_flag" ]]; then
            status_raw="SYNC-ONLY"
          elif [[ "$lag" =~ ^[0-9]+$ && "$lag" -eq 0 ]]; then
            status_raw="MINING"
          else
            status_raw="SYNCING"
          fi
        fi

        # Only run LastProof | AvgProof | Proof/s if MINING; else, set to '--'
        if [[ "${status_raw^^}" == "MINING" ]]; then
          proof_metrics=$(update_proof_durations "$session")
          # echo "[DEBUG] update_proof_durations for $session at $(date +'%Y-%m-%d %H:%M:%S.%3N')" >>/tmp/launcher_monitor_timing.log
          IFS='|' read -r last_comp avg_comp proofs_per_sec <<<"$proof_metrics"
          last_comp=${last_comp:-"--"}
          avg_comp=${avg_comp:-"--"}
          proofs_per_sec=${proofs_per_sec:-"--"}
        else
          last_comp="--"
          avg_comp="--"
          proofs_per_sec="--"
        fi

        # Only skip get_block_deltas if miner is INACTIVE; run for MINING and SYNC ONLY
        if [[ "${status_raw^^}" == "INACTIVE" ]]; then
          last_blk="--"
          avg_blk="--"
        else
          block_metrics=$(get_block_deltas "$session")
          # get_block_deltas for $session at $(date +'%Y-%m-%d %H:%M:%S.%3N')" >>/tmp/launcher_monitor_timing.log
          IFS='|' read -r last_blk avg_blk <<<"$block_metrics"
        fi

        # Miner name coloring
        session_padded=$(printf "%-9s" "$session")
        if [[ $is_active -eq 0 ]]; then
          session_display="${RED}${session_padded}${RESET}"
        else
          session_display="${GREEN}${session_padded}${RESET}"
        fi

        # COLUMN FORMATTING
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
        cpu_padded=$(printf "%-6s" "${cpu}%")
        mem_padded=$(printf "%-6s" "${mem}%")
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
        proofs_per_sec_display=$(pad_plain "${CYAN}${proofs_per_sec}${RESET}" 9)
        blk_age_display=$(pad_plain "$blk_age_colored" 9)
        avg_blk_display=$(pad_plain "$avg_blk_colored" 9)

        printf "%b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b | %b\n" \
          "$icon" "$session_display" "$uptime_display" "$cpu_display" "$mem_display" "$ram_display" "$block_display" "$lag_display" "$status_display" "$peer_display" "$last_comp_display" "$avg_comp_display" "$proofs_per_sec_display" "$blk_age_display" "$avg_blk_display"
      done

      echo ""
      echo -e "${DIM}Refreshing every 2s — press ${BOLD_BLUE}Enter${DIM} to exit.${RESET}"
      key=""
      if read -t 2 -s -r key 2>/dev/null; then
        [[ "$key" == "" ]] && break
      fi
    done
    continue
    ;;

  # ===== Main Menu Option 12 =====
  12)
    clear
    miner_dirs=$(find "$NOCKCHAIN_HOME" -maxdepth 1 -type d -name "miner[0-9]*" | sort -V)

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

    # fzf-based miner log menu with status indicators and formatting
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

    # Sort by miner index
    IFS=$'\n' sorted_info=($(printf "%s\n" "${miner_info_lines[@]}" | sort -t'|' -k1.6n))
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

  # ===== Main Menu Option 13 =====
  13)
    clear
    echo -e ""
    echo -e "${YELLOW}You are about to configure and launch one or more miners.${RESET}"
    echo -e ""
    confirm_yes_no "Do you want to continue with miner setup?" || {
      echo -e ""
      echo -e "${CYAN}Returning to menu...${RESET}"
      echo -e ""
      continue
    }

    clear

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

# --- BEGIN PATCH: Extract NUM_THREADS_FLAG and STACK_SIZE_FLAG ---
NUM_THREADS_FLAG=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^NUM_THREADS_FLAG=/ {sub(/^NUM_THREADS_FLAG=/, ""); print; exit}
' "$SCRIPT_DIR/launch.cfg")

STACK_SIZE_FLAG=$(awk -v section="[miner$id]" '
  $0 == section {found=1; next}
  /^\[.*\]/ {found=0}
  found && /^STACK_SIZE_FLAG=/ {sub(/^STACK_SIZE_FLAG=/, ""); print; exit}
' "$SCRIPT_DIR/launch.cfg")
# --- END PATCH: Extract NUM_THREADS_FLAG and STACK_SIZE_FLAG ---

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
export RUST_LOG=debug,nockchain=debug,nockchain_libp2p_io=info,libp2p=info,libp2p_quic=info

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
[[ -n "$NUM_THREADS_FLAG" ]] && CMD+=($NUM_THREADS_FLAG)
[[ -n "$STACK_SIZE_FLAG" ]] && CMD+=($STACK_SIZE_FLAG)
[[ -n "$EXTRA_FLAGS" ]] && CMD+=($EXTRA_FLAGS)
[[ -n "$STATE_FLAG" ]] && CMD+=($STATE_FLAG)
"${CMD[@]}" 2>&1 | tee "$LOGFILE"
## --- END PATCHED BLOCK ---
EOS
    chmod +x "$RUN_MINER_SCRIPT"
    echo -e "${GREEN}✅ The run_miner.sh script has been generated and is ready to use!${RESET}"
    echo -e "${CYAN}  • This script will be called automatically when launching miners via the launcher.${RESET}"
    echo -e "${CYAN}  • You can also run it manually for advanced debugging: ${DIM}./run_miner.sh <miner_number>${RESET}"
    echo -e ""

    # External command entrypoints (for system automation/scripts)
    if [[ "${1:-}" == "--restart-miner" && -n "${2:-}" && -n "${3:-}" ]]; then
      MINING_KEY_DISPLAY="$3"
      restart_miner_session "$2"
      exit 0
    fi

    # Prompt for use of existing config if present
    if [[ -f "$LAUNCH_CFG" ]]; then
      echo ""
      echo -e "${BOLD_BLUE}${CYAN}⚙️  Miner Configuration${RESET}"
      echo -e "${DIM}──────────────────────────────────────────────${RESET}"
      echo ""
      cat "$LAUNCH_CFG"
      echo -e ""
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
      # Auto-detect NUM_MINERS from existing launch.cfg if keeping config
      if [[ "$USE_EXISTING_CFG" == "1" ]]; then
        LAUNCH_CFG="$SCRIPT_DIR/launch.cfg"
        if [[ -f "$LAUNCH_CFG" ]]; then
          NUM_MINERS=$(grep -c '^\[miner[0-9]\+\]' "$LAUNCH_CFG")
        else
          echo -e "${RED}❌ launch.cfg not found. Cannot determine number of miners.${RESET}"
          continue
        fi
      fi
    else
      USE_EXISTING_CFG=2
    fi

    clear

    # Custom setup sequence
    if [[ "$USE_EXISTING_CFG" == "2" ]]; then
      # Banner Step 1/4: Public Key
      strip_ansi() {
        echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
      }
      BANNER_TITLE="Step 1/4: Public Key"
      BANNER_PADDING=4
      banner_title_len=${#BANNER_TITLE}
      banner_inner_width=$((banner_title_len + BANNER_PADDING * 2))
      [[ $banner_inner_width -lt 80 ]] && banner_inner_width=80
      # Top border
      echo -e "${BOLD_BLUE}╔$(printf '═%.0s' $(seq 1 $banner_inner_width))╗${RESET}"
      # Centered title
      pad_total=$((banner_inner_width - banner_title_len))
      pad_left=$((pad_total / 2))
      pad_right=$((pad_total - pad_left))
      printf "${BOLD_BLUE}║%*s%s%*s║${RESET}\n" $pad_left "" "$BANNER_TITLE" $pad_right ""
      # Bottom border
      echo -e "${BOLD_BLUE}╚$(printf '═%.0s' $(seq 1 $banner_inner_width))╝${RESET}"
      echo -e ""

      # Check requiered
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
        if ! confirm_yes_no "Do you want to generate a new wallet now?"; then
          echo -e "${CYAN}Returning to menu...${RESET}"
          continue
        fi
        echo -e ""
        echo -e "${CYAN}>> Generating new wallet...${RESET}"
        nockchain-wallet keygen
        echo -e ""
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
        echo -e ""
        echo -e "${YELLOW}The following mining public key will be used:${RESET}"
        echo -e "${CYAN}$MINING_KEY${RESET}"
        echo -e ""
        if confirm_yes_no "Is this correct?"; then
          break
        fi
        echo -e ""
        echo -e "${YELLOW}Please enter the correct mining public key:${RESET}"
        read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" MINING_KEY
        sed -i "s/^MINING_PUBKEY=.*/MINING_PUBKEY=$MINING_KEY/" .env
      done

      clear

      # Banner Step 2/4: Miner Config
      strip_ansi() {
        echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
      }
      BANNER_TITLE="Step 2/4: Miner Config"
      BANNER_PADDING=4
      banner_title_len=${#BANNER_TITLE}
      banner_inner_width=$((banner_title_len + BANNER_PADDING * 2))
      [[ $banner_inner_width -lt 80 ]] && banner_inner_width=80
      # Top border
      echo -e "${BOLD_BLUE}╔$(printf '═%.0s' $(seq 1 $banner_inner_width))╗${RESET}"
      # Centered title
      pad_total=$((banner_inner_width - banner_title_len))
      pad_left=$((pad_total / 2))
      pad_right=$((pad_total - pad_left))
      printf "${BOLD_BLUE}║%*s%s%*s║${RESET}\n" $pad_left "" "$BANNER_TITLE" $pad_right ""
      # Bottom border
      echo -e "${BOLD_BLUE}╚$(printf '═%.0s' $(seq 1 $banner_inner_width))╝${RESET}"

      # System spec detection
      CPU_PHYSICAL=$(lscpu | awk '/^Core\(s\) per socket:/ {cores=$4} /^Socket\(s\):/ {sockets=$2} END {print cores*sockets}')
      CPU_THREADS=$(nproc)
      RAM_TOTAL=$(free -g | awk '/^Mem:/ {print $2}')
      RAM_TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
      echo -e "${RESET}"
      echo -e "${GREEN}Detected system:${RESET} 🖥️  ${BOLD_BLUE}${CPU_PHYSICAL}${RESET} physical cores, ${BOLD_BLUE}${CPU_THREADS}${RESET} threads   |   🧠  ${BOLD_BLUE}${RAM_TOTAL}${RESET} GB RAM (${RAM_TOTAL_MB} MB)"
      echo -e ""
      echo -e ""
      echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────${RESET}"
      echo -e "${BOLD_BLUE}How resources work in Nockchain mining:${RESET}"
      echo -e "  • Each miner process runs independently and uses 1 or more CPU threads."
      echo -e "  • ${YELLOW}--num-threads${RESET} controls CPU threads.  ${YELLOW}--stack-size${RESET} is the *total* RAM (not per-thread)."
      echo -e "  • Example: ${CYAN}--stack-size medium${RESET} = reserves 16 GB RAM for that process, even if it uses 1 or 10 threads."
      echo -e ""
      echo -e "${CYAN}Available stack sizes:${RESET}  ${DIM}tiny${RESET}: 2 GB   | ${DIM}small${RESET}: 4 GB   | ${DIM}normal${RESET}: 8 GB   | ${DIM}medium${RESET}: 16 GB   | ${DIM}large${RESET}: 32 GB   | ${DIM}huge${RESET}: 64 GB"
      echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────────────────${RESET}"
      echo -e ""

      # Stack-size RAMs
      declare -A STACK_RAM=([huge]=64 [big]=32 [large]=32 [medium]=16 [normal]=8 [small]=4 [tiny]=2)
      STACKS=(huge big large medium normal small tiny)

      RESERVE_RAM=4 # Always leave 4GB for OS
      SYNC_MINER_THREADS=1
      SYNC_MINER_STACK=""
      SYNC_MINER_RAM=2 # Reserve 2GB for sync-only miner

      CPU_THREADS_INT=${CPU_THREADS:-$(nproc)}
      RAM_TOTAL_INT=${RAM_TOTAL:-$(free -g | awk '/^Mem:/ {print $2}')}
      RAM_USABLE=$((RAM_TOTAL_INT - RESERVE_RAM - SYNC_MINER_RAM))
      THREADS_USABLE=$((CPU_THREADS_INT - SYNC_MINER_THREADS))

      declare -A miners_config
      miners_config[1, "mode"]="sync-only"
      miners_config[1, "threads"]=$SYNC_MINER_THREADS
      miners_config[1, "stack"]="$SYNC_MINER_STACK"
      miners_config[1, "ram"]=$SYNC_MINER_RAM

      miner_id=2
      threads_left=$THREADS_USABLE
      ram_left=$RAM_USABLE

      # Fill threads FIRST, using largest stack-size possible per miner for remaining RAM
      while ((threads_left > 0 && ram_left >= 2)); do
        for stack in "${STACKS[@]}"; do
          stack_ram=${STACK_RAM[$stack]}
          # Only use a miner if it fits in RAM left
          if ((ram_left < stack_ram)); then
            continue
          fi
          # Find max threads we can give this miner, given the remaining threads (but at least 1)
          max_threads_this_miner=$threads_left
          ((max_threads_this_miner < 1)) && continue
          # Assign as many threads as possible to the biggest stack-size that fits, then continue
          miners_config[$miner_id, "mode"]="mining"
          miners_config[$miner_id, "threads"]=$max_threads_this_miner
          miners_config[$miner_id, "stack"]=$stack
          miners_config[$miner_id, "ram"]=$stack_ram
          threads_left=$((threads_left - max_threads_this_miner))
          ram_left=$((ram_left - stack_ram))
          miner_id=$((miner_id + 1))
          break # Always use the biggest available stack for each miner, then re-loop
        done
      done

      # Helper: Remove ANSI escape sequences for accurate width calculation
      strip_ansi() {
        echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
      }
      # Prepare all miner lines (strip color for width calculation)
      BOX_TITLE=" Recommended Mining Layout "
      BOX_PADDING=2 # spaces on each side
      miner_lines_nocolor=()
      miner_lines_colored=()
      max_line_len=80
      for ((i = 1; i < miner_id; i++)); do
        mode=${miners_config[$i, "mode"]}
        threads=${miners_config[$i, "threads"]}
        stack=${miners_config[$i, "stack"]}
        ram=${miners_config[$i, "ram"]}
        miner_label="miner$i"
        if [[ "$mode" == "sync-only" ]]; then
          # No color, for length (do not display thread count for sync-only)
          line_nocolor=$(printf "%-8s: %-9s   (no stack-size, ~2GB RAM reserved)" \
            "$miner_label" "sync-only")
          # Color version
          line_colored="${BOLD_BLUE}${miner_label}${RESET}: ${CYAN}sync-only${RESET}   ${DIM}(no stack-size, ~2GB RAM reserved)${RESET}"
        else
          line_nocolor=$(printf "%-8s: %-9s, %2s thread(s), --stack-size %s ( %2s GB )" \
            "$miner_label" "mining" "$threads" "$stack" "$ram")
          line_colored="${miner_label}: ${GREEN}mining${RESET}, ${YELLOW}$threads${RESET} thread(s), --stack-size ${CYAN}$stack${RESET} ( ${YELLOW}$ram${RESET} GB )"
        fi
        miner_lines_nocolor+=("$line_nocolor")
        miner_lines_colored+=("$line_colored")
        # Update max width
        ((${#line_nocolor} > max_line_len)) && max_line_len=${#line_nocolor}
      done
      # Compare with title length (strip color)
      box_title_len=${#BOX_TITLE}
      content_width=$box_title_len
      ((max_line_len > content_width)) && content_width=$max_line_len
      # Add padding (left+right)
      box_inner_width=$((content_width + BOX_PADDING * 2))
      # Borders: "╭" + "─" * box_inner_width + "╮"
      echo -e "${BOLD_BLUE}╭$(printf '─%.0s' $(seq 1 $box_inner_width))╮${RESET}"
      # Print centered title with padding
      pad_total=$((box_inner_width - box_title_len))
      pad_left=$((pad_total / 2))
      pad_right=$((pad_total - pad_left))
      printf "${BOLD_BLUE}│%*s%s%*s│${RESET}\n" $pad_left "" "$BOX_TITLE" $pad_right ""
      # Print each miner line, with left/right padding, right border always aligned
      for idx in "${!miner_lines_colored[@]}"; do
        colored="${miner_lines_colored[$idx]}"
        nocolor="$(strip_ansi "$colored")"
        pad_right=$((content_width - ${#nocolor}))
        printf "${BOLD_BLUE}│${RESET}%*s%b%*s${BOLD_BLUE}│${RESET}\n" $BOX_PADDING "" "$colored" $((BOX_PADDING + pad_right)) ""
      done
      # Bottom border
      echo -e "${BOLD_BLUE}╰$(printf '─%.0s' $(seq 1 $box_inner_width))╯${RESET}"

      total_mining_threads=0
      total_mining_ram=0
      for ((i = 2; i < miner_id; i++)); do
        ((total_mining_threads += miners_config[$i, "threads"]))
        ((total_mining_ram += miners_config[$i, "ram"]))
      done

      RAM_LEFT_FOR_OS=$((RAM_TOTAL_INT - total_mining_ram - SYNC_MINER_RAM))
      [[ $RAM_LEFT_FOR_OS -lt $RESERVE_RAM ]] && RAM_LEFT_FOR_OS=$RESERVE_RAM
      echo ""
      echo -e "${DIM}Total mining: ${RESET}${YELLOW}$total_mining_threads${RESET} threads, ${YELLOW}$total_mining_ram${RESET} GB RAM  (plus ~2 GB for sync miner, plus OS headroom)"
      echo -e "${MAGENTA}System headroom left:${RESET} ${CYAN}$RAM_TOTAL_INT${RESET} GB - ${YELLOW}$total_mining_ram${RESET} GB - 2 GB ≈ ${YELLOW}$RAM_LEFT_FOR_OS${RESET} GB"
      echo ""
      echo ""
      echo -e "${RED}⚠️  Warning:${RESET} Maxing RAM and threads in a single miner can increase risk of a process crash = downtime."
      echo ""
      echo -e "${YELLOW}Pro tip:${RESET} To reduce risk, split miners (ex: 2×16 threads, 2×32 GB RAM) if you want more redundancy."
      echo ""
      echo -e "${DIM}This setup fills RAM and threads for max mining, always leaves a sync-only node, and auto-recalculates for any server.${RESET}"
      echo ""
      echo ""
      echo -e "${YELLOW}Choose launch mode:${RESET}"
      echo -e "  1) ${BOLD_BLUE}Use recommended config${RESET}  ${DIM}(auto-optimize)${RESET}"
      echo -e "  2) ${BOLD_BLUE}Custom (advanced setup)${RESET}"

      while true; do
        read -rp "$(echo -e \"${BOLD_BLUE} choice [1/2]: ${RESET}\")" LAUNCH_MODE
        [[ \"$LAUNCH_MODE\" == \"1\" || \"$LAUNCH_MODE\" == \"2\" ]] && break
        echo -e \"${RED}❌ Invalid input. Please enter 1 or 2.${RESET}\"
      done

      clear

      if [[ "$LAUNCH_MODE" == "1" ]]; then
        NUM_MINERS=$((miner_id - 1))
        declare -A PER_MINER_THREADS
        declare -A PER_MINER_STACK
        declare -A PER_MINER_SYNCONLY

        # Use recommended miner config as built above for all details
        for i in $(seq 1 $NUM_MINERS); do
          miner="miner$i"
          mode="${miners_config[$i, "mode"]}"
          threads="${miners_config[$i, "threads"]}"
          stack="${miners_config[$i, "stack"]}"

          [[ "$mode" == "sync-only" ]] && PER_MINER_SYNCONLY["$miner"]=1 || PER_MINER_SYNCONLY["$miner"]=0
          PER_MINER_THREADS["$miner"]=$threads
          PER_MINER_STACK["$miner"]=$stack
        done
      elif [[ "$LAUNCH_MODE" == "2" ]]; then
        # --- Custom Miner Setup ---
        while true; do
          # Prompt FIRST for sync-only for miner 1
          SYNC_ONLY_FIRST=0
          echo -e ""
          echo -e "${BOLD_YELLOW}Miner 1:${RESET}"
          echo ""
          echo -e "${YELLOW}(Recommended) Running your first miner as sync-only (no mining) helps ensure you always have a node that keeps up with the chain, regardless of mining load on other nodes.${RESET}"
          echo ""
          echo -e "${BOLD_BLUE}  ➤ Sync-only means:${RESET} This node will stay up-to-date with the chain but does not mine new blocks. This is usually the safest, most stable setup for your first node, especially on servers with many miners."
          echo ""
          echo -e "${BOLD_BLUE}  ➤ You can choose to mine with all your nodes if you wish, but having a dedicated sync-only node is strongly advised unless you have a specific reason not to.${RESET}"
          echo ""
          echo -e "${CYAN}💾 Why is this important?${RESET}"
          echo -e "${DIM}  - The sync-only node is highly resilient and won’t crash due to mining. If a miner process fails, you always have a clean, synced node ready.${RESET}"
          echo -e "${DIM}  - If you enable periodic state.jam backups (see Option 6 in the main menu), an automated backup will save the latest state.jam from the most up-to-date node every hour. This gives you a much better chance of having the very latest chain state ready for fast recovery if needed.${RESET}"
          echo -e "${DIM}  - In case of a miner crash or server reboot, this lets you instantly recover—no long resync required, just restore the latest state.jam.${RESET}"
          echo -e "${DIM}  - Even if all mining nodes fail, your sync-only node will help keep your data safe and ready for a quick restart.${RESET}"
          echo ""
          if confirm_yes_no "${BOLD_YELLOW}Run miner 1 in sync-only mode (no mining)?${RESET}"; then
            SYNC_ONLY_FIRST=1
          else
            SYNC_ONLY_FIRST=0
          fi
          # Now prompt for number of miners
          if [[ "$SYNC_ONLY_FIRST" == "1" ]]; then
            echo ""
            echo -e "${YELLOW}How many total miners do you want to run (including the sync-only node)?${RESET}"
            echo -e "${DIM}You chose to run miner 1 as sync-only. For example, enter 2 for 1 sync-only node + 1 mining node.${RESET}"
          else
            echo ""
            echo -e "${YELLOW}How many miners do you want to run?${RESET}"
          fi
          echo ""
          echo -e "${DIM}Enter a number like 1, 3, 10... or type 'n' to cancel.${RESET}"
          echo ""
          read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" NUM_MINERS
          NUM_MINERS=$(echo "$NUM_MINERS" | tr -d '[:space:]')
          if [[ "$NUM_MINERS" =~ ^[Nn]$ || -z "$NUM_MINERS" ]]; then
            echo ""
            echo -e "${CYAN}Returning to menu...${RESET}"
            continue 2
          elif [[ "$NUM_MINERS" =~ ^[0-9]+$ && "$NUM_MINERS" -ge 1 ]]; then
            declare -A PER_MINER_SYNCONLY
            declare -A PER_MINER_THREADS
            declare -A PER_MINER_STACK
            # Set sync-only for miner 1 based on earlier answer
            if [[ "$SYNC_ONLY_FIRST" == "1" ]]; then
              PER_MINER_SYNCONLY["miner1"]=1
            else
              PER_MINER_SYNCONLY["miner1"]=0
            fi
            # If miner 1 is sync-only, do NOT ask for threads or stack size.
            if [[ "$SYNC_ONLY_FIRST" == "1" ]]; then
              PER_MINER_THREADS["miner1"]=""
              PER_MINER_STACK["miner1"]=""
              echo -e "${CYAN}Miner 1 is sync-only: Using default thread, default stack.${RESET}"
            else
              echo ""
              if confirm_yes_no "${YELLOW}Use multi-threading for miner 1?${RESET}"; then
                while true; do
                  echo -e "${YELLOW}How many threads for miner 1?${RESET}"
                  read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" THREADS
                  if [[ "$THREADS" =~ ^[0-9]+$ && "$THREADS" -ge 1 ]]; then
                    PER_MINER_THREADS["miner1"]=$THREADS
                    break
                  else
                    echo ""
                    echo -e "${RED}❌ Please enter a positive number.${RESET}"
                    echo ""
                  fi
                done
                # Strict stack size validation for miner 1
                VALID_STACKS=(tiny small normal medium large huge)
                while true; do
                  echo -e "${YELLOW}Stack size for miner 1 (e.g. tiny/small/normal/medium/large/huge, or leave empty for default):${RESET}"
                  echo -e "${DIM}tiny: 2GB, small: 4GB, normal: 8GB, medium: 16GB, large: 32GB, huge: 64GB${RESET}"
                  read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" STACKSIZE
                  lower_stacksize=$(echo "$STACKSIZE" | awk '{print tolower($0)}')
                  if [[ -z "$lower_stacksize" ]]; then
                    STACKSIZE=""
                    echo ""
                    break
                  fi
                  valid=0
                  for v in "${VALID_STACKS[@]}"; do
                    if [[ "$lower_stacksize" == "$v" ]]; then
                      STACKSIZE="$lower_stacksize"
                      valid=1
                      break
                    fi
                  done
                  if [[ $valid -eq 1 ]]; then
                    echo ""
                    break
                  else
                    echo -e "${RED}❌ Invalid stack size. Please enter: tiny, small, normal, medium, large, huge, or leave empty.${RESET}"
                  fi
                done
                PER_MINER_STACK["miner1"]=$STACKSIZE
              else
                PER_MINER_THREADS["miner1"]=1
                PER_MINER_STACK["miner1"]=""
                echo ""
              fi
            fi
            # For other miners
            for i in $(seq 2 $NUM_MINERS); do
              echo ""
              echo -e "${CYAN}Miner $i:${RESET}"
              PER_MINER_SYNCONLY["miner$i"]=0
              if confirm_yes_no "${YELLOW}Use multi-threading for miner $i?${RESET}"; then
                while true; do
                  echo -e "${YELLOW}How many threads for miner $i?${RESET}"
                  read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" THREADS
                  if [[ "$THREADS" =~ ^[0-9]+$ && "$THREADS" -ge 1 ]]; then
                    PER_MINER_THREADS["miner$i"]=$THREADS
                    break
                  else
                    echo -e "${RED}❌ Please enter a positive number.${RESET}"
                  fi
                done
                # Strict stack size validation for miner $i
                VALID_STACKS=(tiny small normal medium large huge)
                while true; do
                  echo -e "${YELLOW}Stack size for miner $i (e.g. tiny/small/normal/medium/large/huge, or leave empty for default):${RESET}"
                  echo -e "${DIM}tiny: 2GB, small: 4GB, normal: 8GB, medium: 16GB, large: 32GB, huge: 64GB${RESET}"
                  read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" STACKSIZE
                  lower_stacksize=$(echo "$STACKSIZE" | awk '{print tolower($0)}')
                  if [[ -z "$lower_stacksize" ]]; then
                    STACKSIZE=""
                    echo ""
                    break
                  fi
                  valid=0
                  for v in "${VALID_STACKS[@]}"; do
                    if [[ "$lower_stacksize" == "$v" ]]; then
                      STACKSIZE="$lower_stacksize"
                      valid=1
                      break
                    fi
                  done
                  if [[ $valid -eq 1 ]]; then
                    echo ""
                    break
                  else
                    echo -e "${RED}❌ Invalid stack size. Please enter: tiny, small, normal, medium, large, huge, or leave empty.${RESET}"
                  fi
                done
                PER_MINER_STACK["miner$i"]=$STACKSIZE
              else
                PER_MINER_THREADS["miner$i"]=""
                PER_MINER_STACK["miner$i"]=""
                echo ""
              fi
            done
            echo ""
            break
          else
            echo ""
            echo -e "${RED}❌ Invalid input. Please enter a positive number (e.g. 1, 3) or 'n' to cancel.${RESET}"
            echo ""
          fi
        done
      fi

      # Build mining summary arrays and print config table
      unset miners_config
      declare -A miners_config

      for i in $(seq 1 $NUM_MINERS); do
        miner="miner$i"
        mode="mining"
        [[ "${PER_MINER_SYNCONLY[$miner]}" == "1" ]] && mode="sync-only"
        miners_config[$i, "mode"]="$mode"
        if [[ "$mode" == "sync-only" ]]; then
          miners_config[$i, "threads"]="--"
          miners_config[$i, "stack"]="--"
          miners_config[$i, "ram"]="--"
        else
          miners_config[$i, "threads"]="${PER_MINER_THREADS[$miner]}"
          miners_config[$i, "stack"]="${PER_MINER_STACK[$miner]}"
          # Map stack-size to RAM in GB
          case "${PER_MINER_STACK[$miner]}" in
          tiny) miners_config[$i, "ram"]=2 ;;
          small) miners_config[$i, "ram"]=4 ;;
          normal) miners_config[$i, "ram"]=8 ;;
          medium) miners_config[$i, "ram"]=16 ;;
          large) miners_config[$i, "ram"]=32 ;;
          huge) miners_config[$i, "ram"]=64 ;;
          "" | "default") miners_config[$i, "ram"]="--" ;;
          *) miners_config[$i, "ram"]="--" ;;
          esac
        fi
      done

      echo ""
      echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════"
      echo -e "            MINING CONFIGURATION SUMMARY"
      echo -e "═══════════════════════════════════════════════════════════════════════════════${RESET}"
      echo ""
      printf "${BOLD_BLUE}%-10s %-10s %-10s %-15s %-15s %-10s${RESET}\n" "Miner" "Mode" "Threads" "Stack-size" "Stack RAM (GB)" "Flags"
      for ((i = 1; i <= NUM_MINERS; i++)); do
        miner="miner$i"
        mode="${miners_config[$i, "mode"]}"
        threads="${miners_config[$i, "threads"]}"
        stack="${miners_config[$i, "stack"]}"
        stack_ram="${miners_config[$i, "ram"]}"
        flags=""
        if [[ "$mode" == "sync-only" ]]; then
          threads="--"
          stack="--"
          stack_ram="--"
          flags="(sync)"
        else
          [[ -z "$threads" ]] && threads="default"
          [[ -z "$stack" ]] && stack="default"
          [[ -z "$stack_ram" ]] && stack_ram="--"
          flags="--mine"
        fi
        printf "${CYAN}%-10s${RESET} %-10s %-10s %-15s %-15s %-10s\n" "$miner" "$mode" "$threads" "$stack" "$stack_ram" "$flags"
      done
      echo ""
      echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════${RESET}\n"
      echo ""
      echo ""
      confirm_yes_no "Proceed with this config?" || {
        echo ""
        echo -e "${CYAN}Returning to menu...${RESET}"
        echo ""
        continue
      }

      clear

      # Banner Step 3/4: Network Config
      strip_ansi() {
        echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
      }
      BANNER_TITLE="Step 3/4: Network Config"
      BANNER_PADDING=4
      banner_title_len=${#BANNER_TITLE}
      banner_inner_width=$((banner_title_len + BANNER_PADDING * 2))
      [[ $banner_inner_width -lt 80 ]] && banner_inner_width=80
      # Top border
      echo -e "${BOLD_BLUE}╔$(printf '═%.0s' $(seq 1 $banner_inner_width))╗${RESET}"
      # Centered title
      pad_total=$((banner_inner_width - banner_title_len))
      pad_left=$((pad_total / 2))
      pad_right=$((pad_total - pad_left))
      printf "${BOLD_BLUE}║%*s%s%*s║${RESET}\n" $pad_left "" "$BANNER_TITLE" $pad_right ""
      # Bottom border
      echo -e "${BOLD_BLUE}╚$(printf '═%.0s' $(seq 1 $banner_inner_width))╝${RESET}"
      echo -e ""

      # Configure and enable required UFW firewall rules for Nockchain
      echo ""
      echo -e ""
      echo -e "${CYAN}\e[1m▶ Configuring firewall...${RESET}"
      sudo ufw allow ssh >/dev/null 2>&1 || true
      sudo ufw allow 22 >/dev/null 2>&1 || true
      sudo ufw allow 3005/tcp >/dev/null 2>&1 || true
      sudo ufw allow 3006/tcp >/dev/null 2>&1 || true
      sudo ufw allow 3005/udp >/dev/null 2>&1 || true
      sudo ufw allow 3006/udp >/dev/null 2>&1 || true
      sudo ufw --force enable >/dev/null 2>&1 || echo -e "${YELLOW}Warning: Failed to enable UFW. Continuing script execution.${RESET}"
      echo -e "${GREEN}✅ Firewall configured.${RESET}"
      echo -e ""

      # Prompt for max connections per miner
      echo ""
      echo -e "${YELLOW}Do you want to set a maximum number of connections per miner?${RESET}"
      echo -e ""
      echo -e "${DIM}32 is often a safe value. Leave empty to skip this option.${RESET}"
      echo ""
      read -rp "$(echo -e "${BOLD_BLUE}> Enter value or press enter: ${RESET}")" MAX_ESTABLISHED

      # Prompt for peer mode
      echo ""
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
          echo -e ""
          echo -e "${RED}❌ Invalid input. Enter 1, 2, 3, or 4.${RESET}"
          echo -e ""
        fi
      done

      # Prompt for BASE_PORT if needed
      if [[ "$PEER_MODE" == "2" || "$PEER_MODE" == "3" ]]; then
        echo ""
        echo -e "${YELLOW}Enter a base UDP port for miner communication (recommended: 40000):${RESET}"
        echo ""
        read -rp "$(echo -e "${BOLD_BLUE}> ${RESET}")" BASE_PORT_INPUT
        BASE_PORT_INPUT=$(echo "$BASE_PORT_INPUT" | tr -d '[:space:]')
        if [[ -z "$BASE_PORT_INPUT" ]]; then
          BASE_PORT=40000
        elif ! [[ "$BASE_PORT_INPUT" =~ ^[0-9]+$ ]] || ((BASE_PORT_INPUT < 1024 || BASE_PORT_INPUT > 65000)); then
          echo -e ""
          echo -e "${RED}❌ Invalid port. Using default 40000.${RESET}"
          echo -e ""
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
        # Central node: miner1 is central, no peer flag for miner1; others peer to miner1
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

      # Compute NUM_THREADS_FLAG for all miners
      declare -A NUM_THREADS_FLAG_MAP
      for i in $(seq 1 "$NUM_MINERS"); do
        MINER_NAME="miner$i"
        THREADS="${PER_MINER_THREADS[$MINER_NAME]}"
        MODE="${PER_MINER_SYNCONLY[$MINER_NAME]}"
        if [[ "$MODE" == "1" ]]; then
          NUM_THREADS_FLAG_MAP["$MINER_NAME"]=""
        elif [[ -n "$THREADS" ]]; then
          NUM_THREADS_FLAG_MAP["$MINER_NAME"]="--num-threads $THREADS"
        else
          NUM_THREADS_FLAG_MAP["$MINER_NAME"]=""
        fi
      done

      # Compute PER_MINER_STACK_MAP for all miners
      declare -A PER_MINER_STACK_MAP
      for i in $(seq 1 "$NUM_MINERS"); do
        MINER_NAME="miner$i"
        STACK="${PER_MINER_STACK[$MINER_NAME]}"
        if [[ -n "$STACK" ]]; then
          PER_MINER_STACK_MAP["$MINER_NAME"]="--stack-size $STACK"
        else
          PER_MINER_STACK_MAP["$MINER_NAME"]=""
        fi
      done

      {
        # Write BASE_PORT if set
        [[ -n "$BASE_PORT" ]] && echo "BASE_PORT=$BASE_PORT"
        for i in $(seq 1 "$NUM_MINERS"); do
          MINER_NAME="miner$i"
          echo ""
          echo "[$MINER_NAME]"
          if [[ "${PER_MINER_SYNCONLY[$MINER_NAME]}" == "1" ]]; then
            echo "MINE_FLAG="
          else
            echo "MINE_FLAG=--mine"
          fi
          echo "MINING_KEY=$MINING_KEY"
          echo "BIND_FLAG=${BIND_FLAG_MAP[$MINER_NAME]:-}"
          echo "PEER_FLAG=${PEER_FLAG_MAP[$MINER_NAME]:-}"
          echo "MAX_ESTABLISHED_FLAG=${MAX_ESTABLISHED_FLAG_MAP[$MINER_NAME]:-}"
          echo "NUM_THREADS_FLAG=${NUM_THREADS_FLAG_MAP[$MINER_NAME]:-}"
          echo "PER_MINER_STACK_FLAG=${PER_MINER_STACK_MAP[$MINER_NAME]:-}"
          echo "EXTRA_FLAGS="
          echo "STATE_FLAG=--state-jam ../state.jam"
        done
      } >"$LAUNCH_CFG"
      echo -e ""
      echo -e "${GREEN}📁 Configuration saved to: $LAUNCH_CFG${RESET}"

    fi

    clear

    # Banner Step 4/4: Final Preview
    strip_ansi() {
      echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
    }
    BANNER_TITLE="Final Preview"
    BANNER_PADDING=4
    banner_title_len=${#BANNER_TITLE}
    banner_inner_width=$((banner_title_len + BANNER_PADDING * 2))
    [[ $banner_inner_width -lt 80 ]] && banner_inner_width=80
    # Top border
    echo -e "${BOLD_BLUE}╔$(printf '═%.0s' $(seq 1 $banner_inner_width))╗${RESET}"
    # Centered title
    pad_total=$((banner_inner_width - banner_title_len))
    pad_left=$((pad_total / 2))
    pad_right=$((pad_total - pad_left))
    printf "${BOLD_BLUE}║%*s%s%*s║${RESET}\n" $pad_left "" "$BANNER_TITLE" $pad_right ""
    # Bottom border
    echo -e "${BOLD_BLUE}╚$(printf '═%.0s' $(seq 1 $banner_inner_width))╝${RESET}"
    echo -e ""

    # Check launch.cfg
    if [[ -f "$LAUNCH_CFG" ]]; then
      cat "$LAUNCH_CFG"
    else
      echo -e "${RED}❌ Configuration file not found.${RESET}"
    fi

    echo -e ""
    echo -e "${BOLD_BLUE}${CYAN}═══════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e ""
    echo -e "${BOLD_BLUE}${CYAN}═══════════════════════════════════════════════════════════════════════════════"
    echo -e "            LAUNCH PREVIEW"
    echo -e "═══════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e ""
    printf "  ${CYAN}%-10s %-22s %-22s${RESET}\n" "Miner" "Systemd Service" "Run Command"
    for i in $(seq 1 "$NUM_MINERS"); do
      MINER_NAME="miner$i"
      DIR="$NOCKCHAIN_HOME/$MINER_NAME"
      SERVICE="nockchain-miner$i.service"
      RUN_CMD="cd $DIR && exec run_miner.sh $i"
      printf "  ${BOLD_BLUE}%-10s${RESET} %-22s %-22s\n" "$MINER_NAME" "$SERVICE" "$RUN_CMD"
    done
    echo ""
    echo -e "${BOLD_BLUE}${CYAN}═══════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e ""

    # Ensure Nockchain binary exists and is executable
    require_nockchain "You must have a valid Nockchain binary before launching miners." || continue
    ensure_nockchain_executable

    echo -e "${BOLD}${CYAN}You're ready to launch your Nockchain miners!${RESET}"
    echo -e "${CYAN}All selected miners will be launched using the above configuration."
    echo ""

    if ! confirm_yes_no "${BOLD_YELLOW}Start Nockchain miner(s) with this configuration?${RESET}"; then
      echo -e ""
      echo -e "${YELLOW}Action cancelled. No miners launched.${RESET}"
      echo -e "${CYAN}Press Enter to return to the main menu...${RESET}"
      read -r
      continue
    fi
    echo -e ""
    echo -e "${GREEN}Proceeding with miner launch...${RESET}"
    echo -e ""
    echo -e "${CYAN}🧠 Power user tip: You can edit advanced miner options at any time!${RESET}"
    echo -e "${CYAN}   To customize peer mode, network ports, state.jam path, thread counts, stack size, mining flags, or any extra arguments, just open your launch config:${RESET}"
    echo -e "${BOLD_BLUE}   $LAUNCH_CFG${RESET}"
    echo -e "${DIM}   (Any changes here will apply the next time you launch or restart miners.)${RESET}"
    echo -e ""
    for i in $(seq 1 "$NUM_MINERS"); do
      MINER_DIR="$NOCKCHAIN_HOME/miner$i"
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
    ;;

  # ===== Main Menu Option 14 =====
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

  # ===== Main Menu Option 15 =====
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

  # ===== Main Menu Option 21 =====
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
    if require_nockchain ""; then
      echo -e "${GREEN}✔ nockchain binary present${RESET}"
    else
      echo -e "${RED}❌ nockchain binary missing${RESET}"
    fi
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

  # ===== Main Menu Option 22 =====
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

  # ===== Main Menu Option 23 =====
  23)
    clear
    ensure_fzf_installed
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

  # ===== Main Menu Option 24 =====
  24)
    clear
    ensure_fzf_installed
    echo -e "${CYAN}Clear Log Files${RESET}"
    echo ""

    # List of known log files
    declare -A LOG_FILES
    LOG_FILES["Build Log"]="$NOCKCHAIN_HOME/nockbuild.log"
    LOG_FILES["Update Log"]="$NOCKCHAIN_HOME/nockupdate.log"
    LOG_FILES["Wallet Update Log"]="$NOCKCHAIN_HOME/walletupdate.log"
    LOG_FILES["Statejam Backup Log"]="$NOCKCHAIN_HOME/statejam_backup.log"
    LOG_FILES["Export Log"]="$NOCKCHAIN_HOME/export.log"

    # Miner logs (only main logs and CSVs, not rotated logs)
    for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
      [[ -d "$miner_dir" ]] || continue
      miner_label=$(basename "$miner_dir")
      miner_log="$miner_dir/${miner_label}.log"
      if [[ -f "$miner_log" ]]; then
        LOG_FILES["${miner_label}.log"]="$miner_log"
      fi
      # Add miner CSV logs (block/proof logs)
      for csv in "$miner_dir"/*.csv; do
        [[ -f "$csv" ]] && LOG_FILES["${miner_label}/$(basename "$csv")"]="$csv"
      done
    done

    # Create the selection menu (fzf multi-select)
    LOG_SELECT_LIST=()
    for k in "${!LOG_FILES[@]}"; do
      if [[ -f "${LOG_FILES[$k]}" ]]; then
        LOG_SELECT_LIST+=("$k")
      fi
    done

    # Sort the log list using version sort for natural ordering
    IFS=$'\n' LOG_SELECT_LIST_SORTED=($(printf "%s\n" "${LOG_SELECT_LIST[@]}" | sort -V))
    LOG_SELECT_LIST=("${LOG_SELECT_LIST_SORTED[@]}")
    unset LOG_SELECT_LIST_SORTED

    # Concise ALL/CVS delete options as the first entries after cancel
    LOG_SELECT_LIST=(
      "↩️  Cancel and return to main menu"
      "🧹  Delete ALL logs (all logs + rotated logs + CSVs)"
      "🧹  Delete ALL miner logs (all miner.log & rotated logs)"
      "🧹  Delete ALL block CSV logs"
      "🧹  Delete ALL proof CSV logs"
      "🧹  Delete ALL CSV logs (block and proof)"
      "${LOG_SELECT_LIST[@]}"
    )

    if [[ ${#LOG_SELECT_LIST[@]} -le 2 ]]; then
      echo -e "${YELLOW}No log files found.${RESET}"
      read -n 1 -s -r -p $'\nPress any key to return to the menu...'
      continue
    fi

    # Use fzf for multi-select
    selected=$(printf "%s\n" "${LOG_SELECT_LIST[@]}" | fzf --multi --prompt="Select logs to delete: " \
      --pointer="👉" --color=prompt:blue,fg+:cyan,bg+:238,pointer:green,marker:green \
      --header=$'\nTAB to select, ENTER to confirm. ESC to cancel.\n')

    # If ESC pressed, or cancel option selected, return to menu
    if [[ -z "$selected" ]] || grep -Fxq "↩️  Cancel and return to main menu" <<<"$selected"; then
      echo -e "${YELLOW}No logs selected. Returning to menu.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # If "Delete ALL logs (all logs + rotated logs + CSVs)" is selected, confirmation and delete everything
    if grep -Fxq "🧹  Delete ALL logs (all logs + rotated logs + CSVs)" <<<"$selected"; then
      echo ""
      echo -e "${RED}⚠️  WARNING: You have selected to delete ALL logs.${RESET}"
      echo -e "${RED}This will permanently delete ALL log files and ALL rotated logs for ALL miners!${RESET}"
      echo -e "${RED}This action CANNOT be undone.${RESET}"
      echo -e ""
      if ! confirm_yes_no "Are you ABSOLUTELY sure you want to delete ALL logs?"; then
        echo -e "${YELLOW}Aborted.${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      fi
      # Delete all unique files in LOG_FILES
      declare -A DELETED_PATHS
      for path in "${LOG_FILES[@]}"; do
        [[ -f "$path" ]] || continue
        if [[ -z "${DELETED_PATHS[$path]:-}" ]]; then
          rm -f "$path"
          DELETED_PATHS["$path"]=1
        fi
      done
      # Delete all rotated logs for ALL miners
      for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
        [[ -d "$miner_dir" ]] || continue
        miner_label=$(basename "$miner_dir")
        rm -f "$miner_dir/$miner_label.log" "$miner_dir/$miner_label"-*.log
      done
      echo ""
      echo -e "${GREEN}✅ All logs and rotated logs have been deleted.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # If "Delete ALL miner logs (all miner.log & rotated logs)" is selected, confirmation and delete all miner logs only
    if grep -Fxq "🧹  Delete ALL miner logs (all miner.log & rotated logs)" <<<"$selected"; then
      echo ""
      echo -e "${RED}⚠️  WARNING: You have selected to delete ALL miner log files (.log and rotated logs) for ALL miners.${RESET}"
      echo -e "${RED}This will permanently delete all minerX.log and minerX-*.log files in ALL miner folders!${RESET}"
      echo -e "${RED}This action CANNOT be undone.${RESET}"
      echo -e ""
      if ! confirm_yes_no "Are you ABSOLUTELY sure you want to delete ALL miner log files?"; then
        echo -e "${YELLOW}Aborted.${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      fi
      deleted_count=0
      for miner_dir in "$NOCKCHAIN_HOME"/miner[0-9]*; do
        [[ -d "$miner_dir" ]] || continue
        miner_label=$(basename "$miner_dir")
        logs=("$miner_dir/$miner_label.log" "$miner_dir/$miner_label"-*.log)
        for logf in "${logs[@]}"; do
          [[ -f "$logf" ]] && rm -f "$logf" && ((deleted_count++))
        done
      done
      echo ""
      echo -e "${GREEN}✅ Deleted $deleted_count miner log files from all miner folders.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # If "Delete ALL CSV logs (block and proof)" is selected, confirmation and delete all CSVs
    if grep -Fxq "🧹  Delete ALL CSV logs (block and proof)" <<<"$selected"; then
      echo ""
      echo -e "${RED}⚠️  WARNING: You have selected to delete ALL miner .csv files.${RESET}"
      echo -e "${RED}This will permanently delete ALL CSV files in ALL miner folders!${RESET}"
      echo -e "${RED}This action CANNOT be undone.${RESET}"
      echo -e ""
      if ! confirm_yes_no "Are you ABSOLUTELY sure you want to delete ALL miner .csv files?"; then
        echo -e "${YELLOW}Aborted.${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      fi
      deleted_count=$(find "$NOCKCHAIN_HOME"/miner[0-9]* -type f -name "*.csv" -print -delete | wc -l)
      echo ""
      echo -e "${GREEN}✅ Deleted $deleted_count CSV files from all miner folders.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # If "Delete ALL block CSV logs" is selected
    if grep -Fxq "🧹  Delete ALL block CSV logs" <<<"$selected"; then
      echo ""
      echo -e "${RED}⚠️  WARNING: You have selected to delete ALL block log CSV files (minerX_block_log.csv).${RESET}"
      echo -e "${RED}This will permanently delete ALL block log CSV files in ALL miner folders!${RESET}"
      echo -e "${RED}This action CANNOT be undone.${RESET}"
      echo -e ""
      if ! confirm_yes_no "Are you ABSOLUTELY sure you want to delete ALL miner block log CSV files?"; then
        echo -e "${YELLOW}Aborted.${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      fi
      deleted_count=$(find "$NOCKCHAIN_HOME"/miner[0-9]* -type f -name "*_block_log.csv" -print -delete | wc -l)
      echo ""
      echo -e "${GREEN}✅ Deleted $deleted_count block log CSV files from all miner folders.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # If "Delete ALL proof CSV logs" is selected
    if grep -Fxq "🧹  Delete ALL proof CSV logs" <<<"$selected"; then
      echo ""
      echo -e "${RED}⚠️  WARNING: You have selected to delete ALL proof log CSV files (minerX_proof_log.csv).${RESET}"
      echo -e "${RED}This will permanently delete ALL proof log CSV files in ALL miner folders!${RESET}"
      echo -e "${RED}This action CANNOT be undone.${RESET}"
      echo -e ""
      if ! confirm_yes_no "Are you ABSOLUTELY sure you want to delete ALL miner proof log CSV files?"; then
        echo -e "${YELLOW}Aborted.${RESET}"
        echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
        read -n 1 -s
        continue
      fi
      deleted_count=$(find "$NOCKCHAIN_HOME"/miner[0-9]* -type f -name "*_proof_log.csv" -print -delete | wc -l)
      echo ""
      echo -e "${GREEN}✅ Deleted $deleted_count proof log CSV files from all miner folders.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # Otherwise, normal behavior for selected logs
    echo ""
    echo -e "${RED}WARNING: You are about to delete the following log files:${RESET}"
    echo -e "${DIM}$selected${RESET}"
    if ! confirm_yes_no "Are you sure you want to delete the selected log files?"; then
      echo -e "${YELLOW}Aborted.${RESET}"
      echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
      read -n 1 -s
      continue
    fi

    # Delete selected logs (skip cancel and ALL logs options)
    while IFS= read -r logname; do
      [[ "$logname" == "↩️  Cancel and return to main menu" ]] && continue
      [[ "$logname" == "🧹  Delete ALL logs (all logs + rotated logs + CSVs)" ]] && continue
      [[ "$logname" == "🧹  Delete ALL miner logs (all miner.log & rotated logs)" ]] && continue
      [[ "$logname" == "🧹  Delete ALL CSV logs (block and proof)" ]] && continue
      [[ "$logname" == "🧹  Delete ALL block CSV logs" ]] && continue
      [[ "$logname" == "🧹  Delete ALL proof CSV logs" ]] && continue
      logpath="${LOG_FILES[$logname]}"
      # If this is a minerX.log, delete all rotated logs as well
      if [[ "$logname" =~ ^miner[0-9]+\.log$ ]]; then
        miner_dir="$(dirname "$logpath")"
        miner_label="$(basename "$logpath" .log)"
        echo -e "${GREEN}Deleted:${RESET} $logname and all rotated logs"
        rm -f "$miner_dir/$miner_label.log" "$miner_dir/$miner_label"-*.log
      else
        if [[ -f "$logpath" ]]; then
          rm -f "$logpath"
          echo -e "${GREEN}Deleted:${RESET} $logname"
        fi
      fi
    done <<<"$selected"

    echo ""
    echo -e "${GREEN}✅ Selected logs cleared.${RESET}"
    echo -e "${YELLOW}Press any key to return to the main menu...${RESET}"
    read -n 1 -s
    continue
    ;;

  # ===== Main Menu Invalid Option =====
  *)
    echo -e "${RED}Invalid option selected. Returning to menu...${RESET}"
    sleep 1
    continue
    ;;
  esac

done
