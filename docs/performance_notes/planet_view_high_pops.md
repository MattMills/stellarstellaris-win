# Planet view


## Description

On planets with a large quantity of pops the planet view begins to cause significant lag when visible. This is due to economic category calculations that occur on every frame.

The majoriy of the fps lag for just having the planet view open comes from the CPlanetView::UpdatePopulationTab. The UpdateSummaryTab is a lessor issue. All tab Views are updated every frame, regardless of what tab you're looking at. 

The UpdatePopulationTab can just be limited in execution frequency to decrease the impact, it only causes the default icons to be slow to initially update (can probably be fixed with an OnClick somewhere)

The Summary tab seems to reset all the planetary building icons to default state every frame, so delaying it causes them to be really messy.

Additionally the tooltip primarily for the planet production tooltip can cause immense lag, as it triggers a substantial amount of economic category recalculation on every frame.

## Scales by
number of pops on planet * number of jobs (I think), modifiers have some additional quantity.

## Current fixes applied

CPlanetView::UpdatePopulationTab is limited to 1 every 3 seconds.
The ::GetTooltip() call has a cache applied to it which limits updates to once every 3 seconds. The "instant" tooltips use a std::string coontaining the content of the tooltip so it's easily cached