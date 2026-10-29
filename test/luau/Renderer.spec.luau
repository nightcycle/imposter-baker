--!strict
-- Run in Studio with editable assets enabled. All instances remain unparented.
local Package = require(game:GetService("ReplicatedStorage").ImposterRender)

return function()
	local assetService = game:GetService("AssetService")
	local container = Instance.new("Folder")
	local source: EditableImage? = assetService:CreateEditableImage({ Size = Vector2.new(40, 20) })
	assert(source, "enable editable assets to run this integration test")
	source:DrawRectangle(Vector2.zero, source.Size, Color3.new(0, 1, 0), 0, Enum.ImageCombineType.Overwrite)
	local enabledLayers: { Package.Layer } = { "color" }
	local options: Package.Options = {
		parent = container,
		layers = enabledLayers,
		updateBudget = { targetFps = 60, maxMilliseconds = 16 },
		limits = { maxTextureSize = 128, maxInstances = 2 },
	}
	local renderer, createError = Package.new(options)
	assert(renderer, createError)
	local ok, message = renderer:register(
		"cube",
		{ color = Content.fromObject(source) },
		{ panShotCount = 2, maxResolutionPx = 16 }
	)
	assert(ok, message)
	assert(not renderer:register("cube", { color = Content.fromObject(source) }))
	local a, err = renderer:add("cube", CFrame.new(-3, 0, 0), Vector3.one)
	assert(a, err)
	local b, err2 = renderer:add("cube", CFrame.new(3, 0, 0), Vector3.one)
	assert(b, err2)
	assert(renderer:add("cube", CFrame.identity, Vector3.one) == nil)
	assert(renderer:getUsage().editableMeshes == 1)
	assert(renderer:getUsage().editableImages == 1)
	assert(renderer:getUsage().instances == 2)
	renderer:update(CFrame.new(0, 0, 20), 70, 0)
	assert(renderer:getUsage().updatedInstances == 0 and renderer:getUsage().pendingInstances == 2)
	renderer:update(CFrame.new(0, 0, 20), 70)
	assert(renderer:getUsage().updatedInstances == 2 and renderer:getUsage().pendingInstances == 0)
	local function positionSum(): Vector3
		local sum = Vector3.zero
		for _, vertex in renderer.mesh:GetVertices() do
			sum += renderer.mesh:GetPosition(vertex)
		end
		return sum
	end
	local initial = positionSum()
	renderer:update(CFrame.new(0, 0, 21), 70)
	assert((positionSum() - initial).Magnitude < 1e-5, "same capture must keep geometry fixed")
	a:update(CFrame.new(-4, 0, 0), Vector3.one * 2)
	renderer:update(CFrame.new(0, 0, 21), 70)
	assert(
		(positionSum() - initial - Vector3.new(-4, 0, 0)).Magnitude < 1e-4,
		"bounds changes must invalidate cached geometry"
	)
	local moved = positionSum()
	renderer:setUpdateBudget({ targetFps = 240, maxMilliseconds = 0 })
	renderer.part.CFrame = CFrame.new(1, 0, 0)
	renderer:update(CFrame.new(0, 0, 21), 70)
	assert(positionSum() == moved, "zero budget must defer writes")
	renderer:setUpdateBudget({ targetFps = 60, maxMilliseconds = 16 })
	renderer:update(CFrame.new(0, 0, 21), 70)
	assert(
		(positionSum() - moved + Vector3.new(8, 0, 0)).Magnitude < 1e-4,
		"batch movement must preserve world-space bounds"
	)
	renderer:update(CFrame.new(0, 4, -20), 55)
	assert(not renderer:unregister("cube"))
	a:destroy()
	a:destroy()
	b:destroy()
	assert(renderer:unregister("cube"))
	assert(renderer:getUsage().models == 0)
	local wrongSize = renderer:register("wrong", { color = Content.fromObject(source) })
	assert(not wrongSize and renderer:getUsage().models == 0)
	local okAgain, againError = renderer:register(
		"again",
		{ color = Content.fromObject(source) },
		{ panShotCount = 2, maxResolutionPx = 16 }
	)
	assert(okAgain, againError)
	assert(renderer:setLimits({ maxInstances = 1 }))
	assert(not renderer:setLimits({ maxTextureSize = 256 }))
	renderer:destroy()
	renderer:destroy()
	assert(renderer:getUsage().editableImages == 0 and renderer:getUsage().editableMeshes == 0)

	local pbrOptions: Package.Options = {
		parent = container,
		limits = { maxTextureSize = 128, maxInstances = 2 },
		updateBudget = { targetFps = 60, maxMilliseconds = 16 },
	}
	local pbr, pbrError = Package.new(pbrOptions)
	assert(pbr, pbrError)
	local tile: EditableImage? = assetService:CreateEditableImage({ Size = Vector2.new(20, 20) })
	assert(tile)
	tile:DrawRectangle(Vector2.zero, tile.Size, Color3.new(1, 0, 0), 0, Enum.ImageCombineType.Overwrite)
	local content = Content.fromObject(source)
	local tileContent = Content.fromObject(tile)
	local tileMap: { [string]: Package.ImageContent } = { shot_0000 = tileContent, shot_0001 = tileContent }
	local sources: Package.Sources = {
		color = tileMap,
		normal = content,
		roughness = content,
		metalness = content,
		emissive = content,
	}
	local loaded, loadError = pbr:register("pbr", sources, { panShotCount = 2, maxResolutionPx = 16 })
	assert(loaded, loadError)
	assert(pbr:getUsage().editableImages == 5 and #pbr.mesh:GetVertices() == 14)
	local near, nearError = pbr:add("pbr", CFrame.new(0, 0, -3), Vector3.one)
	local far, farError = pbr:add("pbr", CFrame.new(0, 0, 3), Vector3.one)
	assert(near, nearError)
	assert(far, farError)
	pbr:update(CFrame.identity, 70)
	-- Attribute IDs are stable but their enumeration order is not a contract.
	local hasFirst = false
	local hasSecond = false
	for _, uvId in pbr.mesh:GetUVs() do
		local uv = pbr.mesh:GetUV(uvId)
		if uv then
			hasFirst = hasFirst or uv.X == 2 / 128
			hasSecond = hasSecond or uv.X == 22 / 128
		end
	end
	assert(hasFirst and hasSecond, "instances must select independent shot UVs")
	local pixels = pbr.images.color:ReadPixelsBuffer(Vector2.new(2, 2), Vector2.one)
	assert(buffer.readu8(pixels, 0) == 255 and buffer.readu8(pixels, 1) == 0)
	near:destroy()
	far:destroy()
	pbr:destroy()
	tile:Destroy()
	source:Destroy()
	container:Destroy()
	print("Renderer shared resources, allocation limits, cleanup, and rollback passed")
end
