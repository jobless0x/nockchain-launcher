#!/bin/bash

set -euo pipefail

CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

REPO_URL="git@github.com:jobless0x/nockchain-launcher.git"
CLONE_DIR="$HOME/githubLivePush"
TARGET_PATH="$CLONE_DIR/nockchain-launcher/state.jam"
LOCAL_STATE="$HOME/nockchain/state.jam"

# Ensure Git is installed
if ! command -v git &>/dev/null; then
  echo -e "${RED}❌ Git is not installed. Please install it first.${RESET}"
  exit 1
fi

# Ensure Git LFS is installed (only if missing)
if ! command -v git-lfs &>/dev/null; then
  echo -e "${YELLOW}⚠ git-lfs is not installed. Installing...${RESET}"
  sudo apt-get update && sudo apt-get install -y git-lfs
fi

echo ""
echo -e "${CYAN}🔐 Verifying Git SSH authentication...${RESET}"
SSH_OUTPUT=$(ssh -T git@github.com 2>&1 || true)
echo "$SSH_OUTPUT"

echo ""
if echo "$SSH_OUTPUT" | grep -q "successfully authenticated" || echo "$SSH_OUTPUT" | grep -q "does not provide shell access"; then
  echo -e "${GREEN}✅ SSH authentication to GitHub successful.${RESET}"
else
  echo -e "${RED}❌ SSH authentication failed. Make sure your SSH key is added to GitHub.${RESET}"
  exit 1
fi

# Prepare clean folder
rm -rf "$CLONE_DIR"
mkdir -p "$CLONE_DIR"
cd "$CLONE_DIR"

echo ""
echo -e "${CYAN}📦 Cloning repo into $CLONE_DIR...${RESET}"
GIT_LFS_SKIP_SMUDGE=1 git clone "$REPO_URL"
cd nockchain-launcher

echo ""
echo -e "${CYAN}🔍 Checking for existing state.jam...${RESET}"
if [[ ! -f "$LOCAL_STATE" ]]; then
  echo -e "${RED}❌ No local state.jam file found at $LOCAL_STATE${RESET}"
  exit 1
fi

echo ""
cp "$LOCAL_STATE" "state.jam"
echo -e "${GREEN}✅ Copied state.jam to repository.${RESET}"

echo ""

# Prompt for block number, format it, and confirm commit message
while true; do
  echo -ne "${CYAN}📦 Enter block number (e.g. 123233244244): ${RESET}"
  read BLOCK_INPUT
  if [[ "$BLOCK_INPUT" =~ ^[0-9]+$ ]]; then
    # Format block as groups of 3 digits from the right
    FORMATTED_BLOCK=$(echo "$BLOCK_INPUT" | rev | sed 's/\(...\)/\1./g' | rev | sed 's/^\.//' | sed 's/\.$//')
    COMMIT_MSG="chore(state): push state.jam snapshot at block $FORMATTED_BLOCK"
    echo -e "${CYAN}Proposed commit message:${RESET} ${GREEN}$COMMIT_MSG${RESET}"
    echo -ne "${CYAN}Confirm? (y/n): ${RESET}"
    read CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      break
    elif [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
      continue
    else
      echo -e "${RED}Invalid input. Please enter 'y' or 'n'.${RESET}"
    fi
  else
    echo -e "${RED}Invalid input. Please enter a numeric block number.${RESET}"
  fi
done

echo ""

# Prepare numbered state file for filebin if needed
NUMBERED_JAM="${BLOCK_INPUT}.jam"
cp "$LOCAL_STATE" "$NUMBERED_JAM"

# Prompt for upload destination
while true; do
  echo -e "${CYAN}Where do you want to upload state.jam?${RESET}"
  echo ""
  echo -e "  [1] ${GREEN}GitHub${RESET}  (recommended for permanent storage)"
  echo -e "  [2] ${YELLOW}Filebin${RESET}  (temporary 6-day share, URL: https://filebin.net/joblessnock/)"
  echo ""
  echo -ne "${CYAN}Enter your choice [1/2]: ${RESET}"
  read DEST_CHOICE
  if [[ "$DEST_CHOICE" =~ ^([1Gg])$ ]]; then
    UPLOAD_DEST="github"
    break
  elif [[ "$DEST_CHOICE" =~ ^([2Ff])$ ]]; then
    UPLOAD_DEST="filebin"
    break
  else
    echo -e "${RED}Invalid input. Please enter 1 for GitHub or 2 for Filebin.${RESET}"
  fi
done

if [[ "$UPLOAD_DEST" == "filebin" ]]; then
  echo ""
  echo -e "${CYAN}🚚 Uploading state.jam to filebin.net...${RESET}"
  RESPONSE=$(curl --upload-file "$NUMBERED_JAM" "https://filebin.net/joblessnock/$NUMBERED_JAM")
  URL="https://filebin.net/joblessnock/$NUMBERED_JAM"
  if [[ $? -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}✅ Uploaded to filebin:${RESET} $URL"
    # Log upload to statebin-uploads.txt in the repo
    UPLOAD_TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    LOG_LINE="$UPLOAD_TIMESTAMP | $NUMBERED_JAM | $URL"
    echo "$LOG_LINE" >>statebin-uploads.txt
    git add statebin-uploads.txt
    git commit -m "chore(state): push state.jam snapshot at block $FORMATTED_BLOCK" --no-verify
    git push
  else
    echo -e "${RED}❌ Upload to filebin failed.${RESET}"
    exit 1
  fi

  echo ""

  # Upload summary section for filebin
  echo -e "${YELLOW}====== UPLOAD SUMMARY ======${RESET}"
  echo ""
  echo -e "${CYAN}Block Number:${RESET} $BLOCK_INPUT"
  echo -e "${CYAN}Destination:${RESET} filebin"
  echo -e "${CYAN}File uploaded:${RESET} $NUMBERED_JAM"
  echo -e "${CYAN}Filebin URL:${RESET} $URL"
  echo -e "${CYAN}Commit message:${RESET} chore(state): push state.jam snapshot at block $FORMATTED_BLOCK"
  echo -e "${CYAN}Last 3 filebin uploads:${RESET}"
  LOG_LINES=$(tail -n 3 statebin-uploads.txt)
  while IFS= read -r line; do
    echo -e "${line//jobless/joblessnock}"
    echo ""
  done <<<"$LOG_LINES"
  echo -e "${YELLOW}=============================${RESET}"
  echo ""

  # Clean up and exit
  echo -e "${GREEN}✅ Done. Cleaning up...${RESET}"
  cd ~
  rm -rf "$CLONE_DIR"
  rm -f "$NUMBERED_JAM"
  echo -e "${GREEN}✅ state.jam uploaded and cleaned.${RESET}"
  echo ""
  exit 0
fi

echo -e "${CYAN}🔃 Adding and committing state.jam...${RESET}"
git add state.jam
git commit -m "$COMMIT_MSG"
echo -e "${CYAN}🚀 Pushing to GitHub...${RESET}"
git push

echo ""

# Upload summary section for GitHub
echo -e "${YELLOW}====== UPLOAD SUMMARY ======${RESET}"
echo ""
echo -e "${CYAN}Block Number:${RESET} $BLOCK_INPUT"
echo -e "${CYAN}Destination:${RESET} GitHub"
echo -e "${CYAN}File uploaded:${RESET} state.jam"
echo -e "${CYAN}Commit message:${RESET} $COMMIT_MSG"
echo ""
echo -e "${YELLOW}=============================${RESET}"
echo ""

echo -e "${GREEN}✅ Done. Cleaning up...${RESET}"
cd ~
rm -rf "$CLONE_DIR"
echo -e "${GREEN}✅ state.jam uploaded and cleaned.${RESET}"
echo ""
