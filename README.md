# KStar Proxy 一键包

KStar Proxy 是一个个人 VPS 代理一键部署和管理脚本，基于 Docker Compose 部署：

- VLESS-Reality
- Hysteria2
- MTProxy / mtg
- Web Dashboard 面板

适合在 Ubuntu、Debian、CentOS、Rocky、AlmaLinux 等常见 VPS 系统上快速部署。

## 一键安装

SSH 登录 VPS 后，使用 root 用户执行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/kpepsistar-cell/proxy-stack/main/install.sh)
```

安装脚本会自动拉取项目到：

```text
/opt/proxy
```

并创建快捷命令：

```bash
proxy
```

以后在任意目录输入 `proxy` 即可打开管理菜单。

## 常用操作

打开菜单：

```bash
proxy
```

常用菜单项：

```text
1  全新部署 / 重新部署
2  查看节点信息和订阅链接
3  重启全部服务
4  更新到最新版
5  修改端口
6  查看实时日志
11 健康诊断
12 修复服务
13 TCP 调优
```

第一次安装后选择 `1` 进行部署，部署完成后选择 `2` 查看节点信息、订阅链接和面板地址。

## 手动更新

如果不使用菜单，也可以手动更新：

```bash
cd /opt/proxy
git pull
bash update.sh
chmod 600 config.env
bash doctor.sh
```

## 默认端口

| 服务 | 默认端口 | 协议 |
|---|---:|---|
| VLESS-Reality | 443 | TCP |
| Hysteria2 | 8443 | UDP |
| MTProxy / mtg | 8888 | TCP |
| Dashboard | 2053 | TCP |

如果端口被占用或被网络限制，可以进入菜单选择 `5` 修改端口。

## 重要文件

部署目录：

```text
/opt/proxy
```

核心配置文件：

```text
/opt/proxy/config.env
```

`config.env` 内含 UUID、密码、密钥等敏感信息，不要上传到 GitHub，也不要发给别人。建议权限保持为：

```bash
chmod 600 /opt/proxy/config.env
```

## 健康检查

执行：

```bash
cd /opt/proxy
bash doctor.sh
```

如果日志里出现：

```text
REALITY: processed invalid connection
```

通常只是公网端口被扫描或无效连接尝试，只要客户端能正常连接、容器状态正常，一般不用处理。

## 查看日志

查看 sing-box 日志：

```bash
docker logs --tail=80 proxy-singbox
```

查看 Dashboard 日志：

```bash
docker logs --tail=80 proxy-dashboard
```

查看容器状态：

```bash
docker ps
```

## 卸载

打开菜单：

```bash
proxy
```

选择 `10` 卸载。

也可以在项目目录执行：

```bash
cd /opt/proxy
bash uninstall.sh
```

## 目录结构

```text
proxy-stack/
├── install.sh
├── deploy.sh
├── update.sh
├── doctor.sh
├── repair.sh
├── info.sh
├── uninstall.sh
├── docker-compose.yml
├── sing-box/
│   └── config.json.tpl
└── dashboard/
    ├── Dockerfile
    ├── app.py
    ├── templates/
    └── static/
```

