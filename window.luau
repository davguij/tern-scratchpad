--!strict
-- The window half: palette commands.

tern.command({
	id = "hello",
	title = "Say hello",
	icon = "sparkle",
	run = function(cx)
		local how = if tern.runtime.jit then "native code" else "the interpreter"
		cx:toast("info", "Hello from " .. tern.plugin.name, "running on " .. how)
	end,
})

tern.command({
	id = "open",
	title = "Open Scratchpad",
	icon = "edit",
	keys = { "cmd+alt+j" },
	run = function(cx)
		cx:new_block("scratchpad.notes")
	end,
})
