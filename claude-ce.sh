#!/usr/bin/env bash
set -euo pipefail

trap 'echo "Error on line $LINENO. Exiting." >&2' ERR

BLOCK_START="# >>> claude-ce managed block >>> DO NOT EDIT"
BLOCK_END="# <<< claude-ce managed block <<<"
BLOCK_HEADER_COMMENT="# Added by claude-ce (https://github.com/mdfaridmiah/claude-ce)"

FORCE=0

VERSION="1.0.0"
UPDATE_URL="${CLAUDE_CE_UPDATE_URL:-https://raw.githubusercontent.com/mdfaridmiah/claude-ce/main/claude-ce.sh}"

# Files and folders that sync/clone share between accounts. Credentials
# (.credentials.json) and per-account state (.claude.json) are never included.
SHARED_ITEMS=(settings.json CLAUDE.md keybindings.json agents commands skills output-styles)

usage() {
    cat <<'EOF'
claude-ce - Manage multiple Claude Code accounts with shell aliases

USAGE:
  claude-ce.sh <command> [args] [flags]

COMMANDS:
  add <n>              Add a new account alias (creates ~/.claude-<n>)
  remove <n>           Remove an account alias (keeps config directory)
  list                 List all managed accounts
  uninstall            Remove all managed aliases from your rc file
  run <n> [args...]    Launch Claude Code with account <n>, no alias needed
  rename <old> <new>   Rename an account (alias and config directory)
  sync [from] [to...]  Link shared settings from <from> (default: ~/.claude)
                       into the given accounts (default: all accounts)
  clone <from> <to>    Create account <to> with a copy of <from>'s settings
  export <n> [file]    Back up account <n> to a .tar.gz (no credentials)
  import <file> <n>    Restore a backup into account <n>
  update               Update claude-ce to the latest version
  version              Show the claude-ce version
  help                 Show this help

  <from> can be "default" to mean your main ~/.claude directory.
  Shared items: settings.json, CLAUDE.md, keybindings.json, agents,
  commands, skills, output-styles. Credentials are never shared.

FLAGS:
  -y, --force      Skip interactive confirmations
  -h, --help       Show this help
  --version        Show the claude-ce version

EXAMPLES:
  ./claude-ce.sh add work
  ./claude-ce.sh add personal
  source ~/.zshrc
  claude-work        # launches Claude Code with work account
  claude-personal    # launches Claude Code with personal account
  ./claude-ce.sh run work -p "hello"
  ./claude-ce.sh sync              # share ~/.claude settings with all accounts
  ./claude-ce.sh clone work client-acme
  ./claude-ce.sh export work

LEARN MORE:
  https://github.com/mdfaridmiah/claude-ce
EOF
}

display_path() {
    local p="$1"
    if [[ "$p" == "$HOME"* ]]; then
        echo "~${p#$HOME}"
    else
        echo "$p"
    fi
}

validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo 'Error: account name must be lowercase letters, digits, and hyphens only (e.g., "work", "personal", "client-acme").' >&2
        exit 1
    fi
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
        echo 'Error: account name must be lowercase letters, digits, and hyphens only (e.g., "work", "personal", "client-acme").' >&2
        exit 1
    fi
}

detect_platform() {
    local os
    os="$(uname -s)"
    case "$os" in
        MINGW*|MSYS*|CYGWIN*)
            cat >&2 <<'EOF'
Error: native Windows shells (Git Bash, MSYS, Cygwin) are not supported due to
Claude Code's ~/.claude.json global state conflict on Windows. Please use WSL.
EOF
            exit 1
            ;;
    esac
}

detect_rc_file() {
    local shell_path="${SHELL:-}"
    local shell_base
    shell_base="$(basename "$shell_path")"
    case "$shell_base" in
        bash)
            if [[ "$(uname -s)" == "Darwin" && ! -f "$HOME/.bashrc" && -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
        zsh)
            echo "$HOME/.zshrc"
            ;;
        *)
            echo "Error: unsupported shell \"${shell_path}\". Only bash and zsh are supported." >&2
            exit 1
            ;;
    esac
}

find_block_range() {
    local rc="$1"
    if [[ ! -f "$rc" ]]; then
        return 0
    fi
    local start end
    start="$(grep -n -F "$BLOCK_START" "$rc" | head -n1 | cut -d: -f1 || true)"
    end="$(grep -n -F "$BLOCK_END" "$rc" | head -n1 | cut -d: -f1 || true)"
    if [[ -n "$start" && -n "$end" ]]; then
        echo "$start $end"
    fi
}

block_contains_alias() {
    local rc="$1"
    local name="$2"
    [[ -f "$rc" ]] || return 1
    local range
    range="$(find_block_range "$rc")"
    [[ -z "$range" ]] && return 1
    local start end
    start="${range% *}"
    end="${range#* }"
    if sed -n "${start},${end}p" "$rc" | grep -qE "^alias[[:space:]]+claude-${name}="; then
        return 0
    fi
    return 1
}

external_alias_info() {
    local rc="$1"
    local name="$2"
    [[ -f "$rc" ]] || return 1
    local range start end
    range="$(find_block_range "$rc")"
    if [[ -n "$range" ]]; then
        start="${range% *}"
        end="${range#* }"
    else
        start=0
        end=0
    fi

    local matches
    matches="$(grep -nE "^[[:space:]]*alias[[:space:]]+claude-${name}=|^[[:space:]]*claude-${name}[[:space:]]*\(\)" "$rc" || true)"
    [[ -z "$matches" ]] && return 1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local lnum="${line%%:*}"
        if (( lnum < start || lnum > end )); then
            echo "$line"
            return 0
        fi
    done <<< "$matches"
    return 1
}

ensure_rc_exists() {
    local rc="$1"
    if [[ ! -f "$rc" ]]; then
        local rc_dir
        rc_dir="$(dirname "$rc")"
        if [[ ! -d "$rc_dir" ]]; then
            if ! mkdir -p "$rc_dir" 2>/dev/null; then
                echo "Error: cannot create directory $(display_path "$rc_dir")" >&2
                exit 2
            fi
        fi
        if ! : > "$rc" 2>/dev/null; then
            echo "Error: cannot write to $(display_path "$rc")" >&2
            exit 2
        fi
    fi
}

add_alias_to_rc() {
    local rc="$1"
    local name="$2"
    local alias_line="alias claude-${name}='CLAUDE_CONFIG_DIR=\$HOME/.claude-${name} claude'"
    local tmp="${rc}.tmp.$$"

    ensure_rc_exists "$rc"

    local range
    range="$(find_block_range "$rc")"

    if [[ -z "$range" ]]; then
        {
            cat "$rc"
            local last_char
            if [[ -s "$rc" ]]; then
                last_char="$(tail -c 1 "$rc" || true)"
                if [[ "$last_char" != $'\n' ]]; then
                    echo ""
                fi
                echo ""
            fi
            echo "$BLOCK_START"
            echo "$BLOCK_HEADER_COMMENT"
            echo "$alias_line"
            echo "$BLOCK_END"
        } > "$tmp"
        mv "$tmp" "$rc"
        return 0
    fi

    local end
    end="${range#* }"
    awk -v end="$end" -v line="$alias_line" '
        NR == end { print line }
        { print }
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
}

remove_alias_line() {
    local rc="$1"
    local name="$2"
    local tmp="${rc}.tmp.$$"
    local range
    range="$(find_block_range "$rc")"
    [[ -z "$range" ]] && return 1
    local start end
    start="${range% *}"
    end="${range#* }"

    awk -v start="$start" -v end="$end" -v name="$name" '
        {
            if (NR >= start && NR <= end) {
                pat = "^alias[[:space:]]+claude-" name "="
                if ($0 ~ pat) { next }
            }
            print
        }
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
}

block_has_any_alias() {
    local rc="$1"
    local range
    range="$(find_block_range "$rc")"
    [[ -z "$range" ]] && return 1
    local start end
    start="${range% *}"
    end="${range#* }"
    if sed -n "${start},${end}p" "$rc" | grep -qE "^alias[[:space:]]+claude-"; then
        return 0
    fi
    return 1
}

remove_entire_block() {
    local rc="$1"
    local tmp="${rc}.tmp.$$"
    local range
    range="$(find_block_range "$rc")"
    [[ -z "$range" ]] && return 0
    local start end
    start="${range% *}"
    end="${range#* }"

    awk -v start="$start" -v end="$end" '
        NR >= start && NR <= end { next }
        { print }
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
}

list_managed_aliases() {
    local rc="$1"
    local range
    range="$(find_block_range "$rc")"
    [[ -z "$range" ]] && return 0
    local start end
    start="${range% *}"
    end="${range#* }"
    sed -n "${start},${end}p" "$rc" | grep -oE "^alias[[:space:]]+claude-[a-z0-9][a-z0-9-]*" | awk '{print $2}' || true
}

cmd_add() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Error: 'add' requires an account name." >&2
        usage >&2
        exit 1
    fi
    validate_name "$name"
    detect_platform
    local rc
    rc="$(detect_rc_file)"
    local rc_display
    rc_display="$(display_path "$rc")"

    if ! command -v claude >/dev/null 2>&1; then
        cat <<'EOF'
Warning: 'claude' command not found in PATH.
Install Claude Code first: https://docs.claude.com/en/docs/claude-code/overview
The alias will be added, but won't work until Claude Code is installed.
EOF
        if (( FORCE == 0 )); then
            local ans=""
            read -r -p "Continue anyway? [y/N]: " ans || true
            case "${ans:-}" in
                y|Y|yes|YES) ;;
                *) echo "Aborted."; exit 0 ;;
            esac
        fi
    fi

    local dir="$HOME/.claude-$name"
    local dir_display
    dir_display="$(display_path "$dir")"
    if [[ -d "$dir" ]]; then
        if (( FORCE == 0 )); then
            echo "Config directory ${dir_display} already exists."
            echo "[1] Keep existing directory (use as-is)"
            echo "[2] Abort"
            local ans=""
            read -r -p "Choice [1]: " ans || true
            case "${ans:-1}" in
                1|"") ;;
                2) echo "Aborted."; exit 0 ;;
                *) echo "Invalid choice. Aborted." >&2; exit 1 ;;
            esac
        fi
    else
        if ! mkdir -p "$dir" 2>/dev/null; then
            echo "Error: failed to create ${dir_display}" >&2
            exit 2
        fi
    fi

    if [[ -f "$rc" ]]; then
        if block_contains_alias "$rc" "$name"; then
            if (( FORCE == 0 )); then
                echo "Alias 'claude-$name' already managed by this tool."
                echo "[1] Skip (no changes)"
                echo "[2] Abort"
                local ans=""
                read -r -p "Choice [1]: " ans || true
                case "${ans:-1}" in
                    1|"") echo "Skipped. No changes made."; exit 0 ;;
                    2) echo "Aborted."; exit 0 ;;
                    *) echo "Invalid choice. Aborted." >&2; exit 1 ;;
                esac
            else
                echo "Alias 'claude-$name' already managed by this tool. Skipping."
                exit 0
            fi
        fi

        local external
        external="$(external_alias_info "$rc" "$name" || true)"
        if [[ -n "$external" ]]; then
            local lnum content
            lnum="${external%%:*}"
            content="${external#*:}"
            if (( FORCE == 1 )); then
                echo "Error: found existing 'claude-$name' alias/function in ${rc_display} NOT managed by this tool:" >&2
                echo "  ${lnum}: ${content}" >&2
                echo "Aborting (use interactive mode to override)." >&2
                exit 1
            fi
            echo "Found an existing 'claude-$name' alias/function in ${rc_display} NOT managed by this tool:"
            echo "  ${lnum}: ${content}"
            echo ""
            echo "What would you like to do?"
            echo "[1] Abort (recommended; review the existing definition first)"
            echo "[2] Add ours anyway (yours may shadow theirs depending on order)"
            local ans=""
            read -r -p "Choice [1]: " ans || true
            case "${ans:-1}" in
                1|"") echo "Aborted."; exit 0 ;;
                2) ;;
                *) echo "Invalid choice. Aborted." >&2; exit 1 ;;
            esac
        fi
    fi

    add_alias_to_rc "$rc" "$name"

    cat <<EOF
✓ Added alias 'claude-$name' to ${rc_display}
✓ Config directory: ${dir_display}

Next steps:
  1. Reload your shell:      source ${rc_display}
  2. Launch this account:    claude-$name
  3. Log in when prompted (browser will open)

To list all accounts:   ./claude-ce.sh list
To remove this account: ./claude-ce.sh remove $name
EOF
}

cmd_remove() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Error: 'remove' requires an account name." >&2
        usage >&2
        exit 1
    fi
    validate_name "$name"
    local rc
    rc="$(detect_rc_file)"
    local rc_display
    rc_display="$(display_path "$rc")"
    local dir_display
    dir_display="$(display_path "$HOME/.claude-$name")"

    if [[ ! -f "$rc" ]] || ! block_contains_alias "$rc" "$name"; then
        echo "No alias 'claude-$name' managed by this tool."
        exit 1
    fi

    if (( FORCE == 0 )); then
        echo "Remove alias 'claude-$name' from ${rc_display}?"
        echo "Note: the config directory ${dir_display} will be preserved."
        local ans=""
        read -r -p "[y/N]: " ans || true
        case "${ans:-}" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 0 ;;
        esac
    fi

    remove_alias_line "$rc" "$name"
    if ! block_has_any_alias "$rc"; then
        remove_entire_block "$rc"
    fi

    echo "✓ Removed alias 'claude-$name'. Config directory preserved at ${dir_display}."
}

cmd_list() {
    local rc
    rc="$(detect_rc_file)"

    if [[ ! -f "$rc" ]]; then
        echo "No accounts currently managed by claude-ce."
        return 0
    fi

    local range
    range="$(find_block_range "$rc")"
    if [[ -z "$range" ]]; then
        echo "No accounts currently managed by claude-ce."
        return 0
    fi

    local aliases
    aliases="$(list_managed_aliases "$rc")"
    if [[ -z "$aliases" ]]; then
        echo "No accounts currently managed by claude-ce."
        return 0
    fi

    while IFS= read -r alias_name; do
        [[ -z "$alias_name" ]] && continue
        local n="${alias_name#claude-}"
        local dir="$HOME/.claude-$n"
        local dir_display
        dir_display="$(display_path "$dir")"
        local status
        if [[ -d "$dir" ]]; then
            status="exists"
        else
            status="missing"
        fi
        printf '%s   ->   %s   (%s)\n' "$alias_name" "$dir_display" "$status"
    done <<< "$aliases"
}

cmd_uninstall() {
    local rc
    rc="$(detect_rc_file)"
    local rc_display
    rc_display="$(display_path "$rc")"

    if [[ ! -f "$rc" ]]; then
        echo "Nothing to uninstall."
        return 0
    fi

    local range
    range="$(find_block_range "$rc")"
    if [[ -z "$range" ]]; then
        echo "Nothing to uninstall."
        return 0
    fi

    local aliases
    aliases="$(list_managed_aliases "$rc")"

    if (( FORCE == 0 )); then
        echo "This will remove the claude-ce managed block from ${rc_display}, removing these aliases:"
        if [[ -n "$aliases" ]]; then
            while IFS= read -r a; do
                [[ -z "$a" ]] && continue
                echo "  - $a"
            done <<< "$aliases"
        else
            echo "  (no aliases currently in block)"
        fi
        echo ""
        echo "Config directories (~/.claude-*) will be PRESERVED so your account data is safe."
        echo ""
        local ans=""
        read -r -p "Continue? [y/N]: " ans || true
        case "${ans:-}" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 0 ;;
        esac
    fi

    remove_entire_block "$rc"
    echo "✓ Uninstalled. You can safely delete this script now. To also remove config data, manually rm -rf ~/.claude-<n>."
}

account_dir() {
    local name="$1"
    if [[ "$name" == "default" ]]; then
        echo "$HOME/.claude"
    else
        echo "$HOME/.claude-$name"
    fi
}

validate_source_name() {
    local name="$1"
    if [[ "$name" != "default" ]]; then
        validate_name "$name"
    fi
}

confirm() {
    local prompt="$1"
    if (( FORCE == 1 )); then
        return 0
    fi
    local ans=""
    read -r -p "$prompt [y/N]: " ans || true
    case "${ans:-}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_alias_name_free() {
    local rc="$1"
    local name="$2"
    local rc_display
    rc_display="$(display_path "$rc")"
    [[ -f "$rc" ]] || return 0
    if block_contains_alias "$rc" "$name"; then
        echo "Error: alias 'claude-$name' is already managed by this tool." >&2
        exit 1
    fi
    local external
    external="$(external_alias_info "$rc" "$name" || true)"
    if [[ -n "$external" ]]; then
        echo "Error: found existing 'claude-$name' alias/function in ${rc_display} NOT managed by this tool:" >&2
        echo "  ${external%%:*}: ${external#*:}" >&2
        exit 1
    fi
}

cmd_run() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Error: 'run' requires an account name." >&2
        usage >&2
        exit 1
    fi
    shift
    validate_name "$name"
    detect_platform

    local dir
    dir="$(account_dir "$name")"
    if [[ ! -d "$dir" ]]; then
        echo "Error: config directory $(display_path "$dir") does not exist. Add the account first: claude-ce add $name" >&2
        exit 1
    fi
    if ! command -v claude >/dev/null 2>&1; then
        echo "Error: 'claude' command not found in PATH." >&2
        exit 2
    fi

    CLAUDE_CONFIG_DIR="$dir" exec claude "$@"
}

cmd_rename() {
    local old="${1:-}"
    local new="${2:-}"
    if [[ -z "$old" || -z "$new" ]]; then
        echo "Error: 'rename' requires an old and a new account name." >&2
        usage >&2
        exit 1
    fi
    validate_name "$old"
    validate_name "$new"
    if [[ "$old" == "$new" ]]; then
        echo "Error: old and new names are the same." >&2
        exit 1
    fi
    detect_platform

    local rc
    rc="$(detect_rc_file)"
    local rc_display
    rc_display="$(display_path "$rc")"
    if [[ ! -f "$rc" ]] || ! block_contains_alias "$rc" "$old"; then
        echo "No alias 'claude-$old' managed by this tool." >&2
        exit 1
    fi
    ensure_alias_name_free "$rc" "$new"

    local old_dir new_dir
    old_dir="$(account_dir "$old")"
    new_dir="$(account_dir "$new")"
    if [[ -e "$new_dir" ]]; then
        echo "Error: $(display_path "$new_dir") already exists." >&2
        exit 1
    fi

    if ! confirm "Rename 'claude-$old' to 'claude-$new' and move $(display_path "$old_dir") to $(display_path "$new_dir")?"; then
        echo "Aborted."
        exit 0
    fi

    if [[ -d "$old_dir" ]]; then
        mv "$old_dir" "$new_dir"
    else
        mkdir -p "$new_dir"
    fi
    remove_alias_line "$rc" "$old"
    add_alias_to_rc "$rc" "$new"

    cat <<EOF
✓ Renamed 'claude-$old' to 'claude-$new'
✓ Config directory: $(display_path "$new_dir")

Reload your shell: source ${rc_display}
Note: you may need to log in again the first time you run claude-$new.
EOF
}

cmd_sync() {
    local from="${1:-}"
    [[ -z "$from" ]] && from="default"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    local targets=()
    local t
    for t in "$@"; do
        [[ -n "$t" ]] && targets+=("$t")
    done

    validate_source_name "$from"
    local src
    src="$(account_dir "$from")"
    if [[ ! -d "$src" ]]; then
        echo "Error: source directory $(display_path "$src") does not exist." >&2
        exit 1
    fi

    if (( ${#targets[@]} == 0 )); then
        local rc
        rc="$(detect_rc_file)"
        local a
        while IFS= read -r a; do
            [[ -n "$a" ]] && targets+=("${a#claude-}")
        done <<< "$( [[ -f "$rc" ]] && list_managed_aliases "$rc" || true )"
    fi

    local filtered=()
    for t in ${targets[@]+"${targets[@]}"}; do
        validate_name "$t"
        [[ "$t" != "$from" ]] && filtered+=("$t")
    done
    if (( ${#filtered[@]} == 0 )); then
        echo "No accounts to sync."
        return 0
    fi

    local items=()
    local item
    for item in "${SHARED_ITEMS[@]}"; do
        [[ -e "$src/$item" ]] && items+=("$item")
    done
    if (( ${#items[@]} == 0 )); then
        echo "Nothing to share in $(display_path "$src")."
        return 0
    fi

    echo "This will link these items from $(display_path "$src"):"
    printf '  - %s\n' "${items[@]}"
    echo "into these accounts:"
    printf '  - claude-%s\n' "${filtered[@]}"
    echo "Existing files that are not links are backed up as <name>.bak.<timestamp>."
    if ! confirm "Continue?"; then
        echo "Aborted."
        exit 0
    fi

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    for t in "${filtered[@]}"; do
        local tdir
        tdir="$(account_dir "$t")"
        if [[ ! -d "$tdir" ]]; then
            echo "Skipping claude-$t: $(display_path "$tdir") does not exist."
            continue
        fi
        for item in "${items[@]}"; do
            local dest="$tdir/$item"
            if [[ -L "$dest" ]]; then
                rm "$dest"
            elif [[ -e "$dest" ]]; then
                mv "$dest" "$dest.bak.$ts"
                echo "  backed up $(display_path "$dest") -> $(display_path "$dest.bak.$ts")"
            fi
            ln -s "$src/$item" "$dest"
        done
        echo "✓ Synced claude-$t"
    done
}

cmd_clone() {
    local from="${1:-}"
    local to="${2:-}"
    if [[ -z "$from" || -z "$to" ]]; then
        echo "Error: 'clone' requires a source and a new account name." >&2
        usage >&2
        exit 1
    fi
    validate_source_name "$from"
    validate_name "$to"
    detect_platform

    local src dest
    src="$(account_dir "$from")"
    dest="$(account_dir "$to")"
    if [[ ! -d "$src" ]]; then
        echo "Error: source directory $(display_path "$src") does not exist." >&2
        exit 1
    fi
    if [[ -e "$dest" ]]; then
        echo "Error: $(display_path "$dest") already exists." >&2
        exit 1
    fi

    local rc
    rc="$(detect_rc_file)"
    local rc_display
    rc_display="$(display_path "$rc")"
    ensure_alias_name_free "$rc" "$to"

    if ! mkdir -p "$dest" 2>/dev/null; then
        echo "Error: failed to create $(display_path "$dest")" >&2
        exit 2
    fi

    local item
    for item in "${SHARED_ITEMS[@]}"; do
        if [[ -e "$src/$item" ]]; then
            if cp -RL "$src/$item" "$dest/$item"; then
                echo "  copied $item"
            else
                echo "  warning: could not fully copy $item" >&2
            fi
        fi
    done

    add_alias_to_rc "$rc" "$to"

    cat <<EOF
✓ Created 'claude-$to' from $(display_path "$src") (credentials not copied)
✓ Config directory: $(display_path "$dest")

Next steps:
  1. Reload your shell:      source ${rc_display}
  2. Launch this account:    claude-$to
  3. Log in when prompted (browser will open)
EOF
}

cmd_export() {
    local name="${1:-}"
    local file="${2:-}"
    if [[ -z "$name" ]]; then
        echo "Error: 'export' requires an account name." >&2
        usage >&2
        exit 1
    fi
    validate_source_name "$name"
    local dir
    dir="$(account_dir "$name")"
    if [[ ! -d "$dir" ]]; then
        echo "Error: config directory $(display_path "$dir") does not exist." >&2
        exit 1
    fi
    if [[ -z "$file" ]]; then
        file="claude-$name-$(date +%Y%m%d-%H%M%S).tar.gz"
    fi
    if [[ -e "$file" ]] && ! confirm "$file already exists. Overwrite?"; then
        echo "Aborted."
        exit 0
    fi

    # -h stores the content of linked files (e.g. from sync) instead of the links.
    if ! tar -czhf "$file" -C "$dir" --exclude='./.credentials.json' --exclude='./cache' .; then
        echo "Error: failed to create $file" >&2
        exit 2
    fi
    echo "✓ Exported $(display_path "$dir") to $file (credentials not included)"
}

cmd_import() {
    local file="${1:-}"
    local name="${2:-}"
    if [[ -z "$file" || -z "$name" ]]; then
        echo "Error: 'import' requires a backup file and an account name." >&2
        usage >&2
        exit 1
    fi
    if [[ ! -f "$file" ]]; then
        echo "Error: file '$file' not found." >&2
        exit 1
    fi
    validate_name "$name"
    detect_platform

    local listing
    if ! listing="$(tar -tvzf "$file" 2>/dev/null)"; then
        echo "Error: '$file' is not a valid .tar.gz backup." >&2
        exit 1
    fi
    if grep -qE '^[lh]' <<< "$listing"; then
        echo "Error: '$file' contains links; refusing to import it." >&2
        exit 1
    fi
    if tar -tzf "$file" | grep -qE '^/|(^|/)\.\.(/|$)'; then
        echo "Error: '$file' contains unsafe paths; refusing to import it." >&2
        exit 1
    fi

    local rc
    rc="$(detect_rc_file)"
    local rc_display
    rc_display="$(display_path "$rc")"
    local managed=0
    if [[ -f "$rc" ]] && block_contains_alias "$rc" "$name"; then
        managed=1
    else
        ensure_alias_name_free "$rc" "$name"
    fi

    local dir
    dir="$(account_dir "$name")"
    if [[ -d "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
        if ! confirm "$(display_path "$dir") is not empty. Files from the backup will overwrite matching files. Continue?"; then
            echo "Aborted."
            exit 0
        fi
    fi

    mkdir -p "$dir"
    if ! tar -xzf "$file" -C "$dir"; then
        echo "Error: failed to extract $file" >&2
        exit 2
    fi
    if (( managed == 0 )); then
        add_alias_to_rc "$rc" "$name"
    fi

    cat <<EOF
✓ Imported $file into $(display_path "$dir")
✓ Alias: claude-$name

Next steps:
  1. Reload your shell:      source ${rc_display}
  2. Launch this account:    claude-$name
  3. Log in when prompted (credentials are not part of backups)
EOF
}

cmd_version() {
    echo "claude-ce $VERSION"
}

cmd_update() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: 'curl' is required but not installed." >&2
        exit 2
    fi

    local self="${BASH_SOURCE[0]}"
    while [[ -L "$self" ]]; do
        local link
        link="$(readlink "$self")"
        if [[ "$link" == /* ]]; then
            self="$link"
        else
            self="$(dirname "$self")/$link"
        fi
    done

    if [[ ! -w "$self" || ! -w "$(dirname "$self")" ]]; then
        echo "Error: no write permission for $(display_path "$self")." >&2
        exit 2
    fi

    local tmp
    tmp="$(mktemp "$(dirname "$self")/.claude-ce.update.XXXXXX")"
    if ! curl -fsSL "$UPDATE_URL" -o "$tmp"; then
        rm -f "$tmp"
        echo "Error: failed to download from $UPDATE_URL" >&2
        exit 2
    fi
    local first_line
    first_line="$(head -n 1 "$tmp")"
    if [[ "$first_line" != "#!/usr/bin/env bash" && "$first_line" != "#!/bin/bash" ]] || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "Error: downloaded file is not a valid claude-ce script." >&2
        exit 2
    fi

    local new_version
    new_version="$(grep -m1 -E '^VERSION=' "$tmp" | cut -d'"' -f2 || true)"
    if [[ "$new_version" == "$VERSION" ]] && (( FORCE == 0 )); then
        rm -f "$tmp"
        echo "claude-ce is already up to date ($VERSION)."
        return 0
    fi
    if ! confirm "Update claude-ce $VERSION -> ${new_version:-unknown}?"; then
        rm -f "$tmp"
        echo "Aborted."
        exit 0
    fi

    chmod +x "$tmp"
    mv "$tmp" "$self"
    echo "✓ Updated $(display_path "$self") to ${new_version:-the latest version}"
}

main() {
    local cmd=""
    local positional=()

    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    # Everything after 'run <n>' goes to claude unchanged, including flags.
    if [[ "$1" == "run" ]]; then
        shift
        cmd_run "$@"
    fi

    while [[ $# -gt 0 ]]; do
        local arg="$1"
        case "$arg" in
            -y|--force)
                FORCE=1
                shift
                ;;
            -h|--help)
                if [[ -z "$cmd" ]]; then
                    usage
                    exit 0
                fi
                usage
                exit 0
                ;;
            --version)
                cmd_version
                exit 0
                ;;
            help)
                usage
                exit 0
                ;;
            add|remove|list|uninstall|rename|sync|clone|export|import|update|version)
                if [[ -z "$cmd" ]]; then
                    cmd="$arg"
                else
                    positional+=("$arg")
                fi
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    positional+=("$1")
                    shift
                done
                ;;
            -*)
                echo "Error: unknown flag '$arg'" >&2
                usage >&2
                exit 1
                ;;
            *)
                if [[ -z "$cmd" ]]; then
                    echo "Error: unknown command '$arg'" >&2
                    usage >&2
                    exit 1
                fi
                positional+=("$arg")
                shift
                ;;
        esac
    done

    case "$cmd" in
        add)
            cmd_add "${positional[@]:-}"
            ;;
        remove)
            cmd_remove "${positional[@]:-}"
            ;;
        list)
            cmd_list
            ;;
        uninstall)
            cmd_uninstall
            ;;
        rename)
            cmd_rename "${positional[@]:-}"
            ;;
        sync)
            cmd_sync "${positional[@]:-}"
            ;;
        clone)
            cmd_clone "${positional[@]:-}"
            ;;
        export)
            cmd_export "${positional[@]:-}"
            ;;
        import)
            cmd_import "${positional[@]:-}"
            ;;
        update)
            cmd_update
            ;;
        version)
            cmd_version
            ;;
        "")
            usage
            exit 1
            ;;
    esac
}

main "$@"
