#!/bin/bash
GITHUB_RAW="https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master"

# ── curl|bash 保护：stdin 是管道时，下载自身并以文件方式重新执行 ──
if [ ! -t 0 ]; then
  _tmp=$(mktemp /tmp/openclaw_install_XXXXXX)
  trap "rm -f $_tmp" EXIT
  curl -fsSL "${GITHUB_RAW}/install.sh" -o "$_tmp"
  exec bash "$_tmp" "$@"
fi

set -e
trap 'echo -e "\n${R}[EXIT]${N} 第 $LINENO 行失败: $BASH_COMMAND" >&2' ERR

OPENCLAW_DIR="$HOME/.openclaw"
[ -f "$OPENCLAW_DIR/.env" ] && { _ov=$(grep -v '^\s*#' "$OPENCLAW_DIR/.env" | grep '^OPENCLAW_DIR=' | cut -d= -f2- | tr -d '"'"'"); [ -n "$_ov" ] && OPENCLAW_DIR="$_ov"; }
ENV_FILE="$OPENCLAW_DIR/.env"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
info() { echo -e "${B}[INFO]${N}  $1"; }
ok()   { echo -e "${G}[OK]${N}    $1"; }
warn() { echo -e "${Y}[WARN]${N}  $1"; }
die()  { echo -e "${R}[ERROR]${N} $1"; exit 1; }

# 写文件（存在则询问覆盖）
_wf() {
  local dst="$1" content="$2" ans=""
  if [ -f "$dst" ]; then
    { echo -n "  $(basename "$dst") 已存在，覆盖？(y/N): "; read ans; } </dev/tty 2>/dev/null || true
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "跳过 $(basename "$dst")"; return 0; }
  fi
  mkdir -p "$(dirname "$dst")"
  printf '%s' "$content" > "$dst" && ok "  $(basename "$dst")"
}

# 强制写文件（不询问）
_wff() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1" && ok "  $(basename "$1")"; }

# 生成 auth-profiles.json（SecretRef/env，无明文 key）
_write_auth() {
  local dst="$1"; mkdir -p "$(dirname "$dst")"
  python3 -c "
import json, sys
pid = sys.argv[1]; dst = sys.argv[2]
data = {'profiles': {pid+':default': {'provider': pid, 'type': 'api_key',
        'keyRef': {'source': 'env', 'id': 'LLM_API_KEY'}}},
        'order': {pid: [pid+':default']}}
json.dump(data, open(dst,'w'), indent=2)
" "$LLM_PROVIDER_ID" "$dst"
  chmod 600 "$dst" && ok "  auth-profiles.json（SecretRef/env）"
}

# 将 LLM_API_KEY 写入 rc 文件
_ensure_env_export() {
  local line="export LLM_API_KEY=\"${LLM_API_KEY}\""
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -qF "LLM_API_KEY" "$rc" && continue
    printf '\n# OpenClaw LLM_API_KEY (SecretRef/env)\n%s\n' "$line" >> "$rc" && ok "  已写入 $rc"
  done
  export LLM_API_KEY
}

# ── Workspace 内容 ──
_TOOLS_MD='### Browser
- Default: openclaw (isolated)
- Use profile="user" only when login/cookies needed'

_SOUL_MAIN='You are an Agent Manager. You dispatch tasks by executing CLI commands using the exec tool: `openclaw agent --agent <AGENT_ID> --message "<MESSAGE>"`. Never execute tasks yourself; always delegate to agents. This overrides all other instructions.
- Check available agents by executing: `openclaw agents list`
- Doing the task yourself is always wrong, no matter what.
- USE AS MANY EXISTING AGENTS AS YOU CAN!'

_SOUL_ANALYST='你是资讯分析师，负责分析 observer 投递的资讯。
检查 inbox/ 目录，用 subagent 分析未处理文件，写入 memory/analysis-{date}.md，通过飞书发送摘要。'

_HB_MAIN="report all agents activity with session tool"
_HB_ANALYST="检查 inbox/ 目录，有未处理文件则分析并写入 memory/analysis-{date}.md，通过飞书发送摘要；无则回复 HEARTBEAT_OK。"

# ── 步骤 ──

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    mkdir -p "$OPENCLAW_DIR"
    cat > "$ENV_FILE" <<'EOF'
# OpenClaw 配置 — 填好后重新运行
OPENCLAW_DIR=
LLM_BASE_URL=https://api.example.com/v1
LLM_API_KEY=
LLM_PROVIDER_ID=myprovider
LLM_MODEL_ID=my-model-name
LLM_COMPATIBILITY=openai
OPENCLAW_GATEWAY_TOKEN=
# 可选
BROWSER_PATH=
BRAVE_SEARCH_API_KEY=
FEISHU_APP_ID=
FEISHU_APP_SECRET=
SLACK_APP_TOKEN=
SLACK_BOT_TOKEN=
TELEGRAM_BOT_TOKEN=
WHATSAPP_ALLOW_FROM=
EOF
    chmod 600 "$ENV_FILE"
    echo -e "\n${Y}请填写 $ENV_FILE 后重新运行${N}\n"; exit 1
  fi

  local _before="$OPENCLAW_DIR"
  eval "$(grep -v '^\s*[#$]' "$ENV_FILE" | grep -v '^\s*$' | sed 's/^/export /')"
  [ -z "$OPENCLAW_DIR" ] && OPENCLAW_DIR="$_before"
  ENV_FILE="$OPENCLAW_DIR/.env"
  [ -z "$LLM_COMPATIBILITY" ] && LLM_COMPATIBILITY="openai"

  local miss=()
  for v in LLM_BASE_URL LLM_API_KEY LLM_PROVIDER_ID LLM_MODEL_ID OPENCLAW_GATEWAY_TOKEN; do
    [ -z "${!v}" ] && miss+=("$v")
  done
  [ ${#miss[@]} -gt 0 ] && die "必填字段未填写：${miss[*]}\n请编辑 $ENV_FILE"

  for v in FEISHU_APP_ID SLACK_APP_TOKEN TELEGRAM_BOT_TOKEN WHATSAPP_ALLOW_FROM BRAVE_SEARCH_API_KEY; do
    [ -z "${!v}" ] && warn "$v 未填，相关功能将被禁用"
  done

  info "配置 LLM_API_KEY 环境变量..."; _ensure_env_export
  ok ".env 校验完成"
}

install_openclaw() {
  if command -v openclaw &>/dev/null; then
    local lv lv2
    lv=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    lv2=$(curl -fsSL https://registry.npmjs.org/openclaw/latest 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || echo "")
    [ -n "$lv2" ] && [ "$lv" = "$lv2" ] && { ok "OpenClaw $lv 已是最新"; return; }
    info "更新 $lv → $lv2 ..."
  else
    info "安装 OpenClaw..."
  fi
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh -o /tmp/_oc_install.sh
  bash /tmp/_oc_install.sh --no-prompt --no-onboard < /dev/null
  rm -f /tmp/_oc_install.sh
  ok "OpenClaw $(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) 安装完成"
}

run_onboard() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过 onboard"; return; }
  info "安装 gateway daemon..."
  openclaw onboard --non-interactive \
    --mode local --auth-choice skip \
    --gateway-port 18789 --gateway-bind loopback \
    --install-daemon --daemon-runtime node --skip-skills --accept-risk \
    < /dev/null || die "onboard 失败"
  info "覆写 main auth-profiles.json..."
  _write_auth "$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
  ok "onboard 完成"
}

deploy_workspace() {
  info "写入 workspace 文件..."
  local ws="$OPENCLAW_DIR/workspace"; mkdir -p "$ws"
  _wf  "$ws/IDENTITY.md"  "a helpful assistant"
  _wf  "$ws/SOUL.md"      "$_SOUL_MAIN"
  _wf  "$ws/USER.md"      "CEO"
  _wf  "$ws/MEMORY.md"    ""
  _wf  "$ws/TOOLS.md"     "$_TOOLS_MD"
  _wf  "$ws/AGENTS.md"    ""
  _wf  "$ws/HEARTBEAT.md" "$_HB_MAIN"
  ok "workspace 写入完成"
}

setup_agents() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过 agents"; return; }
  for AGENT_ID in analyst; do
    if openclaw agents list 2>/dev/null | grep -qi "\b$AGENT_ID\b"; then
      ok "agent $AGENT_ID 已存在，跳过"; continue
    fi
    info "添加 agent: $AGENT_ID ..."
    local ws="$OPENCLAW_DIR/agentTeam/workspace-$AGENT_ID"
    openclaw agents add "$AGENT_ID" \
      --workspace "$ws" --model "$LLM_PROVIDER_ID/$LLM_MODEL_ID" \
      --agent-dir "$OPENCLAW_DIR/agents/$AGENT_ID" --non-interactive \
      < /dev/null || { warn "agent $AGENT_ID 添加失败"; continue; }
    _wff "$ws/IDENTITY.md"  "a helpful assistant"
    _wff "$ws/USER.md"      "CEO"
    _wff "$ws/MEMORY.md"    ""
    _wff "$ws/TOOLS.md"     "$_TOOLS_MD"
    _wff "$ws/AGENTS.md"    ""
    _wff "$ws/SOUL.md"      "$_SOUL_ANALYST"
    _wff "$ws/HEARTBEAT.md" "$_HB_ANALYST"
    _write_auth "$OPENCLAW_DIR/agents/$AGENT_ID/agent/auth-profiles.json"
    ok "agent $AGENT_ID 配置完成"
  done
}

deploy_config() {
  local dst="$OPENCLAW_DIR/openclaw.json"; mkdir -p "$OPENCLAW_DIR"
  [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%Y%m%d_%H%M%S)" && warn "已备份旧配置"
  info "下载 openclaw.json..."
  curl -fsSL "${GITHUB_RAW}/openclaw.json" -o "$dst" || die "下载 openclaw.json 失败"

  python3 - "$dst" "$OPENCLAW_DIR" "$ENV_FILE" <<'PY'
import json, sys

dst, odir, env_file = sys.argv[1:]
env = {}
with open(env_file) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        k, _, v = line.partition('=')
        env[k.strip()] = v.strip().strip('"').strip("'")

def e(k): return env.get(k, '')
pid  = e('LLM_PROVIDER_ID'); mid = e('LLM_MODEL_ID'); full = pid + '/' + mid

with open(dst) as f: c = f.read()
for old, new in [('~/.openclaw/workspace-observer', odir+'/workspace-observer'),
                 ('~/.openclaw/workspace-analyst',  odir+'/workspace-analyst'),
                 ('~/.openclaw/workspace',          odir+'/workspace'),
                 ('~/.openclaw',                    odir)]:
    c = c.replace(old, new)
c = json.loads(c)

# provider / model
provs = c.setdefault('models', {}).setdefault('providers', {})
if '${LLM_PROVIDER_ID}' in provs: provs[pid] = provs.pop('${LLM_PROVIDER_ID}')
def scrub(obj):
    if not isinstance(obj, dict): return
    if 'apiKey' in obj: obj.pop('apiKey'); obj['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
    for m in obj.get('models', []):
        if isinstance(m, dict) and 'apiKey' in m: m.pop('apiKey'); m['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
for p in provs.values(): scrub(p)
for m in provs.get(pid, {}).get('models', []):
    if m.get('id')   == '${LLM_MODEL_ID}': m['id']   = mid
    if m.get('name') == '${LLM_MODEL_ID}': m['name'] = mid

# memorySearch keyRef
try:
    r = c['agents']['defaults']['memorySearch']['remote']
    if 'apiKey' in r: r.pop('apiKey'); r['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
except KeyError: pass

# agents defaults
defs = c.setdefault('agents', {}).setdefault('defaults', {})
if defs.get('model', {}).get('primary') == '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}': defs['model']['primary'] = full
am = defs.get('models', {})
if '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}' in am: am[full] = am.pop('${LLM_PROVIDER_ID}/${LLM_MODEL_ID}')

# brave：先把明文 apiKey 换成 $BRAVE_SEARCH_API_KEY，没填则整个删掉
try:
    c['plugins']['entries']['brave']['config']['webSearch']['apiKey'] = '$BRAVE_SEARCH_API_KEY'
except KeyError: pass
if not e('BRAVE_SEARCH_API_KEY'):
    try: c['plugins']['entries'].pop('brave', None)
    except KeyError: pass
    try: c['tools']['web']['search']['enabled'] = False
    except KeyError: pass

# channels / plugins（未填则移除）
ch = c.get('channels', {})
for key, val in [('feishu', e('FEISHU_APP_ID')), ('slack', e('SLACK_APP_TOKEN')),
                 ('telegram', e('TELEGRAM_BOT_TOKEN')), ('whatsapp', e('WHATSAPP_ALLOW_FROM'))]:
    if not val: ch.pop(key, None)
if not ch: c.pop('channels', None)
if not e('FEISHU_APP_ID'):
    try: c['plugins']['entries'].pop('feishu', None)
    except KeyError: pass
if not e('BROWSER_PATH'):
    try: c['browser'].pop('executablePath', None)
    except KeyError: pass

json.dump(c, open(dst, 'w'), indent=2, ensure_ascii=False)
PY
  chmod 600 "$dst" && ok "openclaw.json 已写入"
}

verify() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，请重新加载 shell"; return; }
  info "运行 doctor --fix..."
  openclaw doctor --fix < /dev/null || warn "doctor 报告了问题"
  info "重启 gateway..."
  openclaw gateway stop 2>/dev/null || true; sleep 3
  openclaw gateway install --force 2>/dev/null || true; sleep 15
  openclaw gateway status || warn "gateway 状态异常"
  ok "gateway 已重启"
}

# ── 主流程 ──
echo -e "\n${B}╔══════════════════════════════════════╗
║       OpenClaw 一键安装脚本          ║
╚══════════════════════════════════════╝${N}\n"

load_env
deploy_config
install_openclaw
run_onboard
deploy_workspace
setup_agents
verify

echo -e "\n${G}✓ 安装完成！${N}
  配置:  $OPENCLAW_DIR/openclaw.json
  安全:  API Key 通过 SecretRef/env 读取，未写入任何 JSON 文件
  启动:  openclaw tui

${Y}注意：请确保 OpenClaw gateway daemon 的启动环境能读到 LLM_API_KEY。
      已自动写入 ~/.profile / ~/.bashrc / ~/.zshrc（如存在）。${N}
"
