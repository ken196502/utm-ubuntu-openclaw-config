#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

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

verify
