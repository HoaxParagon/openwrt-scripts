#!/usr/bin/env bash
#
# wifi-scan-helper.sh
# Authorized testing of YOUR OWN network only.
# No airodump-ng / airmon-ng. Uses iw + (tshark or tcpdump).
#
# WARNING: Only run against networks you own or have explicit permission to test.
# Requires root and a wireless adapter that supports monitor mode.
#

set -euo pipefail

# ---------- defaults ----------
INTERFACE=""
CHANNELS=()                 # empty = hop according to band
BAND="bg"                   # a / b / g / n / ac (used to build channel list)
WRITE_PREFIX=""
HIDDEN_MODE=0
UPDATE_INTERVAL=1
HELP=0
MON_IFACE=""
ORIGINAL_IFACE=""
SCAN_DIR=""
declare -A SEEN_AP          # key = BSSID, value = "CH|PWR|ESSID|LAST_SEEN"
declare -a ORDERED_BSSIDS=() # for stable numbering after sort

# 2.4 GHz and common 5 GHz channels (simplified)
CH_2G=(1 2 3 4 5 6 7 8 9 10 11 12 13)
CH_5G=(36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165)

cleanup() {
    echo
    echo "[*] Cleaning up..."
    if [[ -n "$MON_IFACE" ]]; then
        ip link set "$MON_IFACE" down 2>/dev/null || true
        iw dev "$MON_IFACE" del 2>/dev/null || true
    fi
    if [[ -n "$ORIGINAL_IFACE" ]]; then
        ip link set "$ORIGINAL_IFACE" up 2>/dev/null || true
    fi
    [[ -n "$SCAN_DIR" && -d "$SCAN_DIR" ]] && rm -rf "$SCAN_DIR"
    exit 0
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: sudo $0 [options] <interface>

Options (airodump-ng style):
  -h, --help                  Show this help
  -c, --channel <ch>[,<ch>...]  Fixed channel(s). Overrides band hopping.
  -b, --band <abg...>         Band hint: a,b,g,n,ac (default: bg)
  -w, --write <prefix>        Write pcap with this prefix (tshark/tcpdump)
  --hidden                    Passive hidden-SSID focus
                              (show empty SSID beacons + wait for client probes)
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
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) HELP=1; shift ;;
        -c|--channel)
            IFS=',' read -ra CHANNELS <<< "$2"
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

[[ $HELP -eq 1 ]] && usage
[[ -z "$INTERFACE" ]] && { echo "Error: interface required"; usage; }

if [[ $EUID -ne 0 ]]; then
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

if [[ $HAS_TSHARK -eq 0 && $HAS_TCPDUMP -eq 0 ]]; then
    echo "Error: need tshark or tcpdump for monitor-mode capture"
    exit 1
fi

# ---------- build channel list from band if -c not given ----------
if [[ ${#CHANNELS[@]} -eq 0 ]]; then
    case "$BAND" in
        *a*|*n*|*ac*) CHANNELS+=("${CH_5G[@]}") ;;
    esac
    case "$BAND" in
        *b*|*g*|*n*)  CHANNELS+=("${CH_2G[@]}") ;;
    esac
    # unique + sort
    mapfile -t CHANNELS < <(printf '%s\n' "${CHANNELS[@]}" | sort -n | uniq)
fi
[[ ${#CHANNELS[@]} -eq 0 ]] && CHANNELS=(1 6 11)

echo "[*] Interface : $INTERFACE"
echo "[*] Channels  : ${CHANNELS[*]}"
echo "[*] Band hint : $BAND"
[[ $HIDDEN_MODE -eq 1 ]] && echo "[*] Hidden-SSID passive mode"
echo "[*] Capture   : $( [[ $HAS_TSHARK -eq 1 ]] && echo tshark || echo tcpdump )"

# ---------- create monitor interface ----------
ORIGINAL_IFACE="$INTERFACE"
MON_IFACE="mon${INTERFACE}"
# clean possible leftover
iw dev "$MON_IFACE" del 2>/dev/null || true

echo "[*] Creating monitor interface $MON_IFACE ..."
iw dev "$INTERFACE" interface add "$MON_IFACE" type monitor
ip link set "$MON_IFACE" up
# bring original down to avoid interference (common practice)
ip link set "$INTERFACE" down 2>/dev/null || true

SCAN_DIR=$(mktemp -d /tmp/wifi-scan.XXXXXX)
PCAP_FILE=""
if [[ -n "$WRITE_PREFIX" ]]; then
    PCAP_FILE="${WRITE_PREFIX}.pcap"
fi

# ---------- helper: set channel ----------
set_channel() {
    local ch="$1"
    iw dev "$MON_IFACE" set channel "$ch" 2>/dev/null || \
    iw dev "$MON_IFACE" set freq $((ch < 15 ? 2407 + 5*ch : 5000 + 5*ch)) 2>/dev/null || true
}

# ---------- helper: parse one capture burst ----------
# Populates SEEN_AP[ BSSID ] = "CH|PWR|ESSID|timestamp"
capture_burst() {
    local ch="$1"
    local duration=2          # seconds per channel
    local tmp="$SCAN_DIR/burst.txt"

    set_channel "$ch"

    if [[ $HAS_TSHARK -eq 1 ]]; then
        # fields: bssid, ssid, signal, freq, subtype
        timeout "$duration" tshark -i "$MON_IFACE" -l -n -Q \
            -T fields -e wlan.bssid -e wlan.ssid -e radiotap.dbm_antsignal \
            -e radiotap.channel.freq -e wlan.fc.type_subtype \
            2>/dev/null > "$tmp" || true
    else
        # tcpdump fallback – rougher parsing
        timeout "$duration" tcpdump -i "$MON_IFACE" -l -e -s 256 -n \
            'type mgt' 2>/dev/null > "$tmp" || true
    fi

    # very simple parser (works for both tools to different degrees)
    while IFS= read -r line; do
        local bssid="" ssid="" pwr="?" freq=""
        if [[ $HAS_TSHARK -eq 1 ]]; then
            # tshark tab-separated
            bssid=$(echo "$line" | cut -f1)
            ssid=$(echo "$line"  | cut -f2)
            pwr=$(echo "$line"   | cut -f3)
            freq=$(echo "$line"  | cut -f4)
            [[ -z "$bssid" || "$bssid" == "ff:ff:ff:ff:ff:ff" ]] && continue
            [[ -z "$ssid" ]] && ssid="[HIDDEN]"
            # convert freq → channel roughly
            local c="$ch"
            SEEN_AP["\( bssid"]=" \){c}|\( {pwr}| \){ssid}|$(date +%s)"
        else
            # tcpdump: look for SA / BSSID and SSID= patterns (best-effort)
            if [[ "$line" =\~ ([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2} ]]; then
                bssid="${BASH_REMATCH[0]}"
            fi
            if [[ "$line" =\~ SSID=([^ ]+) ]]; then
                ssid="${BASH_REMATCH[1]}"
            elif [[ "$line" =\~ Beacon* || "$line" =\~ Probe* ]]; then
                ssid="[HIDDEN]"
            fi
            [[ -z "$bssid" ]] && continue
            SEEN_AP["\( bssid"]=" \){ch}|?|\( {ssid:-"[HIDDEN]"}| \)(date +%s)"
        fi
    done < "$tmp"
}

# ---------- live scan phase ----------
echo
echo "=== Live scan (Ctrl+C to stop and select targets) ==="
echo "Results are sorted by BSSID/MAC. Hidden APs appear as [HIDDEN]."
echo

RUNNING=1
trap 'RUNNING=0' INT

while [[ $RUNNING -eq 1 ]]; do
    for ch in "${CHANNELS[@]}"; do
        [[ $RUNNING -eq 0 ]] && break
        capture_burst "$ch"
    done

    # rebuild ordered list sorted by MAC
    ORDERED_BSSIDS=()
    mapfile -t ORDERED_BSSIDS < <(printf '%s\n' "${!SEEN_AP[@]}" | sort)

    clear
    echo "=== Scan results (sorted by BSSID) – $(date) ==="
    echo " #  | BSSID              | CH  | PWR   | ESSID"
    echo "----+--------------------+-----+-------+-------------------------"
    local idx=1
    for b in "${ORDERED_BSSIDS[@]}"; do
        IFS='|' read -r ch pwr essid _ <<< "${SEEN_AP[$b]}"
        printf " %2d | %-18s | %3s | %5s | %s\n" \
            "$idx" "$b" "$ch" "$pwr" "$essid"
        ((idx++)) || true
    done
    echo
    echo "Channels hopping: ${CHANNELS[*]}   |  Hidden mode: $HIDDEN_MODE"
    echo "Press Ctrl+C when ready to select targets..."
    sleep "$UPDATE_INTERVAL"
done

# restore default trap
trap cleanup EXIT INT TERM

# ---------- second section ----------
echo
echo "=== Scan stopped – select targets ==="

if [[ ${#ORDERED_BSSIDS[@]} -eq 0 ]]; then
    echo "No access points recorded."
    exit 0
fi

echo " #  | BSSID              | CH  | PWR   | ESSID"
echo "----+--------------------+-----+-------+-------------------------"
idx=1
declare -A IDX2BSSID IDX2CH IDX2ESSID
for b in "${ORDERED_BSSIDS[@]}"; do
    IFS='|' read -r ch pwr essid _ <<< "${SEEN_AP[$b]}"
    printf " %2d | %-18s | %3s | %5s | %s\n" \
        "$idx" "$b" "$ch" "$pwr" "$essid"
    IDX2BSSID[$idx]="$b"
    IDX2CH[$idx]="$ch"
    IDX2ESSID[$idx]="$essid"
    ((idx++)) || true
done

echo
read -r -p "Comma-separated numbers (e.g. 1,3,2) or q to quit: " SELECTION
[[ "$SELECTION" == "q" || -z "$SELECTION" ]] && exit 0

IFS=',' read -ra SEL <<< "$SELECTION"
FOCUS_BSSIDS=()
FOCUS_CHS=()

for n in "${SEL[@]}"; do
    n=$(echo "$n" | tr -d '[:space:]')
    if [[ -n "${IDX2BSSID[$n]:-}" ]]; then
        FOCUS_BSSIDS+=("${IDX2BSSID[$n]}")
        FOCUS_CHS+=("${IDX2CH[$n]}")
        echo "[+] #$n  ${IDX2BSSID[\( n]}  ( \){IDX2ESSID[$n]})  CH ${IDX2CH[$n]}"
    else
        echo "[!] skip invalid index $n"
    fi
done

[[ ${#FOCUS_BSSIDS[@]} -eq 0 ]] && { echo "Nothing selected"; exit 0; }

# ---------- focused passive monitoring ----------
echo
echo "=== Focused passive capture on selected BSSID(s) ==="
echo "In --hidden mode keep this running; when a client of YOUR network"
echo "probes or associates the real ESSID should appear in the frames."
echo "Ctrl+C to stop."
echo

# lock to the (first) channel of the selection for simplicity
PRIMARY_CH="${FOCUS_CHS[0]}"
set_channel "$PRIMARY_CH"
echo "[*] Locked to channel $PRIMARY_CH"

# build a simple bpf filter for the BSSIDs
BPF="type mgt"
for b in "${FOCUS_BSSIDS[@]}"; do
    BPF="$BPF or wlan addr1 $b or wlan addr2 $b or wlan addr3 $b"
done

if [[ $HAS_TSHARK -eq 1 ]]; then
    TSHARK_ARGS=(-i "$MON_IFACE" -l -n)
    [[ -n "$PCAP_FILE" ]] && TSHARK_ARGS+=(-w "$PCAP_FILE")
    tshark "${TSHARK_ARGS[@]}" -Y "wlan.bssid == ${FOCUS_BSSIDS[0]}" \
        -T fields -e frame.time -e wlan.bssid -e wlan.sa -e wlan.ssid \
        -e wlan.fc.type_subtype -e radiotap.dbm_antsignal 2>/dev/null || true
else
    TCPDUMP_ARGS=(-i "$MON_IFACE" -l -e -s 0 -n)
    [[ -n "$PCAP_FILE" ]] && TCPDUMP_ARGS+=(-w "$PCAP_FILE")
    tcpdump "${TCPDUMP_ARGS[@]}" "$BPF" 2>/dev/null || true
fi

echo
echo "[*] Finished. Any pcap written to: ${PCAP_FILE:-none}"
echo "    Review only traffic from networks you are authorized to test." 