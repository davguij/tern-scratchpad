--!strict
-- Scratchpad note store: one tern.kv key holding { next, items }, read-modify-written per call.

export type Note = { id: number, text: string, archived: boolean }
type Store = { next: number, items: { Note } }

local KEY = "notes"

local function load(): Store
	local raw: any = tern.kv.get(KEY)
	local items: any = if type(raw) == "table" then raw.items else nil
	local clean: { Note } = tern.json.array()
	local top = 0
	if type(items) == "table" then
		for _, n in items do
			if type(n) == "table" and type(n.id) == "number" and type(n.text) == "string" then
				table.insert(clean, { id = n.id, text = n.text, archived = n.archived == true })
				if n.id > top then top = n.id end
			end
		end
	end
	local next: any = if type(raw) == "table" then raw.next else nil
	if type(next) ~= "number" or next <= top then next = top + 1 end
	return { next = next, items = clean }
end

local function save(s: Store)
	tern.kv.set(KEY, { next = s.next, items = tern.json.array(s.items) })
end

local function find(items: { Note }, id: number): number?
	for i, n in items do
		if n.id == id then return i end
	end
	return nil
end

local M = {}

-- Non-archived notes (view "active") or archived notes (view "archived"), newest id first.
function M.list(view: "active" | "archived"): { Note }
	local want = view == "archived"
	local out: { Note } = tern.json.array()
	for _, n in load().items do
		if n.archived == want then table.insert(out, n) end
	end
	table.sort(out, function(a: Note, b: Note): boolean
		return a.id > b.id
	end)
	return out
end

function M.get(id: number): Note?
	local s = load()
	local i = find(s.items, id)
	return if i then s.items[i] else nil
end

-- Creates an active note with the next id from the stored counter.
function M.create(text: string): Note
	local s = load()
	local note: Note = { id = s.next, text = text, archived = false }
	s.next += 1
	table.insert(s.items, note)
	save(s)
	return note
end

-- Replaces the text; never drops the note, even when text is empty. No-op for unknown ids.
function M.set_text(id: number, text: string)
	local s = load()
	local i = find(s.items, id)
	if i == nil then return end
	s.items[i].text = text
	save(s)
end

-- Archives or restores; the id is kept, so a restored note returns to its created position.
function M.set_archived(id: number, archived: boolean)
	local s = load()
	local i = find(s.items, id)
	if i == nil then return end
	s.items[i].archived = archived
	save(s)
end

-- Removes the note from storage entirely. No-op for unknown ids.
function M.drop(id: number)
	local s = load()
	local i = find(s.items, id)
	if i == nil then return end
	table.remove(s.items, i)
	save(s)
end

return M
