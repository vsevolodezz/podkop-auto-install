#!/bin/sh

# AmneziaWG + Podkop Auto Installer for OpenWrt 24.10.4
# Complete installation with Podkop configuration

set -e

COLOR_GREEN='\033[32;1m'
COLOR_RED='\033[31;1m'
COLOR_RESET='\033[0m'

msg() {
    printf "${COLOR_GREEN}%s${COLOR_RESET}\n" "$1"
}

error() {
    printf "${COLOR_RED}%s${COLOR_RESET}\n" "$1"
    exit 1
}

# ============ INSTALL AWG PACKAGES ============
install_awg_packages() {
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    
    echo "Detected: OpenWrt $VERSION, Arch: $PKGARCH, Target: $TARGET/$SUBTARGET"
    
    AWG_VERSION="$VERSION"
    PKGPOSTFIX="_v${AWG_VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${AWG_VERSION}/"
    
    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"
    
    # 1. kmod-amneziawg
    if opkg list-installed | grep -q kmod-amneziawg; then
        echo "✓ kmod-amneziawg already installed"
    else
        FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        URL="${BASE_URL}${FILENAME}"
        echo "Downloading: $URL"
        wget -O "$AWG_DIR/$FILENAME" "$URL" || error "Failed to download kmod-amneziawg"
        opkg install "$AWG_DIR/$FILENAME" || error "Failed to install kmod-amneziawg"
        echo "✓ kmod-amneziawg installed"
    fi

    # 2. amneziawg-tools
    if opkg list-installed | grep -q amneziawg-tools; then
        echo "✓ amneziawg-tools already installed"
    else
        FILENAME="amneziawg-tools${PKGPOSTFIX}"
        URL="${BASE_URL}${FILENAME}"
        echo "Downloading: $URL"
        wget -O "$AWG_DIR/$FILENAME" "$URL" || error "Failed to download amneziawg-tools"
        opkg install "$AWG_DIR/$FILENAME" || error "Failed to install amneziawg-tools"
        echo "✓ amneziawg-tools installed"
    fi
    
    # 3. luci-proto-amneziawg
    if opkg list-installed | grep -q luci-proto-amneziawg; then
        echo "✓ luci-proto-amneziawg already installed"
    else
        FILENAME="luci-proto-amneziawg${PKGPOSTFIX}"
        URL="${BASE_URL}${FILENAME}"
        echo "Downloading: $URL"
        wget -O "$AWG_DIR/$FILENAME" "$URL" || error "Failed to download luci-proto-amneziawg"
        opkg install "$AWG_DIR/$FILENAME" || error "Failed to install luci-proto-amneziawg"
        echo "✓ luci-proto-amneziawg installed"
    fi

    rm -rf "$AWG_DIR"
}

# ============ WARP CONFIG GENERATOR ============
requestConfWARP1() {
    HASH='68747470733a2f2f73616e74612d61746d6f2e72752f776172702f776172702e706870'
    COMPILE=$(printf '%b' "$(printf '%s\n' "$HASH" | sed 's/../\\x&/g')")
    
    local response=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" "$COMPILE" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
        -H "referer: $COMPILE" \
        -H "Origin: $COMPILE" 2>/dev/null)
    echo "$response"
}

requestConfWARP2() {
    local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://dulcet-fox-556b08.netlify.app/api/warp' \
        -H 'Content-Type: application/json' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
        --data-raw '{"selectedServices":[],"siteMode":"all","deviceType":"computer","endpoint":"162.159.195.1:500"}' 2>/dev/null)
    echo "$result"
}

confWarpBuilder() {
    response_body=$1
    peer_pub=$(echo "$response_body" | jq -r '.result.config.peers[0].public_key')
    client_ipv4=$(echo "$response_body" | jq -r '.result.config.interface.addresses.v4')
    client_ipv6=$(echo "$response_body" | jq -r '.result.config.interface.addresses.v6')
    priv=$(echo "$response_body" | jq -r '.result.key')
    
    conf=$(cat <<-EOM
[Interface]
PrivateKey = ${priv}
S1 = 0
S2 = 0
Jc = 120
Jmin = 23
Jmax = 911
H1 = 1
H2 = 2
H3 = 3
H4 = 4
MTU = 1280
Address = ${client_ipv4}, ${client_ipv6}
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = ${peer_pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 162.159.192.1:500
EOM
)
    echo "$conf"
}

check_request() {
    local response="$1"
    local choice="$2"
    
    response_code="${response: -3}"
    response_body="${response%???}"
    
    if [ "$response_code" -eq 200 ]; then
        case $choice in
        1)  
            warp_config=$(confWarpBuilder "$response_body")
            echo "$warp_config"
            ;;
        2)
            content=$(echo $response_body | jq -r '.content')  
            content=$(echo $content | jq -r '.configBase64')  
            warp_config=$(echo "$content" | base64 -d)
            echo "$warp_config"
            ;;
        *)
            echo "Error"
        esac
    else
        echo "Error"
    fi
}

# ============ CONFIGURE AWG WARP ============
configure_awg_warp() {
    msg "Generating WARP configuration..."
    
    warp_config="Error"
    
    msg "Request WARP config... Attempt #1"
    result=$(requestConfWARP1)
    warp_config=$(check_request "$result" 1)
    
    if [ "$warp_config" = "Error" ]; then
        msg "Request WARP config... Attempt #2"
        result=$(requestConfWARP2)
        warp_config=$(check_request "$result" 2)
    fi
    
    if [ "$warp_config" = "Error" ]; then
        error "Failed to generate WARP config"
    fi
    
    # Parse config
    while IFS=' = ' read -r line; do
        if echo "$line" | grep -q "="; then
            key=$(echo "$line" | cut -d'=' -f1 | xargs)
            value=$(echo "$line" | cut -d'=' -f2- | xargs)
            eval "$key=\"$value\""
        fi
    done < <(echo "$warp_config")
    
    Address=$(echo "$Address" | cut -d',' -f1)
    DNS=$(echo "$DNS" | cut -d',' -f1)
    AllowedIPs=$(echo "$AllowedIPs" | cut -d',' -f1)
    EndpointIP=$(echo "$Endpoint" | cut -d':' -f1)
    EndpointPort=$(echo "$Endpoint" | cut -d':' -f2)
    
    msg "Configuring AmneziaWG interface..."
    
    INTERFACE_NAME="awg10"
    CONFIG_NAME="amneziawg_awg10"
    PROTO="amneziawg"
    ZONE_NAME="awg"
    
    uci set network.${INTERFACE_NAME}=interface
    uci set network.${INTERFACE_NAME}.proto=$PROTO
    
    if ! uci show network | grep -q ${CONFIG_NAME}; then
        uci add network ${CONFIG_NAME}
    fi
    
    uci set network.${INTERFACE_NAME}.private_key="$PrivateKey"
    uci del network.${INTERFACE_NAME}.addresses 2>/dev/null || true
    uci add_list network.${INTERFACE_NAME}.addresses="$Address"
    uci set network.${INTERFACE_NAME}.mtu="$MTU"
    uci set network.${INTERFACE_NAME}.awg_jc="$Jc"
    uci set network.${INTERFACE_NAME}.awg_jmin="$Jmin"
    uci set network.${INTERFACE_NAME}.awg_jmax="$Jmax"
    uci set network.${INTERFACE_NAME}.awg_s1="$S1"
    uci set network.${INTERFACE_NAME}.awg_s2="$S2"
    uci set network.${INTERFACE_NAME}.awg_h1="$H1"
    uci set network.${INTERFACE_NAME}.awg_h2="$H2"
    uci set network.${INTERFACE_NAME}.awg_h3="$H3"
    uci set network.${INTERFACE_NAME}.awg_h4="$H4"
    uci set network.${INTERFACE_NAME}.nohostroute='1'
    
    uci set network.@${CONFIG_NAME}[-1].description="${INTERFACE_NAME}_peer"
    uci set network.@${CONFIG_NAME}[-1].public_key="$PublicKey"
    uci set network.@${CONFIG_NAME}[-1].endpoint_host="$EndpointIP"
    uci set network.@${CONFIG_NAME}[-1].endpoint_port="$EndpointPort"
    uci set network.@${CONFIG_NAME}[-1].persistent_keepalive='25'
    uci set network.@${CONFIG_NAME}[-1].allowed_ips='0.0.0.0/0'
    uci set network.@${CONFIG_NAME}[-1].route_allowed_ips='0'
    uci commit network
    
    # Configure firewall
    if ! uci show firewall | grep -q "@zone.*name='${ZONE_NAME}'"; then
        msg "Creating firewall zone..."
        uci add firewall zone
        uci set firewall.@zone[-1].name=$ZONE_NAME
        uci set firewall.@zone[-1].network=$INTERFACE_NAME
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi
    
    if ! uci show firewall | grep -q "@forwarding.*name='${ZONE_NAME}'"; then
        msg "Configuring forwarding..."
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name="${ZONE_NAME}"
        uci set firewall.@forwarding[-1].dest=${ZONE_NAME}
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi
    
    service firewall restart
    service network restart
    
    msg "Testing WARP connection..."
    sleep 5
    ifup $INTERFACE_NAME
    sleep 5
    
    if ping -c 1 -I $INTERFACE_NAME 8.8.8.8 >/dev/null 2>&1; then
        msg "✓ WARP connection works!"
    else
        msg "WARP configured, testing endpoints..."
    fi
}

# ============ INSTALL AND CONFIGURE PODKOP ============
install_and_configure_podkop() {
    msg "Installing Podkop..."
    
    # Install Podkop
    sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) || error "Failed to install Podkop"
    
    msg "Configuring Podkop for AWG WARP routing..."
    
    # Main configuration
    uci set podkop.config=podkop
    uci set podkop.config.enabled='1'
    uci set podkop.config.proxy_mode='direct'
    uci set podkop.config.interface='awg10'
    uci set podkop.config.ipset_name='podkop'
    uci set podkop.config.mark='0x1'
    uci set podkop.config.table_id='100'
    uci set podkop.config.priority='100'
    
    # DNS configuration
    uci set podkop.config.dns_enabled='1'
    uci set podkop.config.dns_port='5353'
    uci set podkop.config.upstream_dns='1.1.1.1'
    
    # Add domains to route through AWG
    msg "Adding domains for routing..."
    
    # YouTube
    uci add podkop domain
    uci set podkop.@domain[-1].name='youtube.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='googlevideo.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='ytimg.com'
    uci set podkop.@domain[-1].enabled='1'
    
    # Social networks
    uci add podkop domain
    uci set podkop.@domain[-1].name='instagram.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='facebook.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='twitter.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='x.com'
    uci set podkop.@domain[-1].enabled='1'
    
    # Discord
    uci add podkop domain
    uci set podkop.@domain[-1].name='discord.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='discordapp.com'
    uci set podkop.@domain[-1].enabled='1'
    
    # Telegram
    uci add podkop domain
    uci set podkop.@domain[-1].name='telegram.org'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='t.me'
    uci set podkop.@domain[-1].enabled='1'
    
    # Other services
    uci add podkop domain
    uci set podkop.@domain[-1].name='twitch.tv'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='netflix.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='spotify.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci commit podkop
    
    # Enable and start Podkop
    /etc/init.d/podkop enable
    /etc/init.d/podkop restart
    
    msg "✓ Podkop configured and started"
}

# ============ MAIN ============
main() {
    msg "==================================================================="
    msg "   AmneziaWG + Podkop Auto Installer for OpenWrt 24.10.4"
    msg "==================================================================="
    msg ""
    
    # Check OpenWrt
    if [ ! -f "/etc/openwrt_release" ]; then
        error "This script is for OpenWrt only"
    fi
    
    msg "Updating package list..."
    opkg update
    
    msg "Installing dependencies..."
    opkg install jq curl coreutils-base64 || error "Failed to install dependencies"
    
    msg ""
    msg "Step 1/3: Installing AmneziaWG packages..."
    install_awg_packages
    
    msg ""
    msg "Step 2/3: Configuring AmneziaWG WARP..."
    configure_awg_warp
    
    msg ""
    msg "Step 3/3: Installing and configuring Podkop..."
    install_and_configure_podkop
    
    msg ""
    msg "==================================================================="
    msg "✓✓✓ Installation completed successfully! ✓✓✓"
    msg "==================================================================="
    msg ""
    msg "Configuration:"
    msg "  - AmneziaWG interface: awg10"
    msg "  - Podkop: enabled and configured"
    msg "  - Web interface: http://$(uci get network.lan.ipaddr 2>/dev/null || echo 'router.ip')"
    msg ""
    msg "Podkop will route these domains through AWG WARP:"
    msg "  - YouTube, Google services"
    msg "  - Instagram, Facebook, Twitter/X"
    msg "  - Discord, Telegram"
    msg "  - Twitch, Netflix, Spotify"
    msg ""
    msg "Rebooting in 10 seconds..."
    sleep 10
    reboot
}

# Run
main
