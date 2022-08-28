# Colonizable planet habitability

## Description

During late game, the red/yellow/green colonizable planet habitability icons can cause severe increases in every-frame lag,
when on the global map, at the right zoom level (where they are visible).

## Scales by
Number of species * number of colonizable planets visible
Exacerbated by xeno-compatibility

## Stack
CInGameIdler::UpdateInternal	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\ingameidler.cpp	3270	0x7ff77f48abb5
CMapIconManager::PostCameraUpdate	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\map_graphics\mapicons.cpp	211	0x7ff77fd59f81
CMapIconManager::UpdateGalacticObjectIcons	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\map_graphics\mapicons.cpp	692	0x7ff77fd5bcc4
UpdateIcons<CGalacticObjectMapIcon>	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\map_graphics\mapicons.cpp	476	0x7ff77fd5d263
PdxParallelFor<<lambda_af065631c53f790a5daaff69ef103ed5> >	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_core\thread\pdx_parallel_for.h	136	0x7ff77fd5e2d2
CJob::TrySteal	stellaris	D:\jenkins\workspace\augustus\augustus\clausewitz\pdx_core\thread\pdx_task.cpp	544	0x7ff78012f0d2
boost::detail::function::void_function_ref_invoker0<NParallelForImpl::SPdxParallelFor<<lambda_69ee3a9bcb063d4946672ab4d1847159> >,void>::invoke	stellaris	D:\jenkins\workspace\external_libs3\common\boost\boost_1_69_0\boost\function\function_template.hpp	193	0x7ff77fd5f4c7
CGalacticObjectMapIcon::UpdateThreaded	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\map_graphics\galactic_object_map_icon.cpp	2413	0x7ff77fd6d1f6
NGalacticObjectMapIcon::CColonizablePlanetsIcon::UpdateThreaded	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\map_graphics\galactic_object_map_icon_colonizable_planets.cpp	64	0x7ff77fd8b8a5
CPlanet::CalcColonizableIconFrame	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\planet.cpp	6814	0x7ff77f70266e
CPlanet::CanColonizeAndInhabit	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\spatial_objects\planet.cpp	6745	0x7ff77f702263
CCountry::ListSpecies	stellaris	D:\jenkins\workspace\augustus\augustus\augustus\source\country.cpp	5927	0x7ff77f10fbfd

## Unknown?

This appears to be threaded, but 