#!/bin/sh
#
# wifi-scan-helper.sh  (ash / BusyBox compatible)
# Authorized testing of YOUR OWN network only.
# No airodump-ng / airmon-ng forced. Uses airodump-ng (preferred) or
# tshark / tcpdump. Monitor mode must already be enabled.
#
# WARNING: Only run against networks you own or have explicit permission to test.
#

set -eu

# ---------- defaults ----------
INTERFACE=""
CHANNELS=""                 # space-separated list; empty = build from standards + frequency
BAND="agn"                  # default 802.11 standards: a + g + n
FREQUENCY="auto"            # auto | 2.4 | 5
WRITE_PREFIX=""
HIDDEN_MODE=0
UPDATE_INTERVAL=1
HELP=0
SCAN_DIR=""
AP_FILE=""                  # temporary file holding "BSSID|CH|PWR|ESSID|TS"
HAS_2GHZ=0
HAS_5GHZ=0
STANDARDS_DISPLAY=""        # human-readable list of 802.11 standards being used

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

Options:
  -h, --help                  Show this help
  -c, --channel <ch>[,<ch>...]  Fixed channel(s). Overrides standard/frequency hopping.
  -s, --standard, --std <list>  802.11 standards to include:
                              a, b, g, n, ac, ax, be, or all
                              (default: agn)
  -f, --freq, --frequency <val> Frequency selection:
                              2.4 | 5 | auto
                              (default: auto)
  -w, --write <prefix>        Write pcap with this prefix (tshark/tcpdump)
  --hidden                    Passive hidden-SSID focus
  -u, --update <secs>         Redisplay interval (default: 1)

Examples:
  sudo $0 mon0
  sudo $0 -c 1,6,11 --hidden mon0
  sudo $0 -s abg -f 2.4 -w /tmp/scan --hidden mon0
  sudo $0 -s all -f auto mon0

Notes on standards → channels:
  b, g           → 2.4 GHz channels
  a, ac          → 5 GHz channels
  n, ax, be      → both 2.4 GHz and 5 GHz channels
  all            → every standard the hardware supports

The frequency option further restricts the channel list.
When set to "auto" the script uses only the ranges the hardware reports as capable.

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
            CHANNELS=$(echo "$2" | tr ',' ' ')
            shift 2
            ;;
        -s|--standard|--std)
            BAND="$2"
            shift 2
            ;;
        -f|--freq|--frequency)
            FREQUENCY="$2"
            shift 2
            ;;
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
HAS_AIRODUMP=0
HAS_TSHARK=0
HAS_TCPDUMP=0
command -v airodump-ng >/dev/null 2>&1 && HAS_AIRODUMP=1
command -v tshark      >/dev/null 2>&1 && HAS_TSHARK=1
command -v tcpdump     >/dev/null 2>&1 && HAS_TCPDUMP=1
command -v iw          >/dev/null 2>&1 || { echo "iw is required"; exit 1; }
command -v ip          >/dev/null 2>&1 || { echo "ip is required"; exit 1; }

if [ "$HAS_AIRODUMP" -eq 0 ] && [ "$HAS_TSHARK" -eq 0 ] && [ "$HAS_TCPDUMP" -eq 0 ]; then
    echo "Error: need airodump-ng, tshark or tcpdump"
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

# ---------- detect usable frequency ranges ----------
PHY=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/wiphy/ {print $2}')
if [ -n "$PHY" ]; then
    if iw phy "$PHY" info 2>/dev/null | grep -qE '\* 24[0-9]{2} MHz'; then
        HAS_2GHZ=1
    fi
    if iw phy "$PHY" info 2>/dev/null | grep -qE '\* 5[0-9]{3} MHz'; then
        HAS_5GHZ=1
    fi
fi

if [ "$HAS_2GHZ" -eq 0 ] && [ "$HAS_5GHZ" -eq 0 ]; then
    HAS_2GHZ=1
    HAS_5GHZ=1
fi

echo "[*] Interface : $INTERFACE (already in monitor mode)"
echo "[*] Hardware  : 2.4 GHz capable = $HAS_2GHZ    5 GHz capable = $HAS_5GHZ"

# ---------- build channel list from requested 802.11 standards + frequency ----------
if [ -z "$CHANNELS" ]; then
    CHANNELS=""
    WANT_2=0
    WANT_5=0

    case "$BAND" in
        *all*)
            WANT_2=1
            WANT_5=1
            ;;
        *)
            case "$BAND" in
                *a*|*n*|*ac*|*ax*|*be*) WANT_5=1 ;;
            esac
            case "$BAND" in
                *b*|*g*|*n*|*ax*|*be*)  WANT_2=1 ;;
            esac
            ;;
    esac

    case "$FREQUENCY" in
        2.4|2.4ghz|2.4GHz|24)
            WANT_5=0
            ;;
        5|5ghz|5GHz)
            WANT_2=0
            ;;
        auto|*)
            ;;
    esac

    if [ "$WANT_5" -eq 1 ] && [ "$HAS_5GHZ" -eq 1 ]; then
        CHANNELS="$CHANNELS $CH_5G"
    fi
    if [ "$WANT_2" -eq 1 ] && [ "$HAS_2GHZ" -eq 1 ]; then
        CHANNELS="$CHANNELS $CH_2G"
    fi

    CHANNELS=$(echo $CHANNELS | tr ' ' '\n' | sort -n | uniq | tr '\n' ' ')
fi
[ -z "$CHANNELS" ] && CHANNELS="1 6 11"

# Build a clean, well-spaced display of the 802.11 standards in use
if [ "$BAND" = "all" ]; then
    STANDARDS_DISPLAY="a   b   g   n   ac   ax   be"
else
    STANDARDS_DISPLAY=$(echo "$BAND" | sed \
        -e 's/ac/ ac /g' \
        -e 's/ax/ ax /g' \
        -e 's/be/ be /g' \
        -e 's/\([abgn]\)/\1 /g' \
        | tr -s ' ' | sed 's/^ *//;s/ *$//')
fi

echo "[*] Channels  : $CHANNELS"
echo "[*] Standards : $STANDARDS_DISPLAY"
echo "[*] Frequency : $FREQUENCY"
[ "$HIDDEN_MODE" -eq 1 ] && echo "[*] Hidden-SSID passive mode"

if [ "$HAS_AIRODUMP" -eq 1 ]; then
    echo "[*] Capture   : airodump-ng (preferred)"
elif [ "$HAS_TSHARK" -eq 1 ]; then
    echo "[*] Capture   : tshark"
else
    echo "[*] Capture   : tcpdump"
fi

# ---------- prepare temporary directory ----------
SCAN_DIR=$(mktemp -d /tmp/wifi-scan.XXXXXX)
AP_FILE="$SCAN_DIR/aps.txt"
: > "$AP_FILE"

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
update_ap() {
    bssid="$1"
    ch="$2"
    pwr="$3"
    essid="$4"
    ts=$(date +%s)

    grep -v "^${bssid}|" "$AP_FILE" > "$AP_FILE.tmp" 2>/dev/null || true
    mv "$AP_FILE.tmp" "$AP_FILE"
    echo "${bssid}|${ch}|${pwr}|${essid}|${ts}" >> "$AP_FILE"
}

# ---------- helper: parse one capture burst ----------
capture_burst() {
    ch="$1"
    duration=5          # longer dwell helps airodump-ng
    tmp="$SCAN_DIR/burst.txt"

    set_channel "$ch"
    sleep 1             # BusyBox-compatible settle time

    if [ "$HAS_AIRODUMP" -eq 1 ]; then
        # Clean previous run
        rm -f "$SCAN_DIR"/airodump* 2>/dev/null || true

        # Run airodump-ng in the background so we can control its lifetime cleanly
        airodump-ng \
            --output-format csv \
            -w "$SCAN_DIR/airodump" \
            --write-interval 1 \
            -c "$ch" \
            "$INTERFACE" >/dev/null 2>&1 &
        AIRO_PID=$!

        sleep "$duration"
        kill "$AIRO_PID" 2>/dev/null || true
        wait "$AIRO_PID" 2>/dev/null || true
        sleep 1          # allow final CSV flush

        # Find the CSV that was just written
        csv=$(ls -1 "$SCAN_DIR"/airodump*.csv 2>/dev/null | head -n 1)

        if [ -n "$csv" ] && [ -f "$csv" ] && [ -s "$csv" ]; then
            # Robust parser: stop at the first blank line (end of AP section)
            # Columns: 1=BSSID, 4=channel, 9=Power, 14=ESSID
            awk -F',' '
                BEGIN { OFS="|" }
                /^BSSID/ { next }          # skip header
                /^[[:space:]]*$/ { exit }  # end of AP list
                {
                    # clean fields
                    bssid = $1;  gsub(/[[:space:]]/, "", bssid)
                    pwr   = $9;  gsub(/[[:space:]]/, "", pwr)
                    essid = $14; gsub(/^[[:space:]]+|[[:space:]]+$/, "", essid)

                    if (bssid ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
                        if (essid == "") essid = "[HIDDEN]"
                        if (pwr == "")   pwr   = "?"
                        print bssid, ch, pwr, essid
                    }
                }
            ' ch="$ch" "$csv" > "$SCAN_DIR/parsed.txt"

            # Feed the cleaned lines into update_ap
            while IFS='|' read -r bssid c pwr essid; do
                [ -n "$bssid" ] && update_ap "$bssid" "$c" "$pwr" "$essid"
            done < "$SCAN_DIR/parsed.txt"
        fi

    elif [ "$HAS_TSHARK" -eq 1 ]; then
        # original tshark path (unchanged)
        timeout "$duration" tshark -i "$INTERFACE" -l -n -Q \
            -T fields -e wlan.bssid -e wlan.ssid -e radiotap.dbm_antsignal \
            -e radiotap.channel.freq -e wlan.fc.type_subtype \
            2>/dev/null > "$tmp" || true

        while IFS="$(printf '\t')" read -r bssid ssid pwr freq subtype; do
            [ -z "$bssid" ] && continue
            [ "$bssid" = "ff:ff:ff:ff:ff:ff" ] && continue
            [ -z "$ssid" ] && ssid="[HIDDEN]"
            update_ap "$bssid" "$ch" "${pwr:--}" "$ssid"
        done < "$tmp"

    else
        # original tcpdump path (unchanged)
        timeout "$duration" tcpdump -i "$INTERFACE" -l -e -s 256 -n \
            'type mgt' 2>/dev/null > "$tmp" || true

        while IFS= read -r line; do
            bssid=""
            ssid="[HIDDEN]"

            bssid=$(echo "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -n1)
            [ -z "$bssid" ] && continue

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

    idx=1
    sort -t'|' -k1,1 "$AP_FILE" | while IFS='|' read -r bssid ch pwr essid ts; do
        printf " %2d | %-18s | %3s | %5s | %s\n" \
            "$idx" "$bssid" "$ch" "$pwr" "$essid"
        idx=$((idx + 1))
    done

    echo
    printf "Channels hopping: %s\n" "$CHANNELS"
    printf "Standards:        %-28s  Frequency: %s    Hidden mode: %s\n" \
        "$STANDARDS_DISPLAY" "$FREQUENCY" "$HIDDEN_MODE"
    echo "Press Ctrl+C when ready to select targets..."
    sleep "$UPDATE_INTERVAL"
done

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

FOCUS_BSSIDS=$(echo $FOCUS_BSSIDS)
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

FIRST_BSSID=$(echo $FOCUS_BSSIDS | awk '{print $1}')

if [ "$HAS_AIRODUMP" -eq 1 ]; then
    # airodump-ng focused mode
    AIRO_ARGS="--bssid $FIRST_BSSID -c $PRIMARY_CH"
    [ -n "$PCAP_FILE" ] && AIRO_ARGS="$AIRO_ARGS -w ${WRITE_PREFIX:-/tmp/focused}"
    # shellcheck disable=SC2086
    airodump-ng $AIRO_ARGS "$INTERFACE" || true

elif [ "$HAS_TSHARK" -eq 1 ]; then
    TSHARK_ARGS="-i $INTERFACE -l -n"
    [ -n "$PCAP_FILE" ] && TSHARK_ARGS="$TSHARK_ARGS -w $PCAP_FILE"
    # shellcheck disable=SC2086
    tshark $TSHARK_ARGS -Y "wlan.bssid == $FIRST_BSSID" \
        -T fields -e frame.time -e wlan.bssid -e wlan.sa -e wlan.ssid \
        -e wlan.fc.type_subtype -e radiotap.dbm_antsignal 2>/dev/null || true
else
    BPF="type mgt or wlan addr1 $FIRST_BSSID or wlan addr2 $FIRST_BSSID or wlan addr3 $FIRST_BSSID"
    TCPDUMP_ARGS="-i $INTERFACE -l -e -s 0 -n"
    [ -n "$PCAP_FILE" ] && TCPDUMP_ARGS="$TCPDUMP_ARGS -w $PCAP_FILE"
    # shellcheck disable=SC2086
    tcpdump $TCPDUMP_ARGS "$BPF" 2>/dev/null || true
fi

echo
echo "[*] Finished. Any pcap written to: ${PCAP_FILE:-none}"
echo "    Review only traffic from networks you are authorized to test."