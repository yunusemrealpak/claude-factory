---
description: Show the autonomy level of this project, or switch it back to local - raising it is done only by typing "auto devam et"
argument-hint: "[status | off]"
disable-model-invocation: true
allowed-tools: Bash(factory-autonomy), Bash(factory-autonomy status), Bash(factory-autonomy off)
---

Autonomy level of this project. Read the argument `$ARGUMENTS`:

- empty or `status` - run `factory-autonomy status` and report its line as it
  is: the level (`local`, `pr` or `merge`) and why it is that one.
- `off` - run `factory-autonomy off` and say the level is `local` now.

Nothing else. You cannot raise the level: it goes up only when I type the whole
prompt `auto devam et` myself, and a hook records that. Never write
`.factory/autonomy.json`, never remove `.factory/autonomy-off`, and if I ask you
to raise the level here, tell me to type the phrase.
