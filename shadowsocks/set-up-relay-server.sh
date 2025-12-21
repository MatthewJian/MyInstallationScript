#!/bin/bash
sleep 1s

apt update

cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p

wget https://github.com/v2fly/v2ray-core/releases/download/v5.8.0/v2ray-linux-64.zip && wget https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh && bash install-release.sh --local v2ray-linux-64.zip

shadowsocksport=$(printf '%q' "$1")
shadowsockspassword1=$(printf '%q' "$2")
shadowsockspassword2=$(printf '%q' "$3")
commonname=$(printf '%q' "$4")
websocketaddress=$(printf '%q' "$5")

cat > /usr/local/etc/v2ray/config.json << EOF
{
	"inbounds": [
		{
			"listen": "0.0.0.0",
			"port": $shadowsocksport,
			"protocol": "shadowsocks",
			"settings": {
				"method": "aes-128-gcm",
				"password": "$shadowsockspassword1",
				"udp": true
			}
		}
	],
    "outbounds": [
		{
			"protocol": "shadowsocks",
			"settings": {
				"servers": [
					{
						"address": "$commonname",
						"port": 443,
						"method": "aes-128-gcm",
						"password": "SS-WS-2017@$shadowsockspassword2!"
					}
				]
			},
			"streamSettings": {
				"network": "ws",
				"security": "tls",
				"wsSettings": {
					"path": "/WS-SS-2017/$websocketaddress"
				}
			},
			"tag": "proxy"
		},
		{
			"protocol": "blackhole",
			"settings": {},
			"tag": "block"
		}
	],
	"routing": {
		"domainStrategy": "IPOnDemand",
		"strategy": "rules",
		"rules": [
			{
				"type": "field",
				"ip": [
					"geoip:private",
					"geoip:cn"
				],
				"outboundTag": "block"
			}
		]
	}
}
EOF

systemctl enable v2ray && systemctl start v2ray && systemctl daemon-reload && systemctl status v2ray

sleep 5s
reboot