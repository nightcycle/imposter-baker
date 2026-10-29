--!strict
local Util = require(game:GetService("ReplicatedStorage").ImposterRender.Util)
local Atlas = require(game:GetService("ReplicatedStorage").ImposterRender.Atlas)
local Limits = require(game:GetService("ReplicatedStorage").ImposterRender.Limits)

return function()
	local layout = Util.layout()
	assert(Util.tileSize(layout) == 256)
	assert(Util.atlasSize(layout) == Vector2.new(768, 768))
	local shots = Util.shots(layout)
	assert(#shots == 8 and shots[1].key == "shot_0000" and shots[8].yawDegrees == 315)
	assert(shots[4].position == Vector2.new(0, 256))
	for index, shot in shots do
		assert(Util.selectShot(shot.toward, shots).index == index - 1)
		assert((shot.right:Cross(shot.up) - shot.toward).Magnitude < 1e-5)
	end
	assert(Util.selectShot(Vector3.new(-0.01, 0, 1), shots).index == 0)
	local sphere = Util.shots(Util.layout({ tiltShotCount = 5 }))
	for _, shot in sphere do
		assert(shot.up.Magnitude > 0.99)
		assert(math.abs(shot.up:Dot(shot.toward)) < 1e-5)
	end
	local cf = CFrame.new(20, 5, 8) * CFrame.Angles(0.2, 0.7, 0)
	local size = Vector3.new(2, 4, 6)
	local camera = cf * CFrame.new(0, 0, 100)
	local solved = Util.solve(camera, 70, cf, size, layout, shots)
	assert(solved.shot.index == 0 and math.abs(solved.distance - 100) < 1e-4)
	assert((solved.cframe.Position - cf.Position).Magnitude < 1e-5)
	assert((solved.cframe.ZVector - cf.ZVector).Magnitude < 1e-5)
	assert(solved.size.X == size.Magnitude)
	assert(solved.uvMin == Vector2.one * (2 / 768))
	local narrow = Util.solve(camera, 40, cf, size, layout, shots)
	assert(narrow.projectedHeight > solved.projectedHeight)
	-- Level-only bakes stay upright even when viewed above, below, or at a pole.
	for _, position in { Vector3.new(40, 100, 20), Vector3.new(-30, -100, 10), Vector3.new(0, 100, 0) } do
		local elevatedCamera = cf * CFrame.new(position) * CFrame.Angles(0, 0, 0.8)
		local upright = Util.solve(elevatedCamera, 70, cf, size, layout, shots)
		assert((upright.cframe.UpVector - cf.UpVector).Magnitude < 1e-5)
		assert(math.abs(upright.cframe.ZVector:Dot(cf.UpVector)) < 1e-5)
		assert((upright.cframe.RightVector:Cross(upright.cframe.UpVector) - upright.cframe.ZVector).Magnitude < 1e-5)
	end
	local repeatedLevel = Util.layout({ tiltShotCount = 3, tiltConstraints = NumberRange.new(0, 0) })
	local elevatedCamera = cf * CFrame.new(20, 80, 30)
	local upright = Util.solve(elevatedCamera, 70, cf, size, repeatedLevel)
	assert((upright.cframe.UpVector - cf.UpVector).Magnitude < 1e-5)
	local fixedPitch = Util.layout({ tiltShotCount = 1, tiltConstraints = NumberRange.new(20, 40) })
	for _, height in { -80, 80 } do
		local fixed = Util.solve(cf * CFrame.new(20, height, 30), 70, cf, size, fixedPitch)
		assert(math.abs(fixed.cframe.ZVector:Dot(cf.UpVector) - 0.5) < 1e-5)
	end
	local tilted = Util.solve(elevatedCamera, 70, cf, size, Util.layout({ tiltShotCount = 3 }))
	assert((tilted.cframe.ZVector - cf:VectorToWorldSpace(tilted.shot.toward)).Magnitude < 1e-5)
	-- Both geometry and mapped normals stay fixed until crossing a view boundary.
	for _, sample in { { -22.4, 0 }, { 0, 0 }, { 22.4, 0 }, { 22.6, 1 }, { 45, 1 }, { 337.4, 7 } } do
		local _, _, direction = Util.basis(sample[1], 0)
		local view = Util.solve(cf * CFrame.new(direction * 100), 70, cf, size, layout, shots)
		assert(view.shot.index == sample[2])
		assert((view.cframe.RightVector - cf:VectorToWorldSpace(view.shot.right)).Magnitude < 1e-5)
		assert((view.cframe.UpVector - cf:VectorToWorldSpace(view.shot.up)).Magnitude < 1e-5)
		assert((view.cframe.ZVector - cf:VectorToWorldSpace(view.shot.toward)).Magnitude < 1e-5)
	end
	local attributes = Instance.new("Folder")
	attributes:SetAttribute("PanShotCount", 1)
	attributes:SetAttribute("TiltShotCount", 1)
	attributes:SetAttribute("TiltOffset", 90)
	local topDown = Util.layoutFromAttributes(attributes)
	assert(topDown.tiltOffset == 90 and #Util.shots(topDown) == 1)
	for _, yaw in { 0, 30, 90, 180, 270 } do
		local _, _, direction = Util.basis(yaw, 45)
		local view = Util.solve(cf * CFrame.new(direction * 100), 70, cf, size, topDown)
		assert(view.shot.index == 0 and view.shot.pitchDegrees == 90)
		assert((view.cframe.ZVector - cf.UpVector).Magnitude < 1e-5)
		assert(
			(view.cframe.RightVector - cf.RightVector).Magnitude < 1e-5,
			"top-down views must not spin with the camera"
		)
	end
	attributes:SetAttribute("TiltOffset", "90")
	assert(not pcall(Util.layoutFromAttributes, attributes))
	attributes:Destroy()
	assert(not pcall(Util.layout, { tiltOffset = math.huge }))
	assert(not pcall(Util.layout, { tiltOffset = 181 }))
	assert(not pcall(Util.layout, { panShotCount = 0 }))
	assert(not pcall(Util.layout, { paddingPx = -1 }))
	assert(not pcall(Util.solve, camera, 180, cf, size, layout))
	assert(not pcall(Limits.resolve, { maxTextureSize = 2048 }))
	assert(not pcall(Limits.resolve, { maxInstances = 10000 }))
	assert(not pcall(Limits.resolve, { worldExtent = 2048 }))
	assert(Limits.resolve().maxEditableMeshes == 1)
	local allocator = Atlas.new(1024)
	local a = Atlas.allocate(allocator, Vector2.new(768, 768))
	assert(a ~= nil)
	assert(Atlas.allocate(allocator, Vector2.new(768, 768)) == nil)
	Atlas.release(allocator, a)
	local full = Atlas.allocate(allocator, Vector2.new(1024, 1024))
	assert(full ~= nil)
	Atlas.release(allocator, full)
	for _ = 1, 30 do
		local r = Atlas.allocate(allocator, Vector2.new(256, 256))
		assert(r ~= nil)
		Atlas.release(allocator, r)
	end
	assert(Atlas.allocate(allocator, Vector2.new(1024, 1024)) ~= nil)
	print("Util, shot selection, bounds, FOV, atlas reuse, and limits passed")
end
