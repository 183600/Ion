#!/usr/bin/env bash
set -euo pipefail

# 静默运行：不打印到终端，但默认写入日志文件，便于排查 5 小时后的提交/推送是否成功
# 如仍想彻底丢弃日志：export LOG_FILE=/dev/null
LOG_FILE="${LOG_FILE:-/tmp/claude-cabal-autoloop.log}"
exec >>"$LOG_FILE" 2>&1

###############################################################################
# claude-cabal-autoloop.sh (no-watchdog)
# - 单文件融合版：等价于 claude-cabal-loop.yml + scripts/typus_cabal_loop.sh
# - 非 GitHub Actions 环境运行
# - 使用 Claude Code CLI (@anthropic-ai/claude-code)
# - 已移除 watchdog/heartbeat 机制
#
# 修复点（继承自原 iflow 版本）：
# A) derive_github_repo：修复 GitHub remote URL 正则，兼容 https/ssh/scp 风格
# B) ps_children_of：移除不可靠的 `ps ... -ppid` 分支，改为失败即回退到通用枚举过滤
# C) set -e 模式下的 git 操作保护：关键 git 失败 return 而非 exit，保护外层重试
#
# 新增/修改（Claude 版本）：
# - 移除 NVIDIA OpenAI 接口配置，改用 Anthropic 原生 API Key (ANTHROPIC_API_KEY)
# - 移除 IFLOW 相关逻辑，替换为 `claude --non-interactive` 命令调用
# - 支持通过 CLAUDE_CMD 变量切换命令（默认为 claude，若使用 ccr 包装器可修改为 ccr）
###############################################################################

############################
# 0) 基本参数（可用环境变量覆盖）
############################
RUN_HOURS="${RUN_HOURS:-5}"
WORK_BRANCH="${WORK_BRANCH:-master}"
GIT_REMOTE="${GIT_REMOTE:-origin}"

# Claude Code 配置
# - CLAUDE_CMD: 默认使用官方 claude 命令。
# - 如果你使用 ccr (Claude Code Runner) 等工具，可设置为 "ccr"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"

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

GIT_USER_NAME="${GIT_USER_NAME:-claude-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-claude-bot@users.noreply.github.com}"

# 是否启用“自动 bump + GitHub Release”
ENABLE_RELEASE="${ENABLE_RELEASE:-0}"   # 0/1

# timeout 结束时是否把未提交变更自动提交（WIP autosave）
AUTO_COMMIT_ON_TIMEOUT="${AUTO_COMMIT_ON_TIMEOUT:-1}"  # 0/1

############################
# 1) Claude Code 配置
############################
# Claude CLI 默认读取 ANTHROPIC_API_KEY
: "${ANTHROPIC_API_KEY:?Missing ANTHROPIC_API_KEY. Please export ANTHROPIC_API_KEY before running.}"

# 可选：设置 Anthropic Base URL (通常不需要，除非使用代理)
# export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"

############################
# 2) 工具函数：日志/依赖/timeout 兼容
############################
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }
}

timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"   # macOS coreutils
  else
    log "ERROR: need GNU timeout (timeout/gtimeout)."
    exit 1
  fi
}

run_cmd() {
  # 让输出尽量行缓冲
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
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "${pgid:-}" ]]; then
    pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ' || true)"
  fi
  if [[ -n "${pgid:-}" && "$pgid" =~ ^[0-9]+$ && "$pgid" == "$pid" ]]; then
    kill -- "-$pgid" 2>/dev/null || true
  fi
}

############################
# 3) 依赖准备：git / node / claude / moon
############################
ensure_git() {
  need_cmd git
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log "ERROR: not a git repo."; exit 1; }
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
}

ensure_claude() {
  # 如果用户指定了 ccr，这里只检查命令是否存在，不尝试通过 npm 安装 ccr
  if [[ "$CLAUDE_CMD" == "ccr" ]]; then
    if ! command -v ccr >/dev/null 2>&1; then
      log "ERROR: CLAUDE_CMD is set to 'ccr' but command not found. Please install ccr manually."
      exit 1
    fi
    return 0
  fi

  # 默认安装官方 claude CLI
  need_cmd npm
  if ! command -v claude >/dev/null 2>&1; then
    log "Installing Claude Code CLI..."
    npm i -g @anthropic-ai/claude-code@latest
  fi
  claude --version >/dev/null 2>&1 || true
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
# 4) git 分支就位 & 同步
############################
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
    if remote_exists "$GITEE_REMOTE"; then
      return 0
    fi
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
        log "WARN: cannot fast-forward ${WORK_BRANCH} to ${GIT_REMOTE}/${WORK_BRANCH}. Manual intervention may be needed."
      }
    else
      git checkout -b "$WORK_BRANCH" "${GIT_REMOTE}/${WORK_BRANCH}" || {
        log "WARN: git checkout -b ${WORK_BRANCH} from ${GIT_REMOTE}/${WORK_BRANCH} failed."
        return 1
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
  if [[ ! "$ahead" =~ ^[0-9]+$ ]]; then
    ahead="0"
  fi
  if [[ "$ahead" -gt 0 ]]; then
    log "Pushing ${ahead} commit(s) to ${remote}/${WORK_BRANCH}..."
    git push "$remote" "HEAD:${WORK_BRANCH}" || return 1
  else
    log "No commits ahead of ${remote}/${WORK_BRANCH}. Skip push."
  fi
}

remote_exists() {
  local r="$1"
  git remote get-url "$r" >/dev/null 2>&1
}

infer_gitee_url_from_github() {
  local gh_repo
  gh_repo="$(derive_github_repo 2>/dev/null || true)"
  [[ -n "${gh_repo:-}" ]] || return 1
  printf 'https://gitee.com/%s.git\n' "$gh_repo"
}

commit_worktree_if_dirty() {
  local msg="$1"
  if git diff --quiet && git diff --cached --quiet; then
    return 0
  fi
  git add -A
  if git diff --cached --quiet; then
    return 0
  fi
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
  local url owner repo
  url="$(git config --get "remote.${GIT_REMOTE}.url" || true)"
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
  local old_ver new_ver tag repo
  old_ver="$(extract_moon_version || true)"
  log "INFO: current version: ${old_ver:-<unknown>}"
  
  # 使用 claude 替代 iflow
  # 提示词：修改 moon.mod.json 版本号
  log "INFO: bump patch version in moon.mod.json via ${CLAUDE_CMD}..."
  run_cmd "$CLAUDE_CMD" --non-interactive "把moon.mod.json里的version增加一个patch版本(例如0.9.1变成0.9.2)，只改版本号本身" || {
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
  push_if_ahead "$GIT_REMOTE" || { log "WARN: push failed, skip release creation."; return 0; }
  push_all_remotes || true

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
# 7) 内层循环（Claude Code）
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
    # 检查 MoonBit 必要配置文件
    if [[ ! -f "moon.mod.json" ]]; then
      log "MoonBit config missing. Fixing via ${CLAUDE_CMD}..."
      # 使用 claude 替代 iflow
      run_cmd "$CLAUDE_CMD" --non-interactive "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为Feather)就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源" || true
    fi

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
      # 测试通过：增加测试用例
      run_cmd "$CLAUDE_CMD" --non-interactive "给这个项目增加一些moon test测试用例，不要超过10个" || true

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
      # 测试失败：修复代码
      log "Fixing via ${CLAUDE_CMD}..."
      run_cmd "$CLAUDE_CMD" --non-interactive "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为Feather)就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源" || true
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

  ensure_git

  ensure_github_remote || log "WARN: Failed to ensure GitHub remote config."
  ensure_gitee_remote || log "WARN: Failed to ensure Gitee remote config."

  ensure_branch

  ensure_claude
  ensure_moon

  log "CLAUDE_CMD=$CLAUDE_CMD"
  log "LOG_FILE=$LOG_FILE"

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

    push_all_remotes_with_retry

    ensure_branch || true
  done
}

############################
# 9) 入口分发
############################
if [[ "${1:-}" == "__inner__" ]]; then
  shift
  inner_main "$@"
else
  outer_main "$@"
fi