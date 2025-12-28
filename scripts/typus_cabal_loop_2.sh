#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# iflow-cabal-autoloop.sh
# - 单文件融合版：等价于 iflow-cabal-loop.yml + scripts/typus_cabal_loop.sh
# - 非 GitHub Actions 环境运行
# - iFlow CLI 走 NVIDIA Integrate OpenAI-compatible 接口
###############################################################################

############################
# 0) 基本参数（可用环境变量覆盖）
############################
RUN_HOURS="${RUN_HOURS:-5}"
WORK_BRANCH="${WORK_BRANCH:-master}"
GIT_REMOTE="${GIT_REMOTE:-origin}"

GIT_USER_NAME="${GIT_USER_NAME:-iflow-bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-iflow-bot@users.noreply.github.com}"

# 是否启用“自动 bump + GitHub Release”
ENABLE_RELEASE="${ENABLE_RELEASE:-0}"   # 0/1

############################
# 1) iFlow -> NVIDIA Integrate 配置（OpenAI-compatible）
############################
# iFlow CLI 支持用环境变量配置 apiKey/baseUrl/modelName，并支持 OpenAI-compatible 模式 <!--citation:1-->
export IFLOW_selectedAuthType="${IFLOW_selectedAuthType:-openai-compatible}"
export IFLOW_BASE_URL="${IFLOW_BASE_URL:-https://integrate.api.nvidia.com/v1}"
export IFLOW_MODEL_NAME="${IFLOW_MODEL_NAME:-moonshotai/kimi-k2-thinking}"

# 重要：不要写死 key；请运行前 export IFLOW_API_KEY="nvapi-xxxx"
: "${IFLOW_API_KEY:?Missing IFLOW_API_KEY. Please export IFLOW_API_KEY before running.}"

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

############################
# 3) 依赖准备：git / node / iflow / moon
############################
ensure_git() {
  need_cmd git
  git config user.name  "$GIT_USER_NAME"
  git config user.email "$GIT_USER_EMAIL"
}

ensure_node_and_iflow() {
  # iFlow CLI 需求 Node.js 22+，可通过 npm 安装 <!--citation:4-->
  need_cmd npm || { log "ERROR: npm not found. Install Node.js 22+ first."; exit 1; }

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

  log "Installing MoonBit toolchain..."
  # 你的原安装方式：官方脚本
  curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
  export PATH="$HOME/.moon/bin:$PATH"
  need_cmd moon
  moon version
}

############################
# 4) git 分支就位 & 同步
############################
ensure_branch() {
  log "Ensuring branch: $WORK_BRANCH"
  git switch "$WORK_BRANCH" 2>/dev/null || git checkout -b "$WORK_BRANCH"
  git fetch "$GIT_REMOTE" --prune || true
  # 尽量 fast-forward
  git pull --ff-only "$GIT_REMOTE" "$WORK_BRANCH" || true
}

push_if_ahead() {
  git fetch "$GIT_REMOTE" --prune || true
  local ahead
  ahead="$(git rev-list --count "${GIT_REMOTE}/${WORK_BRANCH}..HEAD" 2>/dev/null || echo 0)"
  if [[ "${ahead}" -gt 0 ]]; then
    log "Pushing ${ahead} commit(s) to ${GIT_REMOTE}/${WORK_BRANCH}..."
    git push "$GIT_REMOTE" "HEAD:${WORK_BRANCH}"
  else
    log "No commits ahead of remote. Skip push."
  fi
}

############################
# 5) 融合版主循环（原 typus_cabal_loop.sh 逻辑内联）
############################
WATCHDOG_TIMEOUT=900
CHECK_INTERVAL=30
RELEASE_WINDOW_SECONDS=604800
MOON_TEST_LOG="/tmp/typus_moon_test_last.log"
HEARTBEAT_FILE="/tmp/typus_heartbeat_$$"

cleanup() { rm -f "$HEARTBEAT_FILE"; }
trap cleanup EXIT INT TERM

get_mtime() {
  if stat -c%Y "$1" >/dev/null 2>&1; then
    stat -c%Y "$1" 2>/dev/null || echo 0
  else
    stat -f %m "$1" 2>/dev/null || echo 0
  fi
}

monitor_watchdog() {
  master_pid="$1"; timeout_s="$2"; hb_file="$3"; shift 3

  while [[ ! -f "$hb_file" ]]; do sleep 1; done
  last_heartbeat="$(date +%s)"

  while true; do
    sleep "$CHECK_INTERVAL"

    if [[ -f "$hb_file" ]]; then
      current_time="$(get_mtime "$hb_file")"
      (( current_time > last_heartbeat )) && last_heartbeat="$current_time"
    fi

    now="$(date +%s)"
    elapsed=$((now - last_heartbeat))

    if (( elapsed > timeout_s )); then
      log "WARN: no output for ${timeout_s}s, restarting loop..."
      kill -- -"$master_pid" 2>/dev/null || true
      sleep 1
      exec "$0"
    fi
  done
}

run_with_heartbeat() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$@" 2>&1 | awk -v hb="$HEARTBEAT_FILE" '{ print; fflush(); system("touch " hb) }'
  else
    "$@" 2>&1 | awk -v hb="$HEARTBEAT_FILE" '{ print; fflush(); system("touch " hb) }'
  fi

  set +u
  local status=${PIPESTATUS[0]:-127}
  set -u
  return "$status"
}

extract_moon_version() {
  local f="./moon.mod.json"
  if [[ ! -f "$f" ]]; then
    f="$(find . -maxdepth 4 -name 'moon.mod.json' -print 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "${f:-}" && -f "$f" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$f"
  else
    awk 'match($0, /"version"[[:space:]]*:[[:space:]]*"([^"]+)"/, m){ print m[1]; exit }' "$f"
  fi
}

has_error_in_log() {
  local logf="$1"
  [[ -f "$logf" ]] || return 1
  grep -Eiq '(^|[^[:alpha:]])(error:|fatal:|panic:|exception:|segmentation fault)([^[:alpha:]]|$)' "$logf"
}

derive_github_repo() {
  # 尝试从 remote url 推断 GITHUB_REPOSITORY=owner/repo
  local url owner repo
  url="$(git config --get "remote.${GIT_REMOTE}.url" || true)"
  [[ -n "$url" ]] || return 1

  if [[ "$url" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    echo "${owner}/${repo}"
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

  pub_ts="$(date -d "$published_at" +%s 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  [[ "$pub_ts" -gt 0 ]] || return 1

  delta=$(( now_ts - pub_ts ))
  (( delta >= RELEASE_WINDOW_SECONDS )) && return 0 || return 1
}

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

  log "INFO: bump patch version in moon.mod.json via iflow..."
  run_with_heartbeat iflow "把moon.mod.json里的version增加一个patch版本(例如0.9.1变成0.9.2)，只改版本号本身 think:high" --yolo || {
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
  push_if_ahead || { log "WARN: push failed, skip release creation."; return 0; }

  tag="v${new_ver}"
  command -v gh >/dev/null 2>&1 || { log "WARN: gh missing, cannot create release."; return 0; }

  repo="${GITHUB_REPOSITORY:-}"
  [[ -n "$repo" ]] || repo="$(derive_github_repo || true)"

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

run_inner_loop_forever() {
  trap 'echo; log "terminated."; exit 0' INT TERM

  # watchdog
  if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    monitor_watchdog "$$" "$WATCHDOG_TIMEOUT" "$HEARTBEAT_FILE" &
    touch "$HEARTBEAT_FILE"
    sleep 1
  fi

  while true; do
    touch "$HEARTBEAT_FILE"

    log "Running: moon test"
    : > "$MOON_TEST_LOG"

    if command -v stdbuf >/dev/null 2>&1; then
      stdbuf -oL -eL moon test 2>&1 | \
        stdbuf -oL -eL tee "$MOON_TEST_LOG" | \
        awk -v hb="$HEARTBEAT_FILE" '
          BEGIN { found=0 }
          { print; fflush(); system("touch " hb); l=tolower($0); if (l ~ /(warn(ing)?|警告)/) found=1 }
          END { exit found ? 0 : 1 }
        '
    else
      moon test 2>&1 | tee "$MOON_TEST_LOG" | \
        awk -v hb="$HEARTBEAT_FILE" '
          BEGIN { found=0 }
          { print; fflush(); system("touch " hb); l=tolower($0); if (l ~ /(warn(ing)?|警告)/) found=1 }
          END { exit found ? 0 : 1 }
        '
    fi

    set +u
    ps0=${PIPESTATUS[0]:-255}
    ps2=${PIPESTATUS[2]:-255}
    set -u

    MOON_TEST_STATUS=$ps0
    AWK_STATUS=$ps2

    HAS_WARNINGS=1
    if [[ $AWK_STATUS -eq 1 ]]; then HAS_WARNINGS=0; fi

    HAS_ERROR=0
    if has_error_in_log "$MOON_TEST_LOG"; then HAS_ERROR=1; fi

    touch "$HEARTBEAT_FILE"

    if [[ $MOON_TEST_STATUS -eq 0 ]]; then
      run_with_heartbeat iflow "给这个项目增加一些moon test测试用例，不要超过10个 think:high" --yolo || true

      git add .
      if git diff --cached --quiet; then
        log "INFO: nothing to commit."
      else
        git commit -m "测试通过" || true
      fi

      if [[ $HAS_ERROR -eq 0 ]]; then
        attempt_bump_and_release || true
      else
        log "INFO: moon test exit 0 but log contains error keywords; skip release."
      fi
    else
      log "Fixing via iflow..."
      run_with_heartbeat iflow "如果PLAN.md里的特性都实现了(如果没有没有都实现就实现这些特性，给项目命名为Ion)就解决moon test显示的所有问题（除了warning），除非测试用例本身有编译错误，否则只修改测试用例以外的代码，debug时可通过加日志和打断点，尽量不要消耗大量CPU/内存资源 think:high" --yolo || true
    fi

    log "Looping..."
    touch "$HEARTBEAT_FILE"
    sleep 1
  done
}

############################
# 6) 外层：跑 RUN_HOURS 小时 -> push -> 再来一轮（等价于原 actions 的“反复触发”）
############################
main() {
  need_cmd curl
  ensure_git
  ensure_branch

  # iFlow + MoonBit
  ensure_node_and_iflow
  ensure_moon

  # 展示当前配置（不打印 key）
  log "IFLOW_BASE_URL=$IFLOW_BASE_URL"
  log "IFLOW_MODEL_NAME=$IFLOW_MODEL_NAME"
  log "IFLOW_selectedAuthType=$IFLOW_selectedAuthType"

  local tbin
  tbin="$(timeout_bin)"

  while true; do
    log "Run loop for ${RUN_HOURS} hour(s)..."
    # 到点发 TERM，让内层 loop 按 trap 退出
    "$tbin" --signal=TERM $(( RUN_HOURS * 3600 )) bash -c 'run_inner_loop_forever' || true

    # 即使没有 staged 变更，也可能已经在内层产生了 commit，所以这里按“是否领先远端”决定 push
    push_if_ahead || true

    # 再次拉一下，避免长期运行导致漂移（可选）
    ensure_branch || true
  done
}

# 让 bash -c 能调用函数
export -f log get_mtime monitor_watchdog run_with_heartbeat extract_moon_version has_error_in_log \
  derive_github_repo latest_release_age_ok attempt_bump_and_release run_inner_loop_forever push_if_ahead ensure_branch

main "$@"