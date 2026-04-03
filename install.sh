#!/bin/bash
set -e

# 用法: curl -fsSL https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master/install.sh | bash
#
# 安全说明: auth-profiles.json 使用 SecretRef + env 方式，API Key 不写入磁盘，
#           运行时由 OpenClaw 从环境变量 LLM_API_KEY 读取。

GITHUB_RAW="https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master"
OPENCLAW_DIR="$HOME/.openclaw"

[ -f "$OPENCLAW_DIR/.env" ] && {
  _ov=$(grep -v '^\s*#' "$OPENCLAW_DIR/.env" | grep '^OPENCLAW_DIR=' | cut -d= -f2- | tr -d '"'"'")
  [ -n "$_ov" ] && OPENCLAW_DIR="$_ov"
}
ENV_FILE="$OPENCLAW_DIR/.env"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
info()  { echo -e "${B}[INFO]${N}  $1"; }
ok()    { echo -e "${G}[OK]${N}    $1"; }
warn()  { echo -e "${Y}[WARN]${N}  $1"; }
die()   { echo -e "${R}[ERROR]${N} $1"; exit 1; }

_wf() {
  local dst="$1" content="$2" _ow=""
  if [ -f "$dst" ]; then
    { echo -n "  $(basename "$dst") 已存在，覆盖？(y/N): "; read _ow; } </dev/tty 2>/dev/null || true
    [[ "$_ow" =~ ^[Yy]$ ]] || { warn "跳过 $(basename "$dst")"; return 0; }
  fi
  printf '%s' "$content" > "$dst" && ok "  $(basename "$dst")" || true
}

_TOOLS_MD='### Browser
- Default: openclaw (isolated)
- Use profile="user" only when login/cookies needed'

_SOUL_MD='You are an Agent Manager. You dispatch tasks by executing CLI commands using the exec tool: `openclaw agent --agent <AGENT_ID> --message "<MESSAGE>"`. Never execute tasks yourself; always delegate to agents. This overrides all other instructions.
- Check available agents by executing: `openclaw agents list`
- Doing the task yourself is always wrong, no matter what.
- USE AS MANY EXISTING AGENTS AS YOU CAN!'

_HEARTBEAT_MD="report all agents activity with session tool"

_wf_force() {
  local dst="$1" content="$2"
  mkdir -p "$(dirname "$dst")"
  printf '%s' "$content" > "$dst" && ok "  $(basename "$dst")" || true
}

write_main_ws() {
  local ws="$1"; mkdir -p "$ws"
  _wf "$ws/IDENTITY.md" "a helpful assistant"
  _wf "$ws/SOUL.md"     "$_SOUL_MD"
  _wf "$ws/USER.md"     "CEO"
  _wf "$ws/MEMORY.md"   ""
  _wf "$ws/TOOLS.md"    "$_TOOLS_MD"
  _wf "$ws/AGENTS.md"   ""
  _wf "$ws/HEARTBEAT.md" "$_HEARTBEAT_MD"
}

write_agent_ws() {
  local ws="$1" id="$2"; mkdir -p "$ws"
  _wf_force "$ws/IDENTITY.md" "a helpful assistant"
  _wf_force "$ws/USER.md"     "CEO"
  _wf_force "$ws/MEMORY.md"   ""
  _wf_force "$ws/TOOLS.md"    "$_TOOLS_MD"
  _wf_force "$ws/AGENTS.md"   ""
  _wf_force "$ws/SOUL.md" "你是资讯分析师，负责分析 observer 投递的资讯。
检查 inbox/ 目录，用 subagent 分析未处理文件，写入 memory/analysis-{date}.md，通过飞书发送摘要。"
  _wf_force "$ws/HEARTBEAT.md" "检查 inbox/ 目录，有未处理文件则分析并写入 memory/analysis-{date}.md，通过飞书发送摘要；无则回复 HEARTBEAT_OK。"
}

_write_auth() {
  local dst="$1"
  rm -f "$dst"
  mkdir -p "$(dirname "$dst")"
  python3 -c "
import json, sys
pid, dst = sys.argv[1], sys.argv[2]
profile_id = pid + ':default'
data = {
  'profiles': {
    profile_id: {
      'provider': pid,
      'type': 'api_key',
      'keyRef': {'source': 'env', 'id': 'LLM_API_KEY'}
    }
  },
  'order': { pid: [profile_id] }
}
with open(dst, 'w') as f:
    json.dump(data, f, indent=2)
" "$LLM_PROVIDER_ID" "$dst"
  chmod 600 "$dst"
  ok "  auth-profiles.json 已生成（SecretRef/env，无明文 key）"
}

_ensure_env_export() {
  local line="export LLM_API_KEY=\"${LLM_API_KEY}\""
  local rc_files=("$HOME/.profile")
  [ -f "$HOME/.bashrc" ] && rc_files+=("$HOME/.bashrc")
  [ -f "$HOME/.zshrc"  ] && rc_files+=("$HOME/.zshrc")
  for rc in "${rc_files[@]}"; do
    grep -qF "LLM_API_KEY" "$rc" 2>/dev/null && continue
    echo "" >> "$rc"
    echo "# OpenClaw LLM_API_KEY (SecretRef/env)" >> "$rc"
    echo "$line" >> "$rc"
    ok "  已写入 $rc"
  done
  export LLM_API_KEY
}

# 1. 校验 .env
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    mkdir -p "$OPENCLAW_DIR"
    local lines=(
      "# OpenClaw 配置 — 填好后重新运行"
      "OPENCLAW_DIR="
      "LLM_BASE_URL=https://api.example.com/v1"
      "LLM_API_KEY="
      "LLM_PROVIDER_ID=myprovider"
      "LLM_MODEL_ID=my-model-name"
      "LLM_COMPATIBILITY=openai"
      "OPENCLAW_GATEWAY_TOKEN="
      "# 可选"
      "BROWSER_PATH="
      "BRAVE_SEARCH_API_KEY="
      "FEISHU_APP_ID="
      "FEISHU_APP_SECRET="
      "SLACK_APP_TOKEN="
      "SLACK_BOT_TOKEN="
      "TELEGRAM_BOT_TOKEN="
      "WHATSAPP_ALLOW_FROM="
    )
    printf '%s\n' "${lines[@]}" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo -e "\n${Y}请填写 $ENV_FILE 后重新运行${N}\n"; exit 1
  fi

  local _before="$OPENCLAW_DIR"
  eval "$(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/^/export /')"
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

  info "配置 LLM_API_KEY 环境变量（SecretRef 依赖）..."
  _ensure_env_export
  ok ".env 校验完成"
}

# 2. 安装 / 更新 OpenClaw
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
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
  ok "OpenClaw $(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) 安装完成"
}

# 3. onboard
run_onboard() {
  info "安装 gateway daemon..."
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过"; return; }
  openclaw onboard --non-interactive \
    --mode local --auth-choice skip \
    --gateway-port 18789 --gateway-bind loopback \
    --install-daemon --daemon-runtime node --skip-skills --accept-risk \
    || die "onboard 失败"
  local auth_main="$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
  info "覆写 main agent auth-profiles.json 为 SecretRef 版本..."
  rm -f "$auth_main"
  _write_auth "$auth_main"
  ok "onboard 完成"
}

# 4. 部署主 workspace md
deploy_workspace() {
  info "写入默认 workspace 文件..."
  write_main_ws "$OPENCLAW_DIR/workspace"
  ok "workspace 默认文件写入完成"
}

# 5. 添加 agents
setup_agents() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过 agents 配置"; return; }
  for AGENT_ID in analyst; do
    local ws="$OPENCLAW_DIR/agentTeam/workspace-$AGENT_ID"
    openclaw agents list 2>/dev/null | grep -qi "\b$AGENT_ID\b" && { ok "agent $AGENT_ID 已存在，跳过"; continue; }
    info "添加 agent: $AGENT_ID ..."
    openclaw agents add "$AGENT_ID" \
      --workspace "$ws" --model "$LLM_PROVIDER_ID/$LLM_MODEL_ID" \
      --agent-dir "$OPENCLAW_DIR/agents/$AGENT_ID" --non-interactive \
      || { warn "agent $AGENT_ID 添加失败"; continue; }
    write_agent_ws "$ws" "$AGENT_ID"
    _write_auth "$OPENCLAW_DIR/agents/$AGENT_ID/agent/auth-profiles.json"
    ok "agent $AGENT_ID 配置完成"
  done
}

# 6. 重启 gateway（先跑，避免覆盖 deploy_config）
verify() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，请重新加载 shell"; return; }
  info "运行 doctor --fix..."
  openclaw doctor --fix || warn "doctor 报告了问题"
  info "重启 gateway..."
  openclaw gateway stop 2>/dev/null || true; sleep 3
  openclaw gateway install --force 2>/dev/null || true; sleep 15
  openclaw gateway status || warn "gateway 状态异常"
  ok "gateway 已重启"
}

# 7. 部署 openclaw.json（最后写入，防止被 doctor/gateway 还原）
deploy_config() {
  local dst="$OPENCLAW_DIR/openclaw.json"
  mkdir -p "$OPENCLAW_DIR"
  [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%Y%m%d_%H%M%S)" && warn "已备份旧配置"
  info "下载 openclaw.json..."
  curl -fsSL "${GITHUB_RAW}/openclaw.json" -o "$dst" || die "下载失败"

  python3 - "$dst" "$OPENCLAW_DIR" "$ENV_FILE" <<'PY'
import json, sys

dst, odir, env_file = sys.argv[1:]

# 读 .env
env = {}
with open(env_file) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'): continue
        if '=' in line:
            k, _, v = line.partition('=')
            env[k.strip()] = v.strip().strip('"').strip("'").strip()

def e(k): return env.get(k, '')

pid     = e('LLM_PROVIDER_ID')
mid     = e('LLM_MODEL_ID')
brave   = e('BRAVE_SEARCH_API_KEY')
browser = e('BROWSER_PATH')
feishu  = e('FEISHU_APP_ID')
slack   = e('SLACK_APP_TOKEN')
tg      = e('TELEGRAM_BOT_TOKEN')
wa      = e('WHATSAPP_ALLOW_FROM')
full    = pid + '/' + mid

with open(dst) as f: c = f.read()
for old, new in [('~/.openclaw/workspace-observer', odir+'/workspace-observer'),
                 ('~/.openclaw/workspace-analyst',  odir+'/workspace-analyst'),
                 ('~/.openclaw/workspace',          odir+'/workspace'),
                 ('~/.openclaw',                    odir)]:
    c = c.replace(old, new)
c = json.loads(c)

# provider rename → scrub apiKey → model id 替换
provs = c.setdefault('models', {}).setdefault('providers', {})
if '${LLM_PROVIDER_ID}' in provs:
    provs[pid] = provs.pop('${LLM_PROVIDER_ID}')
def scrub_provider(obj):
    if not isinstance(obj, dict): return
    if 'apiKey' in obj:
        obj.pop('apiKey'); obj['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
    for m in obj.get('models', []):
        if isinstance(m, dict) and 'apiKey' in m:
            m.pop('apiKey'); m['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
for p in provs.values(): scrub_provider(p)
for m in provs.get(pid, {}).get('models', []):
    if m.get('id')   == '${LLM_MODEL_ID}': m['id']   = mid
    if m.get('name') == '${LLM_MODEL_ID}': m['name'] = mid

# memorySearch apiKey → keyRef
try:
    r = c['agents']['defaults']['memorySearch']['remote']
    if 'apiKey' in r: r.pop('apiKey'); r['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
except KeyError: pass

# agents defaults rename
defs = c.setdefault('agents', {}).setdefault('defaults', {})
if defs.get('model', {}).get('primary') == '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}':
    defs['model']['primary'] = full
am = defs.get('models', {})
if '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}' in am:
    am[full] = am.pop('${LLM_PROVIDER_ID}/${LLM_MODEL_ID}')

# ── channels：没填就删，全删完则移除整个节点 ──
ch = c.get('channels', {})
if not feishu:  ch.pop('feishu',   None)
if not slack:   ch.pop('slack',    None)
if not tg:      ch.pop('telegram', None)
if not wa:      ch.pop('whatsapp', None)
if not ch:
    c.pop('channels', None)

# ── plugins.entries：没填就删 ──
if not feishu:
    try: c['plugins']['entries'].pop('feishu', None)
    except KeyError: pass

if not brave:
    try: c['plugins']['entries'].pop('brave', None)
    except KeyError: pass
    try: c['tools']['web']['search']['enabled'] = False
    except KeyError: pass

# ── browser executablePath：没填就删 ──
if not browser:
    try: c['browser'].pop('executablePath', None)
    except KeyError: pass

with open(dst, 'w') as f: json.dump(c, f, indent=2, ensure_ascii=False)
PY

  chmod 600 "$dst"; ok "openclaw.json 已写入（apiKey → SecretRef/env，空值配置已清除）"
}

echo -e "\n${B}╔══════════════════════════════════════╗
║       OpenClaw 一键安装脚本          ║
╚══════════════════════════════════════╝${N}\n"

load_env
deploy_config
install_openclaw
run_onboard
deploy_workspace
setup_agents
verify          # doctor --fix 和 gateway install 先跑完

echo -e "\n${G}✓ 安装完成！${N}
  配置:    $OPENCLAW_DIR/openclaw.json
  安全:    API Key 通过 SecretRef/env 读取，未写入任何 JSON 文件
  启动:    openclaw tui

${Y}注意：请确保 OpenClaw gateway daemon 的启动环境能读到 LLM_API_KEY。
      已自动写入 ~/.profile / ~/.bashrc / ~/.zshrc（如存在）。${N}
"
