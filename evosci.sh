#!/usr/bin/env bash
set -euo pipefail

# EvoScientist 管理脚本（纯 WSL2）
#
# 用法：
#   ./evosci.sh start      启动 EvoScientist（后端 + WebUI）
#   ./evosci.sh status     查看运行状态
#   ./evosci.sh stop       停止全部 EvoScientist 后台服务
#   ./evosci.sh restart    重启全部服务
#   ./evosci.sh update     安全更新到远端最新代码并重新同步依赖
#   ./evosci.sh help       显示本说明
#
# 访问地址：
#   WebUI: http://127.0.0.1:4716
#   后端:  http://127.0.0.1:6174
#
# 日志与 PID（默认全部落在仓库内，避免在 $HOME 重新创建旧目录）：
#   $REPO_ROOT/.state/evoscientist/evosci-webui.log
#   $REPO_ROOT/.state/evoscientist/evosci-webui.pid
#
# 设计要点：
#   1. 强制使用 WSL2 自己的 Node/npm，绝不调用 Windows node.exe；
#   2. 启动前清理可能残留的 Windows @evoscientist/webui 进程；
#   3. 使用 setsid 完全脱离当前会话，脚本退出后服务继续运行；
#   4. start 会等待 6174 后端和 4716 前端真正就绪后才返回；
#   5. stop 会清理 evosci、langgraph、node、next-server 等整棵进程树。
#
# update 说明：
#   - 只以官方 upstream/main 为基线，把本地改动 rebase 到官方最新提交之后；
#   - 更新前若发现已跟踪文件改动，会先做临时快照，最终合并进唯一一条
#     本地改动提交，不会留在 commit history 中；
#   - 最终历史形态为：官方最新提交 A，后面只有一条本地提交 D；
#   - 出现冲突时，自动调用 DeepSeek（默认 deepseek-v4-flash）
#     解析冲突文件，解析失败则保留备份并提示手动处理；
#   - 更新后自动执行 uv sync --dev；
#   - 如果更新前服务正在运行，更新完成后会自动恢复启动；
#   - 从仓库根目录 .env 或环境变量读取冲突解析配置：DEEPSEEK_BASE_URL、
#     DEEPSEEK_MODEL、DEEPSEEK_API_KEY；
#   - 不要使用 git reset --hard、git checkout -- .、git clean -fd 等命令
#     来“处理”更新问题，它们可能丢弃本地改动。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
PYTHON_BIN="$REPO_ROOT/.venv/bin/python"
WEBUI_DIR="$REPO_ROOT/WebUI"

FORK_REPO_URL="https://github.com/Karbo123/EvoScientist.git"
UPSTREAM_REPO_URL="https://github.com/EvoScientist/EvoScientist.git"
FORK_WEBUI_URL="https://github.com/Karbo123/EvoScientist-WebUI.git"
UPSTREAM_WEBUI_URL="https://github.com/EvoScientist/EvoScientist-WebUI.git"

CONFIG_DIR="$REPO_ROOT/.config/evoscientist"
DATA_DIR="${EVOSCIENTIST_DATA_DIR:-$REPO_ROOT/.evosci-data}"
STATE_DIR="$REPO_ROOT/.state/evoscientist"
LOG_FILE="$STATE_DIR/evosci-webui.log"
PID_FILE="$STATE_DIR/evosci-webui.pid"

BACKEND_URL="http://127.0.0.1:6174"
BACKEND_HEALTH_URL="$BACKEND_URL/ok"
WEBUI_URL="http://127.0.0.1:4716"

_env_value() {
  local key="$1"
  if [[ -f "$REPO_ROOT/.env" ]]; then
    sed -n "s/^${key}=//p" "$REPO_ROOT/.env" | head -1
  fi
}

RESOLVE_BASE_URL="${DEEPSEEK_BASE_URL:-$(_env_value DEEPSEEK_BASE_URL)}"
RESOLVE_BASE_URL="${RESOLVE_BASE_URL:-https://api.deepseek.com/v1}"
RESOLVE_MODEL="${DEEPSEEK_MODEL:-$(_env_value DEEPSEEK_MODEL)}"
RESOLVE_MODEL="${RESOLVE_MODEL:-deepseek-v4-flash}"

WORKSPACE_DIR="${EVOSCIENTIST_WORKSPACE_DIR:-$REPO_ROOT}"

# ---- 环境检查 --------------------------------------------------------------

if [[ "$WORKSPACE_DIR" != /* ]]; then
  WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "错误：找不到 $PYTHON_BIN"
  echo "请先在 $REPO_ROOT 执行：uv sync --dev"
  exit 1
fi

if [[ ! -d "$WORKSPACE_DIR" ]]; then
  echo "错误：工作区不存在：$WORKSPACE_DIR"
  exit 1
fi

# 强制优先使用 WSL2 的 Node/npm。
WSL_NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
if [[ -n "$WSL_NODE_BIN" && -x "$WSL_NODE_BIN/node" && -x "$WSL_NODE_BIN/npm" ]]; then
  export PATH="$WSL_NODE_BIN:$PATH"
fi

if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "错误：WSL2 内找不到 Node.js/npm。"
  echo "请先安装 WSL2 内的 Node.js 20+（例如通过 nvm）。"
  exit 1
fi

NODE_RESOLVED="$(command -v node)"
NPM_RESOLVED="$(command -v npm)"
if [[ "$NODE_RESOLVED" == /mnt/c/* || "$NPM_RESOLVED" == /mnt/c/* ]]; then
  echo "错误：检测到仍会使用 Windows 的 Node/npm："
  echo "  node: $NODE_RESOLVED"
  echo "  npm:  $NPM_RESOLVED"
  echo "请确保 PATH 中 WSL2 Node 优先于 /mnt/c/nvm4w/nodejs。"
  exit 1
fi

# ---- 工具函数 --------------------------------------------------------------

_running_pids() {
  # 收集所有相关后台进程，避免重复启动，也避免把残留子进程当成“已停止”。
  local pids=""
  local found

  found="$(pgrep -f 'EvoScientist\.deploy\.webui_launcher' 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    pids="$pids $found"
  fi

  found="$(pgrep -f 'EvoScientist/langgraph_dev/langgraph.json' 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    pids="$pids $found"
  fi

  found="$(pgrep -f '@evoscientist/webui|evoscientist-webui' 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    pids="$pids $found"
  fi

  if [[ -f "$PID_FILE" ]]; then
    local recorded
    recorded="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$recorded" =~ ^[0-9]+$ ]] && kill -0 "$recorded" 2>/dev/null; then
      pids="$pids $recorded"
    fi
  fi

  # 去重并只保留真实存在的进程。
  printf '%s\n' $pids \
    | grep -E '^[0-9]+$' \
    | sort -un \
    | while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
          printf '%s\n' "$pid"
        fi
      done \
    | tr '\n' ' ' \
    | sed 's/ $//' \
    || true
}

_stop_orphan_webui() {
  # 清理 Windows 侧可能残留的 @evoscientist/webui（纯 WSL2 不应再出现，但保留兜底）。
  if ! command -v powershell.exe >/dev/null 2>&1; then
    return 0
  fi

  local pids
  pids="$(
    powershell.exe -NoProfile -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" |
       Where-Object { \$_.CommandLine -match 'evoscientist' } |
       Select-Object -ExpandProperty ProcessId" \
      2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' || true
  )"
  if [[ -z "$pids" ]]; then
    return 0
  fi

  echo "检测到 Windows 残留 WebUI 进程，正在清理：$pids"
  for pid in $pids; do
    powershell.exe -NoProfile -Command "Stop-Process -Id $pid -Force" \
      2>/dev/null || true
  done
}

_http_ready() {
  local url="$1"
  local code
  code="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

_all_stopped() {
  [[ -z "$(_running_pids)" ]]
}

_stop_all() {
  local pids
  pids="$(_running_pids)"

  if [[ -n "$pids" ]]; then
    echo "正在停止 EvoScientist（PID: $pids）..."
    kill $pids 2>/dev/null || true
  fi

  _stop_orphan_webui

  for _ in $(seq 1 40); do
    if _all_stopped; then
      break
    fi
    sleep 0.5
  done

  local remaining
  remaining="$(_running_pids)"
  if [[ -n "$remaining" ]]; then
    echo "进程未在 20 秒内退出，强制结束：$remaining"
    kill -9 $remaining 2>/dev/null || true
    sleep 1
  fi

  rm -f "$PID_FILE"
}

# ---- 更新与冲突处理 --------------------------------------------------------

_resolve_api_key() {
  local key
  key="${DEEPSEEK_API_KEY:-$(_env_value DEEPSEEK_API_KEY)}"
  if [[ -n "$key" ]]; then
    printf '%s' "$key"
  fi
}

_llm_resolve_file() {
  local file="$1"
  local size
  local key
  local resolved
  local tmp

  size="$(wc -c < "$file" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$size" || "$size" -gt 200000 ]]; then
    echo "跳过自动解决：$file 超过 200KB 或无法读取。"
    return 1
  fi

  key="$(_resolve_api_key)"
  if [[ -z "$key" ]]; then
    echo "跳过自动解决：未配置 API key（可设置 DEEPSEEK_API_KEY）。"
    return 1
  fi

  echo "调用 $RESOLVE_MODEL 解决冲突：$file"
  resolved="$(
    DEEPSEEK_API_KEY="$key" \
      "$REPO_ROOT/.venv/bin/python" - "$file" "$RESOLVE_MODEL" "$RESOLVE_BASE_URL" <<'PY'
import json
import os
import sys
import urllib.request

path, model, base_url = sys.argv[1:4]
with open(path, encoding="utf-8", errors="replace") as fh:
    content = fh.read()

api_key = os.environ.get("DEEPSEEK_API_KEY", "")
if not base_url.endswith("/"):
    base_url += "/"
url = base_url + "chat/completions"

prompt = f"""Resolve the git conflict in the file below.
File: {path}
The local EvoScientist/EvoScientist-WebUI changes are authoritative. Preserve
their custom behavior, especially performance fixes, database/history safety,
workspace isolation, and local UI features. Integrate upstream's meaningful
official changes only when they do not remove or weaken those local features.
Keep both sides' compatible changes, do not invent new behavior, and remove
all git conflict markers.
Output ONLY the resolved file content with no commentary and no code fences.
"""
payload = {
    "model": model,
    "messages": [
        {
            "role": "system",
            "content": (
                "You are an expert git conflict resolver. Reply with only the "
                "resolved file content."
            ),
        },
        {"role": "user", "content": prompt + "\n\nCONFLICTED FILE:\n" + content},
    ],
    "temperature": 0,
}

req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
    },
    method="POST",
)
with urllib.request.urlopen(req, timeout=180) as resp:
    data = json.load(resp)
text = data["choices"][0]["message"]["content"]
lines = text.splitlines()
if lines and lines[0].startswith("```"):
    lines = lines[1:]
if lines and lines[-1].strip() == "```":
    lines = lines[:-1]
sys.stdout.write("\n".join(lines))
PY
  )" || return 1

  if [[ -z "$resolved" ]]; then
    echo "模型返回空内容，跳过自动解决：$file"
    return 1
  fi

  if printf '%s\n' "$resolved" | grep -Eq '^(<<<<<<<|=======|>>>>>>>)'; then
    echo "模型输出仍包含冲突标记，跳过自动解决：$file"
    return 1
  fi

  tmp="$(mktemp "$REPO_ROOT/.git/.evosci-resolve.XXXXXX")"
  printf '%s\n' "$resolved" > "$tmp"

  case "$file" in
    *.py)
      if ! "$REPO_ROOT/.venv/bin/python" -m py_compile "$tmp" 2>/dev/null; then
        echo "解决结果 Python 语法校验失败：$file"
        rm -f "$tmp"
        return 1
      fi
      ;;
    *.sh)
      if ! bash -n "$tmp" 2>/dev/null; then
        echo "解决结果 Shell 语法校验失败：$file"
        rm -f "$tmp"
        return 1
      fi
      ;;
    *.yaml|*.yml)
      if ! "$REPO_ROOT/.venv/bin/python" -c \
        'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
        echo "解决结果 YAML 语法校验失败：$file"
        rm -f "$tmp"
        return 1
      fi
      ;;
  esac

  chmod --reference="$file" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  echo "已自动解决并写入：$file"
}

_auto_resolve_conflicts() {
  local repo_dir="${1:-$REPO_ROOT}"
  local files
  local backup_dir
  local f

  files="$(git -C "$repo_dir" diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [[ -z "$files" ]]; then
    echo "没有检测到未解决的冲突文件。"
    return 1
  fi

  backup_dir="/tmp/evosci-conflict-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  echo "冲突文件已备份到：$backup_dir"

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -f "$repo_dir/$f" ]]; then
      cp "$repo_dir/$f" "$backup_dir/$(basename "$f").conflicted"
    fi
    if ! (cd "$repo_dir" && _llm_resolve_file "$f"); then
      echo "自动解决失败，请手动处理。备份位于：$backup_dir"
      return 1
    fi
    git -C "$repo_dir" add "$f"
  done <<< "$files"

  echo "所有冲突已自动解决并暂存。"
}

_LOCAL_SNAPSHOT_CREATED=0

_local_commit_message() {
  local repo_dir="$1"
  local base="$2"
  local fallback="$3"
  local count
  count="$(git -C "$repo_dir" rev-list --count "$base"..HEAD 2>/dev/null || echo 0)"
  if [[ "$count" -eq 1 ]]; then
    git -C "$repo_dir" log -1 --format=%s
  else
    printf '%s\n' "$fallback"
  fi
}

_snapshot_local_changes() {
  local repo_dir="$1"
  local label="$2"
  _LOCAL_SNAPSHOT_CREATED=0
  git -C "$repo_dir" add -u
  if git -C "$repo_dir" diff --cached --quiet; then
    return 0
  fi

  echo "检测到 $label 已跟踪文件改动，先做临时快照（最终合并进唯一本地提交）。"
  git -C "$repo_dir" -c user.name="EvoScientist Local" \
      -c user.email="local@evoscientist" \
      commit -m "chore: pre-update local snapshot $(date +%Y%m%d-%H%M%S)"
  _LOCAL_SNAPSHOT_CREATED=1
}

_ensure_remotes() {
  local repo_dir="$1"
  local label="$2"
  local fork_url="$3"
  local upstream_url="$4"

  if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    if [[ "$(git -C "$repo_dir" remote get-url origin)" != "$fork_url" ]]; then
      echo "将 $label 的 origin 切换为 fork：$fork_url"
      git -C "$repo_dir" remote set-url origin "$fork_url"
    fi
  else
    git -C "$repo_dir" remote add origin "$fork_url"
  fi

  if git -C "$repo_dir" remote get-url upstream >/dev/null 2>&1; then
    if [[ "$(git -C "$repo_dir" remote get-url upstream)" != "$upstream_url" ]]; then
      echo "将 $label 的 upstream 指向官方仓库：$upstream_url"
      git -C "$repo_dir" remote set-url upstream "$upstream_url"
    fi
  else
    git -C "$repo_dir" remote add upstream "$upstream_url"
  fi
}

_rebase_onto_upstream() {
  local repo_dir="$1"
  local label="$2"
  local old_upstream
  local new_upstream
  local attempts=0

  new_upstream="$(git -C "$repo_dir" rev-parse upstream/main)"
  old_upstream="$(git -C "$repo_dir" merge-base upstream/main HEAD)"
  if [[ "$old_upstream" == "$new_upstream" ]]; then
    echo "$label 已基于官方最新，无需 rebase。"
    return 0
  fi

  echo "$label 将本地改动 rebase 到官方最新..."
  if git -C "$repo_dir" rebase upstream/main; then
    echo "$label rebase 完成。"
    return 0
  fi

  if ! git -C "$repo_dir" diff --name-only --diff-filter=U | grep -q .; then
    echo "$label rebase 失败，但未检测到冲突，请手动检查 git 状态。"
    return 1
  fi

  echo "$label rebase 遇到冲突，开始自动解决。"
  while git -C "$repo_dir" diff --name-only --diff-filter=U | grep -q .; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 10 ]]; then
      echo "$label 自动解决次数过多，请手动处理剩余冲突。"
      return 1
    fi
    _auto_resolve_conflicts "$repo_dir" || return 1
    if GIT_EDITOR=true git -C "$repo_dir" rebase --continue; then
      echo "$label rebase 完成。"
      return 0
    fi
    if ! git -C "$repo_dir" diff --name-only --diff-filter=U | grep -q .; then
      echo "$label rebase --continue 失败，请手动检查 git 状态。"
      return 1
    fi
  done
  echo "$label 冲突已全部解决。"
  return 0
}

_squash_onto_upstream() {
  local repo_dir="$1"
  local label="$2"
  local message="$3"

  git -C "$repo_dir" reset --soft upstream/main
  if git -C "$repo_dir" diff --cached --quiet; then
    echo "$label 没有本地改动，无需生成新提交。"
    return 0
  fi

  git -C "$repo_dir" -c user.name="EvoScientist Local" \
      -c user.email="local@evoscientist" \
      commit -m "$message"
  echo "$label 已生成唯一本地提交：$(git -C "$repo_dir" log -1 --format='%h %s')"
}

_update_webui_submodule() {
  if [[ ! -f "$WEBUI_DIR/package.json" ]]; then
    echo "初始化 WebUI submodule..."
    git submodule update --init --recursive
  fi

  local branch
  local old_upstream
  local new_upstream
  local count_before
  local message
  branch="$(git -C "$WEBUI_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$branch" == "HEAD" || -z "$branch" ]]; then
    if git -C "$WEBUI_DIR" rev-parse --verify -q main >/dev/null 2>&1; then
      git -C "$WEBUI_DIR" switch main
      branch="main"
    else
      git -C "$WEBUI_DIR" switch -c main
      branch="main"
    fi
  fi

  echo "拉取 WebUI 官方仓库更新..."
  _ensure_remotes "$WEBUI_DIR" "WebUI" "$FORK_WEBUI_URL" "$UPSTREAM_WEBUI_URL"
  git -C "$WEBUI_DIR" fetch upstream

  new_upstream="$(git -C "$WEBUI_DIR" rev-parse upstream/main)"
  old_upstream="$(git -C "$WEBUI_DIR" merge-base upstream/main HEAD)"
  count_before="$(git -C "$WEBUI_DIR" rev-list --count upstream/main..HEAD 2>/dev/null || echo 0)"
  message="$(_local_commit_message "$WEBUI_DIR" upstream/main "feat: local WebUI changes")"

  _snapshot_local_changes "$WEBUI_DIR" "WebUI"
  if ! _rebase_onto_upstream "$WEBUI_DIR" "WebUI"; then
    return 1
  fi

  if [[ "$old_upstream" == "$new_upstream" && "$count_before" -le 1 && "$_LOCAL_SNAPSHOT_CREATED" -eq 0 ]]; then
    echo "WebUI 保持唯一本地提交。"
  else
    _squash_onto_upstream "$WEBUI_DIR" "WebUI" "$message"
  fi

  echo "同步 WebUI 依赖..."
  (cd "$WEBUI_DIR" && npm ci --include=optional)
  echo "构建 WebUI..."
  (cd "$WEBUI_DIR" && npm run build)
}

# ---- 子命令 --------------------------------------------------------------

start() {
  local existing
  existing="$(_running_pids)"
  if [[ -n "$existing" ]]; then
    echo "EvoScientist 已经在运行（PID: $existing）。"
    echo "WebUI: $WEBUI_URL"
    return 0
  fi

  _stop_orphan_webui
  mkdir -p "$STATE_DIR"

  # 必须同时传给 langgraph dev 和 WebUI，否则前端会报
  # “No active EvoScientist workspace found”。
  export EVOSCIENTIST_WORKSPACE_DIR="$WORKSPACE_DIR"
  export EVOSCIENTIST_DATA_DIR="$DATA_DIR"
  export XDG_CONFIG_HOME="$REPO_ROOT/.config"

  echo "正在启动 EvoScientist（工作区：$WORKSPACE_DIR）..."
  echo "配置:    $CONFIG_DIR"
  echo "数据:    $DATA_DIR"
  echo "状态:    $STATE_DIR"
  echo "Node:    $NODE_RESOLVED"
  echo "WebUI:   $WEBUI_DIR"

  if command -v setsid >/dev/null 2>&1; then
    setsid "$PYTHON_BIN" -m EvoScientist.deploy.webui_launcher </dev/null >>"$LOG_FILE" 2>&1 &
  else
    nohup "$PYTHON_BIN" -m EvoScientist.deploy.webui_launcher </dev/null >>"$LOG_FILE" 2>&1 &
  fi

  local evosci_pid=$!
  echo "$evosci_pid" >"$PID_FILE"

  local backend_ready=0
  for _ in $(seq 1 480); do
    if _http_ready "$BACKEND_HEALTH_URL"; then
      backend_ready=1
      break
    fi
    if ! kill -0 "$evosci_pid" 2>/dev/null; then
      echo "EvoScientist 主进程提前退出，最近日志："
      tail -60 "$LOG_FILE"
      _stop_all >/dev/null 2>&1 || true
      exit 1
    fi
    sleep 0.5
  done

  if [[ "$backend_ready" -ne 1 ]]; then
    echo "后端 $BACKEND_URL 未在 240 秒内就绪，最近日志："
    tail -80 "$LOG_FILE"
    _stop_all >/dev/null 2>&1 || true
    exit 1
  fi

  local webui_ready=0
  for _ in $(seq 1 480); do
    if _http_ready "$WEBUI_URL"; then
      webui_ready=1
      break
    fi
    if ! kill -0 "$evosci_pid" 2>/dev/null; then
      echo "EvoScientist WebUI 提前退出，最近日志："
      tail -60 "$LOG_FILE"
      _stop_all >/dev/null 2>&1 || true
      exit 1
    fi
    sleep 0.5
  done

  if [[ "$webui_ready" -ne 1 ]]; then
    echo "WebUI $WEBUI_URL 未在 240 秒内就绪，最近日志："
    tail -80 "$LOG_FILE"
    _stop_all >/dev/null 2>&1 || true
    exit 1
  fi

  echo "启动完成，主进程 PID: $evosci_pid"
  echo "WebUI: $WEBUI_URL"
  echo "后端:  $BACKEND_URL"
  echo "日志:  $LOG_FILE"
}

status() {
  local pids
  pids="$(_running_pids)"

  if [[ -n "$pids" ]]; then
    echo "EvoScientist 正在运行（PID: $pids）。"
  else
    echo "EvoScientist 没有检测到运行进程。"
  fi

  if _http_ready "$BACKEND_HEALTH_URL"; then
    echo "后端状态: 在线 ($BACKEND_HEALTH_URL)"
  else
    echo "后端状态: 离线 ($BACKEND_HEALTH_URL)"
  fi

  if _http_ready "$WEBUI_URL"; then
    echo "WebUI 状态: 在线 ($WEBUI_URL)"
  else
    echo "WebUI 状态: 离线 ($WEBUI_URL)"
  fi
}

stop() {
  _stop_all
  echo "EvoScientist 已停止。"
}

restart() {
  stop
  start
}

update() {
  local was_running=0

  if [[ ! -d "$REPO_ROOT/.git" ]]; then
    echo "错误：$REPO_ROOT 不是 git 仓库，无法使用 update。"
    exit 1
  fi
  _ensure_remotes "$REPO_ROOT" "主仓库" "$FORK_REPO_URL" "$UPSTREAM_REPO_URL"
  git fetch upstream
  if ! git rev-parse --verify upstream/main >/dev/null 2>&1; then
    echo "错误：未找到 upstream/main，请先确认官方远端地址。"
    exit 1
  fi

  if [[ -n "$(_running_pids)" ]]; then
    was_running=1
    echo "检测到服务正在运行，更新前先停止。"
    stop
  fi

  if ! _update_webui_submodule; then
    return 1
  fi

  local old_upstream
  local new_upstream
  local count_before
  local message
  new_upstream="$(git rev-parse upstream/main)"
  old_upstream="$(git merge-base upstream/main HEAD)"
  count_before="$(git rev-list --count upstream/main..HEAD 2>/dev/null || echo 0)"
  message="$(_local_commit_message "$REPO_ROOT" upstream/main "feat: local EvoScientist changes")"

  _snapshot_local_changes "$REPO_ROOT" "主仓库"
  if ! _rebase_onto_upstream "$REPO_ROOT" "主仓库"; then
    return 1
  fi

  if [[ "$old_upstream" == "$new_upstream" && "$count_before" -le 1 && "$_LOCAL_SNAPSHOT_CREATED" -eq 0 ]]; then
    echo "主仓库保持唯一本地提交。"
  else
    _squash_onto_upstream "$REPO_ROOT" "主仓库" "$message"
  fi

  echo "同步开发依赖..."
  uv sync --dev

  echo "更新完成。"
  echo "当前版本：$(git log -1 --format='%h %s')"

  if [[ "$was_running" -eq 1 ]]; then
    echo "更新前服务在运行，正在恢复启动。"
    start
  else
    echo "更新前服务未运行，执行 ./evosci.sh start 可启动。"
  fi
}

help() {
  cat <<'EOF'
EvoScientist 管理脚本（纯 WSL2）

用法：
  ./evosci.sh start      启动 EvoScientist（后端 + WebUI）
  ./evosci.sh status     查看运行状态
  ./evosci.sh stop       停止全部 EvoScientist 后台服务
  ./evosci.sh restart    重启全部服务
  ./evosci.sh update     安全更新到远端最新代码并重新同步依赖
  ./evosci.sh help       显示本说明

update 行为：
  1. 只拉取官方 upstream，并把本地改动 rebase 到官方最新提交之后；
  2. 未提交改动会做临时快照，最终合并进唯一一条本地提交 D；
  3. 冲突时调用 DeepSeek，优先保留本地 EvoScientist 功能；
  4. WebUI 自动 npm ci + npm run build；
  5. uv sync --dev；
  6. 更新前若服务在运行，更新后自动恢复。
  最终历史形态：官方最新提交 A，后面只有一条本地提交 D。

冲突解析配置优先读取仓库根目录 .env：
  DEEPSEEK_BASE_URL        默认 https://api.deepseek.com/v1
  DEEPSEEK_MODEL           默认 deepseek-v4-flash
  DEEPSEEK_API_KEY         必填（或作为环境变量提供）

日志与 PID 默认位于仓库内：
  .config/evoscientist/
  .evosci-data/
  .state/evoscientist/
EOF
}

case "${1:-start}" in
  start)
    start
    ;;
  status)
    status
    ;;
  stop)
    stop
    ;;
  restart)
    restart
    ;;
  update)
    update
    ;;
  help|-h|--help)
    help
    ;;
  *)
    help
    exit 2
    ;;
esac
