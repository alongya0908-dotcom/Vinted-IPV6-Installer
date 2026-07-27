# Vinted IPv6 一键安装器

这是 Vinted IPv6 代理控制台的公开、无源码安装分发仓库。安装器固定到
`v1.8.13` 运行包及其 SHA-256，校验失败会立即停止，不会安装未知文件。

## 一键安装或升级

先切换到 `root`，再执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alongya0908-dotcom/Vinted-IPV6-Installer/main/install.sh)
```

- 首次安装会交互询问管理员、监听端口、IPv6 `/48` 前缀等必要配置。
- 默认根据服务器 IPv4 使用 `sslip.io` 域名自动安装 Nginx、Let's Encrypt 可信证书和续期定时器；需确保公网 80/443 端口放行。
- 已有自有域名可增加 `--public-domain example.com`；确实不需要可信证书时可增加 `--skip-trusted-https`。
- 已安装服务器再次执行会进行事务升级，保留数据库、管理员账号和网络设置。
- 安装前自动创建备份；服务健康检查失败会自动回滚。
- 当前支持 Debian/Ubuntu、Linux AMD64 与 systemd。

无人值守升级已有服务器：

```bash
VINTED_IPV6_ASSUME_YES=1 bash <(curl -fsSL https://raw.githubusercontent.com/alongya0908-dotcom/Vinted-IPV6-Installer/main/install.sh)
```

版本化运行包与校验文件见
[v1.8.13 Release](https://github.com/alongya0908-dotcom/Vinted-IPV6-Installer/releases/tag/v1.8.13)。
