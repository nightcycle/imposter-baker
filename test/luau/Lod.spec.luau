--!strict
local Lod = require(game:GetService("ReplicatedStorage").ImposterRender.Lod)

return function()
	local config = Lod.Resolve({ NearDistance = 20, FarDistance = 24, ReplacementMargin = 2 })
	assert(Lod.Distance(Vector3.new(3, 0, 4), Vector3.zero) == 5)
	assert(Lod.ShouldReplace(8, 11, config))
	assert(not Lod.ShouldReplace(9, 11, config), "equal boundary must not churn")
	assert(not Lod.ShouldReplace(21, 40, config), "outside promotion Distance stays an imposter")
	assert(Lod.Resolve({ MaxRealInstances = 0, MaxCreatesPerFrame = 0 }).MaxRealInstances == 0)
	for _, value in { -1, math.huge, 0 / 0 } do
		assert(not pcall(Lod.Resolve, { NearDistance = value }))
	end
	assert(not pcall(Lod.Resolve, { NearDistance = 30, FarDistance = 20 }))
	assert(not pcall(Lod.Resolve, { MaxRealInstances = 1.5 }))
	assert(not pcall(Lod.Resolve, { MaxTransitionsPerFrame = 1 }))
	print("LOD Distance, replacement hysteresis, disable options, and validation passed")
end
