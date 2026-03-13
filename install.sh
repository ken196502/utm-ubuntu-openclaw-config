#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════
# OpenClaw 一键安装脚本
# 用法: bash install.sh
# 依赖: 同目录下的 openclaw.json 和 workspace/
# ═══════════════════════════════════════════════════════

OPENCLAW_DIR="$HOME/.openclaw"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ───────────────────────────────────────────────────────
# 1. 加载 .env
# ───────────────────────────────────────────────────────
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    warn ".env 不存在，正在生成模板..."
    cat > "$ENV_FILE" <<'EOF'
# ══════════════════════════════════════════════
# OpenClaw 配置 — 填好后运行 bash install.sh
# ══════════════════════════════════════════════

# ── LLM Provider（必填）─────────────────────
LLM_BASE_URL=https://api.example.com/v1
LLM_API_KEY=
LLM_PROVIDER_ID=myprovider
LLM_MODEL_ID=my-model-name

# ── Gateway Token（必填，自行生成一个随机串）─
GATEWAY_TOKEN=

# ── Browser（可选，留空则 OpenClaw 自动探测）─
BROWSER_PATH=

# ── Brave Search（可选）─────────────────────
BRAVE_SEARCH_API_KEY=

# ── Feishu / Lark（可选）────────────────────
FEISHU_APP_ID=
FEISHU_APP_SECRET=

# ── Telegram（可选）─────────────────────────
TELEGRAM_BOT_TOKEN=

# ── WhatsApp 通过 QR 配对，无需 token ────────
# 如需禁用，取消下面注释：
# WHATSAPP_ENABLED=false
EOF
    chmod 600 "$ENV_FILE"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  .env 模板已生成，请先填写后重新运行：${NC}"
    echo ""
    echo -e "    ${BLUE}vim $ENV_FILE${NC}"
    echo -e "    ${BLUE}bash $0${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 1
  fi

  info "加载 .env..."
  set -a; source "$ENV_FILE"; set +a

  # 必填校验
  MISSING=()
  [ -z "$LLM_BASE_URL" ]    && MISSING+=("LLM_BASE_URL")
  [ -z "$LLM_API_KEY" ]     && MISSING+=("LLM_API_KEY")
  [ -z "$LLM_PROVIDER_ID" ] && MISSING+=("LLM_PROVIDER_ID")
  [ -z "$LLM_MODEL_ID" ]    && MISSING+=("LLM_MODEL_ID")
  [ -z "$GATEWAY_TOKEN" ]   && MISSING+=("GATEWAY_TOKEN")

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    error "以下必填字段未填写：$(IFS=', '; echo "${MISSING[*]}")\n请编辑 $ENV_FILE 后重新运行。"
  fi

  # 可选项提示
  [ -z "$BROWSER_PATH" ]         && warn "BROWSER_PATH 未填，将由 OpenClaw 自动探测浏览器"
  [ -z "$BRAVE_SEARCH_API_KEY" ] && warn "BRAVE_SEARCH_API_KEY 未填，Brave Search 将被禁用"
  [ -z "$FEISHU_APP_ID" ]        && warn "FEISHU_APP_ID 未填，飞书集成将被禁用"
  [ -z "$FEISHU_APP_SECRET" ]    && warn "FEISHU_APP_SECRET 未填，飞书集成将被禁用"
  [ -z "$TELEGRAM_BOT_TOKEN" ]   && warn "TELEGRAM_BOT_TOKEN 未填，Telegram 将被禁用"

  success ".env 加载完成"
}

# ───────────────────────────────────────────────────────
# 2. 安装 / 更新 OpenClaw（始终执行，拿最新版）
# ───────────────────────────────────────────────────────
install_openclaw() {
  if command -v openclaw &>/dev/null; then
    OLD_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    info "检测到 OpenClaw $OLD_VER，强制更新到最新版..."
  else
    info "未检测到 OpenClaw，开始全新安装..."
  fi

  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh \
    | bash -s -- --no-prompt --no-onboard

  NEW_VER=$(openclaw --version 2>/dev/null || echo "unknown")
  success "OpenClaw 安装/更新完成，当前版本: $NEW_VER"
}

# ───────────────────────────────────────────────────────
# 3. 部署 openclaw.json
# ───────────────────────────────────────────────────────
deploy_config() {
  SRC_CONFIG="$SCRIPT_DIR/openclaw.json"
  DST_CONFIG="$OPENCLAW_DIR/openclaw.json"
  WORKSPACE_PATH="$OPENCLAW_DIR/workspace"

  [ -f "$SRC_CONFIG" ] || error "找不到 $SRC_CONFIG，请确认脚本和 openclaw.json 在同一目录"

  mkdir -p "$OPENCLAW_DIR"

  # 备份旧配置
  if [ -f "$DST_CONFIG" ]; then
    BACKUP="$DST_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$DST_CONFIG" "$BACKUP"
    warn "已备份旧配置 → $BACKUP"
  fi

  info "写入 openclaw.json 并替换占位符..."

  # 用 python 做替换，彻底避免 shell/perl 转义问题
  python3 - \
    "$SRC_CONFIG" "$DST_CONFIG" "$WORKSPACE_PATH" \
    "$LLM_BASE_URL" "$LLM_API_KEY" "$LLM_PROVIDER_ID" "$LLM_MODEL_ID" \
    "$GATEWAY_TOKEN" "$BROWSER_PATH" \
    "$BRAVE_SEARCH_API_KEY" "$FEISHU_APP_ID" "$FEISHU_APP_SECRET" \
    "$TELEGRAM_BOT_TOKEN" \
    <<'PYEOF'
import sys

src, dst, workspace, \
  llm_base_url, llm_api_key, llm_provider_id, llm_model_id, \
  gateway_token, browser_path, \
  brave_key, feishu_id, feishu_secret, \
  telegram_token = sys.argv[1:]

with open(src, 'r') as f:
    c = f.read()

replacements = {
    '${LLM_BASE_URL}':         llm_base_url,
    '${LLM_API_KEY}':          llm_api_key,
    '${LLM_PROVIDER_ID}':      llm_provider_id,
    '${LLM_MODEL_ID}':         llm_model_id,
    '${GATEWAY_TOKEN}':        gateway_token,
    '${BROWSER_PATH}':         browser_path,
    '${BRAVE_SEARCH_API_KEY}': brave_key,
    '${FEISHU_APP_ID}':        feishu_id,
    '${FEISHU_APP_SECRET}':    feishu_secret,
    '${TELEGRAM_BOT_TOKEN}':   telegram_token,
    '~/.openclaw/workspace':   workspace,
}

for placeholder, value in replacements.items():
    c = c.replace(placeholder, value)

with open(dst, 'w') as f:
    f.write(c)
PYEOF

  # 可选模块：key 为空则关闭 enabled
  if [ -z "$BRAVE_SEARCH_API_KEY" ]; then
    info "关闭 tools.web.search..."
    python3 -c "
import re, sys
with open('$DST_CONFIG', 'r') as f: c = f.read()
c = re.sub(r'(\"search\"\s*:\s*\{[^}]*?)\"enabled\"\s*:\s*true', r'\1\"enabled\": false', c, flags=re.DOTALL)
with open('$DST_CONFIG', 'w') as f: f.write(c)
"
    warn "Brave Search 已禁用"
  fi

  if [ -z "$FEISHU_APP_ID" ] || [ -z "$FEISHU_APP_SECRET" ]; then
    info "关闭 channels.feishu 和 plugins.feishu..."
    python3 -c "
import re
with open('$DST_CONFIG', 'r') as f: c = f.read()
c = re.sub(r'(\"feishu\"\s*:\s*\{[^{]*?)\"enabled\"\s*:\s*true', r'\1\"enabled\": false', c, flags=re.DOTALL)
with open('$DST_CONFIG', 'w') as f: f.write(c)
"
    warn "飞书集成已禁用"
  fi

  if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    info "关闭 channels.telegram..."
    python3 -c "
import re
with open('$DST_CONFIG', 'r') as f: c = f.read()
c = re.sub(r'(\"telegram\"\s*:\s*\{[^}]*?)\"enabled\"\s*:\s*true', r'\1\"enabled\": false', c, flags=re.DOTALL)
with open('$DST_CONFIG', 'w') as f: f.write(c)
"
    warn "Telegram 已禁用"
  fi

  if [ "${WHATSAPP_ENABLED:-true}" = "false" ]; then
    info "关闭 channels.whatsapp..."
    python3 -c "
import re
with open('$DST_CONFIG', 'r') as f: c = f.read()
c = re.sub(r'(\"whatsapp\"\s*:\s*\{[^}]*?)\"enabled\"\s*:\s*true', r'\1\"enabled\": false', c, flags=re.DOTALL)
with open('$DST_CONFIG', 'w') as f: f.write(c)
"
    warn "WhatsApp 已禁用"
  fi

  if [ -z "$BROWSER_PATH" ]; then
    info "移除 browser.executablePath（使用自动探测）..."
    python3 -c "
import re
with open('$DST_CONFIG', 'r') as f: c = f.read()
c = re.sub(r',?\s*\"executablePath\"\s*:\s*\"\"', '', c)
with open('$DST_CONFIG', 'w') as f: f.write(c)
"
  fi

  chmod 600 "$DST_CONFIG"
  success "openclaw.json 已写入 $DST_CONFIG"
}

# ───────────────────────────────────────────────────────
# 4. 部署 workspace/*.md
# ───────────────────────────────────────────────────────
deploy_workspace() {
  SRC_WS="$SCRIPT_DIR/workspace"
  DST_WS="$OPENCLAW_DIR/workspace"

  [ -d "$SRC_WS" ] || error "找不到 $SRC_WS 目录"

  mkdir -p "$DST_WS"

  for MD_FILE in "$SRC_WS"/*.md; do
    FNAME=$(basename "$MD_FILE")
    DST_FILE="$DST_WS/$FNAME"

    if [ -f "$DST_FILE" ]; then
      read -p "  $FNAME 已存在，覆盖？(y/N): " OW
      [[ "$OW" =~ ^[Yy]$ ]] || { warn "跳过 $FNAME"; continue; }
    fi

    cp "$MD_FILE" "$DST_FILE"
    success "  已部署 $FNAME"
  done
}

# ───────────────────────────────────────────────────────
# 5. 验证
# ───────────────────────────────────────────────────────
verify() {
  if command -v openclaw &>/dev/null; then
    info "运行 openclaw doctor --fix..."
    openclaw doctor --fix || warn "doctor 报告了问题，请检查上方输出"
  else
    warn "openclaw 未找到，请重新加载 shell 后手动运行: openclaw doctor --fix"
  fi
}

# ───────────────────────────────────────────────────────
# 主流程
# ───────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     OpenClaw 一键安装脚本             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

load_env
install_openclaw
deploy_config
deploy_workspace
verify

echo ""
echo -e "${GREEN}✓ 安装完成！${NC}"
echo ""
echo "  配置文件 : $OPENCLAW_DIR/openclaw.json"
echo "  Workspace: $OPENCLAW_DIR/workspace/"
echo ""
echo "  启动命令 : openclaw start"
echo ""