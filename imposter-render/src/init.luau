--!strict
local AssetService = game:GetService("AssetService")
local Util = require(script.Util)
local Limits = require(script.Limits)
local Atlas = require(script.Atlas)

local ImposterRender = { Util = Util, Limits = Limits, Atlas = Atlas }

export type Layout = Util.Layout
export type LayoutInput = Util.LayoutInput
export type Shot = Util.Shot
export type Solution = Util.Solution
export type LimitOptions = Limits.Options
export type Budget = Limits.Budget
export type Layer = "color" | "normal" | "roughness" | "metalness" | "emissive"
export type ImageContent = Content | string
export type Source = ImageContent | { [string]: ImageContent }
export type Sources = {
	color: Source,
	normal: Source?,
	roughness: Source?,
	metalness: Source?,
	emissive: Source?,
}
export type Options = {
	limits: LimitOptions?,
	parent: Instance?,
	origin: CFrame?,
	layers: { Layer }?,
	emissiveStrength: number?,
	emissiveTint: Color3?,
}
export type Usage = {
	models: number,
	instances: number,
	editableMeshes: number,
	editableImages: number,
	texturePixels: number,
	reservedTransientPixels: number,
}
export type Handle = {
	update: (self: Handle, boundingBoxCFrame: CFrame, boundingBoxSize: Vector3) -> (),
	destroy: (self: Handle) -> (),
}
export type Renderer = {
	mesh: EditableMesh,
	part: MeshPart,
	images: { [string]: EditableImage },
	limits: Budget,
	register: (self: Renderer, id: string, sources: Sources, layout: LayoutInput?) -> (boolean, string?),
	unregister: (self: Renderer, id: string) -> (boolean, string?),
	add: (self: Renderer, id: string, boundingBoxCFrame: CFrame, boundingBoxSize: Vector3) -> (Handle?, string?),
	update: (self: Renderer, cameraCFrame: CFrame, verticalFieldOfView: number) -> (),
	setLimits: (self: Renderer, options: LimitOptions) -> (boolean, string?),
	getUsage: (self: Renderer) -> Usage,
	destroy: (self: Renderer) -> (),
}

type ModelEntry = {
	layout: Layout,
	shots: { Shot },
	rect: Atlas.Rect,
	references: number,
}
type Quad = { vertices: { number }, uvs: { number }, normal: number }
type InstanceEntry = { id: string, cframe: CFrame, size: Vector3, slot: number }

local DEFAULT_LAYERS: { Layer } = { "color", "normal", "roughness", "metalness", "emissive" }
local MAP_NAMES: { [string]: string } = {
	color = "ColorMap",
	normal = "NormalMap",
	roughness = "RoughnessMap",
	metalness = "MetalnessMap",
	emissive = "EmissiveMask",
}
local DEFAULT_COLORS: { [string]: Color3 } = {
	color = Color3.new(1, 1, 1),
	normal = Color3.new(0.5, 0.5, 1),
	roughness = Color3.new(0.6, 0.6, 0.6),
	metalness = Color3.new(0, 0, 0),
	emissive = Color3.new(0, 0, 0),
}

local function asContent(value: ImageContent): Content
	return if type(value) == "string" then Content.fromUri(value) else value
end

local function getSource(sources: Sources, layer: string): Source?
	if layer == "color" then
		return sources.color
	end
	if layer == "normal" then
		return sources.normal
	end
	if layer == "roughness" then
		return sources.roughness
	end
	if layer == "metalness" then
		return sources.metalness
	end
	return sources.emissive
end

local function makeQuad(mesh: EditableMesh): Quad
	local vertices = {}
	local uvs = {}
	for _ = 1, 4 do
		table.insert(vertices, mesh:AddVertex(Vector3.zero))
		table.insert(uvs, mesh:AddUV(Vector2.zero))
	end
	local normal = mesh:AddNormal(Vector3.zAxis)
	local a = mesh:AddTriangle(vertices[1], vertices[3], vertices[2])
	local b = mesh:AddTriangle(vertices[1], vertices[4], vertices[3])
	mesh:SetFaceUVs(a, { uvs[1], uvs[3], uvs[2] })
	mesh:SetFaceUVs(b, { uvs[1], uvs[4], uvs[3] })
	mesh:SetFaceNormals(a, { normal, normal, normal })
	mesh:SetFaceNormals(b, { normal, normal, normal })
	return { vertices = vertices, uvs = uvs, normal = normal }
end

local function hide(mesh: EditableMesh, quad: Quad)
	for _, vertex in quad.vertices do
		mesh:SetPosition(vertex, Vector3.zero)
	end
end

function ImposterRender.new(options: Options?): (Renderer?, string?)
	local o: Options = options or {}
	local limits = Limits.resolve(o.limits)
	local layers: { Layer } = table.clone(o.layers or DEFAULT_LAYERS)
	local selected: { [string]: boolean } = {}
	for _, layer in layers do
		assert(MAP_NAMES[layer] ~= nil and not selected[layer], "invalid or duplicate layer")
		selected[layer] = true
	end
	assert(selected["color"], "color layer is required")
	local pixels = #layers * limits.maxTextureSize ^ 2
	-- Leave room for one full-size source image during streaming registration.
	local transientPixels = 1024 ^ 2
	if #layers + 1 > limits.maxEditableImages or pixels + transientPixels > limits.maxTexturePixels then
		return nil, "texture budget must fit atlas layers plus one transient 1024x1024 source image"
	end
	local images: { [string]: EditableImage } = {}
	local mesh: EditableMesh? = nil
	local part: MeshPart? = nil
	local surface: SurfaceAppearance? = nil
	local quads: { Quad } = {}
	local free: { number } = {}
	local ok, message = pcall(function()
		for _, layer in layers do
			local image: EditableImage? =
				AssetService:CreateEditableImage({ Size = Vector2.one * limits.maxTextureSize })
			assert(image, `Roblox denied EditableImage allocation for {layer}`)
			images[layer] = image
		end
		local createdMesh: EditableMesh? = AssetService:CreateEditableMesh()
		assert(createdMesh, "Roblox denied EditableMesh allocation")
		mesh = createdMesh
		for index = 1, limits.maxInstances do
			table.insert(quads, makeQuad(createdMesh))
			table.insert(free, limits.maxInstances - index + 1)
		end
		-- Degenerate, invisible triangles keep a fixed local-space mesh bound.
		-- All dynamic quads must stay inside this extent for reliable culling.
		for _, sign in { -1, 1 } do
			local point = Vector3.one * limits.worldExtent * sign
			createdMesh:AddTriangle(
				createdMesh:AddVertex(point),
				createdMesh:AddVertex(point),
				createdMesh:AddVertex(point)
			)
		end
		local createdPart = AssetService:CreateMeshPartAsync(Content.fromObject(createdMesh))
		part = createdPart
		createdPart.Name = "ImposterBatch"
		createdPart.Anchored = true
		createdPart.CanCollide = false
		createdPart.CanTouch = false
		createdPart.CanQuery = false
		createdPart.CastShadow = false
		createdPart.DoubleSided = true
		createdPart.Color = Color3.new(1, 1, 1)
		createdPart.CFrame = o.origin or CFrame.identity
		-- Preserve the 1:1 mapping between editable vertex coordinates and studs.
		createdPart.Size = createdPart.MeshSize
		local maps: { [string]: Content } = {}
		for _, layer in layers do
			maps[MAP_NAMES[layer]] = Content.fromObject(images[layer])
		end
		local createdSurface = AssetService:CreateSurfaceAppearanceAsync(maps)
		surface = createdSurface
		createdSurface.AlphaMode = Enum.AlphaMode.Transparency
		createdSurface.EmissiveStrength = o.emissiveStrength or 1
		createdSurface.EmissiveTint = o.emissiveTint or Color3.new(1, 1, 1)
		createdSurface.Parent = createdPart
		createdPart.Parent = o.parent or workspace
	end)
	if not ok then
		if surface then
			surface:Destroy()
		end
		if part then
			part:Destroy()
		end
		if mesh then
			mesh:Destroy()
		end
		for _, image in images do
			image:Destroy()
		end
		return nil, tostring(message)
	end
	local sharedMesh = mesh :: EditableMesh
	local sharedPart = part :: MeshPart
	local allocator = Atlas.new(limits.maxTextureSize)
	local models: { [string]: ModelEntry } = {}
	local instances: { [number]: InstanceEntry } = {}
	local modelCount = 0
	local instanceCount = 0
	local destroyed = false
	local busy = false
	local activeSource: EditableImage? = nil
	local renderer: Renderer

	local function requireAlive()
		assert(not destroyed, "renderer has been destroyed")
	end

	local function validBounds(cframe: CFrame, size: Vector3)
		local position = sharedPart.CFrame:PointToObjectSpace(cframe.Position)
		local extent = limits.worldExtent
		local radius = size.Magnitude / math.sqrt(2)
		assert(size.X > 0 and size.Y > 0 and size.Z > 0 and size.Magnitude < math.huge, "invalid bounding box size")
		assert(
			position.X == position.X
				and position.Y == position.Y
				and position.Z == position.Z
				and math.max(math.abs(position.X), math.abs(position.Y), math.abs(position.Z)) + radius <= extent,
			"imposter lies outside worldExtent; create a batch closer to the model or increase the extent"
		)
	end

	local function clearRect(rect: Atlas.Rect)
		for _, layer in layers do
			images[layer]:DrawRectangle(
				rect.position,
				rect.size,
				DEFAULT_COLORS[layer],
				if layer == "color" then 1 else 0,
				Enum.ImageCombineType.Overwrite
			)
		end
	end

	local function copySource(value: ImageContent, expectedSize: Vector2, destination: Vector2, target: EditableImage)
		local source: EditableImage? = AssetService:CreateEditableImageAsync(asContent(value))
		assert(source, "Roblox denied source image allocation")
		activeSource = source
		assert(not destroyed, "renderer was destroyed during image loading")
		assert(
			source.Size == expectedSize,
			`expected {expectedSize}, got {source.Size}; upload PNGs at their original dimensions`
		)
		target:DrawImage(destination, source, Enum.ImageCombineType.Overwrite)
		source:Destroy()
		activeSource = nil
	end

	renderer = {
		mesh = sharedMesh,
		part = sharedPart,
		images = images,
		limits = limits,
		register = function(
			_self: Renderer,
			id: string,
			sources: Sources,
			layoutInput: LayoutInput?
		): (boolean, string?)
			requireAlive()
			if busy then
				return false, "another registration is in progress"
			end
			if id == "" then
				return false, "model id must not be empty"
			end
			if models[id] then
				return false, "model id is already registered; reuse it with add or unregister it first"
			end
			if modelCount >= limits.maxModels then
				return false, "model cache limit reached"
			end
			local layout = Util.layout(layoutInput)
			local shots = Util.shots(layout)
			local rect = Atlas.allocate(allocator, Util.atlasSize(layout))
			if not rect then
				return false, "shared texture atlas is full; lower bake resolution/shot count or use another batch"
			end
			busy = true
			local success, err = pcall(function()
				clearRect(rect)
				for _, layer in layers do
					local value = getSource(sources, layer)
					if value ~= nil then
						if type(value) == "table" then
							for _, shot in shots do
								local entry = value[shot.key]
								assert(entry, `missing {layer} image for {shot.key}`)
								copySource(
									entry,
									Vector2.one * Util.tileSize(layout),
									rect.position + shot.position,
									images[layer]
								)
							end
						else
							copySource(value, rect.size, rect.position, images[layer])
						end
					end
				end
			end)
			busy = false
			if not success then
				if activeSource then
					activeSource:Destroy()
					activeSource = nil
				end
				Atlas.release(allocator, rect)
				return false, tostring(err)
			end
			models[id] = { layout = layout, shots = shots, rect = rect, references = 0 }
			modelCount += 1
			return true, nil
		end,
		unregister = function(_self: Renderer, id: string): (boolean, string?)
			requireAlive()
			if busy then
				return false, "registration in progress"
			end
			local entry = models[id]
			if not entry then
				return false, "unknown model id"
			end
			if entry.references > 0 then
				return false, "destroy this model's active handles before unregistering"
			end
			Atlas.release(allocator, entry.rect)
			models[id] = nil
			modelCount -= 1
			return true, nil
		end,
		add = function(_self: Renderer, id: string, cframe: CFrame, size: Vector3): (Handle?, string?)
			requireAlive()
			local model = models[id]
			if not model then
				return nil, "register the model before adding instances"
			end
			if instanceCount >= limits.maxInstances then
				return nil, "instance limit reached"
			end
			local slot = table.remove(free)
			if not slot then
				return nil, "mesh capacity reached"
			end
			local success, err = pcall(validBounds, cframe, size)
			if not success then
				table.insert(free, slot)
				return nil, tostring(err)
			end
			local entry: InstanceEntry = { id = id, cframe = cframe, size = size, slot = slot }
			instances[slot] = entry
			model.references += 1
			instanceCount += 1
			local released = false
			local handle: Handle = {
				update = function(_handle: Handle, boxCFrame: CFrame, boxSize: Vector3)
					requireAlive()
					assert(not released, "handle has been destroyed")
					validBounds(boxCFrame, boxSize)
					entry.cframe = boxCFrame
					entry.size = boxSize
				end,
				destroy = function(_handle: Handle)
					if released or destroyed then
						return
					end
					released = true
					hide(sharedMesh, quads[slot])
					instances[slot] = nil
					table.insert(free, slot)
					model.references -= 1
					instanceCount -= 1
				end,
			}
			return handle, nil
		end,
		update = function(_self: Renderer, cameraCFrame: CFrame, verticalFieldOfView: number)
			requireAlive()
			for _, entry in instances do
				local model = models[entry.id]
				local solution =
					Util.solve(cameraCFrame, verticalFieldOfView, entry.cframe, entry.size, model.layout, model.shots)
				local quad = quads[entry.slot]
				local half = solution.size / 2
				local cf = sharedPart.CFrame:ToObjectSpace(solution.cframe)
				local corners = {
					Vector3.new(-half.X, half.Y, 0),
					Vector3.new(half.X, half.Y, 0),
					Vector3.new(half.X, -half.Y, 0),
					Vector3.new(-half.X, -half.Y, 0),
				}
				local atlasSize = Vector2.one * allocator.size
				local start = model.rect.position + solution.shot.position + Vector2.one * model.layout.paddingPx
				local uvMin = start / atlasSize
				local uvMax = (start + Vector2.one * model.layout.maxResolutionPx) / atlasSize
				local uvs = { uvMin, Vector2.new(uvMax.X, uvMin.Y), uvMax, Vector2.new(uvMin.X, uvMax.Y) }
				for i = 1, 4 do
					sharedMesh:SetPosition(quad.vertices[i], cf:PointToWorldSpace(corners[i]))
					sharedMesh:SetUV(quad.uvs[i], uvs[i])
				end
				sharedMesh:SetNormal(quad.normal, cf.ZVector)
			end
		end,
		setLimits = function(self: Renderer, input: LimitOptions): (boolean, string?)
			requireAlive()
			if busy then
				return false, "registration in progress"
			end
			-- Capacity cannot grow in place without replacing the shared objects.
			local merged: LimitOptions = {
				maxTextureSize = input.maxTextureSize or limits.maxTextureSize,
				maxTexturePixels = input.maxTexturePixels or limits.maxTexturePixels,
				maxEditableImages = input.maxEditableImages or limits.maxEditableImages,
				maxEditableMeshes = input.maxEditableMeshes or limits.maxEditableMeshes,
				maxInstances = input.maxInstances or limits.maxInstances,
				maxModels = input.maxModels or limits.maxModels,
				worldExtent = input.worldExtent or limits.worldExtent,
			}
			local nextLimits = Limits.resolve(merged)
			if
				nextLimits.maxTextureSize ~= allocator.size
				or nextLimits.worldExtent ~= limits.worldExtent
				or nextLimits.maxInstances > #quads
			then
				return false, "texture dimensions, mesh capacity, and worldExtent require a new renderer"
			end
			if
				nextLimits.maxInstances < instanceCount
				or nextLimits.maxModels < modelCount
				or nextLimits.maxEditableImages < #layers + 1
				or nextLimits.maxTexturePixels < pixels + transientPixels
			then
				return false, "new limits are below current usage including the transient source reserve"
			end
			limits = nextLimits
			self.limits = nextLimits
			return true, nil
		end,
		getUsage = function(_self: Renderer): Usage
			return {
				models = modelCount,
				instances = instanceCount,
				editableMeshes = if destroyed then 0 else 1,
				editableImages = if destroyed then 0 else #layers + (if activeSource then 1 else 0),
				texturePixels = if destroyed
					then 0
					else pixels + (if activeSource then activeSource.Size.X * activeSource.Size.Y else 0),
				reservedTransientPixels = if destroyed then 0 else transientPixels,
			}
		end,
		destroy = function(_self: Renderer)
			if destroyed then
				return
			end
			destroyed = true
			sharedPart:Destroy()
			sharedMesh:Destroy()
			for _, image in images do
				image:Destroy()
			end
			-- An in-flight registration owns its transient source until it resumes.
			table.clear(models)
			table.clear(instances)
			modelCount = 0
			instanceCount = 0
		end,
	}
	return renderer, nil
end

return table.freeze(ImposterRender)
