--!strict
-- The host half: a lens that reads `seq` output as numbers.

type State = { values: { number } }

local ui = tern.ui
local notes = require("./notes")
local editbuf = require("./editbuf")
local markdown = require("./markdown")

local seq: LensDef<State> = {
	open = function(_run, _cx)
		return { values = {} }
	end,
	line = function(state, l)
		local n = tonumber(l.text)
		if n then
			table.insert(state.values, n)
		end
	end,
	finish = function(_state, _status) end,
	view = function(state)
		if #state.values == 0 then
			return nil -- not numbers: keep the raw output
		end
		local sum = 0
		local series: { { any } } = {}
		for i, n in state.values do
			sum += n
			series[i] = { tostring(i), n }
		end
		return ui.col({
			ui.text({
				ui.span(tostring(#state.values), "strong num"),
				ui.span(" numbers, sum "),
				ui.span(tostring(sum), "num"),
			}),
			ui.spark(series),
		})
	end,
}

tern.lens.define("seq", seq)

type Note = notes.Note
type NotesState = {
	mode: "browse" | "edit",
	sel: number?,
	archived_view: boolean,
	cursor: number,
}

-- Browse-mode keys that run an action with no value.
local KEYS: { [string]: string } = {
	enter = "edit",
	n = "new",
	y = "copy",
	a = "archive_toggle",
	v = "toggle_view",
}

-- First non-blank line of `text`, trimmed; "" when there is none.
local function first_line(text: string): string
	for line in string.gmatch(text, "[^\r\n]+") do
		local t = string.match(line, "^%s*(.-)%s*$") or ""
		if t ~= "" then
			return t
		end
	end
	return ""
end

local function index_of(list: { Note }, id: number?): number?
	for i, n in list do
		if n.id == id then
			return i
		end
	end
	return nil
end

local function view_notes(state: NotesState): { Note }
	return notes.list(if state.archived_view then "archived" else "active")
end

-- Sets props on a node and returns it.
local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Selects the note that took the place of the one at position `i` (next, else previous). When the
-- view is empty, opens a pending new note in edit mode.
local function select_neighbour(state: NotesState, i: number?)
	local after = view_notes(state)
	if #after == 0 then
		state.sel = nil
		state.mode = "edit"
		state.cursor = 0
		return
	end
	state.sel = after[math.min(i or 1, #after)].id
end

-- Stores `text` into the selected note, creating it first when nothing is selected.
local function commit_text(state: NotesState, text: string)
	local id = state.sel
	if id == nil then
		state.sel = notes.create(text).id
	else
		notes.set_text(id, text)
	end
end

-- Text of the selected note; "" while a new note has nothing stored.
local function current_text(state: NotesState): string
	local id = state.sel
	local note = if id ~= nil then notes.get(id) else nil
	return if note then note.text else ""
end

-- Stores an edited text and its byte caret. The store is untouched when the text did not change.
local function set_draft(state: NotesState, text: string, cursor: number)
	state.cursor = cursor
	if text ~= current_text(state) then
		commit_text(state, text)
	end
end

-- Node id of the editor in the view: region `main`, child `body`, key `ed`.
local EDITOR = "main.body.ed"

-- Puts the caret in the editor. Tern draws the caret only on the focused field.
local function focus_editor(cx: BlockCx)
	cx:frame({ { "focus", EDITOR } })
end

-- Leaves edit mode. A stored note still empty is dropped; a pending note has nothing stored.
local function finish_edit(state: NotesState)
	if state.mode ~= "edit" then
		return
	end
	state.mode = "browse"
	local id = state.sel
	if id == nil then
		return
	end
	local note = notes.get(id)
	if note == nil or note.text ~= "" then
		return
	end
	local i = index_of(view_notes(state), id)
	notes.drop(id)
	select_neighbour(state, i)
end

-- Moves the selection by `delta` rows in the current view; false when it did not move.
local function move(state: NotesState, delta: number): boolean
	local list = view_notes(state)
	if #list == 0 then
		return false
	end
	local i = index_of(list, state.sel) or 0
	local target = list[math.max(1, math.min(#list, i + delta))].id
	if target == state.sel then
		return false
	end
	state.sel = target
	return true
end

-- Runs one control. Shared by keys and view events; false when nothing happened.
local function act(state: NotesState, name: string, value: string?, cx: BlockCx): boolean
	if name == "select" then
		finish_edit(state)
		local id = if value then tonumber(value) else nil
		if id == nil or notes.get(id) == nil then
			return false
		end
		state.sel = id
		return true
	elseif name == "edit" then
		local id = state.sel
		local note = if id then notes.get(id) else nil
		if note == nil then
			return false
		end
		state.mode = "edit"
		state.cursor = #note.text
		return true
	elseif name == "new" then
		finish_edit(state)
		state.mode = "edit"
		state.sel = nil
		state.archived_view = false
		state.cursor = 0
		return true
	elseif name == "copy" then
		local id = state.sel
		local note = if id then notes.get(id) else nil
		if note == nil then
			return false
		end
		cx:copy(note.text)
		cx:toast("info", "Copied", first_line(note.text))
		return true
	elseif name == "archive_toggle" then
		finish_edit(state)
		local id = state.sel
		local note = if id then notes.get(id) else nil
		if note == nil then
			return false
		end
		local i = index_of(view_notes(state), id)
		notes.set_archived(note.id, not note.archived)
		select_neighbour(state, i)
		return true
	elseif name == "toggle_view" then
		finish_edit(state)
		state.archived_view = not state.archived_view
		local list = view_notes(state)
		state.sel = if list[1] then list[1].id else nil
		return true
	end
	return false
end

local function list_node(state: NotesState): Node
	local list = view_notes(state)
	local items: { { label: any } } = {}
	for i, note in list do
		local line = first_line(note.text)
		items[i] = { label = if line == "" then ui.span("New note", "muted") else line }
	end
	local listing = ui.list(items)
	local children: { Node } = listing.c or {}
	for i, child in children do
		local id = list[i].id
		with(child, { key = "n" .. id, actions = { click = "select=" .. id } })
	end
	local empty = if state.archived_view then "No archived notes" else "No notes yet"
	local sel = state.sel
	return with(listing, {
		key = "list",
		selected = if sel ~= nil then "main.body.list.n" .. sel else nil,
		empty = { ui.span(empty, "muted") },
	})
end

-- Markdown styling of `text` as editor decorations: UTF-16 ranges with span tokens.
local function decor_of(text: string): { { from: number, to: number, s: string } }
	local out: { { from: number, to: number, s: string } } = {}
	for i, span in markdown.scan(text) do
		out[i] = {
			from = editbuf.to_utf16(text, span.from),
			to = editbuf.to_utf16(text, span.to),
			s = span.token,
		}
	end
	return out
end

local function pane_node(state: NotesState): Node
	local id = state.sel
	local note = if id ~= nil then notes.get(id) else nil
	if state.mode == "edit" then
		local text = if note then note.text else ""
		return ui.node("editor", {
			key = "ed",
			text = text,
			cursor = editbuf.to_utf16(text, state.cursor),
			decor = decor_of(text),
			placeholder = "Write a note…",
		})
	end
	if note == nil then
		return ui.col({ ui.text({ ui.span("Select a note, or press n to write one", "muted") }) })
	end
	return with(ui.col({ ui.md(note.text) }), { actions = { click = "edit=" } })
end

local function dock_node(state: NotesState): Node
	local archive_label = if state.archived_view then "Restore · a" else "Archive · a"
	local view_label = if state.archived_view then "Active · v" else "Archived · v"
	return ui.row({
		with(ui.badge("New · n", "accent"), { key = "new", actions = { click = "new=" } }),
		with(ui.badge("Edit · Enter", "neutral"), { key = "edit", actions = { click = "edit=" } }),
		with(ui.badge("Copy · y", "neutral"), { key = "copy", actions = { click = "copy=" } }),
		with(ui.badge(archive_label, "neutral"), { key = "archive", actions = { click = "archive_toggle=" } }),
		with(ui.badge(view_label, "neutral"), { key = "view", actions = { click = "toggle_view=" } }),
	})
end

-- Keys in browse mode: list moves and the controls in KEYS. False when the key did nothing.
local function browse_key(state: NotesState, key: Key, cx: BlockCx): boolean
	if key.name == "j" or key.name == "down" then
		return move(state, 1)
	elseif key.name == "k" or key.name == "up" then
		return move(state, -1)
	end
	local name = KEYS[key.name]
	if name == nil then
		return false
	end
	return act(state, name, nil, cx)
end

-- Keys in edit mode. Typing and caret keys are applied here; a native selection arrives as an `edit`
-- event instead (see native_edit). False when the key changed nothing.
local function edit_key(state: NotesState, key: Key): boolean
	local name = key.name
	if name == "escape" then
		finish_edit(state)
		return true
	end
	local text = current_text(state)
	local cur = state.cursor
	if name == "paste" then
		local s = editbuf.normalize(key.text or "")
		if s == "" then
			return false
		end
		local t, c = editbuf.insert(text, cur, s)
		set_draft(state, t, c)
		return true
	end
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local moved: number? = nil
	if name == "left" then
		moved = editbuf.left(text, cur)
	elseif name == "right" then
		moved = editbuf.right(text, cur)
	elseif name == "up" then
		moved = editbuf.up(text, cur)
	elseif name == "down" then
		moved = editbuf.down(text, cur)
	elseif name == "home" then
		moved = editbuf.line_start(text, cur)
	elseif name == "end" then
		moved = editbuf.line_end(text, cur)
	end
	if moved ~= nil then
		if moved == cur then
			return false
		end
		state.cursor = moved
		return true
	end
	local t, c = text, cur
	if name == "backspace" then
		t, c = editbuf.backspace(text, cur)
	elseif name == "delete" then
		t, c = editbuf.delete(text, cur)
	else
		local typed = if name == "enter" then "\n" else key.text
		if typed == nil or typed == "" then
			return false
		end
		t, c = editbuf.insert(text, cur, typed)
	end
	if t == text then
		return false
	end
	set_draft(state, t, c)
	return true
end

-- A native selection edit: replaces the UTF-16 range from..to with text and moves the caret. Tern computes
-- `len` against the text it drew; a different length means the edit is stale, so it is ignored.
local function native_edit(state: NotesState, ev: UiEvent)
	local text = current_text(state)
	if ev.len ~= editbuf.utf16_len(text) then
		return
	end
	local t = editbuf.apply_edit(text, ev.from, ev.to, editbuf.normalize(ev.text or ""))
	set_draft(state, t, editbuf.to_bytes(t, ev.cursor))
end

local notes_block: BlockDef<NotesState> = {
	init = function(_cx, _args, _saved)
		return { mode = "edit", sel = nil, archived_view = false, cursor = 0 }
	end,

	title = function(_state)
		return "Scratchpad"
	end,

	view = function(state, _cx)
		local side = with(list_node(state), { grow = 0, shrink = 0, min = { w = "28ch" }, max = { w = "28ch" } })
		local pane = with(pane_node(state), { grow = 1, shrink = 1, basis = 0, min = { w = "0ch" } })
		local body = with(ui.row({ side, pane }), { key = "body", grow = 1, align = "start" })
		-- The bar lives in `main`, not `dock`: the dock strip was clipped at the pane's bottom edge in a real window.
		local bar = with(dock_node(state), { key = "bar", grow = 0, shrink = 0 })
		return { main = ui.col({ body, bar }) }
	end,

	key = function(state, key, cx)
		local was = state.mode
		local changed = if was == "edit" then edit_key(state, key) else browse_key(state, key, cx)
		if state.mode == "edit" and was ~= "edit" then
			focus_editor(cx)
		end
		return changed
	end,

	event = function(state, ev, cx)
		local was = state.mode
		if ev.ev == "action" and ev.act then
			act(state, ev.act, ev.value, cx)
		elseif ev.ev == "edit" and state.mode == "edit" then
			native_edit(state, ev)
		end
		if state.mode == "edit" and was ~= "edit" then
			focus_editor(cx)
		end
	end,

	features = { "edit" },

	save = function(_state)
		return nil
	end,
}

tern.block.define("notes", notes_block)
