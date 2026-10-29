--!strict
-- A pass builds a distance heap incrementally, then visits nearest first.
-- Completing each pass before reprioritizing prevents distant-item starvation.
local Scheduler = {}

export type BudgetInput = { TargetFps: number?, MaxMilliseconds: number? }
export type Budget = { TargetFps: number, MaxMilliseconds: number }
export type Stats = { Checked: number, Updated: number }
type Item = { Id: number, Position: Vector3 }
type Node = { Item: Item, Distance: number }
export type State = {
	Capacity: number,
	Items: { [number]: Item },
	Count: number,
	Revision: number,
	CompletedRevision: number,
	PassRevision: number,
	CompletedCamera: CFrame?,
	Camera: CFrame,
	Heap: { Node },
	Cursor: number,
	Collected: number,
	Phase: "idle" | "collect" | "drain",
	Clock: () -> number,
}

function Scheduler.Budget(input: BudgetInput?): Budget
	local options: BudgetInput = input or {}
	local fps = options.TargetFps or 240
	assert(fps > 0 and fps < math.huge, "TargetFps must be positive and finite")
	local milliseconds = if options.MaxMilliseconds == nil then 1000 / fps * 0.25 else options.MaxMilliseconds
	assert(
		milliseconds >= 0 and milliseconds < math.huge and milliseconds <= 1000 / fps,
		"MaxMilliseconds must be finite and fit within the target frame interval"
	)
	return table.freeze({ TargetFps = fps, MaxMilliseconds = milliseconds })
end

function Scheduler.New(capacity: number, clock: (() -> number)?): State
	return {
		Capacity = capacity,
		Items = {},
		Count = 0,
		Revision = 0,
		CompletedRevision = -1,
		PassRevision = 0,
		CompletedCamera = nil,
		Camera = CFrame.identity,
		Heap = {},
		Cursor = 1,
		Collected = 0,
		Phase = "idle",
		Clock = clock or os.clock,
	}
end

function Scheduler.Set(state: State, id: number, position: Vector3)
	assert(id >= 1 and id <= state.Capacity and id % 1 == 0, "scheduler slot out of range")
	local item = state.Items[id]
	if item then
		-- Preserve identity while moving so a continuously animated handle can
		-- still be visited in this pass, using its latest bounds. Reprioritize
		-- next pass; only removal/reuse invalidates the queued identity.
		item.Position = position
	else
		state.Count += 1
		state.Items[id] = { Id = id, Position = position }
	end
	state.Revision += 1
end

function Scheduler.Remove(state: State, id: number)
	if state.Items[id] then
		state.Items[id] = nil
		state.Count -= 1
		state.Revision += 1
	end
end

function Scheduler.Invalidate(state: State)
	state.Revision += 1
end

function Scheduler.Clear(state: State)
	table.clear(state.Items)
	table.clear(state.Heap)
	state.Count = 0
	state.Phase = "idle"
	state.Revision += 1
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

function Scheduler.Pending(state: State): number
	if state.Phase == "idle" then
		return if state.CompletedRevision == state.Revision then 0 else state.Count
	end
	return #state.Heap + (if state.Phase == "collect" then math.max(0, state.Count - state.Collected) else 0)
end

function Scheduler.Run(state: State, camera: CFrame, deadline: number, visit: (number) -> boolean): Stats
	local stats: Stats = { Checked = 0, Updated = 0 }
	while state.Clock() < deadline do
		if state.Phase == "idle" then
			if state.Count == 0 or (state.CompletedCamera == camera and state.CompletedRevision == state.Revision) then
				break
			end
			state.Camera = camera
			state.PassRevision = state.Revision
			state.Cursor = 1
			state.Collected = 0
			state.Phase = "collect"
		elseif state.Phase == "collect" then
			if state.Cursor > state.Capacity then
				state.Phase = "drain"
			else
				local item = state.Items[state.Cursor]
				if item then
					local delta = item.Position - state.Camera.Position
					push(state.Heap, { Item = item, Distance = delta:Dot(delta) })
					state.Collected += 1
				end
				state.Cursor += 1
			end
		else
			if #state.Heap == 0 then
				state.CompletedRevision = state.PassRevision
				state.CompletedCamera = state.Camera
				state.Phase = "idle"
				-- One completed pass per call, even if the camera moved mid-pass.
				break
			end
			local node = pop(state.Heap)
			if state.Items[node.Item.Id] == node.Item then
				stats.Checked += 1
				if visit(node.Item.Id) then
					stats.Updated += 1
				end
			end
		end
	end
	return stats
end

return table.freeze(Scheduler)
