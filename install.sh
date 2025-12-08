#!/bin/sh

# AmneziaWG + Podkop Auto Installer for OpenWrt
# With full Podkop configuration

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
    msg "Installing AmneziaWG packages..."
    
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')
    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"
    
    # Install kmod-amneziawg
    if opkg list-installed | grep -q kmod-amneziawg; then
        msg "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${KMOD_AMNEZIAWG_FILENAME}"
        
        msg "Downloading $KMOD_AMNEZIAWG_FILENAME..."
        wget -O "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL" || error "Failed to download kmod-amneziawg"
        
        opkg install "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" || error "Failed to install kmod-amneziawg"
        msg "kmod-amneziawg installed successfully"
    fi

    # Install amneziawg-tools
    if opkg list-installed | grep -q amneziawg-tools; then
        msg "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME="amneziawg-tools${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${AMNEZIAWG_TOOLS_FILENAME}"
        
        msg "Downloading $AMNEZIAWG_TOOLS_FILENAME..."
        wget -O "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" "$DOWNLOAD_URL" || error "Failed to download amneziawg-tools"
        
        opkg install "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" || error "Failed to install amneziawg-tools"
        msg "amneziawg-tools installed successfully"
    fi
    
    # Install luci-app-amneziawg
    if opkg list-installed | grep -q luci-app-amneziawg; then
        msg "luci-app-amneziawg already installed"
    else
        LUCI_APP_AMNEZIAWG_FILENAME="luci-app-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${LUCI_APP_AMNEZIAWG_FILENAME}"
        
        msg "Downloading $LUCI_APP_AMNEZIAWG_FILENAME..."
        wget -O "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL" || error "Failed to download luci-app-amneziawg"
        
        opkg install "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME" || error "Failed to install luci-app-amneziawg"
        msg "luci-app-amneziawg installed successfully"
    fi

    rm -rf "$AWG_DIR"
}

# ============ WARP CONFIG GENERATOR ============
requestConfWARP1() {
    HASH='68747470733a2f2f73616e74612d61746d6f2e72752f776172702f776172702e706870'
    COMPILE=$(printf '%b' "$(printf '%s\n' "$HASH" | sed 's/../\\x&/g')")
    
    local response=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" "$COMPILE" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
        -H "referer: $COMPILE" \
        -H "Origin: $COMPILE")
    echo "$response"
}

requestConfWARP2() {
    local result=$(curl --connect-timeout 20 --max-time 60 -w "%{http_code}" 'https://dulcet-fox-556b08.netlify.app/api/warp' \
        -H 'Content-Type: application/json' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
        --data-raw '{"selectedServices":[],"siteMode":"all","deviceType":"computer","endpoint":"162.159.195.1:500"}')
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
    
    opkg install jq curl coreutils-base64 || error "Failed to install dependencies"
    
    warp_config="Error"
    
    msg "Requesting WARP config (Attempt #1)..."
    result=$(requestConfWARP1)
    warp_config=$(check_request "$result" 1)
    
    if [ "$warp_config" = "Error" ]; then
        msg "Requesting WARP config (Attempt #2)..."
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
    
    # Extract values
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
    
    # Configure interface
    uci set network.${INTERFACE_NAME}=interface
    uci set network.${INTERFACE_NAME}.proto=$PROTO
    
    if ! uci show network | grep -q ${CONFIG_NAME}; then
        uci add network ${CONFIG_NAME}
    fi
    
    uci set network.${INTERFACE_NAME}.private_key=$PrivateKey
    uci del network.${INTERFACE_NAME}.addresses 2>/dev/null || true
    uci add_list network.${INTERFACE_NAME}.addresses=$Address
    uci set network.${INTERFACE_NAME}.mtu=$MTU
    uci set network.${INTERFACE_NAME}.awg_jc=$Jc
    uci set network.${INTERFACE_NAME}.awg_jmin=$Jmin
    uci set network.${INTERFACE_NAME}.awg_jmax=$Jmax
    uci set network.${INTERFACE_NAME}.awg_s1=$S1
    uci set network.${INTERFACE_NAME}.awg_s2=$S2
    uci set network.${INTERFACE_NAME}.awg_h1=$H1
    uci set network.${INTERFACE_NAME}.awg_h2=$H2
    uci set network.${INTERFACE_NAME}.awg_h3=$H3
    uci set network.${INTERFACE_NAME}.awg_h4=$H4
    uci set network.${INTERFACE_NAME}.nohostroute='1'
    
    # Default I1 parameter if not set
    if [ -z "$I1" ]; then
        I1="<b 0xc10000000114367096bb0fb3f58f3a3fb8aaacd61d63a1c8a40e14f7374b8a62dccba6431716c3abf6f5afbcfb39bd008000047c32e268567c652e6f4db58bff759bc8c5aaca183b87cb4d22938fe7d8dca22a679a79e4d9ee62e4bbb3a380dd78d4e8e48f26b38a1d42d76b371a5a9a0444827a69d1ab5872a85749f65a4104e931740b4dc1e2dd77733fc7fac4f93011cd622f2bb47e85f71992e2d585f8dc765a7a12ddeb879746a267393ad023d267c4bd79f258703e27345155268bd3cc0506ebd72e2e3c6b5b0f005299cd94b67ddabe30389c4f9b5c2d512dcc298c14f14e9b7f931e1dc397926c31fbb7cebfc668349c218672501031ecce151d4cb03c4c660b6c6fe7754e75446cd7de09a8c81030c5f6fb377203f551864f3d83e27de7b86499736cbbb549b2f37f436db1cae0a4ea39930f0534aacdd1e3534bc87877e2afabe959ced261f228d6362e6fd277c88c312d966c8b9f67e4a92e757773db0b0862fb8108d1d8fa262a40a1b4171961f0704c8ba314da2482ac8ed9bd28d4b50f7432d89fd800c25a50c5e2f5c0710544fef5273401116aa0572366d8e49ad758fcb29e6a92912e644dbe227c247cb3417eabfab2db16796b2fba420de3b1dc94e8361f1f324a331ddaf1e626553138860757fd0bf687566108b77b70fb9f8f8962eca599c4a70ed373666961a8cb506b96756d9e28b94122b20f16b54f118c0e603ce0b831efea614ad836df6cf9affbdd09596412547496967da758cec9080295d853b0861670b71d9abde0d562b1a6de82782a5b0c14d297f27283a895abc889a5f6703f0e6eb95f67b2da45f150d0d8ab805612d570c2d5cb6997ac3a7756226c2f5c8982ffbd480c5004b0660a3c9468945efde90864019a2b519458724b55d766e16b0da25c0557c01f3c11ddeb024b62e303640e17fdd57dedb3aeb4a2c1b7c93059f9c1d7118d77caac1cd0f6556e46cbc991c1bb16970273dea833d01e5090d061a0c6d25af2415cd2878af97f6d0e7f1f936247b394ecb9bd484da6be936dee9b0b92dc90101a1b4295e97a9772f2263eb09431995aa173df4ca2abd687d87706f0f93eaa5e13cbe3b574fa3cfe94502ace25265778da6960d561381769c24e0cbd7aac73c16f95ae74ff7ec38124f7c722b9cb151d4b6841343f29be8f35145e1b27021056820fed77003df8554b4155716c8cf6049ef5e318481460a8ce3be7c7bfac695255be84dc491c19e9dedc449dd3471728cd2a3ee51324ccb3eef121e3e08f8e18f0006ea8957371d9f2f739f0b89e4db11e5c6430ada61572e589519fbad4498b460ce6e4407fc2d8f2dd4293a50a0cb8fcaaf35cd9a8cc097e3603fbfa08d9036f52b3e7fcce11b83ad28a4ac12dba0395a0cc871cefd1a2856fffb3f28d82ce35cf80579974778bab13d9b3578d8c75a2d196087a2cd439aff2bb33f2db24ac175fff4ed91d36a4cdbfaf3f83074f03894ea40f17034629890da3efdbb41141b38368ab532209b69f057ddc559c19bc8ae62bf3fd564c9a35d9a83d14a95834a92bae6d9a29ae5e8ece07910d16433e4c6230c9bd7d68b47de0de9843988af6dc88b5301820443bd4d0537778bf6b4c1dd067fcf14b81015f2a67c7f2a28f9cb7e0684d3cb4b1c24d9b343122a086611b489532f1c3a26779da1706c6759d96d8ab>"
    fi
    uci set network.${INTERFACE_NAME}.awg_i1="$I1"
    
    uci set network.@${CONFIG_NAME}[-1].description="${INTERFACE_NAME}_peer"
    uci set network.@${CONFIG_NAME}[-1].public_key=$PublicKey
    uci set network.@${CONFIG_NAME}[-1].endpoint_host=$EndpointIP
    uci set network.@${CONFIG_NAME}[-1].endpoint_port=$EndpointPort
    uci set network.@${CONFIG_NAME}[-1].persistent_keepalive='25'
    uci set network.@${CONFIG_NAME}[-1].allowed_ips='0.0.0.0/0'
    uci set network.@${CONFIG_NAME}[-1].route_allowed_ips='0'
    uci commit network
    
    # Configure firewall zone
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
    
    # Test endpoints
    msg "Testing WARP endpoints..."
    WARP_ENDPOINT_HOSTS="162.159.192.1 162.159.195.1 188.114.96.1"
    WARP_ENDPOINT_PORTS="500 1701 4500"
    
    I=0
    for host in $WARP_ENDPOINT_HOSTS; do
        for port in $WARP_ENDPOINT_PORTS; do
            I=$((I+1))
            msg "Testing $host:$port (Attempt #$I)..."
            uci set network.@${CONFIG_NAME}[-1].endpoint_host=$host
            uci set network.@${CONFIG_NAME}[-1].endpoint_port=$port
            uci commit network
            
            ifdown $INTERFACE_NAME 2>/dev/null || true
            ifup $INTERFACE_NAME
            sleep 10
            
            if ping -c 1 -I $INTERFACE_NAME 8.8.8.8 >/dev/null 2>&1; then
                msg "✓ Endpoint $host:$port works!"
                return 0
            fi
        done
    done
    
    msg "No optimal endpoint found, using default..."
}

# ============ INSTALL AND CONFIGURE PODKOP ============
install_and_configure_podkop() {
    msg "Installing Podkop from official repository..."
    
    # Install Podkop using official script
    sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) || error "Failed to install Podkop"
    
    msg "Configuring Podkop for AWG WARP routing..."
    
    # Configure Podkop to use AWG interface
    uci set podkop.config=podkop
    uci set podkop.config.enabled='1'
    uci set podkop.config.proxy_mode='sing-box'
    uci set podkop.config.interface='awg10'
    uci set podkop.config.proxy_type='socks5'
    uci set podkop.config.proxy_host='127.0.0.1'
    uci set podkop.config.proxy_port='1080'
    
    # Add domains for routing through AWG
    uci add podkop domain
    uci set podkop.@domain[-1].name='youtube.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='googlevideo.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='instagram.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='facebook.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci add podkop domain
    uci set podkop.@domain[-1].name='twitter.com'
    uci set podkop.@domain[-1].enabled='1'
    
    uci commit podkop
    
    # Enable and start Podkop
    /etc/init.d/podkop enable
    /etc/init.d/podkop start
    
    msg "✓ Podkop configured successfully"
}

# ============ MAIN ============
main() {
    msg "=== AmneziaWG + Podkop Installer for OpenWrt ==="
    msg ""
    
    # Check OpenWrt
    if [ ! -f "/etc/openwrt_release" ]; then
        error "This script is for OpenWrt only"
    fi
    
    msg "Updating package list..."
    opkg update
    
    # Install dependencies
    msg "Installing dependencies..."
    opkg install jq curl unzip coreutils-base64 || error "Failed to install dependencies"
    
    # Install AWG
    install_awg_packages
    
    # Configure AWG WARP
    configure_awg_warp
    
    # Install and configure Podkop
    install_and_configure_podkop
    
    msg ""
    msg "=== Installation completed! ==="
    msg "AmneziaWG interface: awg10"
    msg "Podkop web interface: http://$(uci get network.lan.ipaddr)/cgi-bin/luci/admin/services/podkop"
    msg ""
    msg "Rebooting in 10 seconds..."
    sleep 10
    reboot
}

# Run
main
