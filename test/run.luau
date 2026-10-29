--!strict
-- The pure runtime modules are executed unchanged with Lune's Roblox datatypes.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local globals = {
	Vector2 = roblox.Vector2,
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	NumberRange = roblox.NumberRange,
	Instance = roblox.Instance,
}
local modules = {}
for _, name in { "Util", "Limits", "Atlas", "Scheduler" } do
	modules[name] =
		luau.load(fs.readFile(`imposter-render/src/{name}.luau`), { debugName = name, environment = globals })()
end
local testGlobals = table.clone(globals)
testGlobals.game = {
	GetService = function()
		return { ImposterRender = { Util = "Util", Limits = "Limits", Atlas = "Atlas", Scheduler = "Scheduler" } }
	end,
}
testGlobals.require = function(name: string)
	return modules[name]
end
for _, name in { "Util", "Scheduler" } do
	local test =
		luau.load(fs.readFile(`test/luau/{name}.spec.luau`), { debugName = `{name}.spec`, environment = testGlobals })()
	test()
end
