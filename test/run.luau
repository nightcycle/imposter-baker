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
}
local modules = {}
for _, name in { "Util", "Limits", "Atlas" } do
	modules[name] =
		luau.load(fs.readFile(`imposter-render/src/{name}.luau`), { debugName = name, environment = globals })()
end
local testGlobals = table.clone(globals)
testGlobals.game = {
	GetService = function()
		return { ImposterRender = { Util = "Util", Limits = "Limits", Atlas = "Atlas" } }
	end,
}
testGlobals.require = function(name: string)
	return modules[name]
end
local test =
	luau.load(fs.readFile("test/luau/Util.spec.luau"), { debugName = "Util.spec", environment = testGlobals })()
test()
