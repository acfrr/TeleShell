# SSH 登录 Telegram 通知

SSH 登录时自动通过 Telegram Bot 推送通知，包含主机名、IP、登录用户、来源 IP、终端和时间。

## 功能特点

- SSH 成功登录自动 Telegram 通知
- 基于 PAM 触发，无常驻进程，不占后台资源
- 安装时自动检测公网 IP，支持 AWS / GCP / Azure / Oracle / DigitalOcean Metadata 及外部 API fallback
- 安装时可自定义 VPS 名称，方便区分多台机器
- 支持一键卸载和彻底卸载
- 通知失败不影响 SSH 登录

## 使用方法

以 root 用户执行：

```bash
curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/install.sh -o /root/install-ssh-login-tg-alert.sh
chmod +x /root/install-ssh-login-tg-alert.sh
bash /root/install-ssh-login-tg-alert.sh
```

### 环境变量传入默认值（省去每次手打 Token）

```bash
TG_BOT_TOKEN="你的token" TG_CHAT_ID="你的chatid" SERVER_NAME="我的VPS" bash /root/install-ssh-login-tg-alert.sh
```

所有通过环境变量传入的值都会成为安装提示的默认值，直接回车即可使用。不想用默认值时手动输入新值覆盖。

### 一键安装（不保存脚本）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/install.sh)
```

如需传入默认值：

```bash
TG_BOT_TOKEN="你的token" TG_CHAT_ID="你的chatid" bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/install.sh)
```

## 卸载

保留配置文件（方便重新安装）：
```bash
bash /root/install-ssh-login-tg-alert.sh uninstall
```

彻底卸载（删除配置文件）：
```bash
bash /root/install-ssh-login-tg-alert.sh purge
```

## 通知效果

```
🔐 SSH 登录通知

主机: my-vps
公网IP: 1.2.3.4
用户: root
来源IP: 5.6.7.8
终端: pts/0
时间: 2026-05-25 12:00:00 CST
```

## 依赖

- curl（脚本会自动安装）
- 基于 PAM 的 Linux 系统

## 安全说明

- 通知脚本仅 root 可读写（700），配置文件仅 root 可读写（600）
- 通知脚本执行前会检查配置文件 owner 是否为 root:root，防止普通用户篡改后提权
- PAM 使用 `session optional`，通知失败不会阻断 SSH 登录
- 所有外部 API 调用均设置超时，不会卡死登录流程

## License

MIT
