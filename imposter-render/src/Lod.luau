--!strict
local Lod = {}

export type Options = {
	NearDistance: number?,
	FarDistance: number?,
	ReplacementMargin: number?,
	MaxRealInstances: number?,
	MaxTransitionsPerFrame: number?,
	MaxCreatesPerFrame: number?,
	LookAheadSeconds: number?,
	MaxLookAheadDistance: number?,
	CameraLookAheadDistance: number?,
	PriorityBudgetFraction: number?,
}
export type Config = {
	[string]: number,
	NearDistance: number,
	FarDistance: number,
	ReplacementMargin: number,
	MaxRealInstances: number,
	MaxTransitionsPerFrame: number,
	MaxCreatesPerFrame: number,
	LookAheadSeconds: number,
	MaxLookAheadDistance: number,
	CameraLookAheadDistance: number,
	PriorityBudgetFraction: number,
}

export type Motion = { Position: Vector3?, Velocity: Vector3? }
export type Focus = { Position: Vector3, Target: Vector3 }
type Item = { Id: number, Position: Vector3, Cell: string, Index: number }
type Node = { Item: Item, Distance: number }
export type Queue = {
	Items: { [number]: Item },
	Cells: { [string]: { Item } },
	CellSize: number,
	Clock: () -> number,
	Revision: number,
	PassRevision: number,
	Focus: Focus?,
	Radius: number,
	Heap: { Node },
	Min: Vector3,
	Max: Vector3,
	X: number,
	Y: number,
	Z: number,
	Index: number,
	Collecting: boolean,
}

function Lod.Resolve(options: Options?): Config
	local o: Options = options or {}
	local config: Config = {
		NearDistance = o.NearDistance or 48,
		FarDistance = o.FarDistance or 64,
		ReplacementMargin = o.ReplacementMargin or 4,
		MaxRealInstances = o.MaxRealInstances or 64,
		MaxTransitionsPerFrame = o.MaxTransitionsPerFrame or 4,
		MaxCreatesPerFrame = o.MaxCreatesPerFrame or 1,
		LookAheadSeconds = o.LookAheadSeconds or 0.75,
		MaxLookAheadDistance = o.MaxLookAheadDistance or 192,
		CameraLookAheadDistance = o.CameraLookAheadDistance or 24,
		PriorityBudgetFraction = o.PriorityBudgetFraction or 0.65,
	}
	for key, value in config do
		assert(value >= 0 and value < math.huge, `{key} must be nonnegative and finite`)
	end
	assert(config.FarDistance >= config.NearDistance, "FarDistance must be at least NearDistance")
	for _, value in { config.MaxRealInstances, config.MaxTransitionsPerFrame, config.MaxCreatesPerFrame } do
		assert(value % 1 == 0, "LOD counts must be integers")
	end
	assert(config.MaxTransitionsPerFrame >= 2, "MaxTransitionsPerFrame must allow a replacement pair")
	assert(config.PriorityBudgetFraction <= 0.9, "PriorityBudgetFraction must leave at least 10% for visual updates")
	return table.freeze(config)
end

function Lod.GetFocus(camera: CFrame, motion: Motion?, config: Config): Focus
	local position = if motion and motion.Position then motion.Position else camera.Position
	local velocity = if motion and motion.Velocity then motion.Velocity else Vector3.zero
	assert(position.Magnitude < math.huge and velocity.Magnitude < math.huge, "LOD motion must be finite")
	local speed = velocity.Magnitude
	local offset = if speed > 1
		then velocity / speed * math.min(speed * config.LookAheadSeconds, config.MaxLookAheadDistance)
		else camera.LookVector * math.min(config.CameraLookAheadDistance, config.MaxLookAheadDistance)
	return { Position = position, Target = position + offset }
end

-- Distance to the predicted travel segment, with an along-path penalty so
-- immediate surroundings still outrank distant objects on the same route.
function Lod.PriorityDistance(focus: Focus, center: Vector3): number
	local segment = focus.Target - focus.Position
	local length = segment.Magnitude
	if length < 1e-6 then
		return (center - focus.Position).Magnitude
	end
	local direction = segment / length
	local along = math.clamp((center - focus.Position):Dot(direction), 0, length)
	return (center - focus.Position - direction * along).Magnitude + along * 0.2
end

-- Distance to the model center, consistent with Scheduler's nearest-first order.
function Lod.Distance(camera: Vector3, center: Vector3): number
	return (camera - center).Magnitude
end

function Lod.ShouldReplace(candidate: number, active: number, config: Config): boolean
	return candidate <= config.NearDistance and candidate + config.ReplacementMargin < active
end

local function cellKey(x: number, y: number, z: number): string
	return `{x}:{y}:{z}`
end

function Lod.NewQueue(cellSize: number?, clock: (() -> number)?): Queue
	local size = cellSize or 32
	assert(size > 0 and size < math.huge, "cell size must be positive and finite")
	return {
		Items = {},
		Cells = {},
		CellSize = size,
		Clock = clock or os.clock,
		Revision = 0,
		PassRevision = -1,
		Focus = nil,
		Radius = 0,
		Heap = {},
		Min = Vector3.zero,
		Max = Vector3.zero,
		X = 0,
		Y = 0,
		Z = 0,
		Index = 1,
		Collecting = false,
	}
end

function Lod.Remove(queue: Queue, id: number)
	local item = queue.Items[id]
	if not item then
		return
	end
	local cell = queue.Cells[item.Cell]
	local last = table.remove(cell) :: Item
	if last ~= item then
		cell[item.Index] = last
		last.Index = item.Index
	end
	if #cell == 0 then
		queue.Cells[item.Cell] = nil
	end
	queue.Items[id] = nil
	queue.Revision += 1
end

function Lod.Set(queue: Queue, id: number, position: Vector3)
	assert(position.Magnitude < math.huge, "position must be finite")
	Lod.Remove(queue, id)
	local p = position / queue.CellSize
	local key = cellKey(math.floor(p.X), math.floor(p.Y), math.floor(p.Z))
	local cell = queue.Cells[key]
	if not cell then
		cell = {}
		queue.Cells[key] = cell
	end
	local item = { Id = id, Position = position, Cell = key, Index = #cell + 1 }
	queue.Items[id] = item
	table.insert(cell, item)
	queue.Revision += 1
end

function Lod.Clear(queue: Queue)
	table.clear(queue.Items)
	table.clear(queue.Cells)
	table.clear(queue.Heap)
	queue.Focus = nil
	queue.Revision += 1
end

local function before(a: Node, b: Node): boolean
	return a.Distance < b.Distance or (a.Distance == b.Distance and a.Item.Id < b.Item.Id)
end

local function push(heap: { Node }, node: Node)
	local index = #heap + 1
	while index > 1 do
		local parent = math.floor(index / 2)
		if not before(node, heap[parent]) then
			break
		end
		heap[index] = heap[parent]
		index = parent
	end
	heap[index] = node
end

local function pop(heap: { Node }): Node
	local first = heap[1]
	local last = table.remove(heap) :: Node
	if #heap == 0 then
		return first
	end
	local index = 1
	while index * 2 <= #heap do
		local child = index * 2
		if child < #heap and before(heap[child + 1], heap[child]) then
			child += 1
		end
		if not before(heap[child], last) then
			break
		end
		heap[index] = heap[child]
		index = child
	end
	heap[index] = last
	return first
end

-- Spatial queries avoid waiting for every distant quad. Query construction,
-- heap operations and visits all share the caller's deadline. Large turns or
-- movement discard stale priority work; the visual scheduler retains fairness.
function Lod.RunQueue(
	queue: Queue,
	focus: Focus,
	config: Config,
	deadline: number,
	visit: (number) -> boolean
): { Checked: number, Updated: number }
	local stats = { Checked = 0, Updated = 0 }
	if queue.Clock() >= deadline then
		return stats
	end
	local previous = queue.Focus
	local threshold = math.clamp(config.NearDistance * 0.25, 4, 16)
	if
		not previous
		or queue.PassRevision ~= queue.Revision
		or queue.Radius ~= config.NearDistance
		or (focus.Position - previous.Position).Magnitude >= threshold
		or (focus.Target - previous.Target).Magnitude >= threshold
		or (not queue.Collecting and #queue.Heap == 0)
	then
		table.clear(queue.Heap)
		queue.Focus = focus
		queue.Radius = config.NearDistance
		queue.PassRevision = queue.Revision
		local radius = Vector3.one * config.NearDistance
		queue.Min = (focus.Position:Min(focus.Target) - radius) / queue.CellSize
		queue.Max = (focus.Position:Max(focus.Target) + radius) / queue.CellSize
		queue.X, queue.Y, queue.Z = math.floor(queue.Min.X), math.floor(queue.Min.Y), math.floor(queue.Min.Z)
		queue.Index = 1
		queue.Collecting = true
	end
	local snapshot = queue.Focus :: Focus
	while queue.Clock() < deadline do
		if queue.Collecting then
			local cell = queue.Cells[cellKey(queue.X, queue.Y, queue.Z)]
			local item = if cell then cell[queue.Index] else nil
			if item then
				queue.Index += 1
				local distance = Lod.PriorityDistance(snapshot, item.Position)
				if distance <= queue.Radius then
					push(queue.Heap, { Item = item, Distance = distance })
				end
			else
				queue.Index = 1
				queue.X += 1
				if queue.X > queue.Max.X then
					queue.X = math.floor(queue.Min.X)
					queue.Y += 1
					if queue.Y > queue.Max.Y then
						queue.Y = math.floor(queue.Min.Y)
						queue.Z += 1
						if queue.Z > queue.Max.Z then
							queue.Collecting = false
						end
					end
				end
			end
		else
			if #queue.Heap == 0 then
				break
			end
			local node = pop(queue.Heap)
			if queue.Items[node.Item.Id] == node.Item then
				stats.Checked += 1
				if visit(node.Item.Id) then
					stats.Updated += 1
				end
			end
		end
	end
	return stats
end

return table.freeze(Lod)
