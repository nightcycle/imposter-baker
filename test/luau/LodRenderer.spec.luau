--!strict
local Package = require(game:GetService("ReplicatedStorage").ImposterRender)

return function()
	local world = Instance.new("WorldModel")
	local source = game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(40, 20) })
	assert(source)
	source:DrawRectangle(Vector2.zero, source.Size, Color3.new(1, 1, 1), 0, Enum.ImageCombineType.Overwrite)
	local layers: { Package.Layer } = { "color" }
	local options: Package.Options = {
		Parent = world,
		Layers = layers,
		Limits = { MaxTextureSize = 64, MaxInstances = 3 },
		UpdateBudget = { TargetFps = 60, MaxMilliseconds = 16 },
		Lod = {
			NearDistance = 20,
			FarDistance = 24,
			ReplacementMargin = 2,
			MaxRealInstances = 1,
			MaxTransitionsPerFrame = 2,
			MaxCreatesPerFrame = 0,
		},
		InstanceCache = {
			WorldRoot = world :: WorldRoot,
			MaxInstances = 2,
			MaxPartsPerInstance = 1,
			MaxPartsPerFlush = 2,
		},
	}
	local renderer, err = Package.New(options)
	assert(renderer, err)
	assert(
		renderer:Register("cube", { Color = Content.fromObject(source) }, { PanShotCount = 2, MaxResolutionPx = 16 })
	)
	local template = Instance.new("Part")
	template.CFrame = CFrame.new(80, 5, 50)
	template.Size = Vector3.one
	assert(renderer:RegisterTemplate("cube", template))
	assert(renderer:Prewarm("cube", 1) == 1)
	local a = renderer:Add("cube", CFrame.new(0, 0, 5), Vector3.one)
	local b = renderer:Add("cube", CFrame.new(0, 0, 15), Vector3.one)
	local c = renderer:Add("cube", CFrame.new(0, 0, 40), Vector3.one)
	assert(a and b and c)
	local function settle(camera: CFrame)
		for _ = 1, 50 do
			renderer:Update(camera, 70)
			if renderer:GetUsage().PendingInstances == 0 then
				return
			end
		end
		error("LOD did not settle with a stationary Camera")
	end
	settle(CFrame.identity)
	local real = a:GetRealInstance()
	assert(real and not b:GetRealInstance() and not c:GetRealInstance(), "nearest must claim the limited real slot")
	local sum = Vector3.zero
	for _, vertex in renderer.Mesh:GetVertices() do
		sum += renderer.Mesh:GetPosition(vertex)
	end
	assert((sum - Vector3.new(0, 0, 220)).Magnitude < 1e-3, "the promoted quad must be hidden")
	settle(CFrame.new(0, 0, 19))
	assert(not a:GetRealInstance() and b:GetRealInstance() == real, "a nearer Instance must reuse the farthest clone")
	renderer:Update(CFrame.new(0, 0, 50), 70, 0)
	assert(b:GetRealInstance() == real and renderer:GetUsage().BulkMovedParts == 0, "zero headroom must defer swaps")
	a:SetLodEnabled(false)
	settle(CFrame.new(0, 0, -7))
	assert(b:GetRealInstance() == real, "Active real Models persist in the hysteresis band")
	settle(CFrame.new(0, 0, -10))
	assert(not b:GetRealInstance() and real.Parent == nil, "crossing the far Distance returns the clone to cache")
	a:SetLodEnabled(true)
	renderer:SetLodOptions({ NearDistance = 20, FarDistance = 24, MaxRealInstances = 2, MaxCreatesPerFrame = 0 })
	assert(renderer:Prewarm("cube", 2) == 2)
	settle(CFrame.identity)
	assert(a:GetRealInstance() and b:GetRealInstance() and renderer:GetUsage().RealInstances == 2)
	local moving = a:GetRealInstance()
	a:Update(CFrame.new(4, 0, 5), Vector3.one * 2)
	settle(CFrame.identity)
	assert(a:GetRealInstance() == moving)
	local part = (moving :: Model):FindFirstChildWhichIsA("BasePart", true) :: BasePart
	assert(part.Position == Vector3.new(4, 0, 5) and part.Size == Vector3.one * 2)
	a:Update(CFrame.new(4, 0, 5), Vector3.new(2, 1, 1))
	settle(CFrame.identity)
	assert(not a:GetRealInstance(), "nonuniform sizes must fall back to their imposter")
	renderer:SetLodOptions({ MaxRealInstances = 0 })
	settle(CFrame.identity)
	assert(renderer:GetUsage().RealInstances == 0)
	assert(renderer:UnregisterTemplate("cube"))
	a:Destroy()
	b:Destroy()
	c:Destroy()
	assert(renderer:Unregister("cube"))
	renderer:Destroy()
	assert(renderer:GetUsage().CachedInstances == 0)
	-- A cold pool spreads cloning and promotions over frames, even if the
	-- camera stays still. Bulk move limits apply to whole models.
	local coldOptions: Package.Options = {
		Parent = world,
		Layers = layers,
		Limits = { MaxTextureSize = 64, MaxInstances = 3 },
		UpdateBudget = { TargetFps = 60, MaxMilliseconds = 16 },
		Lod = { MaxRealInstances = 3, MaxTransitionsPerFrame = 2, MaxCreatesPerFrame = 1 },
		InstanceCache = {
			WorldRoot = world :: WorldRoot,
			MaxInstances = 3,
			MaxPartsPerInstance = 1,
			MaxPartsPerFlush = 1,
		},
	}
	local cold, coldError = Package.New(coldOptions)
	assert(cold, coldError)
	assert(cold:Register("cube", { Color = Content.fromObject(source) }, { PanShotCount = 2, MaxResolutionPx = 16 }))
	assert(cold:RegisterTemplate("cube", template))
	local nearest: Package.Handle? = nil
	for _, z in { 7, 6, 5 } do
		nearest = cold:Add("cube", CFrame.new(0, 0, z), Vector3.one)
	end
	assert(nearest)
	for frame = 1, 3 do
		cold:Update(CFrame.identity, 70)
		local usage = cold:GetUsage()
		assert(usage.RealInstances == frame and usage.CachedInstances == frame)
		assert(usage.BulkMovedParts == 1 and usage.LodTransitions == 1)
		assert(nearest:GetRealInstance(), "nearest must claim the first cold-cache allocation")
	end
	cold:SetLodOptions({ MaxRealInstances = 0, MaxTransitionsPerFrame = 2 })
	cold:Update(CFrame.identity, 70)
	assert(cold:GetUsage().RealInstances == 1 and cold:GetUsage().LodTransitions == 2)
	cold:Update(CFrame.identity, 70)
	assert(cold:GetUsage().RealInstances == 0)
	cold:Destroy()
	template:Destroy()
	source:Destroy()
	world:Destroy()
	print("LOD nearest replacement, hysteresis, zero Budget, visibility, movement, and fallback passed")
end
