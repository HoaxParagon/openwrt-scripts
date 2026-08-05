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
    iw dev "$INTERFACE" set freq $((ch < 15 ? 2407 + 5*ch : 5000 + 5*ch)) 2>/dev/null || true
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
        timeout "$duration" tshark -i "$INTERFACE" -l -n -Q \
            -T fields -e wlan.bssid -e wlan.ssid -e radiotap.dbm_antsignal \
            -e radiotap.channel.freq -e wlan.fc.type_subtype \
            2>/dev/null > "$tmp" || true

        # tshark tab-separated output
        while IFS="$(printf '\t')" read -r bssid ssid pwr freq subtype; do
            [ -z "$bssid" ] && continue
            [ "$bssid" = "ff:ff:ff:ff:ff:ff" ] && continue
            [ -z "$ssid" ] && ssid="[HIDDEN]"
            update_ap "$bssid" "$ch" "${pwr:--}" "$ssid"
        done < "$tmp"
    else
        # tcpdump fallback – best-effort parsing
        timeout "$duration" tcpdump -i "$INTERFACE" -l -e -s 256 -n \
            'type mgt' 2>/dev/null > "$tmp" || true

        while IFS= read -r line; do
            bssid=""
            ssid="[HIDDEN]"

            # extract first MAC-looking string
            bssid=$(echo "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n1)
            [ -z "$bssid" ] && continue

            # try to find SSID=
            if echo "$line" | grep -q 'SSID='; then
                ssid=$(echo "$line" | sed -n 's/.*SSID=\([^ ]*\).*/\1/p')
                [ -z "$ssid" ] && ssid="[HIDDEN]"
            fi

            update_ap "$bssid" "$ch" "?" "$ssid"
        done < "$tmp"
    fi
}

# ---------- live scan phase ----------
echo
echo "=== Live scan (Ctrl+C to stop and select targets) ==="
echo "Results are sorted by BSSID. Hidden APs appear as [HIDDEN]."
echo

RUNNING=1
trap 'RUNNING=0' INT

while [ "$RUNNING" -eq 1 ]; do
    for ch in $CHANNELS; do
        [ "$RUNNING" -eq 0 ] && break
        capture_burst "$ch"
    done

    clear 2>/dev/null || true
    echo "=== Scan results (sorted by BSSID) – $(date) ==="
    echo " #  | BSSID              | CH  | PWR   | ESSID"
    echo "----+--------------------+-----+-------+-------------------------"

    # sort by BSSID and number the lines
    idx=1
    sort -t'|' -k1,1 "$AP_FILE" | while IFS='|' read -r bssid ch pwr essid ts; do
        printf " %2d | %-18s | %3s | %5s | %s\n" \
            "$idx" "$bssid" "$ch" "$pwr" "$essid"
        idx=$((idx + 1))
    done

    echo
    echo "Channels hopping: $CHANNELS   |  Hidden mode: $HIDDEN_MODE"
    echo "Press Ctrl+C when ready to select targets..."
    sleep "$UPDATE_INTERVAL"
done

# restore cleanup trap
trap 'cleanup' EXIT INT TERM

# ---------- second section ----------
echo
echo "=== Scan stopped – select targets ==="

if [ ! -s "$AP_FILE" ]; then
    echo "No access points recorded."
    exit 0
fi

echo " #  | BSSID              | CH  | PWR   | ESSID"
echo "----+--------------------+-----+-------+-------------------------"

# build numbered list into a temporary index file
IDX_FILE="$SCAN_DIR/idx.txt"
: > "$IDX_FILE"
idx=1
sort -t'|' -k1,1 "$AP_FILE" | while IFS='|' read -r bssid ch pwr essid ts; do
    printf " %2d | %-18s | %3s | %5s | %s\n" \
        "$idx" "$bssid" "$ch" "$pwr" "$essid"
    echo "${idx}|${bssid}|${ch}|${essid}" >> "$IDX_FILE"
    idx=$((idx + 1))
done

echo
printf "Comma-separated numbers (e.g. 1,3,2) or q to quit: "
read SELECTION
[ "$SELECTION" = "q" ] || [ -z "$SELECTION" ] && exit 0

# turn commas into spaces
SELECTION=$(echo "$SELECTION" | tr ',' ' ')

FOCUS_BSSIDS=""
FOCUS_CHS=""
PRIMARY_CH=""

for n in $SELECTION; do
    n=$(echo "$n" | tr -d '[:space:]')
    line=$(grep "^${n}|" "$IDX_FILE" || true)
    if [ -n "$line" ]; then
        bssid=$(echo "$line" | cut -d'|' -f2)
        ch=$(echo "$line" | cut -d'|' -f3)
        essid=$(echo "$line" | cut -d'|' -f4)
        FOCUS_BSSIDS="$FOCUS_BSSIDS $bssid"
        FOCUS_CHS="$FOCUS_CHS $ch"
        [ -z "$PRIMARY_CH" ] && PRIMARY_CH="$ch"
        echo "[+] #$n  $bssid  ($essid)  CH $ch"
    else
        echo "[!] skip invalid index $n"
    fi
done

FOCUS_BSSIDS=$(echo $FOCUS_BSSIDS)   # trim
[ -z "$FOCUS_BSSIDS" ] && { echo "Nothing selected"; exit 0; }

# ---------- focused passive monitoring ----------
echo
echo "=== Focused passive capture on selected BSSID(s) ==="
echo "In --hidden mode keep this running; when a client of YOUR network"
echo "probes or associates the real ESSID should appear in the frames."
echo "Ctrl+C to stop."
echo

set_channel "$PRIMARY_CH"
echo "[*] Locked to channel $PRIMARY_CH"

# simple BPF for the first BSSID (extend if needed)
FIRST_BSSID=$(echo $FOCUS_BSSIDS | awk '{print $1}')
BPF="type mgt or wlan addr1 $FIRST_BSSID or wlan addr2 $FIRST_BSSID or wlan addr3 $FIRST_BSSID"

if [ "$HAS_TSHARK" -eq 1 ]; then
    TSHARK_ARGS="-i $INTERFACE -l -n"
    [ -n "$PCAP_FILE" ] && TSHARK_ARGS="$TSHARK_ARGS -w $PCAP_FILE"
    # shellcheck disable=SC2086
    tshark $TSHARK_ARGS -Y "wlan.bssid == $FIRST_BSSID" \
        -T fields -e frame.time -e wlan.bssid -e wlan.sa -e wlan.ssid \
        -e wlan.fc.type_subtype -e radiotap.dbm_antsignal 2>/dev/null || true
else
    TCPDUMP_ARGS="-i $INTERFACE -l -e -s 0 -n"
    [ -n "$PCAP_FILE" ] && TCPDUMP_ARGS="$TCPDUMP_ARGS -w $PCAP_FILE"
    # shellcheck disable=SC2086
    tcpdump $TCPDUMP_ARGS "$BPF" 2>/dev/null || true
fi

echo
echo "[*] Finished. Any pcap written to: ${PCAP_FILE:-none}"
echo "    Review only traffic from networks you are authorized to test."