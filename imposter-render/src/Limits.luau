--!strict
local Limits = {}

export type Options = {
	MaxTextureSize: number?,
	MaxTexturePixels: number?,
	MaxEditableImages: number?,
	MaxEditableMeshes: number?,
	MaxInstances: number?,
	MaxModels: number?,
	WorldExtent: number?,
}
export type Budget = {
	[string]: number,
	MaxTextureSize: number,
	MaxTexturePixels: number,
	MaxEditableImages: number,
	MaxEditableMeshes: number,
	MaxInstances: number,
	MaxModels: number,
	WorldExtent: number,
}

function Limits.Resolve(options: Options?): Budget
	local o: Options = options or {}
	local b: Budget = {
		MaxTextureSize = o.MaxTextureSize or 1024,
		MaxTexturePixels = o.MaxTexturePixels or 6 * 1024 * 1024,
		MaxEditableImages = o.MaxEditableImages or 6,
		MaxEditableMeshes = o.MaxEditableMeshes or 1,
		MaxInstances = o.MaxInstances or 256,
		MaxModels = o.MaxModels or 64,
		WorldExtent = o.WorldExtent or 512,
	}
	for name, value in b do
		assert(value == value and value > 0 and value < math.huge, `{name} must be positive and finite`)
		if name ~= "WorldExtent" then
			assert(value % 1 == 0, `{name} must be an integer`)
		end
	end
	assert(b.MaxTextureSize <= 1024, "Roblox EditableImage maximum dimension is 1024")
	-- Four vertices and two triangles per imposter, plus fixed bounds sentinels.
	assert(b.MaxInstances <= 9999, "MaxInstances exceeds the EditableMesh triangle Budget")
	assert(b.WorldExtent >= 0.001 and b.WorldExtent <= 1024, "WorldExtent must be 0.001..1024 studs")
	return table.freeze(b)
end

return table.freeze(Limits)
