#!/usr/bin/env bash
set -euo pipefail

############################
# 0) 基本参数（可用环境变量覆盖）
############################
RUN_HOURS="${RUN_HOURS:-5}"
WORK_BRANCH="${WORK_BRANCH:-master}"
GIT_REMOTE="${GIT_REMOTE:-origin}"

# GitHub 远端 URL 配置
GITHUB_REMOTE_URL="${GITHUB_REMOTE_URL:-}"

# Gitee 推送支持
GITEE_REMOTE="${GITEE_REMOTE:-gitee}"
GITEE_REMOTE_URL="${GITEE_REMOTE_URL:-}"

# 推送的远端列表（空格分隔）。默认：GitHub + Gitee
PUSH_REMOTES="${PUSH_REMOTES:-$GIT_REMOTE $GITEE_REMOTE}"

# 推送失败重试策略
PUSH_RETRY_INTERVAL="${PUSH_RETRY_INTERVAL:-60}"  # 秒
PUSH_RETRY_FOREVER="${PUSH_RETRY_FOREVER:-1}"     # 1=一直重试；0=失败就放过

GIT_USER_NAME="${GIT_USER_NAME:-iflow-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-iflow-bot@users.noreply.github.com}"

# Release 与 Autosave
ENABLE_RELEASE="${ENABLE_RELEASE:-0}"
AUTO_COMMIT_ON_TIMEOUT="${AUTO_COMMIT_ON_TIMEOUT:-1}"

# 项目配置
PROJECT_BASE_DIR="${PWD}/ai_projects"
PROJECTS=(
  "https://github.com/183600/Ion.git:Ion"
  "https://github.com/183600/Feather.git:Feather"
)

############################
# 1) iFlow -> NVIDIA Integrate 配置
############################
export IFLOW_selectedAuthType="${IFLOW_selectedAuthType:-openai-compatible}"
export IFLOW_BASE_URL="${IFLOW_BASE_URL:-https://integrate.api.nvidia.com/v1}"
export IFLOW_MODEL_NAME="${IFLOW_MODEL_NAME:-moonshotai/kimi-k2-thinking}"

# 注意：IFLOW_API_KEY 的检查已移至 ensure_global_environment 函数中统一处理

############################
# 2) 工具函数
############################
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }
}

timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then echo "timeout"; 
  elif command -v gtimeout >/dev/null 2>&1; then echo "gtimeout"; 
  else log "ERROR: need GNU timeout (timeout/gtimeout)."; exit 1; fi
}

run_cmd() {
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  set +e
  local status=0
  if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL "$@"; status=$?;
  else "$@"; status=$?; fi
  ((had_errexit)) && set -e
  return "$status"
}

ps_children_of() {
  local ppid="$1" out=""
  out="$(ps -o pid= --ppid "$ppid" 2>/dev/null || true)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    out="$(ps -axo pid=,ppid= 2>/dev/null | awk -v P="$ppid" '$2==P{print $1}' || true)"
  fi
  echo "$out" | awk '{print $1}' | sed '/^$/d' || true
}

kill_descendants() {
  local parent="$1" kids
  kids="$(ps_children_of "$parent" || true)"
  if [[ -n "${kids:-}" ]]; then
    local k
    while IFS= read -r k; do
      [[ -n "${k:-}" ]] || continue
      kill_descendants "$k" || true
      kill "$k" 2>/dev/null || true
    done <<< "$kids"
  fi
}

try_kill_process_group_if_safe() {
  local pid pgid
  pid="$$"
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "${pgid:-}" ]]; then
    pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ' || true)"
  fi
  if [[ -n "${pgid:-}" && "$pgid" =~ ^[0-9]+$ && "$pgid" == "$pid" ]]; then
    kill -- "-$pgid" 2>/dev/null || true
  fi
}

############################
# 3) 依赖与环境检查
############################

# 新增：全局环境预检查
ensure_global_environment() {
  log "========================================"
  log "Phase 0: Checking global environment."
  log "========================================"

  # 1. 检查基础命令
  need_cmd git
  need_cmd curl
  need_cmd npm

  # 2. 检查 API 密钥
  : "${IFLOW_API_KEY:?Missing IFLOW_API_KEY. Please export IFLOW_API_KEY before running.}"

  # 3. 确保 iFlow CLI (全局安装一次即可)
  if ! command -v iflow >/dev/null 2>&1; then
    log "Installing iFlow CLI globally..."
    npm i -g @iflow-ai/iflow-cli@latest
  fi
  iflow --version >/dev/null 2>&1 || { log "ERROR: iflow check failed."; exit 1; }

  # 4. 确保 MoonBit 工具链
  if ! command -v moon >/dev/null 2>&1; then
    log "Installing MoonBit toolchain..."
    curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
    # 将 PATH 导出到当前 shell 及子进程
    export PATH="$HOME/.moon/bin:$PATH"
  fi
  command -v moon >/dev/null 2>&1 || { log "ERROR: moon installation check failed."; exit 1; }

  # 5. 检查基础参数有效性
  [[ "$RUN_HOURS" =~ ^[0-9]+$ ]] || { log "ERROR: RUN_HOURS must be an integer (got: $RUN_HOURS)"; exit 1; }

  log "Global environment check passed."
}

ensure_git() {
  need_cmd git
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "ERROR: not a git repo."; exit 1; }
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
}

# 此函数已整合进 ensure_global_environment，保留定义以防有其他地方引用，但不再在主流程单独调用
ensure_node_and_iflow() {
  # 已经在全局检查中确保
  return 0
}

# 此函数已整合进 ensure_global_environment
ensure_moon() {
  # 已经在全局检查中确保
  return 0
}

ensure_github_remote() {
  local url="${GITHUB_REMOTE_URL:-}"
  if [[ -z "${url:-}" ]]; then
    remote_exists "$GIT_REMOTE" || { log "ERROR: $GIT_REMOTE remote missing and GITHUB_REMOTE_URL not set."; return 1; }
    return 0
  fi
  if remote_exists "$GIT_REMOTE"; then
    local current_url
    current_url="$(git remote get-url "$GIT_REMOTE" 2>/dev/null || true)"
    if [[ "$current_url" != "$url" ]]; then
      log "Updating GitHub remote URL: ${GIT_REMOTE} -> ${url}"
      git remote set-url "$GIT_REMOTE" "$url" || { log "WARN: failed to update GitHub remote."; return 1; }
    fi
  else
    log "Adding GitHub remote: ${GIT_REMOTE} -> ${url}"
    git remote add "$GIT_REMOTE" "$url" || { log "WARN: failed to add GitHub remote."; return 1; }
  fi
}

ensure_gitee_remote() {
  local url="${GITEE_REMOTE_URL:-}"
  if [[ -z "${url:-}" ]]; then
    if remote_exists "$GITEE_REMOTE"; then return 0; fi
    url="$(infer_gitee_url_from_github || true)"
  fi
  if [[ -z "${url:-}" ]]; then
    log "WARN: ${GITEE_REMOTE} remote missing and cannot infer url. Skip Gitee push."
    return 1
  fi
  if remote_exists "$GITEE_REMOTE"; then
    local current_url
    current_url="$(git remote get-url "$GITEE_REMOTE" 2>/dev/null || true)"
    if [[ "$current_url" != "$url" ]]; then
      log "Updating Gitee remote URL: ${GITEE_REMOTE} -> ${url}"
      git remote set-url "$GITEE_REMOTE" "$url" || { log "WARN: failed to update Gitee remote."; return 1; }
    fi
  else
    log "Adding Gitee remote: ${GITEE_REMOTE} -> ${url}"
    git remote add "$GITEE_REMOTE" "$url" || { log "WARN: failed to add Gitee remote."; return 1; }
  fi
}

ensure_branch() {
  log "Ensuring branch: $WORK_BRANCH"
  git fetch "$GIT_REMOTE" --prune >/dev/null 2>&1 || true
  if git show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/${WORK_BRANCH}"; then
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { log "WARN: git checkout ${WORK_BRANCH} failed."; return 1; }
      git merge --ff-only "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: cannot fast-forward ${WORK_BRANCH} to ${GIT_REMOTE}/${WORK_BRANCH}."
      }
    else
      git checkout -b "$WORK_BRANCH" "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: git checkout -b ${WORK_BRANCH} failed."; return 1;
      }
    fi
    git branch --set-upstream-to="${GIT_REMOTE}/${WORK_BRANCH}" "$WORK_BRANCH" >/dev/null 2>&1 || true
  else
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { log "WARN: git checkout ${WORK_BRANCH} failed."; return 1; }
    else
      git checkout -b "$WORK_BRANCH" || { log "WARN: git checkout -b ${WORK_BRANCH} failed."; return 1; }
    fi
  fi
}

push_if_ahead() {
  local remote="${1:-$GIT_REMOTE}"
  git fetch "$remote" --prune >/dev/null 2>&1 || true
  if ! git show-ref --verify --quiet "refs/remotes/${remote}/${WORK_BRANCH}"; then
    log "Remote branch ${remote}/${WORK_BRANCH} missing; pushing HEAD:${WORK_BRANCH}..."
    git push "$remote" "HEAD:${WORK_BRANCH}" || return 1
    return 0
  fi
  local ahead
  ahead="$(git rev-list --count "${remote}/${WORK_BRANCH}..HEAD" 2>/dev/null || echo 0)"
  if [[ ! "$ahead" =~ ^[0-9]+$ ]]; then ahead="0"; fi
  if [[ "$ahead" -gt 0 ]]; then
    log "Pushing ${ahead} commit(s) to ${remote}/${WORK_BRANCH}..."
    git push "$remote" "HEAD:${WORK_BRANCH}" || return 1
  else
    log "No commits ahead of ${remote}/${WORK_BRANCH}. Skip push."
  fi
}

remote_exists() {
  git remote get-url "$1" >/dev/null 2>&1
}

infer_gitee_url_from_github() {
  local gh_repo
  gh_repo="$(derive_github_repo 2>/dev/null || true)"
  [[ -n "${gh_repo:-}" ]] || return 1
  printf 'https://gitee.com/%s.git\n' "$gh_repo"
}

commit_worktree_if_dirty() {
  local msg="$1"
  if git diff --quiet && git diff --cached --quiet; then return 0; fi
  git add -A
  if git diff --cached --quiet; then return 0; fi
  git commit -m "$msg" || true
}

push_all_remotes() {
  local primary_status=0
  ensure_gitee_remote || true
  local r
  for r in $PUSH_REMOTES; do
    remote_exists "$r" || { log "WARN: remote not found: $r, skip."; continue; }
    if [[ "$r" == "$GIT_REMOTE" ]]; then
      push_if_ahead "$r" || primary_status=1
      git push "$r" --tags >/dev/null 2>&1 || true
    else
      push_if_ahead "$r" || true
      git push "$r" --tags >/dev/null 2>&1 || true
    fi
  done
  return "$primary_status"
}

push_all_remotes_with_retry() {
  local attempt=0
  while true; do
    attempt=$(( attempt + 1 ))
    if push_all_remotes; then
      log "Push ok."
      return 0
    fi
    log "WARN: push to primary remote failed (attempt=${attempt})."
    if [[ "$PUSH_RETRY_FOREVER" != "1" ]]; then
      log "WARN: PUSH_RETRY_FOREVER!=1, giving up retry."
      return 1
    fi
    sleep "$PUSH_RETRY_INTERVAL"
  done
}

############################
# 4) Release 相关工具 (无变化)
############################
extract_moon_version() {
  local f="./moon.mod.json"
  if [[ ! -f "$f" ]]; then f="$(find . -name 'moon.mod.json' -print 2>/dev/null | head -n1 || true)"; fi
  [[ -n "${f:-}" && -f "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then jq -r '.version // empty' "$f"; return 0; fi
  sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -n1
}

has_error_in_log() {
  local logf="$1"
  [[ -f "$logf" ]] || return 1
  grep -Eiq '(^|[^[:alpha:]])(error:|fatal:|panic:|exception:|segmentation fault)([^[:alpha:]]|$)' "$logf"
}

derive_github_repo() {
  local url owner repo
  url="$(git config --get "remote.${GIT_REMOTE}.url" || true)"
  [[ -n "$url" ]] || return 1
  if [[ "$url" =~ github\.com[/:]+([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; repo="${repo%.git}"
    echo "${owner}/${repo}"; return 0
  fi
  return 1
}

iso_to_epoch() {
  local iso="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$iso" <<'PY'
import sys, datetime, re
s = sys.argv[1].strip()
if s.endswith('Z'): s = s[:-1] + '+00:00'
try: dt = datetime.datetime.fromisoformat(s)
except ValueError:
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$', sys.argv[1].strip())
    if not m: sys.exit(1)
    base = m.group(1); tz = m.group(3) or 'Z'
    if tz == 'Z': tz = '+00:00'
    dt = datetime.datetime.fromisoformat(base + tz)
print(int(dt.timestamp()))
PY
    return $?
  fi
  if date -d "$iso" +%s >/dev/null 2>&1; then date -d "$iso" +%s; return 0; fi
  if command -v gdate >/dev/null 2>&1 && gdate -d "$iso" +%s >/dev/null 2>&1; then gdate -d "$iso" +%s; return 0; fi
  return 1
}

latest_release_age_ok() {
  command -v gh >/dev/null 2>&1 || return 1
  local repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "$repo" ]]; then repo="$(derive_github_repo || true)"; fi
  [[ -n "$repo" ]] || return 1
  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then return 1; fi
  local published_at pub_ts now_ts delta
  published_at="$(gh api "/repos/${repo}/releases/latest" --jq '.published_at' 2>/dev/null || true)"
  if [[ -z "$published_at" || "$published_at" == "null" ]]; then return 0; fi
  pub_ts="$(iso_to_epoch "$published_at" 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"; [[ "$pub_ts" -gt 0 ]] || return 1
  delta=$(( now_ts - pub_ts )); local release_window_seconds=604800
  (( delta >= release_window_seconds )) && return 0 || return 1
}

attempt_bump_and_release() {
  if [[ "$ENABLE_RELEASE" != "1" ]]; then return 0; fi
  if ! latest_release_age_ok; then return 0; fi
  local old_ver new_ver tag repo
  old_ver="$(extract_moon_version || true)"
  log "INFO: current version: ${old_ver:-<unknown>}"
  log "INFO: bump patch version in moon.mod.json via iflow..."
  run_cmd iflow "把moon.mod.json里的version增加一个patch版本(例如0.9.1变成0.9.2)，只改版本号本身 think:high" --yolo || {
    log "WARN: bump failed, skip release."; return 0
  }
  git add -A
  new_ver="$(extract_moon_version || true)"
  log "INFO: new version: ${new_ver:-<unknown>}"
  [[ -n "$new_ver" ]] || { log "WARN: cannot parse version, skip."; return 0; }
  [[ -z "$old_ver" || "$new_ver" != "$old_ver" ]] || { log "WARN: version unchanged, skip."; return 0; }
  if git diff --cached --quiet; then log "WARN: no staged changes after bump, skip."; return 0; fi
  git commit -m "chore(release): v${new_ver}" || { log "WARN: commit failed, skip."; return 0; }
  push_if_ahead "$GIT_REMOTE" || { log "WARN: push failed, skip release creation."; return 0; }
  push_all_remotes || true
  tag="v${new_ver}"; command -v gh >/dev/null 2>&1 || { log "WARN: gh missing, cannot create release."; return 0; }
  repo="${GITHUB_REPOSITORY:-}"; [[ -n "$repo" ]] || repo="$(derive_github_repo || true)"
  [[ -n "$repo" ]] || { log "WARN: cannot derive repo, skip release."; return 0; }
  if gh release view "${tag}" >/dev/null 2>&1; then log "INFO: release ${tag} already exists, skip create."; return 0; fi
  log "INFO: creating GitHub Release ${tag}..."
  gh release create "${tag}" --target "$WORK_BRANCH" --generate-notes || { log "WARN: release create failed."; return 0; }
  log "INFO: released ${tag}"
}

############################
# 5) 核心循环逻辑
############################

run_inner_loop_forever() {
  terminate_inner() {
    echo; log "terminated."
    kill_descendants "$$" || true
    try_kill_process_group_if_safe || true
    exit 0
  }
  trap terminate_inner INT TERM

  while true; do
    log "Running: moon test"
    : > "$MOON_TEST_LOG"

    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e

    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL -eL moon test 2>&1 | stdbuf -oL -eL tee "$MOON_TEST_LOG"
    else
      moon test 2>&1 | tee "$MOON_TEST_LOG"
    fi

    local moon_status="${PIPESTATUS[0]:-255}"
    ((had_errexit)) && set -e

    local has_warnings=0
    if grep -Eiq '(warn(ing)?|警告)' "$MOON_TEST_LOG"; then has_warnings=1; fi

    local has_error=0
    if has_error_in_log "$MOON_TEST_LOG"; then has_error=1; fi

    if [[ "$moon_status" -eq 0 ]]; then
      run_cmd iflow "给这个项目增加一些moon test测试用例，不要超过10个 think:high" --yolo || true
      git add -A
      if git diff --cached --quiet; then log "INFO: nothing to commit."
      else git commit -m "测试通过" || true
      fi
      if [[ "$has_error" -eq 0 ]]; then attempt_bump_and_release || true
      else log "INFO: moon test exit 0 but log contains error keywords; skip release."
      fi
      if [[ "$has_warnings" -eq 1 ]]; then log "INFO: warnings detected."; fi
    else
      log "Fixing via iflow..."
      run_cmd iflow "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为${PROJECT_NAME})就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源 think:high" --yolo || true
    fi
    log "Looping..."
    sleep 1
  done
}

inner_main() {
  run_inner_loop_forever
}

# 执行单个项目的单次周期（运行 RUN_HOURS 小时 -> 提交 -> 推送）
execute_single_cycle() {
  # 局部环境检查
  ensure_git
  ensure_github_remote || log "WARN: Failed to ensure GitHub remote config."
  ensure_gitee_remote || log "WARN: Failed to ensure Gitee remote config."
  ensure_branch
  
  # 全局依赖已在 ensure_global_environment 中检查，此处移除冗余调用
  # ensure_node_and_iflow
  # ensure_moon

  log "IFLOW_BASE_URL=$IFLOW_BASE_URL"
  log "IFLOW_MODEL_NAME=$IFLOW_MODEL_NAME"
  log "IFLOW_selectedAuthType=$IFLOW_selectedAuthType"
  log "LOG_FILE=$LOG_FILE"

  local tbin
  tbin="$(timeout_bin)"

  local script
  script="${BASH_SOURCE[0]}"
  script="$(cd -- "$(dirname -- "$script")" && pwd)/$(basename -- "$script")"

  log "Starting ${RUN_HOURS} hour work cycle for project: ${PROJECT_NAME}..."
  
  # 运行内层循环，带有超时
  if command -v setsid >/dev/null 2>&1; then
    "$tbin" --signal=TERM --kill-after=60s $(( RUN_HOURS * 3600 )) setsid bash "$script" __inner__ || true
  else
    "$tbin" --signal=TERM --kill-after=60s $(( RUN_HOURS * 3600 )) bash "$script" __inner__ || true
  fi

  # 结束后的清理与同步
  ensure_branch || true
  if [[ "$AUTO_COMMIT_ON_TIMEOUT" == "1" ]]; then
    commit_worktree_if_dirty "chore: autosave after ${RUN_HOURS}h (${PROJECT_NAME} @ $(date '+%F %T'))"
  fi
  push_all_remotes_with_retry
  ensure_branch || true
}

# 确保仓库克隆成功，如果失败则每10分钟重试
ensure_repo_cloned() {
  local url="$1"
  local dir="$2"
  
  # 如果目录已存在且是git仓库，直接返回（后续逻辑会pull）
  if [[ -d "$dir" && -d "${dir}/.git" ]]; then
    return 0
  fi

  log "Target directory $dir does not exist or is not a git repo. Starting clone process..."
  
  while true; do
    # 如果目录存在但不是git仓库（可能是上次失败的残留），先删除
    if [[ -d "$dir" ]]; then
      log "Removing existing directory $dir (corrupted?)..."
      rm -rf "$dir"
    fi

    log "Attempting to clone $url ..."
    if git clone "$url" "$dir"; then
      log "Clone successful: $dir"
      return 0
    else
      log "ERROR: Clone failed for $url. Retrying in 10 minutes..."
      sleep 600 # 600 seconds = 10 minutes
    fi
  done
}

############################
# 6) 主入口（双项目调度）
############################
outer_main() {
  # 0. 最前面确保环境配置好了
  ensure_global_environment

  # 创建基础目录
  mkdir -p "$PROJECT_BASE_DIR"
  cd "$PROJECT_BASE_DIR"

  # 1. 首先确保所有仓库都已成功克隆
  log "========================================"
  log "Phase 1: Ensuring repositories are cloned."
  log "========================================"
  for project_def in "${PROJECTS[@]}"; do
    IFS=':' read -r url name <<< "$project_def"
    ensure_repo_cloned "$url" "$name"
  done
  log "All repositories are ready."

  # 2. 轮流执行循环
  log "========================================"
  log "Phase 2: Starting alternating execution loop."
  log "========================================"
  
  # 为了让子进程（inner_main）能知道项目名称，export一下
  export PROJECT_NAME="" 

  while true; do
    for project_def in "${PROJECTS[@]}"; do
      IFS=':' read -r url name <<< "$project_def"
      
      log "------------------------------------------------"
      log "Switching to project: $name"
      log "------------------------------------------------"

      # 切换到项目目录
      cd "$PROJECT_BASE_DIR/$name"
      
      # 更新环境变量（日志文件名等），确保当前会话生效
      export PROJECT_NAME="$name"
      export LOG_FILE="${LOG_FILE:-/tmp/iflow-cabal-autoloop-${name}.log}"
      export MOON_TEST_LOG="/tmp/typus_moon_test_last_${name}.log"
      
      # 每次启动前拉取最新代码，防止远程变动导致冲突
      log "Fetching latest changes for $name..."
      git fetch "$GIT_REMOTE" >/dev/null 2>&1 || true
      
      # 执行单轮周期（5小时运行 + 提交推送）
      execute_single_cycle
      
      log "Finished cycle for $name. Sleeping briefly before switching..."
      sleep 5
    done
  done
}

if [[ "${1:-}" == "__inner__" ]]; then
  shift
  inner_main "$@"
else
  outer_main
fi