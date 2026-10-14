#!/bin/bash
#
# ===========================================================================
#  VPS toolkit: 6to4+GRE6 tunnel / BBR / timezone / sysctl tuning / x-ui /
#               nameserver / IPv6 disable
#
#  Fixed version — see comments tagged "FIX:" for what changed vs. the
#  original and why.
# ===========================================================================

# FIX: all the operations below (ip/iptables/sysctl/systemd files) need root.
if [ "$(id -u)" -ne 0 ]; then
    echo "این اسکریپت باید با دسترسی root اجرا بشه (مثلا: sudo ./script.sh)"
    exit 1
fi

# ---------------------------------------------------------------------------
# FIX: the inner tunnel addressing used to be hardcoded (2010:5a8:2e20:f2e::
# and 121.113.9.0/30). Those exact ranges show up in a lot of copies of this
# script floating around, so they're an easy fingerprint for DPI to match and
# block. They're pulled out as variables here so you can change them again in
# a few seconds if this new range ever gets filtered too — just edit the two
# lines below, nothing else in the script needs to change.
# ---------------------------------------------------------------------------
TUN_V6_PREFIX="fd7e:9a2c:41b8:33f1"   # ULA /64 prefix used for the sit<->gre6 link
TUN_V4_SUBNET="10.77.88"              # inner /30: .1 <-> .2

IR_V6="${TUN_V6_PREFIX}::1"
KH_V6="${TUN_V6_PREFIX}::2"
IR_V4="${TUN_V4_SUBNET}.1"
KH_V4="${TUN_V4_SUBNET}.2"

# FIX: MTU chain wasn't accounting for the double encapsulation
# (physical 1500 -> sit/6to4 -eth overhead 20B -> 1480, then ip6gre over
# that adds ~40B IPv6 header + GRE header on top -> needs to be noticeably
# lower than the sit MTU, not the same value). Mismatched MTU here is the
# classic cause of "ping works fine but downloads/uploads stall or drop" --
# small packets go through, larger ones get silently blackholed somewhere
# on the path. 1480 / 1400 leaves enough headroom.
SIT_MTU=1480
GRE_MTU=1400

is_valid_ipv4() {
    local ip="$1" IFS='.' octs
    read -ra octs <<< "$ip"
    [ "${#octs[@]}" -eq 4 ] || return 1
    local o
    for o in "${octs[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

echo "What should I do?"
echo "1) 6to4"
echo "2) Remove tunnels"
echo "3) Enable BBR"
echo "4) Fix Whatsapp Time"
echo "5) Optimize"
echo "6) Install x-ui"
echo "7) Change NameServer"
echo "8) Disable IPv6 - After server reboot IPv6 is activated"
read -p "Select an option (1, 2, 3, 4, 5, 6, 7, or 8): " server_choice

# ---------------------------------------------------------------------------
# FIX: the original setup_rc_local() decided whether to "append before exit 0"
# or "wipe the whole file and start over" based on whether /etc/rc.local
# already contained the literal string 'ip tunnel add'. That means running
# ANY other option that also calls setup_rc_local (e.g. "Fix Whatsapp Time")
# would silently erase the tunnel commands that a previous run had persisted
# there -- the tunnel would then vanish on the next reboot with no obvious
# cause. It also built the sed command by interpolating $commands directly
# into a string passed to `bash -c "sed -i '...' file"`, which breaks the
# moment $commands contains a quote, a `/`, or (as here) multiple lines.
#
# Fixed version: every caller passes a unique tag. Each block is wrapped in
# "# BEGIN-<tag>" / "# END-<tag>" markers, is removed and re-added as a whole
# (so re-running an option is idempotent instead of duplicating itself), and
# other tags' blocks are left completely untouched. No shell string ever gets
# rebuilt through another shell -- awk/sed only operate on fixed markers, the
# multi-line command text is only ever handled as data.
# ---------------------------------------------------------------------------
setup_rc_local() {
    local tag="$1"
    local commands="$2"
    local FILE="/etc/rc.local"
    local begin="# BEGIN-${tag}"
    local end="# END-${tag}"

    if [ ! -f "$FILE" ]; then
        printf '#!/bin/bash\n\nexit 0\n' > "$FILE"
    fi
    chmod +x "$FILE"

    # Idempotent: drop any previous block with this exact tag first.
    sed -i "/^${begin}$/,/^${end}$/d" "$FILE"

    local block
    block=$(printf '%s\n%s\n%s' "$begin" "$commands" "$end")

    if grep -q '^exit 0' "$FILE"; then
        awk -v blk="$block" '
            /^exit 0/ && !done { print blk; done=1 }
            { print }
        ' "$FILE" > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
    else
        printf '%s\n' "$block" >> "$FILE"
        echo "exit 0" >> "$FILE"
    fi

    chmod +x "$FILE"
    echo "Commands for '$tag' saved to /etc/rc.local"
}

remove_rc_local_tag() {
    local tag="$1"
    local FILE="/etc/rc.local"
    [ -f "$FILE" ] || return 0
    sed -i "/^# BEGIN-${tag}$/,/^# END-${tag}$/d" "$FILE"
}

# Function to handle Fix Whatsapp Time option
fix_whatsapp_time() {
    commands="timedatectl set-timezone Asia/Tehran"
    setup_rc_local "whatsapp-time" "$commands"
    echo "Whatsapp time fixed to Asia/Tehran timezone."
}

# Function to handle Optimize option
optimize() {
    USER_CONF="/etc/systemd/user.conf"
    SYSTEM_CONF="/etc/systemd/system.conf"
    LIMITS_CONF="/etc/security/limits.conf"
    SYSCTL_CONF="/etc/sysctl.d/local.conf"
    TEMP_USER_CONF=$(mktemp)
    TEMP_SYSTEM_CONF=$(mktemp)

    add_line_if_not_exists() {
        local file="$1"
        local line="$2"
        local temp_file="$3"

        if [ -f "$file" ]; then
            cp "$file" "$temp_file"
            if ! grep -q "$line" "$file"; then
                sed -i '/^\[Manager\]/a '"$line" "$temp_file"
                mv "$temp_file" "$file"
                echo "Added '$line' to $file"
            else
                echo "The line '$line' already exists in $file"
                rm -f "$temp_file"
            fi
        else
            echo "$file does not exist."
            rm -f "$temp_file"
        fi
    }

    add_line_if_not_exists "$USER_CONF" "DefaultLimitNOFILE=1024000" "$TEMP_USER_CONF"
    add_line_if_not_exists "$SYSTEM_CONF" "DefaultLimitNOFILE=1024000" "$TEMP_SYSTEM_CONF"

    # FIX: originally this block was appended unconditionally every single
    # run, so running "Optimize" twice left two (then three, then four...)
    # duplicate copies of these four lines in limits.conf. Now it only adds
    # them once.
    if [ -f "$LIMITS_CONF" ]; then
        if ! grep -q 'hard nofile 1024000' "$LIMITS_CONF"; then
            cat <<EOF >> "$LIMITS_CONF"
* hard nofile 1024000
* soft nofile 1024000
root hard nofile 1024000
root soft nofile 1024000
EOF
            echo "Added limits to $LIMITS_CONF"
        else
            echo "Limits already present in $LIMITS_CONF"
        fi
    else
        echo "$LIMITS_CONF does not exist."
    fi

    cat <<EOF | tee "$SYSCTL_CONF"
# max open files
fs.file-max = 1024000
EOF
    echo "Added sysctl settings to $SYSCTL_CONF"

    sysctl --system
    echo "Sysctl changes applied."
}

# FIX: invalid/non-numeric input used to crash this with
# "integer expression expected" because of `[ "$xui_choice" -eq 1 ]`.
# A case statement handles any input, numeric or not, cleanly.
install_x_ui() {
    echo "Choose the version of x-ui to install:"
    echo "1) alireza"
    echo "2) MHSanaei"
    read -p "Select an option (1 or 2): " xui_choice

    case "$xui_choice" in
        1)
            bash <(curl -Ls https://raw.githubusercontent.com/alireza0/x-ui/master/install.sh)
            echo "alireza version of x-ui installed."
            ;;
        2)
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
            echo "MHSanaei version of x-ui installed."
            ;;
        *)
            echo "Invalid option. Please select 1 or 2."
            ;;
    esac
}

# FIX: the original only disabled IPv6 at runtime (sysctl -w), which is
# exactly the problem the menu text itself describes -- it comes back on
# reboot. Writing a sysctl.d drop-in makes it persist without relying on
# rc.local at all.
disable_ipv6() {
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1

    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system > /dev/null 2>&1
    echo "IPv6 disabled now, and permanently after reboot (/etc/sysctl.d/99-disable-ipv6.conf)."
}

# FIX: case-based validated input instead of `-eq` (same crash-on-bad-input
# issue as install_x_ui). Added basic IPv4 validation so a typo doesn't
# silently create a broken tunnel. Addressing now comes from the TUN_V6_*/
# TUN_V4_* variables at the top instead of being hardcoded twice. MTU now
# uses the corrected SIT_MTU/GRE_MTU values.
handle_six_to_four() {
    echo "Choose the type of server:"
    echo "1) Outside"
    echo "2) Iran"
    read -p "Select an option (1 or 2): " six_to_four_choice

    case "$six_to_four_choice" in
        1)
            read -p "Enter the IP outside (this server): " ipkharej
            read -p "Enter the IP Iran (remote): " ipiran

            if ! is_valid_ipv4 "$ipkharej" || ! is_valid_ipv4 "$ipiran"; then
                echo "IP وارد شده معتبر نیست. دوباره اجرا کن و آدرس درست بده."
                return 1
            fi

            commands=$(cat <<EOF
ip tunnel add 6to4_To_IR mode sit remote ${ipiran} local ${ipkharej}
ip -6 addr add ${KH_V6}/64 dev 6to4_To_IR
ip link set 6to4_To_IR mtu ${SIT_MTU}
ip link set 6to4_To_IR up

ip -6 tunnel add GRE6Tun_To_IR mode ip6gre remote ${IR_V6} local ${KH_V6}
ip addr add ${KH_V4}/30 dev GRE6Tun_To_IR
ip link set GRE6Tun_To_IR mtu ${GRE_MTU}
ip link set GRE6Tun_To_IR up
EOF
)
            eval "$commands"
            setup_rc_local "6to4-outside" "$commands"
            echo "Commands executed for the outside server."
            ;;
        2)
            read -p "Enter the IP Iran (this server): " ipiran
            read -p "Enter the IP outside (remote): " ipkharej

            if ! is_valid_ipv4 "$ipkharej" || ! is_valid_ipv4 "$ipiran"; then
                echo "IP وارد شده معتبر نیست. دوباره اجرا کن و آدرس درست بده."
                return 1
            fi

            commands=$(cat <<EOF
ip tunnel add 6to4_To_KH mode sit remote ${ipkharej} local ${ipiran}
ip -6 addr add ${IR_V6}/64 dev 6to4_To_KH
ip link set 6to4_To_KH mtu ${SIT_MTU}
ip link set 6to4_To_KH up

ip -6 tunnel add GRE6Tun_To_KH mode ip6gre remote ${KH_V6} local ${IR_V6}
ip addr add ${IR_V4}/30 dev GRE6Tun_To_KH
ip link set GRE6Tun_To_KH mtu ${GRE_MTU}
ip link set GRE6Tun_To_KH up

sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A PREROUTING -p tcp --dport 22 -j DNAT --to-destination ${IR_V4}
iptables -t nat -A PREROUTING -j DNAT --to-destination ${KH_V4}
iptables -t nat -A POSTROUTING -j MASQUERADE
EOF
)
            eval "$commands"
            setup_rc_local "6to4-iran" "$commands"
            # FIX: ip_forward was only ever set at runtime via the eval above;
            # rc.local does re-run it on boot, but giving it its own sysctl.d
            # drop-in too means forwarding survives even if rc.local service
            # is disabled/masked (common on newer distros).
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-tunnel-forward.conf
            sysctl --system > /dev/null 2>&1
            echo "Commands executed for the Iran server."
            ;;
        *)
            echo "Invalid option. Please select 1 or 2."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# FIX: "Remove tunnels" used to only ever clean up the "_To_IR" interface
# names and a single DNAT rule. If you'd set this up as the Iran side
# (_To_KH names), running this did essentially nothing -- interfaces,
# NAT rules and rc.local entries were all left behind. This is now a real
# uninstall: it asks for confirmation, then checks for and removes every
# interface / iptables rule / rc.local block / sysctl.d file this script
# could have created on either side, reporting exactly what it found.
# ---------------------------------------------------------------------------
uninstall_tunnel() {
    echo "این کار تمام تنظیمات 6to4/GRE6 (هر دو سمت) و فورواردینگ مربوط بهش رو پاک می‌کنه."
    read -p "مطمئنی؟ (y/n): " confirm
    case "$confirm" in
        y|Y|yes|Yes) ;;
        *)
            echo "لغو شد."
            return 0
            ;;
    esac

    echo "Removing tunnels..."

    local iface found=0
    for iface in 6to4_To_IR 6to4_To_KH GRE6Tun_To_IR GRE6Tun_To_KH; do
        if ip link show "$iface" >/dev/null 2>&1; then
            ip link del "$iface" 2>/dev/null && { echo "  removed interface: $iface"; found=1; }
        fi
    done
    [ "$found" -eq 0 ] && echo "  (no tunnel interfaces found)"

    # Remove every matching copy of each rule -- the while-loop handles
    # leftover duplicates from before this script was made idempotent.
    while iptables -t nat -D PREROUTING -p tcp --dport 22 -j DNAT --to-destination "${IR_V4}" 2>/dev/null; do
        echo "  removed iptables rule: DNAT dport 22 -> ${IR_V4}"
    done
    while iptables -t nat -D PREROUTING -j DNAT --to-destination "${KH_V4}" 2>/dev/null; do
        echo "  removed iptables rule: DNAT -> ${KH_V4}"
    done
    while iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null; do
        echo "  removed iptables rule: MASQUERADE"
    done

    remove_rc_local_tag "6to4-outside"
    remove_rc_local_tag "6to4-iran"
    echo "  cleared rc.local persistence for the tunnel (other persisted settings, e.g. timezone, left untouched)"

    if [ -f /etc/sysctl.d/99-tunnel-forward.conf ]; then
        rm -f /etc/sysctl.d/99-tunnel-forward.conf
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
        sysctl --system >/dev/null 2>&1
        echo "  removed persistent ip_forward=1 and reset forwarding to off"
    fi

    echo "Tunnel fully removed and uninstalled."
}

change_nameserver() {
    FILE="/etc/resolv.conf"
    # FIX: on systemd-resolved systems /etc/resolv.conf is a symlink and gets
    # regenerated, so a direct edit here can quietly stop having any effect.
    if [ -L "$FILE" ]; then
        echo "هشدار: $FILE یک symlink هست (معمولا یعنی systemd-resolved مدیریتش می‌کنه)."
        echo "ممکنه تغییر بعد از ریستارت سرویس یا ریبوت از بین بره -- اگه اینطور شد،"
        echo "به جاش /etc/systemd/resolved.conf رو ویرایش کن یا از resolvectl استفاده کن."
    fi
    if [ -f "$FILE" ]; then
        # FIX: timestamped backup so repeated runs don't overwrite the
        # one real backup of the original file.
        cp "$FILE" "${FILE}.bak.$(date +%s)"
        sed -i '/^nameserver /d' "$FILE"
        { echo "nameserver 8.8.8.8"; echo "nameserver 1.1.1.1"; } >> "$FILE"
        echo "NameServers have been updated."
    else
        echo "$FILE does not exist."
    fi
}

# Execute the selected option
case $server_choice in
    1)
        handle_six_to_four
        ;;
    2)
        uninstall_tunnel
        ;;
    3)
        wget --no-check-certificate -O /opt/bbr.sh https://github.com/teddysun/across/raw/master/bbr.sh
        chmod 755 /opt/bbr.sh
        /opt/bbr.sh
        echo "BBR optimization enabled."
        ;;
    4)
        fix_whatsapp_time
        ;;
    5)
        optimize
        ;;
    6)
        install_x_ui
        ;;
    7)
        change_nameserver
        ;;
    8)
        disable_ipv6
        ;;
    *)
        echo "Invalid option. Please select 1, 2, 3, 4, 5, 6, 7, or 8."
        ;;
esac
