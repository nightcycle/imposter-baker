--!strict
local Atlas = {}

export type Rect = { Position: Vector2, Size: Vector2 }
export type Allocator = { Size: number, Free: { Rect } }

function Atlas.New(size: number): Allocator
	return { Size = size, Free = { { Position = Vector2.zero, Size = Vector2.one * size } } }
end

function Atlas.Allocate(allocator: Allocator, size: Vector2): Rect?
	for i, rect in allocator.Free do
		if size.X <= rect.Size.X and size.Y <= rect.Size.Y then
			table.remove(allocator.Free, i)
			local result = { Position = rect.Position, Size = size }
			local dx = rect.Size.X - size.X
			local dy = rect.Size.Y - size.Y
			if dx > 0 then
				table.insert(
					allocator.Free,
					{ Position = rect.Position + Vector2.new(size.X, 0), Size = Vector2.new(dx, size.Y) }
				)
			end
			if dy > 0 then
				table.insert(
					allocator.Free,
					{ Position = rect.Position + Vector2.new(0, size.Y), Size = Vector2.new(rect.Size.X, dy) }
				)
			end
			return result
		end
	end
	return nil
end

function Atlas.Release(allocator: Allocator, rect: Rect)
	table.insert(allocator.Free, rect)
	-- Merge adjoining free rectangles so unload/reload does not monotonically
	-- consume atlas capacity. Existing allocations never move.
	local changed = true
	while changed do
		changed = false
		for i = 1, #allocator.Free do
			local a = allocator.Free[i]
			for j = i + 1, #allocator.Free do
				local b = allocator.Free[j]
				local merged: Rect? = nil
				if a.Position.Y == b.Position.Y and a.Size.Y == b.Size.Y then
					if a.Position.X + a.Size.X == b.Position.X or b.Position.X + b.Size.X == a.Position.X then
						merged = {
							Position = Vector2.new(math.min(a.Position.X, b.Position.X), a.Position.Y),
							Size = Vector2.new(a.Size.X + b.Size.X, a.Size.Y),
						}
					end
				elseif a.Position.X == b.Position.X and a.Size.X == b.Size.X then
					if a.Position.Y + a.Size.Y == b.Position.Y or b.Position.Y + b.Size.Y == a.Position.Y then
						merged = {
							Position = Vector2.new(a.Position.X, math.min(a.Position.Y, b.Position.Y)),
							Size = Vector2.new(a.Size.X, a.Size.Y + b.Size.Y),
						}
					end
				end
				if merged then
					table.remove(allocator.Free, j)
					table.remove(allocator.Free, i)
					table.insert(allocator.Free, merged)
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
