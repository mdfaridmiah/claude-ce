#!/usr/bin/env bats
# Tests for claude-ce.sh. Each test runs with a throwaway $HOME, so your real
# ~/.zshrc and ~/.claude-* directories are never touched.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../claude-ce.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export SHELL=/bin/zsh
    mkdir -p "$HOME"
    RC="$HOME/.zshrc"

    # Fake 'claude' that prints the config dir and arguments it was given.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "CONFIG=$CLAUDE_CONFIG_DIR ARGS=$*"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

ce() {
    bash "$SCRIPT" "$@"
}

# --- existing commands ---

@test "add creates the alias and config directory" {
    run ce add work -y
    [ "$status" -eq 0 ]
    [ -d "$HOME/.claude-work" ]
    grep -q "^alias claude-work='CLAUDE_CONFIG_DIR=\$HOME/.claude-work claude'" "$RC"
}

@test "list, remove and uninstall still work" {
    ce add work -y
    ce add personal -y
    run ce list
    [[ "$output" == *"claude-work"* && "$output" == *"claude-personal"* ]]
    ce remove work -y
    [ -z "$(grep "claude-work=" "$RC")" ]
    ce uninstall -y
    [ -z "$(grep "claude-ce managed block" "$RC")" ]
    [ -d "$HOME/.claude-personal" ]
}

# --- run ---

@test "run launches claude with the account's config dir and passes flags through" {
    ce add work -y
    run ce run work -p "hello there" --model x
    [ "$status" -eq 0 ]
    [ "$output" = "CONFIG=$HOME/.claude-work ARGS=-p hello there --model x" ]
}

@test "run fails for an account that does not exist" {
    run ce run nobody
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

# --- rename ---

@test "rename moves the alias and config directory" {
    ce add work -y
    touch "$HOME/.claude-work/marker"
    run ce rename work job -y
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude-job/marker" ]
    [ ! -e "$HOME/.claude-work" ]
    grep -q "^alias claude-job=" "$RC"
    [ -z "$(grep "^alias claude-work=" "$RC")" ]
}

@test "rename refuses when the new name is taken" {
    ce add work -y
    ce add job -y
    run ce rename work job -y
    [ "$status" -eq 1 ]
    [ -d "$HOME/.claude-work" ]
}

# --- sync ---

@test "sync links shared items from ~/.claude into every account and backs up real files" {
    mkdir -p "$HOME/.claude/skills"
    echo '{"shared":true}' > "$HOME/.claude/settings.json"
    echo "# shared" > "$HOME/.claude/CLAUDE.md"
    echo "secret" > "$HOME/.claude/.credentials.json"
    ce add work -y
    ce add personal -y
    echo '{"own":true}' > "$HOME/.claude-work/settings.json"

    run ce sync -y
    [ "$status" -eq 0 ]
    for a in work personal; do
        [ -L "$HOME/.claude-$a/settings.json" ]
        [ -L "$HOME/.claude-$a/CLAUDE.md" ]
        [ -L "$HOME/.claude-$a/skills" ]
        [ ! -e "$HOME/.claude-$a/.credentials.json" ]
    done
    ls -a "$HOME/.claude-work/" | grep -q '^settings.json.bak\.'

    # Running it again just refreshes the links.
    run ce sync -y
    [ "$status" -eq 0 ]
}

@test "sync from one account into a chosen account" {
    ce add work -y
    ce add personal -y
    echo '{}' > "$HOME/.claude-work/settings.json"
    run ce sync work personal -y
    [ "$status" -eq 0 ]
    [ "$(readlink "$HOME/.claude-personal/settings.json")" = "$HOME/.claude-work/settings.json" ]
}

# --- clone ---

@test "clone copies settings but not credentials, and adds an alias" {
    ce add work -y
    echo '{"x":1}' > "$HOME/.claude-work/settings.json"
    mkdir -p "$HOME/.claude-work/agents"
    echo "agent" > "$HOME/.claude-work/agents/a.md"
    echo "secret" > "$HOME/.claude-work/.credentials.json"

    run ce clone work client -y
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude-client/settings.json" ]
    [ ! -L "$HOME/.claude-client/settings.json" ]
    [ -f "$HOME/.claude-client/agents/a.md" ]
    [ ! -e "$HOME/.claude-client/.credentials.json" ]
    grep -q "^alias claude-client=" "$RC"
}

@test "clone refuses an existing target" {
    ce add work -y
    ce add client -y
    run ce clone work client -y
    [ "$status" -eq 1 ]
}

# --- export / import ---

@test "export leaves out credentials and import restores into a new account" {
    ce add work -y
    echo '{"x":1}' > "$HOME/.claude-work/settings.json"
    echo "secret" > "$HOME/.claude-work/.credentials.json"
    mkdir -p "$HOME/.claude-work/cache"
    echo "junk" > "$HOME/.claude-work/cache/c"

    archive="$BATS_TEST_TMPDIR/backup.tar.gz"
    run ce export work "$archive"
    [ "$status" -eq 0 ]
    [ -z "$(tar -tzf "$archive" | grep credentials)" ]
    [ -z "$(tar -tzf "$archive" | grep cache)" ]

    run ce import "$archive" restored -y
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.claude-restored/settings.json")" = '{"x":1}' ]
    grep -q "^alias claude-restored=" "$RC"
}

@test "export stores the content of synced links, not the links" {
    mkdir -p "$HOME/.claude"
    echo '{"shared":true}' > "$HOME/.claude/settings.json"
    ce add work -y
    ce sync -y
    archive="$BATS_TEST_TMPDIR/backup.tar.gz"
    ce export work "$archive"
    ce import "$archive" copy -y
    [ ! -L "$HOME/.claude-copy/settings.json" ]
    [ "$(cat "$HOME/.claude-copy/settings.json")" = '{"shared":true}' ]
}

@test "import refuses archives that contain links" {
    mkdir -p "$BATS_TEST_TMPDIR/evil"
    ln -s /etc/hosts "$BATS_TEST_TMPDIR/evil/settings.json"
    tar -czf "$BATS_TEST_TMPDIR/evil.tar.gz" -C "$BATS_TEST_TMPDIR/evil" .
    run ce import "$BATS_TEST_TMPDIR/evil.tar.gz" bad -y
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.claude-bad" ]
}

@test "import refuses archives with ../ paths" {
    command -v python3 >/dev/null || skip "python3 not available"
    python3 - "$BATS_TEST_TMPDIR/evil.tar.gz" <<'EOF'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    data = b"x"
    info = tarfile.TarInfo("../escape.txt")
    info.size = len(data)
    t.addfile(info, io.BytesIO(data))
EOF
    run ce import "$BATS_TEST_TMPDIR/evil.tar.gz" bad -y
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/escape.txt" ]
}

# --- version / update ---

@test "version and --version print the version" {
    run ce version
    [[ "$output" =~ ^claude-ce\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
    run ce --version
    [[ "$output" =~ ^claude-ce\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "update replaces the script with a newer download" {
    copy="$BATS_TEST_TMPDIR/claude-ce"
    cp "$SCRIPT" "$copy"
    sed 's/^VERSION=.*/VERSION="9.9.9"/' "$SCRIPT" > "$BATS_TEST_TMPDIR/newer.sh"

    CLAUDE_CE_UPDATE_URL="file://$BATS_TEST_TMPDIR/newer.sh" run bash "$copy" update -y
    [ "$status" -eq 0 ]
    run bash "$copy" --version
    [ "$output" = "claude-ce 9.9.9" ]
}

@test "update says up to date when versions match" {
    copy="$BATS_TEST_TMPDIR/claude-ce"
    cp "$SCRIPT" "$copy"
    CLAUDE_CE_UPDATE_URL="file://$SCRIPT" run bash "$copy" update
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date"* ]]
}

@test "update refuses to overwrite a Homebrew-managed install" {
    cellar="$BATS_TEST_TMPDIR/Cellar/claude-ce/1.0.0/bin"
    mkdir -p "$cellar"
    cp "$SCRIPT" "$cellar/claude-ce"

    CLAUDE_CE_UPDATE_URL="file://$SCRIPT" run bash "$cellar/claude-ce" update -y
    [ "$status" -eq 2 ]
    [[ "$output" == *"brew upgrade claude-ce"* ]]

    # brew links its bin entry as a symlink into the Cellar, so the check has
    # to survive symlink resolution too.
    ln -s "$cellar/claude-ce" "$BATS_TEST_TMPDIR/linked-claude-ce"
    CLAUDE_CE_UPDATE_URL="file://$SCRIPT" run bash "$BATS_TEST_TMPDIR/linked-claude-ce" update -y
    [ "$status" -eq 2 ]
    [[ "$output" == *"brew upgrade claude-ce"* ]]
}

@test "update rejects a download that is not a script" {
    copy="$BATS_TEST_TMPDIR/claude-ce"
    cp "$SCRIPT" "$copy"
    echo "<html>not found</html>" > "$BATS_TEST_TMPDIR/bad.sh"
    CLAUDE_CE_UPDATE_URL="file://$BATS_TEST_TMPDIR/bad.sh" run bash "$copy" update -y
    [ "$status" -eq 2 ]
    cmp -s "$SCRIPT" "$copy"
}
