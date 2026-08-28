--!nonstrict
-- CollectionsController.luau
-- The client half of the fishing bestiary. B1 keeps it deliberately small:
-- pull the log once (GetCollections), track pushes, and throw the "New
-- species discovered!" toast off CollectionGranted's isFirst. The browsing
-- modal - island tabs, ??? silhouettes, counts and best grades - is the
-- next collections slice (B2) and builds on the snapshot kept here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Creatures = require(Shared.Data.Creatures)

local Theme = require(script.Parent.Parent.UI.Theme)
local ProgressionController = require(script.Parent.ProgressionController)

local CollectionsController = {}

local player = Players.LocalPlayer
local _ = player -- reserved for the B2 modal

local snapshot: { [string]: any } = {}

function CollectionsController.get(): { [string]: any }
	return snapshot
end

function CollectionsController.start()
	Remotes.CollectionsUpdated.OnClientEvent:Connect(function(data)
		if type(data) == "table" then
			snapshot = data
		end
	end)
	task.spawn(function()
		local data = Remotes.GetCollections:InvokeServer()
		if type(data) == "table" then
			snapshot = data
		end
	end)

	Remotes.CollectionGranted.OnClientEvent:Connect(function(delta)
		if type(delta) ~= "table" then
			return
		end
		local entry = snapshot[delta.speciesId]
		if type(entry) ~= "table" then
			entry = { n = 0, best = delta.best, first = os.time() }
			snapshot[delta.speciesId] = entry
		end
		entry.n = delta.n
		entry.best = delta.best
		if delta.isFirst then
			local row = Creatures.items[delta.speciesId]
			ProgressionController.pop(
				string.format("New species: %s!", row and row.name or tostring(delta.speciesId)),
				Theme.Color.green
			)
		end
	end)
end

return CollectionsController
