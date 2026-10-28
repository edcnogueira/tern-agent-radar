--!strict
-- The radar's model, without `tern`: what each agent's row says, which
-- section it sits in and in what order. `window.luau` feeds it
-- `cx.agents:list()` and the session names; tests run it under plain `luau`.

local radar = {}

-- What the radar remembers about a pane between ticks (kept in `tern.kv`,
-- so every window and a reload see the same thing). Times are os.time().
export type Memory = {
	-- The agent state seen last: idle, working, waiting_input or exited.
	state: string,
	-- When that state started.
	since: number,
	-- How the last turn ended ("done" or "failed"), while it is unseen.
	turn: string?,
	-- agent_finished's result, held until the turn's end is seen.
	result: string?,
	-- Whether the pane was focused since its turn ended.
	seen: boolean,
}

export type Agent = {
	pane: number,
	cwd: string?,
	state: string,
	last_message: string?,
	delivery_error: string?,
	session: number?,
	tab: number?,
	parked: boolean?,
	alive: boolean?,
	host: number?,
	title: string?,
}

export type Row = {
	pane: number,
	-- Section id: wait, work, done, fail, idle or exited.
	kind: string,
	name: string,
	branch: string?,
	session: string?,
	where: string,
	location: string,
	age: string,
	message: string?,
	error: boolean,
	focused: boolean,
	since: number,
	parked: boolean,
	session_id: number?,
}

export type Section = {
	id: string,
	label: string,
	tone: string,
	rows: { Row },
	-- Shown folded (the idle and exited agents).
	folded: boolean,
}

export type Counts = { wait: number, work: number, done: number, idle: number }

export type Model = {
	sections: { Section },
	counts: Counts,
	total: number,
	sessions: number,
	rows: { Row },
}

export type Input = {
	agents: { Agent },
	memory: { [string]: Memory },
	-- Session names by id, and their order.
	sessions: { { id: number, name: string } },
	-- Tab id -> one-based position in its session.
	positions: { [number]: number },
	-- Branch by pane, when known (the window reads it for local agents only).
	branches: { [number]: string },
	focused: number?,
	now: number,
	group: string, -- "status" or "session"
	filter: string?, -- nil, "wait", "work", "done" or "idle"
}

-- Section order and looks in status grouping.
local SECTIONS = {
	{ id = "wait", label = "Needs you", tone = "warning" },
	{ id = "work", label = "Working", tone = "muted" },
	{ id = "done", label = "Done", tone = "muted" },
	{ id = "idle", label = "Idle", tone = "muted" },
}

-- Which filter/section a row kind belongs to.
local BUCKET: { [string]: string } = {
	wait = "wait",
	work = "work",
	done = "done",
	fail = "done",
	idle = "idle",
	exited = "idle",
}

local RANK: { [string]: number } = { wait = 1, work = 2, done = 3, fail = 3, idle = 4, exited = 5 }

radar.TONE = {
	wait = "warning",
	work = "info",
	done = "success",
	fail = "error",
	idle = "muted",
	exited = "muted",
} :: { [string]: string }

-- The last path component: `/work/api/` -> `api`.
function radar.basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- `text` cut to at most `n` characters (UTF-8 aware), ending in `…` when cut.
function radar.cut(text: string, n: number): string
	if utf8.len(text) == nil or (utf8.len(text) :: number) <= n then
		return text
	end
	local stop = utf8.offset(text, n) :: number
	return string.sub(text, 1, stop - 1) .. "…"
end

-- The first non-blank line of `text`, trimmed and cut, or nil.
function radar.headline(text: string?, n: number): string?
	if text == nil then
		return nil
	end
	for line in string.gmatch(text, "[^\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
		if trimmed ~= "" then
			return radar.cut(trimmed, n)
		end
	end
	return nil
end

-- A compact duration: `<1m`, `4m`, `2h`, `3d`. Minutes are the finest step,
-- so ages alone redraw the canvas at most once a minute.
function radar.duration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s < 60 then
		return "<1m"
	elseif s < 3600 then
		return s // 60 .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	end
	return s // 86400 .. "d"
end

-- The agent's state as the radar tracks it: exited when its program ended.
local function raw_state(a: Agent): string
	if a.alive == false or a.state == "exited" then
		return "exited"
	end
	return a.state
end

-- Updates `memory` from the agents seen now. Returns the panes that just
-- started waiting for input (for a toast). Forgets panes that are gone.
function radar.observe(memory: { [string]: Memory }, agents: { Agent }, focused: number?, now: number): { number }
	local waiting: { number } = {}
	local present: { [string]: boolean } = {}
	for _, a in agents do
		local key = tostring(a.pane)
		present[key] = true
		local state = raw_state(a)
		local m = memory[key]
		if m == nil then
			-- First sight: no turn to report, nothing unseen.
			memory[key] = { state = state, since = now, seen = true }
			if state == "waiting_input" and a.pane ~= focused then
				table.insert(waiting, a.pane)
			end
		elseif m.state ~= state then
			local was_busy = m.state == "working" or m.state == "waiting_input"
			if state == "working" then
				m.turn = nil
				m.result = nil
			elseif state == "idle" and was_busy then
				m.turn = m.result or "done"
				m.result = nil
				m.seen = a.pane == focused
			elseif state == "waiting_input" and a.pane ~= focused then
				table.insert(waiting, a.pane)
			end
			m.state = state
			m.since = now
		end
	end
	for key in memory do
		if not present[key] then
			memory[key] = nil
		end
	end
	return waiting
end

-- Records `agent_finished`: a failed turn shows as failed; done/failed
-- arriving after the idle state was seen updates the ended turn.
function radar.finished(memory: { [string]: Memory }, pane: number, result: string, focused: number?, now: number)
	if result ~= "done" and result ~= "failed" then
		return
	end
	local key = tostring(pane)
	local m = memory[key]
	if m == nil then
		memory[key] = { state = "idle", since = now, turn = result, seen = pane == focused }
	elseif m.state == "idle" then
		if m.turn ~= nil or result == "failed" then
			m.turn = result
			m.seen = m.seen and pane == focused
		end
	else
		m.result = result
	end
end

-- Marks `pane` seen (focused, or jumped to). Returns true when that changed.
function radar.see(memory: { [string]: Memory }, pane: number): boolean
	local m = memory[tostring(pane)]
	if m and not m.seen then
		m.seen = true
		return true
	end
	return false
end

-- The row kind of an agent: wait, work, done, fail, idle or exited.
local function kind_of(state: string, m: Memory?): string
	if state == "waiting_input" then
		return "wait"
	elseif state == "working" then
		return "work"
	elseif state == "exited" then
		return "exited"
	elseif m and m.turn and not m.seen then
		return if m.turn == "failed" then "fail" else "done"
	end
	return "idle"
end

local function age_text(kind: string, seconds: number): string
	local d = radar.duration(seconds)
	if kind == "wait" or kind == "work" then
		return d
	elseif d == "<1m" then
		return "just now"
	end
	return d .. " ago"
end

local function compare(a: Row, b: Row): boolean
	if RANK[a.kind] ~= RANK[b.kind] then
		return RANK[a.kind] < RANK[b.kind]
	end
	-- Waiting and working: the longest first. The rest: the most recent first.
	if a.kind == "wait" or a.kind == "work" then
		if a.since ~= b.since then
			return a.since < b.since
		end
	elseif a.since ~= b.since then
		return a.since > b.since
	end
	return a.pane < b.pane
end

-- Builds the model the view draws.
function radar.build(input: Input): Model
	local names: { [number]: string } = {}
	local order: { [number]: number } = {}
	for i, s in input.sessions do
		names[s.id] = s.name
		order[s.id] = i
	end

	local rows: { Row } = {}
	local counts: Counts = { wait = 0, work = 0, done = 0, idle = 0 }
	local used: { [number]: boolean } = {}
	local nsessions = 0
	for _, a in input.agents do
		local state = raw_state(a)
		local m = input.memory[tostring(a.pane)]
		local kind = kind_of(state, m)
		local bucket = BUCKET[kind]
		counts[bucket] += 1
		local session = if a.session then names[a.session] else nil
		if a.session and not used[a.session] then
			used[a.session] = true
			nsessions += 1
		end
		local place = if a.parked then "parked" elseif a.tab and input.positions[a.tab] then tostring(input.positions[a.tab]) else nil
		local location = if session and place then session .. " › " .. place else session or place or ""
		local where = location
		if input.group == "session" then
			-- The section already names the session.
			where = if place == "parked" then "parked" elseif place then "tab " .. place else ""
		end
		local since = if m then m.since else input.now
		local message = radar.headline(a.last_message, 160)
		local err = false
		if a.delivery_error and a.delivery_error ~= "" then
			message = radar.headline(a.delivery_error, 160)
			err = true
		elseif message == nil and kind == "wait" then
			message = "Waiting for your input"
		end
		local cwd = a.cwd or ""
		table.insert(rows, {
			pane = a.pane,
			kind = kind,
			name = if cwd ~= "" then radar.basename(cwd) else a.title or ("pane " .. a.pane),
			branch = input.branches[a.pane],
			session = session,
			where = where,
			location = location,
			age = age_text(kind, input.now - since),
			message = message,
			error = err,
			focused = a.pane == input.focused,
			since = since,
			parked = a.parked == true,
			session_id = a.session,
		})
	end
	table.sort(rows, compare)

	local shown: { Row } = {}
	for _, r in rows do
		if input.filter == nil or BUCKET[r.kind] == input.filter then
			table.insert(shown, r)
		end
	end

	local sections: { Section } = {}
	if input.group == "session" then
		local by: { [string]: Section } = {}
		local list: { Section } = {}
		for _, r in shown do
			local id = if r.session_id then tostring(r.session_id) else "?"
			local sec = by[id]
			if sec == nil then
				sec = { id = "session:" .. id, label = r.session or "No session", tone = "muted", rows = {}, folded = false }
				by[id] = sec
				table.insert(list, sec)
			end
			table.insert(sec.rows, r)
		end
		table.sort(list, function(a: Section, b: Section): boolean
			local ia = order[tonumber(string.sub(a.id, 9)) or -1] or math.huge
			local ib = order[tonumber(string.sub(b.id, 9)) or -1] or math.huge
			return ia < ib
		end)
		for _, sec in list do
			for _, r in sec.rows do
				if r.kind == "wait" then
					sec.tone = "warning"
					break
				end
			end
			table.insert(sections, sec)
		end
	else
		for _, def in SECTIONS do
			local sec: Section = { id = def.id, label = def.label, tone = def.tone, rows = {}, folded = def.id == "idle" }
			for _, r in shown do
				if BUCKET[r.kind] == def.id then
					table.insert(sec.rows, r)
				end
			end
			if #sec.rows > 0 then
				table.insert(sections, sec)
			end
		end
	end

	return { sections = sections, counts = counts, total = #rows, sessions = nsessions, rows = rows }
end

export type Pick = {
	label: string,
	detail: string,
	group: string,
	icon: string,
	current: boolean,
	pane: number,
}

local PICK_GROUP: { [string]: string } = {
	wait = "Needs you",
	work = "Working",
	done = "Done",
	fail = "Done",
	idle = "Idle",
	exited = "Idle",
}

local PICK_ICON: { [string]: string } = {
	wait = "message",
	work = "run",
	done = "check",
	fail = "x",
	idle = "pause",
	exited = "power",
}

local function disambiguate(labels: { string }, rows: { Row }, extra: (Row) -> string?): { [number]: boolean }
	local kinds: { [string]: { [string]: boolean } } = {}
	local distinct: { [string]: number } = {}
	for i, r in rows do
		local l = labels[i]
		local e = extra(r) or ""
		local seen = kinds[l] or {}
		kinds[l] = seen
		if not seen[e] then
			seen[e] = true
			distinct[l] = (distinct[l] or 0) + 1
		end
	end
	local added: { [number]: boolean } = {}
	for i, r in rows do
		local e = extra(r)
		if distinct[labels[i]] > 1 and e and e ~= "" then
			labels[i] ..= " · " .. e
			added[i] = true
		end
	end
	return added
end

function radar.picks(model: Model): { Pick }
	local labels: { string } = {}
	for i, r in model.rows do
		labels[i] = r.name
	end
	disambiguate(labels, model.rows, function(r: Row): string?
		return r.branch
	end)
	local located = disambiguate(labels, model.rows, function(r: Row): string?
		return r.location
	end)
	disambiguate(labels, model.rows, function(r: Row): string?
		return "pane " .. r.pane
	end)

	local picks: { Pick } = {}
	for i, r in model.rows do
		local detail: { string } = {}
		local message = if r.message then radar.cut(r.message, 80) else nil
		if message and r.kind == "wait" then
			table.insert(detail, message)
		end
		if r.location ~= "" and not located[i] then
			table.insert(detail, r.location)
		end
		table.insert(detail, r.age)
		if message and r.kind ~= "wait" then
			table.insert(detail, message)
		end
		table.insert(picks, {
			label = labels[i],
			detail = table.concat(detail, " · "),
			group = PICK_GROUP[r.kind],
			icon = PICK_ICON[r.kind],
			current = r.focused,
			pane = r.pane,
		})
	end
	return picks
end

return radar
