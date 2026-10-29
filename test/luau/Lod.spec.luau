--!strict
local Lod = require(game:GetService("ReplicatedStorage").ImposterRender.Lod)

return function()
	local config = Lod.Resolve({ NearDistance = 20, FarDistance = 24, ReplacementMargin = 2 })
	assert(Lod.Distance(Vector3.new(3, 0, 4), Vector3.zero) == 5)
	assert(Lod.ShouldReplace(8, 11, config))
	assert(not Lod.ShouldReplace(9, 11, config), "equal boundary must not churn")
	assert(not Lod.ShouldReplace(21, 40, config), "outside promotion Distance stays an imposter")
	assert(Lod.Resolve({ MaxRealInstances = 0, MaxCreatesPerFrame = 0 }).MaxRealInstances == 0)
	for _, value in { -1, math.huge, 0 / 0 } do
		assert(not pcall(Lod.Resolve, { NearDistance = value }))
	end
	assert(not pcall(Lod.Resolve, { NearDistance = 30, FarDistance = 20 }))
	assert(not pcall(Lod.Resolve, { MaxRealInstances = 1.5 }))
	assert(not pcall(Lod.Resolve, { MaxTransitionsPerFrame = 1 }))
	assert(not pcall(Lod.Resolve, { PriorityBudgetFraction = 1 }))
	assert(not pcall(Lod.Resolve, { LookAheadSeconds = -1 }))
	local predictive = Lod.Resolve()
	local focus = Lod.GetFocus(CFrame.identity, { Velocity = Vector3.new(160, 0, 0) }, predictive)
	assert(focus.Target == Vector3.new(120, 0, 0), "160 studs/s should predict 120 studs ahead")
	assert(Lod.PriorityDistance(focus, Vector3.new(80, 0, 0)) < Lod.PriorityDistance(focus, Vector3.new(-20, 0, 0)))
	assert(
		Lod.PriorityDistance(focus, Vector3.new(-2, 0, 0)) < Lod.PriorityDistance(focus, Vector3.new(80, 0, 0)),
		"protect immediate surroundings"
	)
	local capped = Lod.GetFocus(
		CFrame.identity,
		{ Position = Vector3.new(10, 0, 0), Velocity = Vector3.new(10000, 0, 0) },
		predictive
	)
	assert((capped.Target - capped.Position).Magnitude == predictive.MaxLookAheadDistance)
	local facing = Lod.GetFocus(CFrame.identity, nil, predictive)
	assert(facing.Target == Vector3.new(0, 0, -24))
	assert(not pcall(Lod.GetFocus, CFrame.identity, { Velocity = Vector3.one * math.huge }, predictive))

	local ticks = 0
	local queue = Lod.NewQueue(32, function(): number
		ticks += 1
		return ticks
	end)
	local visited: { number } = {}
	local function visit(id: number): boolean
		table.insert(visited, id)
		return true
	end
	Lod.Set(queue, 1, Vector3.new(-20, 0, 0))
	Lod.Set(queue, 2, Vector3.new(80, 0, 0))
	Lod.Set(queue, 3, Vector3.new(-2, 0, 0))
	-- A far-field workload must not get scanned before the travel corridor.
	for id = 4, 4100 do
		Lod.Set(queue, id, Vector3.new(600, 0, 0))
	end
	Lod.RunQueue(queue, focus, predictive, ticks, visit)
	assert(#visited == 0 and queue.Focus == nil)
	Lod.RunQueue(queue, focus, predictive, ticks + 20, visit)
	assert(queue.Collecting and #visited == 0, "collection must yield to the deadline")
	local stats = Lod.RunQueue(queue, focus, predictive, ticks + 300, visit)
	assert(table.concat(visited, ",") == "3,2,1" and stats.Checked == 3)
	-- Turn around while a pass is incomplete: discard its old priorities.
	table.clear(visited)
	Lod.RunQueue(queue, focus, predictive, ticks + 10, visit)
	local reverse = Lod.GetFocus(CFrame.identity, { Velocity = Vector3.new(-160, 0, 0) }, predictive)
	Lod.RunQueue(queue, reverse, predictive, ticks + 300, visit)
	assert(table.concat(visited, ",") == "3,1", "turns must preempt stale forward candidates")
	Lod.Remove(queue, 3)
	Lod.Set(queue, 2, Vector3.new(-10, 0, 0))
	table.clear(visited)
	Lod.RunQueue(queue, reverse, predictive, ticks + 300, visit)
	assert(table.concat(visited, ",") == "2,1", "moves, removals and cell membership must stay in sync")
	Lod.Clear(queue)
	assert(next(queue.Items) == nil and next(queue.Cells) == nil and #queue.Heap == 0)
	print("LOD Distance, replacement hysteresis, disable options, and validation passed")
end
