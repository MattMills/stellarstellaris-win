-- simscript/handlers/empire_effects.lua : the empire's effects (species and traits, leaders, the
-- council, policies and edicts, ethics, civics and the government, pop groups and factions) and
-- the random_ / ordered_ iterators over the empire's lists with their `weights` and `inverse`.
-- Loaded by handlers/empire.lua with its helpers (H). docs/script_empire.md has each one's class.

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local sync = I.sync
    local EFF, LISTS = eval.EFF, eval.LISTS

    -- ------------------------------------------------------------------------------------------
    -- iterators: random_<list> = { limit weights <effects> } and ordered_<list> = { limit
    -- order_by position max inverse <effects> } (CRandomIteratorEffect / COrderedIteratorEffect
    -- [I: the weighted draw's arithmetic]); every_<list> is the walker's own

    local SKIP = {}
    for k in pairs(I.ITER_PARAMS) do SKIP[k] = true end
    SKIP.weights, SKIP.inverse = true, true

    local function iterate(kind, lname)
        return function(e, ctx)
            if e.value.text then return end
            local f = LISTS[lname]
            local list = f and f(ctx.this, ctx) or {}
            local limit, order_by, weights, inverse, position, max = nil, nil, nil, false, 0, 1
            for _, x in ipairs(e.value) do
                if x.op and x.key then
                    local xk = x.key.text:lower()
                    if xk == "limit" then limit = x.value
                    elseif xk == "order_by" then order_by = x.value
                    elseif xk == "weights" and x.value.text == nil then weights = x.value
                    elseif xk == "inverse" then inverse = x.value.text == "yes"
                    elseif xk == "position" then position = eval.value(x.value, ctx, x) or 0
                    elseif xk == "max" then max = eval.value(x.value, ctx, x) or 1 end
                end
            end
            local chosen = {}
            for _, s2 in ipairs(list) do
                if not limit or eval.trigger(limit, I.push(ctx, s2)) then chosen[#chosen + 1] = s2 end
            end
            local SR = eval.scope_iter
            local loop = SR and SR.begin(ctx)
            if kind == "random" then
                if #chosen == 0 then return end
                local r = loop and SR.draw(loop) or eval.rand()
                if weights then
                    local ws, total = {}, 0
                    for i, s2 in ipairs(chosen) do
                        ws[i] = math.max(0, eval.weight(weights, I.push(ctx, s2), 1))
                        total = total + ws[i]
                    end
                    if total <= 0 then return end
                    local at = (r % 1000000) / 1000000 * total
                    local pick = chosen[#chosen]
                    for i, w in ipairs(ws) do
                        if at < w then pick = chosen[i] break end
                        at = at - w
                    end
                    chosen = { pick }
                else
                    chosen = { chosen[r % #chosen + 1] }
                end
            else
                local keyed = {}
                for i, s2 in ipairs(chosen) do
                    keyed[i] = { s2, order_by and eval.value(order_by, I.push(ctx, s2), e) or 0, i }
                end
                table.sort(keyed, function(a, b)
                    if a[2] ~= b[2] then
                        if inverse then return a[2] < b[2] end
                        return a[2] > b[2]
                    end
                    return a[3] < b[3]
                end)
                chosen = {}
                for i = position + 1, math.min(#keyed, position + max) do chosen[#chosen + 1] = keyed[i][1] end
            end
            for _, s2 in ipairs(chosen) do
                local c = I.push(ctx, s2)
                if loop then SR.element(loop, c, kind) end
                eval.effect(e.value, c, SKIP)
            end
        end
    end
    for _, l in ipairs({ "existing_species_traits", "owned_pop_species", "pool_leader", "trait_available_for_species",
        "trait_of_species", "galaxy_species", "owned_leader", "owned_species" }) do
        EFF["random_" .. l] = iterate("random", l)
        EFF["ordered_" .. l] = iterate("ordered", l)
    end
end
