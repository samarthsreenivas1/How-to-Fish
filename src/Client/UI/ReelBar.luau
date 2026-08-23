--!nonstrict
-- ReelBar.luau
-- Pure rendering for the reel minigame. FishingController owns the timing
-- and input; this module only draws what it's told - a thin track, its
-- zones, and the marker sweeping across it. No text, no button: catching is
-- click-anywhere-or-Space, so there's nothing here to label.
--
-- Deliberately three colours: a white marker sweeping over a target made of
-- green (forgiving) surrounding red (precise, worth more, see
-- ReelMath.buildZones). Everything else is Theme's grey track.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local ReelBar = {}
ReelBar.__index = ReelBar

local BAR_WIDTH = 340
local BAR_HEIGHT = 18
local MARKER_COLOR = Color3.fromRGB(255, 255, 255)

local function addCorner(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function addStroke(parent: GuiObject, color: Color3, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function ReelBar.new(parent: ScreenGui)
	local self = setmetatable({}, ReelBar)

	-- The track itself is the whole widget - no outer panel, no padding.
	local track = Instance.new("Frame")
	track.Name = "ReelBar"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -60)
	track.Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT)
	track.BackgroundColor3 = Theme.Color.panelLight
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Visible = false
	track.Parent = parent
	addCorner(track, BAR_HEIGHT / 2)
	addStroke(track, Theme.Color.border, 1)

	local zoneHolder = Instance.new("Frame")
	zoneHolder.Name = "Zones"
	zoneHolder.BackgroundTransparency = 1
	zoneHolder.Size = UDim2.fromScale(1, 1)
	zoneHolder.Parent = track

	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0.5, 0)
	marker.BackgroundColor3 = MARKER_COLOR
	marker.BorderSizePixel = 0
	marker.Size = UDim2.new(0, 3, 1, 0)
	marker.ZIndex = 5
	marker.Parent = track

	-- Full-track flash used for hit feedback.
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BackgroundColor3 = MARKER_COLOR
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 6
	flash.Parent = track

	self.root = track
	self.zoneHolder = zoneHolder
	self.marker = marker
	self.flash = flash

	return self
end

function ReelBar:renderZones(zones)
	self.zoneHolder:ClearAllChildren()

	for i, zone in zones do
		local frame = Instance.new("Frame")
		frame.Name = "Zone" .. i
		frame.BorderSizePixel = 0
		frame.Position = UDim2.fromScale(zone.min, 0)
		frame.Size = UDim2.fromScale(zone.max - zone.min, 1)
		frame.BackgroundColor3 = zone.kind == "red" and Theme.Color.red or Theme.Color.green
		frame.ZIndex = zone.kind == "red" and 3 or 2
		frame.Parent = self.zoneHolder
	end
end

function ReelBar:setMarker(position: number)
	self.marker.Position = UDim2.new(math.clamp(position, 0, 1), 0, 0, 0)
end

function ReelBar:flashResult(kind: string)
	local color = Theme.Color.textDim
	if kind == "red" then
		color = Theme.Color.red
	elseif kind == "green" then
		color = Theme.Color.green
	end

	self.flash.BackgroundColor3 = color
	self.flash.BackgroundTransparency = kind == "grey" and 0.75 or 0.4
	TweenService:Create(self.flash, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

function ReelBar:show()
	self.root.Visible = true
end

function ReelBar:hide()
	self.root.Visible = false
end

return ReelBar
