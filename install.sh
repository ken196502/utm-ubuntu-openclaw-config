#!/bin/bash
set -e

# 用法: curl -fsSL https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master/install.sh | bash

GITHUB_RAW="https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master"
OPENCLAW_DIR="$HOME/.openclaw"

# 允许 .env 中的 OPENCLAW_DIR 覆盖默认值
if [ -f "$OPENCLAW_DIR/.env" ]; then
  _override=$(grep -v '^\s*#' "$OPENCLAW_DIR/.env" | grep '^OPENCLAW_DIR=' | cut -d= -f2- | tr -d '"'"'")
  [ -n "$_override" ] && OPENCLAW_DIR="$_override"
fi
ENV_FILE="$OPENCLAW_DIR/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── 1. 校验 .env ────────────────────────────────────────
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    warn ".env 不存在，正在生成模板到 $ENV_FILE ..."
    mkdir -p "$OPENCLAW_DIR"
    cat > "$ENV_FILE" <<'EOF'
# OpenClaw 配置 — 填好后重新运行安装脚本

# 安装目录（可选，默认 ~/.openclaw）
OPENCLAW_DIR=

# LLM Provider（必填）
LLM_BASE_URL=https://api.example.com/v1
LLM_API_KEY=
LLM_PROVIDER_ID=myprovider
LLM_MODEL_ID=my-model-name

# Gateway Token（必填）生成方法: openssl rand -hex 24
# 变量名必须是 OPENCLAW_GATEWAY_TOKEN，gateway 启动时自动读取
OPENCLAW_GATEWAY_TOKEN=

# Browser（可选，留空则自动探测）
BROWSER_PATH=

# Brave Search（可选）
BRAVE_SEARCH_API_KEY=

# Feishu / Lark（必填）
FEISHU_APP_ID=
FEISHU_APP_SECRET=

# Slack（可选）
SLACK_APP_TOKEN=
SLACK_BOT_TOKEN=

# Telegram（可选）
TELEGRAM_BOT_TOKEN=

# WhatsApp（可选）国际格式逗号分隔: +8613800138000,+8613900139000
WHATSAPP_ALLOW_FROM=
EOF
    chmod 600 "$ENV_FILE"
    echo -e "\n${YELLOW}  .env 已生成，请填写后重新运行：\n    vim $ENV_FILE${NC}\n"
    exit 1
  fi

  info "校验 .env..."
  _OPENCLAW_DIR_BEFORE="$OPENCLAW_DIR"
  eval "$(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/^/export /')"
  # .env 里 OPENCLAW_DIR= 为空时恢复默认值
  [ -z "$OPENCLAW_DIR" ] && OPENCLAW_DIR="$_OPENCLAW_DIR_BEFORE"
  ENV_FILE="$OPENCLAW_DIR/.env"

  MISSING=()
  for v in LLM_BASE_URL LLM_API_KEY LLM_PROVIDER_ID LLM_MODEL_ID OPENCLAW_GATEWAY_TOKEN; do
    [ -z "${!v}" ] && MISSING+=("$v")
  done
  [ ${#MISSING[@]} -gt 0 ] && error "必填字段未填写：$(IFS=', '; echo "${MISSING[*]}")\n请编辑 $ENV_FILE 后重新运行。"

  [ -z "$BROWSER_PATH" ]         && warn "BROWSER_PATH 未填，将自动探测"
  [ -z "$BRAVE_SEARCH_API_KEY" ] && warn "BRAVE_SEARCH_API_KEY 未填，Brave Search 将被禁用"
  [ -z "$FEISHU_APP_ID" ]        && warn "FEISHU_APP_ID 未填，feishu 节点将被移除"
  [ -z "$SLACK_APP_TOKEN" ]      && warn "SLACK_APP_TOKEN 未填，slack 节点将被移除"
  [ -z "$TELEGRAM_BOT_TOKEN" ]   && warn "TELEGRAM_BOT_TOKEN 未填，telegram 节点将被移除"
  [ -z "$WHATSAPP_ALLOW_FROM" ]  && warn "WHATSAPP_ALLOW_FROM 未填，whatsapp 节点将被移除"
  success ".env 校验完成"
}

# ── 2. 安装 / 更新 OpenClaw ─────────────────────────────
install_openclaw() {
  if command -v openclaw &>/dev/null; then
    LOCAL=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+[.][0-9]+[.][0-9]+' | head -1)
    LATEST=$(curl -fsSL https://registry.npmjs.org/openclaw/latest 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))" 2>/dev/null || echo "")
    [ -n "$LATEST" ] && [ "$LOCAL" = "$LATEST" ] && { success "OpenClaw $LOCAL 已是最新，跳过"; return; }
    info "更新 $LOCAL → $LATEST ..."
  else
    info "安装 OpenClaw..."
  fi
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
  success "OpenClaw $(openclaw --version 2>/dev/null | grep -oE '[0-9]+[.][0-9]+[.][0-9]+' | head -1) 安装完成"
}

# ── 3. 部署 openclaw.json ───────────────────────────────
deploy_config() {
  DST="$OPENCLAW_DIR/openclaw.json"
  mkdir -p "$OPENCLAW_DIR"
  [ -f "$DST" ] && cp "$DST" "$DST.bak.$(date +%Y%m%d_%H%M%S)" && warn "已备份旧配置"

  info "下载 openclaw.json..."
  curl -fsSL "${GITHUB_RAW}/openclaw.json" -o "$DST" || error "下载失败"

  python3 - "$DST" "$OPENCLAW_DIR" "$LLM_PROVIDER_ID" "$LLM_MODEL_ID" \
    "$BRAVE_SEARCH_API_KEY" "$BROWSER_PATH" \
    "$FEISHU_APP_ID" "$SLACK_APP_TOKEN" "$TELEGRAM_BOT_TOKEN" "$WHATSAPP_ALLOW_FROM" <<'PYEOF'
import json, sys
dst, odir, pid, mid, brave, browser, feishu, slack, telegram, whatsapp = sys.argv[1:]
full = pid + '/' + mid

with open(dst) as f: c = f.read()
for old, new in [
  ('~/.openclaw/workspace-observer', odir + '/workspace-observer'),
  ('~/.openclaw/workspace-analyst',  odir + '/workspace-analyst'),
  ('~/.openclaw/workspace',          odir + '/workspace'),
  ('~/.openclaw',                    odir),
]:
    c = c.replace(old, new)

c = json.loads(c)

# providers object key
providers = c.setdefault('models', {}).setdefault('providers', {})
if '${LLM_PROVIDER_ID}' in providers:
    providers[pid] = providers.pop('${LLM_PROVIDER_ID}')
for m in providers.get(pid, {}).get('models', []):
    if m.get('id')   == '${LLM_MODEL_ID}': m['id']   = mid
    if m.get('name') == '${LLM_MODEL_ID}': m['name'] = mid

# agents defaults
defaults = c.setdefault('agents', {}).setdefault('defaults', {})
if defaults.get('model', {}).get('primary') == '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}':
    defaults['model']['primary'] = full
am = defaults.get('models', {})
if '${LLM_PROVIDER_ID}/${LLM_MODEL_ID}' in am:
    am[full] = am.pop('${LLM_PROVIDER_ID}/${LLM_MODEL_ID}')

# 可选 channel 节点删除
ch = c.setdefault('channels', {})
if not feishu:   ch.pop('feishu',   None)
if not slack:    ch.pop('slack',    None)
if not telegram: ch.pop('telegram', None)
if not whatsapp: ch.pop('whatsapp', None)

# feishu plugin 同步
if not feishu:
    try: c['plugins']['entries'].pop('feishu', None)
    except KeyError: pass

# Brave / Browser
if not brave:
    try: c['tools']['web']['search']['enabled'] = False
    except KeyError: pass
if not browser:
    try: c['browser'].pop('executablePath', None)
    except KeyError: pass

with open(dst, 'w') as f: json.dump(c, f, indent=2, ensure_ascii=False)
PYEOF

  chmod 600 "$DST"
  success "openclaw.json 已写入"
}

# ── 4. 生成 auth-profiles.json ─────────────────────────
deploy_auth() {
  AUTH_DIR="$OPENCLAW_DIR/agents/main/agent"
  AUTH_FILE="$AUTH_DIR/auth-profiles.json"
  mkdir -p "$AUTH_DIR"

  # 已存在则跳过（避免覆盖用户手动配置的 profiles）
  if [ -f "$AUTH_FILE" ]; then
    success "auth-profiles.json 已存在，跳过"
    return
  fi

  info "生成 auth-profiles.json..."
  python3 -c "
import json, sys
pid, key = sys.argv[1], sys.argv[2]
profile_id = pid + ':default'
data = {
  'profiles': {
    profile_id: {
      'provider': pid,
      'type': 'api_key',
      'key': key
    }
  },
  'order': { pid: [profile_id] }
}
with open('$AUTH_FILE', 'w') as f: json.dump(data, f, indent=2)
" "$LLM_PROVIDER_ID" "$LLM_API_KEY"
  chmod 600 "$AUTH_FILE"
  success "auth-profiles.json 已生成"
}

# ── 5. 部署 workspace md ────────────────────────────────
deploy_workspace() {
  DST_WS="$OPENCLAW_DIR/workspace"
  mkdir -p "$DST_WS"
  info "下载 workspace 文件..."
  for F in AGENTS.md HEARTBEAT.md IDENTITY.md MEMORY.md SOUL.md TOOLS.md USER.md; do
    DST_F="$DST_WS/$F"
    if [ -f "$DST_F" ]; then
      read -p "  $F 已存在，覆盖？(y/N): " OW
      [[ "$OW" =~ ^[Yy]$ ]] || { warn "跳过 $F"; continue; }
    fi
    curl -fsSL "${GITHUB_RAW}/workspace/${F}" -o "$DST_F" 2>/dev/null \
      && success "  $F" || warn "  $F 下载失败"
  done
}

# ── 6. 添加 agents（已存在则跳过）─────────────────────────
setup_agents() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过 agents 配置"; return; }

  for AGENT_ID in observer analyst; do
    WS="$OPENCLAW_DIR/workspace-$AGENT_ID"
    openclaw agents list 2>/dev/null | grep -qi "\b$AGENT_ID\b" && { success "agent $AGENT_ID 已存在，跳过"; continue; }

    info "添加 agent: $AGENT_ID ..."
    openclaw agents add "$AGENT_ID" --non-interactive \
      --agent-dir "$OPENCLAW_DIR/agents/$AGENT_ID" --workspace "$WS" \
      || { warn "agent $AGENT_ID 添加失败"; continue; }
    success "agent $AGENT_ID 已添加"

    mkdir -p "$WS"
    case "$AGENT_ID" in
      observer)
        cat > "$WS/SOUL.md" <<'EOF'
你是资讯侦察员，负责定期搜集各领域最新动态与研究进展（科技、学术、产业、社会等，不限于特定领域）。

**工作方式：**
- 使用 browser subagent 浏览 arxiv、HuggingFace、主流科技博客、新闻聚合、X/Twitter、Reddit 等来源，获取最新资讯链接
- 对找到的资讯链接，使用 deepreader skill 抓取完整正文内容（支持网页、Twitter/X 推文与线程、Reddit 帖子与评论、YouTube 字幕），结果自动保存为 Markdown
- 将抓取到的内容整理后写入 ~/.openclaw/workspace-analyst/inbox/news-{date}-{hour}.md，供 analyst 分析

**deepreader 使用方式：**
- 把需要抓取的 URL 直接传给 deepreader，它会自动识别来源（网页/X/Reddit/YouTube）并提取干净的正文
- 无需 API key，无需登录，直接使用
- 支持一次传入多个 URL 批量处理
EOF
        cat > "$WS/HEARTBEAT.md" <<'EOF'
用 browser subagent 搜索过去数小时各领域最新资讯（不限主题），收集值得关注的链接后，用 deepreader skill 逐一抓取完整正文内容，将结果写入 ~/.openclaw/workspace-analyst/inbox/news-{date}-{hour}.md，写完回复 HEARTBEAT_OK。
EOF
        ;;
      analyst)
        cat > "$WS/SOUL.md" <<'EOF'
你是资讯分析师，负责对侦察员（observer）投递的各类资讯进行深度分析与点评，不局限于特定领域。

**工作方式：**
- 每次 heartbeat 检查 inbox/ 目录，对未处理文件逐一用 subagent 进行分析
- 提炼核心观点、趋势判断、潜在影响
- 将分析结果写入 memory/analysis-{date}.md
- 通过飞书发送摘要推送
EOF
        cat > "$WS/HEARTBEAT.md" <<'EOF'
检查 inbox/ 目录，有未处理文件则用 subagent 分析点评并写入 memory/analysis-{date}.md，通过飞书发送摘要；无文件则回复 HEARTBEAT_OK。
EOF
        ;;
    esac
    success "  $AGENT_ID SOUL.md / HEARTBEAT.md 已写入"

    # ── 为 observer 安装 deepreader skill ──────────────
    if [ "$AGENT_ID" = "observer" ]; then
      if command -v npx &>/dev/null; then
        info "为 observer 安装 deepreader skill..."
        (cd "$WS" && npx clawhub@latest install deepreader --force) \
          && success "deepreader skill 已安装到 $WS/skills/" \
          || warn "deepreader skill 安装失败，可手动执行：cd $WS && npx clawhub@latest install deepreader --force"
      else
        warn "npx 未找到，跳过 deepreader 安装，可手动执行：cd $WS && npx clawhub@latest install deepreader --force"
      fi
    fi
  done
}

# ── 7. 重启 gateway 并验证 ──────────────────────────────
verify() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，请重新加载 shell"; return; }
  info "运行 doctor --fix..."
  openclaw doctor --fix || warn "doctor 报告了问题"
  info "重启 gateway..."
  openclaw gateway stop 2>/dev/null || true
  sleep 3
  openclaw gateway install 2>/dev/null || true
  sleep 15
  openclaw gateway status || warn "gateway 状态异常"
  success "gateway 已重启"
}

# ── 主流程 ──────────────────────────────────────────────
echo -e "\n${BLUE}╔══════════════════════════════════════╗
║     OpenClaw 一键安装脚本             ║
╚══════════════════════════════════════╝${NC}\n"

load_env
install_openclaw
deploy_config
deploy_auth
deploy_workspace
setup_agents
verify

echo -e "\n${GREEN}✓ 安装完成！${NC}\n  配置: $OPENCLAW_DIR/openclaw.json\n  启动: openclaw tui\n"