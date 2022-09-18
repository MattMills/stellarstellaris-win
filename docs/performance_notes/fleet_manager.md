# Fleet Manager

## Description

With a high number of fleets / fleet power, ESPECIALLY, if the fleets are un-built (IE, pending reinforcement), the fleet manager UI becomes unusably laggy (< 1 FPS)

CFleetManagerView::Update() calls CFleetManagerView::UpdateReinforceAll() and `anonymous namespace'::CalcNavalCapacityValues(), each of which has a significant impact on performance; largely due to both independently calling CCountryFleetsManager::CalcTotalShipsOfSize()


## Scales by
Number of unbuilt ships * number of resources types needed to build ship (I think) * number of designs (I think)

