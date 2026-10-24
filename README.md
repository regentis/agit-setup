# agit-setup

[agit](https://github.com/mronus/agit) is a distribution of Git with
the provenance extension, which records, for each commit, the AI
reasoning behind it and, for each changed line, whether an AI agent, a
human, or both wrote it. The executable is still `git`, and the
repositories it works on stay plain Git repositories.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mronus/agit-setup/main/install.sh | sh
```

The script downloads the prebuilt release for your platform from
[mronus/agit releases](https://github.com/mronus/agit/releases),
checks it against the release's `SHA256SUMS`, and makes it the default
`git` for your user. It needs no root, builds nothing, and leaves
Homebrew and the system's Git alone. It also installs this repository,
whose `agit-setup` connects your coding agents to agit (see below),
and, on a terminal, offers to run it.

Requirements: `tar`, `gzip`, and `curl` or `wget`; `jq` for the
agent integration.

Supported platforms: macOS 12 or later (Apple silicon and Intel), and
Linux on x86_64 and aarch64 with glibc 2.31 or later, libcurl and zlib
(Debian 11, Ubuntu 20.04, RHEL 9, Fedora and newer). Alpine and other
musl-based systems are not supported.

What it changes:

```
~/.agit/versions/<version>/   the release (bin/, libexec/git-core/, share/)
~/.agit/current               symbolic link to versions/<version>
~/.agit/setup/                this repository (agit-setup, the agent hooks)
~/.agit/env                   puts ~/.agit/versions/<version>/bin first on PATH,
                              and ~/.agit/setup/bin after it
```

and it adds one line, `. "$HOME/.agit/env" # added by agit install.sh`
(with your home directory spelled out), to the startup files of your
shells: `~/.zshrc` and `~/.zprofile` for zsh, `~/.bashrc` and
`~/.bash_profile` (or `~/.profile`) for bash, `~/.profile` otherwise.
For fish it writes `~/.config/fish/conf.d/agit.fish`. Open a new shell,
or run `. ~/.agit/env`, to start using it.

Options, after `sh -s --` when piping:

```
--version <version>   install that release (default: the latest)
--prefix <dir>        install there instead of ~/.agit
--no-modify-path      leave the shell startup files alone
--no-agents           do not offer to connect coding agents
--uninstall           disconnect the agents, remove ~/.agit and the
                      lines added above
-y, --yes             do not prompt; agents are not connected
-q, --quiet           print only warnings and errors
```

For example:

```sh
curl -fsSL https://raw.githubusercontent.com/mronus/agit-setup/main/install.sh | sh -s -- --version 2.56.0.agit.2
```

Running it again installs the requested version next to the others
and points `current` at it; older versions are kept until you remove
them. `AGIT_VERSION` and `AGIT_HOME` can stand in for `--version` and
`--prefix`.

Editors: VS Code and Cursor take `PATH` from your login shell, so they
find agit after a restart. JetBrains IDEs need the path to Git set to
`~/.agit/current/bin/git`.

## Connect your agents

agit tells the lines an AI agent wrote from those a human wrote by
having the agent's hooks call `git stamp` around each edit; lines
changed outside them are recorded as human. `agit-setup` installs
those hooks:

```sh
agit-setup                          # choose agents and options on the terminal
agit-setup add <agent>              # or without questions
agit-setup status [<agent>]         # what is installed, and the last hook errors
agit-setup remove <agent>
```

The agents are `claude-code` (Claude Code), `codex` (Codex CLI),
`cursor` (Cursor 3: the agent of the editor, and the `cursor agent`
command) and `gemini` (Gemini CLI). The menu offers those it finds.
Each is connected for all your projects (`--scope user`, the default)
or, where the agent has project settings, for the one in the current
directory (`--scope project`, for everyone working on it with the
agent; `--scope local`, for you only):

```
agent         how                                       scopes
claude-code   the agit plugin of this repository,       user, project, local
              with claude plugin install
codex         hooks added to ~/.codex/hooks.json        user
              ($CODEX_HOME)
cursor        hooks added to ~/.cursor/hooks.json,      user, project
              or .cursor/hooks.json in the project
gemini        the extension in extensions/gemini,       user, project
              with gemini extensions link; or hooks
              added to .gemini/settings.json in the
              project
```

`agit-setup` adds its hooks to a hooks file after yours, keeps a copy
of the file as `<file>.agit-backup` before its first change, and
`remove` takes out exactly its own hooks; it leaves a file that is not
plain JSON alone. A project's hooks name `agit-hook` from `$HOME`
(`$HOME/.agit/setup/bin/agit-hook`), so they work for everyone who
installed agit the same way; others see the hook fail, and their agent
goes on.

The hooks run `bin/agit-hook`, which:

```
before and after each file edit    git stamp begin / end -- <file>
before and after each shell        git stamp begin / end on the whole tree,
command                            so files written by commands count as
                                   the agent's
at the start of a session          tell the agent to record why it made
                                   its changes, with git stamp reason,
                                   before each commit
```

The reasoning of a commit is what the agent records; the hooks do not
write one for it. When a commit has lines an AI wrote and no
reasoning, `git commit` warns and says how to add it.

What each agent records:

```
                   edits      shell      model   session
                              commands           context
Claude Code        yes        yes        yes     yes
Codex CLI          yes        yes        yes     yes
Cursor             yes        yes        yes     yes
Gemini CLI         yes        yes        no      yes
```

- Cursor needs version 3. The hooks stamp around its agent's `Write`,
  `Delete` and `Shell` tools; the lines of Tab completions and of
  inline edits (Cmd+K) count as human. Cursor also runs the hooks of
  Claude Code plugins; those of the agit plugin then do nothing, so
  Cursor's work is recorded once, by the Cursor hooks.
- Gemini CLI does not tell the hooks its model.
- Codex runs a hook only once you have trusted it: after
  `agit-setup add codex`, start `codex`, run `/hooks`, and trust the
  agit hooks. Codex asks again only if they change; upgrades of
  agit-setup keep them as they are.

One option, asked by `agit-setup` and kept in `~/.agit/setup.conf`:

```
--no-shell        do not stamp around shell commands (default: stamp)
```

The hooks never block the agent, nor its commits: they do nothing
outside a Git worktree, where `provenance.enabled` is false, or when
they find no agit, and they log their errors to `~/.agit/log/hook.log`. They run
the agit installed in `~/.agit` even when the agent was started from a
shell that does not have it on `PATH`. The commits that an agent makes
must be made by agit too: Claude Code's hooks put agit first on the
`PATH` of its shell commands; Codex, Cursor and Gemini CLI use the
`PATH` they were started with, which a new shell, or VS Code and
Cursor restarted, takes from `~/.agit/env`. `agit-setup status` warns
when the `git` on `PATH` is not agit.

Without the installer, with agit and `jq` already on your `PATH`, add
the plugin from Claude Code itself:

```
/plugin marketplace add mronus/agit-setup
/plugin install agit@agit-setup
```

or from the shell with `claude plugin marketplace add mronus/agit-setup`
and `claude plugin install agit@agit-setup`. The option then keeps
its default.

## License

GPL version 2; see COPYING.
