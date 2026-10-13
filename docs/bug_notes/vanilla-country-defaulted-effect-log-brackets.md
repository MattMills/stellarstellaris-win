# Vanilla: country_defaulted_effect loses its player log to brackets in a string

`country_defaulted_effect` (`common/scripted_effects/00_scripted_effects.txt:6239`) logs who
defaulted:

```
		if = {
			limit = { is_ai = yes }
			log = "AI [This.GetName] defaulted as a result of [Root.GetName] in [GetYear]"
		}
		else = {
			log = "Player [This.GetName] defaulted as a result of [Root.GetName] in [GetYear]"
		}
```

A scripted effect's text is a template, and any `[` in it, inside quotes too, starts a parameter
block. The block's name starts two characters in, and the block runs to its matching `]`. These
brackets aren't escaped (`\[`), so the game cuts the text into three blocks:
- `[This.GetName] defaulted ... [Root.GetName]`, named "his.GetName";
- `[GetYear]"` through the second string's `[This.GetName]`, which takes the end of the `if`
  and the `else = {` line between them (the `else`'s own `}` then closes the `if`);
- `[Root.GetName] in [GetYear]` of the second string.

The call passes no arguments of those names, so all three are dropped. What the game reads is:

```
		if = {
			limit = { is_ai = yes }
			log = "AI  in  defaulted as a result of "
		}
```

Affected: 4.5.2 vanilla.

Severity: low. Only logging is lost: the player's default isn't logged, and the AI's log line is
garbled. The effect's real work (the modifiers, downgrading buildings, losing ships) is outside
these lines and runs.


# Notes

The template rules (`ProcessSourceForMacros`) are in [script_engine.md](../script_engine.md),
"Parameter blocks", where this case is the example. `stellar.script.source.instantiate` gives the
text above. The engine session checked that reading against every compiled effect of the game.

The fix: escape the brackets (`\[This.GetName\]`), as vanilla does in its other strings.
