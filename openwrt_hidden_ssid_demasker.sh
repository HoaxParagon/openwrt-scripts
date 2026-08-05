#!/bin/sh
#
# wifi-scan-helper.sh  (ash / BusyBox compatible)
# Authorized testing of YOUR OWN network only.
# No airodump-ng / airmon-ng. Uses iw + (tshark or tcpdump).
#
# WARNING: Only run against networks you own or have explicit permission to test.
# Requires root and a wireless adapter that supports monitor mode.
#

set -eu

# ---------- defaults ----------
INTERFACE=""
CHANNELS=""                 # space-separated list; empty = build from band
BAND="bg"
WRITE_PREFIX=""
HIDDEN_MODE=0
UPDATE_INTERVAL=1
HELP=0
MON_IFACE=""
ORIGINAL_IFACE=""
SCAN_DIR=""
AP_FILE=""                  # temporary file holding "BSSID|CH|PWR|ESSID|TS"

# 2.4 GHz and common 5 GHz channels
CH_2G="1 2 3 4 5 6 7 8 9 10 11 12 13"
CH_5G="36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165"

cleanup() {
    echo
    echo "[*] Cleaning up..."
    if [ -n "$MON_IFACE" ]; then
        ip link set "$MON_IFACE" down 2>/dev/null || true
        iw dev "$MON_IFACE" del 2>/dev/null || true
    fi
    if [ -n "$ORIGINAL_IFACE" ]; then
        ip link set "$ORIGINAL_IFACE" up 2>/dev/null || true
    fi
    [ -n "$SCAN_DIR" ] && [ -d "$SCAN_DIR" ] && rm -rf "$SCAN_DIR"
    exit 0
}
trap 'cleanup' EXIT INT TERM

usage() {
    cat <<EOF
Usage: sudo $0 [options] <interface>

Options (airodump-ng style):
  -h, --help                  Show this help
  -c, --channel <ch>[,<ch>...]  Fixed channel(s). Overrides band hopping.
  -b, --band <abg...>         Band hint: a,b,g,n,ac (default: bg)
  -w, --write <prefix>        Write pcap with this prefix (tshark/tcpdump)
  --hidden                    Passive hidden-SSID focus
  -u, --update <secs>         Redisplay interval (default: 1)

Examples:
  sudo $0 wlan0
  sudo $0 -c 1,6,11 --hidden wlan0
  sudo $0 -b abg -w /tmp/scan --hidden wlan0

After the live scan press Ctrl+C. You will be asked for a comma-separated
list of result numbers (e.g. 1,3,2) to focus on.
EOF
    exit 0
}

# ---------- argument parsing ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) HELP=1; shift ;;
        -c|--channel)
            # convert commas to spaces
            CHANNELS=$(echo "$2" | tr ',' ' ')
            shift 2
            ;;
        -b|--band) BAND="$2"; shift 2 ;;
        -w|--write) WRITE_PREFIX="$2"; shift 2 ;;
        -u|--update) UPDATE_INTERVAL="$2"; shift 2 ;;
        --hidden) HIDDEN_MODE=1; shift ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            INTERFACE="$1"
            shift
            ;;
    esac
done

[ "$HELP" -eq 1 ] && usage
[ -z "$INTERFACE" ] && { echo "Error: interface required"; usage; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must be run as root"
    exit 1
fi

# ---------- tool detection ----------
HAS_TSHARK=0
HAS_TCPDUMP=0
command -v tshark  >/dev/null 2>&1 && HAS_TSHARK=1
command -v tcpdump >/dev/null 2>&1 && HAS_TCPDUMP=1
command -v iw      >/dev/null 2>&1 || { echo "iw is required"; exit 1; }
command -v ip      >/dev/null 2>&1 || { echo "ip is required"; exit 1; }

if [ "$HAS_TSHARK" -eq 0 ] && [ "$HAS_TCPDUMP" -eq 0 ]; then
    echo "Error: need tshark or tcpdump for monitor-mode capture"
    exit 1
fi

# ---------- build channel list from band if -c not given ----------
if [ -z "$CHANNELS" ]; then
    CHANNELS=""
    case "$BAND" in
        *a*|*n*|*ac*) CHANNELS="$CHANNELS $CH_5G" ;;
    esac
    case "$BAND" in
        *b*|*g*|*n*)  CHANNELS="$CHANNELS $CH_2G" ;;
    esac
    # unique + numeric sort
    CHANNELS=$(echo $CHANNELS | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')
fi
[ -z "$CHANNELS" ] && CHANNELS="1 6 11"

echo "[*] Interface : $INTERFACE"
echo "[*] Channels  : $CHANNELS"
echo "[*] Band hint : $BAND"
[ "$HIDDEN_MODE" -eq 1 ] && echo "[*] Hidden-SSID passive mode"
if [ "$HAS_TSHARK" -eq 1 ]; then
    echo "[*] Capture   : tshark"
else
    echo "[*] Capture   : tcpdump"
fi

# ---------- create monitor interface ----------
ORIGINAL_IFACE="$INTERFACE"
MON_IFACE="mon${INTERFACE}"
iw dev "$MON_IFACE" del 2>/dev/null || true

echo "[*] Creating monitor interface $MON_IFACE ..."
iw dev "$INTERFACE" interface add "$MON_IFACE" type monitor
ip link set "$MON_IFACE" up
ip link set "$INTERFACE" down 2>/dev/null || true

SCAN_DIR=$(mktemp -d /tmp/wifi-scan.XXXXXX)
AP_FILE="$SCAN_DIR/aps.txt"
: > "$AP_FILE"          # empty file

PCAP_FILE=""
if [ -n "$WRITE_PREFIX" ]; then
    PCAP_FILE="${WRITE_PREFIX}.pcap"
fi

# ---------- helper: set channel ----------
set_channel() {
    ch="$1"
    iw dev "$MON_IFACE" set channel "$ch" 2>/dev/null || \
    iw dev "$MON_IFACE" set freq $((ch < 15 ? 2407 + 5*ch : 5000 + 5*ch)) 2>/dev/null || true
}

# ---------- helper: update AP record ----------
# Usage: update_ap BSSID CH PWR ESSID
update_ap() {
    bssid="$1"
    ch="$2"
    pwr="$3"
    essid="$4"
    ts=$(date +%s)

    # remove old entry for this BSSID (if any) and append new one
    grep -v "^${bssid}|" "$AP_FILE" > "$AP_FILE.tmp" 2>/dev/null || true
    mv "$AP_FILE.tmp" "$AP_FILE"
    echo "${bssid}|${ch}|${pwr}|${essid}|${ts}" >> "$AP_FILE"
}

# ---------- helper: parse one capture burst ----------
capture_burst() {
    ch="$1"
    duration=2
    tmp="$SCAN_DIR/burst.txt"

    set_channel "$ch"

    if [ "$HAS_TSHARK" -eq 1 ]; then
        timeout "$duration" tshark -i "$MON_IFACE" -l -n -Q \
            -T fields -e wlan.bssid -e wlan.ssid -e radiotap.dbm_antsignal \
            -e radiotap.channel.freq -e wlan.fc.type_subtype \
            2>/dev/null > "$tmp" || true

        # tshark tab-separated output
        while IFS