#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31mError: This script must be run as root (use sudo).\033[0m"
   exit 1
fi

if [ -f /etc/redhat-release ]; then
    echo -e "\033[1;31mError: This script only supports Debian/Ubuntu systems.\033[0m"
    exit 1
fi

# --- 通用函數 ---

# 成功訊息顯示函數
success_message() {
    # 參數：$1 - 要顯示的成功訊息
    # 功能：以綠色粗體顯示成功訊息
    echo -e "\033[1;32m$1\033[0m"
}

# 錯誤退出函數
error_exit() {
    # 參數：$1 - 錯誤訊息
    # 功能：以紅色粗體顯示錯誤訊息並退出腳本，返回退出碼 1
    echo -e "\033[1;31m$1\033[0m"
    exit 1
}

# 倒計時函數
countdown() {
    # 參數：$1 - 秒數, $2 - 提示訊息, $3 - 顏色代碼
    # 功能：顯示倒計時，支援自訂訊息和顏色，每秒更新顯示
    local seconds=$1
    local message=$2
    local color=$3
    sleep 1s
    for ((i = seconds - 1; i >= 0; i--)); do
        echo -en "\r${message//in/in } ${color} $i \033[0m s,"  # 動態更新倒計時訊息
        sleep 1s
    done
    echo ""
}

# 進度條顯示函數
progress_bar() {
    # 參數：$1 - 進度百分比（0-100）
    # 功能：顯示進度條，使用 # 表示已完成部分，- 表示未完成部分
    local progress=$1
    local width=20  # 進度條總寬度
    local filled=$((width * progress / 100))  # 已完成部分長度
    local empty=$((width - filled))  # 未完成部分長度
    printf "\rProgress: ["
    if [ $filled -gt 0 ]; then
        printf "\033[32m%${filled}s\033[0m" | tr ' ' '#'  # 綠色填充已完成部分
    fi
    if [ $empty -gt 0 ]; then
        printf "%${empty}s" | tr ' ' '-'  # 灰色填充未完成部分
    fi
    printf "] %d%%" "$progress"
    if [ "$progress" -eq 100 ]; then
        echo ""  # 進度達 100% 時換行
    fi
}

# --- 配置檢查與初始化函數 ---

# 檢查現有文件並設置標誌
check_existing_files() {
    # 功能：檢查當前目錄下的配置文件並設置全局標誌，方便後續邏輯判斷
    if [ -f "./config.json" ]; then
        HAS_V2RAY_CONFIG=true
        success_message "Found existing V2Ray config.json in current directory"  # 發現現有 V2Ray 配置文件
    fi
    if [ -f "./nginx.conf" ]; then
        HAS_NGINX_CONFIG=true
        success_message "Found existing Nginx configuration in current directory"  # 發現現有 Nginx 配置文件
    fi
    if [ -f "./certificate.pem" ] && [ -f "./private.pem" ]; then
        HAS_SSL_CERT=true
        success_message "Found existing SSL certificate and private key in current directory"  # 發現現有 SSL 證書和私鑰
    fi
}

# 初始化參數
initialize_parameters() {
    # 功能：解析命令行參數，若缺少必要參數則提示用戶輸入
    while getopts "ud:w:s:v:r" opt; do
        case $opt in
            u) USE_SELFSIGNED=true;;  # -u：使用自簽名證書
            d) DOMAIN="$OPTARG";;     # -d：指定域名
            w) WS_PATH="$OPTARG";;    # -w：指定 WebSocket 路徑
            s) SS_PASSWORD="$OPTARG";; # -s：指定 Shadowsocks 密碼
            v) V2RAY_UUID="$OPTARG";;  # -v：指定 V2Ray UUID
            r) REBOOT=true;;          # -r：設置完成後重啟系統
            ?) echo "用法: $0 [-u] [-d domain] [-w ws_path] [-s ss_password] [-v v2ray_uuid] [-r]"; exit 1;;  # 無效參數時顯示用法
        esac
    done
    
# 確保 DOMAIN 不為空
    if [ -z "$DOMAIN" ]; then
        echo -n "Please enter the domain name (e.g., example.com): "
        read DOMAIN
        if [ -z "$DOMAIN" ]; then
            error_exit "Domain name cannot be empty."
        fi
    fi

    # 處理 SS_PASSWORD 和 V2RAY_UUID 以及 WS_PATH 的自動生成
    if [ "$HAS_V2RAY_CONFIG" = true ]; then
        # 如果已有配置，則從文件中提取
        if ! command -v jq >/dev/null 2>&1; then
            apt update >/dev/null 2>&1 && apt install -y jq >/dev/null 2>&1 || error_exit "Failed to install jq."
        fi
        SS_PASSWORD=$(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .settings.password' ./config.json 2>/dev/null)
        V2RAY_UUID=$(jq -r '.inbounds[] | select(.protocol=="vmess") | .settings.clients[0].id' ./config.json 2>/dev/null)
        WS_PATH=$(jq -r '.inbounds[] | select(.protocol=="vmess") | .streamSettings.wsSettings.path' ./config.json 2>/dev/null)
        echo "Loaded existing configuration from config.json"
    else
        # --- 新的自動生成邏輯 ---
        
        # 生成 Shadowsocks 密碼 (時間戳 MD5 前 12 位)
        if [ -z "$SS_PASSWORD" ]; then
            SS_PASSWORD=$(date +%s%N | md5sum | cut -c 1-12)
            echo "Generated Shadowsocks password: $SS_PASSWORD"
        fi

        # 生成 V2Ray UUID
        if [ -z "$V2RAY_UUID" ]; then
            if ! command -v uuidgen >/dev/null 2>&1; then
                apt update >/dev/null 2>&1 && apt install -y uuid-runtime >/dev/null 2>&1
            fi
            V2RAY_UUID=$(uuidgen)
            echo "Generated V2Ray UUID: $V2RAY_UUID"
        fi

        # 處理 WebSocket 路徑 (如果用戶沒輸入，則自動生成)
        if [ -z "$WS_PATH" ]; then
            RANDOM_PATH=$(date +%s%N | md5sum | cut -c 1-6)
            WS_PATH="/$RANDOM_PATH"
            echo "Auto-generated WebSocket path: $WS_PATH"
        fi
    fi
}

# --- 服務配置函數 ---

# 配置系統參數
configure_system() {
    # 功能：優化網絡性能和安全性，修改 sysctl.conf
    if ! cat >> /etc/sysctl.conf << EOF
# 提升網絡性能
net.core.default_qdisc = cake
# 優化 TCP 性能
net.ipv4.tcp_congestion_control = bbr
# 忽略所有 ICMP 回顯請求
net.ipv4.icmp_echo_ignore_all = 1
EOF
    then
        error_exit "Failed to update sysctl.conf."  # 更新失敗時退出
    fi
    if ! sysctl -p >/dev/null; then
        error_exit "Failed to apply sysctl settings."  # 應用設置失敗時退出
    fi
    sleep 1s
    progress_bar 20  # 更新進度條至 20%
}

# 安裝依賴
install_dependencies() {
    # 功能：更新系統並安裝必要工具和服務
    if ! apt update >/dev/null 2>&1 || ! apt install -y wget curl nginx socat cron lsof ufw >/dev/null 2>&1; then
        error_exit "Failed to install dependencies."  # 安裝失敗時退出
    fi
    progress_bar 40  # 更新進度條至 40%
}

# 安裝 V2Ray
install_v2ray() {
    # 功能：從官方來源下載並安裝 V2Ray
    if ! curl -s -O https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh || ! bash install-release.sh >/dev/null 2>&1; then
        error_exit "Failed to install V2Ray."  # 安裝失敗時退出
    fi
    sleep 1s
    progress_bar 60  # 更新進度條至 60%
    echo ""
}

# 配置 V2Ray
configure_v2ray() {
    # 功能：根據是否有現有配置文件進行 V2Ray 配置
    if [ "$HAS_V2RAY_CONFIG" = true ]; then
        echo "Using existing V2Ray configuration..."  # 使用現有配置文件
        if [ -f "/usr/local/etc/v2ray/config.json" ]; then
            if ! mv /usr/local/etc/v2ray/config.json /usr/local/etc/v2ray/config.json.bak; then
                error_exit "Failed to backup existing V2Ray config."  # 備份失敗時退出
            fi
            echo "Existing config.json found at /usr/local/etc/v2ray/. Backing up to config.json.bak..."
        fi
        if ! mv ./config.json /usr/local/etc/v2ray/config.json; then
            error_exit "Failed to move V2Ray config."  # 移動配置文件失敗時退出
        fi
        chmod 644 /usr/local/etc/v2ray/config.json  # 設置文件權限
        success_message "V2Ray configuration moved and permissions set successfully"
    else
        echo "Generating new V2Ray configuration..."  # 生成新配置文件
        if ! cat > /usr/local/etc/v2ray/config.json << EOF
{
  "inbounds": [
    {
      "port": 8387,
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "aes-128-gcm",
        "password": "$SS_PASSWORD",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "metadataOnly": false
      }
    },
    {
      "port": 8488,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$V2RAY_UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    },
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "ip": [
          "geoip:cn",
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": ["geosite:cn"]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
        then
            error_exit "Failed to generate V2Ray config."  # 生成失敗時退出
        fi
    fi
    if [ ! -f "/usr/local/etc/v2ray/config.json" ]; then
        error_exit "/usr/local/etc/v2ray/config.json does not exist."  # 文件不存在時退出
    fi
    if [ $(wc -l < /usr/local/etc/v2ray/config.json) -le 5 ]; then
        error_exit "/usr/local/etc/v2ray/config.json has too few lines."  # 文件內容過少時退出
    fi
    sleep 1s
    progress_bar 70  # 更新進度條至 70%
    echo ""
}

# 配置 SSL 證書
configure_ssl() {
    # 功能：創建 SSL 目錄並配置證書（自簽名或通過 acme.sh 獲取）
    mkdir -p /etc/nginx/ssl
    if [ "$HAS_SSL_CERT" = true ]; then
        echo "Using existing SSL certificates..."  # 使用現有證書
        if ! mv ./certificate.pem /etc/nginx/ssl/certificate.pem || ! mv ./private.pem /etc/nginx/ssl/private.pem; then
            error_exit "Failed to move existing SSL certificates."  # 移動失敗時退出
        fi
        chmod 600 /etc/nginx/ssl/private.pem  # 設置私鑰權限
    else
        if [ "$USE_SELFSIGNED" = true ]; then
            echo "Generating self-signed SSL certificate..."  # 生成自簽名證書
            if ! openssl genrsa -out /etc/nginx/ssl/private.pem 2048; then
                error_exit "Failed to generate SSL private key."  # 生成私鑰失敗時退出
            fi
            chmod 644 /etc/nginx/ssl/private.pem
            if ! openssl req -new -x509 -key /etc/nginx/ssl/private.pem -out /etc/nginx/ssl/certificate.pem -days 2000 -subj "/CN=$DOMAIN"; then
                error_exit "Failed to generate self-signed SSL certificate."  # 生成證書失敗時退出
            fi
        else
            if ! systemctl enable --now cron >/dev/null 2>&1; then
                error_exit "Failed to enable cron service."  # 啟用 cron 失敗時退出
            fi
            if ! curl -s https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com >/dev/null 2>&1; then
                error_exit "Failed to install acme.sh."  # 安裝 acme.sh 失敗時退出
            fi
            local attempt=0
            local max_attempts=4
            local ca_servers=("letsencrypt:https://acme-v02.api.letsencrypt.org/directory" "zerossl:https://acme.zerossl.com/v2/DV90" "buypass:https://api.buypass.com/acme/directory" "sslcom:https://acme.ssl.com/sslcom-dv-rsa")
            while [ $attempt -lt $max_attempts ] && [ ! -f /etc/nginx/ssl/certificate.pem ] && [ ! -f /etc/nginx/ssl/private.pem ]; do
                local ca_name=$(echo "${ca_servers[$attempt]}" | cut -d':' -f1)
                local ca_url=$(echo "${ca_servers[$attempt]}" | cut -d':' -f2-)
                echo "Attempting SSL certificate issuance with ${ca_name} (Domain: $DOMAIN, Attempt $((attempt + 1)) of $max_attempts)..."  # 嘗試從不同 CA 獲取證書
                ~/.acme.sh/acme.sh --set-default-ca --server "${ca_url}" >/dev/null 2>&1
                lsof -i:"80" | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null  # 釋放 80 端口
                ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
                ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file /etc/nginx/ssl/private.pem --fullchain-file /etc/nginx/ssl/certificate.pem >/dev/null 2>&1
                attempt=$((attempt + 1))
            done
            if [ ! -f /etc/nginx/ssl/certificate.pem ] || [ ! -f /etc/nginx/ssl/private.pem ]; then
                error_exit "SSL certificate generation failed after $max_attempts attempts."  # 多次嘗試失敗時退出
            fi
        fi
    fi
    sleep 1s
    progress_bar 80  # 更新進度條至 80%
}

# 配置 Nginx
configure_nginx() {
    # 功能：配置 Nginx 服務器，支援 HTTP 到 HTTPS 重定向和 WebSocket 代理
    if [ "$HAS_NGINX_CONFIG" = true ]; then
        echo "Using existing Nginx configuration..."  # 使用現有配置文件
        if ! mv ./nginx.conf /etc/nginx/sites-enabled/default; then
            error_exit "Failed to move Nginx config."  # 移動失敗時退出
        fi
    else
        # 提取域名主體並格式化為品牌名
        local brand_name
        # 檢查域名點號數量，若大於等於 2（如 www.domain.com），則取倒數第二段
        if [[ $(echo "$DOMAIN" | tr -cd '.' | wc -c) -ge 2 ]]; then
            brand_name=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)}')
        else
            brand_name=$(echo "$DOMAIN" | cut -d'.' -f1)
        fi
        # 首字母大寫並加上 Cloud 字樣
        brand_name="$(tr '[:lower:]' '[:upper:]' <<< ${brand_name:0:1})${brand_name:1}Cloud"
        mkdir -p /var/www/html
        # 這裡設置為拒絕所有爬蟲，符合「內部傳輸節點」不對外公開的邏輯
        cat > /var/www/html/robots.txt << EOF
User-agent: *
Disallow: /admin/
Disallow: /config/
Disallow: /tmp/
Disallow: /private/
EOF
        cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$brand_name - Secure Internal Data Node</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background-color: #f4f7f6; font-family: 'Segoe UI', system-ui, sans-serif; }
        .navbar { background-color: #2c3e50 !important; }
        .hero-section { background: linear-gradient(135deg, #2c3e50 0%, #4ca1af 100%); color: white; padding: 80px 0; }
        .upload-box { border: 2px dashed #bdc3c7; border-radius: 12px; padding: 50px; text-align: center; background: white; transition: all 0.3s; }
        .upload-box:hover { border-color: #4ca1af; box-shadow: 0 10px 20px rgba(0,0,0,0.05); }
        .status-badge { font-size: 0.8rem; padding: 5px 12px; border-radius: 20px; background: rgba(255,255,255,0.2); }
        .file-list { background: white; border-radius: 8px; overflow: hidden; }
        .file-item { padding: 12px 20px; border-bottom: 1px solid #eee; display: flex; justify-content: space-between; font-size: 0.9rem; }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark">
        <div class="container">
            <a class="navbar-brand fw-bold" href="#">$brand_name <span class="ms-2 status-badge">Node: ${DOMAIN}</span></a>
            <div class="navbar-text text-white-50 d-none d-md-block">Internal Use Only</div>
        </div>
    </nav>

    <div class="hero-section text-center">
        <div class="container">
            <h1 class="display-5 fw-bold">Enterprise File Gateway</h1>
            <p class="lead opacity-75">Secure end-to-end encrypted synchronization for corporate data centers.</p>
        </div>
    </div>

    <div class="container my-5">
        <div class="row">
            <div class="col-lg-8">
                <div class="upload-box shadow-sm mb-4">
                    <div class="display-4 mb-3">📁</div>
                    <h4>Drop files to sync with $brand_name</h4>
                    <p class="text-muted">Maximum file size: 2.0 GB. Files are encrypted via AES-256 before transmission.</p>
                    <button class="btn btn-primary btn-lg px-5 shadow-sm">Select Files</button>
                </div>
                
                <h5 class="mb-3 fw-bold">Recent Node Activity</h5>
                <div class="file-list shadow-sm">
                    <div class="file-item"><span>📄 project_requirements_v2.pdf</span><span class="text-muted">2 mins ago</span></div>
                    <div class="file-item"><span>📊 quarterly_report_q4.xlsx</span><span class="text-muted">15 mins ago</span></div>
                    <div class="file-item"><span>📦 distribution_package.tar.gz</span><span class="text-muted">1 hour ago</span></div>
                </div>
            </div>
            
            <div class="col-lg-4">
                <div class="card border-0 shadow-sm mb-4">
                    <div class="card-body">
                        <h6 class="card-title fw-bold">Node Security Policy</h6>
                        <ul class="list-unstyled small text-muted">
                            <li class="mb-2">✓ Mandatory TLS 1.3 protocol</li>
                            <li class="mb-2">✓ Automatic 24h data purging</li>
                            <li class="mb-2">✓ IP-restricted access logs</li>
                            <li>✓ Zero-knowledge encryption</li>
                        </ul>
                    </div>
                </div>
                <div class="alert alert-info border-0 shadow-sm small">
                    <strong>Notice:</strong> This node is optimized for high-speed peering. If you experience latency, contact your system administrator.
                </div>
            </div>
        </div>
    </div>

    <footer class="py-5 bg-white border-top mt-5 text-center">
        <p class="text-muted mb-0">&copy; $(date +%Y) $brand_name Systems, Inc. | Powered by Global Data Mesh</p>
        <div class="mt-2 small text-success">● System Operational - All services active</div>
    </footer>
</body>
</html>
EOF
        if ! cat > /etc/nginx/sites-enabled/default << EOF
# 拒絕所有未經域名解析的直接訪問 (回傳 444 無回應)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    
    ssl_certificate /etc/nginx/ssl/certificate.pem;
    ssl_certificate_key /etc/nginx/ssl/private.pem;
    
    return 444;
}

# HTTP 到 HTTPS 跳轉
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

# 主服務配置
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    root /var/www/html;
    index index.html;

    ssl_certificate /etc/nginx/ssl/certificate.pem;
    ssl_certificate_key /etc/nginx/ssl/private.pem;
    
    # SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # 隱藏 Nginx 版本號，進一步防掃描
    server_tokens off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # V2Ray WebSocket 代理路徑
    location $WS_PATH {
        if (\$http_upgrade != "websocket") {
            return 404;
        }

        # 如果後端 V2Ray 掉線，不回傳 502，而是隱蔽為 404
        proxy_intercept_errors on;
        error_page 502 =404;

        proxy_pass http://127.0.0.1:8488;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
        then
            error_exit "Failed to generate Nginx config."  # 生成失敗時退出
        fi
    fi
    sleep 1s
    progress_bar 90  # 更新進度條至 90%
}

# 啟動服務
start_services() {
    # 功能：重啟並設置 Nginx 和 V2Ray 服務開機自啟
    if ! systemctl restart nginx >/dev/null 2>&1 || ! systemctl enable nginx >/dev/null 2>&1; then
        error_exit "Failed to start Nginx."  # 啟動 Nginx 失敗時退出
    fi
    if ! systemctl restart v2ray >/dev/null 2>&1 || ! systemctl enable v2ray >/dev/null 2>&1; then
        error_exit "Failed to start V2Ray."  # 啟動 V2Ray 失敗時退出
    fi
    sleep 1s
    progress_bar 100  # 更新進度條至 100%
}

# 檢查服務狀態
check_service_status() {
    # 參數：$1 - 服務名稱
    # 功能：檢查指定服務的運行狀態並以顏色顯示
    local service=$1
    local status=$(systemctl status "$service" | grep -oP '(?<=Active: ).*(?= since)')
    if [[ "$status" =~ ^active ]]; then
        echo -e "$service is \033[1;32m$status\033[0m"  # 綠色表示運行中
    else
        echo -e "$service is \033[1;31m$status\033[0m"  # 紅色表示未運行
    fi
}

# 配置防火牆和 SSH
configure_security() {
    # 功能：優化 SSH 設置並配置防火牆規則
    if ! sed -i 's/^#LoginGraceTime 2m$/LoginGraceTime 30s/' /etc/ssh/sshd_config || ! sed -i 's/^#MaxAuthTries 6$/MaxAuthTries 2/' /etc/ssh/sshd_config; then
        error_exit "Failed to configure SSH settings."  # 修改 SSH 配置失敗時退出
    fi
    if ! sshd -t; then
        echo -e "\033[1;31mError: SSH configuration check failed. Skipping restart to prevent lockout.\033[0m"
    else
        systemctl restart ssh >/dev/null 2>&1
    fi
    # 嘗試從配置讀取，如果沒讀到則默認 22
    SSH_PORT=$(grep "^ *Port" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}')
    if [ -z "$SSH_PORT" ]; then
        SSH_PORT=22
    fi
    echo "Detected SSH Port: $SSH_PORT"
    if ! ufw allow 443/tcp >/dev/null 2>&1 || \
       ! ufw allow 80/tcp >/dev/null 2>&1 || \
       ! ufw allow 8387/tcp >/dev/null 2>&1 || \
       ! ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || \
       ! ufw --force enable >/dev/null 2>&1; then
        error_exit "Failed to configure firewall."
    fi
    sleep 1s
}

# --- 主流程 ---

# 初始化全局變量
USE_SELFSIGNED=false  # 是否使用自簽名證書
REBOOT=false          # 是否在完成後重啟系統
HAS_V2RAY_CONFIG=false  # 是否有現有 V2Ray 配置文件
HAS_NGINX_CONFIG=false  # 是否有現有 Nginx 配置文件
HAS_SSL_CERT=false      # 是否有現有 SSL 證書

# 執行初始化
check_existing_files  # 檢查現有文件
initialize_parameters "$@"  # 初始化參數

# 顯示開始提示
countdown 3 "This script will run in" "\033[42m"  # 3 秒倒計時提示

# 執行配置步驟
configure_system      # 配置系統參數
install_dependencies  # 安裝依賴
install_v2ray         # 安裝 V2Ray
configure_v2ray       # 配置 V2Ray
configure_ssl         # 配置 SSL 證書
configure_nginx       # 配置 Nginx
start_services        # 啟動服務

# 檢查服務狀態
check_service_status "v2ray"  # 檢查 V2Ray 狀態
check_service_status "nginx"  # 檢查 Nginx 狀態

# 配置安全設置
configure_security  # 配置防火牆和 SSH

# 輸出配置信息，使用綠色框框
echo -e "\033[32m ──────────────────────────────────────────────────\033[0m"
echo -e "\033[32m  Configuration Details:                           \033[0m"
echo -e "\033[32m  Shadowsocks Port: 8387                           \033[0m"
echo -e "\033[32m  Shadowsocks Password: $SS_PASSWORD               \033[0m"
echo -e "\033[32m  V2Ray Port: 443                                  \033[0m"
echo -e "\033[32m  V2Ray UUID: $V2RAY_UUID                          \033[0m"
echo -e "\033[32m  Domain: $DOMAIN                                  \033[0m"
echo -e "\033[32m  WebSocket Path: $WS_PATH                         \033[0m"
echo -e "\033[32m ──────────────────────────────────────────────────\033[0m"

# 配置完成後的處理
if [ "$REBOOT" = true ]; then
    echo -e "\033[1;32mThe script has finished running successfully.\033[0m"
    # 若提供了 -r 參數，執行倒計時並重啟
    countdown 5 "The system will restart in" "\033[41m"
    echo "System restarting now!"
    sleep 1s
    reboot
else
    # 若未提供 -r 參數，僅提示用戶
    echo -e "\033[1;32mThe script has finished running successfully.\033[0m"
    echo "System will not restart automatically. To apply all changes, you may reboot manually with 'reboot' if needed."
fi
