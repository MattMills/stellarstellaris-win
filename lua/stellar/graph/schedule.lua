-- graph/schedule.lua : spreads a graph's pending work over frames, by deadline.
--
-- The game draws frames (about 60 a second) and runs ticks (10 per game day, a tick every 0.1 to
-- 2 seconds depending on the speed, none while paused). A graph (stellar.graph.core) collects the
-- invalidations of a tick; this scheduler computes them in the frames before they are due:
--
-- * FRAME nodes (what the UI shows) are computed every frame, all of them.
-- * TICK nodes are due before the next tick, DAY nodes before the tick that ends the day, MONTH
--   nodes before the tick that ends the month. Each frame does its share of each: the pending
--   count over the frames left before the deadline, given the expected frame rate and tick rate
--   (whatever the budget: what is due cannot wait, it can only be spread).
-- * Time left in the frame's budget works ahead (the most urgent first); READ nodes are only
--   computed when read.
-- * before_tick() is the barrier: what is due at this tick and not done yet is done there
--   (counted as missed: the expected schedule was wrong, or the work came too late to spread).
-- * after_tick() is the end of the tick: it finishes marking, so the graph holds the complete list
--   of pending invalidations, and advances the date.
--
--   local schedule = require("stellar.graph.schedule")
--   local s = schedule.new(g, { fps = 60, budget = 0.002, tick = 0.1 })
--   -- every frame:                      s:frame()
--   -- around every tick (HandleTurnTick): s:before_tick() ... the tick ... s:after_tick()
--   s:set_speed(0.5)                      -- seconds per tick; s:set_speed(nil) when paused
--   s:set_date(day_in_month, tick_in_day) -- where the game is in its month and day
--   s:plan()                              -- what the next frame will do, per class
--
-- Work is counted in nodes; the scheduler checks the clock between chunks of nodes, and keeps a
-- running estimate of the cost of a node.

local core = require("stellar.graph.core")

local huge = math.huge
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local FRAME, TICK, DAY, MONTH, READ = core.FRAME, core.TICK, core.DAY, core.MONTH, core.READ

local M = {}

M.TICKS_PER_DAY = 10
M.DAYS_PER_MONTH = 30

local function default_clock()
    local ok, util = pcall(require, "stellar.util")
    if ok and util.now then
        return util.now
    end
    return os.clock
end

-- schedule.new(g, options) -> scheduler. options: fps (expected frames per second, 60), budget
-- (seconds of graph work per frame, 0.002), tick (seconds per tick at the current speed; nil
-- while paused), chunk (nodes between clock checks, 64), mark_chunk (marking work between clock
-- checks, 4096), clock (a function returning seconds), measure (true: follow the measured frame
-- and tick rates)
function M.new(g, options)
    options = options or {}
    local s = {
        g = g,
        fps = options.fps or 60,
        budget = options.budget or 0.002,
        tick_seconds = options.tick,
        chunk = options.chunk or 64,
        mark_chunk = options.mark_chunk or 4096,
        clock = options.clock or default_clock(),
        measure = options.measure,
        tick_in_day = 0,     -- ticks done in the current day
        day_in_month = 0,    -- days done in the current month
        last_tick = nil,     -- clock at the last tick
        last_frame = nil,
        cost = 2e-7,         -- estimated seconds per computed node
        stats = {
            frames = 0, ticks = 0, frame_time = 0, frame_work = 0, over_budget = 0,
            unmarked_frames = 0, barrier_work = 0, barrier_time = 0, mark_time = 0,
            done = { 0, 0, 0, 0, 0 },
        },
    }

    function s:set_speed(seconds_per_tick)
        self.tick_seconds = seconds_per_tick or nil
    end

    function s:set_date(day_in_month, tick_in_day)
        self.day_in_month = day_in_month or 0
        self.tick_in_day = tick_in_day or 0
    end

    -- frames left before the deadline of class c (at least 1; huge if never)
    function s:frames_until(c, now)
        if c == FRAME then
            return 1
        end
        local ts = self.tick_seconds
        if c == READ or ts == nil or ts <= 0 then
            return huge
        end
        now = now or self.clock()
        local to_tick = ts
        if self.last_tick ~= nil then
            to_tick = max(0, self.last_tick + ts - now)
        end
        local ticks = 0  -- ticks after the next one
        if c == DAY or c == MONTH then
            ticks = M.TICKS_PER_DAY - self.tick_in_day - 1
            if c == MONTH then
                ticks = ticks + (M.DAYS_PER_MONTH - self.day_in_month - 1) * M.TICKS_PER_DAY
            end
        end
        return max(1, floor((to_tick + ticks * ts) * self.fps))
    end

    -- what a frame would do now: { [class] = { pending, frames, quota } }, quota in nodes
    function s:plan(now)
        now = now or self.clock()
        local p = {}
        for c = FRAME, MONTH do
            local pend = self.g:dirty_count(c)
            local frames = self:frames_until(c, now)
            p[c] = { pending = pend, frames = frames, quota = frames == huge and 0 or ceil(pend / frames) }
        end
        p.cost = self.cost
        p.frame_budget_nodes = floor(self.budget / self.cost)
        return p
    end

    -- run class c in chunks until `want` nodes are done or the time is over (ignored when
    -- forced); -> nodes done
    local function run_for(self, c, want, deadline, forced)
        local g, clock, chunk = self.g, self.clock, self.chunk
        local done = 0
        while done < want do
            local n = g:run(c, min(chunk, want - done))
            if n == 0 then
                break
            end
            done = done + n
            if not forced and clock() >= deadline then
                break
            end
        end
        self.stats.done[c] = self.stats.done[c] + done
        return done
    end

    -- one frame's work; -> { marked, work, time, finished }
    function s:frame()
        local g, clock, st = self.g, self.clock, self.stats
        local t0 = clock()
        if self.measure and self.last_frame ~= nil and t0 > self.last_frame then
            local fps = 1 / (t0 - self.last_frame)
            self.fps = self.fps * 0.9 + fps * 0.1
        end
        self.last_frame = t0
        local deadline = t0 + self.budget
        st.frames = st.frames + 1
        -- marking first: computing needs it complete
        while g:frontier_size() > 0 do
            g:mark(self.mark_chunk)
            if clock() >= deadline then
                break
            end
        end
        local t1 = clock()
        st.mark_time = st.mark_time + (t1 - t0)
        if g:frontier_size() > 0 then
            st.unmarked_frames = st.unmarked_frames + 1
            st.frame_time = st.frame_time + (t1 - t0)
            return { work = 0, time = t1 - t0, finished = false }
        end
        -- the frame's share of each deadline: done whatever the budget (the budget only limits
        -- working ahead; what is due cannot wait)
        local work = run_for(self, FRAME, huge, deadline, true)
        for c = TICK, MONTH do
            local frames = self:frames_until(c, t1)
            if frames < huge then
                local want = ceil(g:dirty_count(c) / frames)
                if want > 0 then
                    work = work + run_for(self, c, want, deadline, true)
                end
            end
        end
        -- work ahead while the budget lasts
        if clock() < deadline then
            work = work + run_for(self, MONTH, huge, deadline, false)
        end
        local t2 = clock()
        if work > 0 then
            local per = (t2 - t1) / work
            self.cost = self.cost * 0.8 + per * 0.2
        end
        st.frame_time = st.frame_time + (t2 - t0)
        st.frame_work = st.frame_work + work
        if t2 > deadline then
            st.over_budget = st.over_budget + 1
        end
        return { work = work, time = t2 - t0, finished = g:dirty_count(MONTH) == 0 }
    end

    -- the barrier before a tick: everything due at this tick; -> nodes done (missed work)
    function s:before_tick()
        local g, clock, st = self.g, self.clock, self.stats
        local t0 = clock()
        g:mark(huge)
        local c = TICK
        if self.tick_in_day + 1 >= M.TICKS_PER_DAY then
            c = DAY
            if self.day_in_month + 1 >= M.DAYS_PER_MONTH then
                c = MONTH
            end
        end
        local w = g:run(c, huge)
        st.done[c] = st.done[c] + w
        st.barrier_work = st.barrier_work + w
        st.barrier_time = st.barrier_time + (clock() - t0)
        return w
    end

    -- the end of a tick: complete the list of invalidations and advance the date; -> g:pending()
    function s:after_tick()
        local g, clock, st = self.g, self.clock, self.stats
        local now = clock()
        if self.measure and self.last_tick ~= nil and self.tick_seconds ~= nil and now > self.last_tick then
            self.tick_seconds = self.tick_seconds * 0.8 + (now - self.last_tick) * 0.2
        end
        self.last_tick = now
        st.ticks = st.ticks + 1
        self.tick_in_day = self.tick_in_day + 1
        if self.tick_in_day >= M.TICKS_PER_DAY then
            self.tick_in_day = 0
            self.day_in_month = self.day_in_month + 1
            if self.day_in_month >= M.DAYS_PER_MONTH then
                self.day_in_month = 0
            end
        end
        local t0 = clock()
        g:mark(huge)
        st.mark_time = st.mark_time + (clock() - t0)
        return g:pending()
    end

    return s
end

return M
