# recover.sh 设计与踩坑

> 本仓为**公开镜像**，本文只记**通用、可公开**的设计与踩坑；涉及具体 IP / 节点名 /
> 内网拓扑 / 凭据的运维细节在私有上游仓，不在此处。

## recover.sh 是什么

容器型 VPS（userspace 模式、常无 systemd、重启或重建后状态可能丢失）的**单文件、
幂等、自包含**自愈脚本。一条命令从**任何中间状态**续跑，不用人工记进度：

```
装 tailscale → 起 tailscaled(userspace) → 登录 tailnet → 设 exit node 借出网
→ 配 git 凭据/代理 → git 自更新仓库 → 连通性验证
```

每步先探测"做完没"，已做则跳过、缺则补，可反复跑。

## 用法

```bash
# @main：URL 固定好记，但 jsDelivr 边缘缓存有延迟（见踩坑 6）
# bash -n 是完整性门槛：网络抖动把脚本下载截断时直接拦下，不会跑半截
curl -fsSL https://cdn.jsdelivr.net/gh/dff652/vps-bootstrap@main/recover.sh -o /root/recover.sh \
  && bash -n /root/recover.sh \
  && chmod +x /root/recover.sh && bash /root/recover.sh

# 急用最新（刚改完）：钉 commit 的 @<sha>，不受缓存影响（发布脚本会打印当次 @sha 一行流）
```

依赖一个 `/root/.ts_env`（密钥文件，**不在本仓**），缺字段时脚本会交互引导补全。

## 关键设计 & 踩坑（通用）

1. **userspace 模式 `ping` 永远不通**——ICMP 走内核栈，而 userspace tailscaled 不接管内核路由。
   验证连通性用 `tailscale ping` 或 TCP 工具，别用 `ping`。
2. **密钥输入**：不回显 + 读后遮罩回显（头16+星+尾4+长度）+ 前缀校验 + 确认/重输；
   任何"输入即用"的密钥失败时都**回到对应输入项**，不让你手动改文件。
3. **错误分类**：`tailscale up` 失败按错误文本分流——
   - `requested tags ... not permitted` → **tag 问题**（ACL 没定义该 tag），提示去 tag 重试，**不是 key 问题**；
   - `invalid key / not valid / expired` → key 问题，重输 key；
   - 网络/冲突 → 只提示，不打扰你重输。
   （早期版本把所有失败都当 key 问题，反复让你换 key——是个误导，已修。）
4. **两种 key 别粘混**：tailscale auth key 是 `tskey-auth-` 开头（生成时勾
   Reusable + Ephemeral + Pre-approved）；GitHub PAT 是 `github_pat_` 开头，给 git 用。脚本会按前缀拦误粘。
5. **版本号自报**：脚本启动打印 `recover.sh version: <源仓短sha + 日期>`（发布时盖戳），
   对照上游 HEAD 即知拉到的是不是最新；旧版无此行。
6. **jsDelivr `@main` 缓存延迟**：`@main` 是分支别名，jsDelivr 各边缘节点**独立刷新**，
   push（甚至 purge）后并非全球即时生效——可能拉到旧版。`@<sha>` 钉 commit 是不可变 URL，
   **永远即时**。所以"急用最新走 `@<sha>`，平时 `@main`"。
7. **webshell 粘贴别用 heredoc**：`cat > f <<'EOF' ... EOF` 粘贴时若被自动缩进，结束标记失效、
   `cat` 一直读。改用 `cat > f` 粘完按 Ctrl-D，或 `vim` 里 `:set paste` 再粘。

## 这个仓与上游的关系

- 本仓只放 `recover.sh`（无密钥）+ 文档，作为**公开镜像**供新 VPS 无 token 一行流拉取。
- `recover.sh` 当前由上游私有仓的发布脚本**单向同步**到此（会覆盖本仓的 `recover.sh` 与 `README.md`）。
- **公开仓铁律**：绝不写入密钥、真实 IP/端口、内网拓扑、token。
