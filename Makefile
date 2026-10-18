include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-zjkju-auth
PKG_VERSION:=1.0.3
PKG_RELEASE:=1

LUCI_TITLE:=LuCI app for ZJKJU Ruijie ePortal authentication
LUCI_DESCRIPTION:=A LuCI application that keeps ZJKJU campus network logged in via Ruijie ePortal web authentication.
LUCI_DEPENDS:=+luci-base +luci-compat +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-zjkju-auth/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0

# B1: 仅在配置文件不存在时写入（避免升级时抹掉用户的学号/密码）
[ -f /etc/config/zjkju-auth ] || cat > /etc/config/zjkju-auth <<EOF
config zjkju-auth 'main'
	option enabled '0'
	option username ''
	option password ''
	option service '%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91'
	option check_interval '10'
	option manual_url ''
EOF

# B3: 强制权限为 600，保护密码安全
# libuci 写盘时会先 chmod 成原文件权限再 rename，所以这个 600 会一直保持
chmod 600 /etc/config/zjkju-auth

# 清理 1.0.2 遗留在旧路径的文件（新版目录保留，避免丢掉日志）
rm -f /var/log/zjkju-auth.log
rm -f /tmp/zjkju-auth-status
rm -f /tmp/zjkju-auth-last-url
rm -f /tmp/zjkju-auth-online-printed
mkdir -p /var/log/zjkju-auth

# B2: 补回 luci.mk 默认 postinst 的缓存清理逻辑
# （自定义 postinst 会顶掉 luci.mk 里 ifndef 包裹的默认实现）
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null

# 重启服务（enabled=0 时 start_service 会自行跳过）
if [ -f /etc/init.d/zjkju-auth ]; then
    /etc/init.d/zjkju-auth restart >/dev/null 2>&1 || true
fi

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
endef

$(eval $(call BuildPackage,luci-app-zjkju-auth))
