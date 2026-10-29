--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Package = require(ReplicatedStorage.ImposterRender)
local Assets = require(ReplicatedStorage.Demo.Assets)
local Scene = require(ReplicatedStorage.Demo.Scene)

local batch: Package.Renderer? = nil
local ready = false
local binding = "ImposterDemoUpdate"
local startBinding = "ImposterDemoFrameStart"
local frameStarted = os.clock()

RunService:BindToRenderStep(startBinding, Enum.RenderPriority.First.Value, function()
	frameStarted = os.clock()
end)

-- Follow the normal Roblox camera after its controller has updated it.
RunService:BindToRenderStep(binding, Enum.RenderPriority.Camera.Value + 1, function()
	local camera = workspace.CurrentCamera
	local active = batch
	if camera and active and ready then
		local available =
			math.max(0, 1000 / Scene.TargetFps - (os.clock() - frameStarted) * 1000 - Scene.FrameReserveMilliseconds)
		debug.profilebegin("Imposter updates")
		active:update(camera.CFrame, camera.FieldOfView, available)
		debug.profileend()
	end
end)

local success, message = pcall(function()
	local options: Package.Options = {
		origin = CFrame.new(0, 0, 256),
		updateBudget = { targetFps = Scene.TargetFps, maxMilliseconds = Scene.UpdateBudgetMilliseconds },
		limits = {
			maxTextureSize = 1024,
			maxTexturePixels = 6 * 1024 * 1024,
			maxEditableImages = 6,
			maxEditableMeshes = 1,
			maxInstances = Scene.InstanceCount,
			maxModels = 4,
			worldExtent = Scene.WorldExtent,
		},
	}
	local renderer, createError = Package.new(options)
	assert(renderer, createError)
	batch = renderer
	local sizes: { [string]: Vector3 } = {}
	local entries: { Assets.Entry } = {}
	for _, name in Assets.Names do
		table.insert(entries, Assets.entry(name))
	end
	-- Pack large sheets before the single-shot lilypad to avoid fragmentation.
	table.sort(entries, function(a: Assets.Entry, b: Assets.Entry): boolean
		local aSize = Package.Util.atlasSize(Assets.layout(a))
		local bSize = Package.Util.atlasSize(Assets.layout(b))
		return if aSize == bSize then a.name < b.name else aSize.X * aSize.Y > bSize.X * bSize.Y
	end)
	for _, entry in entries do
		local loaded = Assets.load(entry)
		local ok, loadError = renderer:register(entry.name, loaded.sources, Assets.layout(entry))
		for _, image in loaded.images do
			image:Destroy()
		end
		assert(ok, loadError)
		sizes[entry.name] = entry.size
	end
	for _, placement in Scene.placements(Assets.Names, sizes) do
		local handle, addError = renderer:add(placement.name, placement.cframe, sizes[placement.name])
		assert(handle, addError)
	end
	ready = true
	local usage = renderer:getUsage()
	print(`Imposter demo: {usage.instances} imposters, {usage.editableMeshes} mesh, {usage.editableImages} shared maps`)
end)
if not success then
	if batch then
		batch:destroy()
		batch = nil
	end
	RunService:UnbindFromRenderStep(binding)
	RunService:UnbindFromRenderStep(startBinding)
	warn("Imposter demo: " .. tostring(message))
end

script.Destroying:Connect(function()
	RunService:UnbindFromRenderStep(binding)
	RunService:UnbindFromRenderStep(startBinding)
	if batch then
		batch:destroy()
		batch = nil
	end
end)
