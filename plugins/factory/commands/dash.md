---
description: Open the factory dashboard - what the team is doing right now, what it is stuck on, and what it needs from me
argument-hint: [optional: "publish" to get a link I can open on my phone]
disable-model-invocation: true
allowed-tools: Read, Bash(factory-dash), Bash(open *), Bash(ls *), Bash(cat *), Artifact
---

Show me the factory dashboard for this project. Argument: $ARGUMENTS

1. If `.factory/active` is missing, say the factory is not open here and stop.
2. Rebuild it and open it:

   ```bash
   factory-dash && open .factory/dashboard.html
   ```

   The page refreshes itself every five seconds and the hooks rebuild it after
   every dispatch, gate run, move and commit, so once it is open I can leave it
   open for the whole run. It costs nothing: it is generated from the board, the
   event log and git, with no model involved.
3. Then tell me in three lines what it currently says: what is running, what is
   stuck, and whether anything is waiting for me. Read `.factory/statusline.txt`
   for the numbers rather than re-deriving them.
4. Only if I asked for `publish`: publish `.factory/dashboard.html` as an
   artifact and give me the link, so I can watch from my phone. Say plainly that
   it is a snapshot - it does not update itself once published, and re-publishing
   is another run of this command. Never publish it unasked: the page carries
   task titles and file paths from a private repository.
