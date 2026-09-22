--!strict
-- InputController: input fisico -> acciones abstractas. No sabe nada de combate.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedUtil = require(ReplicatedStorage.KombatBlox.Modules.SharedUtil)

type ActionCallback = (action: string) -> ()

-- Pulsar: una accion al pulsar
local BINDINGS: {[EnumItem]: string} = {
	[Enum.UserInputType.MouseButton1] = "LightAttack",   -- PC
	[Enum.KeyCode.ButtonX] = "LightAttack",              -- Xbox
	[Enum.KeyCode.Q] = "Dash",                           -- PC
	[Enum.KeyCode.ButtonB] = "Dash",                     -- Xbox
	[Enum.KeyCode.T] = "LockToggle",                     -- PC: alterna lock-on de camara
	[Enum.KeyCode.ButtonSelect] = "LockToggle",          -- Xbox: boton View
}

-- Mantener: "<Accion>Start" al pulsar y "<Accion>End" al soltar
local HOLD_BINDINGS: {[EnumItem]: string} = {
	[Enum.KeyCode.F] = "Block",          -- PC
	[Enum.KeyCode.ButtonR1] = "Block",   -- Xbox (RB)
}

local InputController = {}
local listeners: {ActionCallback} = {}
local held: {[string]: number} = {}

function InputController:OnAction(callback: ActionCallback)
	table.insert(listeners, callback)
end

function InputController:Trigger(action: string)
	for _, cb in listeners do
		task.spawn(cb, action)
	end
end

local function releaseAll()
	for action, count in held do
		if count > 0 then
			held[action] = 0
			SharedUtil.Log("Input", action .. "End")
			InputController:Trigger(action .. "End")
		end
	end
end

function InputController:Init()
end

function InputController:Start()
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end

		local action = BINDINGS[input.UserInputType] or BINDINGS[input.KeyCode]
		if action then
			SharedUtil.Log("Input", action)
			self:Trigger(action)
		end

		local hold = HOLD_BINDINGS[input.KeyCode]
		if hold then
			held[hold] = (held[hold] or 0) + 1
			if held[hold] == 1 then
				SharedUtil.Log("Input", hold .. "Start")
				self:Trigger(hold .. "Start")
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		local hold = HOLD_BINDINGS[input.KeyCode]
		if hold and (held[hold] or 0) > 0 then
			held[hold] -= 1
			if held[hold] == 0 then
				SharedUtil.Log("Input", hold .. "End")
				self:Trigger(hold .. "End")
			end
		end
	end)

	UserInputService.WindowFocusReleased:Connect(releaseAll)
	UserInputService.GamepadDisconnected:Connect(releaseAll)
end

return InputController
