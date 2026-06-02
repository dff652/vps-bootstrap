# CLAUDE.md — vps-bootstrap 仓的 AI 工作指南

公开仓，承载 `recover.sh`（容器型 VPS 接入私有 tailnet 的单文件自愈引导脚本，**无密钥**）
+ 文档。设计与踩坑见 [`NOTES.md`](NOTES.md)。

## 这个仓的性质（动手前先认清）

- **公开仓**（origin 是公开 GitHub）。**铁律：绝不写入任何密钥、真实 IP/端口、内网拓扑、
  token、订阅链接**。新增内容前先确认可公开；密钥永远只在各机 `/root/.ts_env`（不入仓）。
- **`recover.sh` 当前是镜像**：唯一源在**私有上游仓**（`dff652/homelab` 的 `vps/recover.sh`），
  由上游 `vps/publish_recover.sh` **单向同步**到此——会**覆盖**本仓的 `recover.sh` 和 `README.md`。
  所以**别直接在本仓改 `recover.sh`**（下次同步即被覆盖）；要改回上游改、再发布。
- `NOTES.md` / `CLAUDE.md` 等手写文档发布脚本不动，可在本仓维护。

## source-of-truth：已定为架构 A（2026-06-02）

`recover.sh` 的**唯一源永远在私有上游仓 homelab/vps**，本仓是**只读公开镜像**。
**任何时候都别在本仓直接改 `recover.sh`**——回 homelab 改、再跑 `vps/publish_recover.sh` 同步。

为什么不把主源挪到这里（曾考虑的架构 B，已否决）：homelab/vps 有 11 个脚本 + 7 个文档，
其中只有 `recover.sh` 能公开，其余（含真实 IP/节点/凭据逻辑）必须留私有仓且必须持续维护。
把 `recover.sh` 单独挪来只会让它和兄弟脚本/文档分居两仓、徒增切换。**日常维护在 homelab 主仓。**

## 约定

- 全中文文档（代码/标识符英文）。
- commit 格式 follow 习惯：`<type>(<scope>): <message>`，末尾加
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`。
- push 等用户明确说（本仓 push 即公开）。

## 发布/缓存要点（详见 NOTES.md）

- 一行流 `@main` 有 jsDelivr 缓存延迟；急用最新走 `@<sha>`（不可变、即时）。
- `recover.sh` 启动打印 `version: <源仓短sha+日期>`，对照源仓 HEAD 判断新旧。
