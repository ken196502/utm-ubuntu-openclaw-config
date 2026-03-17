# HEARTBEAT.md

## 心跳检查项

### 1. Observer & Analyst Agent 状态检查
- 运行: `openclaw agents list`
- 检查 observer 和 analyst 两个专用代理是否正常配置
- 验证 agent 目录是否存在
- 记录每个 agent 的最后活跃时间

### 2. 技能执行状态
- observer agent 负责执行 rss-monitor-skill
- analyst agent 负责执行 travel-recommendation-skill
- 检查技能执行日志（如果配置了的话）
- 汇报最近一次执行结果

### 3. Heartbeat 报告内容
每次心跳检查后，输出：
- ✅ observer: 配置状态 + 上次执行时间 + 结果摘要
- ✅ analyst: 配置状态 + 上次执行时间 + 结果摘要
- 任何异常或错误信息

### 4. 自动恢复
- 如果发现 agent 配置丢失，自动重建（使用 agents add）
- 确保 workspace 路径使用正确的 OPENCLAW_DIR 环境变量或默认值

## 计划任务
- 定期检查并更新 RSS 数据
- 如果有新旅行文章，分析师生成推荐摘要