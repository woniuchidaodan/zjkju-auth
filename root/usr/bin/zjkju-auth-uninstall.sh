#!/bin/sh
# ZJKJU 校园网认证 - 深度一键卸载
# 适配版本: v1.0.0 ~ 1.0.5
# 用法: /usr/bin/zjkju-auth-uninstall.sh

# ---------- 把自己复制到 /tmp 再执行 ----------
# 原因：下面会调用 opkg remove，卸载过程会删掉本脚本所在文件。
# busybox 的 sh 是逐行读脚本的，边跑边被删会中断，所以先复制一份。
if [ "$ZJKJU_UNINSTALL_SELF" != "1" ]; then
    cp "$0" /tmp/zjkju-uninstall-run.sh 2>/dev/null
    if [ -f /tmp/zjkju-uninstall-run.sh ]; then
        ZJKJU_UNINSTALL_SELF=1 exec sh /tmp/zjkju-uninstall-run.sh
    fi
fi
trap 'rm -f /tmp/zjkju-uninstall-run.sh' EXIT

say()  { echo "$@"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }

say "================================================"
say "  ZJKJU 校园网认证 - 深度一键卸载"
say "  适配版本: v1.0.0 ~ 1.0.5"
say "================================================"
say ""

# ========== 1/7 停止服务并清理进程 ==========
say "[1/7] 停止服务并清理进程..."
/etc/init.d/zjkju-auth stop >/dev/null 2>&1
/etc/init.d/zjkju-auth disable >/dev/null 2>&1
killall -9 zjkju-auth-wrapper.sh 2>/dev/null
killall -9 ruijie 2>/dev/null
sleep 1

# 兜底：遍历强杀残留
for PID in $(ps w 2>/dev/null | grep -E '[z]jkju-auth-wrapper|[r]uijie' | awk '{print $1}'); do
    kill -9 "$PID" 2>/dev/null
done
ok "服务已停止，进程已清理"

# ========== 2/7 卸载软件包 ==========
say "[2/7] 卸载软件包..."
if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -q '^luci-app-zjkju-auth '; then
    opkg remove --force-depends luci-app-zjkju-auth >/dev/null 2>&1
    ok "opkg 已卸载（postrm 自动清理已执行）"
elif command -v apk >/dev/null 2>&1 && apk info 2>/dev/null | grep -q 'luci-app-zjkju-auth'; then
    apk del luci-app-zjkju-auth >/dev/null 2>&1
    ok "apk 已卸载（postrm 自动清理已执行）"
else
    warn "包管理器里没有记录，直接清理残留文件"
fi

# ========== 3/7 删除配置和启动脚本 ==========
say "[3/7] 删除配置和系统脚本..."
rm -f /etc/config/zjkju-auth
rm -f /etc/init.d/zjkju-auth
rm -f /etc/uci-defaults/80_zjkju-auth
ok "已删除 /etc/ 下的配置与启动项"

# ========== 4/7 删除可执行文件和核心脚本 ==========
say "[4/7] 删除可执行文件..."
rm -f /usr/bin/zjkju-auth-wrapper.sh
rm -f /usr/bin/ruijie
rm -f /usr/bin/zjkju-auth-uninstall.sh
ok "已删除 /usr/bin/ 下的核心脚本"

# ========== 5/7 删除 LuCI 界面及依赖文件 ==========
say "[5/7] 删除 LuCI 界面文件..."
rm -f  /usr/share/luci/menu.d/luci-app-zjkju-auth.json
rm -f  /usr/share/rpcd/acl.d/luci-app-zjkju-auth.json
rm -f  /usr/lib/lua/luci/controller/zjkju-auth.lua
rm -rf /usr/lib/lua/luci/model/cbi/zjkju-auth
rm -rf /usr/lib/lua/luci/view/zjkju-auth
# 1.0.4-r10 时期的实验界面（JS 视图）
rm -rf /www/luci-static/resources/view/zjkju-auth
ok "已清理菜单、ACL、控制器与视图文件"

# ========== 6/7 清理历史运行残留 ==========
say "[6/7] 清理历史运行残留 (v1.0.0 ~ 1.0.5)..."
# 1.0.1 时代的单文件日志
rm -f /var/log/zjkju-auth.log
# 1.0.3+ 时代的统一目录
rm -rf /var/log/zjkju-auth
# 旧版散落的 /tmp 状态文件
rm -f /tmp/zjkju-auth-status
rm -f /tmp/zjkju-auth-last-url
rm -f /tmp/zjkju-auth-online-printed
rm -f /tmp/zjkju-auth-out.log
# 1.0.5 的版本号缓存
rm -f /tmp/zjkju-auth-version
# 1.0.4 后台更新脚本、下载与进度残留
rm -f /tmp/zjkju_do_update.sh
rm -f /tmp/zjkju_auth_update.*
rm -f /tmp/zjkju_update_status
# 本地安装包残留
rm -f /tmp/luci-app-zjkju-auth_*.ipk
rm -f /tmp/luci-app-zjkju-auth_*.apk
ok "已彻底清空日志、缓存与运行时目录"

# ========== 7/7 清理包管理器记录及系统缓存 ==========
say "[7/7] 清理包管理器记录与 LuCI 缓存..."
rm -rf /usr/lib/opkg/info/luci-app-zjkju-auth.*
rm -f  /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
ok "包管理器残留与网页缓存已清理"

# ========== 重载前端 ==========
say ""
say "正在重载 rpcd 和 uhttpd 服务..."
/etc/init.d/rpcd reload 2>/dev/null
/etc/init.d/uhttpd reload 2>/dev/null
sleep 1

# ========== 验证 ==========
say ""
say "================================================"
say "  验证清理结果"
say "================================================"

check() {
    if [ -e "$1" ]; then
        echo "  ❌ $1 仍存在！"
    else
        echo "  ✅ $1 已彻底删除"
    fi
}

check /etc/config/zjkju-auth
check /etc/init.d/zjkju-auth
check /etc/uci-defaults/80_zjkju-auth
check /usr/bin/zjkju-auth-wrapper.sh
check /usr/bin/ruijie
check /usr/share/luci/menu.d/luci-app-zjkju-auth.json
check /usr/share/rpcd/acl.d/luci-app-zjkju-auth.json
check /usr/lib/lua/luci/controller/zjkju-auth.lua
check /usr/lib/lua/luci/model/cbi/zjkju-auth
check /usr/lib/lua/luci/view/zjkju-auth
check /www/luci-static/resources/view/zjkju-auth
check /var/log/zjkju-auth
check /tmp/zjkju-auth-status
check /tmp/zjkju-auth-version
check /tmp/zjkju_do_update.sh

if ps w 2>/dev/null | grep -qE '[z]jkju-auth-wrapper|[r]uijie'; then
    echo "  ❌ 仍有进程在运行"
else
    echo "  ✅ 无残留进程在运行"
fi

PKG_INSTALLED=0
if command -v opkg >/dev/null 2>&1 && opkg list-installed 2>/dev/null | grep -q '^luci-app-zjkju-auth '; then
    PKG_INSTALLED=1
fi
if command -v apk >/dev/null 2>&1 && apk info 2>/dev/null | grep -q 'luci-app-zjkju-auth'; then
    PKG_INSTALLED=1
fi

if [ "$PKG_INSTALLED" = "1" ]; then
    echo "  ❌ 包管理器数据库仍有记录"
else
    echo "  ✅ 包管理器数据库已清"
fi

say ""
say "================================================"
say "  卸载完成！"
say "================================================"
say ""
say "⚠️ 最后一步建议（极其重要）："
say "  1. 浏览器按 Ctrl+Shift+R 强制刷新网页"
say "  2. 退出 LuCI 后台重新登录"
say "  3. 确认左侧菜单栏中的「ZJKJU 校园网认证」已彻底消失"
say ""
