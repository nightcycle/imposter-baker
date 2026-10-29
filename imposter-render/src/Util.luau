--!strict
-- Layout version 1. Keep these conventions in sync with src/config.rs.
local Util = {}

export type LayoutInput = {
	panShotCount: number?,
	tiltShotCount: number?,
	maxResolutionPx: number?,
	paddingPx: number?,
	tiltConstraints: NumberRange?,
	tiltOffset: number?,
}
export type Layout = {
	panShotCount: number,
	tiltShotCount: number,
	maxResolutionPx: number,
	paddingPx: number,
	tiltConstraints: NumberRange,
	tiltOffset: number,
}
export type Shot = {
	index: number,
	key: string,
	yawDegrees: number,
	pitchDegrees: number,
	right: Vector3,
	up: Vector3,
	toward: Vector3,
	position: Vector2,
}
export type Solution = {
	shot: Shot,
	cframe: CFrame,
	size: Vector2,
	uvMin: Vector2,
	uvMax: Vector2,
	distance: number,
	projectedHeight: number,
}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function integer(value: number, lo: number, hi: number, name: string)
	assert(finite(value) and value % 1 == 0 and value >= lo and value <= hi, `{name} must be an integer in {lo}..{hi}`)
end

function Util.layout(input: LayoutInput?): Layout
	local options: LayoutInput = input or {}
	local result: Layout = {
		panShotCount = options.panShotCount or 8,
		tiltShotCount = options.tiltShotCount or 1,
		maxResolutionPx = options.maxResolutionPx or 252,
		paddingPx = if options.paddingPx == nil then 2 else options.paddingPx,
		tiltConstraints = options.tiltConstraints or NumberRange.new(-180, 180),
		tiltOffset = options.tiltOffset or 0,
	}
	integer(result.panShotCount, 1, 256, "panShotCount")
	integer(result.tiltShotCount, 1, 256, "tiltShotCount")
	assert(result.panShotCount * result.tiltShotCount <= 4096, "at most 4096 shots are supported")
	integer(result.maxResolutionPx, 1, 4096, "maxResolutionPx")
	integer(result.paddingPx, 0, 64, "paddingPx")
	assert(finite(result.tiltOffset) and math.abs(result.tiltOffset) <= 180, "tiltOffset must be in -180..180 degrees")
	local range = result.tiltConstraints
	assert(
		finite(range.Min) and finite(range.Max) and range.Min >= -180 and range.Max <= 180 and range.Min <= range.Max,
		"invalid tiltConstraints"
	)
	return table.freeze(result)
end

-- Read the same root attributes as the baker. Use the generated layout if the
-- source attributes have changed since baking or the images were resized.
function Util.layoutFromAttributes(root: Instance): Layout
	local input: LayoutInput = {}
	local values: { [string]: number } = {}
	for _, name in { "PanShotCount", "TiltShotCount", "MaxResolutionPx", "PaddingPx", "TiltOffset" } do
		local value = root:GetAttribute(name)
		if value ~= nil then
			assert(typeof(value) == "number", `{name} must be a number`)
			values[name] = value
		end
	end
	input.panShotCount = values.PanShotCount
	input.tiltShotCount = values.TiltShotCount
	input.maxResolutionPx = values.MaxResolutionPx
	input.paddingPx = values.PaddingPx
	input.tiltOffset = values.TiltOffset
	local range = root:GetAttribute("TiltConstraints")
	if range ~= nil then
		assert(typeof(range) == "NumberRange", "TiltConstraints must be a NumberRange")
		input.tiltConstraints = range
	end
	return Util.layout(input)
end

function Util.tileSize(layout: Layout): number
	return layout.maxResolutionPx + 2 * layout.paddingPx
end

function Util.grid(layout: Layout): Vector2
	local count = layout.panShotCount * layout.tiltShotCount
	local columns = math.ceil(math.sqrt(count))
	return Vector2.new(columns, math.ceil(count / columns))
end

function Util.atlasSize(layout: Layout): Vector2
	return Util.grid(layout) * Util.tileSize(layout)
end

function Util.shotKey(index: number): string
	integer(index, 0, 4095, "index")
	return string.format("shot_%04d", index)
end

function Util.basis(yawDegrees: number, pitchDegrees: number): (Vector3, Vector3, Vector3)
	local yaw = math.rad(yawDegrees)
	local pitch = math.rad(pitchDegrees)
	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	local toward = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch))
	return right, toward:Cross(right), toward
end

function Util.shots(layout: Layout): { Shot }
	local shots: { Shot } = {}
	local grid = Util.grid(layout)
	for index = 0, layout.panShotCount * layout.tiltShotCount - 1 do
		local pan = index % layout.panShotCount
		local tilt = math.floor(index / layout.panShotCount)
		local range = layout.tiltConstraints
		local yaw = 360 * pan / layout.panShotCount
		local pitch = (
			if layout.tiltShotCount == 1
				then (range.Min + range.Max) / 2
				else range.Min + (range.Max - range.Min) * tilt / (layout.tiltShotCount - 1)
		) + layout.tiltOffset
		local right, up, toward = Util.basis(yaw, pitch)
		table.insert(
			shots,
			table.freeze({
				index = index,
				key = Util.shotKey(index),
				yawDegrees = yaw,
				pitchDegrees = pitch,
				right = right,
				up = up,
				toward = toward,
				position = Vector2.new(index % grid.X, math.floor(index / grid.X)) * Util.tileSize(layout),
			})
		)
	end
	return table.freeze(shots)
end

function Util.selectShot(localDirection: Vector3, shots: { Shot }): Shot
	assert(#shots > 0, "shot list must not be empty")
	local direction = if localDirection.Magnitude > 1e-8 then localDirection.Unit else Vector3.zAxis
	local best = shots[1]
	local score = -math.huge
	for _, shot in shots do
		local candidate = direction:Dot(shot.toward)
		if candidate > score + 1e-7 then
			best = shot
			score = candidate
		end
	end
	return best
end

function Util.solve(
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
	assert(finite(distance), "camera and bounding box positions must be finite")
	local localToward = boundingBoxCFrame:VectorToObjectSpace(toward)
	local shot = Util.selectShot(localToward, preparedShots or Util.shots(layout))
	-- Geometry and tangent-space normals share the exact capture orientation.
	-- Turning the plane between shots would rotate the baked surface lighting.
	local right = boundingBoxCFrame:VectorToWorldSpace(shot.right)
	local up = boundingBoxCFrame:VectorToWorldSpace(shot.up)
	toward = boundingBoxCFrame:VectorToWorldSpace(shot.toward)
	local atlasSize = Util.atlasSize(layout)
	local start = shot.position + Vector2.one * layout.paddingPx
	local size = boundingBoxSize.Magnitude
	return {
		shot = shot,
		cframe = CFrame.fromMatrix(boundingBoxCFrame.Position, right, up, toward),
		size = Vector2.one * size,
		uvMin = start / atlasSize,
		uvMax = (start + Vector2.one * layout.maxResolutionPx) / atlasSize,
		distance = distance,
		projectedHeight = size / (2 * math.max(distance, 1e-8) * math.tan(math.rad(verticalFieldOfView) / 2)),
	}
end

return table.freeze(Util)
