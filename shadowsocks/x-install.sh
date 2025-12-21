#!/bin/bash
set -e

# --- Global Variables (全域變數) ---
# 定義顏色代碼，用於終端機輸出美化
RED="\033[1;31m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
NC="\033[0m"

# 定義工作目錄與檔案路徑
WORK_DIR="/opt/v2ray-docker"
CONFIG_FILE="$WORK_DIR/config.json"
LOCAL_CONFIG_PATH="./config.json"

# 預設的 SSH 端口
DEFAULT_SSH_PORT="22" 

# 初始化變數
SHADOWSOCKS_PASSWORD=""
SHADOWSOCKS_PORT=""
USE_LOCAL_CONFIG=false
FINAL_PASSWORD=""
FINAL_PORT=""

# 檢查是否存在本地配置
if [ -f "$LOCAL_CONFIG_PATH" ]; then
    echo -e "${GREEN}Found local config.json. Parameters are optional.${NC}"
    USE_LOCAL_CONFIG=true
else
    # 如果沒有本地配置，則必須提供兩個參數
    if [ $# -ne 2 ]; then
        echo -e "${RED}Error: No local config.json found.${NC}"
        echo -e "${RED}Usage: $0 <password> <port>${NC}"
        exit 1
    fi
    SHADOWSOCKS_PASSWORD="$1"
    SHADOWSOCKS_PORT="$2"
fi

# --- Helper Functions (輔助函數) ---

# 檢查 Root 權限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[Error] This script must be run as root.${NC}"
        exit 1
    fi
}

# 進度條函數
show_progress() {
    local percent=$1
    local message=$2
    local width=50 # 進度條寬度
    local num_filled=$((width * percent / 100))
    local num_empty=$((width - num_filled))
    
    printf "\r\033[K" 
    printf "${BLUE}[%-*s]${NC} ${GREEN}%d%%${NC} : %s" "$width" "$(printf "%0.s#" $(seq 1 $num_filled))" "$percent" "$message"
}

# 錯誤處理函數
error_exit() {
    echo ""
    echo -e "${RED}[Error] $1${NC}"
    exit 1
}

# 獲取當前 SSH 端口
get_current_ssh_port() {
    local port="$DEFAULT_SSH_PORT"
    if [ -f "/etc/ssh/sshd_config" ]; then
        # 提取端口
        local config_port=$(grep -i '^Port ' /etc/ssh/sshd_config | grep -v '^\s*#' | awk '{print $2}' | head -n 1 || true)
        if [[ -n "$config_port" && "$config_port" =~ ^[0-9]+$ ]]; then
            port="$config_port"
        fi
    fi
    echo "$port"
}

# --- Core Logic (核心邏輯) ---

# 1. 優化系統參數
configure_system() {
    # 設置 BBR 擁塞控制與 Cake 隊列算法
    cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.icmp_echo_ignore_all = 1
EOF
    sysctl -p >/dev/null
}

# 2. 安裝所有系統依賴
install_system_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    
    local required_packages=("wget" "curl" "jq" "ufw")
    local packages_to_install=()

    show_progress 15 "Updating package lists..."
    if ! apt-get update >/dev/null 2>&1; then
        error_exit "Failed to update package lists."
    fi

    for pkg in "${required_packages[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            packages_to_install+=("$pkg")
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        local pkg_list="${packages_to_install[*]}"
        show_progress 20 "Installing missing dependencies: (${pkg_list})..."
        if ! apt-get install -y "${packages_to_install[@]}" >/dev/null 2>&1; then
            error_exit "Failed to install required packages: ${pkg_list}."
        fi
    fi
}

# 3. 安裝 Docker Engine
install_docker() {
    if ! command -v docker &> /dev/null; then
        show_progress 30 "Installing Docker engine..."
        if ! curl -fsSL https://get.docker.com | bash -s docker >/dev/null 2>&1; then
            error_exit "Failed to download and install Docker."
        fi
    else
        show_progress 30 "Docker is already installed."
    fi
    
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker >/dev/null 2>&1
}

# 4. 準備檔案與規則
prepare_files() {
    mkdir -p "$WORK_DIR"
    
    # --- 處理 V2Ray 配置 ---
    
    # 檢查腳本運行目錄下是否有用戶提供的配置
    if [ "$USE_LOCAL_CONFIG" = true ]; then
        # 將本地配置檔移動到目標目錄。如果移動失敗，則報錯退出。
        show_progress 55 "Using local config.json. Moving to $WORK_DIR..."
        if ! mv "$LOCAL_CONFIG_PATH" "$CONFIG_FILE"; then
            error_exit "Failed to move local config.json to $WORK_DIR."
        fi
        
        # 從配置中提取密碼和端口，用於最終顯示和防火牆
        export FINAL_PASSWORD=$(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .settings.password' "$CONFIG_FILE" 2>/dev/null || echo "N/A")
        export FINAL_PORT=$(jq -r '.inbounds[] | select(.protocol=="shadowsocks") | .port' "$CONFIG_FILE" 2>/dev/null || echo "N/A")
        
    else
        # 未找到用戶配置：生成新配置 (使用傳入的參數)
        show_progress 55 "Generating new config using parameters..."
        
        # 使用傳入的密碼和端口
        export FINAL_PASSWORD="$SHADOWSOCKS_PASSWORD"
        export FINAL_PORT="$SHADOWSOCKS_PORT"
        local current_pwd="$SHADOWSOCKS_PASSWORD"
        local current_port="$SHADOWSOCKS_PORT"

        # 寫入標準 JSON 設定
        cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "hosts": {
      "dns.google": "8.8.8.8",
      "geosite:category-ads-all": "127.0.0.1",
      "geosite:cn": "127.0.0.1"
    },
    "servers": [
      {
        "address": "tls://8.8.8.8:853"
      }
    ]
  },
  "inbounds": [
    {
      "port": $current_port,
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "aes-128-gcm",
        "password": "SS-WS-2017@$current_pwd",
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
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    },
    {
      "protocol": "freedom",
      "tag":"direct",
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
        "domain": [
          "geosite:cn", 
          "geosite:category-ads-all"
        ]
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
    fi
}

# 5. 建立 Docker Compose 檔案
create_docker_compose() {
    # 注意: network_mode: "host" 會導致容器直接使用主機網絡端口，因此需確保主機端口未被佔用
    cat > "$WORK_DIR/docker-compose.yml" << EOF
services:
  v2ray:
    image: v2fly/v2fly-core:latest
    container_name: v2ray-core
    restart: always
    network_mode: "host"
    volumes:
      - ./config.json:/etc/v2ray/config.json
    command: ["run", "-config", "/etc/v2ray/config.json"] 
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

# 6. 設定防火牆
configure_firewall() {
    # 靜默檢測當前 SSH 端口
    local CURRENT_SSH_PORT=$(get_current_ssh_port)
    # V2Ray 端口已在 prepare_files 中確定為 $FINAL_PORT
    local V2RAY_PORT="$FINAL_PORT"
    
    show_progress 85 "Configuring firewall rules (SSH Port: $CURRENT_SSH_PORT, SS Port: $V2RAY_PORT)..."
    
    if command -v ufw &> /dev/null; then        
        # 允許 SSH (使用檢測到的端口)
        ufw allow "$CURRENT_SSH_PORT" >/dev/null 2>&1
        
        # 允許 V2Ray/Shadowsocks 端口 
        if [[ -n "$V2RAY_PORT" && "$V2RAY_PORT" =~ ^[0-9]+$ ]]; then
             ufw allow "$V2RAY_PORT" >/dev/null 2>&1
        else
             echo -e "${RED}Warning: Unable to parse V2Ray port ($V2RAY_PORT), please manually check your UFW settings!${NC}"
        fi
        
        # 強制啟用 UFW 防火牆
        ufw --force enable >/dev/null 2>&1
    fi
}

# 7. 啟動容器
start_container() {
    cd "$WORK_DIR"
    docker compose down >/dev/null 2>&1
    # 使用 -f 確保 docker compose 格式正確
    docker compose -f docker-compose.yml up -d >/dev/null 2>&1
    
    # 檢查容器是否成功啟動
    if ! docker compose ps | grep -q "Up"; then
        error_exit "Docker container failed to start. Please check logs: docker compose logs v2ray"
    fi
}

# 8. 創建腳本級別的管理指令
create_management_script() {    
    local CONTROL_SCRIPT="/usr/local/bin/v2rayctl"
    local TARGET_DIR="$WORK_DIR"
    
    cat > "$CONTROL_SCRIPT" << EOF
#!/bin/bash

# --- V2Ray Docker Management Script ---
# 工作目錄定義
WORK_DIR="$TARGET_DIR"

# 定義顏色
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m"

# 檢查工作目錄是否存在
if [ ! -d "\$WORK_DIR" ]; then
    echo -e "\${RED}Error: V2Ray directory not found at \$WORK_DIR\${NC}"
    exit 1
fi

# 幫助選單
show_help() {
    echo -e "\${BLUE}V2Ray Docker Manager (v2rayctl)\${NC}"
    echo -e "Usage: v2rayctl [command]"
    echo -e ""
    echo -e "Commands:"
    echo -e "  \${GREEN}start\${NC}      Start V2Ray container"
    echo -e "  \${GREEN}stop\${NC}       Stop V2Ray container"
    echo -e "  \${GREEN}restart\${NC}    Restart V2Ray container"
    echo -e "  \${GREEN}status\${NC}     Check container status"
    echo -e "  \${GREEN}logs\${NC}       View real-time logs"
    echo -e "  \${GREEN}edit\${NC}       Edit config.json and auto-restart"
    echo -e "  \${GREEN}config\${NC}     Show current config.json content"
    echo -e "  \${GREEN}uninstall\${NC}  Remove V2Ray, configs, and this script"
    echo -e ""
}

# 參數檢查
if [ -z "\$1" ]; then
    show_help
    exit 1
fi

cd "\$WORK_DIR"

case "\$1" in
    start|stop|restart)
        # 啟動、停止、重啟
        echo -e "\${BLUE}Executing: docker compose \$1 ...\${NC}"
        docker compose "\$1"
        ;;
    
    status|ps)
        # 查看狀態
        docker compose ps
        ;;
        
    logs)
        # 查看日誌
        docker compose logs -f
        ;;
        
    config)
        # 展示當前配置
        echo -e "\${BLUE}--- Current Configuration (\$WORK_DIR/config.json) ---\${NC}"
        if command -v jq &> /dev/null; then
            jq . config.json
        else
            cat config.json
        fi
        echo -e "\${BLUE}---------------------------------------------------\${NC}"
        ;;
        
    edit)
        # 快捷編輯並重啟
        echo -e "\${YELLOW}Opening configuration file...\${NC}"
        
        # 檢測編輯器
        EDITOR="vi"
        if command -v nano &> /dev/null; then
            EDITOR="nano"
        fi
        
        # 備份配置
        cp config.json config.json.bak
        
        # 執行編輯
        \$EDITOR config.json
        
        # 檢查文件語法 (簡單檢查是否為空)
        if [ ! -s config.json ]; then
            echo -e "\${RED}Error: Config file is empty. Restoring backup...\${NC}"
            mv config.json.bak config.json
            exit 1
        fi
        
        echo -e "\${GREEN}Configuration saved. Restarting V2Ray to apply changes...\${NC}"
        docker compose restart
        
        if [ \$? -eq 0 ]; then
            echo -e "\${GREEN}Success! V2Ray restarted with new config.\${NC}"
        else
            echo -e "\${RED}Restart failed! Restoring backup config...\${NC}"
            mv config.json.bak config.json
            docker compose restart
            echo -e "\${YELLOW}Backup restored. Please check your JSON syntax.\${NC}"
        fi
        ;;
        
    uninstall)
        # 卸載全部文件
        echo -e "\${RED}WARNING: This will remove V2Ray container, images, configuration files, and this script.\${NC}"
        read -p "Are you sure you want to proceed? [y/N] " -n 1 -r
        echo ""
        if [[ \$REPLY =~ ^[Yy]\$ ]]; then
            echo -e "\${YELLOW}Stopping and removing containers...\${NC}"
            docker compose down -v
            
            echo -e "\${YELLOW}Removing files...\${NC}"
            cd /
            rm -rf "\$WORK_DIR"
            
            echo -e "\${YELLOW}Removing control script...\${NC}"
            rm "\$0"
            
            echo -e "\${GREEN}V2Ray Docker has been successfully uninstalled.\${NC}"
        else
            echo -e "Uninstall cancelled."
        fi
        ;;
        
    *)
        show_help
        exit 1
        ;;
esac
EOF

    # 賦予執行權限
    chmod +x "$CONTROL_SCRIPT"
}

# 9. 檢查 V2Ray 狀態並決定是否重啟
check_status_and_reboot() {
    # 檢查容器狀態
    local status=$(docker inspect -f '{{.State.Status}}' v2ray-core 2>/dev/null || echo "not running")
    
    echo ""
    if [ "$status" == "running" ]; then
        echo -e "V2Ray Docker container status: ${GREEN}active ($status)${NC}"  # 綠色
        
        # 只有當 V2Ray 狀態為 active 時才執行以下重啟步驟
        
        # 顯示提示訊息，告知系統將於 3 秒後重啟，並使用紅色背景高亮數字 3
        echo -e "The script has finished running and the system will restart in \033[41m 3 \033[0m seconds."
        
        # 倒數計時從 2 到 0，每秒更新顯示，使用紅色背景高亮倒數數字
        for i in 2 1 0; do
            echo -en "\rSystem restarting in \033[41m $i \033[0m s,"
            sleep 1s  # 每顯示一次等待 1 秒
        done
        echo ""  # 換行
        
        # 顯示最終重啟提示
        echo "System restarting now!"
        
        # 重啟系統
        reboot

    else
        echo -e "V2Ray Docker container status: ${RED}$status${NC}"  # 紅色
        echo -e "${RED}Error: V2Ray container is not active. System will NOT restart.${NC}"
        exit 1  # 退出腳本，不執行後續重啟
    fi
}


# --- Main Execution Flow (主執行流程) ---

check_root

echo -e "${GREEN}Starting V2Ray (Docker) Installation...${NC}"
echo -e "Configuring with Password: ${GREEN}$SHADOWSOCKS_PASSWORD${NC} and Port: ${GREEN}$SHADOWSOCKS_PORT${NC}"
echo ""

# 步驟 1: 優化系統
show_progress 10 "Optimizing system parameters (BBR)..."
configure_system
sleep 1

# 步驟 2: 安裝系統依賴
show_progress 15 "Checking and installing system dependencies..."
install_system_dependencies
sleep 1

# 步驟 3: 安裝 Docker Engine
show_progress 30 "Checking and installing Docker..."
install_docker
sleep 1

# 步驟 4: 準備檔案與生成設定 (包含本地配置檢查, 使用參數)
show_progress 50 "Preparing files and generating configuration..."
prepare_files
sleep 1

# 步驟 5: 生成 Docker Compose
show_progress 70 "Creating docker-compose.yml..."
create_docker_compose
sleep 1

# 步驟 6: 設定防火牆
show_progress 85 "Configuring firewall rules (Port $SHADOWSOCKS_PORT)..."
configure_firewall
sleep 1

# 步驟 7: 啟動服務
show_progress 95 "Starting V2Ray container..."
start_container
sleep 2

# 步驟 8: 創建管理指令
show_progress 99 "Creating global management command..."
create_management_script
echo ""

# 顯示最終資訊
show_progress 100 "Installation completed!"

echo ""
clear

echo -e "${GREEN}==========================================================${NC}"
echo -e " Installation Complete! Please take note of the following information:"
echo -e "${GREEN}==========================================================${NC}"
echo -e "  Directory       : ${WORK_DIR}"
echo -e "  Password        : ${GREEN}${FINAL_PASSWORD}${NC}"
echo -e "  Port            : ${GREEN}${FINAL_PORT}${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo -e "  ${BLUE}Quick Management Command: v2rayctl${NC}"
echo -e "  - Edit Config   : ${GREEN}v2rayctl edit${NC}"
echo -e "  - Restart       : ${GREEN}v2rayctl restart${NC}"
echo -e "  - View Config   : ${GREEN}v2rayctl config${NC}"
echo -e "  - View Logs     : ${GREEN}v2rayctl logs${NC}"
echo -e "  - Uninstall     : ${RED}v2rayctl uninstall${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""
sleep 4

# 步驟 8: 檢查狀態並決定是否重啟
check_status_and_reboot
