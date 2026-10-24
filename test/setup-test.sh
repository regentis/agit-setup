#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026 M. Abdullah Onus
#
# Test the commands of bin/agit-setup that do not ask questions, with
# fake agents on PATH that record their arguments, and the hooks files
# of the agents in a temporary HOME:
#
#   test/setup-test.sh
#
# Everything happens in a temporary directory; jq and git are required.

set -e

root=$(cd "$(dirname "$0")/.." && pwd -P)
setup=$root/bin/agit-setup
command -v jq >/dev/null || { echo >&2 "jq is required"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
export HOME="$tmp/home"
export AGIT_HOME="$tmp/agit-home"
export CODEX_HOME="$tmp/home/.codex"
mkdir -p "$HOME" "$tmp/bin" "$tmp/project"
conf=$AGIT_HOME/setup.conf
calls=$tmp/claude-calls
failures=0

fail () {
	echo "FAIL: $*"
	failures=$((failures + 1))
}

ok () {
	echo "ok: $*"
}

# Succeed if the files $1 and $2 have the same bytes (cmp is not on
# every system).
same () {
	test "$(cksum <"$1")" = "$(cksum <"$2")"
}

# A claude that records "<directory>: <arguments>" and keeps the
# installed scopes in a file, for plugin list --json.  It also records
# in $stdin when its stdin is a terminal or has anything to read: the
# real claude (Bun) fails on macOS with "EINVAL: invalid argument,
# kqueue" when its stdin is /dev/tty, as it is under curl | sh.
stdin=$tmp/claude-stdin
cat >"$tmp/bin/claude" <<EOF
#!/bin/sh
echo "\$(pwd -P): \$*" >>"$calls"
if test -t 0
then
	echo "terminal: \$*" >>"$stdin"
elif IFS= read -r line
then
	echo "input: \$*" >>"$stdin"
fi
state="$tmp/claude-installed"
case "\$*" in
--version) echo "9.9.9 (Claude Code)" ;;
"plugin install agit@agit-setup --scope "*) echo "\$4" >>"\$state" ;;
"plugin uninstall agit@agit-setup --scope "*) : >"\$state" ;;
"plugin list --json")
	if test -s "\$state"
	then
		echo '[{"id": "agit@agit-setup", "version": "0.1.0", "scope": "user", "enabled": true}]'
	else
		echo '[]'
	fi ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/claude"
# A git that passes for agit.
real_git=$(command -v git)
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
test "\$*" = "stamp -h" && { echo "usage: git stamp begin"; exit 129; }
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"
PATH=$tmp/bin:$PATH

# Run agit-setup, with input on its stdin that claude must not see;
# check its exit status against $1 (0 or 1).
run () {
	want=$1
	shift
	if echo "not for claude" | sh "$setup" "$@" >"$tmp/out" 2>&1
	then
		got=0
	else
		got=1
	fi
	cat "$tmp/out"
	test "$got" = "$want" || fail "agit-setup $* exited with $got"
}

# Check that the fake claude was called, in the directory $1, with the
# arguments $2.
called () {
	grep -qxF "$1: $2" "$calls" || fail "not called in $1 with: $2"
}

echo "== --help"
run 0 --help
grep -q "usage: agit-setup" "$tmp/out" || fail "no usage"

echo "== add claude-code"
cd "$tmp/project"
run 0 add claude-code --yes
called "$tmp/project" "plugin marketplace add $root"
called "$tmp/project" "plugin install agit@agit-setup --scope user -y"
test "$(git config --file "$conf" hook.shell)" = true || fail "hook.shell"
git config --file "$conf" hook.reason && fail "hook.reason written"
git config --file "$conf" hook.transcript && fail "hook.transcript written"
test "$(git config --file "$conf" --get-all agent.claude-code.install)" = user ||
fail "the user install was not recorded"
grep -q "done: Claude Code records" "$tmp/out" || fail "the self-check did not pass"
ok "add claude-code"

echo "== add claude-code again"
run 0 add claude-code --yes
test "$(git config --file "$conf" --get-all agent.claude-code.install)" = user ||
fail "the user install was recorded twice"
ok "add is idempotent"

echo "== add claude-code with options, project scope"
: >"$calls"
# hook.transcript and hook.reason, from earlier versions, are left
# alone.
git config --file "$conf" hook.transcript true
git config --file "$conf" hook.reason false
run 0 add claude-code --scope project --no-shell -y
called "$tmp/project" "plugin install agit@agit-setup --scope project -y"
test "$(git config --file "$conf" hook.shell)" = false || fail "hook.shell"
test "$(git config --file "$conf" hook.reason)" = false || fail "hook.reason"
test "$(git config --file "$conf" hook.transcript)" = true || fail "hook.transcript"
test "$(git config --file "$conf" --get-all agent.claude-code.install)" = "user
project:$tmp/project" || fail "installs: $(git config --file "$conf" --get-all agent.claude-code.install)"
ok "options and scope"

echo "== status"
mkdir -p "$AGIT_HOME/log"
{
	echo "2026-01-01T00:00:00Z claude pre-edit: /usr/bin/git is not agit; this session records nothing (install agit, or set AGIT_HOME or AGIT_GIT)"
	echo "2026-01-01T00:00:00Z claude pre-edit: an error"
} >"$AGIT_HOME/log/hook.log"
run 0 status
for want in "Claude Code:  $tmp/bin/claude (9.9.9 (Claude Code))" \
	"agit@agit-setup 0.1.0, user scope, enabled" \
	"installed by agit-setup: project:$tmp/project" \
	"edits made by shell commands: no" "an error" "agit-setup:   $root (plugin " \
	"hooks run:    $tmp/bin/git" \
	"warning: the hooks found no agit in some sessions"
do
	grep -qF "$want" "$tmp/out" || fail "status does not show: $want"
done
grep -q transcripts "$tmp/out" && fail "status shows transcripts"
grep -q "summary before commits" "$tmp/out" && fail "status shows summary before commits"
ok "status"

echo "== remove claude-code"
: >"$calls"
cd "$tmp"
run 0 remove claude-code
called "$tmp" "plugin uninstall agit@agit-setup --scope user -y"
called "$tmp/project" "plugin uninstall agit@agit-setup --scope project -y"
called "$tmp" "plugin marketplace remove agit-setup"
git config --file "$conf" --get-all agent.claude-code.install &&
fail "installs are still recorded"
ok "remove claude-code"

echo "== remove without a record"
: >"$calls"
run 0 remove claude-code
called "$tmp" "plugin uninstall agit@agit-setup --scope user -y"
called "$tmp" "plugin marketplace remove agit-setup"
ok "remove without a record"

echo "== claude does not read the stdin of agit-setup"
# install.sh runs agit-setup with its stdin from /dev/tty.
if (: </dev/tty) 2>/dev/null
then
	cd "$tmp/project"
	for args in "add claude-code --yes" status "remove claude-code"
	do
		# shellcheck disable=SC2086
		sh "$setup" $args </dev/tty >"$tmp/out" 2>&1 ||
		{ cat "$tmp/out"; fail "agit-setup $args failed"; }
	done
	cd "$tmp"
else
	echo "no terminal; only checked with input on a pipe"
fi
if test -s "$stdin"
then
	cat "$stdin"
	fail "claude ran with the stdin of agit-setup"
fi
ok "claude runs with its stdin from /dev/null"

# The hooks file of an agent, with the user's own hooks.
codex_file=$CODEX_HOME/hooks.json

echo "== add codex"
cat >"$tmp/bin/codex" <<EOF
#!/bin/sh
echo "codex: \$*" >>"$calls"
EOF
chmod +x "$tmp/bin/codex"
mkdir -p "$CODEX_HOME"
cat >"$codex_file" <<'EOF'
{
  "description": "my hooks",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "~/bin/check-command", "timeout": 5 }]
      }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "say done" }] }
    ]
  }
}
EOF
cp "$codex_file" "$tmp/codex-original.json"
run 0 add codex --yes
same "$codex_file.agit-backup" "$tmp/codex-original.json" || fail "codex: no backup"
jq -e '.description == "my hooks"
	and .hooks.Stop == [{hooks: [{type: "command", command: "say done"}]}]
	and .hooks.PreToolUse[0].hooks[0].command == "~/bin/check-command"
	and (.hooks.PreToolUse | length) == 3
	and (.hooks.SessionStart | length) == 1' "$codex_file" >/dev/null ||
fail "codex: unexpected hooks file: $(cat "$codex_file")"
want="sh \"$root/bin/agit-hook\" codex pre-edit"
jq -e --arg w "$want" '.hooks.PreToolUse[1] == {matcher: "apply_patch",
	hooks: [{type: "command", command: $w, timeout: 30}]}' "$codex_file" >/dev/null ||
fail "codex: no pre-edit hook: $(jq -c .hooks.PreToolUse "$codex_file")"
test "$(git config --file "$conf" --get-all agent.codex.install)" = "user:$codex_file" ||
fail "codex: the install was not recorded"
grep -q "run /hooks" "$tmp/out" || fail "codex: no word about trusting the hooks"
grep -q "codex:" "$calls" && fail "codex was run: $(cat "$calls")"
cp "$codex_file" "$tmp/codex-added.json"
run 0 add codex --yes
same "$codex_file" "$tmp/codex-added.json" || fail "codex: a second add changed the file"
grep -q "unchanged" "$tmp/out" || fail "codex: a second add did not say unchanged"
ok "add codex"

echo "== the hook commands run agit-hook"
# The command of the pre-edit hook, run by a shell as Codex does, with
# the input of Codex: it exits 0 and prints nothing.
cmd=$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$codex_file")
jq '.cwd = $c' --arg c "$tmp" "$root/test/fixtures/codex/pre-tool-use-apply-patch.json" |
sh -c "$cmd" >"$tmp/hook-out" 2>&1 || fail "codex: the hook command failed"
test -s "$tmp/hook-out" && fail "codex: the hook command printed: $(cat "$tmp/hook-out")"
ok "the hook commands run agit-hook"

echo "== status codex"
run 0 status codex
grep -qF "$codex_file: agit hooks for PostToolUse, PreToolUse, SessionEnd, SessionStart" "$tmp/out" ||
fail "status codex"
grep -q "Claude Code:" "$tmp/out" && fail "status codex shows Claude Code"
ok "status codex"

echo "== remove codex"
run 0 remove codex
test "$(jq -S . "$codex_file")" = "$(jq -S . "$tmp/codex-original.json")" ||
fail "codex: remove did not restore the file: $(cat "$codex_file")"
git config --file "$conf" --get-all agent.codex.install && fail "codex: still recorded"
run 0 remove codex
grep -q "unchanged" "$tmp/out" || fail "codex: a second remove changed the file"
ok "remove codex"

echo "== hooks file created, and agit-setup under HOME"
# agit-setup installed in ~/.agit/setup names agit-hook from $HOME.
mkdir -p "$HOME/.agit/setup"
cp -R "$root/bin" "$root/agents" "$HOME/.agit/setup/"
rm -rf "$CODEX_HOME"
setup=$HOME/.agit/setup/bin/agit-setup
run 0 add codex --yes
jq -e '.hooks.PreToolUse[0].hooks[0].command
	== "sh \"$HOME/.agit/setup/bin/agit-hook\" codex pre-edit"' "$codex_file" >/dev/null ||
fail "codex: hook path not from HOME: $(cat "$codex_file")"
test -e "$codex_file.agit-backup" && fail "codex: backup of a file that did not exist"
run 0 remove codex
setup=$root/bin/agit-setup
test "$(jq -c . "$codex_file")" = '{"hooks":{}}' || fail "codex: $(cat "$codex_file")"
rm -rf "$HOME/.agit"
ok "hooks file created"

echo "== a hooks file that is not JSON"
printf '{\n  // my hooks\n  "hooks": {}\n}\n' >"$codex_file"
cp "$codex_file" "$tmp/codex-comments.json"
run 1 add codex --yes
grep -q "is not JSON" "$tmp/out" || fail "codex: no error for a file that is not JSON"
same "$codex_file" "$tmp/codex-comments.json" || fail "codex: a file that is not JSON was changed"
echo '{"hooks": {"PreToolUse": {}}}' >"$codex_file"
run 1 add codex --yes
echo '{"hooks": {"PreToolUse": {}}}' >"$tmp/codex-other.json"
same "$codex_file" "$tmp/codex-other.json" || fail "codex: a file with hooks in another form was changed"
rm -rf "$CODEX_HOME"
ok "a hooks file that is not JSON"

echo "== add cursor, user and project scopes"
cat >"$tmp/bin/cursor" <<EOF
#!/bin/sh
echo "cursor: \$*" >>"$calls"
EOF
chmod +x "$tmp/bin/cursor"
cursor_file=$HOME/.cursor/hooks.json
mkdir -p "$HOME/.cursor"
# The user's hooks, and those that agit-setup added for Cursor 2.
cat >"$tmp/cursor-user.json" <<'EOF'
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [
      { "command": "./hooks/block-git.sh" }
    ],
    "preToolUse": [
      { "command": "./hooks/guard.sh", "matcher": "Shell" }
    ],
    "stop": [
      { "command": "./hooks/audit.sh" }
    ]
  }
}
EOF
jq --arg w "sh \"$root/bin/agit-hook\" cursor" '
	.hooks.afterFileEdit = [{command: ($w + " edit"), timeout: 30}]
	| .hooks.beforeShellExecution += [{command: ($w + " pre-shell"), timeout: 30}]
	| .hooks.afterShellExecution = [{command: ($w + " post-shell"), timeout: 30}]' \
	"$tmp/cursor-user.json" >"$cursor_file"
cp "$cursor_file" "$tmp/cursor-original.json"
cd "$tmp/project"
run 0 add cursor --yes
run 0 add cursor --scope project --yes
same "$cursor_file.agit-backup" "$tmp/cursor-original.json" || fail "cursor: no backup"
want="sh \"$root/bin/agit-hook\" cursor"
jq -e --arg w "$want" '
	def h($e; $m): {command: ($w + " " + $e), matcher: $m, timeout: 30};
	.version == 1
	and (.hooks | keys) == ["beforeShellExecution", "postToolUse", "postToolUseFailure",
		"preToolUse", "sessionEnd", "sessionStart", "stop"]
	and .hooks.stop == [{command: "./hooks/audit.sh"}]
	and .hooks.beforeShellExecution == [{command: "./hooks/block-git.sh"}]
	and .hooks.sessionStart == [{command: ($w + " session-start"), timeout: 10}]
	and .hooks.sessionEnd == [{command: ($w + " session-end"), timeout: 10}]
	and .hooks.preToolUse == [{command: "./hooks/guard.sh", matcher: "Shell"},
		h("pre-edit"; "^(Write|Delete)$"), h("pre-shell"; "^Shell$")]
	and .hooks.postToolUse == [h("post-edit"; "^(Write|Delete)$"), h("post-shell"; "^Shell$")]
	and .hooks.postToolUseFailure == .hooks.postToolUse' \
	"$cursor_file" >/dev/null || fail "cursor: unexpected hooks file: $(cat "$cursor_file")"
jq -e '.version == 1 and (.hooks | keys) ==
	["postToolUse", "postToolUseFailure", "preToolUse", "sessionEnd", "sessionStart"]' \
	"$tmp/project/.cursor/hooks.json" >/dev/null ||
fail "cursor: unexpected project hooks file: $(cat "$tmp/project/.cursor/hooks.json")"
test "$(git config --file "$conf" --get-all agent.cursor.install)" = "user:$cursor_file
project:$tmp/project/.cursor/hooks.json" || fail "cursor: installs not recorded"
grep -q "cursor:" "$calls" && fail "cursor was run: $(cat "$calls")"
# Cursor runs a hook command with its input in a here-document.
cmd=$(jq -r '.hooks.preToolUse[1].command' "$cursor_file")
input=$(jq -c '.workspace_roots = [$d] | .tool_input.file_path = $d + "/x.txt"' --arg d "$tmp" \
	"$root/test/fixtures/cursor/pre-tool-use-write.json")
sh -c "$cmd <<'CURSOR_HOOK_EOF'
$input
CURSOR_HOOK_EOF" >"$tmp/hook-out" 2>&1 || fail "cursor: the hook command failed"
test -s "$tmp/hook-out" && fail "cursor: the hook command printed: $(cat "$tmp/hook-out")"
cp "$cursor_file" "$tmp/cursor-added.json"
run 0 add cursor --yes
same "$cursor_file" "$tmp/cursor-added.json" || fail "cursor: a second add changed the file"
ok "add cursor"

echo "== status and remove cursor"
run 0 status cursor
grep -qF "$cursor_file: agit hooks for postToolUse, postToolUseFailure, preToolUse, sessionEnd, sessionStart" "$tmp/out" ||
fail "status cursor"
grep -qF "$tmp/project/.cursor/hooks.json: agit hooks for" "$tmp/out" || fail "status cursor, project"
cd "$tmp"
run 0 remove cursor
test "$(jq -S . "$cursor_file")" = "$(jq -S . "$tmp/cursor-user.json")" ||
fail "cursor: remove did not leave the user's hooks: $(cat "$cursor_file")"
test "$(jq -c . "$tmp/project/.cursor/hooks.json")" = '{"version":1,"hooks":{}}' ||
fail "cursor: project file after remove: $(cat "$tmp/project/.cursor/hooks.json")"
ok "remove cursor"

echo "== a Cursor hooks file with comments"
printf '{\n  // mine\n  "version": 1,\n  "hooks": {}\n}\n' >"$cursor_file"
run 1 add cursor --yes
grep -q "is not JSON" "$tmp/out" || fail "cursor: no error for comments"
git config --file "$conf" --get-all agent.cursor.install && fail "cursor: recorded after an error"
rm -rf "$HOME/.cursor" "$tmp/project/.cursor"
ok "a Cursor hooks file with comments"

echo "== add gemini"
# A gemini that records its arguments, links one extension, and prints
# the list of extensions on its standard error, as Gemini CLI does.
cat >"$tmp/bin/gemini" <<EOF
#!/bin/sh
echo "\$(pwd -P): \$* (trust=\$GEMINI_CLI_TRUST_WORKSPACE)" >>"$calls"
test -t 0 && echo "terminal: \$*" >>"$stdin"
state="$tmp/gemini-linked"
case "\$*" in
--version) echo "0.99.0" ;;
"extensions link "*" --consent")
	echo "\$3" >"\$state"
	echo 'Extension "agit" linked successfully and enabled.' ;;
"extensions uninstall agit")
	rm -f "\$state" ;;
"extensions list --output-format json")
	if test -s "\$state"
	then
		jq -n --arg s "\$(cat "\$state")" '[{name: "agit", version: "0.1.0",
			installMetadata: {source: \$s, type: "link"}}]' >&2
	else
		echo '[]' >&2
	fi ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/gemini"
cd "$tmp/project"
: >"$calls"
run 0 add gemini --yes
called "$tmp/project" "extensions link $root/extensions/gemini --consent (trust=true)"
grep -q "done: Gemini CLI records" "$tmp/out" || fail "gemini: the self-check did not pass"
test "$(git config --file "$conf" --get-all agent.gemini.install)" = user ||
fail "gemini: the install was not recorded"
: >"$calls"
run 0 add gemini --yes
grep -q "extensions link" "$calls" && fail "gemini: linked twice"
grep -q "linked already" "$tmp/out" || fail "gemini: no word about the link"
ok "add gemini"

echo "== add gemini, project scope"
mkdir -p "$tmp/project/.gemini"
gemini_file=$tmp/project/.gemini/settings.json
cat >"$gemini_file" <<'EOF'
{
  "ui": { "theme": "GitHub" },
  "hooks": {
    "BeforeTool": [
      { "matcher": "write_file", "hooks": [{ "name": "lint", "type": "command", "command": "./lint.sh" }] }
    ]
  }
}
EOF
cp "$gemini_file" "$tmp/gemini-original.json"
run 0 add gemini --scope project --yes
# The hooks of the extension, with the path of agit-hook.
jq --arg h "$root/bin/agit-hook" '.hooks | map_values(map(.hooks |= map(.command |=
	sub("\\$\\{extensionPath\\}/../../bin/agit-hook"; $h))))' \
	"$root/extensions/gemini/hooks/hooks.json" >"$tmp/gemini-want.json"
jq -e --slurpfile w "$tmp/gemini-want.json" '.ui == {theme: "GitHub"}
	and .hooks.BeforeTool[0].hooks[0].name == "lint"
	and .hooks.BeforeTool[1:] == $w[0].BeforeTool
	and .hooks.AfterTool == $w[0].AfterTool
	and .hooks.SessionStart == $w[0].SessionStart' "$gemini_file" >/dev/null ||
fail "gemini: unexpected project settings: $(cat "$gemini_file")"
run 0 status gemini
grep -qF "extension agit: link $root/extensions/gemini" "$tmp/out" || fail "status gemini, extension"
grep -qF "$gemini_file: agit hooks for AfterTool, BeforeTool, SessionEnd, SessionStart" "$tmp/out" ||
fail "status gemini, project"
ok "add gemini, project scope"

echo "== remove gemini"
: >"$calls"
cd "$tmp"
run 0 remove gemini
called "$tmp" "extensions uninstall agit (trust=true)"
test "$(jq -S . "$gemini_file")" = "$(jq -S . "$tmp/gemini-original.json")" ||
fail "gemini: remove did not restore the settings: $(cat "$gemini_file")"
git config --file "$conf" --get-all agent.gemini.install && fail "gemini: still recorded"
ok "remove gemini"

echo "== another extension named agit"
echo "/somewhere/else" >"$tmp/gemini-linked"
run 1 add gemini --yes
grep -q "another Gemini CLI extension named agit" "$tmp/out" || fail "gemini: no word about the other extension"
: >"$calls"
run 0 remove gemini
grep -q "uninstall" "$calls" && fail "gemini: uninstalled an extension it did not link"
rm -f "$tmp/gemini-linked"
ok "another extension named agit"

echo "== errors"
run 1 add
run 1 add claude-code --transcripts --yes
grep -q "unknown option: --transcripts" "$tmp/out" || fail "--transcripts accepted"
run 1 add claude-code --no-reason --yes
grep -q "unknown option: --no-reason" "$tmp/out" || fail "--no-reason accepted"
run 1 add claude-code --scope everywhere --yes
run 1 add codex --scope project --yes
grep -q "Codex supports --scope user" "$tmp/out" || fail "no message for codex --scope project"
run 1 add cursor --scope local --yes
grep -q "Cursor supports --scope user, project" "$tmp/out" || fail "no message for cursor --scope local"
run 1 add frobnicator --yes
run 1 frobnicate
mkdir -p "$tmp/no-claude"
for t in dirname grep mkdir sed tail cat jq
do
	ln -s "$(command -v "$t")" "$tmp/no-claude/$t"
done
ln -s "$tmp/bin/git" "$tmp/no-claude/git"
if PATH=$tmp/no-claude /bin/sh "$setup" add claude-code --yes >"$tmp/out" 2>&1
then
	fail "add succeeded without claude"
fi
cat "$tmp/out"
grep -q "claude is not on PATH" "$tmp/out" || fail "no message without claude"
if PATH=$tmp/no-claude /bin/sh "$setup" add gemini --yes >"$tmp/out" 2>&1
then
	fail "add succeeded without gemini"
fi
grep -q "gemini is not on PATH" "$tmp/out" || fail "no message without gemini"
rm "$tmp/no-claude/jq"
if PATH=$tmp/no-claude /bin/sh "$setup" add claude-code --yes >"$tmp/out" 2>&1
then
	fail "add succeeded without jq"
fi
cat "$tmp/out"
grep -q "the hooks need jq" "$tmp/out" || fail "no message without jq"
ok "errors"

if test -s "$stdin"
then
	cat "$stdin"
	fail "an agent ran with the stdin of agit-setup"
fi

if test $failures -gt 0
then
	echo "== $failures failures"
	exit 1
fi
echo "== all tests passed"
