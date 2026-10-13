--!strict
-- Shared pure module, no Tern API: text edits for the note editor.
--
-- Tern's native editing covers selections and edit events, but a plugin block still gets typed
-- characters, Enter, Backspace, Delete and caret keys as plain keys, so those are applied here.
-- Two offset systems meet: this module works in 0-based UTF-8 byte offsets, while Tern's editor
-- `cursor`, `decor` and edit events use UTF-16 code units. The *16 functions convert between them.

local M = {}

local byte, sub = string.byte, string.sub

-- Length of the UTF-8 sequence that starts with lead byte b; a stray continuation byte counts as 1.
local function width(b: number): number
	if b < 0xC0 then
		return 1
	elseif b < 0xE0 then
		return 2
	elseif b < 0xF0 then
		return 3
	end
	return 4
end

local function is_cont(b: number): boolean
	return b >= 0x80 and b < 0xC0
end

-- Byte offset of the character that ends at offset i (0 at the start of the text).
local function prev(text: string, i: number): number
	local p = math.min(i, #text) - 1
	while p > 0 and is_cont(byte(text, p + 1)) do
		p -= 1
	end
	return math.max(p, 0)
end

-- Byte offset just after the character that starts at offset i; the text's end when none is left.
local function following(text: string, i: number): number
	if i >= #text then
		return #text
	end
	return math.min(i + width(byte(text, i + 1)), #text)
end

-- Byte offset where the logical line holding offset i starts.
function M.line_start(text: string, i: number): number
	local p = math.min(i, #text)
	while p > 0 and byte(text, p) ~= 10 do
		p -= 1
	end
	return p
end

-- Byte offset of the newline that ends the logical line holding offset i, or the text's end.
function M.line_end(text: string, i: number): number
	local p = math.min(i, #text)
	while p < #text and byte(text, p + 1) ~= 10 do
		p += 1
	end
	return p
end

-- Characters between byte offsets from and to.
local function chars_between(text: string, from: number, to: number): number
	local n, p = 0, from
	while p < to do
		p = following(text, p)
		n += 1
	end
	return n
end

-- The offset n characters after `from`, never past `stop`.
local function advance(text: string, from: number, stop: number, n: number): number
	local p = from
	for _ = 1, n do
		if p >= stop then
			break
		end
		p = following(text, p)
	end
	return p
end

-- Line endings become "\n": the note stores one kind of newline.
function M.normalize(s: string): string
	return (string.gsub(s, "\r\n?", "\n"))
end

-- Text with `s` inserted at cur, and the caret after it.
function M.insert(text: string, cur: number, s: string): (string, number)
	return sub(text, 1, cur) .. s .. sub(text, cur + 1), cur + #s
end

-- Text with the character before cur removed, and the caret where it was.
function M.backspace(text: string, cur: number): (string, number)
	if cur <= 0 then
		return text, cur
	end
	local p = prev(text, cur)
	return sub(text, 1, p) .. sub(text, cur + 1), p
end

-- Text with the character after cur removed; the caret stays.
function M.delete(text: string, cur: number): (string, number)
	if cur >= #text then
		return text, cur
	end
	return sub(text, 1, cur) .. sub(text, following(text, cur) + 1), cur
end

function M.left(text: string, cur: number): number
	return prev(text, cur)
end

function M.right(text: string, cur: number): number
	return following(text, cur)
end

-- Up or down one logical line, keeping the column in characters where the line allows it.
function M.up(text: string, cur: number): number
	local start = M.line_start(text, cur)
	if start == 0 then
		return cur
	end
	local above = M.line_start(text, start - 1)
	return advance(text, above, start - 1, chars_between(text, start, cur))
end

function M.down(text: string, cur: number): number
	local stop = M.line_end(text, cur)
	if stop >= #text then
		return cur
	end
	local col = chars_between(text, M.line_start(text, cur), cur)
	local below = stop + 1
	return advance(text, below, M.line_end(text, below), col)
end

-- Byte offset of UTF-16 offset u16; an offset inside a surrogate pair rounds down.
function M.to_bytes(text: string, u16: number): number
	local i, units = 0, 0
	while i < #text and units < u16 do
		local w = width(byte(text, i + 1))
		local u = if w == 4 then 2 else 1
		if units + u > u16 then
			break
		end
		units += u
		i = math.min(i + w, #text)
	end
	return i
end

-- UTF-16 offset of byte offset off; code points above U+FFFF count 2.
function M.to_utf16(text: string, off: number): number
	local n = 0
	for i = 1, math.min(off, #text) do
		local b = byte(text, i)
		if not is_cont(b) then
			n += 1
			if b >= 0xF0 then
				n += 1
			end
		end
	end
	return n
end

function M.utf16_len(text: string): number
	return M.to_utf16(text, #text)
end

-- Text with the UTF-16 range from16..to16 replaced by s.
function M.apply_edit(text: string, from16: number, to16: number, s: string): string
	local a = M.to_bytes(text, from16)
	local b = math.max(a, M.to_bytes(text, to16))
	return sub(text, 1, a) .. s .. sub(text, b + 1)
end

return M
