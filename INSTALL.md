# Installing tellem (for AI agents)

You are an AI coding agent, and the person you work for asked you to install
tellem from `https://github.com/SteveBenner/tellem`. Follow these steps in
order. Run each command yourself, read its output, and stop at the first step
that fails: tell the person what failed and show them the output. Do not work
around a failure, and do not overwrite anything that already exists.

tellem records what coding agents do: which agents and subagents ran, where
they worked, what the provider reported they spent, and what they said. It
installs as a plugin through rplugin, the SDK for agent-harness plugins, into
Claude Code and Codex.

## 1. Check the prerequisites

```sh
ruby -e 'puts RUBY_VERSION'
git --version
```

tellem needs Ruby 3.3 or newer and git. If Ruby is missing or older than 3.3,
stop and tell the person. Do not install or upgrade Ruby yourself.

## 2. Get rplugin

tellem needs rplugin 1.19.0 or newer in `~/.rplugin`.

If `~/.rplugin` does not exist, clone it with its extensions:

```sh
git clone --recurse-submodules https://github.com/SteveBenner/rplugin ~/.rplugin
```

If `~/.rplugin` already exists, do not clone over it and do not pull it. Check
its version instead:

```sh
~/.rplugin/bin/rplugin version
```

If that prints a version below 1.19.0, or fails, stop and tell the person that
their rplugin needs an update before tellem can install.

## 3. Get tellem

If `~/.rplugins/tellem` already exists, stop and tell the person: tellem is
already there, and `~/.rplugin/bin/rplugin doctor tellem` shows its state.
Otherwise:

```sh
mkdir -p ~/.rplugins
git clone https://github.com/SteveBenner/tellem ~/.rplugins/tellem
```

## 4. Install it

```sh
cd ~ && ~/.rplugin/bin/rplugin install tellem
```

This registers tellem with every agent app rplugin finds on the computer
(Claude Code and Codex), installs its agent skill and hooks, and links the
`tellem` command into `~/.local/bin`. Read the output: each line names what it
did.

## 5. Check it

```sh
~/.rplugin/bin/rplugin doctor tellem
~/.local/bin/tellem doctor
```

`rplugin doctor` should report 0 findings, and `tellem doctor` should exit 0.
A finding names its own next command. Show the person any finding you cannot
explain.

## 6. Tell the person what happens next

Tell them, in your own words:

- Recording starts with the **next** session of their agent app, not this one.
  They should start a new session (in Claude Code, exit and start `claude`
  again).
- tellem keeps its records in files on their computer: a `.tellem/` folder in
  each repository an agent works in, and its own state folder. Nothing leaves
  the computer.
- tellem runs beside anything that already records sessions, such as SpecStory
  or the agent app's own transcripts, and changes neither. Taking over from
  them is a separate step they choose later, from a plan they read first.
- To ask about their agents, they just ask you, for example "use tellem: what
  did my agents do today, and what did they spend?". You answer with the
  tellem skill.
- `TELLEM_DISABLED=1` or `tellem config set features.capture false` turns
  recording off.

If `~/.local/bin` is not on their `PATH`, tell them, and use
`~/.local/bin/tellem` when you run it.
