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
apt install -y shadowsocks-libev shadowsocks-v2ray-plugin nginx

commonname=$(printf '%q' "$1")
servername=$(echo "${1%.*}" | awk -F '.' '{print $(NF)}' | sed -E 's/(.)(.*)/\U\1\L\2/')
numbers=(11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97)
if [[ $# -eq 0 ]]; then
	shadowsockspassword="${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}"
	websocketaddress="${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}"
elif [[ $# -eq 1 ]]; then
	shadowsockspassword="${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}"
	websocketaddress="${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}"
else
	shadowsockspassword=$(printf '%q' "$2")
	if [[ $# -eq 2 ]]; then
		websocketaddress="${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}.${numbers[$RANDOM % ${#numbers[@]}]}"
	else
		websocketaddress=$(printf '%q' "$3")
	fi
fi

mkdir -p /etc/nginx/ssl
openssl genrsa -out /etc/nginx/ssl/private.key 2048
chmod 600 /etc/nginx/ssl/private.key
openssl req -new -key /etc/nginx/ssl/private.key -out /etc/nginx/ssl/certificate.csr -subj "/CN=${commonname}"
openssl x509 -req -days 2000 -in /etc/nginx/ssl/certificate.csr -signkey /etc/nginx/ssl/private.key -out /etc/nginx/ssl/certificate.crt
rm /etc/nginx/ssl/certificate.csr

cat > /etc/shadowsocks-libev/config.json << EOF
{
	"server":"127.0.0.1",
	"mode":"tcp_and_udp",
	"server_port":8388,
	"local_port":1080,
	"password":"SS-WS-2017@$shadowsockspassword!",
	"timeout":86400,
	"method":"aes-128-gcm",
	"plugin":"ss-v2ray-plugin",
	"plugin_opts":"server;path=/WS-SS-2017/$websocketaddress;mux=0"
}
EOF

cat > /var/www/html/index.nginx-debian.html << EOF
<!DOCTYPE html>
<html>
	<head>
		<meta charset="UTF-8">
		<title>${servername} FTP Server</title>
		<style>
			body {
				background-color: #f0f0f0;
				display: flex;
				flex-direction: column;
				align-items: center;
				justify-content: center;
				height: 100vh;
				margin: 0;
				font-family: Arial, sans-serif;
			}
			#title {
				position: absolute;
				top: 0;
				text-align: center;
				width: 100%;
				padding: 10px 0;
				background-color: #9ea7aa;
				color: #fff;
				font-size: 24px;
				font-weight: bold;
				box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
			}
			#time {
				font-size: 100px;
				text-align: center;
				font-weight: bold;
				color: #2c3e50;
				margin-bottom: 20px;
			}
			#server-status {
				font-size: 24px;
				font-weight: bold;
				color: #27ae60;
			}
			footer {
				position: absolute;
				bottom: 0;
				text-align: center;
				width: 100%;
				padding: 10px 0;
				background-color: #9ea7aa;
				color: #fff;
				font-size: 14px;
				box-shadow: 0 -2px 4px rgba(0, 0, 0, 0.1);
			}
		</style>
		<script>
			function showTime() {
				var now = new Date();
				var hour = now.getHours();
				var hourString = hour < 10 ? "0" + hour : hour;
				var min = now.getMinutes();
				var minString = min < 10 ? "0" + min : min;
				var sec = now.getSeconds();
				var secString = sec < 10 ? "0" + sec : sec;
				var timeString = hourString + ":" + minString + ":" + secString;
				document.getElementById("time").innerHTML = timeString;
			}
			setInterval(showTime, 1000);
		</script>
	</head>
	<body>
		<div id="title">${servername} FTP Server</div>
		<div id="time"></div>
		<div id="server-status">Server Status: Online</div>
		<footer>&copy; 2023 All rights reserved. ${servername} Inc.</footer>
	</body>
</html>
EOF

cat > /etc/nginx/sites-enabled/default << EOF
server {
	listen 80;
	server_name $commonname;

	location / {
		return 301 https://\$host\$request_uri;
	}
}

server {
	listen 443 ssl;
	server_name $commonname;

	root /var/www/html;
	index index.html index.htm index.nginx-debian.html;
	
	ssl_certificate /etc/nginx/ssl/certificate.crt;
	ssl_certificate_key /etc/nginx/ssl/private.key;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
	ssl_prefer_server_ciphers on;
	ssl_session_timeout 1d;
	ssl_session_cache shared:SSL:30m;
	ssl_session_tickets off;

	location /WS-SS-2017/$websocketaddress {
		if (\$http_upgrade != "websocket") {
			return 404;
		}
		proxy_pass http://127.0.0.1:8388;
		proxy_http_version 1.1;
		proxy_set_header Connection "upgrade";
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Host \$http_host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		}
}
EOF

echo -e "Nginx will restart in \033[42m 3 \033[0m seconds."
for i in 2 1 0; do
	echo -en "\rNginx restarting in \033[42m $i \033[0m s,"
	sleep 1s
done
echo ""
echo "Nginx restarting now!"
systemctl restart shadowsocks-libev.service
systemctl restart nginx.service
sleep 1s

cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

fs.file-max = 2097152

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 1

net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2

net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fin_timeout = 15

net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1

net.ipv4.tcp_window_scaling = 1

net.ipv4.tcp_fastopen = 3

net.ipv4.tcp_max_syn_backlog = 32768

vm.overcommit_memory = 0
vm.oom_kill_allocating_task = 1

net.ipv4.icmp_echo_ignore_all = 1
EOF
sysctl -p

cat >> /etc/security/limits.conf << EOF
*	soft	noproc	65535
*	hard	noproc	65535
*	soft	nofile	65535
*	hard	nofile	65535
EOF

echo "ulimit -SHn 65535" >> /etc/profile
source /etc/profile

currentip=$(who -u | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
currentsshport=$(grep -oP '(?<=Port )\d+' /etc/ssh/sshd_config)
newsshport=$((RANDOM % 20000 + 40001))

sed -i "s/^#\?Port $currentsshport$/Port $newsshport/" /etc/ssh/sshd_config
sed -i "s/^#MaxSessions 10$/MaxSessions 2/" /etc/ssh/sshd_config
sed -i "s/^#MaxAuthTries 6$/MaxAuthTries 2/" /etc/ssh/sshd_config

apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 443
ufw allow 80
ufw enable

echo -e "The new port of ssh is: \033[42m $newsshport \033[0m"
echo -e "The password of shadowsocks-libev is: \033[42m $shadowsockspassword \033[0m"
echo -e "The address of websocket is: \033[42m $websocketaddress \033[0m"

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
