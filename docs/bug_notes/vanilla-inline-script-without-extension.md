# Vanilla: an inline script without its .txt, so the wilderness swap loses its tooltip

`common/inline_scripts/traditions/tr_purity_imperfection_remediation_wilderness` has no `.txt`
extension. The game looks inline scripts up as `<script>.txt`, so it doesn't find this one. It
says nothing about it: a vanilla load's `error.log` (558 bytes) has no line about inline scripts.
`tr_stage_3_tradition_swaps` uses it, and three traditions (cloning, mutation, purity) include that.

It's used by the Wilderness swap of the Purity tradition "Imperfection Remediation"
(`common/inline_scripts/traditions/tr_stage_3_tradition_swaps.txt`, `tradition_swap` named
`tr_purity_imperfection_remediation_wilderness`).

Affected: 4.5.2 vanilla.

Severity: low, cosmetic. The file holds only
`custom_tooltip_with_modifiers = tr_purity_imperfection_remediation_wilderness_tt`, so Wilderness
empires miss that tooltip line. The swap doesn't set `inherit_effects = no`, so it keeps the base
tradition's modifier either way.


# Notes

Found on 2026-10-12, by the engine session's check of the game's compiled script against
`stellar.script.source`, which reports "no such file" for each include. Its siblings,
`tr_purity_imperfection_remediation.txt` and `tr_purity_imperfection_remediation_xenophile.txt`,
have the extension.

The fix: rename the file to `tr_purity_imperfection_remediation_wilderness.txt`.
