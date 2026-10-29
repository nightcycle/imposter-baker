--!strict
local AssetService = game:GetService("AssetService")
local Util = require(script.Util)
local Limits = require(script.Limits)
local Atlas = require(script.Atlas)
local Scheduler = require(script.Scheduler)
local InstanceCache = require(script.InstanceCache)
local Lod = require(script.Lod)

local ImposterRender =
	{ Util = Util, Limits = Limits, Atlas = Atlas, Scheduler = Scheduler, InstanceCache = InstanceCache, Lod = Lod }

export type Layout = Util.Layout
export type LayoutInput = Util.LayoutInput
export type Shot = Util.Shot
export type Solution = Util.Solution
export type LimitOptions = Limits.Options
export type Budget = Limits.Budget
export type UpdateBudgetInput = Scheduler.BudgetInput
export type UpdateBudget = Scheduler.Budget
export type LodOptions = Lod.Options
export type LodConfig = Lod.Config
export type InstanceCacheOptions = InstanceCache.Options
export type TemplateOptions = InstanceCache.TemplateOptions
export type Layer = "color" | "normal" | "roughness" | "metalness" | "emissive"
export type ImageContent = Content | string
export type Source = ImageContent | { [string]: ImageContent }
export type Sources = {
	Color: Source,
	Normal: Source?,
	Roughness: Source?,
	Metalness: Source?,
	Emissive: Source?,
}
export type Options = {
	Limits: LimitOptions?,
	Parent: Instance?,
	Origin: CFrame?,
	Layers: { Layer }?,
	EmissiveStrength: number?,
	EmissiveTint: Color3?,
	UpdateBudget: UpdateBudgetInput?,
	Lod: LodOptions?,
	InstanceCache: InstanceCacheOptions?,
}
export type Usage = {
	Models: number,
	Instances: number,
	EditableMeshes: number,
	EditableImages: number,
	TexturePixels: number,
	ReservedTransientPixels: number,
	PendingInstances: number,
	CheckedInstances: number,
	UpdatedInstances: number,
	UpdateMilliseconds: number,
	RealInstances: number,
	CachedInstances: number,
	BulkMovedParts: number,
	LodTransitions: number,
}
export type Handle = {
	Update: (self: Handle, boundingBoxCFrame: CFrame, boundingBoxSize: Vector3) -> (),
	SetLodEnabled: (self: Handle, enabled: boolean) -> (),
	GetRealInstance: (self: Handle) -> Model?,
	Destroy: (self: Handle) -> (),
}
export type Renderer = {
	Mesh: EditableMesh,
	Part: MeshPart,
	Images: { [string]: EditableImage },
	Limits: Budget,
	UpdateBudget: UpdateBudget,
	Lod: LodConfig,
	Register: (self: Renderer, id: string, sources: Sources, layout: LayoutInput?) -> (boolean, string?),
	Unregister: (self: Renderer, id: string) -> (boolean, string?),
	Add: (self: Renderer, id: string, boundingBoxCFrame: CFrame, boundingBoxSize: Vector3) -> (Handle?, string?),
	Update: (self: Renderer, cameraCFrame: CFrame, verticalFieldOfView: number, availableMilliseconds: number?) -> (),
	SetUpdateBudget: (self: Renderer, input: UpdateBudgetInput) -> (),
	SetLodOptions: (self: Renderer, input: LodOptions) -> (),
	RegisterTemplate: (self: Renderer, id: string, template: Instance, options: TemplateOptions?) -> (boolean, string?),
	UnregisterTemplate: (self: Renderer, id: string) -> (boolean, string?),
	Prewarm: (self: Renderer, id: string, count: number) -> (number, string?),
	SetLimits: (self: Renderer, options: LimitOptions) -> (boolean, string?),
	GetUsage: (self: Renderer) -> Usage,
	Destroy: (self: Renderer) -> (),
}

type ModelEntry = {
	Layout: Layout,
	Shots: { Shot },
	Rect: Atlas.Rect,
	References: number,
	HasTemplate: boolean?,
}
type Quad = { Vertices: { number }, UVs: { number }, Normal: number }
type InstanceEntry = {
	Id: string,
	CFrame: CFrame,
	Size: Vector3,
	Slot: number,
	LastShot: number?,
	PartRevision: number?,
	LodEnabled: boolean,
	Real: InstanceCache.Lease?,
	RealDirty: boolean,
}

local DEFAULT_LAYERS: { Layer } = { "color", "normal", "roughness", "metalness", "emissive" }
local MAP_NAMES: { [string]: string } = {
	["color"] = "ColorMap",
	["normal"] = "NormalMap",
	["roughness"] = "RoughnessMap",
	["metalness"] = "MetalnessMap",
	["emissive"] = "EmissiveMask",
}
local DEFAULT_COLORS: { [string]: Color3 } = {
	["color"] = Color3.new(1, 1, 1),
	["normal"] = Color3.new(0.5, 0.5, 1),
	["roughness"] = Color3.new(0.6, 0.6, 0.6),
	["metalness"] = Color3.new(0, 0, 0),
	["emissive"] = Color3.new(0, 0, 0),
}

local function asContent(value: ImageContent): Content
	return if type(value) == "string" then Content.fromUri(value) else value
end

local function getSource(sources: Sources, layer: string): Source?
	if layer == "color" then
		return sources.Color
	end
	if layer == "normal" then
		return sources.Normal
	end
	if layer == "roughness" then
		return sources.Roughness
	end
	if layer == "metalness" then
		return sources.Metalness
	end
	return sources.Emissive
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
	return { Vertices = vertices, UVs = uvs, Normal = normal }
end

local function hide(mesh: EditableMesh, quad: Quad)
	for _, vertex in quad.Vertices do
		mesh:SetPosition(vertex, Vector3.zero)
	end
end

function ImposterRender.New(options: Options?): (Renderer?, string?)
	local o: Options = options or {}
	local limits = Limits.Resolve(o.Limits)
	local updateBudget = Scheduler.Budget(o.UpdateBudget)
	local lod = Lod.Resolve(o.Lod)
	local layers: { Layer } = table.clone(o.Layers or DEFAULT_LAYERS)
	local selected: { [string]: boolean } = {}
	for _, layer in layers do
		assert(MAP_NAMES[layer] ~= nil and not selected[layer], "invalid or duplicate layer")
		selected[layer] = true
	end
	assert(selected["color"], "color layer is required")
	local pixels = #layers * limits.MaxTextureSize ^ 2
	-- Leave room for one full-size source image during streaming registration.
	local transientPixels = 1024 ^ 2
	if #layers + 1 > limits.MaxEditableImages or pixels + transientPixels > limits.MaxTexturePixels then
		return nil, "texture Budget must fit atlas Layers plus one transient 1024x1024 source image"
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
				AssetService:CreateEditableImage({ Size = Vector2.one * limits.MaxTextureSize })
			assert(image, `Roblox denied EditableImage allocation for {layer}`)
			images[layer] = image
		end
		local createdMesh: EditableMesh? = AssetService:CreateEditableMesh()
		assert(createdMesh, "Roblox denied EditableMesh allocation")
		mesh = createdMesh
		for index = 1, limits.MaxInstances do
			table.insert(quads, makeQuad(createdMesh))
			table.insert(free, limits.MaxInstances - index + 1)
		end
		-- Degenerate, invisible triangles keep a fixed local-space mesh bound.
		-- All dynamic quads must stay inside this extent for reliable culling.
		for _, sign in { -1, 1 } do
			local point = Vector3.one * limits.WorldExtent * sign
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
		createdPart.CFrame = o.Origin or CFrame.identity
		-- Preserve the 1:1 mapping between editable vertex coordinates and studs.
		createdPart.Size = createdPart.MeshSize
		local maps: { [string]: Content } = {}
		for _, layer in layers do
			maps[MAP_NAMES[layer]] = Content.fromObject(images[layer])
		end
		local createdSurface = AssetService:CreateSurfaceAppearanceAsync(maps)
		surface = createdSurface
		createdSurface.AlphaMode = Enum.AlphaMode.Transparency
		createdSurface.EmissiveStrength = o.EmissiveStrength or 1
		createdSurface.EmissiveTint = o.EmissiveTint or Color3.new(1, 1, 1)
		createdSurface.Parent = createdPart
		createdPart.Parent = o.Parent or workspace
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
	local allocator = Atlas.New(limits.MaxTextureSize)
	local models: { [string]: ModelEntry } = {}
	local instances: { [number]: InstanceEntry } = {}
	local modelCount = 0
	local instanceCount = 0
	local destroyed = false
	local busy = false
	local activeSource: EditableImage? = nil
	local renderer: Renderer
	local lastPartCFrame: CFrame? = nil
	local partRevision = 0
	local scheduler = Scheduler.New(limits.MaxInstances)
	local lastStats: Scheduler.Stats = { Checked = 0, Updated = 0 }
	local updateMilliseconds = 0
	local cache: InstanceCache.Cache? = nil
	local realEntries: { [InstanceEntry]: boolean } = {}
	local realCount = 0
	local transitions = 0
	local movedParts = 0
	local flushMilliseconds = 0.05

	local function requireAlive()
		assert(not destroyed, "renderer has been destroyed")
	end

	local function validBounds(cframe: CFrame, size: Vector3)
		local position = sharedPart.CFrame:PointToObjectSpace(cframe.Position)
		local extent = limits.WorldExtent
		local radius = size.Magnitude / math.sqrt(2)
		assert(size.X > 0 and size.Y > 0 and size.Z > 0 and size.Magnitude < math.huge, "invalid bounding box size")
		assert(
			position.X == position.X
				and position.Y == position.Y
				and position.Z == position.Z
				and math.max(math.abs(position.X), math.abs(position.Y), math.abs(position.Z)) + radius <= extent,
			"imposter lies outside WorldExtent; create a batch closer to the model or increase the extent"
		)
	end

	local function clearRect(rect: Atlas.Rect)
		for _, layer in layers do
			images[layer]:DrawRectangle(
				rect.Position,
				rect.Size,
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

	local function draw(entry: InstanceEntry, cameraCFrame: CFrame, verticalFieldOfView: number): boolean
		local cameraPosition = cameraCFrame.Position
		local partCFrame = sharedPart.CFrame
		local model = models[entry.Id]
		local relative = cameraPosition - entry.CFrame.Position
		local toward = if relative.Magnitude > 1e-8 then relative else -cameraCFrame.LookVector
		local shot = Util.SelectShot(entry.CFrame:VectorToObjectSpace(toward), model.Shots)
		-- Capture-locked geometry only changes at a shot boundary or when
		-- its bounds/batch transform change. Avoid thousands of mesh writes.
		if entry.LastShot == shot.Index and entry.PartRevision == partRevision then
			return false
		end
		local solution =
			Util.Solve(cameraCFrame, verticalFieldOfView, entry.CFrame, entry.Size, model.Layout, model.Shots)
		local quad = quads[entry.Slot]
		local half = solution.Size / 2
		local cf = partCFrame:ToObjectSpace(solution.CFrame)
		local corners = {
			Vector3.new(-half.X, half.Y, 0),
			Vector3.new(half.X, half.Y, 0),
			Vector3.new(half.X, -half.Y, 0),
			Vector3.new(-half.X, -half.Y, 0),
		}
		local atlasSize = Vector2.one * allocator.Size
		local start = model.Rect.Position + solution.Shot.Position + Vector2.one * model.Layout.PaddingPx
		local uvMin = start / atlasSize
		local uvMax = (start + Vector2.one * model.Layout.MaxResolutionPx) / atlasSize
		local uvs = { uvMin, Vector2.new(uvMax.X, uvMin.Y), uvMax, Vector2.new(uvMin.X, uvMax.Y) }
		for i = 1, 4 do
			sharedMesh:SetPosition(quad.Vertices[i], cf:PointToWorldSpace(corners[i]))
			sharedMesh:SetUV(quad.UVs[i], uvs[i])
		end
		sharedMesh:SetNormal(quad.Normal, cf.ZVector)
		entry.LastShot = shot.Index
		entry.PartRevision = partRevision
		return true
	end

	renderer = {
		Mesh = sharedMesh,
		Part = sharedPart,
		Images = images,
		Limits = limits,
		UpdateBudget = updateBudget,
		Lod = lod,
		RegisterTemplate = function(
			_self: Renderer,
			id: string,
			template: Instance,
			input: TemplateOptions?
		): (boolean, string?)
			requireAlive()
			local model = models[id]
			if not model then
				return false, "Register the baked model before its Template"
			end
			if model.HasTemplate then
				return false, "Template already registered"
			end
			if not cache then
				local ok, err = pcall(function()
					cache = InstanceCache.New(o.InstanceCache)
				end)
				if not ok then
					return false, tostring(err)
				end
			end
			local pool = cache :: InstanceCache.Cache
			if lod.MaxRealInstances > pool.MaxInstances then
				return false, "MaxRealInstances exceeds the Instance cache Capacity"
			end
			local ok, err = pool:Register(id, template, input)
			if ok then
				model.HasTemplate = true
				Scheduler.Invalidate(scheduler)
			end
			return ok, err
		end,
		UnregisterTemplate = function(_self: Renderer, id: string): (boolean, string?)
			requireAlive()
			local pool = cache
			local model = models[id]
			if not model or not model.HasTemplate or not pool then
				return false, "unknown Template"
			end
			local ok, err = pool:Unregister(id)
			if ok then
				model.HasTemplate = nil
				Scheduler.Invalidate(scheduler)
			end
			return ok, err
		end,
		Prewarm = function(_self: Renderer, id: string, count: number): (number, string?)
			requireAlive()
			local pool = cache
			if not pool then
				return 0, "Register a Template before prewarming"
			end
			local warmed, err = pool:Prewarm(id, count)
			Scheduler.Invalidate(scheduler)
			return warmed, err
		end,
		Register = function(
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
				return false, "model id is already registered; reuse it with add or Unregister it first"
			end
			if modelCount >= limits.MaxModels then
				return false, "model cache limit reached"
			end
			local layout = Util.Layout(layoutInput)
			local shots = Util.Shots(layout)
			local rect = Atlas.Allocate(allocator, Util.AtlasSize(layout))
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
								local entry = value[shot.Key]
								assert(entry, `missing {layer} image for {shot.Key}`)
								copySource(
									entry,
									Vector2.one * Util.TileSize(layout),
									rect.Position + shot.Position,
									images[layer]
								)
							end
						else
							copySource(value, rect.Size, rect.Position, images[layer])
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
				Atlas.Release(allocator, rect)
				return false, tostring(err)
			end
			models[id] = { Layout = layout, Shots = shots, Rect = rect, References = 0 }
			modelCount += 1
			return true, nil
		end,
		Unregister = function(_self: Renderer, id: string): (boolean, string?)
			requireAlive()
			if busy then
				return false, "registration in progress"
			end
			local entry = models[id]
			if not entry then
				return false, "unknown model id"
			end
			if entry.References > 0 then
				return false, "Destroy this model's Active handles before unregistering"
			end
			if entry.HasTemplate and cache then
				local ok, err = cache:Unregister(id)
				if not ok then
					return false, err
				end
			end
			Atlas.Release(allocator, entry.Rect)
			models[id] = nil
			modelCount -= 1
			return true, nil
		end,
		Add = function(_self: Renderer, id: string, cframe: CFrame, size: Vector3): (Handle?, string?)
			requireAlive()
			local model = models[id]
			if not model then
				return nil, "Register the model before adding Instances"
			end
			if instanceCount >= limits.MaxInstances then
				return nil, "Instance limit reached"
			end
			local slot = table.remove(free)
			if not slot then
				return nil, "mesh Capacity reached"
			end
			local success, err = pcall(validBounds, cframe, size)
			if not success then
				table.insert(free, slot)
				return nil, tostring(err)
			end
			local entry: InstanceEntry =
				{ Id = id, CFrame = cframe, Size = size, Slot = slot, LodEnabled = true, RealDirty = false }
			instances[slot] = entry
			Scheduler.Set(scheduler, slot, cframe.Position)
			model.References += 1
			instanceCount += 1
			local released = false
			local handle: Handle = {
				Update = function(_handle: Handle, boxCFrame: CFrame, boxSize: Vector3)
					requireAlive()
					assert(not released, "handle has been destroyed")
					validBounds(boxCFrame, boxSize)
					entry.CFrame = boxCFrame
					entry.Size = boxSize
					entry.LastShot = nil
					entry.RealDirty = true
					Scheduler.Set(scheduler, slot, boxCFrame.Position)
				end,
				SetLodEnabled = function(_handle: Handle, enabled: boolean)
					requireAlive()
					assert(not released, "handle has been destroyed")
					entry.LodEnabled = enabled
					Scheduler.Invalidate(scheduler)
				end,
				GetRealInstance = function(_handle: Handle): Model?
					return if not released and not destroyed and entry.Real then entry.Real.Instance else nil
				end,
				Destroy = function(_handle: Handle)
					if released or destroyed then
						return
					end
					released = true
					if entry.Real and cache then
						cache:Release(entry.Real)
						entry.Real = nil
						realEntries[entry] = nil
						realCount -= 1
					end
					hide(sharedMesh, quads[slot])
					instances[slot] = nil
					Scheduler.Remove(scheduler, slot)
					table.insert(free, slot)
					model.References -= 1
					instanceCount -= 1
				end,
			}
			return handle, nil
		end,
		Update = function(
			_self: Renderer,
			cameraCFrame: CFrame,
			verticalFieldOfView: number,
			availableMilliseconds: number?
		)
			local started = os.clock()
			requireAlive()
			local milliseconds = updateBudget.MaxMilliseconds
			if availableMilliseconds ~= nil then
				assert(
					availableMilliseconds >= 0 and availableMilliseconds < math.huge,
					"availableMilliseconds must be nonnegative and finite"
				)
				milliseconds = math.min(milliseconds, availableMilliseconds)
			end
			assert(verticalFieldOfView > 0 and verticalFieldOfView < 180, "vertical FOV must be in (0, 180) degrees")
			local cameraPosition = cameraCFrame.Position
			assert(cameraPosition.Magnitude < math.huge, "Camera Position must be finite")
			local partCFrame = sharedPart.CFrame
			if partCFrame ~= lastPartCFrame then
				partRevision += 1
				Scheduler.Invalidate(scheduler)
				lastPartCFrame = partCFrame
			end
			transitions, movedParts = 0, 0
			local creates = 0
			local retry = false
			local promoted: { InstanceEntry } = {}
			local pool = cache
			local function farthest(): (InstanceEntry?, number)
				local result: InstanceEntry? = nil
				local distance = -1
				for active in realEntries do
					local nextDistance = Lod.Distance(cameraPosition, active.CFrame.Position)
					if
						nextDistance > distance or (nextDistance == distance and result and active.Slot > result.Slot)
					then
						result, distance = active, nextDistance
					end
				end
				return result, distance
			end
			local function demote(entry: InstanceEntry)
				local lease = entry.Real
				assert(pool and lease)
				-- Restore the quad immediately before releasing its real counterpart.
				entry.LastShot = nil
				draw(entry, cameraCFrame, verticalFieldOfView)
				pool:Release(lease)
				entry.Real = nil
				realEntries[entry] = nil
				realCount -= 1
				transitions += 1
			end
			-- Reserve part of this same budget for the bounded, atomic bulk move.
			local reserve = if pool then math.min(milliseconds * 0.25, math.max(0.05, flushMilliseconds * 1.2)) else 0
			lastStats = Scheduler.Run(
				scheduler,
				cameraCFrame,
				started + (milliseconds - reserve) / 1000,
				function(slot: number): boolean
					local entry = instances[slot]
					if not entry then
						return false
					end
					if pool then
						if realCount > lod.MaxRealInstances then
							if transitions < lod.MaxTransitionsPerFrame then
								local victim = farthest()
								if victim then
									demote(victim)
								end
							else
								retry = true
							end
						end
						local distance = Lod.Distance(cameraPosition, entry.CFrame.Position)
						local scale = if models[entry.Id].HasTemplate then pool:ScaleFor(entry.Id, entry.Size) else nil
						local eligible = entry.LodEnabled and scale ~= nil and lod.MaxRealInstances > 0
						local real = entry.Real
						if real then
							if not eligible or distance > lod.FarDistance then
								if transitions < lod.MaxTransitionsPerFrame then
									demote(entry)
									return true
								else
									retry = true
									return false
								end
							end
							if entry.RealDirty then
								local queued = pool:Queue(real, entry.CFrame, entry.Size)
								if queued then
									entry.RealDirty = false
								else
									retry = true
								end
							end
							return false
						elseif eligible and distance <= lod.NearDistance then
							local victim: InstanceEntry? = nil
							local allowed = true
							if realCount >= lod.MaxRealInstances then
								local far, farDistance = farthest()
								victim = far
								allowed = far ~= nil and Lod.ShouldReplace(distance, farDistance, lod)
							end
							if allowed then
								local needed = if victim then 2 else 1
								local canCreate = creates < lod.MaxCreatesPerFrame
								local warm = pool:Available(entry.Id) > 0 or (victim ~= nil and victim.Id == entry.Id)
								if
									transitions + needed > lod.MaxTransitionsPerFrame
									or (not warm and not canCreate)
									or pool:GetUsage().QueuedParts + pool:PartCount(entry.Id)
										> pool.MaxPartsPerFlush
								then
									-- A cold pool with creation disabled needs an explicit
									-- prewarm, not endless rescans of a stationary scene.
									retry = retry or warm or lod.MaxCreatesPerFrame > 0
								else
									if victim then
										demote(victim)
									end
									local lease, _, created = pool:Acquire(entry.Id, canCreate)
									if lease then
										if created then
											creates += 1
										end
										local queued, queueError = pool:Queue(lease, entry.CFrame, entry.Size)
										if not queued then
											pool:Release(lease)
											error(queueError)
										end
										entry.Real = lease
										entry.RealDirty = false
										realEntries[entry] = true
										realCount += 1
										transitions += 1
										table.insert(promoted, entry)
									else
										retry = true
									end
								end
							end
						end
					end
					return draw(entry, cameraCFrame, verticalFieldOfView)
				end
			)
			if pool then
				local flushStarted = os.clock()
				local ok, err = pool:Flush()
				if not ok then
					for _, entry in promoted do
						if entry.Real then
							demote(entry)
						end
					end
					Scheduler.Invalidate(scheduler)
					error(err)
				end
				movedParts = pool:GetUsage().MovedParts
				for _, entry in promoted do
					if entry.Real then
						hide(sharedMesh, quads[entry.Slot])
						entry.LastShot = nil
					end
				end
				if movedParts > 0 then
					flushMilliseconds = (os.clock() - flushStarted) * 1000
				end
			end
			if retry then
				Scheduler.Invalidate(scheduler)
			end
			updateMilliseconds = (os.clock() - started) * 1000
		end,
		SetUpdateBudget = function(self: Renderer, input: UpdateBudgetInput)
			requireAlive()
			updateBudget = Scheduler.Budget(input)
			self.UpdateBudget = updateBudget
		end,
		SetLodOptions = function(self: Renderer, input: LodOptions)
			requireAlive()
			local nextLod = Lod.Resolve(input)
			assert(
				not cache or nextLod.MaxRealInstances <= cache.MaxInstances,
				"MaxRealInstances exceeds cache Capacity"
			)
			lod = nextLod
			self.Lod = nextLod
			Scheduler.Invalidate(scheduler)
		end,
		SetLimits = function(self: Renderer, input: LimitOptions): (boolean, string?)
			requireAlive()
			if busy then
				return false, "registration in progress"
			end
			-- Capacity cannot grow in place without replacing the shared objects.
			local merged: LimitOptions = {
				MaxTextureSize = input.MaxTextureSize or limits.MaxTextureSize,
				MaxTexturePixels = input.MaxTexturePixels or limits.MaxTexturePixels,
				MaxEditableImages = input.MaxEditableImages or limits.MaxEditableImages,
				MaxEditableMeshes = input.MaxEditableMeshes or limits.MaxEditableMeshes,
				MaxInstances = input.MaxInstances or limits.MaxInstances,
				MaxModels = input.MaxModels or limits.MaxModels,
				WorldExtent = input.WorldExtent or limits.WorldExtent,
			}
			local nextLimits = Limits.Resolve(merged)
			if
				nextLimits.MaxTextureSize ~= allocator.Size
				or nextLimits.WorldExtent ~= limits.WorldExtent
				or nextLimits.MaxInstances > #quads
			then
				return false, "texture dimensions, mesh Capacity, and WorldExtent require a new renderer"
			end
			if
				nextLimits.MaxInstances < instanceCount
				or nextLimits.MaxModels < modelCount
				or nextLimits.MaxEditableImages < #layers + 1
				or nextLimits.MaxTexturePixels < pixels + transientPixels
			then
				return false, "new Limits are below current usage including the transient source reserve"
			end
			limits = nextLimits
			self.Limits = nextLimits
			return true, nil
		end,
		GetUsage = function(_self: Renderer): Usage
			return {
				RealInstances = realCount,
				CachedInstances = if cache then cache:GetUsage().Cached else 0,
				BulkMovedParts = movedParts,
				LodTransitions = transitions,
				PendingInstances = if destroyed then 0 else Scheduler.Pending(scheduler),
				CheckedInstances = lastStats.Checked,
				UpdatedInstances = lastStats.Updated,
				UpdateMilliseconds = updateMilliseconds,
				Models = modelCount,
				Instances = instanceCount,
				EditableMeshes = if destroyed then 0 else 1,
				EditableImages = if destroyed then 0 else #layers + (if activeSource then 1 else 0),
				TexturePixels = if destroyed
					then 0
					else pixels + (if activeSource then activeSource.Size.X * activeSource.Size.Y else 0),
				ReservedTransientPixels = if destroyed then 0 else transientPixels,
			}
		end,
		Destroy = function(_self: Renderer)
			if destroyed then
				return
			end
			destroyed = true
			if cache then
				cache:Destroy()
			end
			table.clear(realEntries)
			realCount = 0
			sharedPart:Destroy()
			sharedMesh:Destroy()
			for _, image in images do
				image:Destroy()
			end
			-- An in-flight registration owns its transient source until it resumes.
			table.clear(models)
			table.clear(instances)
			Scheduler.Clear(scheduler)
			modelCount = 0
			instanceCount = 0
		end,
	}
	return renderer, nil
end

return table.freeze(ImposterRender)
