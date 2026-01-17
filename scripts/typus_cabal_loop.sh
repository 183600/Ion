#!/usr/bin/env bash
set -euo pipefail

# 静默运行：默认写入日志文件，避免终端刷屏
# 每个仓库将拥有独立的日志文件，存储在 BASE_DIR 下

###############################################################################
# 0) 多仓库配置
###############################################################################
# 格式："本地目录名|Gitee克隆地址|GitHub推送地址|BaseURL|APIKey|Model|AuthType"
# 注意：
#   - 前三项必填，后四项选填。
#   - 若后四项留空，脚本将自动使用下方的全局默认配置。
#   - 这样允许你为 repo1 使用 NVIDIA API，为 repo2 使用 OpenAI API 等。
REPO_LIST=(
    # 示例：repo1 使用特定配置 (如 NVIDIA)
    "repo1|https://gitee.com/user/repo1.git|https://github.com/user/repo1.git|https://integrate.api.nvidia.com/v1|nvapi-xxxxx|moonshotai/kimi-k2-thinking|openai-compatible"
    
    # 示例：repo2 使用特定配置 (如 DeepSeek/自定义)
    "repo2|https://gitee.com/user/repo2.git|https://github.com/user/repo2.git|https://api.deepseek.com|sk-xxxxx|deepseek-chat|openai-compatible"
    
    # 示例：repo3 留空，使用脚本下方的全局默认配置
    "repo3|https://gitee.com/user/repo3.git|https://github.com/user/repo3.git||||"
)

# 所有仓库存放的基础目录
BASE_DIR="${BASE_DIR:-/tmp/iflow_repos}"

###############################################################################
# 原有全局参数（可用环境变量覆盖，作为各项目的默认值）
###############################################################################
RUN_HOURS="${RUN_HOURS:-5}"
WORK_BRANCH="${WORK_BRANCH:-master}"
GIT_REMOTE="${GIT_REMOTE:-origin}"

# GitHub 远端 URL 配置（脚本内部会根据配置动态添加，这里保留变量接口）
GITHUB_REMOTE_URL="${GITHUB_REMOTE_URL:-}"

# Gitee 推送支持
GITEE_REMOTE="${GITEE_REMOTE:-gitee}"
GITEE_REMOTE_URL="${GITEE_REMOTE_URL:-}"

# 推送的远端列表（将在运行时动态修改为同时包含 Gitee 和 GitHub）
PUSH_REMOTES="${PUSH_REMOTES:-$GIT_REMOTE $GITEE_REMOTE}"

# 推送失败重试策略
PUSH_RETRY_INTERVAL="${PUSH_RETRY_INTERVAL:-60}"
PUSH_RETRY_FOREVER="${PUSH_RETRY_FOREVER:-1}"

GIT_USER_NAME="${GIT_USER_NAME:-iflow-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-iflow-bot@users.noreply.github.com}"

ENABLE_RELEASE="${ENABLE_RELEASE:-0}"
AUTO_COMMIT_ON_TIMEOUT="${AUTO_COMMIT_ON_TIMEOUT:-1}"

# iFlow 全局默认配置 (当 REPO_LIST 中未指定具体值时使用)
export IFLOW_selectedAuthType="${IFLOW_selectedAuthType:-openai-compatible}"
export IFLOW_BASE_URL="${IFLOW_BASE_URL:-https://integrate.api.nvidia.com/v1}"
export IFLOW_MODEL_NAME="${IFLOW_MODEL_NAME:-moonshotai/kimi-k2-thinking}"

# 注意：这里不再强制检查 IFLOW_API_KEY，因为允许在 REPO_LIST 中按项目配置
# 如果既没有全局 Key，项目也没配，运行时会报错并休眠
export IFLOW_API_KEY="${IFLOW_API_KEY:-}"

###############################################################################
# 1) 工具函数
###############################################################################
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }
}

timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"
  else
    log "ERROR: need GNU timeout (timeout/gtimeout)."
    exit 1
  fi
}

run_cmd() {
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  set +e
  local status=0
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$@"
    status=$?
  else
    "$@"
    status=$?
  fi
  ((had_errexit)) && set -e
  return "$status"
}

ps_children_of() {
  local ppid="$1"
  local out=""
  out="$(ps -o pid= --ppid "$ppid" 2>/dev/null || true)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    out="$(ps -axo pid=,ppid= 2>/dev/null | awk -v P="$ppid" '$2==P{print $1}' || true)"
  fi
  echo "$out" | awk '{print $1}' | sed '/^$/d' || true
}

kill_descendants() {
  local parent="$1"
  local kids
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

###############################################################################
# 2) 依赖与环境准备
###############################################################################
ensure_git() {
  need_cmd git
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "ERROR: not a git repo."; exit 1; }
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
}

ensure_node_and_iflow() {
  need_cmd npm
  if ! command -v iflow >/dev/null 2>&1; then
    log "Installing iFlow CLI..."
    npm i -g @iflow-ai/iflow-cli@latest
  fi
  iflow --version >/dev/null 2>&1 || true
}

ensure_moon() {
  if command -v moon >/dev/null 2>&1; then
    moon version || true
    return 0
  fi
  need_cmd curl
  log "Installing MoonBit toolchain..."
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
  export PATH="$HOME/.moon/bin:$PATH"
  need_cmd moon
  moon version
}

###############################################################################
# 3) Git 操作逻辑
###############################################################################
ensure_github_remote() {
  # 本脚本策略：origin 保持为 Gitee，因此这里仅做基础检查
  # 实际的 GitHub remote (名为 'github') 将在 wrapper 中强制添加
  local url="${GITHUB_REMOTE_URL:-}"
  if [[ -z "${url:-}" ]]; then
    remote_exists "$GIT_REMOTE" || { log "ERROR: $GIT_REMOTE remote missing."; return 1; }
    return 0
  fi
  # 如果用户显式设置了 GITHUB_REMOTE_URL，则覆盖 origin（这会变成拉取源为 GitHub）
  # 为了符合题目要求"从 Gitee 克隆"，主流程中会 unset 这个变量
  if remote_exists "$GIT_REMOTE"; then
    local current_url
    current_url="$(git remote get-url "$GIT_REMOTE" 2>/dev/null || true)"
    if [[ "$current_url" != "$url" ]]; then
      log "Updating $GIT_REMOTE URL to: ${url}"
      git remote set-url "$GIT_REMOTE" "$url" || { log "WARN: failed to update remote."; return 1; }
    fi
  else
    git remote add "$GIT_REMOTE" "$url" || { log "WARN: failed to add remote."; return 1; }
  fi
}

ensure_gitee_remote() {
  # 基础逻辑，确保 Gitee 远端存在
  local url="${GITEE_REMOTE_URL:-}"
  if [[ -z "${url:-}" ]]; then
    if remote_exists "$GITEE_REMOTE"; then return 0; fi
    url="$(infer_gitee_url_from_github || true)"
  fi
  if [[ -z "${url:-}" ]]; then
    # 如果无法推断且未设置，跳过 Gitee 单独配置（因为 origin 可能已经是 Gitee）
    return 0 
  fi

  if remote_exists "$GITEE_REMOTE"; then
    local current_url
    current_url="$(git remote get-url "$GITEE_REMOTE" 2>/dev/null || true)"
    if [[ "$current_url" != "$url" ]]; then
      git remote set-url "$GITEE_REMOTE" "$url" || true
    fi
  else
    git remote add "$GITEE_REMOTE" "$url" || true
  fi
}

ensure_branch() {
  log "Ensuring branch: $WORK_BRANCH"
  git fetch "$GIT_REMOTE" --prune >/dev/null 2>&1 || true

  if git show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/${WORK_BRANCH}"; then
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { log "WARN: checkout ${WORK_BRANCH} failed."; return 1; }
      git merge --ff-only "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: cannot fast-forward ${WORK_BRANCH}. Resetting to remote..."
        git reset --hard "${GIT_REMOTE}/${WORK_BRANCH}" || true
      }
    else
      git checkout -b "$WORK_BRANCH" "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: checkout -b ${WORK_BRANCH} failed."; return 1; 
      }
    fi
  else
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { log "WARN: checkout ${WORK_BRANCH} failed."; return 1; }
    else
      git checkout -b "$WORK_BRANCH" || { log "WARN: checkout -b ${WORK_BRANCH} failed."; return 1; }
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

###############################################################################
# 4) Release 辅助函数
###############################################################################
extract_moon_version() {
  local f="./moon.mod.json"
  if [[ ! -f "$f" ]]; then
    f="$(find . -name 'moon.mod.json' -print 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "${f:-}" && -f "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$f"
    return 0
  fi
  sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -n1
}

has_error_in_log() {
  local logf="$1"
  [[ -f "$logf" ]] || return 1
  grep -Eiq '(^|[^[:alpha:]])(error:|fatal:|panic:|exception:|segmentation fault)([^[:alpha:]]|$)' "$logf"
}

derive_github_repo() {
  local url owner repo
  # 检查名为 github 的远端，或者 origin
  url="$(git config --get "remote.github.url" 2>/dev/null || git config --get "remote.${GIT_REMOTE}.url" || true)"
  [[ -n "$url" ]] || return 1
  if [[ "$url" =~ github\.com[/:]+([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    repo="${repo%.git}"
    echo "${owner}/${repo}"
    return 0
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
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$', s)
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
  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' >/dev/null 2>&1; then date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s'; return 0; fi
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
  now_ts="$(date +%s)"
  [[ "$pub_ts" -gt 0 ]] || return 1
  delta=$(( now_ts - pub_ts ))
  local release_window_seconds=604800
  (( delta >= release_window_seconds )) && return 0 || return 1
}

attempt_bump_and_release() {
  if [[ "$ENABLE_RELEASE" != "1" ]]; then return 0; fi
  if ! latest_release_age_ok; then log "INFO: release in last 7 days (or cannot check). skip release."; return 0; fi

  local old_ver new_ver tag repo
  old_ver="$(extract_moon_version || true)"
  log "INFO: current version: ${old_ver:-<unknown>}"

  log "INFO: bump patch version in moon.mod.json via iflow..."
  run_cmd iflow "把moon.mod.json里的version增加一个patch版本(例如0.9.1变成0.9.2)，只改版本号本身 think:high" --yolo || {
    log "WARN: bump failed, skip release."; return 0;
  }

  git add -A
  new_ver="$(extract_moon_version || true)"
  log "INFO: new version: ${new_ver:-<unknown>}"

  [[ -n "$new_ver" ]] || { log "WARN: cannot parse version, skip."; return 0; }
  [[ -z "$old_ver" || "$new_ver" != "$old_ver" ]] || { log "WARN: version unchanged, skip."; return 0; }

  if git diff --cached --quiet; then log "WARN: no staged changes after bump, skip."; return 0; fi

  git commit -m "chore(release): v${new_ver}" || { log "WARN: commit failed, skip."; return 0; }
  # 这里的 push 如果使用 origin (Gitee)，gh release 可能读不到，但没关系，我们主要在 GitHub 做 release
  # 最好确保推到了 GitHub，但这由 push_all_remotes 处理
  push_all_remotes_with_retry || { log "WARN: push failed, skip release creation."; return 0; }

  tag="v${new_ver}"
  command -v gh >/dev/null 2>&1 || { log "WARN: gh missing, cannot create release."; return 0; }
  repo="${GITHUB_REPOSITORY:-}"
  [[ -n "$repo" ]] || repo="$(derive_github_repo || true)"
  [[ -n "$repo" ]] || { log "WARN: cannot derive repo, skip release."; return 0; }

  if gh release view "${tag}" >/dev/null 2>&1; then log "INFO: release ${tag} already exists, skip create."; return 0; fi

  log "INFO: creating GitHub Release ${tag}..."
  gh release create "${tag}" --target "$WORK_BRANCH" --generate-notes || { log "WARN: release create failed."; return 0; }
  log "INFO: released ${tag}"
}

###############################################################################
# 5) 内层循环
###############################################################################
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
      if git diff --cached --quiet; then
        log "INFO: nothing to commit."
      else
        git commit -m "测试通过" || true
      fi

      if [[ "$has_error" -eq 0 ]]; then
        attempt_bump_and_release || true
      else
        log "INFO: moon test exit 0 but log contains error keywords; skip release."
      fi
      if [[ "$has_warnings" -eq 1 ]]; then log "INFO: warnings detected."; fi
    else
      log "Fixing via iflow..."
      run_cmd iflow "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为Feather)就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源 think:high" --yolo || true
    fi
    log "Looping..."
    sleep 1
  done
}

inner_main() {
  MOON_TEST_LOG="/tmp/typus_moon_test_last_$$.log"
  run_inner_loop_forever
}

outer_main() {
  need_cmd curl
  [[ "$RUN_HOURS" =~ ^[0-9]+$ ]] || { log "ERROR: RUN_HOURS must be an integer."; exit 1; }

  ensure_git
  # 确保远端正确配置
  ensure_github_remote || log "WARN: Failed to ensure GitHub remote config."
  ensure_gitee_remote || log "WARN: Failed to ensure Gitee remote config."

  ensure_branch
  ensure_node_and_iflow
  ensure_moon

  log "IFLOW_BASE_URL=$IFLOW_BASE_URL"
  log "IFLOW_MODEL_NAME=$IFLOW_MODEL_NAME"
  log "LOG_FILE=$LOG_FILE"

  local tbin
  tbin="$(timeout_bin)"

  # 获取脚本自身路径
  local script
  script="${BASH_SOURCE[0]}"
  script="$(cd -- "$(dirname -- "$script")" && pwd)/$(basename -- "$script")"

  while true; do
    log "Run loop for ${RUN_HOURS} hour(s)..."

    if command -v setsid >/dev/null 2>&1; then
      "$tbin" --signal=TERM --kill-after=60s $(( RUN_HOURS * 3600 )) setsid bash "$script" __inner__ || true
    else
      "$tbin" --signal=TERM --kill-after=60s $(( RUN_HOURS * 3600 )) bash "$script" __inner__ || true
    fi

    ensure_branch || true
    if [[ "$AUTO_COMMIT_ON_TIMEOUT" == "1" ]]; then
      commit_worktree_if_dirty "chore: autosave after ${RUN_HOURS}h ($(date '+%F %T'))"
    fi
    push_all_remotes_with_retry
    ensure_branch || true
  done
}

###############################################################################
# 6) 多仓库并发控制逻辑
###############################################################################

# 初始化仓库（克隆或拉取）
setup_repos() {
  log "Initializing workspace at $BASE_DIR..."
  mkdir -p "$BASE_DIR"
  
  for entry in "${REPO_LIST[@]}"; do
    # 仅解析前三个字段 name|gitee|github，用于初始化操作
    IFS='|' read -r name gitee_url _ <<< "$entry"
    local repo_dir="${BASE_DIR}/${name}"
    
    if [[ -d "$repo_dir" ]]; then
      log "Repo [$name] exists, fetching updates..."
      (cd "$repo_dir" && git fetch --all)
    else
      log "Cloning [$name] from Gitee: $gitee_url"
      git clone "$gitee_url" "$repo_dir"
    fi
  done
}

# 运行单个仓库的工作流
run_repo_process() {
  local name="$1"
  local gitee_url="$2"
  local github_url="$3"
  
  # --- 新增 API 配置参数 ---
  local custom_base_url="$4"
  local custom_api_key="$5"
  local custom_model_name="$6"
  local custom_auth_type="$7"
  
  local repo_dir="${BASE_DIR}/${name}"
  
  # 进入仓库目录
  cd "$repo_dir" || { log "ERROR: Cannot cd to $repo_dir"; exit 1; }
  
  # 设置该仓库专用的日志文件
  export LOG_FILE="${BASE_DIR}/${name}.log"
  # 重定向输出到该日志文件
  exec >>"$LOG_FILE" 2>&1
  
  log "========== Starting Worker for $name =========="
  log "Gitee: $gitee_url"
  log "GitHub: $github_url"

  # --- 应用 API 配置 ---
  # 逻辑：如果 custom_xxx 非空则使用参数，否则沿用全局环境变量
  if [[ -n "$custom_base_url" ]]; then export IFLOW_BASE_URL="$custom_base_url"; fi
  if [[ -n "$custom_api_key" ]]; then export IFLOW_API_KEY="$custom_api_key"; fi
  if [[ -n "$custom_model_name" ]]; then export IFLOW_MODEL_NAME="$custom_model_name"; fi
  if [[ -n "$custom_auth_type" ]]; then export IFLOW_selectedAuthType="$custom_auth_type"; fi
  
  # 校验 API Key 是否最终有效
  if [[ -z "${IFLOW_API_KEY:-}" ]]; then
    log "ERROR: IFLOW_API_KEY is missing for project '$name' (Not in REPO_LIST and not set globally). Sleeping 1h to prevent loop."
    sleep 3600
    return 1
  fi

  log "Using API Config: BaseURL=${IFLOW_BASE_URL}, Model=${IFLOW_MODEL_NAME}, Auth=${IFLOW_selectedAuthType}"

  # 1. 确保 origin 指向 Gitee
  local current_origin
  current_origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$current_origin" != "$gitee_url" ]]; then
    log "Updating origin to Gitee URL..."
    git remote set-url origin "$gitee_url" || true
  fi

  # 2. 确保存在名为 'github' 的远端指向 GitHub
  if ! git remote get-url github >/dev/null 2>&1; then
    log "Adding remote 'github' -> $github_url"
    git remote add github "$github_url"
  else
    local current_gh
    current_gh="$(git remote get-url github 2>/dev/null || true)"
    if [[ "$current_gh" != "$github_url" ]]; then
      log "Updating remote 'github' URL..."
      git remote set-url github "$github_url"
    fi
  fi

  # 3. 配置并发送环境变量给 outer_main
  export PUSH_REMOTES="origin github"
  unset GITHUB_REMOTE_URL
  unset GITEE_REMOTE_URL
  
  # 4. 启动主循环
  outer_main
}

main() {
  # 1. 全局环境检查
  need_cmd git
  need_cmd npm
  # 全局预安装一次，防止并发冲突
  ensure_node_and_iflow
  ensure_moon
  
  # 2. 克隆/更新所有仓库
  setup_repos
  
  # 3. 并发启动各个仓库的 worker
  log "Starting workers for all repos..."
  local pids=()
  
  for entry in "${REPO_LIST[@]}"; do
    # 解析所有7个字段，不足的为空
    IFS='|' read -r name gitee_url github_url base_url api_key model_name auth_type <<< "$entry"
    
    # 使用后台子进程启动，并传入所有参数
    run_repo_process "$name" "$gitee_url" "$github_url" "$base_url" "$api_key" "$model_name" "$auth_type" &
    pids+=($!)
  done
  
  log "All workers started. Waiting..."
  
  # 4. 等待所有后台进程
  wait
}

###############################################################################
# 7) 入口分发
###############################################################################
if [[ "${1:-}" == "__inner__" ]]; then
  shift
  inner_main "$@"
else
  main "$@"
fi
