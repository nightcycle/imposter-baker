--!strict
local Scene = {}
Scene.Columns = 64
Scene.Rows = 64
Scene.Spacing = 8
Scene.InstanceCount = Scene.Columns * Scene.Rows + 4
Scene.WorldExtent = 768
Scene.TargetFps = 240
Scene.UpdateBudgetMilliseconds = 1
Scene.FrameReserveMilliseconds = 1

export type Placement = { name: string, cframe: CFrame, comparison: boolean }

function Scene.placements(names: { string }, sizes: { [string]: Vector3 }): { Placement }
	local placements: { Placement } = {}
	for index, name in names do
		local size = sizes[name]
		table.insert(
			placements,
			{ name = name, cframe = CFrame.new((index - 2.5) * 18 + 4.5, size.Y / 2 + 1, 0), comparison = true }
		)
	end
	for row = 0, Scene.Rows - 1 do
		for column = 0, Scene.Columns - 1 do
			local name = names[(row + column) % #names + 1]
			table.insert(placements, {
				name = name,
				cframe = CFrame.new(
					(column - (Scene.Columns - 1) / 2) * Scene.Spacing,
					sizes[name].Y / 2 + 0.05,
					24 + row * Scene.Spacing
				) * CFrame.Angles(0, math.rad(column * 30), 0),
				comparison = false,
			})
		end
	end
	return placements
end

return table.freeze(Scene)
