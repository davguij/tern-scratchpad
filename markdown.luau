--!strict
-- Shared pure module, no Tern API: Markdown span scanner for live styling.
--
-- scan(text) returns decoration spans over the raw note text. Offsets are
-- 0-based UTF-8 byte offsets over `text`: `from` is inclusive, `to` is
-- exclusive. Spans are sorted by `from` and never overlap. Tokens:
--   dim            delimiters and markers (`**`, `` ` ``, `# `, `- `, `[`, `](url)`, fences)
--   strong         bold content
--   em             italic content
--   code           inline code content, and fenced code body
--   link           link text
--   strong accent  heading text
-- Unclosed or unsupported constructs produce no spans. Nested emphasis
-- (`**a *b* c**`) produces no spans for the outer construct, and emphasis
-- containing inline code produces none either.

export type Span = { from: number, to: number, token: string }

type Pair = { number }

local find, sub, match = string.find, string.sub, string.match

-- Returns the inline code range (1-based inclusive backtick pair) containing i, or nil.
local function code_at(codes: { Pair }, i: number): Pair?
	for _, cr in codes do
		if i >= cr[1] and i <= cr[2] then
			return cr
		end
	end
	return nil
end

-- Next plain occurrence of pat at or after from that does not start inside inline code.
local function find_free(s: string, pat: string, from: number, codes: { Pair }): number?
	local o = find(s, pat, from, true)
	while o ~= nil do
		local cr = code_at(codes, o)
		if cr == nil then
			return o
		end
		o = find(s, pat, cr[2] + 1, true)
	end
	return nil
end

-- True when a code span starts within the 1-based inclusive range [a, b].
local function has_code(codes: { Pair }, a: number, b: number): boolean
	for _, cr in codes do
		if cr[1] >= a and cr[1] <= b then
			return true
		end
	end
	return false
end

local function is_space(c: string): boolean
	return c == " " or c == "\t"
end

-- Inline spans in s. base is the 0-based byte offset of s's first byte.
-- Pass 1 pairs backticks into code spans; pass 2 scans emphasis and links
-- outside those code spans, left to right.
local function inline(s: string, base: number, out: { Span })
	local codes: { Pair } = {}
	local n = #s

	-- a, b are 1-based inclusive indices into s.
	local function emit(a: number, b: number, token: string)
		table.insert(out, { from = base + a - 1, to = base + b, token = token })
	end

	local p = 1
	while true do
		local o = find(s, "`", p, true)
		if o == nil then
			break
		end
		local c = find(s, "`", o + 1, true)
		if c == nil then
			break
		end
		if c == o + 1 then
			-- "``" is not a code span; the second backtick may open one.
			p = c
		else
			table.insert(codes, { o, c })
			emit(o, o, "dim")
			emit(o + 1, c - 1, "code")
			emit(c, c, "dim")
			p = c + 1
		end
	end

	p = 1
	while p <= n do
		local cr = code_at(codes, p)
		if cr ~= nil then
			p = cr[2] + 1
		elseif sub(s, p, p + 1) == "**" then
			local q = find_free(s, "**", p + 2, codes)
			if q == nil or q == p + 2 then
				p = p + 2
			else
				local a, b = p + 2, q - 1
				if is_space(sub(s, a, a)) or is_space(sub(s, b, b)) then
					p = p + 2
				elseif find(sub(s, a, b), "*", 1, true) ~= nil or has_code(codes, a, b) then
					-- Nested emphasis or code inside bold: no spans for this construct.
					p = q + 2
				else
					emit(p, p + 1, "dim")
					emit(a, b, "strong")
					emit(q, q + 1, "dim")
					p = q + 2
				end
			end
		elseif sub(s, p, p) == "*" then
			local q = find_free(s, "*", p + 1, codes)
			if
				q ~= nil
				and not is_space(sub(s, p + 1, p + 1))
				and not is_space(sub(s, q - 1, q - 1))
				and sub(s, q + 1, q + 1) ~= "*"
				and not has_code(codes, p + 1, q - 1)
			then
				emit(p, p, "dim")
				emit(p + 1, q - 1, "em")
				emit(q, q, "dim")
				p = q + 1
			else
				p = p + 1
			end
		elseif sub(s, p, p) == "[" then
			local r = find_free(s, "]", p + 1, codes)
			local t: number? = nil
			if r ~= nil and sub(s, r + 1, r + 1) == "(" then
				t = find_free(s, ")", r + 2, codes)
			end
			if
				r ~= nil
				and t ~= nil
				and r > p + 1
				and t > r + 2
				and find(sub(s, p + 1, r - 1), "[", 1, true) == nil
				and not has_code(codes, p, t)
			then
				emit(p, p, "dim")
				emit(p + 1, r - 1, "link")
				emit(r, t, "dim")
				p = t + 1
			else
				p = p + 1
			end
		else
			p = p + 1
		end
	end
end

-- One line outside a fence. off is the 0-based offset of the line's first byte.
local function scan_line(line: string, off: number, out: { Span })
	local hashes = match(line, "^(#+)[ \t]")
	if hashes ~= nil and #hashes <= 6 then
		local mlen = #(match(line, "^#+[ \t]+") or "")
		table.insert(out, { from = off, to = off + mlen, token = "dim" })
		if mlen < #line then
			table.insert(out, { from = off + mlen, to = off + #line, token = "strong accent" })
		end
		return
	end

	local lead, mk = match(line, "^([ \t]*)([%-%*][ \t]+)")
	if lead == nil then
		lead, mk = match(line, "^([ \t]*)(%d+%.[ \t]+)")
	end
	if lead ~= nil and mk ~= nil then
		local a = #lead + #mk
		table.insert(out, { from = off + #lead, to = off + a, token = "dim" })
		inline(sub(line, a + 1), off + a, out)
		return
	end

	inline(line, off, out)
end

local function scan(text: string): { Span }
	local out: { Span } = {}
	local n = #text
	local fence = false
	-- 0-based body range of the current fence; -1 until the first body line.
	local body_from = -1
	local body_to = -1

	local start = 1
	while start <= n do
		local nl = find(text, "\n", start, true)
		local stop = (nl or n + 1) - 1
		local line = sub(text, start, stop)
		local off = start - 1
		local lto = off + #line

		if fence then
			if find(line, "^[ \t]*```[ \t]*$") ~= nil then
				if body_to > body_from then
					table.insert(out, { from = body_from, to = body_to, token = "code" })
				end
				table.insert(out, { from = off, to = lto, token = "dim" })
				fence = false
			else
				if body_from < 0 then
					body_from = off
				end
				body_to = lto
			end
		elseif find(line, "^[ \t]*```") ~= nil then
			fence = true
			body_from = -1
			body_to = -1
			table.insert(out, { from = off, to = lto, token = "dim" })
		else
			scan_line(line, off, out)
		end

		start = stop + 2
	end

	-- An unclosed fence styles its body to the end of the text.
	if fence and body_from >= 0 and n > body_from then
		table.insert(out, { from = body_from, to = n, token = "code" })
	end

	table.sort(out, function(x, y)
		return x.from < y.from
	end)
	return out
end

return { scan = scan }

--[[
Hand-traced cases from the plan (U2 test scenarios). Not executed; traced
against the logic above.

- "**done"            -> {}. Pass 2: "**" at 1 has no closing "**"; p=3, no further openers.
- "**done**"          -> dim [0,2), strong [2,6), dim [6,8). q=7, body "done" has no space edge, "*", or code.
- "*a*"               -> dim [0,1), em [1,2), dim [2,3).
- "`x`"               -> dim [0,1), code [1,2), dim [2,3). Pass 2 skips the code range.
- "[t](u)"            -> dim [0,1), link [1,2), dim [2,6). r=3, t=6, url "u" nonempty.
- "# Title"           -> dim [0,2), strong accent [2,7).
- "- item"            -> dim [0,2) for "- ". Rest "item" has no inline spans.
- "```\ncode\n```"    -> dim [0,3), code [4,8), dim [9,12).
- "```\nabc"          -> dim [0,3), code [4,7) to end of text (unclosed).
- "**a *b* c**"       -> {}. Body contains "*", so the whole bold construct is skipped.
- ""                  -> {}. The loop never runs.
- "*"                 -> {}. No closing "*", literal.
- "**done" + "**" typed later as "**done**" -> the previous case, now styled.
]]
