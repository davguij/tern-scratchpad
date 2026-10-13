--!strict
-- The window half: a palette command.

tern.command({
	id = "hello",
	title = "Say hello",
	icon = "sparkle",
	run = function(cx)
		local how = if tern.runtime.jit then "native code" else "the interpreter"
		cx:toast("info", "Hello from " .. tern.plugin.name, "running on " .. how)
	end,
})
