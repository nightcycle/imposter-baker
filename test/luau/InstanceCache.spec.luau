--!strict
-- Studio integration test: the WorldModel and templates remain outside the DataModel.
local InstanceCache = require(game:GetService("ReplicatedStorage").ImposterRender.InstanceCache)

return function()
	local world = Instance.new("WorldModel")
	local template = Instance.new("Model")
	local bounds = CFrame.new(100, 5, 200) * CFrame.Angles(0, 0.7, 0)
	for index, x in { -2, 2 } do
		local part = Instance.new("Part")
		part.Name = tostring(index)
		part.Size = Vector3.one
		part.CFrame = bounds * CFrame.new(x, 0, 0)
		part.Parent = template
		local attachment = Instance.new("Attachment")
		attachment.Position = Vector3.yAxis
		attachment.Parent = part
	end
	local scriptCopy = Instance.new("Script")
	scriptCopy.Parent = template
	template.WorldPivot = CFrame.new(-30, 2, -10)
	local size = Vector3.new(5, 1, 1)
	local cache = InstanceCache.New({
		WorldRoot = world :: WorldRoot,
		MaxInstances = 3,
		MaxPartsPerInstance = 2,
		MaxPartsPerFlush = 4,
	})
	assert(cache:Register("pair", template, { BoundingBoxCFrame = bounds, BoundingBoxSize = size }))
	assert(cache:Prewarm("pair", 2) == 2)
	assert(cache:GetUsage().Cached == 2 and #cache.Folder:GetChildren() == 0)
	assert(scriptCopy.Parent == template and not (template:FindFirstChild("1") :: BasePart).Anchored)
	local a = cache:Acquire("pair", false)
	local b = cache:Acquire("pair", false)
	assert(a and b and a.Instance ~= b.Instance)
	assert(not a.Instance:FindFirstChildWhichIsA("LuaSourceContainer", true))
	local target = CFrame.new(7, 8, 9) * CFrame.Angles(0.2, -0.4, 0.3)
	assert(cache:Queue(a, CFrame.identity, size * 2))
	assert(cache:Queue(a, target, size * 2))
	assert(cache:Queue(b, CFrame.new(0, 0, 50), size * 0.5))
	assert(cache:GetUsage().QueuedParts == 4 and a.Instance.Parent == nil)
	assert(cache:Flush())
	assert(cache:GetUsage().MovedParts == 4 and a.Instance.Parent == cache.Folder)
	for index, part in a.Parts do
		local offset = a.Offsets[index]
		local expected = target * (offset.Rotation + offset.Position * 2)
		assert((part.Position - expected.Position).Magnitude < 1e-4)
		assert(part.CFrame.LookVector:Dot(expected.LookVector) > 0.99999)
		assert((part.Size - Vector3.one * 2).Magnitude < 1e-5)
		assert((part:FindFirstChildWhichIsA("Attachment") :: Attachment).Position == Vector3.yAxis * 2)
		assert(part.Anchored and not part.CanCollide and not part.CanQuery)
	end
	assert(not cache:Unregister("pair"))
	cache:Release(a)
	assert(a.Instance.Parent == nil)
	cache:Release(a) -- idempotent
	local reused = cache:Acquire("pair", false)
	assert(reused == a and cache:GetUsage().ClonesCreated == 2)
	assert(cache:Queue(a, CFrame.new(0, 10, 0), size))
	cache:Release(a) -- cancel a pending move, then reuse that same lease
	local again = cache:Acquire("pair", false)
	assert(again == a)
	assert(cache:Queue(a, target, size))
	assert(cache:Queue(b, CFrame.identity, size))
	local c = cache:Acquire("pair")
	assert(c and cache:GetUsage().Cached == 3)
	assert(cache:Acquire("pair") == nil, "cache must obey its hard Instance limit")
	assert(not cache:Queue(c, target, size), "bulk part cap must defer a whole model")
	assert(cache:Flush() and cache:GetUsage().MovedParts == 4)
	assert(not cache:Queue(c, target, Vector3.one), "nonuniform scaling must be rejected")
	for _, lease in { a, b, c } do
		cache:Release(lease)
	end
	assert(cache:Unregister("pair") and cache:GetUsage().Cached == 0)
	assert(cache:Register("first", template))
	assert(cache:Prewarm("first", 3) == 3)
	assert(cache:Register("second", template, { CanCollide = true, CanQuery = true }))
	assert(cache:Prewarm("second", 1) == 1 and cache:GetUsage().Cached == 3, "new pools must reclaim idle Capacity")
	local collidable = cache:Acquire("second", false)
	local noncollidable = cache:Acquire("first", false)
	assert(collidable and noncollidable)
	for _, part in collidable.Parts do
		assert(part.CanCollide and part.CanQuery)
	end
	for _, part in noncollidable.Parts do
		assert(not part.CanCollide and not part.CanQuery)
	end
	cache:Destroy()
	cache:Destroy()
	assert(cache:GetUsage().Cached == 0)
	template:Destroy()
	world:Destroy()
	print("Instance cache reuse, scaling, bulk placement, cancellation, caps, and cleanup passed")
end
