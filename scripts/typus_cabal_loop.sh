#!/usr/bin/env bash
set -euo pipefail

# 静默运行：不打印到终端，但默认写入日志文件，便于排查 5 小时后的提交/推送是否成功
# 如仍想彻底丢弃日志：export LOG_FILE=/dev/null
LOG_FILE="${LOG_FILE:-/tmp/iflow-cabal-autoloop.log}"
exec >>"$LOG_FILE" 2>&1

###############################################################################
# iflow-cabal-autoloop.sh (Gitee优先版)
# - 单文件融合版：等价于 iflow-cabal-loop.yml + scripts/typus_cabal_loop.sh
# - 非 GitHub Actions 环境运行
# - iFlow CLI 走 NVIDIA Integrate OpenAI-compatible 接口
#
# 本次变更点：
# 1. 初始化：优先从 GITEE_REPO_URL 克隆代码，origin 指向 Gitee。
# 2. 推送：默认同时强制推送到 Gitee (origin) 和 GitHub (github)。
# 3. 容错：GitHub 推送失败不影响脚本运行（仅报错），Gitee 推送失败会重试。
###############################################################################

############################
# 0) 基本参数（可用环境变量覆盖）
############################
RUN_HOURS="${RUN_HOURS:-5}"
WORK_BRANCH="${WORK_BRANCH:-master}"

# 远端命名与配置
GIT_REMOTE="${GIT_REMOTE:-origin}"                 # 主远端（Gitee）
GITHUB_REMOTE_NAME="${GITHUB_REMOTE_NAME:-github}" # 镜像远端（GitHub）

# 必填配置：Gitee 用于克隆/拉取，GitHub 用于镜像推送
# 示例：GITEE_REPO_URL="https://gitee.com/user/repo.git"
GITEE_REPO_URL="${GITEE_REPO_URL:-}"
# 示例：GITHUB_REMOTE_URL="git@github.com:user/repo.git"
GITHUB_REMOTE_URL="${GITHUB_REMOTE_URL:-}"

# 推送的远端列表（空格分隔）。默认：Gitee(origin) + GitHub(github)
PUSH_REMOTES="${PUSH_REMOTES:-$GIT_REMOTE $GITHUB_REMOTE_NAME}"

# 推送失败重试策略（针对主远端 Gitee）
PUSH_RETRY_INTERVAL="${PUSH_RETRY_INTERVAL:-60}"  # 秒
PUSH_RETRY_FOREVER="${PUSH_RETRY_FOREVER:-1}"     # 1=一直重试；0=失败就放过

GIT_USER_NAME="${GIT_USER_NAME:-iflow-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-iflow-bot@users.noreply.github.com}"

# 是否启用“自动 bump + GitHub Release”
ENABLE_RELEASE="${ENABLE_RELEASE:-0}"

# timeout 结束时是否把未提交变更自动提交
AUTO_COMMIT_ON_TIMEOUT="${AUTO_COMMIT_ON_TIMEOUT:-1}"

############################
# 1) iFlow -> NVIDIA Integrate 配置
############################
export IFLOW_selectedAuthType="${IFLOW_selectedAuthType:-openai-compatible}"
export IFLOW_BASE_URL="${IFLOW_BASE_URL:-https://integrate.api.nvidia.com/v1}"
export IFLOW_MODEL_NAME="${IFLOW_MODEL_NAME:-moonshotai/kimi-k2-thinking}"

: "${IFLOW_API_KEY:?Missing IFLOW_API_KEY. Please export IFLOW_API_KEY before running.}"

############################
# 2) 工具函数：日志/依赖/timeout
############################
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

############################
# 2.5) 进程清理
############################
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
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' || true)"
  if [[ -z "${pgid:-}" ]]; then
    pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' || true)"
  fi
  if [[ -n "${pgid:-}" && "$pgid" =~ ^[0-9]+$ && "$pgid" == "$pid" ]]; then
    kill -- "-$pgid" 2>/dev/null || true
  fi
}

############################
# 3) 依赖准备
############################
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

############################
# 4) 仓库初始化与远端配置 (修改核心)
############################

# 初始化仓库：从 Gitee 克隆，或确保 origin 指向 Gitee
ensure_repo_initialized() {
  # 检查是否为 git 仓库
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    # 不是仓库：从 Gitee 克隆
    if [[ -z "${GITEE_REPO_URL:-}" ]]; then
      log "ERROR: Current directory is not a git repo, and GITEE_REPO_URL is not set."
      log "Please set GITEE_REPO_URL to clone the repository."
      exit 1
    fi
    log "Cloning from Gitee: ${GITEE_REPO_URL}"
    git clone "${GITEE_REPO_URL}" .
    return 0
  fi

  # 已是仓库：检查是否需要更新 origin 指向 Gitee
  if [[ -n "${GITEE_REPO_URL:-}" ]]; then
    local current_url
    current_url="$(git remote get-url "${GIT_REMOTE}" 2>/dev/null || true)"
    # 简单判断：如果配置不一致则更新
    if [[ "$current_url" != "${GITEE_REPO_URL}" ]]; then
      log "Updating remote '${GIT_REMOTE}' (Gitee) URL to: ${GITEE_REPO_URL}"
      git remote set-url "${GIT_REMOTE}" "${GITEE_REPO_URL}" || {
        log "WARN: Failed to update ${GIT_REMOTE} URL."
      }
    fi
  else
    log "WARN: GITEE_REPO_URL not set. Assuming current origin is correctly configured."
  fi
}

# 配置 GitHub 镜像远端
ensure_github_mirror() {
  if [[ -z "${GITHUB_REMOTE_URL:-}" ]]; then
    log "INFO: GITHUB_REMOTE_URL not set. Skipping GitHub mirror setup."
    # 移除可能存在的旧 github 远端以避免混淆？或者保留。这里选择静默跳过。
    return 0
  fi

  if git remote get-url "${GITHUB_REMOTE_NAME}" >/dev/null 2>&1; then
    local current_url
    current_url="$(git remote get-url "${GITHUB_REMOTE_NAME}" 2>/dev/null || true)"
    if [[ "$current_url" != "${GITHUB_REMOTE_URL}" ]]; then
      log "Updating GitHub mirror remote '${GITHUB_REMOTE_NAME}' URL."
      git remote set-url "${GITHUB_REMOTE_NAME}" "${GITHUB_REMOTE_URL}"
    fi
  else
    log "Adding GitHub mirror remote '${GITHUB_REMOTE_NAME}'."
    git remote add "${GITHUB_REMOTE_NAME}" "${GITHUB_REMOTE_URL}"
  fi
}

ensure_branch() {
  log "Ensuring branch: $WORK_BRANCH"
  # 从 origin (Gitee) 拉取
  git fetch "${GIT_REMOTE}" --prune >/dev/null 2>&1 || true

  if git show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/${WORK_BRANCH}"; then
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { log "WARN: checkout ${WORK_BRANCH} failed."; return 1; }
      # 注意：本地 checkout 后，若远端有更新且本地无分歧，ff-only 是安全的。
      # 如果远端领先本地且本地也有新提交，ff-only 会失败，随后的 force push 将用本地覆盖远端。
      git merge --ff-only "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: cannot fast-forward ${WORK_BRANCH} to ${GIT_REMOTE}/${WORK_BRANCH}. Local history differs, will force push later."
      }
    else
      git checkout -b "$WORK_BRANCH" "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: checkout -b ${WORK_BRANCH} failed."; return 1; }
    fi
    git branch --set-upstream-to="${GIT_REMOTE}/${WORK_BRANCH}" "$WORK_BRANCH" >/dev/null 2>&1 || true
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
    log "Remote branch ${remote}/${WORK_BRANCH} missing; force pushing HEAD:${WORK_BRANCH}..."
    # 修改：添加 --force 参数
    git push --force "$remote" "HEAD:${WORK_BRANCH}" || return 1
    return 0
  fi

  local ahead
  ahead="$(git rev-list --count "${remote}/${WORK_BRANCH}..HEAD" 2>/dev/null || echo 0)"
  if [[ ! "$ahead" =~ ^[0-9]+$ ]]; then ahead="0"; fi

  if [[ "$ahead" -gt 0 ]]; then
    log "Force pushing ${ahead} commit(s) to ${remote}/${WORK_BRANCH}..."
    # 修改：添加 --force 参数
    git push --force "$remote" "HEAD:${WORK_BRANCH}" || return 1
  else
    log "No commits ahead of ${remote}/${WORK_BRANCH}. Skip push."
  fi
}

commit_worktree_if_dirty() {
  local msg="$1"
  if git diff --quiet && git diff --cached --quiet; then return 0; fi
  git add -A
  if git diff --cached --quiet; then return 0; fi
  git commit -m "$msg" || true
}

push_all_remotes() {
  # 返回值：仅当主远端（Gitee/origin）失败才返回非 0
  # 镜像远端（GitHub/github）失败仅记录日志，不影响返回值
  local primary_status=0

  # 确保 github 远端配置存在（如果配置了 URL）
  ensure_github_mirror || true

  local r
  for r in $PUSH_REMOTES; do
    # 检查远端是否存在
    if ! git remote get-url "$r" >/dev/null 2>&1; then
      log "WARN: remote not found: $r, skip."
      continue
    fi

    if [[ "$r" == "$GIT_REMOTE" ]]; then
      # 主远端（Gitee）：失败会影响 primary_status，触发重试
      push_if_ahead "$r" || primary_status=1
      # 修改：添加 --force 参数以强制覆盖远端标签
      git push --force "$r" --tags >/dev/null 2>&1 || true
    else
      # 镜像远端（GitHub）：失败不影响 primary_status，仅打印警告
      if push_if_ahead "$r"; then
        # 修改：添加 --force 参数以强制覆盖远端标签
        git push --force "$r" --tags >/dev/null 2>&1 || true
      else
        log "WARN: Push to mirror remote $r failed (ignored)."
      fi
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

    log "WARN: push to primary remote (Gitee) failed (attempt=${attempt})."

    if [[ "$PUSH_RETRY_FOREVER" != "1" ]]; then
      log "WARN: PUSH_RETRY_FOREVER!=1, giving up retry."
      return 1
    fi

    sleep "$PUSH_RETRY_INTERVAL"
  done
}

############################
# 5) Release 相关工具
############################
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
  # 尝试从 GITHUB_REMOTE_URL 推断，或者从名为 github 的远端推断
  local url
  url="${GITHUB_REMOTE_URL:-}"
  if [[ -z "$url" ]]; then
    url="$(git remote get-url "${GITHUB_REMOTE_NAME}" 2>/dev/null || true)"
  fi
  [[ -n "$url" ]] || return 1

  if [[ "$url" =~ github\.com[/:]+([^/]+)/([^/]+)$ ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
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
if s.endswith('Z'):
    s = s[:-1] + '+00:00'
try:
    dt = datetime.datetime.fromisoformat(s)
except ValueError:
    m = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$', sys.argv[1].strip())
    if not m:
        sys.exit(1)
    base = m.group(1)
    tz = m.group(3) or 'Z'
    if tz == 'Z':
        tz = '+00:00'
    dt = datetime.datetime.fromisoformat(base + tz)
print(int(dt.timestamp()))
PY
    return $?
  fi
  if date -d "$iso" +%s >/dev/null 2>&1; then
    date -d "$iso" +%s
    return 0
  fi
  if command -v gdate >/dev/null 2>&1 && gdate -d "$iso" +%s >/dev/null 2>&1; then
    gdate -d "$iso" +%s
    return 0
  fi
  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' >/dev/null 2>&1; then
    date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s'
    return 0
  fi
  return 1
}

latest_release_age_ok() {
  command -v gh >/dev/null 2>&1 || return 1
  local repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "$repo" ]]; then
    repo="$(derive_github_repo || true)"
  fi
  [[ -n "$repo" ]] || return 1

  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    return 1
  fi

  local published_at pub_ts now_ts delta
  published_at="$(gh api "/repos/${repo}/releases/latest" --jq '.published_at' 2>/dev/null || true)"
  if [[ -z "$published_at" || "$published_at" == "null" ]]; then
    return 0
  fi

  pub_ts="$(iso_to_epoch "$published_at" 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  [[ "$pub_ts" -gt 0 ]] || return 1

  delta=$(( now_ts - pub_ts ))
  local release_window_seconds=604800
  (( delta >= release_window_seconds )) && return 0 || return 1
}

############################
# 6) bump + release
############################
attempt_bump_and_release() {
  if [[ "$ENABLE_RELEASE" != "1" ]]; then
    log "INFO: ENABLE_RELEASE=0, skip bump+release."
    return 0
  fi

  if ! latest_release_age_ok; then
    log "INFO: release in last 7 days (or cannot check). skip release."
    return 0
  fi

  local old_ver new_ver tag
  old_ver="$(extract_moon_version || true)"
  log "INFO: current version: ${old_ver:-<unknown>}"

  log "INFO: bump patch version in moon.mod.json via iflow..."
  run_cmd iflow "把moon.mod.json里的version增加一个patch版本(例如0.9.1变成0.9.2)，只改版本号本身 think:high" --yolo || {
    log "WARN: bump failed, skip release."
    return 0
  }

  git add -A
  new_ver="$(extract_moon_version || true)"
  log "INFO: new version: ${new_ver:-<unknown>}"

  [[ -n "$new_ver" ]] || { log "WARN: cannot parse version, skip."; return 0; }
  [[ -z "$old_ver" || "$new_ver" != "$old_ver" ]] || { log "WARN: version unchanged, skip."; return 0; }

  if git diff --cached --quiet; then
    log "WARN: no staged changes after bump, skip."
    return 0
  fi

  git commit -m "chore(release): v${new_ver}" || { log "WARN: commit failed, skip."; return 0; }
  
  # Release 时先推送到 Gitee，并尝试推送到 GitHub (均为 force push)
  push_all_remotes_with_retry || { log "WARN: push failed, skip release creation."; return 0; }

  tag="v${new_ver}"
  command -v gh >/dev/null 2>&1 || { log "WARN: gh missing, cannot create release."; return 0; }

  repo="${GITHUB_REPOSITORY:-}"
  [[ -n "$repo" ]] || repo="$(derive_github_repo || true)"
  [[ -n "$repo" ]] || { log "WARN: cannot derive repo, skip release."; return 0; }

  if gh release view "${tag}" >/dev/null 2>&1; then
    log "INFO: release ${tag} already exists, skip create."
    return 0
  fi

  log "INFO: creating GitHub Release ${tag}..."
  gh release create "${tag}" --target "$WORK_BRANCH" --generate-notes || {
    log "WARN: release create failed."
    return 0
  }

  log "INFO: released ${tag}"
}

############################
# 7) 内层循环
############################
run_inner_loop_forever() {
  terminate_inner() {
    echo
    log "terminated."
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
      stdbuf -oL -eL moon test 2>&1 \
        | stdbuf -oL -eL tee "$MOON_TEST_LOG"
    else
      moon test 2>&1 | tee "$MOON_TEST_LOG"
    fi

    local moon_status="${PIPESTATUS[0]:-255}"
    ((had_errexit)) && set -e

    local has_warnings=0
    if grep -Eiq '(warn(ing)?|警告)' "$MOON_TEST_LOG"; then
      has_warnings=1
    fi

    local has_error=0
    if has_error_in_log "$MOON_TEST_LOG"; then
      has_error=1
    fi

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

      if [[ "$has_warnings" -eq 1 ]]; then
        log "INFO: warnings detected."
      fi
    else
      log "Fixing via iflow..."
      run_cmd iflow "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为Feather)就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源 think:high" --yolo || true
    fi

    log "Looping..."
    sleep 1
  done
}

############################
# 8) inner / outer main
############################
inner_main() {
  MOON_TEST_LOG="/tmp/typus_moon_test_last_$$.log"
  run_inner_loop_forever
}

outer_main() {
  need_cmd curl

  [[ "$RUN_HOURS" =~ ^[0-9]+$ ]] || { log "ERROR: RUN_HOURS must be an integer (got: $RUN_HOURS)"; exit 1; }

  # 1. 初始化/克隆仓库 (优先 Gitee)
  ensure_repo_initialized
  
  # 2. 确保 Git 配置正确
  ensure_git
  
  # 3. 确保 GitHub 镜像配置 (如果提供了 URL)
  ensure_github_mirror
  
  # 4. 检出并拉取分支 (从 origin/Gitee)
  ensure_branch

  ensure_node_and_iflow
  ensure_moon

  log "IFLOW_BASE_URL=$IFLOW_BASE_URL"
  log "IFLOW_MODEL_NAME=$IFLOW_MODEL_NAME"
  log "IFLOW_selectedAuthType=$IFLOW_selectedAuthType"
  log "LOG_FILE=$LOG_FILE"
  log "Primary Remote (Gitee): $GIT_REMOTE -> $(git remote get-url $GIT_REMOTE)"
  if git remote get-url "$GITHUB_REMOTE_NAME" >/dev/null 2>&1; then
      log "Mirror Remote (GitHub): $GITHUB_REMOTE_NAME -> $(git remote get-url $GITHUB_REMOTE_NAME)"
  fi

  local tbin
  tbin="$(timeout_bin)"

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

    # 推送到 Gitee 和 GitHub (Gitee 失败会重试，GitHub 失败跳过)
    # 注意：当前脚本已配置为 Force Push
    push_all_remotes_with_retry

    ensure_branch || true
  done
}

if [[ "${1:-}" == "__inner__" ]]; then
  shift
  inner_main "$@"
else
  outer_main "$@"
fi