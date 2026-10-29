--!strict
local Atlas = {}

export type Rect = { position: Vector2, size: Vector2 }
export type Allocator = { size: number, free: { Rect } }

function Atlas.new(size: number): Allocator
	return { size = size, free = { { position = Vector2.zero, size = Vector2.one * size } } }
end

function Atlas.allocate(allocator: Allocator, size: Vector2): Rect?
	for i, rect in allocator.free do
		if size.X <= rect.size.X and size.Y <= rect.size.Y then
			table.remove(allocator.free, i)
			local result = { position = rect.position, size = size }
			local dx = rect.size.X - size.X
			local dy = rect.size.Y - size.Y
			if dx > 0 then
				table.insert(
					allocator.free,
					{ position = rect.position + Vector2.new(size.X, 0), size = Vector2.new(dx, size.Y) }
				)
			end
			if dy > 0 then
				table.insert(
					allocator.free,
					{ position = rect.position + Vector2.new(0, size.Y), size = Vector2.new(rect.size.X, dy) }
				)
			end
			return result
		end
	end
	return nil
end

function Atlas.release(allocator: Allocator, rect: Rect)
	table.insert(allocator.free, rect)
	-- Merge adjoining free rectangles so unload/reload does not monotonically
	-- consume atlas capacity. Existing allocations never move.
	local changed = true
	while changed do
		changed = false
		for i = 1, #allocator.free do
			local a = allocator.free[i]
			for j = i + 1, #allocator.free do
				local b = allocator.free[j]
				local merged: Rect? = nil
				if a.position.Y == b.position.Y and a.size.Y == b.size.Y then
					if a.position.X + a.size.X == b.position.X or b.position.X + b.size.X == a.position.X then
						merged = {
							position = Vector2.new(math.min(a.position.X, b.position.X), a.position.Y),
							size = Vector2.new(a.size.X + b.size.X, a.size.Y),
						}
					end
				elseif a.position.X == b.position.X and a.size.X == b.size.X then
					if a.position.Y + a.size.Y == b.position.Y or b.position.Y + b.size.Y == a.position.Y then
						merged = {
							position = Vector2.new(a.position.X, math.min(a.position.Y, b.position.Y)),
							size = Vector2.new(a.size.X, a.size.Y + b.size.Y),
						}
					end
				end
				if merged then
					table.remove(allocator.free, j)
					table.remove(allocator.free, i)
					table.insert(allocator.free, merged)
					changed = true
					break
				end
			end
			if changed then
				break
			end
		end
	end
end

return table.freeze(Atlas)
