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
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.icmp_echo_ignore_all = 1
EOF
sysctl -p >/dev/null

# 將參數轉義並儲存到變量
dokodemodoorport=$(printf '%q' "$1")
commonname=$(printf '%q' "$2")
shadowsocksport=$(printf '%q' "$3")
progress_bar 30  # 完成 30%
echo ""  # 換行

# 檢查 curl 是否存在，若無則安裝
if ! command -v curl &>/dev/null; then
    apt update >/dev/null 2>&1 && apt install -y curl >/dev/null 2>&1
fi

# 檢查 wget 是否存在，若無則安裝
if ! command -v wget &>/dev/null; then
    apt update >/dev/null 2>&1 && apt install -y wget >/dev/null 2>&1
fi

# 取得 v2fly/v2ray-core 的最新版本
latest_tag=$(curl -s "https://api.github.com/repos/v2fly/v2ray-core/releases/latest" | grep -oP '"tag_name":\s*"\K(.*)(?=")')
# 構建下載網址
download_url="https://github.com/v2fly/v2ray-core/releases/download/${latest_tag}/v2ray-linux-64.zip"
# 下載最新版本的 V2Ray 執行檔案
wget -q "$download_url" -O v2ray-linux-64.zip >/dev/null 2>&1
# 下載安裝腳本
wget -q https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh -O install-release.sh >/dev/null 2>&1
# 執行安裝腳本安裝 V2Ray
bash install-release.sh --local v2ray-linux-64.zip
progress_bar 50  # 完成 50%

# 檢查是否有本地config.json配置
LOCAL_CONFIG_PATH="./config.json"
TARGET_CONFIG_PATH="/usr/local/etc/v2ray/config.json"

if [ -f "$LOCAL_CONFIG_PATH" ]; then
    echo -e "\033[1;32mFound local config.json, using it for V2Ray.\033[0m"
    cp "$LOCAL_CONFIG_PATH" "$TARGET_CONFIG_PATH"
    rm "$LOCAL_CONFIG_PATH"
else
    # 沒有本地配置則寫入自動生成配置
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
fi

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