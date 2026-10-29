--!strict
local Limits = {}

export type Options = {
	maxTextureSize: number?,
	maxTexturePixels: number?,
	maxEditableImages: number?,
	maxEditableMeshes: number?,
	maxInstances: number?,
	maxModels: number?,
	worldExtent: number?,
}
export type Budget = {
	[string]: number,
	maxTextureSize: number,
	maxTexturePixels: number,
	maxEditableImages: number,
	maxEditableMeshes: number,
	maxInstances: number,
	maxModels: number,
	worldExtent: number,
}

function Limits.resolve(options: Options?): Budget
	local o: Options = options or {}
	local b: Budget = {
		maxTextureSize = o.maxTextureSize or 1024,
		maxTexturePixels = o.maxTexturePixels or 6 * 1024 * 1024,
		maxEditableImages = o.maxEditableImages or 6,
		maxEditableMeshes = o.maxEditableMeshes or 1,
		maxInstances = o.maxInstances or 256,
		maxModels = o.maxModels or 64,
		worldExtent = o.worldExtent or 512,
	}
	for name, value in b do
		assert(value == value and value > 0 and value < math.huge, `{name} must be positive and finite`)
		if name ~= "worldExtent" then
			assert(value % 1 == 0, `{name} must be an integer`)
		end
	end
	assert(b.maxTextureSize <= 1024, "Roblox EditableImage maximum dimension is 1024")
	-- Four vertices and two triangles per imposter, plus fixed bounds sentinels.
	assert(b.maxInstances <= 9999, "maxInstances exceeds the EditableMesh triangle budget")
	assert(b.worldExtent >= 0.001 and b.worldExtent <= 1024, "worldExtent must be 0.001..1024 studs")
	return table.freeze(b)
end

return table.freeze(Limits)
