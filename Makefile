include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-zjkju-auth
PKG_VERSION:=1.0.4
PKG_RELEASE:=10

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

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null

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
	$(INSTALL_DATA) ./luasrc/view/zjkju-auth/update.htm $(1)/usr/lib/lua/luci/view/zjkju-auth/update.htm
endef

define Package/luci-app-zjkju-auth/conffiles
/etc/config/zjkju-auth
endef

$(eval $(call BuildPackage,luci-app-zjkju-auth))
