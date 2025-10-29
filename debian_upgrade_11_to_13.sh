#!/bin/bash
# =================================================================
# Debian 11 → 12 → 13 全自動無人值守升級腳本
# =================================================================

# --- 腳本執行設定 ---
# set -e: 當任何命令以非零狀態碼退出時，立即終止腳本。這是確保腳本健壯性的關鍵。
set -e

# --- 日誌設定 ---
# 將所有標準輸出(stdout)和標準錯誤(stderr)重定向到一個帶有時間戳的日誌文件。
# > >(sudo tee -a "$LOGFILE"): 使用`tee`命令，讓輸出同時顯示在終端機並附加到日誌文件。
# `sudo`確保即使腳本以普通用戶運行，也能寫入/var/log目錄。
LOGFILE="/var/log/debian_upgrade_$(date +%Y%m%d_%H%M%S).log"
exec > >(sudo tee -a "$LOGFILE") 2>&1

# --- 全域常數 ---
# 定義非互動式 apt 命令的統一選項，以避免在升級過程中出現任何需要使用者輸入的提示。
# -o Dpkg::Options::="--force-confold": 當設定檔被修改過時，保留本地（舊的）版本。
# -o Dpkg::Options::="--force-confdef": 當設定檔未被修改時，使用新套件提供的預設版本。
APT_NONINTERACTIVE_OPTIONS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
# 動態獲取系統架構，增強腳本通用性
ARCH=$(dpkg --print-architecture)

# --- 函數定義 ---

# 暫停函數，給予使用者最後一次中止操作的機會。
pause() {
    echo ""
    # -p: 顯示提示字串。
    # -t 5: 等待5秒。
    # <> /dev/tty: 確保即使在 stdout/stdin 被重定向的情況下，依然能從終端機讀取輸入。
    # || true: 如果 read 命令因超時而失敗，不會觸發 `set -e` 導致腳本退出。
    read -rp ">>> 這是一個全自動腳本，將在5秒後繼續，按 Ctrl+C 中止..." -t 5 <> /dev/tty || true
}

# 檢測當前系統狀態（發行版、內核版本）。
detect_system() {
    echo "--- 檢測系統狀態 ---"
    if [ ! -f /etc/os-release ]; then
        echo "錯誤：無法讀取 /etc/os-release，無法確定系統版本。" >&2
        exit 1
    fi
    # 使用 `.` 命令（source 的同義詞）將 /etc/os-release 中的變數載入到當前 shell 環境。
    . /etc/os-release
    # 將檢測到的發行版代號（codename）匯出為環境變數，供後續函數使用。
    export USERLAND_CODENAME="${VERSION_CODENAME:-unknown}"
    echo "使用者空間 (Userland) 版本: $PRETTY_NAME"

    KERNEL_VERSION=$(uname -r)
    echo "正在運行的核心版本: $KERNEL_VERSION"

    # 根據核心主版本號推斷其對應的 Debian 發行版。
    # 這有助於判斷升級後是否已成功引導至新核心。
    case "${KERNEL_VERSION%%.*}" in
        5) KERNEL_CODENAME="bullseye" ;;
        6)
            # Debian 12 (bookworm) 和 13 (trixie) 都使用 6.x 核心，需用次版本號區分。
            if dpkg --compare-versions "$KERNEL_VERSION" "lt" "6.2"; then
                KERNEL_CODENAME="bookworm"
            else
                KERNEL_CODENAME="trixie"
            fi
            ;;
        *) KERNEL_CODENAME="unknown" ;;
    esac
    echo "核心推斷發行版: $KERNEL_CODENAME"

    # 比較使用者空間和核心版本，判斷系統狀態是否一致。
    if [[ "$USERLAND_CODENAME" == "$KERNEL_CODENAME" ]]; then
        export SYSTEM_STATE="$USERLAND_CODENAME"
        echo "狀態診斷: 核心與使用者空間匹配 ($SYSTEM_STATE)"
    else
        export SYSTEM_STATE="MISMATCHED_KERNEL"
        echo "警告: 核心與使用者空間版本不匹配！(使用者空間: $USERLAND_CODENAME / 核心: $KERNEL_CODENAME)"
    fi
    echo "---------------------------"
}

# 備份 APT 套件來源清單。
backup_sources() {
    echo "備份 APT 來源..."
    local backup_timestamp
    backup_timestamp=$(date +%F_%T)
    sudo cp -a /etc/apt/sources.list "/etc/apt/sources.list.backup.${backup_timestamp}"
    # 檢查 sources.list.d 目錄是否存在，存在才進行備份。
    [ -d /etc/apt/sources.list.d ] && \
        sudo cp -a /etc/apt/sources.list.d "/etc/apt/sources.list.d.backup.${backup_timestamp}"
}

# 修改 APT 來源，將舊的發行版代號替換為新的。
fix_sources() {
    local FROM=$1
    local TO=$2
    echo "更新來源: $FROM -> $TO"
    # 使用 find 搜尋所有 .list 文件，並用 sed 進行原地替換。
    # 這樣可以處理主 sources.list 文件以及 sources.list.d 目錄下的所有文件。
    # 優化：將多個 -e 參數合併為一個，用分號分隔。
    sudo find /etc/apt/ -name "*.list" -type f -exec sed -i \
        "s/${FROM}-security/${TO}-security/g; s/${FROM}-updates/${TO}-updates/g; s/${FROM}-backports/${TO}-backports/g; s/${FROM}/${TO}/g" '{}' +
}

# --- 核心強化部分 ---

# 修復可能存在的 dpkg 問題，確保升級環境乾淨。
repair_dpkg() {
    # 強制設定為非互動模式，避免任何 dpkg 設定提示。
    export DEBIAN_FRONTEND=noninteractive
    
    # 檢查並移除 dpkg 鎖文件，處理 apt 意外中斷的情況。
    if sudo lsof /var/lib/dpkg/lock >/dev/null 2>&1 || sudo lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo "警告：檢測到 dpkg 鎖文件，正在強制移除..."
        # 使用 fuser 嘗試優雅地終止佔用鎖的進程。
        sudo fuser -k /var/lib/dpkg/lock || true
        sudo fuser -k /var/lib/dpkg/lock-frontend || true
        sudo rm -f /var/lib/dpkg/lock*
    fi

    # 檢查 dpkg 是否有未完成的設定，並嘗試自動修復。
    if ! sudo dpkg --audit >/dev/null 2>&1; then
        echo "警告：檢測到 dpkg 存在未完成的設定，正在嘗試自動修復..."
        sudo dpkg --configure -a
        sudo apt ${APT_NONINTERACTIVE_OPTIONS} -y -f install
        echo "dpkg 修復完成。"
    else
        echo "dpkg 狀態檢查通過。"
    fi
}

# 執行主要的升級步驟。
perform_upgrade() {
    # 再次確保非互動模式，並執行 dpkg 修復檢查。
    export DEBIAN_FRONTEND=noninteractive
    repair_dpkg
    
    echo "開始更新套件列表..."
    sudo apt update
    
    echo "開始全系統升級 (將自動保留本地修改過的設定檔)..."
    # full-upgrade (或 dist-upgrade) 會處理套件依賴關係的變更，可能會安裝或移除套件，是發行版升級所必需的。
    sudo apt ${APT_NONINTERACTIVE_OPTIONS} -y full-upgrade
    
    echo "執行最終清理..."
    # 再次修復可能損壞的依賴關係。
    sudo apt ${APT_NONINTERACTIVE_OPTIONS} -y --fix-broken install
    # 自動移除不再需要的套件，並清除其設定檔。
    sudo apt autoremove --purge -y
    # 清除本地下載的套件包快取。
    sudo apt clean
}

# 為新的使用者空間版本安裝推薦的最新核心。
install_latest_kernel() {
    export DEBIAN_FRONTEND=noninteractive
    echo "正在為 $USERLAND_CODENAME 安裝最新推薦核心 (架構: ${ARCH})..."
    sudo apt update
    # linux-image-amd64 是一個元數據包(metapackage)，它會依賴於當前最新的穩定核心。
    # 使用動態架構變數 ${ARCH} 增強通用性。
    # 增加 linux-image-cloud-${ARCH} 是為了更好地兼容雲端環境。
    # `|| echo ...` 結構允許在其中一個包安裝失敗時（例如，非雲環境沒有 cloud 核心），腳本不會因 `set -e` 而中止。
    sudo apt ${APT_NONINTERACTIVE_OPTIONS} install -y "linux-image-${ARCH}" "linux-image-cloud-${ARCH}" || \
        echo "一個或多個核心元數據包安裝失敗，這可能是正常的（例如在非雲環境下）。"
}

# 最終檢查並自動重啟。
final_check_and_auto_reboot() {
    echo ""
    echo "==== 驗證最終系統狀態 ===="
    detect_system
    echo ""
    echo "✅ 升級流程已全部完成！日誌文件位於: $LOGFILE"
    echo "系統將在 10 秒後自動重啟以應用所有變更..."
    sleep 10
    echo "正在重啟..."
    sudo reboot
}

# --- 主流程 ---
echo "========================================================="
echo "  Debian 全自動無人值守升級腳本"
echo "========================================================="
echo "日誌將被記錄到: $LOGFILE"

# 升級前，強烈建議禁用 unattended-upgrades，以防其在升級過程中干擾 apt。
echo "正在暫時禁用自動更新服務，以防干擾..."
# `|| true` 確保即使服務不存在或已停止，腳本也不會失敗。
sudo systemctl stop unattended-upgrades.service || true
sudo systemctl disable unattended-upgrades.service || true
# 強化建議：此處應加入邏輯在腳本結束時重新啟用此服務。

detect_system
pause # 給予使用者最後一次中止的機會

# 根據檢測到的系統狀態，執行相應的升級流程。
case "$SYSTEM_STATE" in
    bullseye)
        echo "檢測到 Debian 11 (bullseye)，開始升級至 Debian 12 (bookworm)..."
        backup_sources
        fix_sources bullseye bookworm
        perform_upgrade
        echo ""
        echo "✅ 第一階段完成！"
        echo "🚨 正在自動重啟以應用 Debian 12 核心。請在重啟後，再次運行此腳本以繼續升級到 Debian 13。"
        sleep 5
        sudo reboot
        ;;
    bookworm)
        echo "檢測到 Debian 12 (bookworm)，開始升級至 Debian 13 (trixie)..."
        backup_sources
        fix_sources bookworm trixie
        perform_upgrade
        install_latest_kernel
        echo "✅ 第二階段完成！"
        final_check_and_auto_reboot
        ;;
    trixie)
        echo "檢測到 Debian 13 (trixie)，系統已是最新。執行最終檢查。"
        # 即使已是最新，也可能需要修復或清理。
        perform_upgrade
        final_check_and_auto_reboot
        ;;
    MISMATCHED_KERNEL)
        echo "檢測到核心與使用者空間版本不匹配，通常發生在升級後但未重啟的情況。"
        echo "將嘗試為當前的使用者空間 ($USERLAND_CODENAME) 安裝/更新核心並重啟..."
        install_latest_kernel
        echo "✅ 核心修復嘗試完成。"
        final_check_and_auto_reboot
        ;;
    *)
        echo "錯誤：未知的系統狀態 ($SYSTEM_STATE)，腳本終止。" >&2
        exit 1
        ;;
esac

exit 0
