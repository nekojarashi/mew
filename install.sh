#!/usr/bin/env bash
# mew インストーラ
# 本体をダウンロードし、PATH 上のディレクトリに配置して実行権限を付与する。
#
# source で実行すると、このターミナルに PATH が反映され、すぐ mew が使える:
#   source <(curl -sSL .../install.sh)
# パイプで実行した場合はインストールのみ（新しいターミナルか .bashrc 等で PATH を追加すること）:
#   curl -sSL .../install.sh | bash

# Source-safety: set -euo pipefail がユーザーの対話シェルに漏洩するのを防ぐ。
# RETURN trap は bash で source 終了時（エラー含む）に発火する。
# zsh では RETURN trap 非対応のため、末尾の明示呼び出しで対応（エラー時は漏洩する制限あり）。
_mew_saved_options="$(set +o 2>/dev/null)" || true

_mew_restore_options() {
  eval "$_mew_saved_options" 2>/dev/null || true
  unset _mew_saved_options 2>/dev/null || true
  unset -f _mew_restore_options 2>/dev/null || true
  trap - RETURN 2>/dev/null || true
}

trap _mew_restore_options RETURN 2>/dev/null || true

set -euo pipefail

MEW_RAW_URL="${MEW_RAW_URL:-https://raw.githubusercontent.com/nekojarashi/mew/main/mew}"
MEW_INSTALL_DIR="${MEW_INSTALL_DIR:-}"
MEW_CHECKSUM="${MEW_CHECKSUM:-}"

# 前提チェック（警告のみ、インストールは続行）
for cmd in git docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "mew install: 警告: $cmd が PATH にありません。mew 実行時にエラーになります。" >&2
  fi
done

# 書き込み可能なディレクトリを選ぶ
choose_install_dir() {
  if [[ -n "$MEW_INSTALL_DIR" ]]; then
    echo "$MEW_INSTALL_DIR"
    return
  fi
  for dir in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
    if [[ -d "$dir" && -w "$dir" ]]; then
      echo "$dir"
      return
    fi
    if [[ ! -d "$dir" && "$dir" == "$HOME"/* ]]; then
      mkdir -p "$dir" 2>/dev/null && echo "$dir" && return
    fi
  done
  echo "$HOME/.local/bin"
}

INSTALL_DIR="$(choose_install_dir)"
INSTALL_DIR="$(cd "$INSTALL_DIR" 2>/dev/null && pwd || echo "$INSTALL_DIR")"
TARGET="$INSTALL_DIR/mew"

# ローカル実行時: install.sh と同じディレクトリに mew があればコピーするだけ
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
fi
LOCAL_MEW="${SCRIPT_DIR}/mew"

if [[ -n "$SCRIPT_DIR" && -f "$LOCAL_MEW" ]]; then
  echo "mew をインストールします（ローカルからコピー）: $TARGET"
  cp "$LOCAL_MEW" "$TARGET"
else
  echo "mew をインストールします: $TARGET"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 --max-redirs 3 "$MEW_RAW_URL" -o "$TARGET"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only --max-redirect=3 -O "$TARGET" "$MEW_RAW_URL"
  else
    echo "mew install: curl または wget が必要です。" >&2
    return 1 2>/dev/null || exit 1
  fi
  # チェックサム検証（MEW_CHECKSUM が指定されている場合）
  if [[ -n "$MEW_CHECKSUM" ]]; then
    ACTUAL_CHECKSUM=""
    if command -v sha256sum >/dev/null 2>&1; then
      ACTUAL_CHECKSUM="$(sha256sum "$TARGET" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      ACTUAL_CHECKSUM="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
    fi
    if [[ -z "$ACTUAL_CHECKSUM" ]]; then
      echo "mew install: 警告: sha256sum/shasum が利用できないため、チェックサム検証をスキップしました。" >&2
    elif [[ "$ACTUAL_CHECKSUM" != "$MEW_CHECKSUM" ]]; then
      rm -f "$TARGET"
      echo "mew install: チェックサム不一致。ダウンロードを中断しました。" >&2
      echo "  期待値: $MEW_CHECKSUM" >&2
      echo "  実際値: $ACTUAL_CHECKSUM" >&2
      return 1 2>/dev/null || exit 1
    else
      echo "チェックサム検証: OK"
    fi
  fi
  # 404 や HTML が保存されていないか確認（先頭が shebang であること）
  if ! head -n 1 "$TARGET" | grep -q '^#!'; then
    rm -f "$TARGET"
    echo "mew install: ダウンロードに失敗しました（404 または不正な応答）。URL を確認してください: $MEW_RAW_URL" >&2
    return 1 2>/dev/null || exit 1
  fi
fi

chmod +x "$TARGET"
echo "インストールしました: $TARGET"

# source で実行された場合はこのシェルに PATH を反映（パイプで bash に渡した場合はサブシェルなので影響しない）
INSTALL_DIR_WAS_IN_PATH=false
echo ":$PATH:" | grep -q ":$INSTALL_DIR:" && INSTALL_DIR_WAS_IN_PATH=true
export PATH="$INSTALL_DIR:$PATH"

if ! $INSTALL_DIR_WAS_IN_PATH; then
  echo
  echo "次のディレクトリが PATH に含まれていませんでした: $INSTALL_DIR"
  echo "source で実行した場合は、このターミナルで mew が使えます。"
  echo "パイプ（curl | bash）で実行した場合は、新しいターミナルを開くか、.bashrc / .zshrc に以下を追加:"
  echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
fi

# --- シェルフック（docker compose → mew compose 自動置換）の登録 ---
HOOK_MARKER_BEGIN="# BEGIN mew hook"
HOOK_MARKER_END="# END mew hook"

# フックブロックを stdout に出力（install.sh 内に保持し、mew コマンドには含めない）
emit_mew_hook() {
  cat <<'HOOK'
# BEGIN mew hook — do not edit this block manually
# docker compose → mew compose in mew-managed worktrees
# See: https://github.com/nekojarashi/mew
docker() {
  if [[ "$1" == "compose" ]]; then
    local _mew_d="$PWD"
    while [[ "$_mew_d" != "/" ]]; do
      if [[ -f "$_mew_d/.git" ]]; then
        local _mew_gitdir
        _mew_gitdir="$(sed -n 's/^gitdir: //p' "$_mew_d/.git" 2>/dev/null)"
        if [[ -n "$_mew_gitdir" ]]; then
          [[ "$_mew_gitdir" != /* ]] && _mew_gitdir="$_mew_d/$_mew_gitdir"
          if [[ -f "$_mew_gitdir/mew" ]]; then
            shift
            command mew compose "$@"
            return $?
          fi
        fi
        break
      fi
      [[ -d "$_mew_d/.git" ]] && break
      _mew_d="$(dirname "$_mew_d")"
    done
  fi
  command docker "$@"
}
# END mew hook
HOOK
}

install_hook_to_rc() {
  local rc_file="$1"
  [[ ! -f "$rc_file" ]] && return 1
  # 既にインストール済みなら更新（古いフックを除去して再追加）
  if grep -qF "$HOOK_MARKER_BEGIN" "$rc_file" 2>/dev/null; then
    # 一旦古いブロックを除去
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$HOOK_MARKER_BEGIN" -v end="$HOOK_MARKER_END" '
      $0 ~ begin { skip=1; next }
      $0 ~ end   { skip=0; next }
      !skip
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
  fi
  # フックを末尾に追加
  echo >> "$rc_file"
  emit_mew_hook >> "$rc_file"
  echo "シェルフックを追加しました: $rc_file"
  return 0
}

# 対象の rc ファイルを判定
RC_FILES=()
CURRENT_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "$CURRENT_SHELL" in
  zsh)  [[ -f "$HOME/.zshrc" ]]  && RC_FILES+=("$HOME/.zshrc");;
  bash) [[ -f "$HOME/.bashrc" ]] && RC_FILES+=("$HOME/.bashrc");;
esac
# bash も zsh もない場合はフォールバック
if ((${#RC_FILES[@]} == 0)); then
  for f in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$f" ]] && RC_FILES+=("$f") && break
  done
fi

HOOK_INSTALLED=false
for rc in "${RC_FILES[@]}"; do
  if install_hook_to_rc "$rc"; then
    HOOK_INSTALLED=true
  fi
done

if ! $HOOK_INSTALLED; then
  echo
  echo "シェルフックの自動追加をスキップしました（.zshrc / .bashrc が見つかりません）。"
  echo "手動で追加するには: README の「シェルフックの仕組み」を参照してください。"
fi

# シェルオプション復元（正常終了時。bash ではエラー時も RETURN trap で復元される）
_mew_restore_options
