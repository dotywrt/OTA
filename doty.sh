#!/bin/sh

BASE_URL="https://api.dotycat.com"

SECRET_ID="$1"
TELEGRAM_USERNAME="$2"

TMP_BIN="/tmp/ota_firmware.bin"
REGISTER_JSON="/tmp/ota_register.json"
CHECK_JSON="/tmp/ota_check.json"

[ -z "$SECRET_ID" ] && echo "SECRET_ID required" && exit 1
[ -z "$TELEGRAM_USERNAME" ] && echo "TELEGRAM_USERNAME required. Example: @username" && exit 1

get_device_id() {
  if [ -f /sys/class/net/br-lan/address ]; then
    cat /sys/class/net/br-lan/address
    return
  fi

  if [ -f /sys/class/net/eth0/address ]; then
    cat /sys/class/net/eth0/address
    return
  fi

  if [ -f /sys/class/net/wan/address ]; then
    cat /sys/class/net/wan/address
    return
  fi

  if [ -f /sys/class/ieee80211/phy0/macaddress ]; then
    cat /sys/class/ieee80211/phy0/macaddress
    return
  fi

  if command -v ip >/dev/null 2>&1; then
    ip link | awk '/link\/ether/ {print $2; exit}'
    return
  fi

  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig | awk '/HWaddr|ether/ {print $5; exit}'
    return
  fi

  hostname
}

urlencode() {
  echo "$1" | sed \
    -e 's/%/%25/g' \
    -e 's/ /%20/g' \
    -e 's/@/%40/g' \
    -e 's/:/%3A/g' \
    -e 's/\//%2F/g' \
    -e 's/&/%26/g' \
    -e 's/=/%3D/g' \
    -e 's/+/%2B/g'
}

RAW_DEVICE_ID="$(get_device_id | tr 'A-Z' 'a-z' | tr -d ' \n\r')"

if command -v md5sum >/dev/null 2>&1; then
  DEVICE_ID="$(echo -n "$RAW_DEVICE_ID" | md5sum | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  DEVICE_ID="$(echo -n "$RAW_DEVICE_ID" | sha256sum | awk '{print $1}')"
else
  DEVICE_ID="$RAW_DEVICE_ID"
fi

HOSTNAME="$(hostname 2>/dev/null | tr -d '\n\r')"
MODEL="$(cat /tmp/sysinfo/model 2>/dev/null | tr -d '\n\r')"
FIRMWARE="$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d\' -f2 | tr -d '\n\r')"

ENC_DEVICE_ID="$(urlencode "$DEVICE_ID")"
ENC_SECRET_ID="$(urlencode "$SECRET_ID")"
ENC_HOSTNAME="$(urlencode "$HOSTNAME")"
ENC_MODEL="$(urlencode "$MODEL")"
ENC_FIRMWARE="$(urlencode "$FIRMWARE")"
ENC_TELEGRAM_USERNAME="$(urlencode "$TELEGRAM_USERNAME")"

api_log() {
  ACTION="$(urlencode "$1")"
  MESSAGE="$(urlencode "$2")"

  RESPONSE="$(wget -qO- \
    --post-data="device_id=$ENC_DEVICE_ID&secret_id=$ENC_SECRET_ID&action=$ACTION&message=$MESSAGE" \
    "$BASE_URL/api/log" 2>/dev/null)"

  if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "Log sent to server: success"
  else
    echo "Log sent to server: failed"
  fi
}

api_log "install" "Script started"

wget -qO "$REGISTER_JSON" \
  --post-data="device_id=$ENC_DEVICE_ID&hostname=$ENC_HOSTNAME&model=$ENC_MODEL&firmware=$ENC_FIRMWARE&telegram_username=$ENC_TELEGRAM_USERNAME" \
  "$BASE_URL/api/register-device"

if grep -q '"ok":true' "$REGISTER_JSON"; then
  echo "Device registration sent to server: success"
else
  echo "Device registration sent to server: failed"
  cat "$REGISTER_JSON"
fi

CHECK_URL="$BASE_URL/api/check?device_id=$ENC_DEVICE_ID&secret_id=$ENC_SECRET_ID&hostname=$ENC_HOSTNAME&model=$ENC_MODEL&firmware=$ENC_FIRMWARE&telegram_username=$ENC_TELEGRAM_USERNAME"

wget -qO "$CHECK_JSON" "$CHECK_URL"

if ! grep -q '"ok":true' "$CHECK_JSON"; then

  if grep -q '"error":"device_not_approved"' "$CHECK_JSON"; then
    echo "Device not approved."
    echo "Encoded Device ID: $DEVICE_ID"
    echo "Please ask admin to approve this device."
    echo "Telegram admin: @anzclan"
    api_log "device_not_approved" "Device needs admin approval"
    exit 1
  fi

  if grep -q '"error":"invalid_secret_id"' "$CHECK_JSON"; then
    echo "Invalid Secret ID."
    echo "Please check your SECRET_ID."
    echo "Telegram admin: @anzclan"
    api_log "invalid_secret_id" "Invalid Secret ID"
    exit 1
  fi

  echo "Unknown API error."
  echo "Telegram admin: @anzclan"
  cat "$CHECK_JSON"
  api_log "upgrade_denied" "Unknown check failed"
  exit 1
fi

DOWNLOAD_URL="$BASE_URL/api/download?device_id=$ENC_DEVICE_ID&secret_id=$ENC_SECRET_ID"

api_log "download_start" "Downloading firmware"

wget -O "$TMP_BIN" "$DOWNLOAD_URL" || {
  api_log "download_failed" "wget failed"
  exit 1
}

if [ ! -s "$TMP_BIN" ]; then
  api_log "download_failed" "empty file"
  exit 1
fi

api_log "download_complete" "Firmware downloaded"

if command -v sysupgrade >/dev/null 2>&1; then
  api_log "sysupgrade_start" "Running sysupgrade"
  sysupgrade "$TMP_BIN"
else
  echo "sysupgrade command not found. Firmware saved at $TMP_BIN"
  api_log "sysupgrade_missing" "sysupgrade not found"
fi
