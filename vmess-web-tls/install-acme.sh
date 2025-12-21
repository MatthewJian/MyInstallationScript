#!/bin/bash
echo -e "This script will run in \033[42m 3 \033[0m seconds."
sleep 1s
for i in 2 1 0; do
	echo -en "\rRunning in \033[42m $i \033[0m s,"
	sleep 1s
done
echo ""
echo "Running now!"

sleep 1s

apt update
apt install -y curl nginx
curl -O https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
bash install-release.sh

if [[ -z "$1" ]]; then
	echo -e "\033[1m\033[31mError: no input provided.\033[0m"
	exit 1
fi
commonname=$(printf '%q' "$1")
v2rayuuid=$(cat /proc/sys/kernel/random/uuid)
numbers=(11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97)
websocketaddress="${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}"

mkdir -p /etc/nginx/ssl
apt-get update && apt-get install -y curl socat cron lsof
systemctl enable --now cron
curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
~/.acme.sh/acme.sh --set-default-ca --server buypass
lsof -i:"80" | awk 'NR>1 {print $2}' | xargs -r kill -9
~/.acme.sh/acme.sh --issue -d ${commonname} --standalone
acme.sh --install-cert -d ${commonname} --key-file /etc/nginx/ssl/private.pem --fullchain-file /etc/nginx/ssl/certificate.pem --reloadcmd "service nginx force-reload"

    
cat > /usr/local/etc/v2ray/config.json << EOF
{
  "inbounds": [
    {
      "port": 8488,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$v2rayuuid",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
        "path": "/$websocketaddress"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

cat > /etc/nginx/sites-enabled/default << EOF
server {
	listen 80;
	listen [::]:80;
	server_name ${commonname};

	return 301 https://${commonname}\$request_uri;
	add_header Cache-Control "no-cache, no-store, must-revalidate";
}

server {
	listen 443 ssl backlog=65535;
	listen [::]:443 ssl backlog=65535;
	server_name $commonname;

	root /var/www/html;
	index index.html index.htm index.nginx-debian.html;
	
	ssl_certificate /etc/nginx/ssl/certificate.pem;
	ssl_certificate_key /etc/nginx/ssl/private.pem;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
	ssl_prefer_server_ciphers on;
	ssl_session_timeout 1d;
	ssl_session_cache shared:SSL:30m;
	ssl_session_tickets off;
	
	location /{
		proxy_redirect off;
		proxy_pass https://sci-hub.hkvisa.net;
		proxy_ssl_server_name on;
		proxy_set_header Host "sci-hub.hkvisa.net";
		}

	location /$websocketaddress {
		if (\$http_upgrade != "websocket") {
			 return 404;
		}
		proxy_pass http://127.0.0.1:8488;
		proxy_http_version 1.1;
		proxy_set_header Connection "upgrade";
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Host \$http_host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		}
}
EOF

sleep 1s
systemctl start v2ray
systemctl enable v2ray
systemctl restart nginx.service
sleep 1s

cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

fs.file-max = 6815744
fs.aio-max-nr = 1048576

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.wmem_default = 8388608
net.core.rmem_default = 8388608
net.ipv4.tcp_rmem = 32768 8388608 67108864
net.ipv4.tcp_wmem = 32768 8388608 67108864
net.ipv4.tcp_mem = 16777216 25165824 33554432
net.core.netdev_max_backlog = 524288
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_orphans = 4194304

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_thin_linear_timeouts = 1
net.unix.max_dgram_qlen = 32768

vm.overcommit_memory = 2
vm.oom_kill_allocating_task = 0

net.ipv4.icmp_echo_ignore_all = 1
EOF
sysctl -p

cat >> /etc/security/limits.conf << EOF
*	soft	noproc	1000000
*	hard	noproc	1000000
*	soft	nofile	1000000
*	hard	nofile	1000000
EOF

echo "ulimit -SHn 1000000" >> /etc/profile
source /etc/profile

currentsshport=$(grep -oP '(?<=Port )\d+' /etc/ssh/sshd_config)

apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ${currentsshport}
ufw allow 80
ufw allow 443
ufw enable

sed -i 's/^#MaxSessions 10$/MaxSessions 2/' /etc/ssh/sshd_config
sed -i 's/^#MaxAuthTries 6$/MaxAuthTries 2/' /etc/ssh/sshd_config

echo -e "The uuid of vmess is: \033[42m $v2rayuuid \033[0m"
echo -e "The address of websocket is: \033[42m /${websocketaddress} \033[0m"

echo -e "The script has finished running and the system will restart in \033[41m 5 \033[0m seconds."
sleep 1s
for i in 4 3 2 1 0; do
	echo -en "\rSystem restarting in \033[41m $i \033[0m s,"
	sleep 1s
done
echo ""
echo "System restarting now!"
sleep 1s
reboot
