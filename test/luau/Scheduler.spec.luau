--!strict
local Scheduler = require(game:GetService("ReplicatedStorage").ImposterRender.Scheduler)

return function()
	local time = 0
	local state = Scheduler.new(4, function(): number
		time += 1
		return time
	end)
	local visited: { number } = {}
	local function visit(id: number): boolean
		table.insert(visited, id)
		return id % 2 == 0
	end
	for id, distance in { 40, 10, 30, 20 } do
		Scheduler.set(state, id, Vector3.new(distance, 0, 0))
	end
	Scheduler.run(state, CFrame.identity, time, visit)
	assert(#visited == 0 and state.phase == "idle", "zero headroom must defer all work")
	Scheduler.run(state, CFrame.identity, time + 4, visit)
	assert(#visited == 0 and state.cursor == 3, "queue construction must also honor the deadline")
	Scheduler.run(state, CFrame.identity, time + 5, visit)
	assert(#visited == 1 and visited[1] == 2, "closest must update first, regardless of insertion order")
	-- A camera move must not restart the pass and starve distant entries.
	local stats = Scheduler.run(state, CFrame.new(100, 0, 0), time + 20, visit)
	assert(table.concat(visited, ",") == "2,4,3,1" and stats.checked == 3 and stats.updated == 1)
	assert(Scheduler.pending(state) == 0)
	table.clear(visited)
	Scheduler.run(state, CFrame.new(100, 0, 0), time + 20, visit)
	assert(table.concat(visited, ",") == "1,3,4,2", "next pass must refresh distances")
	table.clear(visited)
	Scheduler.run(state, CFrame.new(100, 0, 0), time + 20, visit)
	assert(#visited == 0, "stationary camera and unchanged instances need no repeated work")

	Scheduler.invalidate(state)
	Scheduler.run(state, CFrame.identity, time + 7, visit) -- Build the heap, before any visit.
	assert(#visited == 0 and tostring(state.phase) == "drain")
	Scheduler.remove(state, 2)
	Scheduler.set(state, 2, Vector3.zero)
	Scheduler.set(state, 4, Vector3.new(50, 0, 0))
	Scheduler.run(state, CFrame.identity, time + 20, visit)
	assert(
		table.concat(visited, ",") == "4,3,1",
		"moving handles must still update; reused slots must skip stale nodes"
	)
	assert(Scheduler.pending(state) == 4, "mutations during a pass must trigger another pass")
	table.clear(visited)
	Scheduler.run(state, CFrame.identity, time + 20, visit)
	assert(table.concat(visited, ",") == "2,3,1,4")
	Scheduler.clear(state)
	Scheduler.run(state, CFrame.identity, time + 20, visit)
	assert(state.count == 0 and Scheduler.pending(state) == 0)

	-- Equal distances have a stable slot-order tie break, including sparse slots.
	table.clear(visited)
	Scheduler.set(state, 4, Vector3.one)
	Scheduler.set(state, 1, Vector3.one)
	Scheduler.run(state, CFrame.identity, time + 20, visit)
	assert(table.concat(visited, ",") == "1,4")
	table.clear(visited)
	for frame = 1, 12 do
		Scheduler.set(state, 1, Vector3.new(frame, 0, 0))
		Scheduler.run(state, CFrame.identity, time + 3, visit)
	end
	assert(table.find(visited, 1) ~= nil, "continuous movement must not starve a queued handle")
	assert(math.abs(Scheduler.budget().maxMilliseconds - 1000 / 240 / 4) < 1e-8)
	assert(Scheduler.budget({ maxMilliseconds = 0 }).maxMilliseconds == 0)
	for _, fps in { 0, -1, math.huge, 0 / 0 } do
		assert(not pcall(Scheduler.budget, { targetFps = fps }))
	end
	for _, ms in { -1, 5, math.huge, 0 / 0 } do
		assert(not pcall(Scheduler.budget, { targetFps = 240, maxMilliseconds = ms }))
	end
	print("Scheduler deadlines, nearest-first passes, fairness, invalidation, and slot reuse passed")
end
