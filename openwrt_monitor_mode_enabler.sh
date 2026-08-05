#!/bin/sh

# Create a monitor interface with required MAC + many optional features
# Defaults: phy0 → mon0

PHY="phy0"
MON="mon0"
MAC_MODE=""
CUSTOM_MAC=""
CHANNEL=""
FREQ=""
WIDTH=""
TXPOWER=""
DELETE_EXISTING=0
KEEP_DOWN=0
VERBOSE=0
QUIET=0
DRY_RUN=0

usage() {
    cat << EOF
Usage: $0 -m MAC [OPTIONS]

Create a monitor interface on a given phy.
The -m option is required.

Required:
  -m MAC          MAC address:
                    random | r | rand   → random locally-administered MAC
                    xx:xx:xx:xx:xx:xx   → specific MAC address

Optional:
  -p PHY          Physical device (default: phy0)
  -i IFACE        Monitor interface name (default: mon0)
  -c CHANNEL      Set channel (e.g. 6, 36, 149)
  -f FREQ         Set frequency in MHz (e.g. 2437, 5180)
  -w WIDTH        Channel width. Possible values:

                    2.4 GHz:
                      HT20
                      HT40+
                      HT40-

                    5 GHz:
                      HT20
                      HT40+
                      HT40-
                      80MHz
                      160MHz
                      80+80MHz

  -t DBM          Set TX power in dBm (e.g. 20)
  -d              Delete interface first if it already exists
  -k              Keep interface down after creation
  -v              Verbose (show commands)
  -q              Quiet (only errors + final status)
  -n              Dry-run (show what would be done, then prompt to apply)
  -h              Show this help

Examples:
  $0 -m random
  $0 -m r -c 6 -w HT40+
  $0 -p phy1 -i mon1 -m rand -f 5180 -w 80MHz -d
  $0 -m 02:11:22:33:44:55 -c 36 -t 15 -k -v
  $0 -m random -n          # dry-run + prompt
EOF
    exit 1
}

log() {
    [ "\( QUIET" -eq 0 ] && echo " \)@"
}

vlog() {
    [ "$VERBOSE" -eq 1 ] && echo "+ $*"
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  $*"
        return 0
    fi
    vlog "$*"
    eval "$@"
    return $?
}

# Fully random MAC, but forced to be locally-administered + unicast
# (bit 1 set, bit 0 cleared in the first octet) so it is always valid
generate_mac() {
    printf '%02x:%02x:%02x:%02x:%02x:%02x' \
        $(( (RANDOM & 0xFC) | 0x02 )) \
        $((RANDOM % 256)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256))
}

is_valid_mac() {
    echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}

# ---------- Parse arguments ----------
while getopts "p:i:m:c:f:w:t:dkvqnh" opt; do
    case "$opt" in
        p) PHY="$OPTARG" ;;
        i) MON="$OPTARG" ;;
        m)
            case "$OPTARG" in
                random|r|rand)
                    MAC_MODE="random"
                    ;;
                *)
                    if is_valid_mac "$OPTARG"; then
                        MAC_MODE="custom"
                        CUSTOM_MAC="$OPTARG"
                    else
                        echo "Error: invalid MAC address '$OPTARG'"
                        echo "Accepted values:"
                        echo "  random | r | rand          → generate a random MAC"
                        echo "  xx:xx:xx:xx:xx:xx          → use a specific MAC address"
                        echo
                        echo "Example: -m 02:11:22:33:44:55"
                        exit 1
                    fi
                    ;;
            esac
            ;;
        c) CHANNEL="$OPTARG" ;;
        f) FREQ="$OPTARG" ;;
        w) WIDTH="$OPTARG" ;;
        t) TXPOWER="$OPTARG" ;;
        d) DELETE_EXISTING=1 ;;
        k) KEEP_DOWN=1 ;;
        v) VERBOSE=1 ;;
        q) QUIET=1 ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

# -m is mandatory
if [ -z "$MAC_MODE" ]; then
    echo "Error: -m option is required"
    echo
    usage
fi

# Channel and frequency are mutually exclusive
if [ -n "$CHANNEL" ] && [ -n "$FREQ" ]; then
    echo "Error: use either -c CHANNEL or -f FREQ, not both"
    exit 1
fi

# ---------- Decide MAC ----------
case "$MAC_MODE" in
    random) MAC=$(generate_mac) ;;
    custom) MAC="$CUSTOM_MAC" ;;
esac

# ---------- Pre-flight checks (skip heavy checks in pure dry-run display) ----------
if [ "$DRY_RUN" -eq 0 ]; then
    if ! iw phy "$PHY" info >/dev/null 2>&1; then
        echo "Error: $PHY does not exist"
        echo "Available phys:"
        iw phy | grep -E '^Wiphy'
        exit 1
    fi
fi

# ---------- Dry-run header ----------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "=== DRY RUN ==="
    echo "Would perform the following actions:"
    echo
fi

# ---------- Delete existing interface if requested ----------
if [ "$DELETE_EXISTING" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ] || iw dev "$MON" info >/dev/null 2>&1; then
        log "Deleting existing interface $MON (if present)..."
        run "iw dev $MON del 2>/dev/null || true"
    fi
else
    if [ "$DRY_RUN" -eq 0 ] && iw dev "$MON" info >/dev/null 2>&1; then
        echo "Error: interface $MON already exists (use -d to delete it first)"
        exit 1
    fi
fi

# ---------- Create interface ----------
log "Creating $MON on $PHY with MAC $MAC ..."
run "iw phy $PHY interface add $MON type monitor"
if [ $? -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "Failed to create $MON"
    exit 1
fi

# ---------- Set MAC ----------
run "ip link set $MON address $MAC"
if [ $? -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "Failed to set MAC address"
    iw dev "$MON" del 2>/dev/null
    exit 1
fi

# ---------- Set channel / frequency + width ----------
if [ -n "$CHANNEL" ] || [ -n "$FREQ" ]; then
    SET_CMD="iw dev $MON set"
    if [ -n "$CHANNEL" ]; then
        SET_CMD="$SET_CMD channel $CHANNEL"
    else
        SET_CMD="$SET_CMD freq $FREQ"
    fi
    [ -n "$WIDTH" ] && SET_CMD="$SET_CMD $WIDTH"

    log "Setting channel/frequency..."
    run "$SET_CMD"
    if [ $? -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "Warning: failed to set channel/frequency (continuing anyway)"
    fi
elif [ -n "$WIDTH" ]; then
    echo "Warning: -w WIDTH ignored because neither -c nor -f was given"
fi

# ---------- Set TX power ----------
if [ -n "$TXPOWER" ]; then
    log "Setting TX power to ${TXPOWER} dBm..."
    run "iw dev $MON set txpower fixed ${TXPOWER}00"   # iw wants mBm
    if [ $? -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "Warning: failed to set TX power"
    fi
fi

# ---------- Bring up (unless -k) ----------
if [ "$KEEP_DOWN" -eq 0 ]; then
    log "Bringing $MON up..."
    run "ip link set $MON up"
    if [ $? -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "Failed to bring $MON up"
        exit 1
    fi
else
    log "Leaving $MON down (-k)"
fi

# ---------- Dry-run prompt ----------
if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "=== END OF DRY RUN ==="
    printf "Apply these changes for real? [y/N] "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            echo "Applying..."
            DRY_RUN=0
            # Re-run the whole script without -n
            CMD="$0 -m $MAC -p $PHY -i $MON"
            [ -n "$CHANNEL" ] && CMD="$CMD -c $CHANNEL"
            [ -n "$FREQ" ]    && CMD="$CMD -f $FREQ"
            [ -n "$WIDTH" ]   && CMD="$CMD -w $WIDTH"
            [ -n "$TXPOWER" ] && CMD="$CMD -t $TXPOWER"
            [ "$DELETE_EXISTING" -eq 1 ] && CMD="$CMD -d"
            [ "$KEEP_DOWN" -eq 1 ] && CMD="$CMD -k"
            [ "$VERBOSE" -eq 1 ] && CMD="$CMD -v"
            [ "$QUIET" -eq 1 ] && CMD="$CMD -q"
            exec $CMD
            ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

# ---------- Final status ----------
if [ "$QUIET" -eq 0 ]; then
    echo
    echo "Success! $MON is ready"
    echo "  MAC     : $MAC"
    [ -n "$CHANNEL" ] && echo "  Channel : $CHANNEL ${WIDTH}"
    [ -n "$FREQ" ]    && echo "  Freq    : $FREQ MHz ${WIDTH}"
    [ -n "$TXPOWER" ] && echo "  TX power: ${TXPOWER} dBm"
    [ "$KEEP_DOWN" -eq 1 ] && echo "  State   : down"
    echo
    iw dev "$MON" info 2>/dev/null || true
fi 