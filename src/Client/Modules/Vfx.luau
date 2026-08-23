--!nonstrict
-- Vfx.luau
-- Small client-only effects library: splashes, ripples, puffs, sparkle
-- bursts, trails and drips. Every effect is built from plain Instances
-- (ParticleEmitters, Trails, tweened parts) on throwaway anchored parts
-- under Workspace.ClientVfx, so nothing here replicates and nothing needs a
-- server round-trip. Textures are Roblox's built-in rbxasset particles - no
-- asset ids to upload, same as the rest of the project's "everything in the
-- repo" stance.
--
-- The look follows the game's flat-shaded low-poly style: ripple rings are
-- real little parts expanding outward rather than a soft decal, and the
-- particle sizes are chunky.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Vfx = {}

local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

Vfx.Color = {
	water = Color3.fromRGB(206, 238, 255),
	foam = Color3.fromRGB(246, 252, 255),
	sand = Color3.fromRGB(228, 208, 160),
	line = Color3.fromRGB(230, 244, 255),
}

-- Ripple rings are this many short flat segments around a circle.
local RING_SEGMENTS = 12

local folder: Folder? = nil

local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "ClientVfx"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

local function kp(t: number, v: number): NumberSequenceKeypoint
	return NumberSequenceKeypoint.new(t, v)
end

-- An invisible anchored part to hang emitters / attachments off.
function Vfx.anchorPart(position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = "VfxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(position)
	part.Parent = container()
	return part
end

local function makeEmitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.LockedToPart = false
	for key, value in props do
		emitter[key] = value
	end
	emitter.Parent = parent
	return emitter
end

-- ============================================================ ripple ring

-- A ring of flat segments that expands from `fromRadius` to `toRadius` over
-- `duration` while fading out. `position` is the ring's centre (put it just
-- above the water plane).
function Vfx.ring(position: Vector3, fromRadius: number, toRadius: number, duration: number, color: Color3?)
	local model = Instance.new("Model")
	model.Name = "Ripple"
	model.Parent = container()

	local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

	local function place(angle: number, radius: number): CFrame
		return CFrame.new(position) * CFrame.Angles(0, angle, 0) * CFrame.new(radius, 0, 0)
	end
	local function size(radius: number): Vector3
		-- Segment runs along its local Z (the tangent); leave gaps so it
		-- reads as a dashed ring rather than a solid disc edge.
		return Vector3.new(0.16, 0.05, (2 * math.pi * radius / RING_SEGMENTS) * 0.72)
	end

	for i = 1, RING_SEGMENTS do
		local angle = (i / RING_SEGMENTS) * math.pi * 2
		local segment = Instance.new("Part")
		segment.Name = "Segment"
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanQuery = false
		segment.CanTouch = false
		segment.CastShadow = false
		segment.Material = Enum.Material.SmoothPlastic
		segment.Color = color or Vfx.Color.foam
		segment.Transparency = 0.15
		segment.CFrame = place(angle, fromRadius)
		segment.Size = size(fromRadius)
		segment.Parent = model

		TweenService:Create(segment, info, {
			CFrame = place(angle, toRadius),
			Size = size(toRadius),
			Transparency = 1,
		}):Play()
	end

	Debris:AddItem(model, duration + 0.1)
end

-- Keeps spawning rings at whatever `getPosition` returns, every `interval`
-- seconds, until stop() is called. For a bobber sitting on the water.
function Vfx.ripples(getPosition: () -> Vector3?, interval: number)
	local running = true
	task.spawn(function()
		while running do
			local position = getPosition()
			if position then
				Vfx.ring(position, 0.45, 2.2, 1.1)
			end
			task.wait(interval)
		end
	end)
	return {
		stop = function()
			running = false
		end,
	}
end

-- ============================================================ one-shots

-- Water splash: a burst of droplets up and out, a puff of mist, and a
-- ripple ring. `scale` 1 is a bobber-sized plop; 1.5+ is a fish breaching.
function Vfx.splash(position: Vector3, scale: number?)
	scale = scale or 1
	local part = Vfx.anchorPart(position)

	local drops = makeEmitter(part, {
		Texture = SPARKLE,
		Color = ColorSequence.new(Vfx.Color.foam, Vfx.Color.water),
		Size = NumberSequence.new({ kp(0, 0.34 * scale), kp(0.6, 0.22 * scale), kp(1, 0.04) }),
		Transparency = NumberSequence.new({ kp(0, 0.05), kp(0.7, 0.25), kp(1, 1) }),
		Lifetime = NumberRange.new(0.4, 0.7),
		Speed = NumberRange.new(10 * math.sqrt(scale), 17 * math.sqrt(scale)),
		SpreadAngle = Vector2.new(40, 40),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -70, 0),
		Drag = 0.4,
		Rotation = NumberRange.new(0, 360),
		LightEmission = 0.35,
	})
	local mist = makeEmitter(part, {
		Texture = SMOKE,
		Color = ColorSequence.new(Vfx.Color.foam),
		Size = NumberSequence.new({ kp(0, 0.9 * scale), kp(1, 2.3 * scale) }),
		Transparency = NumberSequence.new({ kp(0, 0.5), kp(1, 1) }),
		Lifetime = NumberRange.new(0.45, 0.65),
		Speed = NumberRange.new(1.5, 3),
		SpreadAngle = Vector2.new(180, 180),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
		LightEmission = 0.1,
	})

	drops:Emit(math.max(6, math.floor(16 * scale)))
	mist:Emit(math.max(3, math.floor(5 * scale)))
	Vfx.ring(position, 0.5 * scale, 3 * scale, 0.7)

	Debris:AddItem(part, 1.5)
end

-- Dust / sand puff for something hitting dry ground.
function Vfx.puff(position: Vector3, color: Color3?, scale: number?)
	scale = scale or 1
	local part = Vfx.anchorPart(position)

	local dust = makeEmitter(part, {
		Texture = SMOKE,
		Color = ColorSequence.new(color or Vfx.Color.sand),
		Size = NumberSequence.new({ kp(0, 0.5 * scale), kp(1, 1.7 * scale) }),
		Transparency = NumberSequence.new({ kp(0, 0.35), kp(1, 1) }),
		Lifetime = NumberRange.new(0.35, 0.6),
		Speed = NumberRange.new(2, 4.5),
		SpreadAngle = Vector2.new(75, 75),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -3, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-30, 30),
	})
	dust:Emit(math.max(4, math.floor(8 * scale)))

	Debris:AddItem(part, 1.2)
end

-- Sparkles shooting up and out then falling: a celebration pop (a catch,
-- a rare drop). `count` defaults to 28.
function Vfx.burst(position: Vector3, color: Color3, count: number?)
	local part = Vfx.anchorPart(position)

	local sparks = makeEmitter(part, {
		Texture = SPARKLE,
		Color = ColorSequence.new(color),
		Size = NumberSequence.new({ kp(0, 0.45), kp(0.5, 0.3), kp(1, 0) }),
		Transparency = NumberSequence.new({ kp(0, 0), kp(0.8, 0.2), kp(1, 1) }),
		Lifetime = NumberRange.new(0.6, 1.0),
		Speed = NumberRange.new(9, 15),
		SpreadAngle = Vector2.new(55, 55),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -28, 0),
		Drag = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-120, 120),
		LightEmission = 0.7,
	})
	sparks:Emit(count or 28)

	Debris:AddItem(part, 2)
end

-- ============================================================ attached

-- A ribbon trail across a part, `halfWidth` studs either side of its centre
-- along its local Y. Returns the Trail; the caller owns enabling/destroying.
function Vfx.trail(part: BasePart, halfWidth: number, color: Color3, lifetime: number): Trail
	local top = Instance.new("Attachment")
	top.Name = "TrailTop"
	top.Position = Vector3.new(0, halfWidth, 0)
	top.Parent = part

	local bottom = Instance.new("Attachment")
	bottom.Name = "TrailBottom"
	bottom.Position = Vector3.new(0, -halfWidth, 0)
	bottom.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = lifetime
	trail.MinLength = 0.02
	trail.FaceCamera = true
	trail.LightEmission = 0.4
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({ kp(0, 0.25), kp(1, 1) })
	trail.WidthScale = NumberSequence.new({ kp(0, 1), kp(1, 0.15) })
	trail.Parent = part
	return trail
end

-- Water dripping off a part (a fish fresh out of the sea). Starts disabled;
-- flip Enabled while it should drip. Returns the emitter.
function Vfx.drip(part: BasePart): ParticleEmitter
	return makeEmitter(part, {
		Texture = SPARKLE,
		Color = ColorSequence.new(Vfx.Color.water),
		Size = NumberSequence.new({ kp(0, 0.18), kp(1, 0.04) }),
		Transparency = NumberSequence.new({ kp(0, 0.15), kp(1, 1) }),
		Lifetime = NumberRange.new(0.35, 0.6),
		Rate = 26,
		Speed = NumberRange.new(0.5, 2),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -45, 0),
		LightEmission = 0.3,
	})
end

-- ============================================================ enemy moments

local function effectPart(name: string, shape: Enum.PartType, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Parent = container()
	return part
end

-- A flat ring lying in the ground plane that grows from `fromRadius` to
-- `toRadius` over `duration` while fading: one neon cylinder on its side. The
-- horizontal twin of the punch's hit ring (Vfx.ring, dashed, stays for water
-- ripples). For explosions and shockwaves.
function Vfx.shockwave(
	position: Vector3,
	fromRadius: number,
	toRadius: number,
	duration: number,
	color: Color3,
	thickness: number?
)
	local t = thickness or 0.2
	local part = effectPart("Shockwave", Enum.PartType.Cylinder, color)
	part.Transparency = 0.15
	-- A cylinder's axis is its X; stand it on end so the flat face looks up.
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Size = Vector3.new(t, fromRadius * 2, fromRadius * 2)
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(t, toRadius * 2, toRadius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

-- A neon ball that pops to `size` and collapses over `duration`: the bright
-- core of an explosion, a snap, a discharge.
function Vfx.flash(position: Vector3, color: Color3, size: number, duration: number)
	local part = effectPart("Flash", Enum.PartType.Ball, color)
	part.Transparency = 0
	part.CFrame = CFrame.new(position)
	part.Size = Vector3.new(size, size, size)
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, 0.2, 0.2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

-- A point along a lobbed arc from `from` to `to` peaking `apex` studs above
-- the straight line, at fraction `u` (0..1). Pure math, for anything drawn
-- flying along a parabola (a spat glob).
function Vfx.arcPoint(from: Vector3, to: Vector3, apex: number, u: number): Vector3
	return from:Lerp(to, u) + Vector3.new(0, 4 * apex * u * (1 - u), 0)
end

return Vfx
