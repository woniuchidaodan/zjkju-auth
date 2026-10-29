include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-zjkju-auth
PKG_VERSION:=1.0.5
PKG_RELEASE:=1

LUCI_TITLE:=LuCI app for ZJKJU Ruijie ePortal authentication
LUCI_DESCRIPTION:=A LuCI application that keeps ZJKJU campus network logged in via Ruijie ePortal web authentication.
LUCI_DEPENDS:=+luci-base +luci-compat +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-zjkju-auth/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0

[ -f /etc/config/zjkju-auth ] || cat > /etc/config/zjkju-auth <<EOF
config zjkju-auth 'main'
	option enabled '0'
	option username ''
	option password ''
	option service '%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91'
	option check_interval '10'
	option manual_url ''
	option beta_channel '0'
EOF
chmod 600 /etc/config/zjkju-auth

# 平滑升级：确保已有配置自动补全 beta_channel 字段
if ! uci -q get zjkju-auth.main.beta_channel >/dev/null 2>&1; then
    uci set zjkju-auth.main.beta_channel='0'
    uci commit zjkju-auth
fi

rm -rf /var/log/zjkju-auth
rm -f /var/log/zjkju-auth.log
rm -f /tmp/zjkju-auth-status
rm -f /tmp/zjkju-auth-last-url
rm -f /tmp/zjkju-auth-online-printed
rm -f /tmp/zjkju_do_update.sh
rm -f /tmp/zjkju_auth_update.*
rm -f /tmp/zjkju_update_status
mkdir -p /var/log/zjkju-auth

# 版本号缓存：避免 LuCI 每 5 秒轮询 /status 时都去跑一次 opkg
if command -v opkg >/dev/null 2>&1; then
    opkg status luci-app-zjkju-auth 2>/dev/null | grep '^Version:' | awk '{print $2}' > /tmp/zjkju-auth-version
elif command -v apk >/dev/null 2>&1; then
    apk info -v luci-app-zjkju-auth 2>/dev/null | head -n1 | cut -d'-' -f2- > /tmp/zjkju-auth-version
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null

if [ -f /etc/init.d/zjkju-auth ]; then
    /etc/init.d/zjkju-auth restart >/dev/null 2>&1 || true
fi

exit 0
endef

define Package/luci-app-zjkju-auth/postrm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0

# 只在"真正卸载"时清理；升级（$$1 = upgrade）时保留配置，什么都不做
case "$$1" in
	remove) ;;
	*) exit 0 ;;
esac

# ========== 1. 停服务、清进程 ==========
/etc/init.d/zjkju-auth stop >/dev/null 2>&1
/etc/init.d/zjkju-auth disable >/dev/null 2>&1
killall -9 zjkju-auth-wrapper.sh 2>/dev/null
killall -9 ruijie 2>/dev/null
sleep 1

# 兜底：遍历强杀残留进程
for p in $$(ps w 2>/dev/null | grep -E '[z]jkju-auth-wrapper|[r]uijie' | awk '{print $$1}'); do
	kill -9 "$$p" 2>/dev/null
done

# ========== 2. 配置、启动项与可执行文件 ==========
# 这些本来就由包管理器删除，这里再兜底一次，
# 防止包数据库损坏或旧版本残留导致删不干净
rm -f /etc/config/zjkju-auth
rm -f /etc/init.d/zjkju-auth
rm -f /etc/uci-defaults/80_zjkju-auth
rm -f /usr/bin/zjkju-auth-wrapper.sh
rm -f /usr/bin/ruijie

# ========== 2b. 运行数据 ==========
rm -rf /var/log/zjkju-auth
rm -f /var/log/zjkju-auth.log

# ========== 3. /tmp 残留（覆盖 v1.0.0 ~ r11 各版本）==========
rm -f /tmp/zjkju-auth-status
rm -f /tmp/zjkju-auth-last-url
rm -f /tmp/zjkju-auth-online-printed
rm -f /tmp/zjkju-auth-out.log
rm -f /tmp/zjkju_do_update.sh
rm -f /tmp/zjkju_auth_update.*
rm -f /tmp/zjkju_update_status
rm -f /tmp/zjkju-auth-version
rm -f /tmp/luci-app-zjkju-auth_*.ipk
rm -f /tmp/luci-app-zjkju-auth_*.apk

# ========== 4. 旧版本遗留的界面文件（升级路径可能留下）==========
rm -rf /usr/lib/lua/luci/model/cbi/zjkju-auth
rm -rf /usr/lib/lua/luci/view/zjkju-auth
rm -f  /usr/lib/lua/luci/controller/zjkju-auth.lua
rm -f  /usr/share/luci/menu.d/luci-app-zjkju-auth.json
rm -f  /usr/share/rpcd/acl.d/luci-app-zjkju-auth.json
# r10 的实验界面（JS 视图）
rm -rf /www/luci-static/resources/view/zjkju-auth

# ========== 5. LuCI 缓存与包管理器记录 ==========
rm -rf /usr/lib/opkg/info/luci-app-zjkju-auth.*
rm -f  /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/

# ========== 6. 重载前端服务，菜单立即消失 ==========
/etc/init.d/rpcd reload 2>/dev/null
/etc/init.d/uhttpd reload 2>/dev/null

exit 0
endef

define Package/luci-app-zjkju-auth/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/zjkju-auth-wrapper.sh $(1)/usr/bin/zjkju-auth-wrapper.sh
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/zjkju-auth $(1)/etc/config/zjkju-auth
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/zjkju-auth $(1)/etc/init.d/zjkju-auth
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/80_zjkju-auth $(1)/etc/uci-defaults/80_zjkju-auth
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-zjkju-auth.json $(1)/usr/share/luci/menu.d/luci-app-zjkju-auth.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-zjkju-auth.json $(1)/usr/share/rpcd/acl.d/luci-app-zjkju-auth.json
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/zjkju-auth.lua $(1)/usr/lib/lua/luci/controller/zjkju-auth.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/zjkju-auth
	$(INSTALL_DATA) ./luasrc/model/cbi/zjkju-auth/main.lua $(1)/usr/lib/lua/luci/model/cbi/zjkju-auth/main.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/zjkju-auth
	$(INSTALL_DATA) ./luasrc/view/zjkju-auth/log.htm $(1)/usr/lib/lua/luci/view/zjkju-auth/log.htm
	$(INSTALL_DATA) ./luasrc/view/zjkju-auth/update.htm $(1)/usr/lib/lua/luci/view/zjkju-auth/update.htm
endef

define Package/luci-app-zjkju-auth/conffiles
/etc/config/zjkju-auth
endef

$(eval $(call BuildPackage,luci-app-zjkju-auth))
