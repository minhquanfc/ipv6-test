#!/bin/bash

# Function to generate random string
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Function to generate random port
random_port() {
    while :; do
        PORT=$((RANDOM % 20001 + 30000))  # Port range: 30000-50000
        if ! echo "${used_ports[@]}" | grep -qw "$PORT"; then
            used_ports+=($PORT)
            echo $PORT
            return
        fi
    done
}

# Initialize arrays
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
main_interface=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
used_ports=()
used_ipv6s=()

# Function to generate IPv6
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    while :; do
        ipv6="$1:$(ip64):$(ip64):$(ip64):$(ip64)"
        if ! echo "${used_ipv6s[@]}" | grep -qw "$ipv6"; then
            used_ipv6s+=($ipv6)
            echo $ipv6
            return
        fi
    done
}

# Function to install 3proxy
install_3proxy() {
    echo "📦 Installing 3proxy..."
    mkdir -p /3proxy
    cd /3proxy || exit
    URL="https://github.com/z3APA3A/3proxy/archive/0.9.3.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.3 || exit
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    mv /3proxy/3proxy-0.9.3/bin/3proxy /usr/local/etc/3proxy/bin/

    # Create systemd service
    cat <<EOF > /usr/lib/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
RemainAfterExit=yes
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # Configure system limits and network settings
    cat <<EOF >> /etc/security/limits.conf
* soft nofile 999999
* hard nofile 999999
EOF

    cat <<EOF >> /etc/sysctl.conf
net.ipv6.conf.$main_interface.proxy_ndp=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.ip_nonlocal_bind=1
EOF

    sysctl -p
    systemctl disable firewalld
    systemctl stop firewalld

    cd "$WORKDIR" || exit
}

# Function to generate 3proxy config
gen_3proxy() {
    cat <<EOF
# 3proxy configuration
daemon
maxconn 2000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush

# DNS Servers
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844

# Authentication settings
auth strong cache
authcache 60

# Users configuration
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "${WORKDATA}")

# Proxy configuration
$(awk -F "/" '{print "auth strong cache\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' "${WORKDATA}")
EOF
}

# Function to generate proxy list file
gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' "${WORKDATA}")
EOF
}

# Function to upload proxy list
upload_proxy() {
    cd "$WORKDIR" || exit
    local PASS
    PASS=$(random)
    zip --password "$PASS" proxy.zip proxy.txt
    URL=$(curl -s -F "file=@proxy.zip" https://0x0.st)

    echo "✅ Proxy is ready! Format: IP:PORT:LOGIN:PASS"
    echo "📦 Download zip archive from: ${URL}"
    echo "🔐 Password: ${PASS}"
}

# Function to generate proxy data
gen_data() {
    for ((i=1; i<=COUNT; i++)); do
        PORT=$(random_port)
        echo "$(random)/$(random)/$IP4/$PORT/$(gen64 "$IP6")"
    done
}

# Function to generate iptables rules
gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "${WORKDATA}")
EOF
}

# Function to generate ifconfig commands
gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig '"$main_interface"' inet6 add " $5 "/64"}' "${WORKDATA}")
EOF
}

# Main installation process
echo "🚀 Starting proxy installation..."

# Create working directory
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit

# Install required packages
echo "🛠️ Installing required packages..."
yum -y install gcc net-tools bsdtar zip make curl >/dev/null

# Get IP addresses
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "🌐 IPv4: $IP4"
echo "🌐 IPv6 Subnet: $IP6"

# Get number of proxies to create
read -p "❓ Enter number of proxies to create: " COUNT
if ! echo "$COUNT" | grep -Eq '^[0-9]+$' || [ "$COUNT" -le 0 ]; then
    echo "⚠️ Invalid number!"
    exit 1
fi

# Install and configure 3proxy
install_3proxy

# Generate data and configuration files
echo "📝 Generating configuration files..."
gen_data > "$WORKDATA"
gen_iptables > "${WORKDIR}/boot_iptables.sh"
gen_ifconfig > "${WORKDIR}/boot_ifconfig.sh"

# Configure network interface
echo "NM_CONTROLLED=no" >> "/etc/sysconfig/network-scripts/ifcfg-${main_interface}"
chmod +x "${WORKDIR}/boot_"*.sh /etc/rc.local

# Generate 3proxy configuration
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# Configure autostart
cat >>/etc/rc.local <<EOF
#!/bin/bash
systemctl start NetworkManager.service
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

# Start services
bash /etc/rc.local

# Generate and upload proxy list
echo "📋 Generating proxy list..."
gen_proxy_file_for_user
upload_proxy

echo "✨ Installation completed!"
echo "⚡ Proxy server is running and ready to use!"