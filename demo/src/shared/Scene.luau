--!strict
local Scene = {}

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
	for row = 0, 3 do
		for column = 0, 11 do
			local name = names[(row * 12 + column) % #names + 1]
			table.insert(placements, {
				name = name,
				cframe = CFrame.new((column - 5.5) * 7, sizes[name].Y / 2 + 1, 18 + row * 7)
					* CFrame.Angles(0, math.rad(column * 30), 0),
				comparison = false,
			})
		end
	end
	return placements
end

return table.freeze(Scene)
