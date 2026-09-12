-- Vector3 stub: the four operations BrinejawPath actually performs on a
-- vector, and nothing else. Roblox's Vector3 is a userdata this file cannot
-- import, and the shared path module is pure geometry - it touches no
-- Instance, no service and no CFrame (verified: `grep -o "Vector3\.[a-z]*"`
-- over all 1980 lines answers only `Vector3.new` and `Vector3.zero`), which
-- is exactly why it can be gated outside Studio at all.
-- Declared as a chunk-level local, not on _G: the `luau` CLI's globals are
-- readonly, and the module is wrapped in a function in this SAME chunk, so it
-- closes over this name exactly as it would over Roblox's own.
local Vector3 = {}
Vector3.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		return Vector3.new(self.X / m, self.Y / m, self.Z / m)
	elseif key == "Lerp" then
		return function(a, b, t)
			return Vector3.new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
		end
	end
	return nil
end
Vector3.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__mul = function(a, b)
	if type(a) == "number" then
		return Vector3.new(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	return Vector3.new(a.X / b, a.Y / b, a.Z / b)
end
Vector3.__unm = function(a)
	return Vector3.new(-a.X, -a.Y, -a.Z)
end
Vector3.__pow = function(a, b)
	return Vector3.new(a.X ^ b, a.Y ^ b, a.Z ^ b)
end
Vector3.__tostring = function(a)
	return string.format("(%.4f, %.4f, %.4f)", a.X, a.Y, a.Z)
end
function Vector3.new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
