#!/bin/sh

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

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
main_interface=$(ip route get 8.8.8.8 | awk -- '{printf $5}')

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

install_3proxy() {
    echo "installing 3proxy"
    mkdir -p /3proxy
    cd /3proxy
    URL="https://github.com/z3APA3A/3proxy/archive/0.9.3.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.3
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    mv /3proxy/3proxy-0.9.3/bin/3proxy /usr/local/etc/3proxy/bin/
    wget https://raw.githubusercontent.com/thuongtin/ipv4-ipv6-proxy/master/scripts/3proxy.service-Centos8 --output-document=/3proxy/3proxy-0.9.3/scripts/3proxy.service2
    cp /3proxy/3proxy-0.9.3/scripts/3proxy.service2 /usr/lib/systemd/system/3proxy.service
    systemctl link /usr/lib/systemd/system/3proxy.service
    systemctl daemon-reload
    echo "* hard nofile 999999" >>  /etc/security/limits.conf
    echo "* soft nofile 999999" >>  /etc/security/limits.conf
    echo "net.ipv6.conf.$main_interface.proxy_ndp=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.proxy_ndp=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    echo "net.ipv6.ip_nonlocal_bind = 1" >> /etc/sysctl.conf
    sysctl -p
    systemctl stop firewalld
    systemctl disable firewalld

    cd $WORKDIR
}

# Config 3proxy KHÔNG CẦN AUTHENTICATION
gen_3proxy() {
    cat <<EOF
daemon
maxconn 4000
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

$(awk -F "/" '{print "proxy -6 -n -a -p" $3 " -i" $2 " -e" $4}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $2 ":" $3}' ${WORKDATA})
EOF
}

upload_proxy() {
    cd $WORKDIR
    echo "✅ Proxy is ready! Format: IP:PORT (NO AUTH REQUIRED)"
    echo "📋 Proxy list saved to: ${WORKDIR}/proxy.txt"
    cat proxy.txt
}

# Data format: IP/PORT/IPV6 (không có user/pass)
gen_data() {
    for i in $(seq 1 $COUNT); do
        PORT=$(random_port)
        echo "$IP4/$PORT/$(gen64 $IP6)"
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $2 " -m state --state NEW -j ACCEPT"}' ${WORKDATA})
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig '$main_interface' inet6 add " $3 "/64"}' ${WORKDATA})
EOF
}

optimize_system() {
    echo "🔧 Optimizing system for proxy performance..."

    # Tăng giới hạn kết nối
    cat >> /etc/sysctl.conf << EOF
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
EOF

    sysctl -p

    # Cập nhật limits
    cat >> /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
}

restart_3proxy() {
    echo "🔄 Restarting 3proxy service..."
    systemctl stop 3proxy 2>/dev/null || killall 3proxy 2>/dev/null
    sleep 2

    # Test config trước khi start
    echo "🧪 Testing 3proxy config..."
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg -t

    if [ $? -eq 0 ]; then
        echo "✅ Config syntax is OK"
        systemctl start 3proxy
        systemctl enable 3proxy

        if systemctl is-active --quiet 3proxy; then
            echo "✅ 3proxy started successfully"
        else
            echo "⚠️ Starting 3proxy manually..."
            /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
        fi
    else
        echo "❌ Config syntax error!"
        exit 1
    fi
}

test_proxy() {
    echo "🧪 Testing first proxy..."
    FIRST_PROXY=$(head -n1 ${WORKDATA})
    TEST_IP=$(echo $FIRST_PROXY | cut -d'/' -f1)
    TEST_PORT=$(echo $FIRST_PROXY | cut -d'/' -f2)

    echo "Testing: $TEST_IP:$TEST_PORT (NO AUTH)"

    # Test connection without authentication
    timeout 10 curl -x $TEST_IP:$TEST_PORT -s https://httpbin.org/ip

    if [ $? -eq 0 ]; then
        echo "✅ Proxy test successful!"
    else
        echo "⚠️ Proxy test failed - check configuration"
        # Thử test với localhost
        echo "Testing with localhost..."
        timeout 10 curl -x 127.0.0.1:$TEST_PORT -s https://httpbin.org/ip
    fi
}

# == MAIN SETUP ==
echo "🛠️ Installing packages..."
yum -y install gcc net-tools bsdtar zip make curl >/dev/null

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

if [ -z "$IP4" ] || [ -z "$IP6" ]; then
    echo "⚠️ Không thể lấy IP address. Vui lòng kiểm tra kết nối mạng!"
    exit 1
fi

echo "🌐 Internal IP: $IP4 — IPv6 Subnet: $IP6"

# Ask user how many proxies to create
read -p "❓ Nhập số lượng proxy muốn tạo: " COUNT
if ! echo "$COUNT" | grep -Eq '^[0-9]+$' || [ "$COUNT" -le 0 ] || [ "$COUNT" -gt 1000 ]; then
    echo "⚠️ Số lượng không hợp lệ! (1-1000)"
    exit 1
fi

used_ports=()
used_ipv6s=()

optimize_system
install_3proxy

echo "🔧 Generating proxy configuration..."
gen_data >$WORKDATA
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
echo NM_CONTROLLED="no" >> /etc/sysconfig/network-scripts/ifcfg-${main_interface}
chmod +x $WORKDIR/boot_*.sh /etc/rc.local

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.local <<EOF
#!/bin/bash
systemctl start NetworkManager.service
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 1048576
systemctl start 3proxy
EOF

chmod +x /etc/rc.local

# Chạy các lệnh cấu hình
bash $WORKDIR/boot_iptables.sh
bash $WORKDIR/boot_ifconfig.sh

restart_3proxy

gen_proxy_file_for_user
test_proxy
upload_proxy

echo ""
echo "🎯 Proxy setup completed! (NO AUTHENTICATION REQUIRED)"
echo "📋 Configuration saved in: $WORKDATA"
echo "⚡ 3proxy config: /usr/local/etc/3proxy/3proxy.cfg"
echo ""
echo "📝 Proxy format: IP:PORT"
echo "🔍 To check proxy status: systemctl status 3proxy"
echo "📊 To view logs: journalctl -u 3proxy -f"
echo ""
echo "⚠️  WARNING: These proxies have NO AUTHENTICATION!"
echo "🔒 Anyone can use them if they know IP:PORT"