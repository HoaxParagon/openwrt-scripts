#!/bin/sh
#
# wifi-scan-helper.sh  (ash / BusyBox compatible)
# Authorized testing of YOUR OWN network only.
# No airodump-ng / airmon-ng. Uses iw + (tshark or tcpdump).
#
# WARNING: Only run against networks you own or have explicit permission to test.
# Requires root and a wireless interface already in monitor mode
# (monitor mode setup is handled by another script).
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
SCAN_DIR=""
AP_FILE=""                  # temporary file holding "BSSID|CH|PWR|ESSID|TS"

# 2.4 GHz and common 5 GHz channels
CH_2G="1 2 3 4 5 6 7 8 9 10 11 12 13"
CH_5G="36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165"

cleanup() {
    echo
    echo "[*] Cleaning up..."
    [ -n "$SCAN_DIR" ] && [ -d "$SCAN_DIR" ] && rm -rf "$SCAN_DIR"
    exit 0
}
trap 'cleanup' EXIT INT TERM

usage() {
    cat <<EOF
Usage: sudo $0 [options] <interface>

The given interface must already be in monitor mode
(monitor mode is set up by another script).

Options (airodump-ng style):
  -h, --help                  Show this help
  -c, --channel <ch>[,<ch>...]  Fixed channel(s). Overrides band hopping.
  -b, --band <abg...>         Band hint: a,b,g,n,ac (default: bg)
  -w, --write <prefix>        Write pcap with this prefix (tshark/tcpdump)
  --hidden                    Passive hidden-SSID focus
  -u, --update <secs>         Redisplay interval (default: 1)

Examples:
  sudo $0 mon0
  sudo $0 -c 1,6,11 --hidden mon0
  sudo $0 -b abg -w /tmp/scan --hidden mon0

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

# ---------- verify interface exists and is in monitor mode ----------
if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: interface $INTERFACE does not exist"
    exit 1
fi

if ! iw dev "$INTERFACE" info 2>/dev/null | grep -q "type monitor"; then
    echo "Error: $INTERFACE is not in monitor mode"
    echo "       (monitor mode must be enabled by another script before running this one)"
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

echo "[*] Interface : $INTERFACE (already in monitor mode)"
echo "[*] Channels  : $CHANNELS"
echo "[*] Band hint : $BAND"
[ "$HIDDEN_MODE" -eq 1 ] && echo "[*] Hidden-SSID passive mode"
if [ "$HAS_TSHARK" -eq 1 ]; then
    echo "[*] Capture   : tshark"
else
    echo "[*] Capture   : tcpdump"
fi

# ---------- prepare temporary directory ----------
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
    iw dev "$INTERFACE" set channel "$ch" 2>/dev/null || \
    iw dev "$INTERFACE" set freq $((ch < 15 ? 2407 + 5*ch : 5000 + 5*ch)) 2>/