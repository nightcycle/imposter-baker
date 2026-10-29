--!strict
local Scheduler = require(game:GetService("ReplicatedStorage").ImposterRender.Scheduler)

return function()
	local time = 0
	local state = Scheduler.New(4, function(): number
		time += 1
		return time
	end)
	local visited: { number } = {}
	local function visit(id: number): boolean
		table.insert(visited, id)
		return id % 2 == 0
	end
	for id, distance in { 40, 10, 30, 20 } do
		Scheduler.Set(state, id, Vector3.new(distance, 0, 0))
	end
	Scheduler.Run(state, CFrame.identity, time, visit)
	assert(#visited == 0 and state.Phase == "idle", "zero headroom must defer all work")
	Scheduler.Run(state, CFrame.identity, time + 4, visit)
	assert(#visited == 0 and state.Cursor == 3, "queue construction must also honor the deadline")
	Scheduler.Run(state, CFrame.identity, time + 5, visit)
	assert(#visited == 1 and visited[1] == 2, "closest must Update first, regardless of insertion order")
	-- A camera move must not restart the pass and starve distant entries.
	local stats = Scheduler.Run(state, CFrame.new(100, 0, 0), time + 20, visit)
	assert(table.concat(visited, ",") == "2,4,3,1" and stats.Checked == 3 and stats.Updated == 1)
	assert(Scheduler.Pending(state) == 0)
	table.clear(visited)
	Scheduler.Run(state, CFrame.new(100, 0, 0), time + 20, visit)
	assert(table.concat(visited, ",") == "1,3,4,2", "next pass must refresh distances")
	table.clear(visited)
	Scheduler.Run(state, CFrame.new(100, 0, 0), time + 20, visit)
	assert(#visited == 0, "stationary Camera and unchanged Instances need no repeated work")

	Scheduler.Invalidate(state)
	Scheduler.Run(state, CFrame.identity, time + 7, visit) -- Build the heap, before any visit.
	assert(#visited == 0 and tostring(state.Phase) == "drain")
	Scheduler.Remove(state, 2)
	Scheduler.Set(state, 2, Vector3.zero)
	Scheduler.Set(state, 4, Vector3.new(50, 0, 0))
	Scheduler.Run(state, CFrame.identity, time + 20, visit)
	assert(
		table.concat(visited, ",") == "4,3,1",
		"moving handles must still Update; reused slots must skip stale nodes"
	)
	assert(Scheduler.Pending(state) == 4, "mutations during a pass must trigger another pass")
	table.clear(visited)
	Scheduler.Run(state, CFrame.identity, time + 20, visit)
	assert(table.concat(visited, ",") == "2,3,1,4")
	Scheduler.Clear(state)
	Scheduler.Run(state, CFrame.identity, time + 20, visit)
	assert(state.Count == 0 and Scheduler.Pending(state) == 0)

	-- Equal distances have a stable slot-order tie break, including sparse slots.
	table.clear(visited)
	Scheduler.Set(state, 4, Vector3.one)
	Scheduler.Set(state, 1, Vector3.one)
	Scheduler.Run(state, CFrame.identity, time + 20, visit)
	assert(table.concat(visited, ",") == "1,4")
	table.clear(visited)
	for frame = 1, 12 do
		Scheduler.Set(state, 1, Vector3.new(frame, 0, 0))
		Scheduler.Run(state, CFrame.identity, time + 3, visit)
	end
	assert(table.find(visited, 1) ~= nil, "continuous movement must not starve a queued handle")
	assert(math.abs(Scheduler.Budget().MaxMilliseconds - 1000 / 240 / 4) < 1e-8)
	assert(Scheduler.Budget({ MaxMilliseconds = 0 }).MaxMilliseconds == 0)
	for _, fps in { 0, -1, math.huge, 0 / 0 } do
		assert(not pcall(Scheduler.Budget, { TargetFps = fps }))
	end
	for _, ms in { -1, 5, math.huge, 0 / 0 } do
		assert(not pcall(Scheduler.Budget, { TargetFps = 240, MaxMilliseconds = ms }))
	end
	print("Scheduler deadlines, nearest-first passes, fairness, invalidation, and slot reuse passed")
end
