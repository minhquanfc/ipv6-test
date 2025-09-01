#!/bin/sh
set -e

random() {
  tr </dev/urandom -dc A-Za-z0-9 | head -c5
  echo
}

random_port() {
  while :; do
    PORT=$((RANDOM % 20001 + 30000))  # 30000–50000
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
  ip64() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
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
  echo "==> Installing 3proxy"
  mkdir -p /3proxy
  cd /3proxy
  URL="https://github.com/z3APA3A/3proxy/archive/0.9.3.tar.gz"
  wget -qO- $URL | bsdtar -xvf-
  cd 3proxy-0.9.3
  make -f Makefile.Linux
  mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
  mv /3proxy/3proxy-0.9.3/bin/3proxy /usr/local/etc/3proxy/bin/

  # service file
  wget -q https://raw.githubusercontent.com/thuongtin/ipv4-ipv6-proxy/master/scripts/3proxy.service-Centos8 -O /3proxy/3proxy-0.9.3/scripts/3proxy.service2
  cp /3proxy/3proxy-0.9.3/scripts/3proxy.service2 /usr/lib/systemd/system/3proxy.service

  # tăng limit cho service
  mkdir -p /etc/systemd/system/3proxy.service.d
  cat >/etc/systemd/system/3proxy.service.d/override.conf <<'EOU'
[Service]
LimitNOFILE=65535
EOU

  systemctl daemon-reload
  systemctl enable 3proxy.service

  # sysctl IPv6 + nonlocal bind
  sysctl -w net.ipv6.conf."$main_interface".proxy_ndp=1
  sysctl -w net.ipv6.conf.all.proxy_ndp=1
  sysctl -w net.ipv6.conf.default.forwarding=1
  sysctl -w net.ipv6.conf.all.forwarding=1
  sysctl -w net.ipv6.ip_nonlocal_bind=1

  # tắt firewalld (bạn đã dùng iptables)
  systemctl stop firewalld || true
  systemctl disable firewalld || true

  cd "$WORKDIR"
}

gen_3proxy() {
  cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
# nới timeout để client kịp gửi lại Proxy-Authorization
timeouts 5 10 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush

# bật xác thực + cache để giảm 407 khi nhiều profile mở đồng thời
auth strong
authcache user 60

# log để debug nhanh (D = ghi time/date)
log /usr/local/etc/3proxy/logs/3proxy.log D
rotate 30

# users: user:CL:pass user2:CL:pass2 ...
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

# mỗi dòng data -> 1 service proxy riêng, allow đúng user
$(awk -F "/" '{
  print "allow " $1 "\n" \
        "proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
        "flush\n"
}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
  cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

upload_proxy() {
  cd "$WORKDIR"
  PASS=$(random)
  zip --password "$PASS" proxy.zip proxy.txt >/dev/null
  URL=$(curl -s -F file=@proxy.zip https://0x0.st)
  echo "✅ Proxy is ready! Format: IP:PORT:LOGIN:PASS"
  echo "📦 Download zip archive from: ${URL}"
  echo "🔐 Password: ${PASS}"
}

gen_data() {
  for i in $(seq 1 $COUNT); do
    PORT=$(random_port)
    echo "$(random)/$(random)/$IP4/$PORT/$(gen64 $IP6)"
  done
}

gen_iptables() {
  cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' ${WORKDATA})
EOF
}

gen_ifconfig() {
  cat <<EOF
$(awk -F "/" '{print "ifconfig '$main_interface' inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

# == MAIN ==
echo "🛠️ Installing packages..."
yum -y install gcc net-tools bsdtar zip make curl iptables >/dev/null

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "🌐 Internal IP: $IP4 — IPv6 Subnet: $IP6"

read -p "❓ Nhập số lượng proxy muốn tạo: " COUNT
if ! echo "$COUNT" | grep -Eq '^[0-9]+$' || [ "$COUNT" -le 0 ]; then
  echo "⚠️ Số lượng không hợp lệ!"
  exit 1
fi

used_ports=()
used_ipv6s=()

install_3proxy

# sinh data / scripts boot
gen_data >"$WORKDATA"
gen_iptables >"$WORKDIR/boot_iptables.sh"
gen_ifconfig >"$WORKDIR/boot_ifconfig.sh"
chmod +x "$WORKDIR"/boot_*.sh

# rc.local compatibility trên Alma/CentOS 8
mkdir -p /etc/rc.d
[ -f /etc/rc.d/rc.local ] || cat >/etc/rc.d/rc.local <<'EORC'
#!/bin/sh
exit 0
EORC
chmod +x /etc/rc.d/rc.local
[ -f /etc/rc.local ] || ln -sf /etc/rc.d/rc.local /etc/rc.local

# append lệnh khởi động vào rc.local (chỉ thêm nếu chưa có)
grep -q "proxy-installer/boot_iptables.sh" /etc/rc.local || cat >>/etc/rc.local <<EOF
systemctl start NetworkManager.service
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

# viết cấu hình 3proxy
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

# chạy boot scripts và start 3proxy bởi systemd (ổn định hơn)
bash "$WORKDIR/boot_iptables.sh"
bash "$WORKDIR/boot_ifconfig.sh"
ulimit -n 65535
systemctl restart 3proxy.service

# xuất file proxy và link tải
gen_proxy_file_for_user
upload_proxy

echo "✅ Done."
