#!/usr/bin/env bash

# upload_file
upload_file() {
  local FILE="$1"
  local CAPTION="${2:-}"

  if ! [[ -f $FILE ]]; then
    error "file $FILE doesn't exist"
  fi

  chmod 777 "$FILE"

  curl -s -F "document=@${FILE}" \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "message_thread_id=7" \
    -F "caption=${CAPTION}" \
    -F "parse_mode=markdown" \
    -F "disable_web_page_preview=true" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument"
}

# send_msg
send_msg() {
  local MESSAGE="$1"
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    -d "message_thread_id=7" \
    -d "disable_web_page_preview=true" \
    -d "parse_mode=markdown" \
    -d "text=$MESSAGE"
}

# westwood
use_westwood() {
  sed -i '/CONFIG_DEFAULT_TCP_CONG=/d' "$DEFCONFIG"
  sed -i '/CONFIG_DEFAULT_WESTWOOD/d' "$DEFCONFIG"

  sed -i '/CONFIG_TCP_CONG_BBRPLUS/d' "$DEFCONFIG"
  sed -i '/CONFIG_TCP_CONG_WESTWOOD/d' "$DEFCONFIG"

  echo "CONFIG_TCP_CONG_BBRPLUS=y" >> "$DEFCONFIG"
  echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
  echo "CONFIG_TCP_CONG_WESTWOOD=y" >> "$DEFCONFIG"

  echo "CONFIG_DEFAULT_WESTWOOD=y" >> "$DEFCONFIG"
  echo 'CONFIG_DEFAULT_TCP_CONG="westwood"' >> "$DEFCONFIG"
}

# bbrv3
use_bbr() {
  sed -i '/CONFIG_DEFAULT_TCP_CONG=/d' "$DEFCONFIG"
  sed -i '/CONFIG_DEFAULT_WESTWOOD/d' "$DEFCONFIG"

  sed -i '/CONFIG_TCP_CONG_BBRPLUS/d' "$DEFCONFIG"
  sed -i '/CONFIG_TCP_CONG_WESTWOOD/d' "$DEFCONFIG"

  echo "CONFIG_TCP_CONG_BBRPLUS=y" >> "$DEFCONFIG"
  echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
  echo "CONFIG_TCP_CONG_WESTWOOD=y" >> "$DEFCONFIG"

  echo "CONFIG_DEFAULT_BBR=y" >> "$DEFCONFIG"
  echo 'CONFIG_DEFAULT_TCP_CONG="bbr"' >> "$DEFCONFIG"
}

# bbrplus
use_bbrplus() {
  sed -i '/CONFIG_DEFAULT_TCP_CONG=/d' "$DEFCONFIG"
  sed -i '/CONFIG_DEFAULT_BBRPLUS/d' "$DEFCONFIG"

  sed -i '/CONFIG_TCP_CONG_WESTWOOD/d' "$DEFCONFIG"
  sed -i '/CONFIG_TCP_CONG_BBRPLUS/d' "$DEFCONFIG"

  echo "CONFIG_TCP_CONG_BBRPLUS=y" >> "$DEFCONFIG"
  echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
  echo "CONFIG_TCP_CONG_WESTWOOD=y" >> "$DEFCONFIG"

  echo "CONFIG_DEFAULT_BBRPLUS=y" >> "$DEFCONFIG"
  echo 'CONFIG_DEFAULT_TCP_CONG="bbrplus"' >> "$DEFCONFIG"
}

# KernelSU-related functions
install_ksu() {
  local REPO="$1"
  local REF="$2"
  local URL

  if [[ -z "$REPO" ]] || [[ -z "$REF" ]]; then
    echo "Usage: install_ksu <user/repo> <ref>"
    exit 1
  fi

  URL="https://raw.githubusercontent.com/$REPO/$REF/kernel/setup.sh"
  log "Installing KernelSU from $REPO | $REF"
  curl -LSs "$URL" | bash -s "$REF"
}

# ksu
ksu_included() {
  [[ $VARIANT != "VNL" ]]
  return $?
}

# susfs
susfs_included() {
  [[ "$VARIANT" == "SUSFS" ]]
  return $?
}

# simplify_gh_url
simplify_gh_url() {
  local URL="$1"
  echo "$URL" | sed "s|https://github.com/||g" | sed "s|.git||g"
}

# Kernel scripts function
config() {
  "$KSRC/scripts/config" --file "$DEFCONFIG_FILE" "$@"
}

# Logging function
log() {
  echo -e "[LOG] $*"
}

error() {
  local err_txt
  err_txt=$(
    cat << EOF
*Kernel CI*
ERROR: $*
EOF
  )
  echo -e "[ERROR] $*"
  send_msg "$err_txt"
  upload_file "$WORKDIR/build.log"
  exit 1
}
