# Contributing

tellem is developed in a private repository. This public repository receives one
commit per release, so its history is a list of releases rather than a list of
changes.

## Issues

Bug reports and feature requests are welcome as GitHub issues. A useful report
names the tellem version (`tellem version`), the harness and its version, the
operating system and Ruby version, the command you ran, and what `tellem doctor`
printed. Redact paths, prompts, and anything else private before you paste it.

## Pull requests

Pull requests are welcome as proposals. A pull request is never merged through
GitHub: the maintainer reads it, re-applies the change in the development
repository, and it reaches this repository with the next release, credited in
`CHANGELOG.md`. The pull request is then closed with a pointer to that release.

Before you open one:

- Keep it to one change, and say what it fixes or adds and how you ran it.
- Match the surrounding file's conventions. The code carries no comments.
- Run `rplugin check tellem` and `tellem doctor` against scratch homes, and say
  what they printed.
- A change in behavior starts in `specs/tellem.app.yml`; say which decision or
  requirement it touches.

By opening a pull request you agree that your contribution is licensed under the
MIT License in `LICENSE`.

## Security

Report vulnerabilities privately as `SECURITY.md` describes, never in a public
issue.
