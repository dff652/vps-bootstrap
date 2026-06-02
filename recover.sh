#!/usr/bin/env bash
# recover.sh —— 容器型 VPS 一键自愈（Moark / Kunpeng 等 userspace 容器）
#
# 用途：从「任何状态」继续，不用人工记进度。每步先探测「做完没」，
#       缺则补，已做则跳过 —— 幂等，可反复跑。
#       重启后、半途中断、全新机器，统一跑这一个脚本。
#
# 解决 stale-repo 陷阱：关键拉起逻辑全部 inline（不调用仓库其它脚本，
#   不管它们新旧），网络拉起后第一件事 git pull 自更新整个仓库，之后
#   才委托(已刷新的) diag 验证。建议拷一份到 /root（/root 持久化）：
#     cp /data/homelab/vps/recover.sh /root/recover.sh
#
# 用法:
#   bash recover.sh              # 完整自愈：拉起→exit node→git→自更新→验证
#   bash recover.sh check        # 只读探测现状（新机器/任何状态都能跑，不改东西）
#   bash recover.sh env          # 只交互建/补 .ts_env（缺字段才问，不跑后续；避免手敲 heredoc 易错）
#   bash recover.sh reset        # 备份旧 .ts_env→.ts_env.bak（可回退），清空全字段重新交互建后跑完整流程
#   bash recover.sh status       # 看 tailscale 当前状态
#   bash recover.sh --no-pull    # 跳过 git 自更新
#   bash recover.sh --no-exit    # 不设 exit node
#
# 依赖 /root/.ts_env（重启后仍在；>3 天关机被清则需先从家里 vault 拷回，
#   或交互跑本脚本时按提示新建）:
#   export TS_AUTHKEY=tskey-auth-xxxxx
#   export TS_HOSTNAME=vps-3-xxxx           # 本机唯一名
#   export TS_TAGS=tag:vps                  # 可选
#   export GH_TOKEN=github_pat_xxxxx        # 可选，配 git 凭据
#   export GH_USER=dff652                   # 可选
#   export BOOT_EXIT_NODE=gl-mt2500-3       # 可选，默认 gl-mt2500-3
#   export REPO_DIR=/data/homelab           # 可选，默认 /data/homelab
#
# 结论判定: [OK] 正常   [!] 有问题   [WARN] 能继续但需留意

set -uo pipefail

LOG=/var/log/vps-recover.log
ENV_FILE="${TS_ENV_FILE:-/root/.ts_env}"
CRED_FILE=/root/.git-credentials
SOCKS_PORT=1055
HTTP_PORT=1056
TSD_LOG=/var/log/tailscaled.log
REPO_DIR="${REPO_DIR:-/data/homelab}"
# 版本标记：publish_recover.sh 发布到公开仓时会把 "source" 替换成 homelab 短 sha+日期，
# 所以一行流拉下来的副本会自报来自哪个 commit —— 对照 homelab HEAD 即知是否最新。
RECOVER_VERSION="d36bac6 (2026-06-02)"

DO_PULL=1
DO_EXIT=1
ONLY_STATUS=0
ONLY_CHECK=0
ONLY_ENV=0
ONLY_RESET=0

ok()   { printf '  [OK]   %s\n' "$1"; }
bad()  { printf '  [!]    %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
hr()   { printf '\n=== %s ===\n' "$1"; }

# 遮罩回显：头 16 + 星 + 尾 4 + 长度。short 串少露。secret 全文绝不进终端/日志。
mask() {
  local s="$1" n=${#1}
  if [ "$n" -le 16 ]; then printf '%s***%s (len %d)' "${s:0:4}" "${s: -2}" "$n"
  else printf '%s********%s (len %d)' "${s:0:16}" "${s: -4}" "$n"; fi
}

# 交互读密钥：不回显（避免进终端/LOG 全文）→ 遮罩回显 → 前缀校验 → 确认/重输。
# 用法: read_secret "提示" 期望前缀 [备用前缀]   结果在 $_SECRET；空输入返回 1（用于可跳过的字段）
read_secret() {
  local prompt="$1" p1="$2" p2="${3:-}" val c
  while :; do
    read -r -s -p "$prompt" val; echo
    [ -z "$val" ] && { _SECRET=""; return 1; }
    printf '    读到 %s\n' "$(mask "$val")"
    if [ "${val#"$p1"}" != "$val" ] || { [ -n "$p2" ] && [ "${val#"$p2"}" != "$val" ]; }; then
      ok "格式正确（${p1} 开头）"
    else
      bad "前缀不是 ${p1}${p2:+/$p2}（疑似粘错），仍可强制确认"
    fi
    read -r -p "    确认用这把? [Y=用 / 其它键=重输]: " c
    case "$c" in ""|y|Y) _SECRET="$val"; return 0 ;; *) warn "重新输入"; : ;; esac
  done
}

ts_state() { tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-pull) DO_PULL=0; shift ;;
    --no-exit) DO_EXIT=0; shift ;;
    status)    ONLY_STATUS=1; shift ;;
    check)     ONLY_CHECK=1; shift ;;
    env|setenv) ONLY_ENV=1; shift ;;
    reset)     ONLY_RESET=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) bad "未知参数: $1"; exit 2 ;;
  esac
done

printf 'recover.sh version: %s\n' "$RECOVER_VERSION"

# ---------- check：零依赖只读探测（新机器/任何状态都能跑，不写日志、不需 root）----------
if [ "$ONLY_CHECK" -eq 1 ]; then
  hr "现状探测（只读，不改任何东西）"
  ls "$REPO_DIR/vps/recover.sh" >/dev/null 2>&1 && ok "仓库:   有 $REPO_DIR" || bad "仓库:   无（需 git clone 或 push_bootstrap_to_vps.sh）"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE" 2>/dev/null || true
    ok "密钥:   有 $ENV_FILE (TS_HOSTNAME=${TS_HOSTNAME:-?}, GH_TOKEN=$([ -n "${GH_TOKEN:-}" ] && echo 有 || echo 无))"
  else
    bad "密钥:   无 $ENV_FILE（交互跑 recover.sh 会引导你建）"
  fi
  command -v tailscale >/dev/null 2>&1 && ok "二进制: $(tailscale version 2>/dev/null | head -1)" || bad "二进制: 无 tailscale"
  pgrep -x tailscaled >/dev/null 2>&1 && ok "守护:   tailscaled 在跑" || warn "守护:   tailscaled 没跑"
  if tailscale status >/dev/null 2>&1; then
    ok "登录:   已登录 IP $(tailscale ip -4 2>/dev/null | head -1)"
  else
    warn "登录:   未登录 / daemon 没起"
  fi
  ls /dev/net/tun >/dev/null 2>&1 && echo "  环境:   有 TUN" || echo "  环境:   无 TUN → 只能 userspace"
  grep -q docker /proc/1/cgroup 2>/dev/null && echo "  环境:   容器" || echo "  环境:   非容器"
  echo
  echo "  下一步: 直接跑  bash $0  （幂等，缺什么补什么；无 .ts_env 会交互引导）"
  exit 0
fi

# ---------- status：tailscale 当前状态 ----------
if [ "$ONLY_STATUS" -eq 1 ]; then
  hr "状态快照"
  command -v tailscale >/dev/null && ok "tailscale: $(tailscale version 2>/dev/null | head -1)" || bad "tailscale 未装"
  pgrep -x tailscaled >/dev/null && ok "tailscaled 在跑" || warn "tailscaled 没跑"
  echo "  BackendState: $(ts_state)"
  echo "  本节点 IP:    $(tailscale ip -4 2>/dev/null | head -1)"
  echo "  exit node:    $(tailscale debug prefs 2>/dev/null | sed -n 's/.*"ExitNodeID": *"\([^"]*\)".*/\1/p' | head -1)"
  tailscale status 2>/dev/null | head -5
  exit 0
fi

# 完整流程：所有输出 tee 到 LOG（覆盖），方便贴回排查
exec > >(tee "$LOG") 2>&1

[ "$(id -u)" -eq 0 ] || { bad "请用 root 跑"; exit 1; }

# reset：备份旧配置（可回退）再清空，让 step0 走全字段交互重建
if [ "$ONLY_RESET" -eq 1 ]; then
  hr "reset：重置 $ENV_FILE"
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$ENV_FILE.bak" && chmod 600 "$ENV_FILE.bak"
    ok "旧配置已备份 → $ENV_FILE.bak（回退：mv $ENV_FILE.bak $ENV_FILE）"
    rm -f "$ENV_FILE"
  else
    warn "$ENV_FILE 本就不存在，直接进交互新建"
  fi
fi

# ---------- 0. 读 / 建 / 补全环境 ----------
hr "0. 读 $ENV_FILE"
# 先尝试 source 已有内容（可能不存在、或存在但缺字段）
[ -f "$ENV_FILE" ] && { . "$ENV_FILE" 2>/dev/null || true; }   # shellcheck disable=SC1090

# 判定按字段而非文件存在：覆盖「不存在 / 存在但缺 TS_AUTHKEY」两种半途场景
if [ -z "${TS_AUTHKEY:-}" ]; then
  if [ -f "$ENV_FILE" ]; then
    warn "$ENV_FILE 存在但缺 TS_AUTHKEY（半途/只配了 GitHub 部分），补全 tailscale 字段"
  else
    warn "$ENV_FILE 不存在（新机器首次，或关机 >3 天被清）"
  fi
  if [ -t 0 ]; then
    echo "  到 https://login.tailscale.com/admin/settings/keys 生成 key"
    echo "  （勾 Reusable + Ephemeral + Pre-approved；或复用家里 vault 的 reusable key）"
    read_secret "  粘贴 TS_AUTHKEY (tskey-auth-…，输入不回显，粘完回车): " "tskey-auth-" "tskey-" \
      || { bad "空输入，放弃"; exit 1; }
    _AK="$_SECRET"
    umask 077
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    # 逐字段补：缺则问、有则保留（不整体覆盖，保护已有的 GH_TOKEN/GH_USER）
    sed -i '/^export TS_AUTHKEY=/d' "$ENV_FILE"
    printf 'export TS_AUTHKEY=%s\n' "$_AK" >> "$ENV_FILE"
    if [ -z "${TS_HOSTNAME:-}" ]; then
      read -r -p "  TS_HOSTNAME (本机唯一名，默认 vps-$(uname -n | cut -c1-8)): " _HN
      _HN="${_HN:-vps-$(uname -n | cut -c1-8)}"
      printf 'export TS_HOSTNAME=%s\n' "$_HN" >> "$ENV_FILE"
    fi
    if [ -z "${TS_TAGS:-}" ]; then
      read -r -p "  TS_TAGS (可选，留空=不加；仅当 tailnet ACL 的 tagOwners 已定义才填，如 tag:vps): " _TG
      [ -n "$_TG" ] && [ "$_TG" != "-" ] && printf 'export TS_TAGS=%s\n' "$_TG" >> "$ENV_FILE"
    fi
    if [ -z "${GH_TOKEN:-}" ]; then
      if read_secret "  GH_TOKEN (github_pat_…，私仓用；无则直接回车跳过): " "github_pat_" "ghp_"; then
        printf 'export GH_TOKEN=%s\n' "$_SECRET" >> "$ENV_FILE"
        grep -q '^export GH_USER=' "$ENV_FILE" || printf 'export GH_USER=dff652\n' >> "$ENV_FILE"
      fi
    fi
    chmod 600 "$ENV_FILE"
    ok "$ENV_FILE 已补全 (chmod 600)"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  else
    bad "无终端无法交互补 $ENV_FILE。手动追加缺失字段后重跑:"
    echo "    echo 'export TS_AUTHKEY=tskey-auth-xxx' >> $ENV_FILE"
    echo "    echo 'export TS_HOSTNAME=vps-$(uname -n | cut -c1-8)' >> $ENV_FILE"
    echo "    # 或从家里 vault 整体拷回:"
    echo "    scp root@192.168.2.123:/root/ts-vault/<name>/.ts_env $ENV_FILE && chmod 600 $ENV_FILE"
    exit 1
  fi
fi
[ -n "${TS_AUTHKEY:-}" ] || { bad "$ENV_FILE 仍缺 TS_AUTHKEY"; exit 1; }
# 校验前缀：tailscale auth key 应以 tskey- 开头。常见误粘 github_pat_（GH_TOKEN）。
# 前缀错时交互直接回到输入（与 step3 一致），不再 exit 让你手动 sed。
while [ "${TS_AUTHKEY#tskey-}" = "$TS_AUTHKEY" ]; do
  bad "TS_AUTHKEY 前缀 '${TS_AUTHKEY:0:12}...' 不是 tskey-（疑似误粘 GH_TOKEN）"
  if [ -t 0 ]; then
    read_secret "  重新粘 TS_AUTHKEY（tskey-auth-…，直接回车=放弃）: " "tskey-auth-" "tskey-" \
      || { bad "放弃"; exit 1; }
    TS_AUTHKEY="$_SECRET"
    umask 077; sed -i '/^export TS_AUTHKEY=/d' "$ENV_FILE"
    printf 'export TS_AUTHKEY=%s\n' "$TS_AUTHKEY" >> "$ENV_FILE"; chmod 600 "$ENV_FILE"
    ok ".ts_env 的 TS_AUTHKEY 已更新"
  else
    echo "    修正: sed -i '/^export TS_AUTHKEY=/d' $ENV_FILE"
    echo "          read -rs K   # 单独跑，粘真正的 tskey-auth-xxx 回车"
    echo "          printf 'export TS_AUTHKEY=%s\\n' \"\$K\" >> $ENV_FILE && bash $0"
    exit 1
  fi
done
HOSTNAME_USE="${TS_HOSTNAME:-$(uname -n)}"
EXIT_NODE="${BOOT_EXIT_NODE:-gl-mt2500-3}"
ok "TS_AUTHKEY 已加载 (前缀 ${TS_AUTHKEY:0:12}...)"
ok "hostname=$HOSTNAME_USE   exit-node=$EXIT_NODE   repo=$REPO_DIR"

# env 子命令：只补/建 .ts_env，不跑后续流程（避免手敲 heredoc 易错）
if [ "$ONLY_ENV" -eq 1 ]; then
  hr "仅配置 .ts_env 模式 — 完成"
  echo "  字段一览（值脱敏）:"
  sed 's/=.*/=<已设>/' "$ENV_FILE" | sed 's/^/    /'
  echo
  echo "  要改某字段（如换 key）：先删旧行再重跑 env，例如"
  echo "    sed -i '/^export TS_AUTHKEY=/d' $ENV_FILE && bash $0 env"
  echo "  配好后跑完整流程：bash $0"
  exit 0
fi

# ---------- 1. tailscale 二进制 ----------
hr "1. tailscale 二进制"
if command -v tailscale >/dev/null 2>&1; then
  ok "已装: $(tailscale version 2>/dev/null | head -1)"
else
  warn "未装，从 pkgs.tailscale.com 直装（此时还没代理，靠本机直连 CDN）"
  if command -v dnf >/dev/null 2>&1; then
    cat > /etc/yum.repos.d/tailscale.repo <<'REPO'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/rhel/9/$basearch
enabled=1
gpgcheck=0
REPO
    dnf install -y tailscale >/dev/null 2>&1 && ok "装好" || { bad "装失败，检查能否直连 pkgs.tailscale.com"; exit 1; }
  else
    curl -fsSL https://tailscale.com/install.sh | sh || { bad "install.sh 失败"; exit 1; }
  fi
fi

# ---------- 2. tailscaled 进程（inline userspace）----------
hr "2. tailscaled 进程 (userspace)"
if pgrep -x tailscaled >/dev/null; then
  ok "已在跑 (pid $(pgrep -x tailscaled | tr '\n' ' '))"
else
  mkdir -p "$(dirname "$TSD_LOG")"
  nohup tailscaled \
    --tun=userspace-networking \
    --socks5-server="localhost:${SOCKS_PORT}" \
    --outbound-http-proxy-listen="localhost:${HTTP_PORT}" \
    > "$TSD_LOG" 2>&1 &
  sleep 2
  pgrep -x tailscaled >/dev/null && ok "已启动 (SOCKS5 :$SOCKS_PORT, HTTP :$HTTP_PORT)" \
    || { bad "启动失败，最后 20 行日志:"; tail -n 20 "$TSD_LOG"; exit 1; }
fi

# ---------- 3. tailnet 登录（inline，不传废弃的 --ephemeral）----------
hr "3. tailnet 登录"
STATE="$(ts_state)"
if [ "$STATE" = "Running" ]; then
  ok "已 Running，不重复 up"
else
  while :; do
    echo "  执行: tailscale up --auth-key=*** --hostname=$HOSTNAME_USE ${TS_TAGS:+--advertise-tags=$TS_TAGS} --accept-routes (--reset)"
    # shellcheck disable=SC2086
    up_out="$(tailscale up \
      --auth-key="$TS_AUTHKEY" \
      --hostname="$HOSTNAME_USE" \
      ${TS_TAGS:+--advertise-tags="$TS_TAGS"} \
      --accept-routes \
      --reset 2>&1)"
    [ -n "$up_out" ] && printf '%s\n' "$up_out" | sed 's/^/    /'
    sleep 2
    STATE="$(ts_state)"
    if [ "$STATE" = "Running" ]; then
      ok "登录成功，IP: $(tailscale ip -4 2>/dev/null | head -1)"; break
    fi

    # 按错误类型分流：tag 问题 ≠ key 问题，不能都让你重输 key
    if printf '%s' "$up_out" | grep -qi "requested tags"; then
      bad "tag '${TS_TAGS:-}' 在你 tailnet 的 ACL 里没定义/不允许 —— 这不是 key 的问题，重输 key 没用"
      if [ -z "${TS_TAGS:-}" ]; then bad "已无 tag 仍报 tag 错，异常，看上面输出"; exit 1; fi
      if [ -t 0 ]; then
        read -r -p "  去掉 tag 重试? [Y=去掉(key 不变) / n=放弃]: " _c
        case "$_c" in
          ""|y|Y) : ;;
          *) bad "放弃；想保留 tag 请在 tailnet ACL 的 tagOwners 里加 ${TS_TAGS}"; exit 1 ;;
        esac
      else
        warn "非交互：自动去掉 TS_TAGS 重试"
      fi
      sed -i '/^export TS_TAGS=/d' "$ENV_FILE"; TS_TAGS=""
      ok "已去掉 TS_TAGS，用同一把 key 重试登录"
      continue
    fi

    if printf '%s' "$up_out" | grep -qiE "invalid key|not valid|expired"; then
      bad "key 失效/过期/属于别的 tailnet"
      if [ -t 0 ]; then
        echo "  先在 https://login.tailscale.com/admin/machines 确认能看到 gl-mt2500-3（= 账号/tailnet 选对了）"
        read_secret "  重新粘一把 TS_AUTHKEY（tskey-auth-…，直接回车=放弃）: " "tskey-auth-" "tskey-" \
          || { bad "放弃登录"; exit 1; }
        TS_AUTHKEY="$_SECRET"
        umask 077; sed -i '/^export TS_AUTHKEY=/d' "$ENV_FILE"
        printf 'export TS_AUTHKEY=%s\n' "$TS_AUTHKEY" >> "$ENV_FILE"; chmod 600 "$ENV_FILE"
        ok ".ts_env 的 TS_AUTHKEY 已更新；logout 清旧 session 后用新 key 真登录"
        tailscale logout >/dev/null 2>&1 || true
        continue
      fi
      bad "非交互无法重输。手动: sed -i '/^export TS_AUTHKEY=/d' $ENV_FILE && bash $0"; exit 1
    fi

    # 其它未识别失败
    bad "登录失败（状态=$STATE），未识别错误，看上面输出 / $TSD_LOG"
    tail -n 12 "$TSD_LOG" 2>/dev/null | sed 's/^/    /'
    exit 1
  done
fi

# 登录后校验账号/tailnet 选对没：看不到 exit-node 多半是 key 来自别的账号
if ! tailscale status 2>/dev/null | grep -qw "$EXIT_NODE"; then
  warn "登录成功，但 tailnet 里看不到 $EXIT_NODE —— 这把 key 可能来自**别的账号/tailnet**"
  warn "对照 https://login.tailscale.com/admin/machines 应能看到 $EXIT_NODE；不对就换对账号的 key：bash $0 reset"
fi

# ---------- 4. exit node（inline）----------
if [ "$DO_EXIT" -eq 1 ]; then
  hr "4. 借 $EXIT_NODE 出网 (exit node)"
  if tailscale status 2>/dev/null | grep -qw "$EXIT_NODE"; then
    if tailscale set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=true --accept-routes=true 2>/dev/null; then
      ok "已设 exit-node=$EXIT_NODE"
    else
      warn "tailscale set exit-node 失败（$EXIT_NODE 可能没在 admin 面板批准 Use as exit node）"
    fi
  else
    warn "tailnet 里看不到 $EXIT_NODE，跳过（不影响 tailnet 内访问）"
  fi
else
  hr "4. exit node (--no-exit 跳过)"
fi

# ---------- 5. git 凭据 + 代理（inline）----------
hr "5. git 凭据 + 代理"
if [ -n "${GH_TOKEN:-}" ]; then
  umask 077
  echo "https://${GH_USER:-dff652}:${GH_TOKEN}@github.com" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  git config --global credential.helper "store --file=$CRED_FILE"
  git config --global http.proxy  "socks5h://localhost:${SOCKS_PORT}"
  git config --global https.proxy "socks5h://localhost:${SOCKS_PORT}"
  ok "git 凭据 + proxy 配好 (socks5h://localhost:$SOCKS_PORT)"
else
  warn "$ENV_FILE 没 GH_TOKEN，跳过 git 凭据（私仓 pull 会要密码）"
fi

# ---------- 6. git pull 自更新仓库（解决 stale-repo）----------
if [ "$DO_PULL" -eq 1 ] && [ -d "$REPO_DIR/.git" ]; then
  hr "6. git pull 自更新 $REPO_DIR（修复旧脚本）"
  while :; do
    before="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"
    pull_out="$(git -C "$REPO_DIR" pull --ff-only 2>&1)"; pull_rc=$?
    printf '%s\n' "$pull_out" | sed 's/^/  /'
    if [ "$pull_rc" -eq 0 ]; then
      after="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)"
      [ "$before" = "$after" ] && ok "已是最新 ($after)" || ok "更新 $before → $after（下次重启用新脚本）"
      break
    fi
    # 区分认证失败 vs 网络/冲突：只有认证类才回到 GH_TOKEN 输入（网络抖动不该烦你重输）
    if printf '%s' "$pull_out" | grep -qiE "authentication failed|invalid username or token|could not read username|40[13]|repository not found|permission denied|access denied"; then
      bad "git pull 认证失败 —— GH_TOKEN 可能错/过期/权限不足（需 Contents: Read-only）"
      if [ -t 0 ]; then
        echo "  到 https://github.com/settings/personal-access-tokens 重生 fine-grained PAT（只给 dff652/homelab 的 Contents: Read-only）"
        read_secret "  重新粘一把 GH_TOKEN（github_pat_…，直接回车=放弃 pull）: " "github_pat_" "ghp_" \
          || { warn "跳过 git 自更新，继续用本地版本"; break; }
        GH_TOKEN="$_SECRET"
        umask 077
        sed -i '/^export GH_TOKEN=/d' "$ENV_FILE"
        printf 'export GH_TOKEN=%s\n' "$GH_TOKEN" >> "$ENV_FILE"
        grep -q '^export GH_USER=' "$ENV_FILE" || printf 'export GH_USER=dff652\n' >> "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        echo "https://${GH_USER:-dff652}:${GH_TOKEN}@github.com" > "$CRED_FILE"; chmod 600 "$CRED_FILE"
        ok ".ts_env + 凭据已更新，重试 pull"
        continue
      fi
      warn "非交互无法重输 GH_TOKEN，跳过；手动改 $ENV_FILE 后重跑"
      break
    fi
    warn "git pull 失败（网络/冲突，非认证问题），继续用本地版本"
    break
  done
elif [ "$DO_PULL" -eq 0 ]; then
  hr "6. git pull (--no-pull 跳过)"
else
  hr "6. git pull"
  warn "$REPO_DIR 不是 git 仓，跳过；如需 clone 跑: bash $REPO_DIR/vps/setup_git_auth.sh restore"
fi

# ---------- 7. 验证 ----------
hr "7. 连通性验证"
echo "  tailscale ping istoreos:"
# tailscale ping 拿到 pong 后仍会试建直连，可能拖到 timeout 被 kill，
# 退出码非 0 不代表失败 —— 以输出里有没有 pong 为准。
ping_out="$(timeout 8 tailscale ping -c 2 istoreos 2>&1)"
printf '%s\n' "$ping_out" | sed 's/^/    /'
case "$ping_out" in
  *pong*) ok "istoreos 可达" ;;
  *)      warn "ping istoreos 无 pong（看上面输出）" ;;
esac

if [ -n "${GH_TOKEN:-}" ]; then
  echo "  出口 IP (走 SOCKS5):"
  ip="$(curl -s -m 12 --socks5-hostname "localhost:$SOCKS_PORT" https://myip.ipip.net 2>/dev/null)"
  [ -n "$ip" ] && echo "    $ip" || warn "出口探测无响应"
fi

# ---------- 总结 ----------
hr "完成"
cat <<EOF
  本节点: $HOSTNAME_USE  IP: $(tailscale ip -4 2>/dev/null | head -1)
  状态:   $(ts_state)
  日志:   $LOG

  常用后续:
    git -C $REPO_DIR pull                                          # 手动更新仓库
    curl --socks5-hostname localhost:$SOCKS_PORT https://api.ipify.org   # 看出口
    bash $REPO_DIR/vps/diag_tailscale_to_istoreos.sh              # 完整诊断

  建议拷到 /root（持久化，/data 万一没了也能起步）:
    cp $REPO_DIR/vps/recover.sh /root/recover.sh
EOF
