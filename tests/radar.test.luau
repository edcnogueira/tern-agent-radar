local radar = require("../radar")

local failures = 0
local function check(name: string, got: any, want: any)
	if got ~= want then
		failures += 1
		print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
	end
end

local function agent(pane: number, state: string, extra: { [string]: any }?): any
	local a: { [string]: any } = { pane = pane, state = state, cwd = "/w/p" .. pane, session = 1, tab = 10, alive = true }
	for k, v in extra or {} do
		a[k] = v
	end
	return a
end

local function model(agents: { any }, memory: any, opts: { [string]: any }?): any
	local o = opts or {}
	return radar.build({
		agents = agents,
		memory = memory,
		sessions = o.sessions or { { id = 1, name = "setare" }, { id = 2, name = "kodacoda" } },
		positions = o.positions or { [10] = 1, [20] = 2 },
		branches = o.branches or {},
		focused = o.focused,
		now = o.now or 1000,
		group = o.group or "status",
		filter = o.filter,
	})
end

local function kinds(m: any): string
	local out = {}
	for _, s in m.sections do
		for _, r in s.rows do
			table.insert(out, r.pane .. ":" .. r.kind)
		end
	end
	return table.concat(out, " ")
end

-- A turn that ends while you look elsewhere shows as done until you focus the pane.
do
	local mem = {}
	radar.observe(mem, { agent(1, "working") }, nil, 100)
	radar.observe(mem, { agent(1, "idle") }, nil, 200)
	check("done unseen", kinds(model({ agent(1, "idle") }, mem)), "1:done")
	check("see changes", radar.see(mem, 1), true)
	check("see again", radar.see(mem, 1), false)
	check("done seen is idle", kinds(model({ agent(1, "idle") }, mem)), "1:idle")
end

-- A turn that ends on the focused pane is already seen.
do
	local mem = {}
	radar.observe(mem, { agent(1, "working") }, 1, 100)
	radar.observe(mem, { agent(1, "idle") }, 1, 200)
	check("focused end is seen", kinds(model({ agent(1, "idle") }, mem)), "1:idle")
end

-- An agent that was idle when first seen has no turn to report.
do
	local mem = {}
	radar.observe(mem, { agent(1, "idle") }, nil, 100)
	check("first sight idle", kinds(model({ agent(1, "idle") }, mem)), "1:idle")
end

-- agent_finished "failed" before or after the idle state marks the turn failed.
do
	local before = {}
	radar.observe(before, { agent(1, "working") }, nil, 100)
	radar.finished(before, 1, "failed", nil, 150)
	radar.observe(before, { agent(1, "idle") }, nil, 200)
	check("failed before idle", kinds(model({ agent(1, "idle") }, before)), "1:fail")

	local after = {}
	radar.observe(after, { agent(1, "working") }, nil, 100)
	radar.observe(after, { agent(1, "idle") }, nil, 200)
	radar.finished(after, 1, "failed", nil, 210)
	check("failed after idle", kinds(model({ agent(1, "idle") }, after)), "1:fail")

	-- Working again clears the ended turn.
	radar.observe(after, { agent(1, "working") }, nil, 300)
	check("working clears turn", kinds(model({ agent(1, "working") }, after)), "1:work")
	radar.observe(after, { agent(1, "idle") }, nil, 400)
	check("next turn done", kinds(model({ agent(1, "idle") }, after)), "1:done")
end

-- "closed"/"exited" results don't invent a turn.
do
	local mem = {}
	radar.observe(mem, { agent(1, "idle") }, nil, 100)
	radar.finished(mem, 1, "closed", nil, 150)
	check("closed ignored", kinds(model({ agent(1, "idle") }, mem)), "1:idle")
end

-- Entering waiting_input asks for a toast, except on the focused pane.
do
	local mem = {}
	radar.observe(mem, { agent(1, "working"), agent(2, "working") }, 2, 100)
	local w = radar.observe(mem, { agent(1, "waiting_input"), agent(2, "waiting_input") }, 2, 200)
	check("toast count", #w, 1)
	check("toast pane", w[1], 1)
	local again = radar.observe(mem, { agent(1, "waiting_input"), agent(2, "waiting_input") }, nil, 300)
	check("toast once per wait", #again, 0)
end

-- Gone panes are forgotten.
do
	local mem = {}
	radar.observe(mem, { agent(1, "idle"), agent(2, "idle") }, nil, 100)
	radar.observe(mem, { agent(2, "idle") }, nil, 200)
	check("forgotten", mem["1"], nil)
end

-- Order: waiting (oldest first), working (longest first), done (newest first), idle, exited.
do
	local mem = {}
	local t0 = { agent(1, "idle"), agent(2, "idle"), agent(3, "idle"), agent(4, "idle"), agent(5, "idle"), agent(6, "idle"), agent(7, "idle") }
	radar.observe(mem, t0, nil, 0)
	radar.observe(mem, {
		agent(1, "working"), agent(2, "working"), agent(3, "working"), agent(4, "working"),
		agent(5, "idle"), agent(6, "idle"), agent(7, "idle"),
	}, nil, 10)
	radar.observe(mem, {
		agent(1, "waiting_input"), agent(2, "working"), agent(3, "working"), agent(4, "working"),
		agent(5, "idle"), agent(6, "idle"), agent(7, "idle"),
	}, nil, 20)
	radar.observe(mem, {
		agent(1, "waiting_input"), agent(2, "waiting_input"), agent(3, "idle"), agent(4, "working"),
		agent(5, "idle"), agent(6, "idle"), agent(7, "idle"),
	}, nil, 30)
	local now = {
		agent(1, "waiting_input"), agent(2, "waiting_input"), agent(3, "idle"), agent(4, "idle"),
		agent(5, "working"), agent(6, "idle"), agent(7, "exited", { alive = false }),
	}
	radar.observe(mem, now, nil, 40)
	local m = model(now, mem, { now = 100 })
	check("order", kinds(m), "1:wait 2:wait 5:work 4:done 3:done 6:idle 7:exited")
	check("counts wait", m.counts.wait, 2)
	check("counts work", m.counts.work, 1)
	check("counts done", m.counts.done, 2)
	check("counts idle", m.counts.idle, 2)
	check("idle folded", m.sections[#m.sections].folded, true)
	check("filter", kinds(model(now, mem, { now = 100, filter = "done" })), "4:done 3:done")
	check("age wait", m.sections[1].rows[1].age, "waiting 1m")
	check("age done", m.sections[3].rows[1].age, "1m ago")
end

-- Session grouping follows the session order and tints sessions with a waiting agent.
do
	local mem = {}
	local list = { agent(1, "idle", { session = 2, tab = 20 }), agent(2, "waiting_input", { session = 1 }), agent(3, "working", { session = 2, tab = 20 }) }
	radar.observe(mem, list, nil, 0)
	local m = model(list, mem, { group = "session" })
	check("session count", #m.sections, 2)
	check("session first", m.sections[1].label, "SETARE")
	check("session first tone", m.sections[1].tone, "warning")
	check("session second", m.sections[2].label, "KODACODA")
	check("session second tone", m.sections[2].tone, "muted")
	check("session rows", kinds(m), "2:wait 3:work 1:idle")
	check("sessions", m.sessions, 2)
	check("session where names the tab only", m.sections[2].rows[1].where, "tab 2")
end

-- Row text: name from cwd, where with tab position or parked, branch, messages.
do
	local mem = {}
	local list = {
		agent(1, "waiting_input", { cwd = "/work/api/", last_message = "\n  Allow migrate?  \nmore" }),
		agent(2, "idle", { parked = true, tab = 77 }),
		agent(3, "working", { delivery_error = "omp needs updating" }),
		agent(4, "waiting_input", { session = 99, tab = 77 }),
	}
	radar.observe(mem, list, nil, 0)
	local m = model(list, mem, { branches = { [1] = "PP-18/x" } })
	local by = {}
	for _, r in m.rows do
		by[r.pane] = r
	end
	check("name", by[1].name, "api")
	check("branch", by[1].branch, "PP-18/x")
	check("where tab", by[1].where, "setare › 1")
	check("headline", by[1].message, "Allow migrate?")
	check("where parked", by[2].where, "setare › parked")
	check("delivery error", by[3].message, "omp needs updating")
	check("delivery error flag", by[3].error, true)
	check("wait fallback", by[4].message, "Waiting for your input")
	check("unknown session", by[4].where, "")
end

-- Helpers.
check("duration under a minute", radar.duration(59), "<1m")
check("duration minute boundary", radar.duration(60), "1m")
check("duration m", radar.duration(125), "2m")
check("duration h", radar.duration(7300), "2h")
check("duration d", radar.duration(200000), "2d")
check("cut short", radar.cut("abc", 5), "abc")
check("cut long", radar.cut("abcdef", 4), "abc…")
check("cut utf8", radar.cut("ãéíõú", 3), "ãé…")

if failures > 0 then
	error(failures .. " failed")
end
print("ok")
