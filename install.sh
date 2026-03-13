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
#    - 不存在 → 生成模板，提示用户填写后重跑，直接退出
#    - 存在   → 加载，校验必填项，可选项给 warn 提示
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

  # ── 必填校验 ──────────────────────────────
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

  # ── 可选项提示 ────────────────────────────
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
#    a) perl 替换所有 ${VAR} 占位符
#    b) 可选 key 为空时，用 perl 把对应模块的 enabled 改为 false
# ───────────────────────────────────────────────────────
deploy_config() {
  SRC_CONFIG="$SCRIPT_DIR/openclaw.json"
  DST_CONFIG="$OPENCLAW_DIR/openclaw.json"

  [ -f "$SRC_CONFIG" ] || error "找不到 $SRC_CONFIG，请确认脚本和 openclaw.json 在同一目录"

  mkdir -p "$OPENCLAW_DIR"

  # 备份旧配置
  if [ -f "$DST_CONFIG" ]; then
    BACKUP="$DST_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$DST_CONFIG" "$BACKUP"
    warn "已备份旧配置 → $BACKUP"
  fi

  # workspace 实际路径
  WORKSPACE_PATH="$OPENCLAW_DIR/workspace"

  # ── 替换所有占位符 ────────────────────────
  info "写入 openclaw.json 并替换占位符..."
  # workspace 路径：把 json 里的 ~/.openclaw/workspace 展开为实际绝对路径
  perl -pe "
    s|\\\${LLM_BASE_URL}|${LLM_BASE_URL}|g;
    s|\\\${LLM_API_KEY}|${LLM_API_KEY}|g;
    s|\\\${LLM_PROVIDER_ID}|${LLM_PROVIDER_ID}|g;
    s|\\\${LLM_MODEL_ID}|${LLM_MODEL_ID}|g;
    s|\\\${GATEWAY_TOKEN}|${GATEWAY_TOKEN}|g;
    s|\\\${BROWSER_PATH}|${BROWSER_PATH}|g;
    s|\\\${BRAVE_SEARCH_API_KEY}|${BRAVE_SEARCH_API_KEY}|g;
    s|\\\${FEISHU_APP_ID}|${FEISHU_APP_ID}|g;
    s|\\\${FEISHU_APP_SECRET}|${FEISHU_APP_SECRET}|g;
    s|\\\${TELEGRAM_BOT_TOKEN}|${TELEGRAM_BOT_TOKEN}|g;
    s|\\\${OPENCLAW_WORKSPACE}|${WORKSPACE_PATH}|g;
  " "$SRC_CONFIG" > "$DST_CONFIG"

  # 展开 workspace 路径（~ 不被 openclaw 自动解析）
  perl -i -pe "s|~/.openclaw/workspace|${WORKSPACE_PATH}|g" "$DST_CONFIG"

  # ── 可选模块：key 为空则关闭 enabled ──────

  if [ -z "$BRAVE_SEARCH_API_KEY" ]; then
    info "关闭 tools.web.search..."
    perl -i -0pe 's|("web"\s*:\s*\{[^}]*?"search"\s*:\s*\{[^}]*?)"enabled"\s*:\s*true|\1"enabled": false|s' "$DST_CONFIG"
    warn "Brave Search 已禁用"
  fi

  if [ -z "$FEISHU_APP_ID" ] || [ -z "$FEISHU_APP_SECRET" ]; then
    info "关闭 channels.feishu 和 plugins.feishu..."
    perl -i -0pe '
      s|("channels"\s*:\s*\{.*?"feishu"\s*:\s*\{.*?)"enabled"\s*:\s*true|\1"enabled": false|s;
      s|("plugins"\s*:\s*\{.*?"feishu"\s*:\s*\{.*?)"enabled"\s*:\s*true|\1"enabled": false|s;
    ' "$DST_CONFIG"
    warn "飞书集成已禁用"
  fi

  if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    info "关闭 channels.telegram..."
    perl -i -0pe 's|("telegram"\s*:\s*\{[^}]*?)"enabled"\s*:\s*true|\1"enabled": false|s' "$DST_CONFIG"
    warn "Telegram 已禁用"
  fi

  # WhatsApp 无 token，默认 enabled:true，如需禁用请在 .env 加 WHATSAPP_ENABLED=false
  if [ "${WHATSAPP_ENABLED:-true}" = "false" ]; then
    info "关闭 channels.whatsapp..."
    perl -i -0pe 's|("whatsapp"\s*:\s*\{[^}]*?)"enabled"\s*:\s*true|\1"enabled": false|s' "$DST_CONFIG"
    warn "WhatsApp 已禁用"
  fi

  if [ -z "$BROWSER_PATH" ]; then
    info "BROWSER_PATH 为空，移除 browser.executablePath（使用自动探测）..."
    perl -i -0pe 's|"executablePath"\s*:\s*"",?\s*\n?||g' "$DST_CONFIG"
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