#!/usr/bin/env bash
# add-realm-landing.sh —— 交互式给 Realm 中转机追加一台「落地机」转发
#
# 用途：在中转机（如 Vultr）上，为新的落地机开一个监听端口、放行防火墙、
#       拉起一个独立的 realm 进程做 TCP 转发，并产出可导入 Clash 的 vless 链接。
#
# 设计约定（见仓库 CLAUDE.md / relay/README.md）：
#   - 不碰已有 realm 进程：每台落地一个独立进程，旧的零影响。
#   - 幂等：端口被占/落地已转发会拦下；防火墙规则先查再加。
#   - 结论判定：[OK] 通 / [WARN] 能继续但注意 / [!] 失败。
#   - secrets（UUID/pbk/sid）优先读环境变量；不写进日志；最终链接只落到 600 文件 + 终端。
#   - 支持非交互：非 tty 时全部走环境变量，缺一即报错退出。
#   - 日志覆盖写（不带 -a）：tee /var/log/add-realm-landing.log。
#
# 落地参数三种来源（择一）：
#   ① SUB_URL=vless://… —— 直接粘 vless 链接，解析最准最省事（推荐）
#   ② SUB_URL=http://…  —— 落地 Clash 订阅，自动 curl + 解析 proxy（需含内联节点）
#   ③ 手动逐项：LANDING_IP LANDING_PORT UUID PBK SNI SID FP
# 子命令：add(默认) | install [版本] | list | remove <端口|名称> | build [simple|urltest] | -v | -h
#   install：缺 realm 时自动下载安装（zhboner/realm，按架构）；add 时若缺也会提示自动装
# 环境变量（设了就跳过对应交互提问）：
#   REALM_BIN(默认 /root/realm)  NODE_DIR(默认 /root/realm-nodes)  RELAY_IP(默认自动探测)
#   SUB_URL  LANDING_NAME  LANDING_PORT/上述落地参数  LISTEN_PORT  FLOW(默认 vision)  NETWORK(默认 tcp)  FP(默认 chrome)
#   NO_SYSTEMD=1 强制用 nohup（默认有 systemd 就建 service 自启）

set -uo pipefail

VERSION="1.7.0"
REALM_BIN="${REALM_BIN:-/root/realm}"
NODE_DIR="${NODE_DIR:-/root/realm-nodes}"
LOG="/var/log/add-realm-landing.log"

say()  { echo "$*"; }
ok()   { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[!] $*"; }
die()  { err "$*"; exit 1; }

mask() { local s=$1; [ ${#s} -le 8 ] && { echo '****'; return; }; echo "${s:0:4}…${s: -4}"; }

# ask VAR "提示" [默认值] —— 已有同名环境变量则沿用；非交互且缺值则退出。
ask() {
  local var=$1 prompt=$2 def=${3:-} cur val
  cur="${!var:-}"
  if [ -n "$cur" ]; then say "  $prompt = (取自环境变量)"; return; fi
  if [ ! -t 0 ]; then                         # 非交互：有默认值就用默认，否则报错退出
    [ -n "$def" ] && { printf -v "$var" '%s' "$def"; return; }
    die "非交互模式下未提供环境变量 $var"
  fi
  read -rp "  ${prompt}${def:+ [$def]}: " val
  printf -v "$var" '%s' "${val:-$def}"
}

is_port()  { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_ip()    { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_host()  { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
# vless 结构校验：vless://<uuid>@<host>:<port> 且带 ? 查询串
is_vless() { [[ $1 =~ ^vless://[^@/]+@[^:/]+:[0-9]+\? ]]; }
# flow 合法值（防链接被终端换行截断成 flow=x 之类）
flow_ok()  { [ -z "$1" ] || [[ $1 =~ ^xtls-rprx-vision(-udp443)?$ ]]; }
# 落地名校验：非空、≤40、不含链接残留字符（@ # : / 空白）
name_ok()  { [ -n "$1" ] && [ ${#1} -le 40 ] && [[ ! $1 =~ [@#:/[:space:]] ]]; }

port_listening() { ss -tlnH "sport = :$1" 2>/dev/null | grep -q .; }
realm_has_listen() { pgrep -af '[r]ealm' | grep -q -- "-l 0.0.0.0:$1\b"; }
realm_has_remote() { pgrep -af '[r]ealm' | grep -q -- "-r $1:$2\b"; }

# systemd：可用且未被 NO_SYSTEMD 禁用时，新转发走 service（开机自启）；否则回退 nohup。
SYSTEMD_DIR=/etc/systemd/system
use_systemd() { [ -z "${NO_SYSTEMD:-}" ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }
unit_active() { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$1"; }
unit_exists() { command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^$1\b"; }

# tcp_probe HOST PORT [超时秒] —— 纯 L4 连通性探测（不依赖 nc，用 bash /dev/tcp）。
tcp_probe() { timeout "${3:-5}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# parse_vless URI —— 解析 vless://UUID@HOST:PORT?query#name，落地参数写入全局变量。
parse_vless() {
  local body q name v
  body="${1#vless://}"
  case "$body" in *#*) name="${body##*#}"; body="${body%%#*}";; *) name="";; esac
  SUBNAME="$name"
  case "$body" in *\?*) q="${body#*\?}"; body="${body%%\?*}";; *) q="";; esac
  UUID="${body%%@*}"
  local hp="${body#*@}"
  LANDING_IP="${hp%%:*}"; LANDING_PORT="${hp##*:}"
  qget() { printf '%s' "$q" | tr '&' '\n' | grep -m1 -E "^$1=" | cut -d= -f2-; }
  SNI="$(qget sni)"; PBK="$(qget pbk)"; SID="$(qget sid)"
  v="$(qget flow)"; [ -n "$v" ] && FLOW="$v"
  v="$(qget type)"; [ -n "$v" ] && NETWORK="$v"
  v="$(qget fp)";   [ -n "$v" ] && FP="$v"
}

# yval KEY —— 从订阅 YAML 文本 $SUB_YAML 里取首个 `KEY:` 的值（去引号/注释/空白）。
# 够用于单节点 Clash Meta 订阅；多节点时取第一个。
yval() {
  grep -m1 -E "^[[:space:]]*(-[[:space:]]+)?$1:[[:space:]]*\S" <<<"$SUB_YAML" 2>/dev/null \
    | sed -E "s/^[[:space:]]*(-[[:space:]]+)?$1:[[:space:]]*//; s/^[\"']//; s/[\"',]*[[:space:]]*(#.*)?$//"
}

# ---- 节点文件 ↔ 端口 互查（list/remove 用）----
node_name_for_port() {
  local port=$1 f
  for f in "$NODE_DIR"/*.txt; do
    [ -e "$f" ] || continue
    grep -q "@[^?]*:$port?" "$f" 2>/dev/null && { basename "$f" .txt; return; }
  done
}

do_list() {
  say "当前 Realm 转发（监听端口 → 落地）："
  local pid args lp rp port name mgr found=0
  while read -r pid args; do
    lp=$(grep -oE -- '-l [^ ]+' <<<"$args" | head -1 | awk '{print $2}')
    rp=$(grep -oE -- '-r [^ ]+' <<<"$args" | head -1 | awk '{print $2}')
    [ -z "$lp" ] && continue
    found=1; port=${lp##*:}; name=$(node_name_for_port "$port")
    mgr="[nohup]"; [ -n "$name" ] && unit_exists "realm-$name.service" && mgr="[systemd]"
    printf '  · 端口 %-6s → %-22s  pid=%-7s %-9s %s\n' "$port" "$rp" "$pid" "$mgr" "${name:+名称=$name}"
  done < <(pgrep -af '[r]ealm')
  [ "$found" = 0 ] && say "  （无）"
  return 0
}

do_remove() {
  local arg=${1:-} port name pids
  [ -z "$arg" ] && die "用法：$0 remove <监听端口|落地名称>"
  if is_port "$arg"; then
    port=$arg; name=$(node_name_for_port "$port")
  else
    name=$arg
    [ -e "$NODE_DIR/$name.txt" ] || die "找不到名称 $name 的节点文件（$NODE_DIR/$name.txt）"
    port=$(grep -oE '@[^?]*:[0-9]+\?' "$NODE_DIR/$name.txt" | grep -oE '[0-9]+' | tail -1)
    [ -z "$port" ] && die "无法从 $NODE_DIR/$name.txt 解析端口"
  fi
  local unit=""; [ -n "$name" ] && unit="realm-$name.service"
  pids=$(pgrep -af '[r]ealm' | grep -- "-l 0.0.0.0:$port\b" | awk '{print $1}')
  say "将删除转发：端口 $port ${name:+（名称 $name）}"
  [ -n "$unit" ] && unit_exists "$unit" && say "  systemd 服务：$unit"
  [ -n "$pids" ] && say "  realm 进程：$pids" || warn "  未发现监听 $port 的 realm 进程（可能已停）"
  if [ -t 0 ] && [ -z "${ASSUME_YES:-}" ]; then
    read -rp "确认删除？仅删这一条，其它转发不动。(y/N): " yn
    [[ $yn =~ ^[Yy]$ ]] || die "已取消"
  fi
  # systemd 服务优先停用 + 删 unit（含开机自启）
  if [ -n "$unit" ] && unit_exists "$unit"; then
    systemctl disable --now "$unit" >/dev/null 2>&1 && ok "已停用 systemd 服务 $unit"
    rm -f "$SYSTEMD_DIR/$unit" && systemctl daemon-reload 2>/dev/null
  fi
  # 残留 nohup 进程（systemd 停用后通常已无）
  pids=$(pgrep -af '[r]ealm' | grep -- "-l 0.0.0.0:$port\b" | awk '{print $1}')
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null && ok "已停 realm 进程 $pids" || warn "停进程失败（需 root？）"
  fi
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qE "^${port}/tcp\b"; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 && ok "ufw 删除 ${port}/tcp" || warn "ufw 删除失败"
  fi
  while iptables -C INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null && ok "iptables 删除 dport $port 一条" || break
  done
  if [ -n "$name" ] && { [ -e "$NODE_DIR/$name.txt" ] || [ -e "$NODE_DIR/$name.yaml" ]; }; then
    rm -f "$NODE_DIR/$name.txt" "$NODE_DIR/$name.yaml" && ok "已删产物 $name.{txt,yaml}"
  fi
  ok "remove 完成。其它转发未受影响。"
}

# 汇总所有 proxy 片段成一份完整 Clash 配置。fmt：simple(默认) | urltest
do_build() {
  local fmt=${1:-simple} f n out names=() files=()
  case "$fmt" in simple|urltest) : ;; *) die "未知格式：$fmt（可选 simple | urltest）" ;; esac
  shopt -s nullglob; files=("$NODE_DIR"/*.yaml); shopt -u nullglob
  out="$NODE_DIR/clash-all.yaml"
  local list=()
  for f in "${files[@]}"; do [ "$f" = "$out" ] && continue; list+=("$f"); done
  [ ${#list[@]} -eq 0 ] && die "没有可用的 proxy 片段（$NODE_DIR/*.yaml 为空），先 add 几台落地"
  umask 077
  {
    echo "proxies:"
    for f in "${list[@]}"; do
      grep -v '^[[:space:]]*#' "$f"
      n=$(grep -m1 -E '^[[:space:]]*-[[:space:]]*name:' "$f" | sed -E 's/.*name:[[:space:]]*//; s/^"//; s/"$//')
      names+=("$n")
    done
    echo
    echo "proxy-groups:"
    if [ "$fmt" = urltest ]; then
      echo "  - name: ♻️ 自动选择"
      echo "    type: url-test"
      echo "    url: http://www.gstatic.com/generate_204"
      echo "    interval: 300"
      echo "    proxies:"
      for n in "${names[@]}"; do echo "      - \"$n\""; done
    fi
    echo "  - name: 🚀 节点选择"
    echo "    type: select"
    echo "    proxies:"
    [ "$fmt" = urltest ] && echo "      - ♻️ 自动选择"
    for n in "${names[@]}"; do echo "      - \"$n\""; done
    echo "      - DIRECT"
    echo
    echo "rules:"
    echo "  - GEOIP,CN,DIRECT"
    echo "  - MATCH,🚀 节点选择"
  } > "$out"
  chmod 600 "$out"
  ok "已生成汇总配置（$fmt 格式，${#names[@]} 个节点，chmod 600）：$out"
  say "  含节点：${names[*]}"
  say "  （含 secrets，别 scp 进会被 track 的位置；导入 Clash Verge 用 Local profile）"
}

# 安装/更新 realm 到 $REALM_BIN（zhboner/realm release）。幂等：已装且能跑则跳过（FORCE=1 强装）。
install_realm() {
  local ver="${1:-}" arch tag url tmp bin
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64-unknown-linux-gnu ;;
    aarch64|arm64) arch=aarch64-unknown-linux-gnu ;;
    *) die "不支持的架构 $(uname -m)；手动装 realm 后用 REALM_BIN= 指定" ;;
  esac
  if [ -x "$REALM_BIN" ] && "$REALM_BIN" --version >/dev/null 2>&1 && [ -z "${FORCE:-}" ]; then
    ok "realm 已安装：$("$REALM_BIN" --version 2>&1 | head -1)（跳过；FORCE=1 可强装）"; return 0
  fi
  command -v curl >/dev/null || die "缺 curl，无法下载 realm"
  command -v tar  >/dev/null || die "缺 tar，无法解压 realm"
  tag="$ver"
  [ -z "$tag" ] && tag="$(curl -fsSL --max-time 15 https://api.github.com/repos/zhboner/realm/releases/latest 2>/dev/null \
                          | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$tag" ] || die "取不到 realm 最新版本号；用 'install <版本>' 指定，如 install v2.7.0"
  url="https://github.com/zhboner/realm/releases/download/${tag}/realm-${arch}.tar.gz"
  say "下载 realm ${tag}（${arch}）…"
  tmp="$(mktemp -d)"
  curl -fsSL --max-time 90 "$url" -o "$tmp/realm.tar.gz" || { rm -rf "$tmp"; die "下载失败：$url（网络？或换 'install <版本>'）"; }
  tar -xzf "$tmp/realm.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "解压失败"; }
  bin="$(find "$tmp" -name realm -type f 2>/dev/null | head -1)"
  [ -n "$bin" ] || { rm -rf "$tmp"; die "包里没找到 realm 二进制"; }
  mkdir -p "$(dirname "$REALM_BIN")"
  install -m 0755 "$bin" "$REALM_BIN" 2>/dev/null || { cp "$bin" "$REALM_BIN" && chmod +x "$REALM_BIN"; }
  rm -rf "$tmp"
  "$REALM_BIN" --version >/dev/null 2>&1 \
    && ok "realm 安装成功 → $REALM_BIN（$("$REALM_BIN" --version 2>&1 | head -1)）" \
    || die "已落地但 $REALM_BIN --version 跑不起来（架构不符？换版本重试）"
}

# ---- 子命令分发（add 为默认；list/remove/build/install/-v/-h 不写 add 日志）----
case "${1:-}" in
  -v|--version) echo "add-realm-landing.sh v$VERSION"; exit 0 ;;
  -h|--help)    echo "用法：$0 [add] | install [版本] | list | remove <端口|名称> | build [simple|urltest] | -v"; exit 0 ;;
  install)      shift; install_realm "${1:-}"; exit 0 ;;
  list)         do_list; exit 0 ;;
  remove)       shift; do_remove "${1:-}"; exit 0 ;;
  build)        shift; do_build "${1:-simple}"; exit 0 ;;
  add)          shift ;;
  "")           : ;;
  *)            die "未知子命令：$1（用法：add | install [版本] | list | remove <端口|名称> | build [simple|urltest] | -v）" ;;
esac

# 仅「添加」流程：日志覆盖写（不带 -a）；fd 3 留给不入日志的敏感输出（链接/片段）。
exec 3>&1
exec > >(tee "$LOG") 2>&1

say "============ Realm 落地追加  (v$VERSION) ============"

# ---- 0. 前置检查（缺 realm 可自动装）----
if [ ! -x "$REALM_BIN" ]; then
  warn "未找到 realm：$REALM_BIN"
  if [ -n "${ASSUME_YES:-}" ]; then install_realm
  elif [ -t 0 ]; then read -rp "自动下载安装 realm？(Y/n): " a; [[ $a =~ ^[Nn]$ ]] && die "realm 未安装。跑 '$0 install' 装，或 REALM_BIN= 指定已有的" || install_realm
  else die "realm 未安装（非交互）。先跑 '$0 install'，或设 REALM_BIN= 指定"; fi
fi
command -v ss >/dev/null   || die "缺少 ss（iproute2）"
command -v ufw >/dev/null  || warn "未装 ufw，将只用 iptables 放行"

# ---- 1. 展示现状（已有转发，绝不触碰）----
say
say "当前 realm 转发（这些进程本脚本不会动）："
if pgrep -af '[r]ealm' | grep -q -- '-l '; then
  pgrep -af '[r]ealm' | sed -E 's/.*(-l [^ ]+).*(-r [^ ]+).*/  · \1 \2/' | sort -u
else
  say "  （无）"
fi

# ---- 2. 中转机公网 IP（拼客户端链接用）----
RELAY_IP="${RELAY_IP:-$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || true)}"
say
ask RELAY_IP "中转机公网 IP（客户端要连的地址）" "$RELAY_IP"
is_ip "$RELAY_IP" || warn "中转机 IP 形如 1.2.3.4，当前：$RELAY_IP（继续，但请确认）"

# ---- 3. 落地信息：vless:// 链接 / http 订阅 自动解析（格式不对则重输），留空则手动逐项 ----
FLOW="${FLOW:-xtls-rprx-vision}"; NETWORK="${NETWORK:-tcp}"
say
have_essentials() { [ -n "${LANDING_IP:-}" ] && [ -n "${LANDING_PORT:-}" ] && [ -n "${UUID:-}" ] && [ -n "${PBK:-}" ] && [ -n "${SNI:-}" ]; }

SRC_ENV="${SUB_URL:-}"   # 来源是否来自环境变量（决定失败时是 die 还是重输）
FROM_SUB=0
while :; do
  # 取来源：env 优先；否则交互提问；非交互无 env 则视为留空（手动）
  if [ -n "$SRC_ENV" ]; then SUB_URL="$SRC_ENV"
  elif [ -t 0 ]; then read -rp "  落地来源：粘贴 vless:// 链接 或 http 订阅（留空=手动逐项输入）: " SUB_URL
  else SUB_URL=""; fi
  [ -z "$SUB_URL" ] && break   # 留空 → 手动模式

  reason=""
  case "$SUB_URL" in
    vless://*)
      if ! is_vless "$SUB_URL"; then
        reason="vless 链接格式不对，应形如 vless://UUID@HOST:PORT?security=reality&..."
      else
        parse_vless "$SUB_URL"
        if ! have_essentials; then
          reason="vless 链接缺关键字段（需含 sni= 与 pbk=）"
        elif ! flow_ok "$FLOW"; then
          reason="flow 值异常（$FLOW）——链接可能被终端换行截断，请把整条链接一行粘贴重输"
        else
          FROM_SUB=1
          ok "已从 vless 链接解析：$LANDING_IP:$LANDING_PORT  uuid=$(mask "$UUID")  sni=$SNI  sid=$(mask "$SID")  flow=$FLOW"
        fi
      fi
      ;;
    http://*|https://*)
      say "  抓取订阅中…"
      SUB_YAML="$(curl -fsSL --max-time 10 -H 'User-Agent: clash-verge' "$SUB_URL" 2>/dev/null || true)"
      if [ -z "$SUB_YAML" ]; then
        reason="订阅抓取失败（不可达 / 需登录 / 超时）"
      elif ! grep -q 'proxies:' <<<"$SUB_YAML"; then
        reason="订阅未返回 Clash YAML（找不到 proxies:）"
      else
        n=$(grep -cE '^[[:space:]]*-[[:space:]]*(name|\{)' <<<"$SUB_YAML")
        [ "${n:-0}" -gt 1 ] && warn "订阅含 $n 个节点，默认取第一个；要指定别的请改用 vless 链接或手动"
        LANDING_IP="$(yval server)";   LANDING_PORT="$(yval port)"
        UUID="$(yval uuid)";           PBK="$(yval public-key)"
        SNI="$(yval servername)";      [ -z "$SNI" ] && SNI="$(yval sni)"
        SID="$(yval short-id)"
        f="$(yval flow)";              [ -n "$f" ]  && FLOW="$f"
        nw="$(yval network)";          [ -n "$nw" ] && NETWORK="$nw"
        fpv="$(yval client-fingerprint)"; [ -n "$fpv" ] && FP="$fpv"
        SUBNAME="$(yval name)"
        if ! have_essentials; then
          reason="订阅缺关键字段（server/port/uuid/pbk/sni 有空，可能是 proxy-providers 模板）"
        elif ! flow_ok "$FLOW"; then
          reason="flow 值异常（$FLOW），订阅解析疑似出错"
        else
          FROM_SUB=1
          ok "已从订阅解析：$LANDING_IP:$LANDING_PORT  uuid=$(mask "$UUID")  sni=$SNI  flow=$FLOW"
        fi
      fi
      ;;
    *)
      reason="无法识别：来源须以 vless:// 或 http(s):// 开头（留空=手动）"
      ;;
  esac

  [ "$FROM_SUB" = 1 ] && break
  err "$reason"
  [ -n "$SRC_ENV" ] && die "环境变量 SUB_URL 无效，请改正；或清空 SUB_URL 改用手动参数重跑"
  [ -t 0 ] || break            # 非交互无 env：转手动
  warn "请重新粘贴来源，或直接回车留空走手动输入"
done

if [ "$FROM_SUB" = 0 ]; then
  say "请逐项填写【落地机】信息（pbk/sni/sid 在落地机 mack-a 节点信息里查）："
  ask LANDING_IP   "落地机公网 IP"
  ask LANDING_PORT "落地机 Reality 监听端口"
  ask UUID "UUID"
  ask PBK  "Reality 公钥 pbk"
  ask SNI  "SNI（serverNames）"
  ask SID  "shortId（sid，可留空）"
  ask FP   "指纹 fp" "chrome"
fi

{ is_ip "$LANDING_IP" || is_host "$LANDING_IP"; } || die "落地地址既非 IP 也非域名：$LANDING_IP"
is_port "$LANDING_PORT" || die "落地端口不合法：$LANDING_PORT"

# 落地名：非法（含链接残留字符/过长）则重输，挡住"粘贴截断串进名称"
NAME_ENV="${LANDING_NAME:-}"
while :; do
  if [ -n "$NAME_ENV" ]; then LANDING_NAME="$NAME_ENV"
  else LANDING_NAME=""; ask LANDING_NAME "落地名称（节点备注/文件名，如 racknerd-2）" "${SUBNAME:-}"; fi
  name_ok "$LANDING_NAME" && break
  err "落地名称非法（含 @#:/ 或空白、或过长）：$LANDING_NAME —— 别把链接粘进名称"
  [ -n "$NAME_ENV" ] && die "环境变量 LANDING_NAME 非法"
  [ -t 0 ] || die "非交互下 LANDING_NAME 非法"
done
SAFENAME="$(printf '%s' "$LANDING_NAME" | tr -c 'A-Za-z0-9._-' '_')"
NODENAME="${SAFENAME}-中转"

# 监听端口：交互时校验失败就重输，直到拿到一个空闲端口；非交互(env)失败即退出。
LISTEN_PORT_ENV="${LISTEN_PORT:-}"
while :; do
  if [ -n "$LISTEN_PORT_ENV" ]; then
    LISTEN_PORT="$LISTEN_PORT_ENV"          # 来自环境变量：只试一次
  else
    LISTEN_PORT=""                          # 清空 → ask 会重新提问
    ask LISTEN_PORT "本中转机要新开的监听端口（如 8889）"
  fi
  reason=""
  if   ! is_port "$LISTEN_PORT";          then reason="端口不合法：$LISTEN_PORT"
  elif realm_has_listen "$LISTEN_PORT";   then reason="已有 realm 进程在监听 $LISTEN_PORT，换一个"
  elif port_listening   "$LISTEN_PORT";   then reason="端口 $LISTEN_PORT 已被占用（ss 可见 LISTEN），换一个"
  fi
  [ -z "$reason" ] && break
  err "$reason"
  [ -n "$LISTEN_PORT_ENV" ] && die "环境变量 LISTEN_PORT=$LISTEN_PORT 不可用，改值重跑"
  warn "请重新输入一个空闲端口"
done

# ---- 4. 幂等 / 冲突校验（监听端口已在上面循环里校验过空闲）----
say
if realm_has_remote "$LANDING_IP" "$LANDING_PORT"; then
  warn "已有 realm 进程转发到 $LANDING_IP:$LANDING_PORT —— 你在为同一落地再开一个入口端口，确认是有意为之"
fi

# ---- 5. 确认摘要（secrets 脱敏，不泄全量到屏幕/日志）----
say
say "------------------- 即将执行 -------------------"
say "  落地名称 : $LANDING_NAME"
say "  转发     : 0.0.0.0:$LISTEN_PORT  →  $LANDING_IP:$LANDING_PORT"
say "  UUID     : $(mask "$UUID")"
say "  pbk      : $(mask "$PBK")"
say "  sni      : $SNI"
say "  sid      : $(mask "$SID")"
say "------------------------------------------------"
if [ -t 0 ] && [ -z "${ASSUME_YES:-}" ]; then
  read -rp "确认添加？(y/N): " yn
  [[ $yn =~ ^[Yy]$ ]] || die "已取消，未做任何改动"
fi

# ---- 6. 放行防火墙（先查再加，幂等）----
say
if command -v ufw >/dev/null; then
  if ufw status | grep -qE "^${LISTEN_PORT}/tcp\b"; then
    ok "ufw 已放行 ${LISTEN_PORT}/tcp，跳过"
  else
    ufw allow "${LISTEN_PORT}/tcp" && ok "ufw 放行 ${LISTEN_PORT}/tcp"
  fi
fi
if iptables -C INPUT -p tcp -m tcp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null; then
  ok "iptables 已有 dport $LISTEN_PORT 规则，跳过"
else
  iptables -A INPUT -p tcp -m tcp --dport "$LISTEN_PORT" -j ACCEPT && ok "iptables 放行 dport $LISTEN_PORT"
fi

# ---- 7. 拉起新 realm（systemd 优先=开机自启；否则 nohup；都不动已有转发）----
say
MANAGED=nohup; NEWPID=""; UNIT=""
if use_systemd; then
  UNIT="realm-${SAFENAME}.service"
  cat > "$SYSTEMD_DIR/$UNIT" <<EOF
[Unit]
Description=Realm relay ${NODENAME} (:${LISTEN_PORT} -> ${LANDING_IP}:${LANDING_PORT})
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${REALM_BIN} -l 0.0.0.0:${LISTEN_PORT} -r ${LANDING_IP}:${LANDING_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if systemctl enable --now "$UNIT" >/dev/null 2>&1; then
    MANAGED=systemd
    ok "已创建并启用 systemd 服务 $UNIT（开机自启）"
  else
    warn "systemd 启用失败，回退 nohup（无开机自启）"
    rm -f "$SYSTEMD_DIR/$UNIT"; UNIT=""
  fi
fi
if [ "$MANAGED" = nohup ]; then
  nohup "$REALM_BIN" -l "0.0.0.0:$LISTEN_PORT" -r "$LANDING_IP:$LANDING_PORT" >/dev/null 2>&1 &
  NEWPID=$!
  warn "以 nohup 启动（重启不自存活）：无 systemd 或被 NO_SYSTEMD 禁用"
fi
sleep 1

# ---- 8. 结论判定 ----
say
alive=0
if [ "$MANAGED" = systemd ]; then unit_active "$UNIT" && alive=1
else kill -0 "$NEWPID" 2>/dev/null && alive=1; fi
if [ "$alive" = 1 ] && port_listening "$LISTEN_PORT"; then
  ok "新转发已起（$MANAGED）：0.0.0.0:$LISTEN_PORT → $LANDING_IP:$LANDING_PORT${NEWPID:+，pid=$NEWPID}"
else
  err "转发未存活或端口未监听，失败"
  [ "$MANAGED" = systemd ] && err "排查：systemctl status $UNIT" \
                           || err "排查：手动跑 $REALM_BIN -l 0.0.0.0:$LISTEN_PORT -r $LANDING_IP:$LANDING_PORT"
  exit 1
fi
say "现存 realm 进程："
pgrep -af '[r]ealm' | sed -E 's/.*(-l [^ ]+).*(-r [^ ]+).*/  · \1 \2/' | sort -u

# ---- 8.5. 连通性自检（L4 可达，不验 Reality 握手）----
say
say "连通性自检（仅 L4 TCP，不代表 Reality 握手成功）："
if tcp_probe "$LANDING_IP" "$LANDING_PORT" 5; then
  ok "中转 → 落地 $LANDING_IP:$LANDING_PORT  TCP 可达"
else
  warn "中转 → 落地 $LANDING_IP:$LANDING_PORT  TCP 不通：落地是否在线 / 端口对不对 / 落地防火墙？（转发已起，但链路不通）"
fi
if tcp_probe 127.0.0.1 "$LISTEN_PORT" 5; then
  ok "经本机转发口 127.0.0.1:$LISTEN_PORT  TCP 通（客户端就走这条）"
else
  warn "经本机转发口 $LISTEN_PORT  不通：realm 转发可能异常"
fi
say "[提示] Reality 握手（sni/pbk/sid 是否匹配）请在客户端导入节点后实测连接确认。"

# ---- 9. 产出：vless 链接 + Clash proxy 片段（含 secrets：600 文件 + 终端，不进日志）----
FP="${FP:-chrome}"
LINK="vless://${UUID}@${RELAY_IP}:${LISTEN_PORT}?encryption=none&security=reality&flow=${FLOW}&pbk=${PBK}&sni=${SNI}&sid=${SID}&fp=${FP}&type=${NETWORK}#${NODENAME}"

mkdir -p "$NODE_DIR"; chmod 700 "$NODE_DIR"
umask 077
TXT="$NODE_DIR/${SAFENAME}.txt"
YML="$NODE_DIR/${SAFENAME}.yaml"
printf '%s\n' "$LINK" > "$TXT"

# Clash Meta proxy 片段：节点地址改写成中转，Reality 参数沿用落地。2 空格缩进可直接贴进 proxies:
cat > "$YML" <<EOF
# ${NODENAME} —— 经中转 ${RELAY_IP}:${LISTEN_PORT} → 落地 ${LANDING_IP}:${LANDING_PORT}
# 用法：把下面整段贴到 Clash 配置 proxies: 列表里，再把 "${NODENAME}" 加进某个 proxy-group。
  - name: "${NODENAME}"
    type: vless
    server: ${RELAY_IP}
    port: ${LISTEN_PORT}
    uuid: ${UUID}
    network: ${NETWORK}
    tls: true
    udp: true
    flow: ${FLOW}
    servername: ${SNI}
    reality-opts:
      public-key: ${PBK}
      short-id: "${SID}"
    client-fingerprint: ${FP}
EOF

say
ok "已生成（均 chmod 600，含 secrets，未写入 $LOG）："
say "  · vless 链接 : $TXT"
say "  · proxy 片段 : $YML"
# fd 3 = 真终端，绕过 tee，不进日志：
{
  echo
  echo "===== vless 链接（订阅转换 / 粘贴用） ====="
  echo "$LINK"
  echo
  echo "===== Clash proxy 片段（贴进 config 的 proxies:） ====="
  cat "$YML"
  echo "======================================================="
} >&3

say
ok "完成。旧转发未受影响。"
[ "$MANAGED" = systemd ] && say "[持久化] 已 systemd 托管，重启自动拉起。" \
                         || say "[持久化] nohup 启动，重启不自存活（装 systemd 或别设 NO_SYSTEMD 可自启）。"
say "[提示] 多落地可跑：$0 list 查看 / $0 build 生成汇总 Clash 配置。"
