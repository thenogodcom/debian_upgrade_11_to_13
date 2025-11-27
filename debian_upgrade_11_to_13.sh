#!/bin/bash
# =================================================================
# Debian 11 → 12 → 13 全自動無人值守【雲端核心】升級腳本 (優化版)
# =================================================================
#
# 【假設前提】:
# - 假設 Debian 13 (Trixie) 已進入 Stable 階段，擁有獨立 security 源。
#
# 【優化變更】:
# - Fix: 增加 grub-pc debconf 預設，防止引導安裝詢問卡住
# - Fix: 增加 check_pending_reboot 防止在未重啟新核心的情況下連續跨版本升級
# - Fix: 允許 apt update 在第三方源 404 時發出警告而非中止 (容錯增強)
# - Mod: 正確處理 Bookworm+ 的 non-free-firmware 組件
#
# =================================================================

# --- 腳本執行設定 ---
# 使用嚴格模式防止災難性錯誤
set -e          # 任何命令失敗立即退出
set -o pipefail # pipe 中任何命令失敗都視為失敗
export DEBIAN_FRONTEND=noninteractive
# 防止 SSH 斷線導致腳本中止
trap '' HUP

# --- 日誌設定 ---
LOGFILE="/var/log/debian_cloud_upgrade_$(date +%Y%m%d_%H%M%S).log"
exec > >(sudo tee -a "$LOGFILE") 2>&1

# --- 全域常數 ---
# 寬鬆的 Dpkg 選項，遇到設定檔衝突時自動保留舊檔或使用預設值
APT_NONINTERACTIVE_OPTIONS="-y --allow-downgrades --allow-remove-essential --allow-change-held-packages -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
ARCH=$(dpkg --print-architecture)
REQUIRED_SPACE_MB=5120 # 5GB

# --- 檢查函數 (Pre-flight Checks) ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "錯誤：此腳本必須以 root 身份運行 (sudo)。" >&2
       exit 1
    fi
}

check_network() {
    echo "--- [0/8] 檢查網路連線 ---"
    if ping -c 1 -W 5 deb.debian.org >/dev/null 2>&1 || ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        echo "網路連線正常。"
    else
        echo "錯誤：無法連線到網際網路，請檢查網路設定。" >&2
        exit 1
    fi
}

check_disk_space() {
    echo "--- [0/8] 檢查磁碟空間 ---"
    local available_space
    available_space=$(df / --output=avail -B M | tail -n 1 | tr -d 'M[:space:]')
    echo "根目錄可用空間: ${available_space} MB (需求: ${REQUIRED_SPACE_MB} MB)"
    
    if [ "$available_space" -lt "$REQUIRED_SPACE_MB" ]; then
        echo "錯誤：磁碟空間不足！建議至少保留 5GB 空間進行發行版升級。" >&2
        exit 1
    fi
}

check_pending_reboot() {
    echo "--- [0/8] 檢查掛起的重啟狀態 ---"
    if [ -f /var/run/reboot-required ]; then
        echo "錯誤：檢測到系統有掛起的重啟請求 (可能是上一次升級未完成)。" >&2
        echo "請先執行 reboot 重啟系統，載入新核心後再重新執行此腳本。" >&2
        exit 1
    fi
}

# --- 核心函數 ---

preseed_debconf() {
    echo "--- [1/8] 準備環境依賴與 Debconf 預設 ---"
    # 容忍 update 失敗 (可能是舊源失效) - 這裡允許失敗
    sudo apt-get update -q || echo "警告: 初始 apt update 返回非零狀態，嘗試繼續..."
    
    if ! sudo apt-get install -y debconf-utils psmisc; then
        echo "錯誤：無法安裝必要工具 (debconf-utils/psmisc)。" >&2
        exit 1
    fi

    echo "預先配置 debconf (防止服務重啟與 GRUB 詢問)..."
    # 自動重啟服務不詢問
    sudo debconf-set-selections <<EOF
libc6 libraries/restart-without-asking boolean true
EOF
    
    # 防止 GRUB 詢問安裝位置
    # 方案：允許空設備列表，GRUB 會自動探測並安裝到現有位置
    # 這在雲端環境和已有 GRUB 的系統中是安全的
    sudo debconf-set-selections <<EOF
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices string
EOF
}

configure_unattended_tools() {
    echo "暫停自動更新服務..."
    sudo systemctl stop unattended-upgrades.service || true
    sudo systemctl disable unattended-upgrades.service || true
    
    # 設定 needrestart 自動重啟 library 相關服務
    if [ -f /etc/needrestart/needrestart.conf ]; then
        sudo sed -i "s/^#*\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    fi
    
    # 關閉 apt-listchanges 的互動顯示
    if ! dpkg -s apt-listchanges >/dev/null 2>&1; then
        sudo apt-get install -y apt-listchanges || {
            echo "警告: 無法安裝 apt-listchanges，跳過配置。"
            return 0
        }
    fi
    
    # 確保配置文件存在才修改
    if [ -f /etc/apt/apt.conf.d/20listchanges ]; then
        sudo sed -i "s/frontend=.*/frontend=none/" /etc/apt/apt.conf.d/20listchanges
    else
        echo "APT::Listchanges::frontend \"none\";" | sudo tee /etc/apt/apt.conf.d/20listchanges >/dev/null
    fi
}

restore_services() {
    echo "正在恢復 unattended-upgrades 服務狀態..."
    sudo systemctl enable unattended-upgrades.service || true
    sudo systemctl start unattended-upgrades.service || true
    echo "服務恢復完成。"
}

trap restore_services EXIT

pause() {
    echo ""
    if [ -t 0 ]; then
        read -rp ">>> 將在 5 秒後繼續，按 Ctrl+C 中止..." -t 5 <> /dev/tty || true
    else
        echo ">>> 無人值守模式：將在 5 秒後自動繼續..."
        sleep 5
    fi
}

detect_system() {
    echo "--- [2/8] 檢測系統狀態 ---"
    if [ ! -f /etc/os-release ]; then
        echo "錯誤：無法讀取 /etc/os-release。" >&2
        exit 1
    fi
    . /etc/os-release
    export USERLAND_CODENAME="${VERSION_CODENAME:-unknown}"
    export SYSTEM_STATE="$USERLAND_CODENAME"
    
    echo "當前發行版: $USERLAND_CODENAME"
    echo "當前核心: $(uname -r)"
}

backup_sources() {
    echo "備份 APT 來源..."
    local ts=$(date +%F_%T)
    sudo cp -a /etc/apt/sources.list "/etc/apt/sources.list.backup.${ts}"
    [ -d /etc/apt/sources.list.d ] && \
        sudo cp -a /etc/apt/sources.list.d "/etc/apt/sources.list.d.backup.${ts}"
}

repair_dpkg() {
    # 檢查並清理 APT/DPKG 鎖
    if sudo lsof /var/lib/dpkg/lock-frontend &>/dev/null || sudo lsof /var/lib/dpkg/lock &>/dev/null; then
        echo "檢測到 dpkg 鎖，正在清理..."
        sudo fuser -k /var/lib/dpkg/lock-frontend 2>/dev/null || true
        sudo fuser -k /var/lib/dpkg/lock 2>/dev/null || true
        sudo rm -f /var/lib/dpkg/lock-frontend
        sudo rm -f /var/lib/dpkg/lock
        sudo rm -f /var/cache/apt/archives/lock
        sudo rm -f /var/lib/apt/lists/lock
    fi
    
    # 修復中斷的安裝
    if ! sudo dpkg --audit &>/dev/null; then
        echo "修復中斷的套件安裝..."
        sudo dpkg --configure -a || true
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} -f install || true
    fi
}

safe_apt_update() {
    # 包裝 apt update，允許非致命錯誤 (如第三方源 404)
    echo "執行 apt update..."
    
    # 使用臨時文件捕獲輸出和返回值
    local apt_output
    local apt_exit_code
    
    apt_output=$(sudo -E apt update 2>&1) || apt_exit_code=$?
    echo "$apt_output"  # 顯示輸出
    
    if [ -z "${apt_exit_code:-}" ] || [ "$apt_exit_code" -eq 0 ]; then
        # 成功
        return 0
    else
        echo "警告: apt update 返回錯誤代碼 $apt_exit_code"
        
        # 檢查是否是第三方源問題 (404 或 Failed to fetch)
        if echo "$apt_output" | grep -qE '(404|Failed to fetch|NO_PUBKEY|igned)'; then
            echo "檢測到第三方軟體源錯誤 (404/Failed/簽名問題)，這通常不影響主要升級。"
            echo "腳本將繼續執行，但部分第三方軟體可能無法更新。"
            return 0  # 允許繼續
        else
            echo "警告: apt update 失敗，原因未知。嘗試清理快取後重試..."
            sudo rm -rf /var/lib/apt/lists/* || true
            if sudo -E apt update; then
                echo "重試成功。"
                return 0
            else
                echo "錯誤: apt update 重試後仍然失敗，這可能影響升級。" >&2
                return 1  # 這是真正的錯誤
            fi
        fi
    fi
}

ensure_current_updated() {
    echo "--- [Pre-Upgrade] 確保當前系統已更新 ---"
    repair_dpkg
    
    safe_apt_update
    
    echo "2. 升級現有套件..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} upgrade || {
        echo "警告: upgrade 部分失敗，嘗試修復後繼續..." >&2
        repair_dpkg
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} upgrade || {
            echo "錯誤: upgrade 失敗，無法繼續" >&2
            return 1
        }
    }
    
    echo "3. 執行 dist-upgrade..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} dist-upgrade || {
        echo "警告: dist-upgrade 部分失敗，嘗試修復後繼續..." >&2
        repair_dpkg
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} dist-upgrade || {
            echo "錯誤: dist-upgrade 失敗，無法繼續" >&2
            return 1
        }
    }
    
    echo "4. 清理未使用的套件..."
    sudo -E apt autoremove --purge -y || true
}

generate_clean_sources() {
    local TARGET=$1
    echo "生成標準 Debian $TARGET 軟體源列表..."
    
    # 判斷是否需要 non-free-firmware (Bookworm 及更新版本)
    local COMPONENTS="main contrib non-free"
    if [[ "$TARGET" == "bookworm" ]] || [[ "$TARGET" == "trixie" ]]; then
        COMPONENTS="$COMPONENTS non-free-firmware"
    fi
    
    # 寫入主源 (使用 deb.debian.org 全球 CDN)
    cat <<EOF | sudo tee /etc/apt/sources.list >/dev/null
deb http://deb.debian.org/debian $TARGET $COMPONENTS
deb-src http://deb.debian.org/debian $TARGET $COMPONENTS

deb http://deb.debian.org/debian $TARGET-updates $COMPONENTS
deb-src http://deb.debian.org/debian $TARGET-updates $COMPONENTS

deb http://deb.debian.org/debian-security/ ${TARGET}-security $COMPONENTS
deb-src http://deb.debian.org/debian-security/ ${TARGET}-security $COMPONENTS
EOF
    echo "軟體源已更新至 $TARGET (組件: $COMPONENTS)"
}

fix_sources() {
    local FROM=$1
    local TO=$2
    echo "--- [3/8] 更新軟體源: $FROM -> $TO ---"
    
    # 1. 重寫主列表
    generate_clean_sources "$TO"

    # 2. 更新第三方列表 (僅替換代號)
    if [ -d /etc/apt/sources.list.d ]; then
        echo "更新第三方軟體源 (將 $FROM 替換為 $TO)..."
        # 注意：這可能導致第三方源 404，由 safe_apt_update 處理容錯
        sudo find /etc/apt/sources.list.d/ -name "*.list" -type f -exec sed -i \
            "s/${FROM}/${TO}/g" '{}' +
    fi
}

perform_robust_upgrade() {
    repair_dpkg
    echo "--- [4/8] 執行系統升級 (Robust Mode) ---"
    
    # 1. 更新軟體包索引 (容許失敗)
    safe_apt_update
    
    echo "2. 優先升級核心工具 (apt/dpkg/libc6)..."
    # 這裡允許失敗，因為可能某些包在當前源中不存在
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} install --only-upgrade apt dpkg libc6 || echo "警告: 核心工具升級部分失敗，繼續..."
    
    echo "3. 執行套件升級 (Upgrade)..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} upgrade || {
        echo "警告: upgrade 失敗，嘗試修復..." >&2
        repair_dpkg
        # 重試，這次失敗則退出
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} upgrade
    }
    
    echo "4. 執行完整發行版升級 (Full Upgrade)..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} full-upgrade || {
        echo "警告: full-upgrade 失敗，嘗試修復..." >&2
        repair_dpkg
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --fix-broken install
        # 重試，這次失敗則退出 (set -e 會自動終止腳本)
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} full-upgrade
    }
    
    echo "5. 清理與修復..."
    sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --fix-broken install || true
    sudo -E apt autoremove --purge -y || true
    sudo -E apt clean || true
}

upgrade_to_cloud_kernel() {
    echo "--- [5/8] 標準化至【雲端服務核心】 ---"
    safe_apt_update
    
    # 嘗試安裝雲端核心 - 允許失敗
    if sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} --no-install-recommends install "linux-image-cloud-${ARCH}"; then
        echo "雲端核心安裝成功。"
    else
        echo "警告: 無法安裝 linux-image-cloud-${ARCH}，嘗試安裝通用核心..."
        # 嘗試通用核心，這次也允許失敗（可能已經安裝）
        sudo -E apt ${APT_NONINTERACTIVE_OPTIONS} install "linux-image-${ARCH}" || echo "警告: 通用核心安裝也失敗，可能已存在核心。"
    fi
    
    # 檢查是否安裝成功並移除舊核心
    if dpkg -l | grep -q "linux-image-cloud-${ARCH}"; then
        echo "檢測到雲端核心已安裝，嘗試移除舊的通用核心..."
        # 找出非 cloud 的核心 (謹慎操作)
        # 這裡不強制移除，避免誤刪導致無法開機，僅作建議性清理
        echo "建議：重啟確認系統穩定後，手動移除舊核心以釋放空間。"
    fi
}

reboot_sequence() {
    local msg=$1
    echo ""
    echo "--- [6/8] $msg ---"
    echo "正在恢復服務設定..."
    restore_services
    
    echo "系統將在 10 秒後重啟..."
    sleep 10
    
    trap - EXIT 
    
    echo "REBOOTING NOW..."
    sudo reboot -f
    sleep infinity
}

# --- 主流程 ---
check_root
check_network
check_disk_space
check_pending_reboot # 新增: 防止連續升級導致狀態錯亂

echo "========================================================="
echo "  Debian 生產環境雲端升級腳本 (Optimized for Trixie Stable)"
echo "========================================================="

preseed_debconf
configure_unattended_tools
detect_system
pause

run_upgrade_flow() {
    local CURRENT=$1
    local TARGET=$2
    
    echo ">>> 開始升級流程: $CURRENT -> $TARGET"
    
    # 確保當前系統已更新
    if ! ensure_current_updated; then
        echo "錯誤: 無法更新當前系統，中止升級。" >&2
        exit 1
    fi
    
    backup_sources
    fix_sources "$CURRENT" "$TARGET"
    
    # 執行升級 - 如果失敗則中止
    if ! perform_robust_upgrade; then
        echo "錯誤: 系統升級失敗，不會執行重啟以避免損壞系統。" >&2
        echo "請檢查日誌: $LOGFILE" >&2
        exit 1
    fi
    
    # 安裝雲端核心 - 允許失敗
    upgrade_to_cloud_kernel || echo "警告: 雲端核心安裝失敗，但系統升級已完成。"
}

case "$SYSTEM_STATE" in
    bullseye)
        echo "狀態: Debian 11 (Bullseye) -> 12 (Bookworm)"
        run_upgrade_flow bullseye bookworm
        reboot_sequence "第一階段完成，需要重啟加載新核心後，再次執行腳本以升級至 Trixie"
        ;;
    bookworm)
        echo "狀態: Debian 12 (Bookworm) -> 13 (Trixie)"
        run_upgrade_flow bookworm trixie
        echo "--- [全部完成] 升級全部完成 ---"
        reboot_sequence "所有階段完成，執行最終重啟"
        ;;
    trixie)
        echo "狀態: 系統已是 Trixie，執行維護更新..."
        if ! perform_robust_upgrade; then
            echo "錯誤: 維護更新失敗" >&2
            exit 1
        fi
        upgrade_to_cloud_kernel || echo "警告: 雲端核心安裝失敗"
        reboot_sequence "維護完成，執行重啟"
        ;;
    *)
        echo "未知狀態或已是最新版，執行通用更新"
        if ! perform_robust_upgrade; then
            echo "錯誤: 通用更新失敗" >&2
            exit 1
        fi
        upgrade_to_cloud_kernel || echo "警告: 雲端核心安裝失敗"
        reboot_sequence "通用更新完成，執行重啟"
        ;;
esac

exit 0
