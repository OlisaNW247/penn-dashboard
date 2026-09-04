# i-have-adhd

Project-level copy of the `i-have-adhd` Claude Code skill.

- Upstream: https://github.com/ayghri/i-have-adhd (MIT, see `LICENSE`)
- Vendored from commit `58494af`

## Use

Type `/i-have-adhd` in a Claude Code session opened in this repo. The rules stay on
for the session. Say "stop adhd mode" or "normal mode" to turn them off.

The skill sets `disable-model-invocation: true`, so nothing changes until you invoke it.

## Update

```sh
curl -fsSL https://raw.githubusercontent.com/ayghri/i-have-adhd/main/skills/i-have-adhd/SKILL.md \
  -o .claude/skills/i-have-adhd/SKILL.md
```
