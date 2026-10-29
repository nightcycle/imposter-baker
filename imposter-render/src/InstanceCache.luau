--!strict
-- Static visual clones. Idle models are unparented; active parts move in one batch.
local InstanceCache = {}

export type Options = {
	MaxInstances: number?,
	MaxPartsPerInstance: number?,
	MaxPartsPerFlush: number?,
	Parent: Instance?,
	WorldRoot: WorldRoot?,
	CanCollide: boolean?,
	CanQuery: boolean?,
}
export type TemplateOptions = {
	BoundingBoxCFrame: CFrame?,
	BoundingBoxSize: Vector3?,
	CanCollide: boolean?,
	CanQuery: boolean?,
}
export type Lease = {
	Id: string,
	Instance: Model,
	Parts: { BasePart },
	Offsets: { CFrame },
	Scale: number,
	Active: boolean,
	CFrame: CFrame,
}
export type Usage = {
	Cached: number,
	Active: number,
	Idle: number,
	QueuedParts: number,
	MovedParts: number,
	ClonesCreated: number,
}
export type Cache = {
	MaxInstances: number,
	MaxPartsPerFlush: number,
	Folder: Folder,
	Register: (self: Cache, id: string, template: Instance, options: TemplateOptions?) -> (boolean, string?),
	Unregister: (self: Cache, id: string) -> (boolean, string?),
	Prewarm: (self: Cache, id: string, count: number) -> (number, string?),
	Acquire: (self: Cache, id: string, allowCreate: boolean?) -> (Lease?, string?, boolean),
	Release: (self: Cache, lease: Lease) -> (),
	Queue: (self: Cache, lease: Lease, cframe: CFrame, size: Vector3) -> (boolean, string?),
	Flush: (self: Cache) -> (boolean, string?),
	Available: (self: Cache, id: string) -> number,
	PartCount: (self: Cache, id: string) -> number,
	ScaleFor: (self: Cache, id: string, size: Vector3) -> number?,
	GetUsage: (self: Cache) -> Usage,
	Destroy: (self: Cache) -> (),
}
type Template = {
	Model: Model,
	Bounds: CFrame,
	Size: Vector3,
	Parts: number,
	Free: { Lease },
	Count: number,
	Active: number,
}

local function integer(value: number, name: string): number
	assert(value > 0 and value < math.huge and value % 1 == 0, `{name} must be a positive finite integer`)
	return value
end

function InstanceCache.New(options: Options?): Cache
	local o: Options = options or {}
	local maxInstances = integer(o.MaxInstances or 128, "MaxInstances")
	local maxParts = integer(o.MaxPartsPerInstance or 128, "MaxPartsPerInstance")
	local maxFlush = integer(o.MaxPartsPerFlush or 256, "MaxPartsPerFlush")
	assert(maxParts <= maxFlush, "one Template must fit in a bulk move")
	local worldRoot = o.WorldRoot or workspace
	local parent = o.Parent or worldRoot
	assert(parent == worldRoot or parent:IsDescendantOf(worldRoot), "cache Parent must be inside WorldRoot")
	local folder = Instance.new("Folder")
	folder.Name = "ImposterRealInstances"
	folder.Parent = parent
	local templates: { [string]: Template } = {}
	local leases: { [Lease]: boolean } = {}
	local pending: { [Lease]: boolean } = {}
	local cached, active, queuedParts, movedParts, clonesCreated = 0, 0, 0, 0, 0
	local destroyed = false
	local cache: Cache

	local function alive()
		assert(not destroyed, "Instance cache has been destroyed")
	end
	local function drop(lease: Lease)
		leases[lease] = nil
		templates[lease.Id].Count -= 1
		cached -= 1
		lease.Instance:Destroy()
	end
	local function create(id: string): (Lease?, string?)
		local template = templates[id]
		if cached >= maxInstances then
			-- Reclaim an idle clone of another template before growing this pool.
			for key, other in templates do
				if key ~= id and #other.Free > 0 then
					drop(table.remove(other.Free) :: Lease)
					break
				end
			end
		end
		if cached >= maxInstances then
			return nil, "Instance cache is full"
		end
		local model: Model? = nil
		local result: Lease? = nil
		local ok, message = pcall(function()
			local clone = template.Model:Clone()
			model = clone
			local parts: { BasePart } = {}
			local offsets: { CFrame } = {}
			for _, child in clone:GetDescendants() do
				if child:IsA("BasePart") then
					table.insert(parts, child)
					table.insert(offsets, template.Bounds:ToObjectSpace(child.CFrame))
				end
			end
			result = {
				Id = id,
				Instance = clone,
				Parts = parts,
				Offsets = offsets,
				Scale = 1,
				Active = false,
				CFrame = template.Bounds,
			}
		end)
		if not ok then
			if model then
				model:Destroy()
			end
			return nil, tostring(message)
		end
		local lease = result :: Lease
		leases[lease] = true
		cached += 1
		clonesCreated += 1
		template.Count += 1
		return lease, nil
	end

	cache = {
		MaxInstances = maxInstances,
		MaxPartsPerFlush = maxFlush,
		Folder = folder,
		Register = function(_self: Cache, id: string, source: Instance, input: TemplateOptions?): (boolean, string?)
			alive()
			if templates[id] or id == "" then
				return false, "Template id must be nonempty and unique"
			end
			if not source:IsA("Model") and not source:IsA("BasePart") then
				return false, "Template must be a Model or BasePart"
			end
			local model = Instance.new("Model")
			local result: Template? = nil
			local ok, message = pcall(function()
				local settings: TemplateOptions = input or {}
				local cf: CFrame, size: Vector3
				if source:IsA("Model") then
					cf, size = source:GetBoundingBox()
				else
					local part = source :: BasePart
					cf, size = part.CFrame, part.Size
				end
				cf = settings.BoundingBoxCFrame or cf
				size = settings.BoundingBoxSize or size
				assert(
					cf.Position.Magnitude < math.huge
						and size.Magnitude < math.huge
						and math.min(size.X, size.Y, size.Z) > 0,
					"invalid Template Bounds"
				)
				local clone: Instance = source:Clone()
				assert(clone, "Template must be Archivable")
				clone.Parent = model
				model.Name = id
				model.WorldPivot = cf
				local count = 0
				for _, child in model:GetDescendants() do
					if child:IsA("BasePart") then
						count += 1
						child.Anchored = true
						child.CanCollide = if settings.CanCollide == nil
							then o.CanCollide == true
							else settings.CanCollide
						child.CanTouch = false
						child.CanQuery = if settings.CanQuery == nil then o.CanQuery == true else settings.CanQuery
					elseif child:IsA("LuaSourceContainer") then
						child:Destroy()
					end
				end
				assert(count > 0 and count <= maxParts, "Template must contain 1..MaxPartsPerInstance parts")
				result = { Model = model, Bounds = cf, Size = size, Parts = count, Free = {}, Count = 0, Active = 0 }
			end)
			if not ok then
				model:Destroy()
				return false, tostring(message)
			end
			templates[id] = result :: Template
			return true, nil
		end,
		Unregister = function(_self: Cache, id: string): (boolean, string?)
			alive()
			local template = templates[id]
			if not template then
				return false, "unknown Template"
			end
			if template.Active > 0 then
				return false, "Release Active leases before unregistering"
			end
			for _, lease in template.Free do
				drop(lease)
			end
			template.Model:Destroy()
			templates[id] = nil
			return true, nil
		end,
		Prewarm = function(_self: Cache, id: string, count: number): (number, string?)
			alive()
			assert(count >= 0 and count < math.huge and count % 1 == 0, "Prewarm count must be a nonnegative integer")
			local template = templates[id]
			if not template then
				return 0, "unknown Template"
			end
			while template.Count < count do
				local lease, err = create(id)
				if not lease then
					return template.Count, err
				end
				table.insert(template.Free, lease)
			end
			return template.Count, nil
		end,
		Acquire = function(_self: Cache, id: string, allowCreate: boolean?): (Lease?, string?, boolean)
			alive()
			local template = templates[id]
			if not template then
				return nil, "unknown Template", false
			end
			local lease = table.remove(template.Free)
			local created = false
			if not lease then
				if allowCreate == false then
					return nil, "no prewarmed Instance Available", false
				end
				local err: string?
				lease, err = create(id)
				if not lease then
					return nil, err, false
				end
				created = true
			end
			assert(lease)
			lease.Active = true
			active += 1
			template.Active += 1
			return lease, nil, created
		end,
		Release = function(_self: Cache, lease: Lease)
			if destroyed then
				return
			end
			assert(leases[lease], "lease belongs to another cache")
			if not lease.Active then
				return
			end
			if pending[lease] then
				pending[lease] = nil
				queuedParts -= #lease.Parts
			end
			lease.Instance.Parent = nil
			lease.Active = false
			active -= 1
			local template = templates[lease.Id]
			template.Active -= 1
			table.insert(template.Free, lease)
		end,
		Queue = function(self: Cache, lease: Lease, cf: CFrame, size: Vector3): (boolean, string?)
			alive()
			assert(leases[lease] and lease.Active, "queue requires an Active lease from this cache")
			assert(cf.Position.Magnitude < math.huge, "Position must be finite")
			local scale = self:ScaleFor(lease.Id, size)
			if not scale then
				return false, "real Models require a uniform scale relative to Template Bounds"
			end
			if not pending[lease] and queuedParts + #lease.Parts > maxFlush then
				return false, "bulk move limit reached"
			end
			if lease.Scale ~= scale then
				lease.Instance:ScaleTo(scale)
				lease.Scale = scale
			end
			lease.CFrame = cf
			if not pending[lease] then
				pending[lease] = true
				queuedParts += #lease.Parts
			end
			return true, nil
		end,
		Flush = function(_self: Cache): (boolean, string?)
			alive()
			movedParts = 0
			if queuedParts == 0 then
				return true, nil
			end
			local parts: { BasePart } = {}
			local frames: { CFrame } = {}
			for lease in pending do
				for index, part in lease.Parts do
					local offset = lease.Offsets[index]
					table.insert(parts, part)
					table.insert(frames, lease.CFrame * (offset.Rotation + offset.Position * lease.Scale))
				end
			end
			local ok, message = pcall(function()
				worldRoot:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
			end)
			if not ok then
				return false, tostring(message)
			end
			for lease in pending do
				lease.Instance.WorldPivot = lease.CFrame
				lease.Instance.Parent = folder
			end
			movedParts = #parts
			queuedParts = 0
			table.clear(pending)
			return true, nil
		end,
		Available = function(_self: Cache, id: string): number
			local template = templates[id]
			return if template then #template.Free else 0
		end,
		PartCount = function(_self: Cache, id: string): number
			local template = templates[id]
			return if template then template.Parts else 0
		end,
		ScaleFor = function(_self: Cache, id: string, size: Vector3): number?
			local template = templates[id]
			if not template or size.Magnitude >= math.huge or not (math.min(size.X, size.Y, size.Z) > 0) then
				return nil
			end
			local ratio = size / template.Size
			if not (ratio.Magnitude < math.huge and ratio.X > 0) then
				return nil
			end
			if math.max(math.abs(ratio.Y - ratio.X), math.abs(ratio.Z - ratio.X)) > ratio.X * 0.001 then
				return nil
			end
			return ratio.X
		end,
		GetUsage = function(_self: Cache): Usage
			return {
				Cached = cached,
				Active = active,
				Idle = cached - active,
				QueuedParts = queuedParts,
				MovedParts = movedParts,
				ClonesCreated = clonesCreated,
			}
		end,
		Destroy = function(_self: Cache)
			if destroyed then
				return
			end
			destroyed = true
			for lease in leases do
				lease.Instance:Destroy()
			end
			for _, template in templates do
				template.Model:Destroy()
			end
			table.clear(leases)
			table.clear(templates)
			table.clear(pending)
			folder:Destroy()
			cached, active, queuedParts, movedParts = 0, 0, 0, 0
		end,
	}
	return cache
end

return table.freeze(InstanceCache)
