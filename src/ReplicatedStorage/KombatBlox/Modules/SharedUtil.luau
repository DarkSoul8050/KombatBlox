--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KombatBlox = ReplicatedStorage:WaitForChild("KombatBlox")
local GameConfig = require(KombatBlox:WaitForChild("Config"):WaitForChild("GameConfig"))

local SharedUtil = {}

function SharedUtil.GetRemote(category: string, name: string): Instance
	return KombatBlox:WaitForChild("Remotes"):WaitForChild(category):WaitForChild(name)
end

function SharedUtil.Log(tag: string, ...: any)
	if GameConfig.Debug then print(("[KombatBlox:%s]"):format(tag), ...) end
end

function SharedUtil.Warn(tag: string, ...: any)
	warn(("[KombatBlox:%s]"):format(tag), ...)
end

function SharedUtil.IsDebug(): boolean
	return GameConfig.Debug == true
end

return SharedUtil
