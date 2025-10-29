#!/bin/bash
# =========================================================
# Debian 11 → 12 → 13 自動升級腳本
# 適用於：Debian 11 (Bullseye) 到 Debian 13 (Trixie)
# =========================================================

set -e

# --- 函數定義 ---
pause() {
    echo ""
    read -rp ">>> 按 Enter 鍵繼續..."
}

check_version() {
    echo "目前系統版本："
    lsb_release -a || cat /etc/debian_version
    echo ""
}

backup_sources() {
    echo "備份 sources.list ..."
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S)
}

# ... (update_system 函數可以保留，雖然主流程沒用到) ...

upgrade_to_bookworm() {
    echo ""
    echo "==== 開始升級 Debian 11 → 12 (Bookworm) ===="
    backup_sources
    sudo sed -i 's/bullseye/bookworm/g' /etc/apt/sources.list
    sudo apt update
    sudo apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    echo ""
    echo "✅ 第一階段升級完成！"
    echo "🚨 系統需要重啟以加載 Debian 12 的新內核。"
    echo "   請手動執行 'sudo reboot' 來重啟。"
    echo "   重啟並重新登錄後，請再次運行同一個腳本以繼續升級到 Debian 13。"
}

upgrade_to_trixie() {
    echo ""
    echo "==== 開始升級 Debian 12 → 13 (Trixie) ===="
    backup_sources
    sudo sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
    sudo apt update
    sudo apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade -y
    sudo apt --fix-broken install -y
    sudo apt autoremove --purge -y
    echo ""
    echo "✅ 第二階段升級完成！"
    echo "🚨 系統需要重啟以完成 Debian 13 的升級。"
    echo "   請手動執行 'sudo reboot' 來重啟。"
    echo "   重啟後，您可以選擇再次運行腳本進行最終檢查。"
}

final_check() {
    echo ""
    echo "==== 驗證系統版本 ===="
    lsb_release -a || cat /etc/debian_version
    uname -a
    echo ""
    echo "==== 系統清理 ===="
    sudo apt clean
    sudo apt autoremove -y
    echo ""
    echo "✅ 您的系統已是 Debian 13，升級已完成！"
}

# --- 主流程 ---
echo "========================================================="
echo "  Debian 狀態感知升級腳本：11 → 12 → 13"
echo "========================================================="

# 獲取版本信息，如果命令失敗則退出
if ! source /etc/os-release; then
    echo "錯誤：無法讀取 /etc/os-release 文件來確定系統版本。"
    exit 1
fi

check_version
pause

case "$VERSION_CODENAME" in
  bullseye)
    echo "檢測到 Debian 11 (Bullseye)。準備升級至 Debian 12。"
    upgrade_to_bookworm
    ;;
  bookworm)
    echo "檢測到 Debian 12 (Bookworm)。準備升級至 Debian 13。"
    upgrade_to_trixie
    ;;
  trixie)
    echo "檢測到系統已是 Debian 13 (Trixie)。"
    final_check
    ;;
  *)
    echo "錯誤：不支持的版本 ($VERSION_CODENAME)。腳本終止。"
    exit 1
    ;;
esac

exit 0
