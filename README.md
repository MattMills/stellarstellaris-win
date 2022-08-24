
# StellarStellars - Windows (+Linux?) edition

The goal of this project is to start building an enhanced version of StellarStellaris that can hook into Stellaris on multiple platforms, with the initial focus being Steam Windows, since that is the most heavily used version.

This is in a very early alpha stage, it currently doesn't do much of anything.

## Current State

Currently this hooks:
 * CEvent::ExecuteActual
 * CEffect::ExecuteActual
 * CRandomInListEffect::ExecuteActual

 in order to dump debug data to a new log file (stellarstellaris-debug.log in the normal directory [example file as of 8/24/2022 here](docs/example-stellarstellaris-debug.log.txt)).

 Compiled windows executables are available in Github workflows/actions as build artifacts, download the zip file, extract it somewhere, start Stellaris and run stellar-loader.exe

## Support discord:

https://discord.gg/Mtm5nURDSC

[![Join Support discord link](https://discordapp.com/api/guilds/960348408990793838/widget.png?style=banner3)](https://discord.gg/Mtm5nURDSC)

## How to sponsor / support:
https://github.com/sponsors/MattMills

https://www.patreon.com/RadioCapture


### References / Thanks / Borrowed code:
https://github.com/khalladay/hooking-by-example
