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
GATEWAY_TOKEN=

# Browser（可选，留空则自动探测）
BROWSER_PATH=

# Brave Search（可选）
BRAVE_SEARCH_API_KEY=

# Feishu / Lark（必填）
FEISHU_APP_ID=
FEISHU_APP_SECRET=

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
  # 在 subshell 里 source，避免污染当前环境
  eval "$(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | sed 's/^/export /' )"

  MISSING=()
  for v in LLM_BASE_URL LLM_API_KEY LLM_PROVIDER_ID LLM_MODEL_ID GATEWAY_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET; do
    [ -z "${!v}" ] && MISSING+=("$v")
  done
  [ ${#MISSING[@]} -gt 0 ] && error "必填字段未填写：$(IFS=', '; echo "${MISSING[*]}")\n请编辑 $ENV_FILE 后重新运行。"

  [ -z "$BROWSER_PATH" ]         && warn "BROWSER_PATH 未填，将自动探测"
  [ -z "$BRAVE_SEARCH_API_KEY" ] && warn "BRAVE_SEARCH_API_KEY 未填，Brave Search 将被禁用"
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
    "$BRAVE_SEARCH_API_KEY" "$BROWSER_PATH" "$TELEGRAM_BOT_TOKEN" "$WHATSAPP_ALLOW_FROM" <<'PYEOF'
import json, sys
dst, odir, pid, mid, brave, browser, telegram, whatsapp = sys.argv[1:]
full = pid + '/' + mid

with open(dst) as f: c = f.read()
# 路径占位符（顺序：长串优先）
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
if not telegram: ch.pop('telegram', None)
if not whatsapp: ch.pop('whatsapp', None)

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

# ── 4. 部署 workspace md ────────────────────────────────
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

# ── 5. 添加 agents（已存在则跳过）─────────────────────────
setup_agents() {
  command -v openclaw &>/dev/null || { warn "openclaw 未找到，跳过 agents 配置"; return; }

  for AGENT_ID in observer analyst; do
    WS="$OPENCLAW_DIR/workspace-$AGENT_ID"
    openclaw agents list 2>/dev/null | grep -q "^$AGENT_ID\b" && { success "agent $AGENT_ID 已存在，跳过"; continue; }

    info "添加 agent: $AGENT_ID ..."
    openclaw agents add "$AGENT_ID" --non-interactive \
      --agent-dir "$OPENCLAW_DIR/agents/$AGENT_ID" --workspace "$WS" \
      || { warn "agent $AGENT_ID 添加失败"; continue; }
    success "agent $AGENT_ID 已添加"

    mkdir -p "$WS"
    case "$AGENT_ID" in
      observer)
        echo "你是 AI 资讯侦察员，每次 heartbeat 用 browser subagent 搜集过去数小时最新 AI 资讯（arxiv、HuggingFace、主流科技博客），将原始结果写入 ~/.openclaw/workspace-analyst/inbox/news-{date}-{hour}.md。" > "$WS/SOUL.md"
        echo "用 browser subagent 搜索过去数小时最新 AI 资讯，将结果写入 ~/.openclaw/workspace-analyst/inbox/news-{date}-{hour}.md，写完回复 HEARTBEAT_OK。" > "$WS/HEARTBEAT.md"
        ;;
      analyst)
        echo "你是 AI 资讯分析师，每次 heartbeat 检查 inbox/ 目录，对 observer 投递的资讯文件逐一用 subagent 进行分析点评，将结果写入 memory/analysis-{date}.md 并通过飞书发送摘要。" > "$WS/SOUL.md"
        echo "检查 inbox/ 目录，有未处理文件则用 subagent 分析点评并写入 memory/analysis-{date}.md，通过飞书发送摘要；无文件则回复 HEARTBEAT_OK。" > "$WS/HEARTBEAT.md"
        ;;
    esac
    success "  $AGENT_ID SOUL.md / HEARTBEAT.md 已写入"
  done
}

# ── 6. 重启 gateway 并验证 ──────────────────────────────
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
deploy_workspace
setup_agents
verify

echo -e "\n${GREEN}✓ 安装完成！${NC}\n  配置: $OPENCLAW_DIR/openclaw.json\n  启动: openclaw tui\n"