--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
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
		local motion: Package.Motion? = nil
		local character = Players.LocalPlayer.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if root and root:IsA("BasePart") then
			local velocity = root.AssemblyLinearVelocity
			-- Intent reacts immediately to turns and still predicts forward when
			-- contact with an existing collider temporarily reduces velocity.
			if humanoid and humanoid.MoveDirection.Magnitude > 0.01 then
				local speed = math.max(humanoid.WalkSpeed, Vector3.new(velocity.X, 0, velocity.Z).Magnitude)
				velocity = humanoid.MoveDirection * speed + Vector3.new(0, velocity.Y, 0)
			end
			motion = { Position = root.Position, Velocity = velocity }
		end
		local available =
			math.max(0, 1000 / Scene.TargetFps - (os.clock() - frameStarted) * 1000 - Scene.FrameReserveMilliseconds)
		debug.profilebegin("Imposter updates")
		active:Update(camera.CFrame, camera.FieldOfView, available, motion)
		debug.profileend()
	end
end)

local success, message = pcall(function()
	local options: Package.Options = {
		Origin = CFrame.new(Scene.Center),
		UpdateBudget = { TargetFps = Scene.TargetFps, MaxMilliseconds = Scene.UpdateBudgetMilliseconds },
		Lod = {
			NearDistance = Scene.RealNearDistance,
			FarDistance = Scene.RealFarDistance,
			MaxRealInstances = Scene.MaxRealInstances,
			MaxTransitionsPerFrame = 4,
			MaxCreatesPerFrame = 1,
			LookAheadSeconds = Scene.RealLookAheadSeconds,
			MaxLookAheadDistance = Scene.RealMaxLookAheadDistance,
			CameraLookAheadDistance = Scene.RealCameraLookAheadDistance,
		},
		InstanceCache = { MaxInstances = 128, MaxPartsPerInstance = 128, MaxPartsPerFlush = 256 },
		Limits = {
			MaxTextureSize = 1024,
			MaxTexturePixels = 6 * 1024 * 1024,
			MaxEditableImages = 6,
			MaxEditableMeshes = 1,
			MaxInstances = Scene.InstanceCount,
			MaxModels = 4,
			WorldExtent = Scene.WorldExtent,
		},
	}
	local renderer, createError = Package.New(options)
	assert(renderer, createError)
	batch = renderer
	local sizes: { [string]: Vector3 } = {}
	local entries: { Assets.Entry } = {}
	for _, name in Assets.Names do
		table.insert(entries, Assets.Entry(name))
	end
	-- Pack large sheets before the single-shot lilypad to avoid fragmentation.
	table.sort(entries, function(a: Assets.Entry, b: Assets.Entry): boolean
		local aSize = Package.Util.AtlasSize(Assets.Layout(a))
		local bSize = Package.Util.AtlasSize(Assets.Layout(b))
		return if aSize == bSize then a.Name < b.Name else aSize.X * aSize.Y > bSize.X * bSize.Y
	end)
	for _, entry in entries do
		local loaded = Assets.Load(entry)
		local ok, loadError = renderer:Register(entry.Name, loaded.Sources, Assets.Layout(entry))
		for _, image in loaded.Images do
			image:Destroy()
		end
		assert(ok, loadError)
		local templateOk, templateError = renderer:RegisterTemplate(entry.Name, entry.Template, {
			BoundingBoxCFrame = CFrame.identity,
			BoundingBoxSize = entry.Size,
			CanCollide = entry.Name == "tree" or entry.Name == "pillar",
			CanQuery = entry.Name == "tree" or entry.Name == "pillar",
		})
		assert(templateOk, templateError)
		local warmed, warmError = renderer:Prewarm(entry.Name, Scene.RealPrewarmPerModel)
		assert(warmed >= Scene.RealPrewarmPerModel, warmError)
		sizes[entry.Name] = entry.Size
	end
	for _, placement in Scene.Placements(Assets.Names, sizes) do
		local handle, addError = renderer:Add(placement.Name, placement.CFrame, sizes[placement.Name])
		assert(handle, addError)
		handle:SetLodEnabled(not placement.Comparison)
	end
	ready = true
	local usage = renderer:GetUsage()
	print(
		`Imposter demo: {usage.Instances} instances, {usage.EditableMeshes} imposter mesh, {usage.EditableImages} shared maps; up to {Scene.MaxRealInstances} nearby real models ({usage.CachedInstances} prewarmed)`
	)
end)
if not success then
	if batch then
		batch:Destroy()
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
		batch:Destroy()
		batch = nil
	end
end)
