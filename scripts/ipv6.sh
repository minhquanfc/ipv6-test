#!/bin/sh
set -e

random() {
	tr </dev/urandom -dc A-Za-z0-9 | head -c5
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
    systemctl link /usr/lib/systemd/system/3proxy.service || true
    systemctl daemon-reload
    echo "* hard nofile 999999" >>  /etc/security/limits.conf
    echo "* soft nofile 999999" >>  /etc/security/limits.conf
    echo "net.ipv6.conf.$main_interface.proxy_ndp=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.proxy_ndp=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    echo "net.ipv6.ip_nonlocal_bind = 1" >> /etc/sysctl.conf
    sysctl -p || true
    systemctl stop firewalld || true
    systemctl disable firewalld || true

    cd $WORKDIR
}

# ===== 3PROXY CONFIG: KHÔNG USER/PASS, CHỈ WHITELIST IP =====
gen_3proxy() {
    # Chuyển danh sách ALLOW_IPS (phân tách bởi dấu phẩy) thành các dòng allow
    IFS=',' read -r -a _ALLOWED <<< "$ALLOW_IPS"
    ALLOW_LINES=""
    for _ip in "${_ALLOWED[@]}"; do
        ALLOW_LINES="${ALLOW_LINES}allow * ${_ip}\n"
    done

    cat <<EOF
daemon
maxconn 2000
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

# ✅ Không dùng user/pass, khóa theo IP nguồn
auth iponly
${ALLOW_LINES}deny *

$(awk -F "/" '{print "proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# Xuất file cho user: chỉ IP:PORT
gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4}' ${WORKDATA})
EOF
}

# Upload ZIP có password (giữ như code cũ)
upload_proxy() {
    cd $WORKDIR
    local PASS=$(random)
    zip --password $PASS proxy.zip proxy.txt >/dev/null
    URL=$(curl -s -F file=@proxy.zip https://0x0.st)
    echo "✅ Proxy is ready! Format: IP:PORT (no auth, IP-whitelist)"
    echo "📦 Download zip archive from: ${URL}"
    echo "🔐 Password: ${PASS}"
}

gen_data() {
    for i in $(seq 1 $COUNT); do
        PORT=$(random_port)
        echo "$(random)/$(random)/$IP4/$PORT/$(gen64 $IP6)"
    done
}

# IPTABLES: CHỈ CHO PHÉP IP TRONG WHITELIST
gen_iptables() {
    IFS=',' read -r -a _ALLOWED <<< "$ALLOW_IPS"
    {
        # Cho phép trước (INSERT) cho từng IP được whitelist
        for _ip in "${_ALLOWED[@]}"; do
            awk -F "/" -v SRC="$_ip" '{print "iptables -I INPUT -p tcp -s " SRC " --dport " $4 " -m state --state NEW -j ACCEPT"}' ${WORKDATA}
        done
        # Sau đó chặn tất cả IP khác truy cập các port proxy
        awk -F "/" '{print "iptables -A INPUT -p tcp --dport " $4 " -j DROP"}' ${WORKDATA}
    } | sed 's/^/ /'
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig '$main_interface' inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

# == MAIN SETUP ==
echo "🛠️ Installing packages..."
yum -y install gcc net-tools bsdtar zip make curl iproute >/dev/null

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "🌐 Internal IP: $IP4 — IPv6 Subnet: $IP6"

# Nhập danh sách IP PUBLIC được phép truy cập (cách nhau bằng dấu phẩy)
read -p "❓ Nhập IP public được phép (ví dụ: 113.22.33.44,203.0.113.7): " ALLOW_IPS
if [ -z "$ALLOW_IPS" ]; then
    echo "⚠️ Bạn chưa nhập IP nào. Dừng để tránh mở toàn bộ."
    exit 1
fi

# Nhập số lượng proxy
read -p "❓ Nhập số lượng proxy muốn tạo: " COUNT
if ! echo "$COUNT" | grep -Eq '^[0-9]+$' || [ "$COUNT" -le 0 ]; then
    echo "⚠️ Số lượng không hợp lệ!"
    exit 1
fi

used_ports=()
used_ipv6s=()

install_3proxy

gen_data >$WORKDATA
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh

# Đảm bảo rc.local tồn tại & executable (một số bản CentOS/AlmaLinux không có sẵn)
if [ ! -f /etc/rc.local ]; then
  echo '#!/bin/sh -e' > /etc/rc.local
  chmod +x /etc/rc.local
fi

chmod +x $WORKDIR/boot_iptables.sh $WORKDIR/boot_ifconfig.sh

# Hạn chế NetworkManager quản card (giữ nguyên như code cũ)
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
echo NM_CONTROLLED="no" >> /etc/sysconfig/network-scripts/ifcfg-${main_interface} || true

# Sinh 3proxy.cfg và autostart
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.local <<EOF
systemctl start NetworkManager.service
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

# Chạy ngay
bash /etc/rc.local

# Xuất file cho user + link tải
gen_proxy_file_for_user
upload_proxy

echo "🎉 Hoàn tất! Proxy chỉ cho phép IP: $ALLOW_IPS"
