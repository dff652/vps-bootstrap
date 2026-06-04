# vps-bootstrap

`dff652/homelab`（私有）里**可公开、无密钥**脚本的公开镜像，让新机/中转无需 token 一行流拉取。
**源永远在私有仓**，此处只读镜像（由 homelab `vps/publish_recover.sh` 单向同步，**勿在此直接改**）。
密钥 / 真实节点参数都不在脚本里（运行时传 / 各机 `/root/.ts_env`）。

## recover.sh —— 容器型 VPS 接入家庭 tailnet 自愈

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/dff652/vps-bootstrap@main/recover.sh -o /root/recover.sh \
  && bash -n /root/recover.sh \
  && chmod +x /root/recover.sh && bash /root/recover.sh
```

## relay/add-realm-landing.sh —— Realm 中转加落地

「中转 + 落地」二级跳里中转机侧：装 realm、配端口转发、systemd 自启、L4 自检、产出 Clash 节点。
来源支持 `vless://` / http 订阅 / 手动；含 `install`/`list`/`remove`/`build` 子命令。

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/dff652/vps-bootstrap@main/relay/add-realm-landing.sh -o /root/add-realm-landing.sh \
  && bash -n /root/add-realm-landing.sh && chmod +x /root/add-realm-landing.sh \
  && sudo ./add-realm-landing.sh          # 交互：粘落地 vless → 名称 → 监听端口（缺 realm 自动装）
```

`bash -n` 是完整性门槛：网络抖动导致下载截断时直接拦下，不跑半截脚本。
