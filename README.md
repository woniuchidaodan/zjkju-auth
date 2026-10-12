# LuCI App - 湛江科技学院锐捷校园网自动认证 (luci-app-zjkju-auth)

一个用于 ImmortalWrt / OpenWrt 的 LuCI 应用，在后台自动完成湛江科技学院锐捷 ePortal Web 认证，支持断线自动重连、开机自启、Web 界面配置。

本项目的核心认证逻辑基于上游项目 [Micro-Cnhua/Ruijie_Porta_Auth](https://github.com/Micro-Cnhua/Ruijie_Porta_Auth)（该上游又参考了 [Turris-Babel/school_ruijie](https://github.com/Turris-Babel/school_ruijie)）也一定程度上参考了本校前辈的思路[ZJKJU-Network-Login](https://github.com/YaYa404/ZJKJU-Network-Login)。我们在其基础上将其封装为 OpenWrt 软件包，并增加了 LuCI 图形界面和自动重连 wrapper。

> ⚠️ 本项目仅针对湛江科技学院（ZJKJU）锐捷 ePortal Web 认证进行适配。其他学校的锐捷 Web 认证页面如果结构相同，理论上也能使用，但需要自行测试。

## 📷 界面预览

- **菜单**：服务 → ZJKJU 校园网认证
- **配置项**：学号、密码、服务类型（默认电信校园网）、手动认证 URL（可选）
- **实时状态**：当前在线/离线状态 + 服务进程状态
- **运行日志**：实时查看认证日志，每 10 秒自动刷新，支持一键清空
![图片](./认证页.png)
![图片](./配置样图.png)

## ✨ 特性

- ✅ **全架构通用**：shell + curl 实现，一个 ipk 支持所有 CPU 架构（ARM / MIPS / x86）
- ✅ **包体积极小**：仅 ~7 KB（相比 Go 版本的 2 MB 缩小 100 倍）
- ✅ **图形化配置**：LuCI Web 界面填写学号密码，无需 SSH
- ✅ **自动认证**：开机自启动，断线自动重连（默认 10 秒检测一次）
- ✅ **实时状态指示**：顶部徽章实时显示在线/离线状态，服务进程运行状态
- ✅ **进程守护**：procd 守护，崩溃后自动重启
- ✅ **实时日志**：LuCI 页面内查看运行日志，无需 SSH，支持一键清空
- ✅ **三层 URL 兜底**：手动 URL / 自动抓取 / 缓存兜底
- ✅ **智能检测**：双 DNS ping + HTTP 兜底，流量几乎为零

## 💻 支持平台

| 项目 | 版本 |
|------|------|
| 系统 | ImmortalWrt / OpenWrt 21.02+ |
| 包格式 | ipk（opkg） |
| CPU 架构 | **全架构通用**（aarch64 / armv7 / mips / mipsel / x86_64） |
| 依赖 | `luci-base`、`luci-compat`、`curl` |

> 本包为** shell 实现**，不含任何预编译二进制，因此一个 ipk 通吃所有 CPU 架构，理论上支持所有 ImmortalWrt / OpenWrt 系统。

> 💡 OpenWrt 25.12+ 已改用 apk 包格式，本仓库暂未提供 apk 版本。

## 📥 下载预编译版本

进入 GitHub 仓库的 **Releases** 或 **Actions** 页面，下载最新构建产物：

| 文件名 | 适用系统 | 架构 |
|--------|----------|------|
| luci-app-zjkju-auth_1.0.1-r1_all.ipk | OpenWrt / ImmortalWrt 21.02 ~ 24.10 | **全架构** |

## 🚀 安装

### 1. 上传 ipk 到路由器

```bash
scp luci-app-zjkju-auth_1.0.1-r1_all.ipk root@192.168.1.1:/tmp/
```

### 2. SSH 登录路由器安装

```bash
opkg update
opkg install /tmp/luci-app-zjkju-auth_1.0.1-r1_all.ipk
```

如果提示缺少依赖（`luci-compat`、`curl`），先执行：

```bash
opkg install luci-compat curl
```

### 3. 登录 LuCI 配置

浏览器打开 `http://192.168.1.1` （你真实的路由器后台地址，这里仅供参考）→ **服务 → ZJKJU 校园网认证**

- **启用**：勾选
- **学号**：填你的学号
- **密码**：填你的密码
- **服务类型**：保持默认 `%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91`（电信校园网）
- **手动认证 URL（可选）**：留空则自动抓取

点击 **保存并应用**，服务会自动启动。

### 4. 查看状态和日志

页面顶部显示实时状态徽章：

| 徽章 | 含义 |
|------|------|
| 🟢 **在线** | 网络已连接，认证有效 |
| 🔴 **离线** | 检测到掉线，正在自动重新认证 |
| ⚫ **未运行** | 服务进程已停止 |
| ⚪ **未知** | 检测失败 |

页面底部"运行日志"区会实时显示认证日志，每 10 秒自动刷新，支持：

- **立即刷新**：手动刷新日志
- **重启服务**：重启认证服务
- **清空日志**：一键清空系统日志

联网在线时：
```
wrapper started
锐捷认证客户端启动
用户名: 填你的学号
身份类型: %E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91
使用手动指定的认证地址
认证地址: http://10.80.80.249/eportal/index.jsp?wlanuserip=...
提取到queryString (长度: 236)
已联网，无需认证
```

掉线时会自动触发：

```
正在尝试认证...
认证请求URL: http://10.80.80.249/eportal/InterFace.do?method=login
发送POST数据...
响应状态: 200
响应内容: {"userIndex":"...","result":"success",...}
认证成功！
```



## ⚙️ 工作原理

本项目由三个组件构成：

| 组件 | 职责 |
|------|------|
| `zjkju-auth-wrapper.sh` | shell 脚本，循环检测在线状态；掉线时抓取最新 URL；用 curl 发送认证请求 |
| LuCI 前端 | 配置界面 + 状态指示 + 日志查看 |
| procd 服务 | 守护 wrapper 进程，崩溃自动重启 |

### 智能在线检测（双 DNS + HTTP）

```
① ping 223.5.5.5（阿里主 DNS）→ 通就认为在线
② ping 223.6.6.6（阿里备 DNS）→ 通就认为在线
③ HTTP 访问 msftconnecttest.com 确认 → 防 ICMP 被拦误判
```

流量消耗约 20 MB/月（相比纯 HTTP 检测的 300 MB/月，省 93%）。

### 三层 URL 兜底

1. **手动 URL**：若用户在 LuCI 中填写了手动 URL，优先使用
2. **自动抓取**：访问普通外网（baidu/example/qualcomm），从 302 响应中提取带 `wlanuserip` 的认证页 URL
3. **缓存兜底**：使用上次认证成功时缓存的 URL

### 为什么不用 `-e` 持久化模式？

上游 `ruijie` 的 `-e` 模式进入循环后**永远使用最初传入的 URL**。但学校掉线后 `wlanuserip` 等参数会变化，旧 URL 会失效。因此我们用 wrapper 重新实现了循环，每次掉线都重新抓取最新 URL。

### 为什么改用 shell 实现？

上游使用 Go 语言实现，编译出的二进制每个架构需单独编译（2 MB/架构），需要 Go 编译环境，包体积大。改用 shell + curl 后：

- 一个 ipk **全架构通用**（~7 KB）
- 无需 Go 编译环境
- **认证逻辑与上游完全一致**

## 🛠️ 自行编译

### 使用 GitHub Actions 云编译（推荐）

1. Fork 本仓库
2. 进入 **Actions** 页面 → 点击 **Run workflow**
3. 等待约 10 分钟
4. 编译产物自动发布到 Releases

### 本地编译（需要 OpenWrt SDK）

```bash
# 1. 下载对应 SDK
wget https://downloads.immortalwrt.org/releases/24.10.6/targets/mediatek/filogic/immortalwrt-sdk-24.10.6-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
tar --use-compress-program=unzstd -xf immortalwrt-sdk-*.tar.zst
cd immortalwrt-sdk-*/

# 2. 拉取 feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 放置本包
cp -r /path/to/luci-app-zjkju-auth package/

# 4. 编译
make package/luci-app-zjkju-auth/compile V=s

# 5. 产物在 bin/packages/<arch>/base/ 下
```

## 📁 项目结构

```
luci-app-zjkju-auth/
├── .github/workflows/build.yml       # GitHub Actions 云编译配置
├── Makefile                          # OpenWrt 包定义
├── root/                             # 安装到路由器的文件
│   ├── etc/
│   │   ├── config/zjkju-auth         # UCI 默认配置
│   │   ├── init.d/zjkju-auth         # procd 服务脚本
│   │   └── uci-defaults/80_zjkju-auth # 首次安装初始化
│   └── usr/
│       ├── bin/zjkju-auth-wrapper.sh # 自动重连 wrapper（核心）
│       └── share/
│           ├── luci/menu.d/          # LuCI 菜单注册
│           └── rpcd/acl.d/           # LuCI 权限声明
└── luasrc/                           # LuCI 前端源码
    ├── controller/zjkju-auth.lua     # 路由控制器（含状态/日志/重启接口）
    ├── model/cbi/zjkju-auth/main.lua # 配置表单
    └── view/zjkju-auth/log.htm       # 状态指示 + 日志显示
```

## ❓ 常见问题

**Q：日志一直很安静，是不是服务挂了？**

A：**看顶部状态徽章**。🟢 在线说明服务正常。在线时 wrapper 静默检测，不输出日志——这正是优化后的效果。

**Q：掉线后多久能恢复？**

A：**最多 10 秒**。wrapper 每 10 秒检测一次，检测到掉线立即认证。但如果学校网关有"观察期"（2-3 分钟），实际恢复时间可能更长。

**Q：流量消耗大吗？**

A：**极小**。使用双 DNS ping 检测，在线时每次只发一个 ICMP 包（~100 字节）。每月流量约 20 MB。

**Q：支持其他学校吗？**

A：理论上只要认证页面结构相同就能用，但需要自行测试。主要差异可能在：
- `service` 参数值（本仓库针对"电信校园网"）
- 认证服务器 IP（本仓库针对 `10.80.80.249`）
- 是否需要 RSA 加密密码（本仓库使用明文，`passwordEncrypt=false`）

如需适配其他学校，修改 `root/usr/bin/zjkju-auth-wrapper.sh` 和 `root/etc/config/zjkju-auth` 中的 `service` 与 `AUTH_SERVER` 即可。

**Q：25.12 能用吗？**

A：OpenWrt 25.12+ 使用 apk 包格式，需单独编译。目前暂未提供 apk 版本。

**Q：安装后 LuCI 里看不到菜单？**

A：浏览器缓存问题。按 `Ctrl+Shift+R` 强制刷新，或退出 LuCI 重新登录。

## 🔬 抓包获取 service 值（适配其他学校）
本仓库硬编码的 service 值是针对湛江科技学院的"电信校园网"。如果后续学校更换了服务类型也可以通过此方法写入服务类型。如果你要适配其他学校，需要抓出你们学校的 service 值。

为什么需要抓包？
锐捷 ePortal 认证要求 POST 请求里带 service 字段。不同学校、不同运营商的值都不一样，必须实测。常见的有：

default（学生）

Teacher（教工）

电信校园网 / 移动校园网 / 联通校园网

学校_学生 / 学校_教工

抓包步骤（5 步）
第 1 步：打开抓包

浏览器按 F12

切换到 Network（网络） 标签

勾选 Preserve log（保留日志）

第 2 步：触发认证

注销校园网

浏览器访问 baidu.com → 自动跳到认证页

输入账号密码，选好服务类型，点登录

第 3 步：找到 login 请求

在 Network 面板搜索框输入 login

找到 InterFace.do?method=login（POST 请求）

右键它 → Copy → Copy as cURL (bash)

粘贴到记事本

第 4 步：提取 service 值

在复制的 curl 命令里找到 service= 字段：

text
--data-raw 'userId=xxx&password=xxx&service=%25E7%2594%25B5%25E4%25BF%25A1%25E6%25A0%25A1%25E5%259B%25AD%25E7%25BD%2591&...'
把 %25 全部替换成 %，得到：

text
%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91
第 5 步：替换代码里的值

打开 root/etc/config/zjkju-auth，把 service 改成第 4 步得到的新值：

text
option service '新抓的service值'
同时修改 luasrc/model/cbi/zjkju-auth/main.lua 里的候选值，让界面能显示成中文。

快速解码命令（Linux / WSL / Mac）
bash
echo "%25E7%2594%25B5%25E4%25BF%25A1%25E6%25A0%25A1%25E5%259B%25AD%25E7%25BD%2591" | sed 's/%25/%/g'
# 输出: %E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91
再解一次验证：

bash
echo "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91" | sed 's/%\([0-9A-F][0-9A-F]\)/\\x\1/g'
# 或用在线 URL 解码工具，结果: 电信校园网
原理（1 句话）
浏览器发双重编码 → 我们硬编码用单次编码 → curl 再编码一次 → 还原成双重 → 和浏览器一致。

完整数据流
阶段	值
浏览器选"电信校园网"	电信校园网
JS 编码（单次）	%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91
表单提交再编码（双重）	%25E7%2594%25B5...%25BD%2591
我们硬编码存的值	%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91
curl --data-urlencode 再编码	%25E7%2594%25B5...%25BD%2591 ← 和浏览器一致 ✅
修改认证服务器 IP
如果你们学校的认证服务器不是 10.80.80.249，还要改 root/usr/bin/zjkju-auth-wrapper.sh 里的：

sh
AUTH_SERVER="http://你们学校的认证服务器IP"
改完重新编译即可。

## 🙏 致谢

本项目基于以下开源项目：

- [Micro-Cnhua/Ruijie_Porta_Auth](https://github.com/Micro-Cnhua/Ruijie_Porta_Auth) — 锐捷 ePortal 命令行认证工具（本项目核心认证逻辑来源）
- [Turris-Babel/school_ruijie](https://github.com/Turris-Babel/school_ruijie) — 上游的参考项目
- [ZJKJU-Network-Login](https://github.com/YaYa404/ZJKJU-Network-Login) — 本校前人的贡献
- 所有 LuCI 和 OpenWrt 社区的贡献者

## 📄 许可证

本项目采用 **GNU General Public License v2.0**（GPL-2.0）许可证，详见 [LICENSE](./LICENSE) 文件。

### 上游来源声明

- 核心认证逻辑来自 [Micro-Cnhua/Ruijie_Porta_Auth](https://github.com/Micro-Cnhua/Ruijie_Porta_Auth)
- 上游参考了 [Turris-Babel/school_ruijie](https://github.com/Turris-Babel/school_ruijie)
- 上游未声明许可证，本项目自主选择 GPL-2.0，并保留上游版权声明

## ⚠️ 免责声明

- 本项目仅供学习交流使用，请勿用于商业用途
- 使用本工具可能违反学校网络管理规定，请自行承担风险
- 密码保存在路由器 `/etc/config/zjkju-auth` 中（权限 600，仅 root 可读），请确保路由器安全
