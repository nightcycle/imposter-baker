--!strict
-- Layout version 1. Keep these conventions in sync with src/config.rs.
local Util = {}

export type LayoutInput = {
	PanShotCount: number?,
	TiltShotCount: number?,
	MaxResolutionPx: number?,
	PaddingPx: number?,
	TiltConstraints: NumberRange?,
	TiltOffset: number?,
}
export type Layout = {
	PanShotCount: number,
	TiltShotCount: number,
	MaxResolutionPx: number,
	PaddingPx: number,
	TiltConstraints: NumberRange,
	TiltOffset: number,
}
export type Shot = {
	Index: number,
	Key: string,
	YawDegrees: number,
	PitchDegrees: number,
	Right: Vector3,
	Up: Vector3,
	Toward: Vector3,
	Position: Vector2,
}
export type Solution = {
	Shot: Shot,
	CFrame: CFrame,
	Size: Vector2,
	UVMin: Vector2,
	UVMax: Vector2,
	Distance: number,
	ProjectedHeight: number,
}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function integer(value: number, lo: number, hi: number, name: string)
	assert(finite(value) and value % 1 == 0 and value >= lo and value <= hi, `{name} must be an integer in {lo}..{hi}`)
end

function Util.Layout(input: LayoutInput?): Layout
	local options: LayoutInput = input or {}
	local result: Layout = {
		PanShotCount = options.PanShotCount or 8,
		TiltShotCount = options.TiltShotCount or 1,
		MaxResolutionPx = options.MaxResolutionPx or 252,
		PaddingPx = if options.PaddingPx == nil then 2 else options.PaddingPx,
		TiltConstraints = options.TiltConstraints or NumberRange.new(-180, 180),
		TiltOffset = options.TiltOffset or 0,
	}
	integer(result.PanShotCount, 1, 256, "PanShotCount")
	integer(result.TiltShotCount, 1, 256, "TiltShotCount")
	assert(result.PanShotCount * result.TiltShotCount <= 4096, "at most 4096 shots are supported")
	integer(result.MaxResolutionPx, 1, 4096, "MaxResolutionPx")
	integer(result.PaddingPx, 0, 64, "PaddingPx")
	assert(finite(result.TiltOffset) and math.abs(result.TiltOffset) <= 180, "TiltOffset must be in -180..180 degrees")
	local range = result.TiltConstraints
	assert(
		finite(range.Min) and finite(range.Max) and range.Min >= -180 and range.Max <= 180 and range.Min <= range.Max,
		"invalid TiltConstraints"
	)
	return table.freeze(result)
end

-- Read the same root attributes as the baker. Use the generated layout if the
-- source attributes have changed since baking or the images were resized.
function Util.LayoutFromAttributes(root: Instance): Layout
	local input: LayoutInput = {}
	local values: { [string]: number } = {}
	for _, name in { "PanShotCount", "TiltShotCount", "MaxResolutionPx", "PaddingPx", "TiltOffset" } do
		local value = root:GetAttribute(name)
		if value ~= nil then
			assert(typeof(value) == "number", `{name} must be a number`)
			values[name] = value
		end
	end
	input.PanShotCount = values.PanShotCount
	input.TiltShotCount = values.TiltShotCount
	input.MaxResolutionPx = values.MaxResolutionPx
	input.PaddingPx = values.PaddingPx
	input.TiltOffset = values.TiltOffset
	local range = root:GetAttribute("TiltConstraints")
	if range ~= nil then
		assert(typeof(range) == "NumberRange", "TiltConstraints must be a NumberRange")
		input.TiltConstraints = range
	end
	return Util.Layout(input)
end

function Util.TileSize(layout: Layout): number
	return layout.MaxResolutionPx + 2 * layout.PaddingPx
end

function Util.Grid(layout: Layout): Vector2
	local count = layout.PanShotCount * layout.TiltShotCount
	local columns = math.ceil(math.sqrt(count))
	return Vector2.new(columns, math.ceil(count / columns))
end

function Util.AtlasSize(layout: Layout): Vector2
	return Util.Grid(layout) * Util.TileSize(layout)
end

function Util.ShotKey(index: number): string
	integer(index, 0, 4095, "index")
	return string.format("shot_%04d", index)
end

function Util.Basis(yawDegrees: number, pitchDegrees: number): (Vector3, Vector3, Vector3)
	local yaw = math.rad(yawDegrees)
	local pitch = math.rad(pitchDegrees)
	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	local toward = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch))
	return right, toward:Cross(right), toward
end

function Util.Shots(layout: Layout): { Shot }
	local shots: { Shot } = {}
	local grid = Util.Grid(layout)
	for index = 0, layout.PanShotCount * layout.TiltShotCount - 1 do
		local pan = index % layout.PanShotCount
		local tilt = math.floor(index / layout.PanShotCount)
		local range = layout.TiltConstraints
		local yaw = 360 * pan / layout.PanShotCount
		local pitch = (
			if layout.TiltShotCount == 1
				then (range.Min + range.Max) / 2
				else range.Min + (range.Max - range.Min) * tilt / (layout.TiltShotCount - 1)
		) + layout.TiltOffset
		local right, up, toward = Util.Basis(yaw, pitch)
		table.insert(
			shots,
			table.freeze({
				Index = index,
				Key = Util.ShotKey(index),
				YawDegrees = yaw,
				PitchDegrees = pitch,
				Right = right,
				Up = up,
				Toward = toward,
				Position = Vector2.new(index % grid.X, math.floor(index / grid.X)) * Util.TileSize(layout),
			})
		)
	end
	return table.freeze(shots)
end

function Util.SelectShot(localDirection: Vector3, shots: { Shot }): Shot
	assert(#shots > 0, "shot list must not be empty")
	local direction = if localDirection.Magnitude > 1e-8 then localDirection.Unit else Vector3.zAxis
	local best = shots[1]
	local score = -math.huge
	for _, shot in shots do
		local candidate = direction:Dot(shot.Toward)
		if candidate > score + 1e-7 then
			best = shot
			score = candidate
		end
	end
	return best
end

function Util.Solve(
	cameraCFrame: CFrame,
	verticalFieldOfView: number,
	boundingBoxCFrame: CFrame,
	boundingBoxSize: Vector3,
	layout: Layout,
	preparedShots: { Shot }?
): Solution
	assert(
		finite(verticalFieldOfView) and verticalFieldOfView > 0 and verticalFieldOfView < 180,
		"vertical FOV must be in (0, 180) degrees"
	)
	assert(
		finite(boundingBoxSize.X)
			and finite(boundingBoxSize.Y)
			and finite(boundingBoxSize.Z)
			and math.min(boundingBoxSize.X, boundingBoxSize.Y, boundingBoxSize.Z) > 0,
		"bounding box size must be positive and finite"
	)
	local relative = cameraCFrame.Position - boundingBoxCFrame.Position
	local distance = relative.Magnitude
	local toward = if distance > 1e-8 then relative.Unit else -cameraCFrame.LookVector
	assert(finite(distance), "Camera and bounding box positions must be finite")
	local localToward = boundingBoxCFrame:VectorToObjectSpace(toward)
	local shot = Util.SelectShot(localToward, preparedShots or Util.Shots(layout))
	-- Geometry and tangent-space normals share the exact capture orientation.
	-- Turning the plane between shots would rotate the baked surface lighting.
	local right = boundingBoxCFrame:VectorToWorldSpace(shot.Right)
	local up = boundingBoxCFrame:VectorToWorldSpace(shot.Up)
	toward = boundingBoxCFrame:VectorToWorldSpace(shot.Toward)
	local atlasSize = Util.AtlasSize(layout)
	local start = shot.Position + Vector2.one * layout.PaddingPx
	local size = boundingBoxSize.Magnitude
	return {
		Shot = shot,
		CFrame = CFrame.fromMatrix(boundingBoxCFrame.Position, right, up, toward),
		Size = Vector2.one * size,
		UVMin = start / atlasSize,
		UVMax = (start + Vector2.one * layout.MaxResolutionPx) / atlasSize,
		Distance = distance,
		ProjectedHeight = size / (2 * math.max(distance, 1e-8) * math.tan(math.rad(verticalFieldOfView) / 2)),
	}
end

return table.freeze(Util)
