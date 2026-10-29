--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Package = require(ReplicatedStorage.ImposterRender)
local Assets = require(ReplicatedStorage.Demo.Assets)
local Scene = require(ReplicatedStorage.Demo.Scene)

local batch: Package.Renderer? = nil
local ready = false
local binding = "ImposterDemoUpdate"

-- Follow the normal Roblox camera after its controller has updated it.
RunService:BindToRenderStep(binding, Enum.RenderPriority.Camera.Value + 1, function()
	local camera = workspace.CurrentCamera
	local active = batch
	if camera and active and ready then
		active:update(camera.CFrame, camera.FieldOfView)
	end
end)

local success, message = pcall(function()
	local options: Package.Options = {
		limits = {
			maxTextureSize = 512,
			maxTexturePixels = 3 * 1024 * 1024,
			maxEditableImages = 6,
			maxEditableMeshes = 1,
			maxInstances = 64,
			maxModels = 4,
			worldExtent = 128,
		},
	}
	local renderer, createError = Package.new(options)
	assert(renderer, createError)
	batch = renderer
	local sizes: { [string]: Vector3 } = {}
	for _, name in Assets.Names do
		local entry = Assets.entry(name)
		local loaded = Assets.load(entry)
		local ok, loadError = renderer:register(name, loaded.sources, Assets.layout())
		for _, image in loaded.images do
			image:Destroy()
		end
		assert(ok, loadError)
		sizes[name] = entry.size
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
	warn("Imposter demo: " .. tostring(message))
end

script.Destroying:Connect(function()
	RunService:UnbindFromRenderStep(binding)
	if batch then
		batch:destroy()
		batch = nil
	end
end)
