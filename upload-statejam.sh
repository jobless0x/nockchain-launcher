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

echo -e "${CYAN}🔐 Verifying Git SSH authentication...${RESET}"
SSH_OUTPUT=$(ssh -T git@github.com 2>&1 || true)
echo "$SSH_OUTPUT"

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

echo -e "${CYAN}📦 Cloning repo into $CLONE_DIR...${RESET}"
GIT_LFS_SKIP_SMUDGE=1 git clone "$REPO_URL"
cd nockchain-launcher

echo -e "${CYAN}🔍 Checking for existing state.jam...${RESET}"
if [[ ! -f "$LOCAL_STATE" ]]; then
  echo -e "${RED}❌ No local state.jam file found at $LOCAL_STATE${RESET}"
  exit 1
fi

cp "$LOCAL_STATE" "state.jam"
echo -e "${GREEN}✅ Copied state.jam to repository.${RESET}"


# Prompt for block number, format it, and confirm commit message
while true; do
  echo -ne "${CYAN}📦 Enter block number (e.g. 123233244244): ${RESET}"
  read BLOCK_INPUT
  if [[ "$BLOCK_INPUT" =~ ^[0-9]+$ ]]; then
    # Format block as groups of 3 digits from the right
    FORMATTED_BLOCK=$(echo "$BLOCK_INPUT" | rev | sed 's/...\B/./g' | rev)
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

echo -e "${CYAN}🔃 Adding and committing state.jam...${RESET}"
git add state.jam
git commit -m "$COMMIT_MSG"
echo -e "${CYAN}🚀 Pushing to GitHub...${RESET}"
git push

echo -e "${GREEN}✅ Done. Cleaning up...${RESET}"
cd ~
rm -rf "$CLONE_DIR"
echo -e "${GREEN}✅ state.jam uploaded and cleaned.${RESET}"