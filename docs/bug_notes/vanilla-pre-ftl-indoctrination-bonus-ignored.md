# Vanilla: the pre-FTL indoctrination operation ignores its bonus

The pre-FTL indoctrination espionage operation ("Compelling the Crowds", First Contact) is meant
to shift more pre-FTL pops to the chosen ethic on its good result and fewer on its poor one. It
shifts the same number whatever the result, because the script value that counts them misspells its
parameter.

Affected: 4.5.2 vanilla (checked in its files). Earlier versions weren't checked.

Severity: medium, a gameplay bug. The operation's outcomes don't matter for the number of pops
shifted.


# Notes

`events/first_contact_dlc_operations_events.txt` calls the effect with a bonus per outcome:

```
pre_ftl_indoctrinate_operation_result = { BONUS = 0 }    # line 330, preftl_operation.1016 (normal)
pre_ftl_indoctrinate_operation_result = { BONUS = 3 }    # line 370, preftl_operation.1017 (good)
pre_ftl_indoctrinate_operation_result = { BONUS = -4 }   # line 421, preftl_operation.1018 (poor)
```

The effect (`common/scripted_effects/first_contact_dlc_effects.txt:2478`) loops
`count = value:pre_ftl_pops_shifting_ethic|BONUS|$BONUS$|`. The script value
(`common/script_values/00_script_values.txt:1766`) ends with:

```
	[[BONUS]
		add = $bonus$
	]
```

- Parameter names are case-sensitive, so `$bonus$` isn't `BONUS`.
- An argument the call doesn't give, with no default, becomes the empty string (`GetArgumentValue`
  returns `CString::_NullString`; [script_engine.md](../script_engine.md)).
- So the game reads `add =` with no value (the next token is the `}` that closes the script value),
  and the bonus is never added.

The script value just above it, `pre_ftl_gain_tech_progress`, writes `$BONUS$` and works.

Found by the engine session's comparison of every compiled trigger and effect against the game's
own (48 roots, all from this one value). `stellar.script.source` leaves `$bonus$` in the text where
the game puts nothing.

The fix: write `$BONUS$`.
