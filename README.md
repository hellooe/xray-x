# Xray 管理脚本 (xr.sh)

一个轻量级的 Xray 核心管理工具，通过 [Web 前端](https://hellooe.github.io/xray-x/) 可视化配置与智能 Shell 脚本后端的解耦联动，轻松配置 VLESS + Reality / 后量子加密 / XHTTP + TLS 等协议，支持 Cloudflare 增强（Origin Certificate + Origin Rule）。

---

## ✨ 功能特性

- **全自动安装/更新/卸载** Xray 核心（支持 amd64 / arm64）
- **交互式菜单**，或通过 `ACTION` 环境变量实现非交互式操作
- **入站支持**：
  - VLESS + Reality（自动生成密钥对）
  - VLESS + 后量子加密（`vlessenc`，ML-KEM-768）
  - VLESS + XHTTP + TLS（可配合 Cloudflare 源站证书和 Origin Rule）
- **出站支持**：
  - VLESS + Reality
  - SOCKS5
  - WireGuard（WARP 分流）
- **灵活的路由规则**（按域名/IP/端口/网络类型）
- **配置自动生成与验证**（使用 `xray run -test`）
- **分享链接生成**（VLESS 标准格式链接）
- **服务管理**（systemd / OpenRC / nohup 自动适配）
- **持久化配置**：用户输入保存在 `~/xr/env.conf`，避免重复输入

---

## 🚀 安装与使用

### 1. 交互式运行

```bash
curl -L -o xr.sh https://raw.githubusercontent.com/hellooe/xray-x/refs/heads/master/xr.sh
chmod +x xr.sh
./xr.sh
```

进入菜单后按数字选择功能：
```
  1) 安装 Xray
  2) 更新 Xray
  3) 卸载 Xray
  4) 添加入站
  5) 添加出站
  6) 添加路由
  7) 列出所有配置
  8) 删除 (入站/出站/路由)
  9) 生成配置
 10) 启动 Xray
 11) 停止 Xray
 12) 重启 Xray
 13) 生成分享链接
 14) 查看状态
  0) 退出
```

### 2. 非交互式执行（用于自动化）

通过环境变量 `ACTION` 指定操作：
```bash
ACTION=install bash <(curl -Ls ...)
ACTION=add_inbound bash <(curl -Ls ...)
ACTION=add_outbound bash <(curl -Ls ...)
ACTION=add_route bash <(curl -Ls ...)
ACTION=update bash <(curl -Ls ...)
ACTION=uninstall bash <(curl -Ls ...)
```

在执行 `add_inbound`、`add_outbound`、`add_route` 后，脚本会自动生成配置并重启服务。

---

## 🗂️ 目录结构

脚本将所有数据存放在 `~/xr/` 下：
```
~/xr/
├── xray                     # Xray 可执行文件
├── env.conf                 # 持久化变量
├── config/
│   ├── config.json          # 最终生成的配置
│   ├── inbounds/            # 入站片段 (*.json)
│   ├── outbounds/           # 出站片段 (*.json)
│   └── routes/              # 路由片段 (*.json)
├── logs/
│   ├── access.log
│   └── error.log
├── reality/                 # Reality 密钥对 (private/public_key, short_id)
├── certs/                   # TLS 证书（Cloudflare 源站证书）
└── encryption/              # 后量子加密标识（inbound-<port>.enc）
```

---

## ⚙️ 配置说明

### 入站协议

| 协议 | 说明 | 关键参数 |
|------|------|----------|
| 1 – tcp+Reality | 使用 `xray x25519`，自动生成密钥对 | 目标域名 (dest) |
| 2 – tcp+enc | 使用 `xray vlessenc` 生成的加密方式（ML-KEM-768） | 无额外参数 |
| 3 – XHTTP+TLS | 可套 CDN，可选 Cloudflare 增强 | 域名、路径、CF 邮箱/Global Key/Zone ID |

**Cloudflare 增强**：
- 自动申请 Origin Certificate（有效期 365 天）
- 自动创建 Origin Rule，将特定路径的请求转发到本机端口（需提供 CF 邮箱、Global API Key、Zone ID）

### 出站类型

| 类型 | 说明 | 必填参数 |
|------|------|----------|
| 1 – vless+reality | 连接到远程 Reality 节点 | 地址、端口、UUID、serverName、publicKey、shortId |
| 2 – SOCKS5 | SOCKS5 代理（可选认证） | 地址、端口、用户名/密码（可选） |
| 3 – WireGuard | WARP 或自定义 WireGuard 节点 | 私钥、地址、端点、公钥、reserved（可选） |

### 路由规则

每条路由规则包含：
- 名称（用于文件名）
- 目标出站标签（`outboundTag`）
- 匹配条件（域名、IP、端口、网络类型）至少一项

---

## 📊 服务管理

脚本自动检测系统：
- **OpenRC**（Alpine 等）：使用 `rc-service` 和 `/etc/init.d/xray`
- **systemd**：使用 `systemctl`
- **其他**：使用 `nohup` 后台运行，日志输出到 `~/xr/logs/xray.log`

支持命令：`start` / `stop` / `restart` / `status`

---

## 📦 依赖

脚本会自动尝试安装（`apk` / `apt` / `yum`）：
- `curl`, `wget`, `unzip`, `openssl`, `jq`

如无法自动安装，请手动安装上述工具。

---

## 📝 许可证

本项目脚本遵循 MIT 许可证，Xray 核心遵循其自身许可证。

---

## 🤝 贡献

欢迎提交 Issue 或 PR。如有问题，请先审阅日志文件（`~/xr/logs/error.log`）以便诊断。
