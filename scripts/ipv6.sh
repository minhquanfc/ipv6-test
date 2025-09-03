#!/bin/sh

random() {
	tr </dev/urandom -dc A-Za-z0-9 | head -c8
	echo
}

random_port() {
	while :; do
		PORT=$((RANDOM % 20001 + 30000))  # Port từ 30000–50000
		if ! echo "${used_ports[@]}" | grep -qw "$PORT"; then
			used_ports+=($PORT)
			echo $PORT
			return
		fi
	done
}

main_interface=$(ip route get 8.8.8.8 | awk '{print $5}')

# Tạo IPv6 chuẩn với format đúng
gen_ipv6() {
	local prefix=$1
	local suffix=""

	# Tạo 4 nhóm hex cuối (64 bit cuối)
	for i in {1..4}; do
		local group=$(printf "%x" $((RANDOM * RANDOM % 65536)))
		suffix="${suffix}:${group}"
	done

	# Loại bỏ dấu : đầu tiên
	suffix=${suffix:1}

	local ipv6="${prefix}:${suffix}"

	# Kiểm tra trùng lặp
	if ! echo "${used_ipv6s[@]}" | grep -qw "$ipv6"; then
		used_ipv6s+=($ipv6)
		echo $ipv6
	else
		gen_ipv6 $prefix  # Đệ quy nếu trùng
	fi
}

install_3proxy() {
    echo "🔧 Installing 3proxy..."
    mkdir -p /3proxy
    cd /3proxy

    # Sử dụng phiên bản mới nhất
    URL="https://github.com/z3APA3A/3proxy/archive/0.9.4.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.4
    make -f Makefile.Linux

    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    mv bin/3proxy /usr/local/etc/3proxy/bin/

    # Tạo service file
    cat > /usr/lib/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
PIDFile=/var/run/3proxy.pid
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -USR1 \$MAINPID
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable 3proxy

    # Cấu hình hệ thống
    echo "* hard nofile 999999" >> /etc/security/limits.conf
    echo "* soft nofile 999999" >> /etc/security/limits.conf

    # IPv6 forwarding
    cat >> /etc/sysctl.conf <<EOF
net.ipv6.conf.${main_interface}.proxy_ndp=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.ip_nonlocal_bind=1
net.core.somaxconn=65535
EOF
    sysctl -p

    # Tắt firewall
    systemctl stop firewalld 2>/dev/null
    systemctl disable firewalld 2>/dev/null

    cd $WORKDIR
}

# Cấu hình 3proxy không cần auth
gen_3proxy() {
    cat <<EOF
daemon
maxconn 5000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush

$(awk -F "/" '{print "proxy -6 -n -a -p" $2 " -i0.0.0.0 -e" $3}' ${WORKDATA})
EOF
}

# Tạo file proxy format: IP:PORT
gen_proxy_file_for_user() {
    cat > proxy.txt <<EOF
$(awk -F "/" '{print $1 ":" $2}' ${WORKDATA})
EOF
}

upload_proxy() {
    cd $WORKDIR
    local PASS=$(random)
    zip --password $PASS proxy.zip proxy.txt

    # Thử nhiều service upload
    local URL=""
    for service in "https://0x0.st" "https://transfer.sh" "https://file.io"; do
        if [ "$service" = "https://transfer.sh" ]; then
            URL=$(curl -s --upload-file proxy.zip https://transfer.sh/proxy.zip)
        elif [ "$service" = "https://file.io" ]; then
            URL=$(curl -s -F file=@proxy.zip https://file.io | jq -r .link 2>/dev/null)
        else
            URL=$(curl -s -F file=@proxy.zip $service)
        fi

        if [ ! -z "$URL" ] && [ "$URL" != "null" ]; then
            break
        fi
    done

    echo ""
    echo "✅ Proxy is ready! Format: IP:PORT (No authentication required)"
    echo "📊 Total proxies created: $COUNT"
    echo "📦 Download link: ${URL}"
    echo "🔐 Archive password: ${PASS}"
    echo "🌐 IPv4: $IP4 | IPv6 Subnet: $IP6"
}

gen_data() {
    for i in $(seq 1 $COUNT); do
        PORT=$(random_port)
        IPV6=$(gen_ipv6 $IP6)
        echo "$IP4/$PORT/$IPV6"
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $2 " -m state --state NEW -j ACCEPT"}' ${WORKDATA})
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ip -6 addr add " $3 "/128 dev '$main_interface'"}' ${WORKDATA})
EOF
}

# Kiểm tra IPv6 support
check_ipv6() {
    if [ ! -f /proc/net/if_inet6 ]; then
        echo "❌ IPv6 is not supported on this system!"
        exit 1
    fi

    if ! ping6 -c1 2001:4860:4860::8888 >/dev/null 2>&1; then
        echo "⚠️ Warning: IPv6 connectivity test failed. Proxies may not work properly."
    fi
}

# == MAIN SETUP ==
echo "🚀 IPv6 Proxy Generator - Optimized Version"
echo "============================================"

# Kiểm tra quyền root
if [ "$(id -u)" != "0" ]; then
   echo "❌ This script must be run as root"
   exit 1
fi

check_ipv6

echo "🛠️ Installing packages..."
yum -y install gcc net-tools bsdtar zip make curl jq >/dev/null 2>&1

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

# Lấy IP
echo "🌐 Getting IP addresses..."
IP4=$(curl -4 -s --connect-timeout 10 icanhazip.com)
IP6=$(curl -6 -s --connect-timeout 10 icanhazip.com | cut -f1-4 -d':')

if [ -z "$IP4" ]; then
    echo "❌ Cannot get IPv4 address"
    exit 1
fi

if [ -z "$IP6" ]; then
    echo "❌ Cannot get IPv6 subnet"
    exit 1
fi

echo "✅ IPv4: $IP4"
echo "✅ IPv6 Subnet: $IP6"

# Hỏi số lượng proxy
while true; do
    read -p "❓ Enter number of proxies to create (1-1000): " COUNT
    if echo "$COUNT" | grep -Eq '^[0-9]+$' && [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 1000 ]; then
        break
    else
        echo "⚠️ Please enter a valid number between 1 and 1000!"
    fi
done

echo "⏳ Creating $COUNT proxies..."

# Khởi tạo mảng
used_ports=()
used_ipv6s=()

install_3proxy

# Tạo dữ liệu
echo "📝 Generating proxy data..."
gen_data > $WORKDATA

echo "🔥 Configuring firewall rules..."
gen_iptables > $WORKDIR/boot_iptables.sh

echo "🌐 Configuring IPv6 addresses..."
gen_ifconfig > $WORKDIR/boot_ifconfig.sh

# Cấu hình network
echo 'NM_CONTROLLED="no"' >> /etc/sysconfig/network-scripts/ifcfg-${main_interface}
chmod +x $WORKDIR/boot_*.sh

# Tạo cấu hình 3proxy
echo "⚙️ Generating 3proxy configuration..."
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# Tạo startup script
cat > /etc/rc.local <<EOF
#!/bin/bash
touch /var/lock/subsys/local
systemctl start NetworkManager.service
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 999999
systemctl start 3proxy
EOF

chmod +x /etc/rc.local

# Khởi động các service
echo "🚀 Starting services..."
bash $WORKDIR/boot_iptables.sh
bash $WORKDIR/boot_ifconfig.sh
systemctl start 3proxy

# Kiểm tra trạng thái
if systemctl is-active --quiet 3proxy; then
    echo "✅ 3proxy service is running"
else
    echo "❌ 3proxy service failed to start"
    systemctl status 3proxy
fi

# Tạo và upload file proxy
echo "📦 Preparing proxy list..."
gen_proxy_file_for_user
upload_proxy

echo ""
echo "🎉 Setup completed successfully!"
echo "💡 Tip: Proxies work without username/password authentication"
echo "🔄 Service will auto-start on reboot"