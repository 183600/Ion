#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# iflow-cabal-autoloop.sh (no-watchdog)
# - 单文件融合版：等价于 iflow-cabal-loop.yml + scripts/typus_cabal_loop.sh
# - 非 GitHub Actions 环境运行
# - iFlow CLI 走 NVIDIA Integrate OpenAI-compatible 接口
# - 已移除 watchdog/heartbeat 机制
#
# 修复点（在原有修复点基础上新增/调整）：
# A) derive_github_repo：修复 GitHub remote URL 正则，兼容 https/ssh/scp 风格
# B) ps_children_of：移除不可靠的 `ps ... -ppid` 分支，改为失败即回退到通用枚举过滤
#
# 重要修复（本次新增）：
# C) 在 set -e 模式下，push_if_ahead / ensure_branch / ensure_gitee_remote 等函数内部
#    若 git push/checkout/remote add 失败，会导致脚本直接退出，破坏 retry/|| true 语义。
#    现已将关键 git 操作改为"失败 return"，避免意外终止外层重试流程。
#
# 本次修改逻辑：
# - 新增 commit_and_push_changes 函数：统一处理 iflow 结束后的提交与推送。
# - 移除外层循环超时后的自动提交和推送（AUTO_COMMIT_ON_TIMEOUT 逻辑移除）。
# - 确保每运行完一次 iflow（包括内层循环和 release 流程），立即 commit 并 push 一次。
###############################################################################

############################
# 0) 基本参数（可用环境变量覆盖）
############################
RUN_HOURS="${RUN_HOURS:-5}"
WORK_BRANCH="${WORK_BRANCH:-master}"
GIT_REMOTE="${GIT_REMOTE:-origin}"

# GitHub 远端 URL 配置
# - 若设置，脚本将确保 $GIT_REMOTE 指向该地址
# - 若未设置，脚本使用当前 $GIT_REMOTE 已有的配置
GITHUB_REMOTE_URL="${GITHUB_REMOTE_URL:-}"

# Gitee 推送支持：
# - 默认认为远端名叫 gitee
# - 若本地没有该 remote 或 URL 不匹配环境变量：
#     - 优先使用 GITEE_REMOTE_URL 添加/更新
#     - 否则尝试从 GitHub 的 owner/repo 推断：https://gitee.com/owner/repo.git
GITEE_REMOTE="${GITEE_REMOTE:-gitee}"
GITEE_REMOTE_URL="${GITEE_REMOTE_URL:-}"

# 推送的远端列表（空格分隔）。默认：GitHub + Gitee
PUSH_REMOTES="${PUSH_REMOTES:-$GIT_REMOTE $GITEE_REMOTE}"

# 推送失败重试策略（确保"推送完成后再进入下一轮"）
PUSH_RETRY_INTERVAL="${PUSH_RETRY_INTERVAL:-60}"  # 秒
PUSH_RETRY_FOREVER="${PUSH_RETRY_FOREVER:-1}"     # 1=一直重试；0=失败就放过（不推荐）

GIT_USER_NAME="${GIT_USER_NAME:-iflow-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-iflow-bot@users.noreply.github.com}"

# 是否启用"自动 bump + GitHub Release"
ENABLE_RELEASE="${ENABLE_RELEASE:-0}"   # 0/1

# 注意：AUTO_COMMIT_ON_TIMEOUT 逻辑已移除，现在仅根据 iflow 运行结果触发提交
# AUTO_COMMIT_ON_TIMEOUT="${AUTO_COMMIT_ON_TIMEOUT:-1}"

############################
# 1) iFlow -> NVIDIA Integrate 配置（OpenAI-compatible）
############################
export IFLOW_selectedAuthType="${IFLOW_selectedAuthType:-openai-compatible}"
export IFLOW_BASE_URL="${IFLOW_BASE_URL:-https://integrate.api.nvidia.com/v1}"
export IFLOW_MODEL_NAME="${IFLOW_MODEL_NAME:-moonshotai/kimi-k2-thinking}"

: "${IFLOW_API_KEY:?Missing IFLOW_API_KEY. Please export IFLOW_API_KEY before running.}"

############################
# 2) 工具函数：依赖/timeout 兼容
############################
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }
}

timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    echo "timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    echo "gtimeout"   # macOS coreutils
  else
    echo "ERROR: need GNU timeout (timeout/gtimeout)."
    exit 1
  fi
}

run_cmd() {
  # 让输出尽量行缓冲，便于实时看到进度；同时不破坏 set -e 语义
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
# 2.5) 进程清理（避免误杀外层进程）
############################
ps_children_of() {
  # 输出指定 PPID 的子 PID 列表（尽量兼容 macOS / Linux）
  local ppid="$1"
  local out=""

  # Linux procps: --ppid
  out="$(ps -o pid= --ppid "$ppid" 2>/dev/null || true)"

  # 通用回退：枚举全部进程过滤 PPID（兼容性更强，但稍慢）
  if [[ -z "${out//[[:space:]]/}" ]]; then
    # `ps -axo pid=,ppid=` 在 Linux/macOS 通常可用
    out="$(ps -axo pid=,ppid= 2>/dev/null | awk -v P="$ppid" '$2==P{print $1}' || true)"
  fi

  # 规范化：一行一个 PID，去掉空白
  echo "$out" | awk '{print $1}' | sed '/^$/d' || true
}

kill_descendants() {
  # 尽力递归 kill 子孙进程；失败不报错
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
  # 仅当"自己是进程组组长"时，才 kill 整个进程组，避免误杀同组其它进程
  local pid pgid
  pid="$$"

  # macOS/BSD 的 ps 通常需要 -p PID
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "${pgid:-}" ]]; then
    # 少数环境接受 `ps ... <pid>`，作为回退
    pgid="$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ' || true)"
  fi

  if [[ -n "${pgid:-}" && "$pgid" =~ ^[0-9]+$ && "$pgid" == "$pid" ]]; then
    kill -- "-$pgid" 2>/dev/null || true
  fi
}

############################
# 3) 依赖准备：git / node / iflow / moon
############################
ensure_git() {
  need_cmd git
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git repo."; exit 1; }
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
}

ensure_node_and_iflow() {
  need_cmd npm

  if ! command -v iflow >/dev/null 2>&1; then
    echo "Installing iFlow CLI..."
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
  echo "Installing MoonBit toolchain..."
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
  export PATH="$HOME/.moon/bin:$PATH"
  need_cmd moon
  moon version
}

############################
# 4) git 分支就位 & 同步（修复版）
############################
ensure_github_remote() {
  # 确保 GitHub 远端配置正确
  local url="${GITHUB_REMOTE_URL:-}"

  # 如果未指定环境变量，且远端已存在，则信任现有配置
  if [[ -z "${url:-}" ]]; then
    remote_exists "$GIT_REMOTE" || { echo "ERROR: $GIT_REMOTE remote missing and GITHUB_REMOTE_URL not set."; return 1; }
    return 0
  fi

  # 如果指定了环境变量，强制设置/更新
  if remote_exists "$GIT_REMOTE"; then
    local current_url
    current_url="$(git remote get-url "$GIT_REMOTE" 2>/dev/null || true)"
    if [[ "$current_url" != "$url" ]]; then
      echo "Updating GitHub remote URL: ${GIT_REMOTE} -> ${url}"
      git remote set-url "$GIT_REMOTE" "$url" || { echo "WARN: failed to update GitHub remote."; return 1; }
    fi
  else
    echo "Adding GitHub remote: ${GIT_REMOTE} -> ${url}"
    git remote add "$GIT_REMOTE" "$url" || { echo "WARN: failed to add GitHub remote."; return 1; }
  fi
}

ensure_gitee_remote() {
  # 确保 Gitee 远端配置正确
  local url="${GITEE_REMOTE_URL:-}"

  # 1. 如果未设置环境变量
  if [[ -z "${url:-}" ]]; then
    # 如果 remote 已存在，就不动它（信任现有配置）
    if remote_exists "$GITEE_REMOTE"; then
      return 0
    fi
    # 如果 remote 不存在，尝试从 GitHub 推断
    url="$(infer_gitee_url_from_github || true)"
  fi

  # 如果 URL 仍为空（无法推断且未设置），则无法处理 Gitee
  if [[ -z "${url:-}" ]]; then
    echo "WARN: ${GITEE_REMOTE} remote missing and cannot infer url. Skip Gitee push."
    return 1
  fi

  # 2. 此时我们有了 url，确保 remote 指向它
  if remote_exists "$GITEE_REMOTE"; then
    local current_url
    current_url="$(git remote get-url "$GITEE_REMOTE" 2>/dev/null || true)"
    if [[ "$current_url" != "$url" ]]; then
      echo "Updating Gitee remote URL: ${GITEE_REMOTE} -> ${url}"
      git remote set-url "$GITEE_REMOTE" "$url" || { echo "WARN: failed to update Gitee remote."; return 1; }
    fi
  else
    echo "Adding Gitee remote: ${GITEE_REMOTE} -> ${url}"
    git remote add "$GITEE_REMOTE" "$url" || { echo "WARN: failed to add Gitee remote."; return 1; }
  fi
}

ensure_branch() {
  echo "Ensuring branch: $WORK_BRANCH"

  git fetch "$GIT_REMOTE" --prune >/dev/null 2>&1 || true

  if git show-ref --verify --quiet "refs/remotes/${GIT_REMOTE}/${WORK_BRANCH}"; then
    # 远端存在该分支
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { echo "WARN: git checkout ${WORK_BRANCH} failed."; return 1; }
      git merge --ff-only "${GIT_REMOTE}/${WORK_BRANCH}" || {
        echo "WARN: cannot fast-forward ${WORK_BRANCH} to ${GIT_REMOTE}/${WORK_BRANCH}. Manual intervention may be needed."
      }
    else
      # 本地没有该分支：从远端分支创建，避免从错误 HEAD 分叉
      git checkout -b "$WORK_BRANCH" "${GIT_REMOTE}/${WORK_BRANCH}" || {
        echo "WARN: git checkout -b ${WORK_BRANCH} from ${GIT_REMOTE}/${WORK_BRANCH} failed."
        return 1
      }
    fi
    git branch --set-upstream-to="${GIT_REMOTE}/${WORK_BRANCH}" "$WORK_BRANCH" >/dev/null 2>&1 || true
  else
    # 远端不存在该分支：本地确保存在即可
    if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
      git checkout "$WORK_BRANCH" || { echo "WARN: git checkout ${WORK_BRANCH} failed."; return 1; }
    else
      git checkout -b "$WORK_BRANCH" || { echo "WARN: git checkout -b ${WORK_BRANCH} failed."; return 1; }
    fi
  fi
}

push_if_ahead() {  # push_if_ahead [remote]
  # 注意：在 set -e 模式下，函数内部的 git push 失败可能导致脚本直接退出。
  # 这里用 "|| return 1 / if ! ...; then ..." 确保失败只向上返回状态码，方便外层重试。
  local remote="${1:-$GIT_REMOTE}"

  git fetch "$remote" --prune >/dev/null 2>&1 || true

  # 远端分支不存在：直接推送
  if ! git show-ref --verify --quiet "refs/remotes/${remote}/${WORK_BRANCH}"; then
    echo "Remote branch ${remote}/${WORK_BRANCH} missing; pushing HEAD:${WORK_BRANCH}..."
    git push "$remote" "HEAD:${WORK_BRANCH}" || return 1
    return 0
  fi

  local ahead
  ahead="$(git rev-list --count "${remote}/${WORK_BRANCH}..HEAD" 2>/dev/null || echo 0)"
  # 防御：确保是整数
  if [[ ! "$ahead" =~ ^[0-9]+$ ]]; then
    ahead="0"
  fi

  if [[ "$ahead" -gt 0 ]]; then
    echo "Pushing ${ahead} commit(s) to ${remote}/${WORK_BRANCH}..."
    git push "$remote" "HEAD:${WORK_BRANCH}" || return 1
  else
    echo "No commits ahead of ${remote}/${WORK_BRANCH}. Skip push."
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

# 新增通用函数：提交并推送
commit_and_push_changes() {
  local msg="${1:-chore: update}"
  git add -A

  if git diff --cached --quiet; then
    echo "INFO: No changes to commit."
    return 0
  fi

  git commit -m "$msg" || {
    echo "ERROR: git commit failed."
    return 1
  }

  if ! push_all_remotes_with_retry; then
    echo "ERROR: Failed to push changes after multiple retries."
    return 1
  fi
  
  return 0
}

push_all_remotes() {
  # 返回值：仅当"主远端(GIT_REMOTE) push 失败"才返回非 0；Gitee 失败不影响返回值
  local primary_status=0

  # 尝试保证 gitee remote 存在（失败就跳过）
  ensure_gitee_remote || true

  local r
  for r in $PUSH_REMOTES; do
    remote_exists "$r" || { echo "WARN: remote not found: $r, skip."; continue; }

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
  # 确保"主远端(GIT_REMOTE)"推送成功才返回 0
  # 默认一直重试（PUSH_RETRY_FOREVER=1），从而保证"提交并推送完成后再进入下一轮"
  local attempt=0

  while true; do
    attempt=$(( attempt + 1 ))

    if push_all_remotes; then
      echo "Push ok."
      return 0
    fi

    echo "WARN: push to primary remote failed (attempt=${attempt})."

    if [[ "$PUSH_RETRY_FOREVER" != "1" ]]; then
      echo "WARN: PUSH_RETRY_FOREVER!=1, giving up retry."
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

  # 更通用（避免 awk match 第三参数在不同 awk 实现不兼容）
  sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$f" | head -n1
}

has_error_in_output() {
  local output="$1"
  [[ -n "${output:-}" ]] || return 1
  echo "$output" | grep -Eiq '(^|[^[:alpha:]])(error:|fatal:|panic:|exception:|segmentation fault)([^[:alpha:]]|$)'
}

derive_github_repo() {
  local url owner repo
  url="$(git config --get "remote.${GIT_REMOTE}.url" || true)"
  [[ -n "$url" ]] || return 1

  # 修复：兼容
  # - https://github.com/owner/repo.git
  # - ssh://git@github.com/owner/repo.git
  # - git@github.com:owner/repo.git
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
  # 0=允许发布；1=不允许或无法判断（保守跳过）
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
    echo "INFO: ENABLE_RELEASE=0, skip bump+release."
    return 0
  fi

  if ! latest_release_age_ok; then
    echo "INFO: release in last 7 days (or cannot check). skip release."
    return 0
  fi

  local old_ver new_ver tag repo
  old_ver="$(extract_moon_version || true)"
  echo "INFO: current version: ${old_ver:-<unknown>}"

  echo "INFO: bump patch version in moon.mod.json via iflow..."
  run_cmd iflow "把moon.mod.json里的version增加一个patch版本(例如0.9.1变成0.9.2)，只改版本号本身 think:high" --yolo || {
    echo "WARN: bump failed, skip release."
    return 0
  }

  new_ver="$(extract_moon_version || true)"
  echo "INFO: new version: ${new_ver:-<unknown>}"

  [[ -n "$new_ver" ]] || { echo "WARN: cannot parse version, skip."; return 0; }
  [[ -z "$old_ver" || "$new_ver" != "$old_ver" ]] || { echo "WARN: version unchanged, skip."; return 0; }

  # 统一调用 commit_and_push_changes，确保也是"运行完一次 iflow -> commit -> push"
  # 且复用重试逻辑
  if ! commit_and_push_changes "chore(release): v${new_ver}"; then
    echo "WARN: commit/push failed for release, skip release creation."
    return 0
  fi

  tag="v${new_ver}"
  command -v gh >/dev/null 2>&1 || { echo "WARN: gh missing, cannot create release."; return 0; }

  repo="${GITHUB_REPOSITORY:-}"
  [[ -n "$repo" ]] || repo="$(derive_github_repo || true)"
  [[ -n "$repo" ]] || { echo "WARN: cannot derive repo, skip release."; return 0; }

  if gh release view "${tag}" >/dev/null 2>&1; then
    echo "INFO: release ${tag} already exists, skip create."
    return 0
  fi

  echo "INFO: creating GitHub Release ${tag}..."
  gh release create "${tag}" --target "$WORK_BRANCH" --generate-notes || {
    echo "WARN: release create failed."
    return 0
  }

  echo "INFO: released ${tag}"
}

############################
# 7) 内层循环（无 watchdog）
############################
run_inner_loop_forever() {
  terminate_inner() {
    echo
    echo "terminated."
    # 尽量清理自己派生的进程，避免误杀 outer/同组进程
    kill_descendants "$$" || true
    try_kill_process_group_if_safe || true
    exit 0
  }
  trap terminate_inner INT TERM

  while true; do
    echo "Running: moon test"

    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e

    local moon_output=""
    if command -v stdbuf >/dev/null 2>&1; then
      moon_output="$(stdbuf -oL -eL moon test 2>&1)"
    else
      moon_output="$(moon test 2>&1)"
    fi

    local moon_status="${PIPESTATUS[0]:-255}"
    ((had_errexit)) && set -e

    local has_warnings=0
    if echo "$moon_output" | grep -Eiq '(warn(ing)?|警告)'; then
      has_warnings=1
    fi

    local has_error=0
    if has_error_in_output "$moon_output"; then
      has_error=1
    fi

    if [[ "$moon_status" -eq 0 ]]; then
      run_cmd iflow "给这个项目增加一些moon test测试用例，不要超过10个 think:high" --yolo || true

      # 修改点：运行完 iflow 后，立即 commit 并 push
      commit_and_push_changes "feat: add test cases" || true

      if [[ "$has_error" -eq 0 ]]; then
        attempt_bump_and_release || true
      else
        echo "INFO: moon test exit 0 but output contains error keywords; skip release."
      fi

      if [[ "$has_warnings" -eq 1 ]]; then
        echo "INFO: warnings detected."
      fi
    else
      echo "Fixing via iflow..."
      run_cmd iflow "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为Feather)就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源 think:high" --yolo || true
      
      # 修改点：运行完 iflow 后，立即 commit 并 push
      commit_and_push_changes "fix: resolve errors" || true
    fi

    echo "Looping..."
    sleep 1
  done
}

############################
# 8) inner / outer main
############################
inner_main() {
  run_inner_loop_forever
}

outer_main() {
  need_cmd curl

  # RUN_HOURS 必须是整数，避免 $((...)) 直接退出
  [[ "$RUN_HOURS" =~ ^[0-9]+$ ]] || { echo "ERROR: RUN_HOURS must be an integer (got: $RUN_HOURS)"; exit 1; }

  ensure_git

  # 初始化远端配置（在 fetch/checkout 之前）
  ensure_github_remote || echo "WARN: Failed to ensure GitHub remote config."
  ensure_gitee_remote || echo "WARN: Failed to ensure Gitee remote config."

  ensure_branch

  ensure_node_and_iflow
  ensure_moon

  echo "IFLOW_BASE_URL=$IFLOW_BASE_URL"
  echo "IFLOW_MODEL_NAME=$IFLOW_MODEL_NAME"
  echo "IFLOW_selectedAuthType=$IFLOW_selectedAuthType"

  local tbin
  tbin="$(timeout_bin)"

  # 获取脚本绝对路径，避免 $0 不可靠（例如通过 bash script.sh 启动）
  local script
  script="${BASH_SOURCE[0]}"
  script="$(cd -- "$(dirname -- "$script")" && pwd)/$(basename -- "$script")"

  while true; do
    echo "Run loop for ${RUN_HOURS} hour(s)..."

    # 用 setsid 把 inner 放到独立 session/进程组，便于 timeout/TERM 时一并回收子进程
    # 加 --kill-after 防止 TERM 后仍残留（例如子进程忽略 TERM）
    if command -v setsid >/dev/null 2>&1; then
      "$tbin" --signal=TERM --kill-after=60s $(( RUN_HOURS * 3600 )) setsid bash "$script" __inner__ || true
    else
      # 没有 setsid 也能跑，但 inner 已避免 kill 0 误伤；清理力度会弱一点
      "$tbin" --signal=TERM --kill-after=60s $(( RUN_HOURS * 3600 )) bash "$script" __inner__ || true
    fi

    # 修改点：移除了 timeout 结束后的 autosave 和 push 逻辑
    # 仅保留分支同步，确保下次循环是基于最新的远端状态
    ensure_branch || true

    echo "Restarting loop (no autosave/push as per requirements)..."
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
