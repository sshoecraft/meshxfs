---
name: trap-verify-argument-claiming-a-branch-whose-input-was-empty-on-the-rig
description: A release-reviewer rejects a verify argument that claims coverage of a branch the rig fed an empty input (empty matches empty), or overstates the con…
metadata:
  type: feedback
---

**Trap.** When a lap compares values between nodes (module parameters, keys, contract strings), a branch whose input is empty on this rig compares empty with empty and passes however the code behaves. Claiming it as covered in a verify proposal gets the proposal rejected even when the batch itself is sound. Observed on P20261024-52e185 (rejoin module arguments): the argument named target_retire_contract as "the contract argument whose quoting the rejection named", but prep on the rig reports `PREP retire-contract: NONE`, so neither node loaded one.

The same review also rejected two overstatements about the control: (1) "with no extra arguments nothing is measured", when the control also failed on a non-extra argument (log_repeat_limit); (2) implying the control produced the defect's user-visible effect (mixed death windows), when the candidate's default window equalled the variant's (12 s) so the effective windows matched.

**What to do before filing a verify.** For each compared field, read one control lap's and one fix-on lap's captured values and list as untested every field that was empty or equal by default on both sides. State what the control's failures actually were (every differing field, from its own lines), and say plainly whether the control showed the downstream effect or only the root difference. No new runs were needed to fix the argument; the resubmission was P20261024-d7c365.
