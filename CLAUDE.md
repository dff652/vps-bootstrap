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

## ⚠️ 待定决策：source-of-truth 归属

用户计划后续在本目录开会话维护 `recover.sh`。但当前架构是"上游为源、单向覆盖同步到此"，
**若要把本仓改成 `recover.sh` 的主源**，必须先：
1. 停用/反转上游 `publish_recover.sh` 的覆盖同步（否则本仓改动被覆盖）；
2. 决定上游私有仓如何引用本仓的 `recover.sh`（submodule / 反向同步 / 不再保留副本）。

**在这个决策落定前，改 `recover.sh` 仍应回上游改**，避免两边打架。

## 约定

- 全中文文档（代码/标识符英文）。
- commit 格式 follow 习惯：`<type>(<scope>): <message>`，末尾加
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`。
- push 等用户明确说（本仓 push 即公开）。

## 发布/缓存要点（详见 NOTES.md）

- 一行流 `@main` 有 jsDelivr 缓存延迟；急用最新走 `@<sha>`（不可变、即时）。
- `recover.sh` 启动打印 `version: <源仓短sha+日期>`，对照源仓 HEAD 判断新旧。
