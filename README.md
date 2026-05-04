# Proxy Stack

个人自用的代理一键部署工具:**VLESS-Reality + Hysteria2 + MTProxy(mtg) + 只读面板**,Docker 跑,菜单驱动。

## 一键安装

在新 VPS(Ubuntu 22 / Debian 11+ / CentOS 8+)上执行:

```bash
bash <(curl -sL https://raw.githubusercontent.com/kpepsistar-cell/proxy-stack/main/install.sh)
```

会弹出菜单:

```
  ╔══════════════════════════════════════════════╗
  ║       Proxy Stack — Manager                  ║
  ║       VLESS-Reality + Hysteria2 + MTProxy    ║
  ╚══════════════════════════════════════════════╝

  ● Not deployed

  Setup
    1) Full deploy / Re-deploy
    2) Show node info & subscription links

  Manage
    3) Restart all services
    4) Update to latest (pull from GitHub)
    5) Change a port
    6) View live logs

  Tweaks
    7) Change Reality SNI
    8) Regenerate Telegram MTProxy secret
    9) Check / Enable BBR

  Other
   10) Uninstall
    0) Exit

  Choice [0-10]:
```

第一次按 `1` 全自动部署,完成后按 `2` 查看节点订阅链接。

部署完成后,以后任何时候只需输入 `proxy` 命令即可呼出菜单(脚本自动建了软链 `/usr/local/bin/proxy`)。

---

## 默认端口

| 协议 | 端口 | 备注 |
|---|---|---|
| VLESS-Reality | 443 / TCP | 主力 |
| Hysteria2 | 8443 / UDP | 加速 |
| MTProxy(mtg) | 8888 / TCP | Telegram 专用 |
| Dashboard | 2053 / TCP | HTTP + Basic Auth |

如果某个端口被你的网络拦截,菜单选 `5)` 改端口。

---

## 客户端推荐

| 平台 | 客户端 |
|---|---|
| iOS | Shadowrocket(小火箭) / Streisand |
| Android | NekoBox / v2rayNG |
| macOS | V2Box / NekoBox / Hiddify |
| Windows | NekoBox / v2rayN / Hiddify |

**导入节点最稳的方式**:浏览器打开面板,点 **Copy** 按钮,客户端"从剪贴板导入"。**不要扫码**,扫码经常丢 Flow 字段。

---

## 多 VPS 部署

每台 VPS 重复"一键安装"流程即可。每台密钥独立。客户端里把所有节点加到一个分组,自动测速 + 故障转移。

---

## 升级

新 VPS:重新执行一键安装命令即可。
已部署:进菜单按 `4)` Update。

---

## 故障排查

### 容器一直 Restarting
```bash
proxy
# 选 6) View live logs → 1) singbox
```

### Dashboard 端口变成随机端口
说明 `.env` 软链没建好,docker compose 没读到变量:
```bash
cd /opt/proxy
ln -sf config.env .env
docker compose down && docker compose up -d
```

### Telegram iOS 显示 "MTProto, unavailable"
secret 不是 hex 格式。进菜单选 `8) Regenerate Telegram MTProxy secret`,然后手机端:
1. Telegram → Settings → Data and Storage → Proxy → 删旧代理
2. 完全关 Telegram(从后台滑掉)
3. 重新点面板里 `tg://proxy?...` 链接加代理

### 客户端测延迟超时
1. VPS 上看 sing-box 实时日志:`proxy → 6 → 1`,客户端测延迟时观察
   - 日志有新输出 → 流量到了 VPS,客户端配置错(检查 Flow / Public Key / SNI / Allow Insecure)
   - 日志一片空白 → 流量没到 VPS,**客户端网络环境拦截**(运营商/路由器/防火墙拦了端口)
2. 端口被拦的话,`proxy → 5` 改端口(试 2087、2096 等)

### VPS 防火墙
`ufw status` 应该是 inactive。**Vultr Firewall Group 千万别挂**(白名单模式,挂了锁 SSH)。

---

## 安全建议

1. **`/opt/proxy/config.env` 是密钥文件**,权限 600,不要 git 提交、不要发群里。建议 `scp` 备份到本地一份
2. **面板端口 2053 默认对公网开放**,有 Basic Auth 保护
3. **VPS SSH 端口建议改掉**(不用默认 22),并禁用密码登录只用密钥

---

## 协议选型说明

**为什么砍掉 VMess/Trojan/SS?** 这些协议特征已被 GFW 机器学习识别,IP 容易进黑名单。**Reality 用真实 HTTPS 网站握手,从协议层面消除指纹**,目前最抗封锁。

**为什么 Reality + Hy2?** 一个 TCP 一个 UDP,底层不同互为补充。Reality 主力,Hy2 加速。中国移动网络对 UDP 限速严重时 Reality 才是真主力。

**mtg 单独跑?** 它专门给 Telegram 用,fake-tls 伪装独立于 sing-box 体系。

---

## 已知踩坑记录

1. **Telegram iOS 不认 base64 secret**,只能 hex 格式(`ee` 开头)
2. **docker compose 只读 `.env`**,不读 `config.env`,所以脚本自动建软链
3. **sing-box 1.12+ 改了 DNS 配置格式**,本项目已去掉 DNS 块用系统 DNS
4. **Vultr Firewall Group 是白名单**,挂上锁 SSH,新手陷阱
5. **mtg v2 generate-secret 输出 base64**,iOS 不识别,本项目改用 openssl 直接构造 hex
6. **本地/路由器防火墙**有时拦 8443/8888 等非标准端口,改端口或加白名单
7. **客户端扫码导入容易丢字段**(尤其 VLESS 的 `flow`),用复制链接 + 剪贴板导入更稳

---

## 目录结构

```
proxy-stack/
├── install.sh             # 入口菜单(curl 一键安装)
├── deploy.sh              # 实际部署逻辑
├── update.sh              # 更新镜像
├── uninstall.sh           # 卸载
├── info.sh                # 命令行查节点
├── docker-compose.yml
├── sing-box/
│   └── config.json.tpl    # 配置模板
└── dashboard/
    ├── Dockerfile
    ├── app.py
    └── templates/index.html
```

部署后会在 `/opt/proxy/` 下额外生成(被 .gitignore 排除):
- `config.env` — 密钥配置
- `sing-box/config.json` — 渲染后的 sing-box 配置
- `sing-box/hy2.crt`、`hy2.key` — 自签证书
