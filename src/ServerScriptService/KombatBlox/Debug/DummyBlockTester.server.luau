--!strict
-- DummyBlockTester (DEBUG, solo Studio): el TestDummy bloquea automaticamente.
-- Atributos de este script (editables en Propiedades):
--   Enabled     -> activa/desactiva el tester
--   RearmDelay  -> segundos para recuperar la guardia tras un guard break / golpe por la espalda
--   FacePlayer  -> el Dummy mira siempre al jugador (desactivalo para probar golpes por la espalda)
-- Indicador: resplandor AZUL = guardia puesta.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local Players = game:GetService("Players")

local BLOCK_ATTR = "KB_Blocking"
local rearmAt: number? = nil
local lastState: boolean? = nil

local function getDummy(): Model?
	local d = workspace:FindFirstChild("TestDummy", true)
	if d and d:IsA("Model") then
		return d
	end
	return nil
end

local function nearestPlayerRoot(from: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDist = math.huge
	for _, p in Players:GetPlayers() do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local dist = (root.Position - from).Magnitude
			if dist < bestDist then
				best = root
				bestDist = dist
			end
		end
	end
	return best
end

local function setIndicator(dummy: Model, on: boolean)
	local hl = dummy:FindFirstChild("BlockIndicator") :: Highlight?
	if not hl then
		local newHl = Instance.new("Highlight")
		newHl.Name = "BlockIndicator"
		newHl.FillColor = Color3.fromRGB(80, 160, 255)
		newHl.FillTransparency = 0.7
		newHl.OutlineColor = Color3.fromRGB(80, 160, 255)
		newHl.Parent = dummy
		hl = newHl
	end
	(hl :: Highlight).Enabled = on
end

while true do
	task.wait(0.1)

	if script:GetAttribute("Enabled") ~= true then
		continue
	end

	local dummy = getDummy()
	local hum = dummy and dummy:FindFirstChildOfClass("Humanoid")
	local root = dummy and dummy:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (dummy and hum and root and hum.Health > 0) then
		rearmAt = nil
		lastState = nil
		continue
	end

	-- Mirar al jugador mas cercano (solo giro horizontal)
	if script:GetAttribute("FacePlayer") == true then
		local target = nearestPlayerRoot(root.Position)
		if target then
			local pos = root.Position
			local lookAt = Vector3.new(target.Position.X, pos.Y, target.Position.Z)
			if (lookAt - pos).Magnitude > 0.1 then
				dummy:PivotTo(CFrame.lookAt(pos, lookAt))
			end
		end
	end

	-- Guardia: si la pierde, la recupera tras RearmDelay
	local blocking = dummy:GetAttribute(BLOCK_ATTR) == true
	if not blocking then
		if not rearmAt then
			local delay = script:GetAttribute("RearmDelay") or 2
			rearmAt = os.clock() + (if lastState == nil then 0 else delay)
			if lastState ~= nil then
				print(("[KombatBlox:Debug] TestDummy sin guardia. La recupera en %ss"):format(tostring(delay)))
			end
		end
		if os.clock() >= (rearmAt :: number) then
			dummy:SetAttribute(BLOCK_ATTR, true)
			blocking = true
			rearmAt = nil
			print("[KombatBlox:Debug] TestDummy GUARDIA ON")
		end
	else
		rearmAt = nil
	end

	if blocking ~= lastState then
		setIndicator(dummy, blocking)
		lastState = blocking
	end
end
