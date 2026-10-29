--!strict
local Util = require(game:GetService("ReplicatedStorage").ImposterRender.Util)
local Atlas = require(game:GetService("ReplicatedStorage").ImposterRender.Atlas)
local Limits = require(game:GetService("ReplicatedStorage").ImposterRender.Limits)

return function()
	local layout = Util.Layout()
	assert(Util.TileSize(layout) == 256)
	assert(Util.AtlasSize(layout) == Vector2.new(768, 768))
	local shots = Util.Shots(layout)
	assert(#shots == 8 and shots[1].Key == "shot_0000" and shots[8].YawDegrees == 315)
	assert(shots[4].Position == Vector2.new(0, 256))
	for index, shot in shots do
		assert(Util.SelectShot(shot.Toward, shots).Index == index - 1)
		assert((shot.Right:Cross(shot.Up) - shot.Toward).Magnitude < 1e-5)
	end
	assert(Util.SelectShot(Vector3.new(-0.01, 0, 1), shots).Index == 0)
	local sphere = Util.Shots(Util.Layout({ TiltShotCount = 5 }))
	for _, shot in sphere do
		assert(shot.Up.Magnitude > 0.99)
		assert(math.abs(shot.Up:Dot(shot.Toward)) < 1e-5)
	end
	local cf = CFrame.new(20, 5, 8) * CFrame.Angles(0.2, 0.7, 0)
	local size = Vector3.new(2, 4, 6)
	local camera = cf * CFrame.new(0, 0, 100)
	local solved = Util.Solve(camera, 70, cf, size, layout, shots)
	assert(solved.Shot.Index == 0 and math.abs(solved.Distance - 100) < 1e-4)
	assert((solved.CFrame.Position - cf.Position).Magnitude < 1e-5)
	assert((solved.CFrame.ZVector - cf.ZVector).Magnitude < 1e-5)
	assert(solved.Size.X == size.Magnitude)
	assert(solved.UVMin == Vector2.one * (2 / 768))
	local narrow = Util.Solve(camera, 40, cf, size, layout, shots)
	assert(narrow.ProjectedHeight > solved.ProjectedHeight)
	-- Level-only bakes stay upright even when viewed above, below, or at a pole.
	for _, position in { Vector3.new(40, 100, 20), Vector3.new(-30, -100, 10), Vector3.new(0, 100, 0) } do
		local elevatedCamera = cf * CFrame.new(position) * CFrame.Angles(0, 0, 0.8)
		local upright = Util.Solve(elevatedCamera, 70, cf, size, layout, shots)
		assert((upright.CFrame.UpVector - cf.UpVector).Magnitude < 1e-5)
		assert(math.abs(upright.CFrame.ZVector:Dot(cf.UpVector)) < 1e-5)
		assert((upright.CFrame.RightVector:Cross(upright.CFrame.UpVector) - upright.CFrame.ZVector).Magnitude < 1e-5)
	end
	local repeatedLevel = Util.Layout({ TiltShotCount = 3, TiltConstraints = NumberRange.new(0, 0) })
	local elevatedCamera = cf * CFrame.new(20, 80, 30)
	local upright = Util.Solve(elevatedCamera, 70, cf, size, repeatedLevel)
	assert((upright.CFrame.UpVector - cf.UpVector).Magnitude < 1e-5)
	local fixedPitch = Util.Layout({ TiltShotCount = 1, TiltConstraints = NumberRange.new(20, 40) })
	for _, height in { -80, 80 } do
		local fixed = Util.Solve(cf * CFrame.new(20, height, 30), 70, cf, size, fixedPitch)
		assert(math.abs(fixed.CFrame.ZVector:Dot(cf.UpVector) - 0.5) < 1e-5)
	end
	local tilted = Util.Solve(elevatedCamera, 70, cf, size, Util.Layout({ TiltShotCount = 3 }))
	assert((tilted.CFrame.ZVector - cf:VectorToWorldSpace(tilted.Shot.Toward)).Magnitude < 1e-5)
	-- Both geometry and mapped normals stay fixed until crossing a view boundary.
	for _, sample in { { -22.4, 0 }, { 0, 0 }, { 22.4, 0 }, { 22.6, 1 }, { 45, 1 }, { 337.4, 7 } } do
		local _, _, direction = Util.Basis(sample[1], 0)
		local view = Util.Solve(cf * CFrame.new(direction * 100), 70, cf, size, layout, shots)
		assert(view.Shot.Index == sample[2])
		assert((view.CFrame.RightVector - cf:VectorToWorldSpace(view.Shot.Right)).Magnitude < 1e-5)
		assert((view.CFrame.UpVector - cf:VectorToWorldSpace(view.Shot.Up)).Magnitude < 1e-5)
		assert((view.CFrame.ZVector - cf:VectorToWorldSpace(view.Shot.Toward)).Magnitude < 1e-5)
	end
	local attributes = Instance.new("Folder")
	attributes:SetAttribute("PanShotCount", 1)
	attributes:SetAttribute("TiltShotCount", 1)
	attributes:SetAttribute("TiltOffset", 90)
	local topDown = Util.LayoutFromAttributes(attributes)
	assert(topDown.TiltOffset == 90 and #Util.Shots(topDown) == 1)
	for _, yaw in { 0, 30, 90, 180, 270 } do
		local _, _, direction = Util.Basis(yaw, 45)
		local view = Util.Solve(cf * CFrame.new(direction * 100), 70, cf, size, topDown)
		assert(view.Shot.Index == 0 and view.Shot.PitchDegrees == 90)
		assert((view.CFrame.ZVector - cf.UpVector).Magnitude < 1e-5)
		assert(
			(view.CFrame.RightVector - cf.RightVector).Magnitude < 1e-5,
			"top-down views must not spin with the Camera"
		)
	end
	attributes:SetAttribute("TiltOffset", "90")
	assert(not pcall(Util.LayoutFromAttributes, attributes))
	attributes:Destroy()
	assert(not pcall(Util.Layout, { TiltOffset = math.huge }))
	assert(not pcall(Util.Layout, { TiltOffset = 181 }))
	assert(not pcall(Util.Layout, { PanShotCount = 0 }))
	assert(not pcall(Util.Layout, { PaddingPx = -1 }))
	assert(not pcall(Util.Solve, camera, 180, cf, size, layout))
	assert(not pcall(Limits.Resolve, { MaxTextureSize = 2048 }))
	assert(not pcall(Limits.Resolve, { MaxInstances = 10000 }))
	assert(not pcall(Limits.Resolve, { WorldExtent = 2048 }))
	assert(Limits.Resolve().MaxEditableMeshes == 1)
	local allocator = Atlas.New(1024)
	local a = Atlas.Allocate(allocator, Vector2.new(768, 768))
	assert(a ~= nil)
	assert(Atlas.Allocate(allocator, Vector2.new(768, 768)) == nil)
	Atlas.Release(allocator, a)
	local full = Atlas.Allocate(allocator, Vector2.new(1024, 1024))
	assert(full ~= nil)
	Atlas.Release(allocator, full)
	for _ = 1, 30 do
		local r = Atlas.Allocate(allocator, Vector2.new(256, 256))
		assert(r ~= nil)
		Atlas.Release(allocator, r)
	end
	assert(Atlas.Allocate(allocator, Vector2.new(1024, 1024)) ~= nil)
	print("Util, shot selection, Bounds, FOV, atlas reuse, and Limits passed")
end
