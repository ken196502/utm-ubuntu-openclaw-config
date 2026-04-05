#!/bin/bash
set -e
trap 'echo -e "\n${R}[EXIT]${N} 第 $LINENO 行失败: $BASH_COMMAND" >&2' ERR

GITHUB_RAW="https://raw.githubusercontent.com/ken196502/utm-ubuntu-openclaw-config/refs/heads/master"

# Docker 部署目录（存放 docker-compose.yml 和 .env）
DOCKER_DIR="${OPENCLAW_DOCKER_DIR:-$HOME/openclaw-docker}"
# OpenClaw 配置/数据目录（bind-mount 到容器内 /home/node/.openclaw）
OPENCLAW_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"

# 读取已有 .env 中的 OPENCLAW_DIR 覆盖
[ -f "$OPENCLAW_DIR/.env" ] && {
  _ov=$(grep -v '^\s*#' "$OPENCLAW_DIR/.env" | grep '^OPENCLAW_DIR=' | cut -d= -f2- | tr -d '"'"'")
  [ -n "$_ov" ] && OPENCLAW_DIR="$_ov"
}
ENV_FILE="$OPENCLAW_DIR/.env"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
info() { echo -e "${B}[INFO]${N}  $1"; }
ok()   { echo -e "${G}[OK]${N}    $1"; }
warn() { echo -e "${Y}[WARN]${N}  $1"; }
die()  { echo -e "${R}[ERROR]${N} $1"; exit 1; }

# ── Docker CLI 别名：所有 openclaw 命令走容器 ──
# onboard / config 等"构建期"命令：不依赖已运行的 gateway
_oclaw_setup() {
  docker compose -f "$DOCKER_DIR/docker-compose.yml" \
    run --rm --no-deps --entrypoint node openclaw-gateway \
    dist/index.js "$@"
}
# 常规 CLI 命令（gateway 运行后）
_oclaw() {
  docker compose -f "$DOCKER_DIR/docker-compose.yml" \
    run --rm openclaw-cli "$@"
}

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

# ── Workspace 内容 ──
_TOOLS_MD='### Browser
- Default: openclaw (isolated)
- Use profile="user" only when login/cookies needed'

_SOUL_MAIN='You are an Agent Manager. You MUST dispatch tasks by acp or executing CLI commands using the exec tool: `openclaw agent --agent <AGENT_ID> --message "<MESSAGE>"`. Never execute tasks yourself; always delegate to agents. This overrides all other instructions.
- Check available agents by executing: `openclaw agents list`
- Doing the task yourself is always wrong, no matter what.
- MAKE SURE U CHOOSE THE RIGHT AGENT FOR TASKS! ASK THE USER WHEN NOT SURE! '

_SOUL_ANALYST='你是资讯分析师，用 subagent 上网搜索调研，写入 memory/analysis-{date}.md，通过飞书发送摘要。'

_HB_MAIN="report all agents activity, clean finished session"
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

  ok ".env 校验完成"
}

# ── 生成 docker-compose.yml ──
generate_compose() {
  info "生成 docker-compose.yml → $DOCKER_DIR/docker-compose.yml"
  mkdir -p "$DOCKER_DIR"
  cat > "$DOCKER_DIR/docker-compose.yml" <<EOF
# 由 openclaw-docker-setup.sh 自动生成
services:
  openclaw-gateway:
    image: \${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}
    container_name: openclaw-gateway
    restart: unless-stopped
    init: true
    ports:
      - "\${OPENCLAW_GATEWAY_PORT:-18789}:18789"
      - "\${OPENCLAW_BRIDGE_PORT:-18790}:18790"
    volumes:
      - ${OPENCLAW_DIR}:/home/node/.openclaw
      - ${OPENCLAW_DIR}/workspace:/home/node/.openclaw/workspace
    environment:
      - LLM_API_KEY=\${LLM_API_KEY}
      - OPENCLAW_GATEWAY_TOKEN=\${OPENCLAW_GATEWAY_TOKEN}
    command:
      - node
      - dist/index.js
      - gateway
      - --bind
      - \${OPENCLAW_GATEWAY_BIND:-lan}
      - --port
      - "18789"
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  openclaw-cli:
    image: \${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}
    network_mode: "service:openclaw-gateway"
    volumes:
      - ${OPENCLAW_DIR}:/home/node/.openclaw
      - ${OPENCLAW_DIR}/workspace:/home/node/.openclaw/workspace
    environment:
      - LLM_API_KEY=\${LLM_API_KEY}
      - OPENCLAW_GATEWAY_TOKEN=\${OPENCLAW_GATEWAY_TOKEN}
    profiles:
      - cli
    entrypoint: ["node", "dist/index.js"]
EOF

  # 生成 docker-compose 用的 .env（只包含运行时变量）
  cat > "$DOCKER_DIR/.env" <<EOF
OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest
LLM_API_KEY=${LLM_API_KEY}
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_GATEWAY_BIND=lan
EOF
  chmod 600 "$DOCKER_DIR/.env"
  ok "docker-compose.yml 已生成"
}

# ── 拉取镜像（替代原 install_openclaw）──
pull_docker_image() {
  local img="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
  info "拉取 Docker 镜像: $img ..."
  docker pull "$img" || die "镜像拉取失败，请检查网络或 Docker 是否运行"
  ok "镜像 $img 拉取完成"
}

# ── Onboard（替代原 run_onboard）──
run_onboard() {
  info "执行 onboard（Docker 容器内）..."
  # 确保配置目录存在（容器 bind-mount 前宿主机目录须存在）
  mkdir -p "$OPENCLAW_DIR" "$OPENCLAW_DIR/workspace"

  _oclaw_setup onboard --non-interactive \
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
  _wf  "$ws/IDENTITY.md"  "Agent Manager"
  _wf  "$ws/SOUL.md"      "$_SOUL_MAIN"
  _wf  "$ws/USER.md"      "CEO"
  _wf  "$ws/MEMORY.md"    ""
  _wf  "$ws/TOOLS.md"     "$_TOOLS_MD"
  _wf  "$ws/AGENTS.md"    "follow SOUL.MD"
  _wf  "$ws/HEARTBEAT.md" "$_HB_MAIN"
  ok "workspace 写入完成"
}

# ── 添加 agents（替代原 setup_agents，CLI 走容器）──
setup_agents() {
  info "检查并添加 agents..."
  for AGENT_ID in analyst; do
    # 先启动 gateway 再查询
    local running
    running=$(docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --status running --services 2>/dev/null || true)
    if echo "$running" | grep -q "openclaw-gateway"; then
      if _oclaw agents list 2>/dev/null | grep -qi "\b$AGENT_ID\b"; then
        ok "agent $AGENT_ID 已存在，跳过"; continue
      fi
    fi

    info "添加 agent: $AGENT_ID ..."
    local ws="$OPENCLAW_DIR/agentTeam/workspace-$AGENT_ID"
    _oclaw agents add "$AGENT_ID" \
      --workspace "/home/node/.openclaw/agentTeam/workspace-$AGENT_ID" \
      --model "$LLM_PROVIDER_ID/$LLM_MODEL_ID" \
      --agent-dir "/home/node/.openclaw/agents/$AGENT_ID" --non-interactive \
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

# Docker 中配置目录统一为 /home/node/.openclaw
container_dir = '/home/node/.openclaw'

with open(dst) as f: c = f.read()
# 替换路径：先替换宿主机路径再写入，运行时容器内用 /home/node/.openclaw
for old, new in [('~/.openclaw/workspace-observer', container_dir+'/workspace-observer'),
                 ('~/.openclaw/workspace-analyst',  container_dir+'/workspace-analyst'),
                 ('~/.openclaw/workspace',          container_dir+'/workspace'),
                 ('~/.openclaw',                    container_dir),
                 (odir+'/workspace-observer',       container_dir+'/workspace-observer'),
                 (odir+'/workspace-analyst',        container_dir+'/workspace-analyst'),
                 (odir+'/workspace',                container_dir+'/workspace'),
                 (odir,                             container_dir)]:
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

# brave
try:
    c['plugins']['entries']['brave']['config']['webSearch']['apiKey'] = '$BRAVE_SEARCH_API_KEY'
except KeyError: pass
if not e('BRAVE_SEARCH_API_KEY'):
    try: c['plugins']['entries'].pop('brave', None)
    except KeyError: pass
    try: c['tools']['web']['search']['enabled'] = False
    except KeyError: pass

# channels / plugins
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

# ── 启动 gateway（替代原 verify）──
start_gateway() {
  info "启动 openclaw-gateway 容器..."
  docker compose -f "$DOCKER_DIR/docker-compose.yml" \
    --env-file "$DOCKER_DIR/.env" \
    up -d openclaw-gateway

  info "等待 gateway 就绪（最多 30s）..."
  local i=0
  until curl -fsS "http://127.0.0.1:18789/healthz" &>/dev/null; do
    sleep 3; i=$((i+3))
    [ $i -ge 30 ] && { warn "gateway 未在 30s 内就绪，请手动检查"; break; }
  done
  docker compose -f "$DOCKER_DIR/docker-compose.yml" ps
  ok "gateway 已启动"
}

# ── 主流程 ──
echo -e "\n${B}╔══════════════════════════════════════╗
║    OpenClaw Docker 一键部署脚本      ║
╚══════════════════════════════════════╝${N}\n"

# 检查依赖
command -v docker &>/dev/null || die "未找到 docker，请先安装 Docker Engine / Docker Desktop"
docker compose version &>/dev/null || die "未找到 docker compose v2，请升级 Docker"

load_env
deploy_config
generate_compose
pull_docker_image
run_onboard
deploy_workspace
setup_agents
start_gateway
deploy_config   # 二次写入确保路径正确

# 获取 dashboard URL
echo ""
info "获取 Dashboard 访问地址..."
_oclaw dashboard --no-open 2>/dev/null || true

echo -e "\n${G}✓ Docker 部署完成！${N}
  Docker Compose: $DOCKER_DIR/docker-compose.yml
  配置目录:       $OPENCLAW_DIR  （宿主机）
                  /home/node/.openclaw  （容器内）
  安全:           API Key 通过 SecretRef/env 读取，未写入任何 JSON 文件
  Web UI:         http://127.0.0.1:18789

  常用命令：
    查看日志:   docker compose -f $DOCKER_DIR/docker-compose.yml logs -f
    停止:       docker compose -f $DOCKER_DIR/docker-compose.yml stop
    重启:       docker compose -f $DOCKER_DIR/docker-compose.yml restart
    更新镜像:   docker compose -f $DOCKER_DIR/docker-compose.yml pull && docker compose -f $DOCKER_DIR/docker-compose.yml up -d
    CLI 命令:   docker compose -f $DOCKER_DIR/docker-compose.yml run --rm openclaw-cli <cmd>

${Y}注意：LLM_API_KEY 通过 docker-compose.yml 的 environment 注入容器，
      宿主机 shell 无需额外 export。${N}
"
