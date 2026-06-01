# vps-bootstrap

容器型 VPS 接入家庭 tailnet 的**单文件自愈脚本**公开镜像。

源在私有仓 `dff652/homelab`（`vps/recover.sh`），此处只做公开镜像，
让新 VPS 无需 token 即可一行流拉取。**脚本本身不含任何密钥**，
auth key / PAT 都在各机的 `/root/.ts_env`，与本脚本分离。

## 用法（新 VPS 上）

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/dff652/vps-bootstrap@main/recover.sh -o /root/recover.sh \
  && chmod +x /root/recover.sh && bash /root/recover.sh
```

直连断网时改用本机 SSH 推（见私有仓 `vps/push_bootstrap_to_vps.sh`）。
