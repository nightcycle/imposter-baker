--!strict
-- A pass builds a distance heap incrementally, then visits nearest first.
-- Completing each pass before reprioritizing prevents distant-item starvation.
local Scheduler = {}

export type BudgetInput = { targetFps: number?, maxMilliseconds: number? }
export type Budget = { targetFps: number, maxMilliseconds: number }
export type Stats = { checked: number, updated: number }
type Item = { id: number, position: Vector3 }
type Node = { item: Item, distance: number }
export type State = {
	capacity: number,
	items: { [number]: Item },
	count: number,
	revision: number,
	completedRevision: number,
	passRevision: number,
	completedCamera: CFrame?,
	camera: CFrame,
	heap: { Node },
	cursor: number,
	collected: number,
	phase: "idle" | "collect" | "drain",
	clock: () -> number,
}

function Scheduler.budget(input: BudgetInput?): Budget
	local options: BudgetInput = input or {}
	local fps = options.targetFps or 240
	assert(fps > 0 and fps < math.huge, "targetFps must be positive and finite")
	local milliseconds = if options.maxMilliseconds == nil then 1000 / fps * 0.25 else options.maxMilliseconds
	assert(
		milliseconds >= 0 and milliseconds < math.huge and milliseconds <= 1000 / fps,
		"maxMilliseconds must be finite and fit within the target frame interval"
	)
	return table.freeze({ targetFps = fps, maxMilliseconds = milliseconds })
end

function Scheduler.new(capacity: number, clock: (() -> number)?): State
	return {
		capacity = capacity,
		items = {},
		count = 0,
		revision = 0,
		completedRevision = -1,
		passRevision = 0,
		completedCamera = nil,
		camera = CFrame.identity,
		heap = {},
		cursor = 1,
		collected = 0,
		phase = "idle",
		clock = clock or os.clock,
	}
end

function Scheduler.set(state: State, id: number, position: Vector3)
	assert(id >= 1 and id <= state.capacity and id % 1 == 0, "scheduler slot out of range")
	local item = state.items[id]
	if item then
		-- Preserve identity while moving so a continuously animated handle can
		-- still be visited in this pass, using its latest bounds. Reprioritize
		-- next pass; only removal/reuse invalidates the queued identity.
		item.position = position
	else
		state.count += 1
		state.items[id] = { id = id, position = position }
	end
	state.revision += 1
end

function Scheduler.remove(state: State, id: number)
	if state.items[id] then
		state.items[id] = nil
		state.count -= 1
		state.revision += 1
	end
end

function Scheduler.invalidate(state: State)
	state.revision += 1
end

function Scheduler.clear(state: State)
	table.clear(state.items)
	table.clear(state.heap)
	state.count = 0
	state.phase = "idle"
	state.revision += 1
end

local function before(a: Node, b: Node): boolean
	return a.distance < b.distance or (a.distance == b.distance and a.item.id < b.item.id)
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
	local result = heap[1]
	local last = table.remove(heap) :: Node
	if #heap == 0 then
		return result
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
	return result
end

function Scheduler.pending(state: State): number
	if state.phase == "idle" then
		return if state.completedRevision == state.revision then 0 else state.count
	end
	return #state.heap + (if state.phase == "collect" then math.max(0, state.count - state.collected) else 0)
end

function Scheduler.run(state: State, camera: CFrame, deadline: number, visit: (number) -> boolean): Stats
	local stats: Stats = { checked = 0, updated = 0 }
	while state.clock() < deadline do
		if state.phase == "idle" then
			if state.count == 0 or (state.completedCamera == camera and state.completedRevision == state.revision) then
				break
			end
			state.camera = camera
			state.passRevision = state.revision
			state.cursor = 1
			state.collected = 0
			state.phase = "collect"
		elseif state.phase == "collect" then
			if state.cursor > state.capacity then
				state.phase = "drain"
			else
				local item = state.items[state.cursor]
				if item then
					local delta = item.position - state.camera.Position
					push(state.heap, { item = item, distance = delta:Dot(delta) })
					state.collected += 1
				end
				state.cursor += 1
			end
		else
			if #state.heap == 0 then
				state.completedRevision = state.passRevision
				state.completedCamera = state.camera
				state.phase = "idle"
				-- One completed pass per call, even if the camera moved mid-pass.
				break
			end
			local node = pop(state.heap)
			if state.items[node.item.id] == node.item then
				stats.checked += 1
				if visit(node.item.id) then
					stats.updated += 1
				end
			end
		end
	end
	return stats
end

return table.freeze(Scheduler)
