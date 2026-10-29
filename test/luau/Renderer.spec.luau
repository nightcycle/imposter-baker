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
		Parent = container,
		Layers = enabledLayers,
		UpdateBudget = { TargetFps = 60, MaxMilliseconds = 16 },
		Limits = { MaxTextureSize = 128, MaxInstances = 2 },
	}
	local renderer, createError = Package.New(options)
	assert(renderer, createError)
	local ok, message = renderer:Register(
		"cube",
		{ Color = Content.fromObject(source) },
		{ PanShotCount = 2, MaxResolutionPx = 16 }
	)
	assert(ok, message)
	assert(not renderer:Register("cube", { Color = Content.fromObject(source) }))
	local a, err = renderer:Add("cube", CFrame.new(-3, 0, 0), Vector3.one)
	assert(a, err)
	local b, err2 = renderer:Add("cube", CFrame.new(3, 0, 0), Vector3.one)
	assert(b, err2)
	assert(renderer:Add("cube", CFrame.identity, Vector3.one) == nil)
	assert(renderer:GetUsage().EditableMeshes == 1)
	assert(renderer:GetUsage().EditableImages == 1)
	assert(renderer:GetUsage().Instances == 2)
	renderer:Update(CFrame.new(0, 0, 20), 70, 0)
	assert(renderer:GetUsage().UpdatedInstances == 0 and renderer:GetUsage().PendingInstances == 2)
	renderer:Update(CFrame.new(0, 0, 20), 70)
	assert(renderer:GetUsage().UpdatedInstances == 2 and renderer:GetUsage().PendingInstances == 0)
	local function positionSum(): Vector3
		local sum = Vector3.zero
		for _, vertex in renderer.Mesh:GetVertices() do
			sum += renderer.Mesh:GetPosition(vertex)
		end
		return sum
	end
	local initial = positionSum()
	renderer:Update(CFrame.new(0, 0, 21), 70)
	assert((positionSum() - initial).Magnitude < 1e-5, "same capture must keep geometry fixed")
	a:Update(CFrame.new(-4, 0, 0), Vector3.one * 2)
	renderer:Update(CFrame.new(0, 0, 21), 70)
	assert(
		(positionSum() - initial - Vector3.new(-4, 0, 0)).Magnitude < 1e-4,
		"Bounds changes must Invalidate Cached geometry"
	)
	local moved = positionSum()
	renderer:SetUpdateBudget({ TargetFps = 240, MaxMilliseconds = 0 })
	renderer.Part.CFrame = CFrame.new(1, 0, 0)
	renderer:Update(CFrame.new(0, 0, 21), 70)
	assert(positionSum() == moved, "zero Budget must defer writes")
	renderer:SetUpdateBudget({ TargetFps = 60, MaxMilliseconds = 16 })
	renderer:Update(CFrame.new(0, 0, 21), 70)
	assert(
		(positionSum() - moved + Vector3.new(8, 0, 0)).Magnitude < 1e-4,
		"batch movement must preserve world-space Bounds"
	)
	renderer:Update(CFrame.new(0, 4, -20), 55)
	assert(not renderer:Unregister("cube"))
	a:Destroy()
	a:Destroy()
	b:Destroy()
	assert(renderer:Unregister("cube"))
	assert(renderer:GetUsage().Models == 0)
	local wrongSize = renderer:Register("wrong", { Color = Content.fromObject(source) })
	assert(not wrongSize and renderer:GetUsage().Models == 0)
	local okAgain, againError = renderer:Register(
		"again",
		{ Color = Content.fromObject(source) },
		{ PanShotCount = 2, MaxResolutionPx = 16 }
	)
	assert(okAgain, againError)
	assert(renderer:SetLimits({ MaxInstances = 1 }))
	assert(not renderer:SetLimits({ MaxTextureSize = 256 }))
	renderer:Destroy()
	renderer:Destroy()
	assert(renderer:GetUsage().EditableImages == 0 and renderer:GetUsage().EditableMeshes == 0)

	local pbrOptions: Package.Options = {
		Parent = container,
		Limits = { MaxTextureSize = 128, MaxInstances = 2 },
		UpdateBudget = { TargetFps = 60, MaxMilliseconds = 16 },
	}
	local pbr, pbrError = Package.New(pbrOptions)
	assert(pbr, pbrError)
	local tile: EditableImage? = assetService:CreateEditableImage({ Size = Vector2.new(20, 20) })
	assert(tile)
	tile:DrawRectangle(Vector2.zero, tile.Size, Color3.new(1, 0, 0), 0, Enum.ImageCombineType.Overwrite)
	local content = Content.fromObject(source)
	local tileContent = Content.fromObject(tile)
	local tileMap: { [string]: Package.ImageContent } = { shot_0000 = tileContent, shot_0001 = tileContent }
	local sources: Package.Sources = {
		Color = tileMap,
		Normal = content,
		Roughness = content,
		Metalness = content,
		Emissive = content,
	}
	local loaded, loadError = pbr:Register("pbr", sources, { PanShotCount = 2, MaxResolutionPx = 16 })
	assert(loaded, loadError)
	assert(pbr:GetUsage().EditableImages == 5 and #pbr.Mesh:GetVertices() == 14)
	local near, nearError = pbr:Add("pbr", CFrame.new(0, 0, -3), Vector3.one)
	local far, farError = pbr:Add("pbr", CFrame.new(0, 0, 3), Vector3.one)
	assert(near, nearError)
	assert(far, farError)
	pbr:Update(CFrame.identity, 70)
	-- Attribute IDs are stable but their enumeration order is not a contract.
	local hasFirst = false
	local hasSecond = false
	for _, uvId in pbr.Mesh:GetUVs() do
		local uv = pbr.Mesh:GetUV(uvId)
		if uv then
			hasFirst = hasFirst or uv.X == 2 / 128
			hasSecond = hasSecond or uv.X == 22 / 128
		end
	end
	assert(hasFirst and hasSecond, "Instances must select independent shot UVs")
	local pixels = pbr.Images["color"]:ReadPixelsBuffer(Vector2.new(2, 2), Vector2.one)
	assert(buffer.readu8(pixels, 0) == 255 and buffer.readu8(pixels, 1) == 0)
	near:Destroy()
	far:Destroy()
	pbr:Destroy()
	tile:Destroy()
	source:Destroy()
	container:Destroy()
	print("Renderer shared resources, allocation Limits, cleanup, and rollback passed")
end
