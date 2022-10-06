[![Build stellarstellaris Windows](https://github.com/MattMills/stellarstellaris-win/actions/workflows/cmake.yml/badge.svg?branch=master)](https://github.com/MattMills/stellarstellaris-win/actions/workflows/cmake.yml)


# StellarStellars - Windows (+Linux?) edition

The goal of this project is to start building an enhanced version of StellarStellaris that can hook into Stellaris on multiple platforms, with the initial focus being Steam Windows, since that is the most heavily used version.

This is in a very early alpha stage, it currently doesn't do much of anything.

# NEED BETA TESTERS, JOIN DISCORD!

## Current State

Currently works on WINDOWS, Steam or GOG. I will eventually add Linux support, I don't have any macs.

Game bugs patched:
 * Hull/Shield/Armor Regen overflow - Replaced fixed point calculations with double based calculations to eliminate ship regen overflow
 * Disapearing army outliner group - Fixed Armies dissapearing from outliner menu
 
Performance issues patched:
* Planet view with high pop count performance improvement - Causes the icons on the population tab to be a bit slow to initially update from their default state.
* Planet view tooltips - Caching the tooltip data dramatically improves framerate for high population worlds.
* Fleet Manager View - Limits the UI update rate to once every 3 seconds, which makes some pieces of the UI slow to respond, but with a lot of fleets dramatically improves frame rate (1 FPS -> 40 FPS); should be a fixable issue.
* Fleet View - Caches Fleet reinforcement calculations for selected fleets to reduce lag
* Multiple places / Ship Design - Reduced frequency of Applying modifiers to ship design values (once every 3 seconds max)
* Species-is-modifiable alert - Causes large lag spikes in late game with a lot of species/planets

Debug logging added:
 * CEvent::ExecuteActual
 * CEffect::ExecuteActual
 * CRandomInListEffect::ExecuteActual
 * CEveryInListEffect::ExecuteActual
 * COnActionDatabase::PerformEvent
 * Implemented but disabled (way too noisy) - CTrigger::ExecuteActual

 in order to dump debug data to a new log file (stellarstellaris-debug.log in the normal directory [example file as of 9/14/2022 here](docs/example-stellarstellaris-debug.log.txt)).

## Install/Using:

 Compiled windows executables are available in Github workflows/actions as build artifacts, download the zip file, extract it somewhere, start Stellaris and run stellar-loader.exe 

 This will load the DLL into the currently running game, it must be run every time the game is restarted to use it.

 NOTE: There is not currently any protection against loading the patch into game memory more than once at a time; this may cause weirdness.

## Compatibility:

Currently, there are no compatibility issues, the loader can be run at any time during a game, and can be removed by restarting the game without any issue (although obviously any patched bugs will return).

## Support discord:

https://discord.gg/Mtm5nURDSC

[![Join Support discord link](https://discordapp.com/api/guilds/960348408990793838/widget.png?style=banner3)](https://discord.gg/Mtm5nURDSC)

## How to sponsor / support:
https://github.com/sponsors/MattMills

https://www.patreon.com/RadioCapture


### References / Thanks / Borrowed code:
https://github.com/khalladay/hooking-by-example
