#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-/proj}"
DATA_DIR="${DATA_DIR:-${PROJECT_ROOT}/data}"
REPO_DIR="${GIT_REPO_DIR:-${PROJECT_ROOT}/project}"
REPO_URL="${GIT_REPO_URL:-}"
GIT_CLONE_DEPTH="${GIT_CLONE_DEPTH:-1}"
S3_ROOT="${S3_URI:-}"
S3_ROOT="${S3_ROOT%/}"

mkdir -p "$PROJECT_ROOT" "$DATA_DIR"

sync_s3() {
  [[ -n "$S3_ROOT" ]] || return 0
  if [[ "$S3_ROOT" != s3://* ]]; then
    echo "[sync] S3_URI must start with s3://" >&2
    return 2
  fi

  local sync_dirs="${SYNC_DIRS:-}"
  local force_sync="${FORCE_SYNC:-0}"
  local manifest_uri="${S3_ROOT}/sync_dirs.txt"
  local manifest_present=0
  local file_dirs=""
  local sync_id marker raw path destination
  local -a items
  local -a s5_global=(s5cmd --numworkers "${S5CMD_NUMWORKERS:-1024}")
  local -a s5_cp=(s5cmd --numworkers "${S5CMD_NUMWORKERS:-1024}" cp --concurrency "${S5CMD_CONCURRENCY:-20}")

  if "${s5_global[@]}" ls "$manifest_uri" >/dev/null 2>&1; then
    manifest_present=1
    file_dirs="$("${s5_global[@]}" cat "$manifest_uri" | tr '\n' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')"
    sync_dirs="$file_dirs"
    if [[ -n "$sync_dirs" ]]; then
      echo "[sync] using ${manifest_uri}: ${sync_dirs}"
    else
      echo "[sync] sync_dirs.txt is empty; skipping data sync"
    fi
  fi

  sync_dirs="${sync_dirs#\"}"
  sync_dirs="${sync_dirs%\"}"
  sync_dirs="${sync_dirs#\'}"
  sync_dirs="${sync_dirs%\'}"
  sync_id="$(printf '%s\n%s' "$S3_ROOT" "$sync_dirs" | sha256sum | awk '{print $1}')"
  marker="${DATA_DIR}/.s3_sync_done_${sync_id}"

  if [[ "$force_sync" == "1" || "$force_sync" == "true" ]]; then
    rm -f "$marker"
  fi
  [[ ! -f "$marker" ]] || return 0

  if [[ -z "$sync_dirs" ]]; then
    if [[ "$manifest_present" == "0" ]]; then
      echo "[sync] syncing ${S3_ROOT} to ${DATA_DIR}"
      "${s5_global[@]}" sync --size-only "${S3_ROOT}/*" "${DATA_DIR}/"
    fi
  else
    IFS=',' read -r -a items <<<"$sync_dirs"
    for raw in "${items[@]}"; do
      path="$raw"
      path="${path#"${path%%[![:space:]]*}"}"
      path="${path%"${path##*[![:space:]]}"}"
      path="${path//\\\"/}"
      path="${path//\\\'/}"
      path="${path//\"/}"
      path="${path//\'/}"
      path="${path#/}"
      [[ -n "$path" ]] || continue

      if [[ "$path" == ".." || "$path" == ../* || "$path" == */../* || "$path" == */.. ]]; then
        echo "[sync] refusing path outside DATA_DIR: ${path}" >&2
        return 2
      fi

      if [[ "$path" == */ ]]; then
        mkdir -p "${DATA_DIR}/${path}"
        "${s5_global[@]}" sync --size-only "${S3_ROOT}/${path}*" "${DATA_DIR}/${path}"
      else
        destination="${DATA_DIR}/$(dirname "$path")"
        mkdir -p "$destination"
        "${s5_cp[@]}" --if-size-differ "${S3_ROOT}/${path}" "${destination}/"
      fi
    done
  fi

  touch "$marker"
}

sync_repo() {
  [[ -n "$REPO_URL" ]] || return 0

  mkdir -p "$(dirname "$REPO_DIR")"
  if ! git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "$REPO_DIR"; then
    git config --system --add safe.directory "$REPO_DIR" 2>/dev/null || true
  fi

  if [[ ! -d "$REPO_DIR/.git" ]]; then
    rm -rf "$REPO_DIR" 2>/dev/null || true
    git clone --depth "$GIT_CLONE_DEPTH" "$REPO_URL" "$REPO_DIR"
  else
    git -C "$REPO_DIR" fetch --all --prune --depth "$GIT_CLONE_DEPTH"
    git -C "$REPO_DIR" pull --rebase --autostash --depth "$GIT_CLONE_DEPTH"
  fi

  if [[ -f "$REPO_DIR/pyproject.toml" || -f "$REPO_DIR/setup.py" ]]; then
    /opt/venv/bin/pip install -e "$REPO_DIR"
  fi
}

start_tailscale() {
  local hostname="${TS_HOSTNAME:-gpu-box}"
  local connected=0
  local -a up_args=(
    "--hostname=${hostname}"
    "--accept-dns=${TS_ACCEPT_DNS:-false}"
    "--advertise-tags=${TS_TAGS:-tag:gpu}"
  )
  local -a extra=()

  mkdir -p "${TS_STATE_DIR:-/var/lib/tailscale}" /var/run/tailscale
  nohup /usr/sbin/tailscaled \
    --tun=userspace-networking \
    --state="${TS_STATE_DIR:-/var/lib/tailscale}/tailscaled.state" \
    --socket=/var/run/tailscale/tailscaled.sock \
    >/tmp/tailscaled.log 2>&1 &

  for _ in {1..100}; do
    [[ -S /var/run/tailscale/tailscaled.sock ]] && break
    sleep 0.1
  done

  if [[ "${TS_ENABLE_SSH:-true}" == "true" ]]; then
    up_args+=(--ssh)
  fi
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    up_args+=("--authkey=${TS_AUTHKEY}")
  fi
  if [[ -n "${TS_EXTRA_ARGS:-}" ]]; then
    read -r -a extra <<<"${TS_EXTRA_ARGS}"
  fi

  for _ in {1..60}; do
    if tailscale up "${up_args[@]}" "${extra[@]}"; then
      connected=1
      break
    fi
    sleep 2
  done

  [[ "$connected" == "1" ]] || echo "[tailscale] connection was not established" >&2
  tailscale status || true
}

run_s3_entrypoint() {
  [[ -n "$S3_ROOT" ]] || return 0

  local remote="${S3_ENTRYPOINT_URI:-${S3_ROOT}/entrypoint.sh}"
  local script="${DATA_DIR}/entrypoint.sh"
  rm -f "$script"

  if s5cmd cp --if-size-differ "$remote" "$script" && [[ -f "$script" ]]; then
    chmod +x "$script"
    "$script"
  fi
}

sync_s3
sync_repo
start_tailscale
run_s3_entrypoint

if [[ $# -gt 0 ]]; then
  exec "$@"
else
  exec sleep infinity
fi
