--!strict
local Lod = {}

export type Options = {
	NearDistance: number?,
	FarDistance: number?,
	ReplacementMargin: number?,
	MaxRealInstances: number?,
	MaxTransitionsPerFrame: number?,
	MaxCreatesPerFrame: number?,
}
export type Config = {
	[string]: number,
	NearDistance: number,
	FarDistance: number,
	ReplacementMargin: number,
	MaxRealInstances: number,
	MaxTransitionsPerFrame: number,
	MaxCreatesPerFrame: number,
}

function Lod.Resolve(options: Options?): Config
	local o: Options = options or {}
	local config: Config = {
		NearDistance = o.NearDistance or 48,
		FarDistance = o.FarDistance or 64,
		ReplacementMargin = o.ReplacementMargin or 4,
		MaxRealInstances = o.MaxRealInstances or 64,
		MaxTransitionsPerFrame = o.MaxTransitionsPerFrame or 4,
		MaxCreatesPerFrame = o.MaxCreatesPerFrame or 1,
	}
	for key, value in config do
		assert(value >= 0 and value < math.huge, `{key} must be nonnegative and finite`)
	end
	assert(config.FarDistance >= config.NearDistance, "FarDistance must be at least NearDistance")
	for _, value in { config.MaxRealInstances, config.MaxTransitionsPerFrame, config.MaxCreatesPerFrame } do
		assert(value % 1 == 0, "LOD counts must be integers")
	end
	assert(config.MaxTransitionsPerFrame >= 2, "MaxTransitionsPerFrame must allow a replacement pair")
	return table.freeze(config)
end

-- Distance to the model center, consistent with Scheduler's nearest-first order.
function Lod.Distance(camera: Vector3, center: Vector3): number
	return (camera - center).Magnitude
end

function Lod.ShouldReplace(candidate: number, active: number, config: Config): boolean
	return candidate <= config.NearDistance and candidate + config.ReplacementMargin < active
end

return table.freeze(Lod)
