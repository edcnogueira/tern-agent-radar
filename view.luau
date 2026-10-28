--!strict
-- The radar canvas: the model from `radar.luau` as tern.ui nodes. Classes
-- are styled by `radar.css`; colors come from each node's tone.

local radar = require("./radar")

local ui = tern.ui
local el = ui.el

local view = {}

local STATS = {
	{ id = "wait", label = "need you", tone = "warning" },
	{ id = "work", label = "working", tone = "info" },
	{ id = "done", label = "done", tone = "success" },
	{ id = "idle", label = "idle", tone = "muted" },
}

local function text(class: string, t: string): Node
	return el("span", { class = class, text = t })
end

local function stats(model: radar.Model, filter: string?): Node
	local chips: { Node } = {}
	for _, s in STATS do
		local n = (model.counts :: any)[s.id]
		local class = "ar-stat"
		if filter == s.id then
			class ..= " ar-on"
		end
		if s.id == "wait" and n > 0 then
			class ..= " ar-hot"
		end
		table.insert(chips, el("div", {
			class = class,
			key = "stat-" .. s.id,
			tone = s.tone,
			actions = { click = "filter=" .. s.id },
		}, {
			el("span", { class = "ar-dot" }),
			text("ar-stat-value", tostring(n)),
			text("ar-stat-label", s.label),
		}))
	end
	return el("div", { class = "ar-stats", key = "stats" }, chips)
end

local GLYPH: { [string]: string } = { done = "✓", fail = "✕" }

local function row(r: radar.Row): Node
	local wait = r.kind == "wait"
	local where_below = r.message ~= nil and not wait
	local line: { Node } = {
		el("span", { class = "ar-glyph", text = GLYPH[r.kind] }),
		text("ar-name", r.name),
	}
	if r.branch then
		table.insert(line, text("ar-branch", r.branch))
	end
	table.insert(line, el("span", { class = "ar-fill" }))
	if r.where ~= "" and not where_below then
		table.insert(line, text("ar-where", r.where))
	end
	table.insert(line, text("ar-age", r.age))

	local children: { Node } = { el("div", { class = "ar-l1" }, line) }
	if r.message then
		local l2: { Node } = { text(if r.error then "ar-msg ar-err" else "ar-msg", r.message) }
		if r.where ~= "" and where_below then
			table.insert(l2, text("ar-where", r.where))
		end
		table.insert(children, el("div", { class = "ar-l2" }, l2))
	end
	local class = "ar-row ar-" .. r.kind
	if r.focused then
		class ..= " ar-cur"
	end
	return el("div", {
		class = class,
		key = "agent-" .. r.pane,
		tone = radar.TONE[r.kind],
		actions = { click = "go=" .. r.pane },
	}, children)
end

local function head(sec: radar.Section): Node
	return el("div", { class = "ar-head", tone = sec.tone }, {
		text("ar-head-label", sec.label),
		text("ar-head-count", tostring(#sec.rows)),
	})
end

local function section(sec: radar.Section): Node
	local rows: { Node } = {}
	for _, r in sec.rows do
		table.insert(rows, row(r))
	end
	if sec.folded then
		-- Idle agents fold away; Tern toggles the section locally.
		local exited = 0
		for _, r in sec.rows do
			if r.kind == "exited" then
				exited += 1
			end
		end
		local parts: { string } = {}
		if #sec.rows > exited then
			table.insert(parts, (#sec.rows - exited) .. " idle")
		end
		if exited > 0 then
			table.insert(parts, exited .. " exited")
		end
		local label = table.concat(parts, " · ")
		local node = ui.section({ ui.span(label, "dim") }, rows)
		local p: { [string]: any } = node.p or {}
		p.key = "sec-" .. sec.id
		p.collapsible = true
		p.collapsed = true
		node.p = p
		return node
	end
	table.insert(rows, 1, head(sec))
	return el("div", { class = "ar-sec", key = "sec-" .. sec.id }, rows)
end

local function empty(): Node
	return el("div", { class = "ar-empty", key = "empty" }, {
		text("ar-empty-title", "No agents running"),
		text("ar-empty-text", "Agents started in any session show up here as soon as they start."),
		el("button", { class = "ar-btn", text = "New agent block", actions = { click = "new" } }),
	})
end

-- The canvas view of `model`; `filter` is the active stat chip.
function view.main(model: radar.Model, filter: string?): Node
	local children: { Node } = {}
	if model.total == 0 then
		table.insert(children, empty())
	else
		table.insert(children, stats(model, filter))
		for _, sec in model.sections do
			table.insert(children, section(sec))
		end
		if #model.sections == 0 then
			table.insert(children, el("div", { class = "ar-none", key = "none" }, {
				text("ar-empty-text", "Nothing here. Click the chip again to show every agent."),
			}))
		end
	end
	return el("div", { class = "ar", role = "agent-radar" }, children)
end

-- The canvas dock: grouping toggle and a hint.
function view.dock(group: string): Node
	local function seg(id: string, label: string): Node
		return el("span", {
			class = if group == id then "ar-seg ar-on" else "ar-seg",
			text = label,
			actions = { click = "group=" .. id },
		})
	end
	return el("div", { class = "ar-dock", role = "agent-radar-dock" }, {
		el("div", { class = "ar-segs" }, { seg("status", "Status"), seg("session", "Session") }),
		el("span", { class = "ar-fill" }),
		text("ar-hint", "⌥⌘J jump"),
	})
end

-- The canvas title: the pane's tab label too.
function view.title(model: radar.Model): string
	if model.total == 0 then
		return "Agent Radar"
	elseif model.counts.wait > 0 then
		return string.format("Agent Radar · %d need you", model.counts.wait)
	end
	return string.format("Agent Radar · %d agents", model.total)
end

return view
