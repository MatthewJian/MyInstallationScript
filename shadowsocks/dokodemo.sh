#!/bin/bash

# 進度條函數
progress_bar() {
    local progress=$1  # 進度百分比
    local width=20     # 進度條寬度
    local filled=$((width * progress / 100))  # 已填充的部分
    local empty=$((width - filled))           # 未填充的部分
    printf "\rProgress: ["
    printf "\033[32m%${filled}s\033[0m" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "] %d%%" "$progress"
    if [ "$progress" -eq 100 ]; then
        echo ""  # 完成時換行
    fi
}

# 顯示提示訊息，告知腳本將於 3 秒後開始運行，並使用綠色背景高亮數字 3
echo -e "This script will run in \033[42m 3 \033[0m seconds."
sleep 1s  # 等待 1 秒
# 倒數計時從 2 到 0，每秒更新顯示，使用綠色背景高亮倒數數字
for i in 2 1 0; do
    echo -en "\rRunning in \033[42m $i \033[0m s,"
    sleep 1s  # 每顯示一次等待 1 秒
done
echo ""  # 換行

# 將網絡優化參數追加到 /etc/sysctl.conf 文件
cat >> /etc/sysctl.conf << EOF
# 設置默認隊列規則為 cake，提升網絡性能
net.core.default_qdisc = cake
# 使用 BBR 擁塞控制算法，優化 TCP 性能
net.ipv4.tcp_congestion_control = bbr
# 忽略所有 ICMP 回顯請求（ping），增強安全性
net.ipv4.icmp_echo_ignore_all = 1
EOF
# 應用 sysctl 配置，並將輸出重定向到 /dev/null 以保持簡潔
sysctl -p >/dev/null

# 將參數轉義並儲存到變量
dokodemodoorport=$(printf '%q' "$1")
commonname=$(printf '%q' "$2")
shadowsocksport=$(printf '%q' "$3")
progress_bar 30  # 完成 30%
echo ""  # 換行

# 下載並安裝 V2Ray
wget -q https://github.com/v2fly/v2ray-core/releases/download/v5.8.0/v2ray-linux-64.zip -O v2ray-linux-64.zip >/dev/null 2>&1 && \
wget -q https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh -O install-release.sh >/dev/null 2>&1 && \
bash install-release.sh --local v2ray-linux-64.zip
progress_bar 50  # 完成 50%

# 創建 V2Ray 配置文件，設定服務器參數
cat > /usr/local/etc/v2ray/config.json << EOF
{
	"inbounds": [
		{
			"listen": "0.0.0.0",
			"port": $dokodemodoorport,
			"protocol": "dokodemo-door",
			"settings": {
				"address": "$commonname",
				"port": $shadowsocksport,
				"network": "tcp,udp"
			},
			"sniffing": {
				"enabled": true,
				"destOverride": ["http", "tls"]
			}
		}
	],
	"outbounds": [
		{
			"protocol": "freedom",
			"settings": {},
			"tag": "direct"
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
			},
   			{
				"type": "field",
				"domain": [
					"geosite:cn"
				],
				"outboundTag": "block"
			},
			{
				"type": "field",
				"network": "tcp,udp",
				"outboundTag": "direct"
			}
		]
	}
}
EOF

# 啟用並啟動 V2Ray 服務，抑制輸出
systemctl enable v2ray >/dev/null 2>&1 && systemctl start v2ray >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
progress_bar 100  # 完成 100%

# 檢查 V2Ray 服務狀態
v2ray_status=$(systemctl status v2ray | grep -oP '(?<=Active: ).*(?= since)')
if [[ "$v2ray_status" =~ ^active ]]; then
    echo -e "V2Ray status: \033[1;32m$v2ray_status\033[0m"  # 綠色
else
    echo -e "V2Ray status: \033[1;31m$v2ray_status\033[0m"  # 紅色
    echo -e "\033[1;31mError: V2Ray is not active. System will not restart.\033[0m"
    exit 1  # 退出腳本，不重啟
fi

# 只有當 V2Ray 狀態為 active 時才執行以下重啟步驟
echo -e "The script has finished running and the system will restart in \033[41m 3 \033[0m seconds."
for i in 2 1 0; do
    echo -en "\rSystem restarting in \033[41m $i \033[0m s,"
    sleep 1s  # 每顯示一次等待 1 秒
done
echo ""  # 換行
echo "System restarting now!"
reboot