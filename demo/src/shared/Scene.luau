--!strict
local Scene = {}
Scene.FieldCount = 4096
Scene.BaseplateSize = 1536
Scene.Center = Vector3.new(0, 0, 256)
Scene.EdgeMargin = 24
Scene.MinimumSpacing = 6
Scene.ScatterSeed = 1729
Scene.StageMin = Vector2.new(-48, -32)
Scene.StageMax = Vector2.new(48, 16)
Scene.InstanceCount = Scene.FieldCount + 4
Scene.WorldExtent = 768
Scene.TargetFps = 240
Scene.UpdateBudgetMilliseconds = 1
Scene.FrameReserveMilliseconds = 1
Scene.RealNearDistance = 48
Scene.RealFarDistance = 64
Scene.MaxRealInstances = 64
Scene.RealPrewarmPerModel = 16
Scene.RealLookAheadSeconds = 0.75
Scene.RealMaxLookAheadDistance = 192
Scene.RealCameraLookAheadDistance = 24

export type Placement = { Name: string, CFrame: CFrame, Comparison: boolean }

function Scene.Placements(names: { string }, sizes: { [string]: Vector3 }): { Placement }
	assert(#names > 0, "at least one decoration is required")
	local placements: { Placement } = {}
	for index, name in names do
		local size = sizes[name]
		table.insert(placements, {
			Name = name,
			CFrame = CFrame.new((index - 2.5) * 18 + 4.5, size.Y / 2 + 1, 0),
			Comparison = true,
		})
	end
	-- A local Park-Miller sequence keeps rebuilds repeatable without changing
	-- the game's random state. The same sequence runs in Studio and offline tests.
	local seed = Scene.ScatterSeed
	local function random(): number
		seed = seed * 48271 % 2147483647
		return seed / 2147483647
	end
	local spacing = Scene.MinimumSpacing
	local cells: { [number]: { [number]: { Vector2 } } } = {}
	local half = Scene.BaseplateSize / 2 - Scene.EdgeMargin
	local count, attempts = 0, 0
	while count < Scene.FieldCount do
		attempts += 1
		assert(attempts <= Scene.FieldCount * 100, "scatter is too dense; reduce FieldCount or MinimumSpacing")
		local position =
			Vector2.new(Scene.Center.X + (random() * 2 - 1) * half, Scene.Center.Z + (random() * 2 - 1) * half)
		if
			position.X >= Scene.StageMin.X
			and position.X <= Scene.StageMax.X
			and position.Y >= Scene.StageMin.Y
			and position.Y <= Scene.StageMax.Y
		then
			continue
		end
		local x, z = math.floor(position.X / spacing), math.floor(position.Y / spacing)
		local clear = true
		for dx = -1, 1 do
			local column = cells[x + dx]
			if column then
				for dz = -1, 1 do
					local neighbors = column[z + dz]
					if neighbors then
						for _, other in neighbors do
							if (position - other).Magnitude < spacing then
								clear = false
								break
							end
						end
					end
				end
			end
		end
		if not clear then
			continue
		end
		local column = cells[x]
		if not column then
			column = {}
			cells[x] = column
		end
		local cell = column[z]
		if not cell then
			cell = {}
			column[z] = cell
		end
		table.insert(cell, position)
		local name = names[count % #names + 1]
		table.insert(placements, {
			Name = name,
			CFrame = CFrame.new(position.X, sizes[name].Y / 2 + 0.05, position.Y)
				* CFrame.Angles(0, random() * math.pi * 2, 0),
			Comparison = false,
		})
		count += 1
	end
	return placements
end

return table.freeze(Scene)
