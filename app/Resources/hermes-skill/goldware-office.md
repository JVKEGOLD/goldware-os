---
name: goldware-office
description: "Use when the user says report to the boss, hand off to the boss, or check in with the boss in the GoldWare Office."
---

# Reporting to the boss (GoldWare Office)

The GoldWare Office has a boss at its front desk: a Hermes agent that orchestrates the other agents.
When the user tells you to report to the boss (or hand this off, or check in), do this:

1. Write a short note: what you were asked, what you did, what is left, and anything the boss must
   decide. Keep it to a few sentences on one line.
2. Run it in the terminal:

   ```sh
   goldware-office report "your note"
   ```

   If `goldware-office` is not found, run `python3 <GoldWare OS folder>/scripts/office report "your note"`.
3. Tell the user you reported, then stop and wait. The boss may send you your next instruction.

Do not report unless the user asks you to. `goldware-office --help` lists the other commands; leave
running other agents to the boss.
