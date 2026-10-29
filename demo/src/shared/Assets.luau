--!strict
local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Package = require(ReplicatedStorage.ImposterRender)

local Assets = {}
Assets.Names = table.freeze({ "grass", "pillar", "lilypad", "tree" })

export type Entry = { name: string, template: Model, size: Vector3, folder: Folder }
export type Loaded = { sources: Package.Sources, images: { EditableImage } }

function Assets.root(): Folder
	local root = ReplicatedStorage:WaitForChild("DemoAssets")
	assert(root:IsA("Folder"), "DemoAssets is missing; build the complete demo.rbxl")
	return root
end

function Assets.layout(entry: Entry): Package.Layout
	return Package.Util.layoutFromAttributes(entry.folder)
end

function Assets.entry(name: string): Entry
	local folder = Assets.root():FindFirstChild(name)
	assert(folder and folder:IsA("Folder"), `missing demo model {name}`)
	local size = folder:GetAttribute("BoundsSize")
	local template = folder:FindFirstChild("Original")
	assert(typeof(size) == "Vector3" and template and template:IsA("Model"), "invalid demo model metadata")
	return { name = name, template = template, size = size, folder = folder }
end

function Assets.loadImage(folder: Folder): EditableImage
	local width = folder:GetAttribute("Width")
	local height = folder:GetAttribute("Height")
	assert(typeof(width) == "number" and typeof(height) == "number", "invalid embedded texture size")
	assert(width > 0 and height > 0 and width <= 1024 and height <= 1024, "embedded image exceeds engine limits")
	local children = folder:GetChildren()
	table.sort(children, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	local chunks: { string } = {}
	for _, child in children do
		assert(child:IsA("StringValue"), "unexpected embedded texture chunk")
		table.insert(chunks, child.Value)
	end
	local compressed = EncodingService:Base64Decode(buffer.fromstring(table.concat(chunks)))
	local expectedSize = width * height * 4
	assert(
		EncodingService:GetDecompressedBufferSize(compressed, Enum.CompressionAlgorithm.Zstd) == expectedSize,
		"invalid texture payload length"
	)
	local pixels = EncodingService:DecompressBuffer(compressed, Enum.CompressionAlgorithm.Zstd)
	local image: EditableImage? = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	assert(image, "Roblox denied the demo's EditableImage allocation")
	local ok, message = pcall(function()
		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
	end)
	if not ok then
		image:Destroy()
		error(tostring(message))
	end
	return image
end

function Assets.load(entry: Entry): Loaded
	local images: { EditableImage } = {}
	local maps: { [string]: Content } = {}
	local success, message = pcall(function()
		for _, name in { "color", "normal", "roughness", "metalness", "emissive" } do
			local folder = entry.folder:FindFirstChild(name)
			assert(folder and folder:IsA("Folder"), `missing {name} texture`)
			local image = Assets.loadImage(folder)
			table.insert(images, image)
			maps[name] = Content.fromObject(image)
		end
	end)
	if not success then
		for _, image in images do
			image:Destroy()
		end
		error(tostring(message))
	end
	return {
		sources = {
			color = maps.color,
			normal = maps.normal,
			roughness = maps.roughness,
			metalness = maps.metalness,
			emissive = maps.emissive,
		},
		images = images,
	}
end

return table.freeze(Assets)
