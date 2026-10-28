--!strict
-- agent-radar, window half: one canvas listing every agent across sessions,
-- a picker to jump to one, a status line count and a toast when an agent
-- starts waiting for you. `radar.luau` holds the logic, `view.luau` the nodes.

local radar = require("./radar")
local view = require("./view")

local ID = tern.plugin.id
local OPEN = "plugin." .. ID .. ".open"
local TICK_MS = 1500
local BRANCH_TTL = 30
local ABOUT = "Every coding agent across sessions, ordered by who needs you. "
	.. "Clicking a row focuses that agent's pane; chips filter, the dock groups by status or session."

-- What the radar remembers per pane, shared with other windows through tern.kv.
local memory: { [string]: radar.Memory } = {}
local stored = "" -- the memory JSON last read or written, to write only changes

-- Branch per cwd, read through cx.git; `at` is os.time() of the answer.
type Branch = { name: string?, at: number, pending: boolean }
local branches: { [string]: Branch } = {}

-- Last model, for the status formatter (which may not call any cx).
local counts: radar.Counts = { wait = 0, work = 0, done = 0, idle = 0 }
local shown_counts = ""

-- Canvas JSON last set per canvas pane, so unchanged views aren't sent again.
local drawn: { [number]: string } = {}

local function kv(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

type Settings = { group: string, filter: string?, toasts: boolean }

local function settings(): Settings
	local s = kv("settings")
	local t: { [string]: any } = if type(s) == "table" then s else {}
	return {
		group = if t.group == "session" then "session" else "status",
		filter = if type(t.filter) == "string" then t.filter else nil,
		toasts = t.toasts ~= false,
	}
end

local function save_settings(s: Settings)
	tern.kv.set("settings", { group = s.group, filter = s.filter or tern.json.null, toasts = s.toasts })
end

-- Reads the shared memory again (another window may have changed it).
local function load_memory()
	local m = kv("memory")
	local text = if type(m) == "table" then tern.json.encode(m) else ""
	if text ~= stored then
		memory = {}
		if type(m) == "table" then
			for key, value in m do
				if type(value) == "table" and type(value.state) == "string" and type(value.since) == "number" then
					memory[tostring(key)] = {
						state = value.state,
						since = value.since,
						turn = if type(value.turn) == "string" then value.turn else nil,
						result = if type(value.result) == "string" then value.result else nil,
						seen = value.seen == true,
					}
				end
			end
		end
		stored = text
	end
end

local function save_memory()
	local text = tern.json.encode(memory)
	if text ~= stored then
		tern.kv.set("memory", memory)
		stored = text
	end
end

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

-- cx.agents:list() as plain radar agents (unknown fields come as tern.json.null).
local function agents(cx: WindowCx): { radar.Agent }
	local out: { radar.Agent } = {}
	for _, raw in cx.agents:list() do
		local a: any = raw
		table.insert(out, {
			pane = a.pane,
			cwd = str(a.cwd),
			state = str(a.state) or "idle",
			last_message = str(a.last_message),
			delivery_error = str(a.delivery_error),
			session = num(a.session),
			tab = num(a.tab),
			parked = a.parked == true,
			alive = a.alive ~= false,
			host = num(a.host),
			title = str(a.title),
		})
	end
	return out
end

local function local_host(cx: WindowCx): number?
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	if ok then
		for _, h in hosts do
			if h.kind == "local" then
				return h.id
			end
		end
	end
	return nil
end

-- The branch of each local agent's directory, by pane. Asks git again at most
-- every BRANCH_TTL seconds per directory; answers show from the next tick.
-- Agents on other hosts get none: their paths name another machine's files.
local function branches_of(cx: WindowCx, list: { radar.Agent }, now: number): { [number]: string }
	local out: { [number]: string } = {}
	local host = local_host(cx)
	if host == nil then
		return out
	end
	for _, a in list do
		local cwd = a.cwd
		if cwd and cwd ~= "" and a.host == host then
			local b = branches[cwd]
			-- A request with no answer for two TTLs is retried (a reset VM drops late answers).
			if b == nil or now - b.at >= (if b.pending then 2 * BRANCH_TTL else BRANCH_TTL) then
				local entry: Branch = { name = if b then b.name else nil, at = now, pending = true }
				branches[cwd] = entry
				local ok = pcall(function()
					cx.git:repo(cwd):next(function(repo: any, err: string?, _cx: WindowCx?)
						entry.pending = false
						entry.at = os.time()
						entry.name = if err == nil and repo and type(repo.branch) == "string" then repo.branch else nil
					end)
				end)
				if not ok then
					entry.pending = false
				end
				b = entry
			end
			if b.name then
				out[a.pane] = b.name
			end
		end
	end
	return out
end

local function owned(cx: WindowCx): { number }
	local panes: { number } = {}
	for _, c in cx.canvas:list() do
		if c.owner == ID then
			table.insert(panes, c.pane)
		end
	end
	return panes
end

local function model_of(cx: WindowCx, list: { radar.Agent }, now: number, s: Settings): radar.Model
	local sessions: { { id: number, name: string } } = {}
	for _, info in cx.session:sessions() do
		table.insert(sessions, { id = info.id, name = info.name })
	end
	local positions: { [number]: number } = {}
	for _, t in cx.session:tabs() do
		positions[t.id] = t.position
	end
	return radar.build({
		agents = list,
		memory = memory,
		sessions = sessions,
		positions = positions,
		branches = branches_of(cx, list, now),
		focused = cx.session:focused(),
		now = now,
		group = s.group,
		filter = s.filter,
	})
end

-- Sends the view to every canvas this plugin owns, when it changed.
local function draw(cx: WindowCx, model: radar.Model, s: Settings)
	local panes = owned(cx)
	if #panes == 0 then
		return
	end
	local change = { title = view.title(model), view = view.main(model, s.filter), dock = view.dock(s.group) }
	local text = tern.json.encode(change)
	for _, pane in panes do
		if drawn[pane] ~= text then
			cx.canvas:set(pane, change)
			drawn[pane] = text
		end
	end
end

local function where_line(r: radar.Row): string
	local parts: { string } = {}
	if r.location ~= "" then
		table.insert(parts, r.location)
	end
	if r.message then
		table.insert(parts, radar.cut(r.message, 90))
	end
	return table.concat(parts, " · ")
end

-- One pass: read the agents, update the memory, toast new waits, redraw.
-- Returns the model, for commands that show it another way.
local function tick(cx: WindowCx): radar.Model
	local now = os.time()
	local list = agents(cx)
	local focused = cx.session:focused()
	load_memory()
	local waiting = radar.observe(memory, list, focused, now)
	save_memory()
	local s = settings()
	local model = model_of(cx, list, now, s)

	if s.toasts and #waiting > 0 then
		for _, pane in waiting do
			for _, r in model.rows do
				if r.pane == pane then
					cx:toast("info", r.name .. " needs you", where_line(r))
				end
			end
		end
	end

	counts = model.counts
	local c = string.format("%d/%d/%d/%d", counts.wait, counts.work, counts.done, counts.idle)
	if c ~= shown_counts then
		shown_counts = c
		tern.chrome.refresh()
	end

	draw(cx, model, s)
	return model
end

local function safe_tick(cx: WindowCx): radar.Model?
	local model: radar.Model? = nil
	local ok, err = pcall(function()
		model = tick(cx)
	end)
	if not ok then
		tern.log.error("agent-radar tick failed:", err)
	end
	return model
end

local function find(cx: WindowCx, pane: number): radar.Agent?
	for _, a in agents(cx) do
		if a.pane == pane then
			return a
		end
	end
	return nil
end

-- Moves the radar canvas beside the focused block of `tab`, unless it is
-- already in that tab: the radar follows you across tabs and sessions.
local function bring(cx: WindowCx, tab: number?)
	local canvas = owned(cx)[1]
	if canvas == nil or tab == nil or cx.session:tab_of(canvas) == tab then
		return
	end
	local ok, err = cx.layout:move_to_tab(canvas, tab, { focus = false })
	if not ok then
		tern.log.warn("agent-radar: canvas not moved:", err)
	end
end

-- Shows the agent's pane: its session, out of the deck when parked, focused.
-- With `follow`, the radar canvas moves into the agent's tab.
local function jump(cx: WindowCx, pane: number, follow: boolean)
	local a = find(cx, pane)
	if a == nil then
		cx:toast("error", "That agent is gone")
		return
	end
	if a.parked then
		if a.session then
			cx.sessions:switch(a.session)
		end
		cx.layout:unpark(pane)
	end
	cx.layout:focus(pane)
	if follow then
		bring(cx, cx.session:tab_of(pane))
	end
	load_memory()
	if radar.see(memory, pane) then
		save_memory()
	end
end

-- Opens the radar beside the focused pane. When it is open in another tab it
-- moves here; when it is already here it takes the focus.
local function open(cx: WindowCx)
	local canvas = owned(cx)[1]
	if canvas then
		local focused = cx.session:focused()
		local here = if focused then cx.session:tab_of(focused) else nil
		if here and cx.session:tab_of(canvas) ~= here then
			bring(cx, here)
		else
			cx.layout:focus(canvas)
		end
		return
	end
	local model = safe_tick(cx)
	if model == nil then
		cx:toast("error", "Agent Radar did not open", "Reading the agents failed; see Tern's log.")
		return
	end
	local s = settings()
	local pane, err = cx.canvas:open({
		title = view.title(model),
		about = ABOUT,
		view = view.main(model, s.filter),
		dock = view.dock(s.group),
		how = "beside",
		focus = false,
	})
	if pane == nil then
		cx:toast("error", "Agent Radar did not open", err)
	end
end

local function pick(cx: WindowCx)
	-- The tick's model lists every agent in jump order, whatever the canvas filter.
	local model = safe_tick(cx)
	if model == nil then
		return
	end
	if model.total == 0 then
		cx:toast("info", "No agents running")
		return
	end
	local items: { PickItem } = radar.picks(model)
	cx:pick({ items = items, placeholder = "Jump to agent…", icon = "compass", action = "jump" }):next(
		function(item: PickItem?, _err: string?, cx2: WindowCx?)
			if item and cx2 and type(item.pane) == "number" then
				jump(cx2, item.pane, false)
			end
		end
	)
end

tern.command({
	id = "open",
	title = "Agent Radar",
	icon = "compass",
	keys = { "cmd+alt+r" },
	run = open,
})

tern.command({
	id = "jump",
	title = "Jump to agent",
	icon = "compass",
	keys = { "cmd+alt+j" },
	run = pick,
})

tern.command({
	id = "toasts",
	title = "Agent Radar: turn waiting toasts on or off",
	icon = "bell",
	run = function(cx: WindowCx)
		local s = settings()
		s.toasts = not s.toasts
		save_settings(s)
		cx:toast("info", if s.toasts then "Waiting toasts on" else "Waiting toasts off")
	end,
})

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.owner ~= ID then
		return false
	end
	local s = settings()
	if ev.act == "go" then
		local pane = tonumber(ev.value)
		if pane then
			jump(cx, pane, true)
		end
	elseif ev.act == "filter" then
		s.filter = if s.filter == ev.value then nil else ev.value
		save_settings(s)
	elseif ev.act == "group" then
		s.group = if ev.value == "session" then "session" else "status"
		save_settings(s)
	elseif ev.act == "new" then
		cx:action("new_agent_block")
		return true
	else
		return false
	end
	safe_tick(cx)
	return true
end)

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	load_memory()
	if radar.see(memory, ev.pane) then
		save_memory()
		safe_tick(cx)
	end
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	load_memory()
	radar.finished(memory, ev.pane, ev.result, cx.session:focused(), os.time())
	save_memory()
	safe_tick(cx)
end)

-- The tick loop starts when the entry loads: a plugin reload does not run
-- window_start again, and each timer callback gets a fresh cx.
local function loop(cx: WindowCx?)
	if cx then
		safe_tick(cx)
	end
	tern.timer(TICK_MS, loop)
end
tern.timer(100, loop)

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	local segs: { StatusSegment } = {}
	if counts.wait > 0 then
		table.insert(segs, { text = counts.wait .. " need you", icon = "bell", tone = "warning", command = OPEN })
	end
	if counts.work > 0 then
		table.insert(segs, { text = counts.work .. " working", icon = "run", tone = "info", command = OPEN })
	end
	if counts.done > 0 then
		table.insert(segs, { text = counts.done .. " done", icon = "check", tone = "success", command = OPEN })
	end
	return if #segs > 0 then segs else nil
end)
