--!strict
local Scene = require(game:GetService("ReplicatedStorage").Demo.Scene)

return function()
	local names = { "grass", "pillar", "lilypad", "tree" }
	local sizes: { [string]: Vector3 } = {
		["grass"] = Vector3.one,
		["pillar"] = Vector3.one * 5,
		["lilypad"] = Vector3.one * 2,
		["tree"] = Vector3.one * 5,
	}
	local placements = Scene.Placements(names, sizes)
	local repeated = Scene.Placements(names, sizes)
	assert(#placements == 4100 and #placements == Scene.InstanceCount)
	local positions: { Vector2 } = {}
	local counts: { [string]: number } = {}
	local quadrants = { 0, 0, 0, 0 }
	for index, placement in placements do
		assert(placement.Name == repeated[index].Name and placement.CFrame == repeated[index].CFrame)
		local position = placement.CFrame.Position
		if index <= #names then
			assert(placement.Comparison and placement.Name == names[index])
			assert(position == Vector3.new((index - 2.5) * 18 + 4.5, sizes[placement.Name].Y / 2 + 1, 0))
		else
			assert(not placement.Comparison)
			local offset = position - Scene.Center
			local edge = Scene.BaseplateSize / 2 - Scene.EdgeMargin
			assert(math.abs(offset.X) <= edge and math.abs(offset.Z) <= edge)
			assert(
				math.max(math.abs(offset.X), math.abs(offset.Z)) + sizes[placement.Name].Magnitude / math.sqrt(2)
					< Scene.WorldExtent
			)
			assert(math.abs(position.Y - sizes[placement.Name].Y / 2 - 0.05) < 1e-5)
			assert(
				position.X < Scene.StageMin.X
					or position.X > Scene.StageMax.X
					or position.Z < Scene.StageMin.Y
					or position.Z > Scene.StageMax.Y
			)
			assert((placement.CFrame.UpVector - Vector3.yAxis).Magnitude < 1e-5)
			local quadrant = 1 + (if offset.X > 0 then 1 else 0) + (if offset.Z > 0 then 2 else 0)
			quadrants[quadrant] += 1
			counts[placement.Name] = (counts[placement.Name] or 0) + 1
			table.insert(positions, Vector2.new(position.X, position.Z))
		end
	end
	for _, count in quadrants do
		assert(count > 800 and count < 1200, "decorations must cover the enlarged baseplate")
	end
	for _, name in names do
		assert(counts[name] == 1024)
	end
	-- Check spacing independently of the spatial hash used to generate the scene.
	table.sort(positions, function(a: Vector2, b: Vector2): boolean
		return a.X < b.X
	end)
	for index, position in positions do
		for other = index + 1, #positions do
			if positions[other].X - position.X >= Scene.MinimumSpacing then
				break
			end
			assert((position - positions[other]).Magnitude >= Scene.MinimumSpacing - 1e-4)
		end
	end
	print("Demo scatter: repeatable positions, clear spawn, balanced models, spacing, and bounds passed")
end
