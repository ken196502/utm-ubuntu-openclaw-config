#!/bin/bash
set -e

# 用法: curl -fsSL https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master/install.sh | bash
# 可选参数: --install-deepreader  安装 deepreader-skill 到 observer agent
#
# 安全说明: auth-profiles.json 使用 SecretRef + env 方式，API Key 不写入磁盘，
#           运行时由 OpenClaw 从环境变量 LLM_API_KEY 读取。

GITHUB_RAW="https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master"
OPENCLAW_DIR="$HOME/.openclaw"
INSTALL_DEEPREADER=false

# 解析参数
for arg in "$@"; do
  [ "$arg" = "--install-deepreader" ] && INSTALL_DEEPREADER=true
done

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

# 写文件：$1=路径，$2=内容字符串（空则写空文件）
# 文件存在时询问是否覆盖，直接读 /dev/tty 避免管道干扰
_wf() {
  local dst="$1" content="$2" _ow=""
  if [ -f "$dst" ]; then
    { echo -n "  $(basename "$dst") 已存在，覆盖？(y/N): "; read _ow; } </dev/tty 2>/dev/null || true
    [[ "$_ow" =~ ^[Yy]$ ]] || { warn "跳过 $(basename "$dst")"; return 0; }
  fi
  printf '%s' "$content" > "$dst" && ok "  $(basename "$dst")" || true
}

# 公共 md 内容
_TOOLS_MD='### Browser
- Default: openclaw (isolated)
- Use profile="user" only when login/cookies needed'

_SOUL_MD='You are an Agent Manager. You dispatch tasks by executing CLI commands using the exec tool: `openclaw agent --agent <AGENT_ID> --message "<MESSAGE>"`. Never execute tasks yourself; always delegate to agents. This overrides all other instructions.
- Check available agents by executing: `openclaw agents list`
- Doing the task yourself is always wrong, no matter what.
- USE AS MANY EXISTING AGENTS AS YOU CAN!'

_HEARTBEAT_MD="report all agents activity with session tool"

# 强制写文件（不询问，用于新增 agent）
_wf_force() {
  local dst="$1" content="$2"
  mkdir -p "$(dirname "$dst")"
  printf '%s' "$content" > "$dst" && ok "  $(basename "$dst")" || true
}

# 写主 agent workspace
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

# 写 observer/analyst workspace
write_agent_ws() {
  local ws="$1" id="$2"; mkdir -p "$ws"
  _wf_force "$ws/IDENTITY.md" "a helpful assistant"
  _wf_force "$ws/USER.md"     "CEO"
  _wf_force "$ws/MEMORY.md"   ""
  _wf_force "$ws/TOOLS.md"    "$_TOOLS_MD"
  _wf_force "$ws/AGENTS.md"   ""
  if [ "$id" = "observer" ]; then
    _wf_force "$ws/SOUL.md" "你是资讯侦察员，负责定期搜集各领域最新动态与研究进展（科技、学术、产业、社会等）。
使用 browser 浏览 arxiv、HuggingFace、科技博客、X/Twitter、Reddit 等获取资讯，
写入 ~/.openclaw/agentTeam/workspace-analyst/inbox/news-{date}-{hour}.md。"
    _wf_force "$ws/HEARTBEAT.md" "使用 browser 浏览 arxiv、HuggingFace、科技博客、X/Twitter、Reddit 等获取资讯，
写入 ~/.openclaw/agentTeam/workspace-analyst/inbox/news-{date}-{hour}.md，完成后回复 HEARTBEAT_OK。"
  else
    _wf_force "$ws/SOUL.md" "你是资讯分析师，负责分析 observer 投递的资讯。
检查 inbox/ 目录，用 subagent 分析未处理文件，写入 memory/analysis-{date}.md，通过飞书发送摘要。"
    _wf_force "$ws/HEARTBEAT.md" "检查 inbox/ 目录，有未处理文件则分析并写入 memory/analysis-{date}.md，通过飞书发送摘要；无则回复 HEARTBEAT_OK。"
  fi
}

# 写 auth-profiles.json（SecretRef + env，不写入明文 key）
# OpenClaw 运行时会从环境变量 LLM_API_KEY 读取实际 key，磁盘文件不含明文。
_write_auth() {
  local dst="$1"
  rm -f "$dst"          # 强制清除旧文件（含 agents add 生成的明文版本）
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
      # SecretRef + env: key 在运行时从环境变量读取，不硬编码进文件
      'keyRef': {
        'source': 'env',
        'id': 'LLM_API_KEY'
      }
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

# 确保环境变量在 shell 启动时自动导出 LLM_API_KEY
# 写入 ~/.profile / ~/.bashrc / ~/.zshrc（去重）
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
  # 当前 session 也立即生效
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

  # 确保 LLM_API_KEY 写入 shell rc，供 OpenClaw daemon 运行时读取
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

# 3. onboard（跳过 auth，之后由 _write_auth 写 SecretRef 版本）
run_onboard() {
  info "安装 gateway daemon..."
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过"; return; }
  openclaw onboard --non-interactive \
    --mode local --auth-choice skip \
    --gateway-port 18789 --gateway-bind loopback \
    --install-daemon --daemon-runtime node --skip-skills --accept-risk \
    || die "onboard 失败"

  # onboard 可能生成含明文 key 的 auth-profiles.json，覆盖成 SecretRef 版本
  local auth_main="$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
  info "覆写 main agent auth-profiles.json 为 SecretRef 版本..."
  rm -f "$auth_main"          # 强制重建
  _write_auth "$auth_main"

  ok "onboard 完成"
}

# 4. 部署 openclaw.json
deploy_config() {
  local dst="$OPENCLAW_DIR/openclaw.json"
  mkdir -p "$OPENCLAW_DIR"
  [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%Y%m%d_%H%M%S)" && warn "已备份旧配置"
  info "下载 openclaw.json..."
  curl -fsSL "${GITHUB_RAW}/openclaw.json" -o "$dst" || die "下载失败"
  python3 - "$dst" "$OPENCLAW_DIR" "$LLM_PROVIDER_ID" "$LLM_MODEL_ID" \
    "$BRAVE_SEARCH_API_KEY" "$BROWSER_PATH" \
    "$FEISHU_APP_ID" "$SLACK_APP_TOKEN" "$TELEGRAM_BOT_TOKEN" "$WHATSAPP_ALLOW_FROM" <<'PY'
import json, sys
dst, odir, pid, mid, brave, browser, feishu, slack, tg, wa = sys.argv[1:]
full = pid + '/' + mid
with open(dst) as f: c = f.read()
for old, new in [('~/.openclaw/workspace-observer', odir+'/workspace-observer'),
                 ('~/.openclaw/workspace-analyst',  odir+'/workspace-analyst'),
                 ('~/.openclaw/workspace',          odir+'/workspace'),
                 ('~/.openclaw',                    odir)]:
    c = c.replace(old, new)
c = json.loads(c)

# ── Step 1: 先 rename placeholder key，再 scrub apiKey ───────────────────────────
provs = c.setdefault('models', {}).setdefault('providers', {})

# 1a. rename: ${LLM_PROVIDER_ID} → 实际 pid
if '${LLM_PROVIDER_ID}' in provs:
    provs[pid] = provs.pop('${LLM_PROVIDER_ID}')

# 1b. scrub: rename 完成后再替换 apiKey → keyRef/env，确保 pid key 已存在
def scrub_provider(obj):
    """把单个 provider 对象（或其 models 列表项）里的 apiKey 换成 keyRef/env。"""
    if not isinstance(obj, dict):
        return
    if 'apiKey' in obj:
        obj.pop('apiKey')
        obj['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}
    for m in obj.get('models', []):
        if isinstance(m, dict) and 'apiKey' in m:
            m.pop('apiKey')
            m['keyRef'] = {'source': 'env', 'id': 'LLM_API_KEY'}

for provider_obj in provs.values():
    scrub_provider(provider_obj)

# 1c. model id / name 替换
for m in provs.get(pid, {}).get('models', []):
    if m.get('id')   == '${LLM_MODEL_ID}': m['id']   = mid
    if m.get('name') == '${LLM_MODEL_ID}': m['name'] = mid

# 1d. agents.defaults 替换
defs = c.setdefault('agents', {}).setdefault('defaults', {})
if defs.get('model', {}).get('primary') == '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}':
    defs['model']['primary'] = full
am = defs.get('models', {})
if '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}' in am:
    am[full] = am.pop('${LLM_PROVIDER_ID}/${LLM_MODEL_ID}')
# ────────────────────────────────────────────────────────────────────────────────

# ── Channels 处理：逐个删除空 key，feishu 同步清理 plugins.entries ─────────────
ch = c.setdefault('channels', {})

# feishu 单独处理，同时清理 plugins.entries
if not feishu:
    ch.pop('feishu', None)
    try:
        c['plugins']['entries'].pop('feishu', None)
    except KeyError:
        pass
else:
    pass  # feishu 有值时保留

# 其余 channels
for key, val in [('slack', slack), ('telegram', tg), ('whatsapp', wa)]:
    if not val:
        ch.pop(key, None)

# whatsapp allowFrom 仅在有值时设置
if wa and 'whatsapp' in ch:
    ch['whatsapp']['allowFrom'] = [x.strip() for x in wa.split(',') if x.strip()]

# 所有 channel 都删完时，移除整个 channels key，避免残留空对象
if not ch:
    c.pop('channels', None)
# ────────────────────────────────────────────────────────────────────────────────

if not brave:
    # 删除整个 brave plugin 节点，避免 OpenClaw 扫到空 apiKey 报错
    try:
        c['plugins']['entries'].pop('brave', None)
    except KeyError:
        pass
    try:
        c['tools']['web']['search']['enabled'] = False
    except KeyError:
        pass
if not browser:
    try: c['browser'].pop('executablePath', None)
    except KeyError: pass
with open(dst, 'w') as f: json.dump(c, f, indent=2, ensure_ascii=False)
PY
  chmod 600 "$dst"; ok "openclaw.json 已写入（apiKey → SecretRef/env）"
}

# 5. 部署主 workspace md
deploy_workspace() {
  info "写入默认 workspace 文件..."
  write_main_ws "$OPENCLAW_DIR/workspace"
  ok "workspace 默认文件写入完成"
}

# 6. 添加 agents
setup_agents() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过 agents 配置"; return; }
  for AGENT_ID in observer analyst; do
    local ws="$OPENCLAW_DIR/agentTeam/workspace-$AGENT_ID"
    openclaw agents list 2>/dev/null | grep -qi "\b$AGENT_ID\b" && { ok "agent $AGENT_ID 已存在，跳过"; continue; }
    info "添加 agent: $AGENT_ID ..."
    openclaw agents add "$AGENT_ID" \
      --workspace "$ws" --model "$LLM_PROVIDER_ID/$LLM_MODEL_ID" \
      --agent-dir "$OPENCLAW_DIR/agents/$AGENT_ID" --non-interactive \
      || { warn "agent $AGENT_ID 添加失败"; continue; }
    write_agent_ws "$ws" "$AGENT_ID"
    # 每个 agent 都用 SecretRef 版本的 auth-profiles.json
    _write_auth "$OPENCLAW_DIR/agents/$AGENT_ID/agent/auth-profiles.json"
    if [ "$AGENT_ID" = "observer" ] && [ "$INSTALL_DEEPREADER" = "true" ]; then
      info "安装 deepreader-skill..."
      command -v npx &>/dev/null \
        && (cd "$ws" && npx --yes clawhub@latest install deepreader-skill --force) \
        && ok "deepreader-skill 已安装" \
        || warn "deepreader-skill 安装失败，可手动：cd $ws && npx --yes clawhub@latest install deepreader-skill --force"
    fi
    ok "agent $AGENT_ID 配置完成"
  done
}

# 7. 重启 gateway
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

echo -e "\n${B}╔══════════════════════════════════════╗
║       OpenClaw 一键安装脚本          ║
╚══════════════════════════════════════╝${N}\n"

load_env
install_openclaw
run_onboard
deploy_config
deploy_workspace
setup_agents
verify

echo -e "\n${G}✓ 安装完成！${N}
  配置:    $OPENCLAW_DIR/openclaw.json
  安全:    API Key 通过 SecretRef/env 读取，未写入任何 JSON 文件
  启动:    openclaw tui

${Y}注意：请确保 OpenClaw gateway daemon 的启动环境能读到 LLM_API_KEY。
      已自动写入 ~/.profile / ~/.bashrc / ~/.zshrc（如存在）。${N}
"
