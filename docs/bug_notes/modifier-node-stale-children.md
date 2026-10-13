# Modifier nodes keep children that no longer read them

Every modifier node keeps the ids of the nodes that read it in `CPdxUnorderedSet<uint> _ChildNodes`
(`NModifierNode::CModifierNodeBase +0x128`). A child's id is added when the child reads the parent, and removed only
when that parent invalidates it. A child that stops reading the parent stays listed: for example, a
ship moved to another fleet is recomputed under its new fleet, and the old fleet still lists it.

The values are never wrong: a recompute reads only the node's current parents. The cost is extra
work. The next invalidation of the old parent also invalidates the former child, and everything
below it, and both are rebuilt for nothing. The entry is removed then.

Severity: low. This is a performance bug only, and a small one. No wrong values, no crash.


# Notes

The functions (4.5.2, from the PDB; the call graph is in [modifiers.md](../modifiers.md)):

- `AddModifierNode(this, parent, mult, mask)` `0x232b40` ends with `AddExplicitDependency(this,
  parent)` `0x232a90`. That puts this node's id into the parent's `_ChildNodes`. The edges are
  found while the node is computed.
- `InvalidateChildren(mask)` `0x239460` invalidates every listed child (looked up in the registry,
  version checked) and removes the children it invalidated, and the dead ones.
- Nothing else removes an entry. A node's `CalculateModifier` rebuilds it whole from its current
  parents, but doesn't take its id out of the parents it no longer reads.

So an edge lives until the parent's next invalidation, whether or not the child still reads it.

Seen in the captures (`stellar.modifier_capture`, with `_ChildNodes`) of the 2211.07.01 game:
15,953 nodes and 32,798 edges, of which one listed child has none of its parent's values that would
pass its filter:

- Country 16777223, the leader of federation 0, is listed by Federation 0, which holds
  `federation_experience_add = 0.25` (Countries, Federations).
- The country's node doesn't have that value.
- The other members (49, 50) aren't listed.

That is what a stale entry looks like. The capture alone can't rule out a read through a mask that
filters the value out.

The rewrite's graph (`lua/stellar/graph/`, `sim/lua/engine/modifiers/`) has no such entries:
- built from a capture, it leaves out an edge whose parent's values would pass but added nothing
  (`stellar.graph.nodes`, `stale_edges`);
- built from a save, its links come from the world's structure (`engine.modifiers.structure`).

A fix in the game: when a node is recomputed, drop its id from the parents of its previous
computation that it no longer reads. The node would have to keep that list of parents.
