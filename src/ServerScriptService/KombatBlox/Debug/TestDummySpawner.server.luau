--!strict
-- DEBUG (solo Studio): Dummy de 100 HP delante del jugador.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end

local DUMMY_NAME, DISTANCE, MAX_HEALTH, RESPAWN_DELAY = "TestDummy", 4, 100, 3
local spawnCFrame: CFrame? = nil

local function buildRig(): Model
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(HumanoidDescription.new(), Enum.HumanoidRigType.R15)
	end)
	if ok and rig then return rig end
	local model = Instance.new("Model")
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart" hrp.Size = Vector3.new(2, 5, 1) hrp.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = hrp
	return model
end

local function spawnDummy()
	if not spawnCFrame then return end
	local old = workspace:FindFirstChild(DUMMY_NAME, true)
	if old then old:Destroy() end

	local dummy = buildRig()
	dummy.Name = DUMMY_NAME
	local hum = dummy:FindFirstChildOfClass("Humanoid") :: Humanoid
	hum.MaxHealth = MAX_HEALTH hum.Health = MAX_HEALTH
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	hum.HealthDisplayDistance = 50
	local hrp = dummy:FindFirstChild("HumanoidRootPart") :: BasePart
	hrp.Anchored = true
	dummy:PivotTo(spawnCFrame)
	local arena = workspace:FindFirstChild("KombatBlox")
	dummy.Parent = (arena and arena:FindFirstChild("Arena")) or workspace

	hum.HealthChanged:Connect(function(hp)
		print(("[KombatBlox:Debug] %s HP: %d / %d"):format(DUMMY_NAME, hp, MAX_HEALTH))
	end)
	hum.Died:Connect(function()
		task.wait(RESPAWN_DELAY)
		spawnDummy()
	end)
	print("[KombatBlox:Debug] " .. DUMMY_NAME .. " listo (" .. MAX_HEALTH .. " HP)")
end

local function onCharacter(character: Model)
	if spawnCFrame then return end
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root then return end
	task.wait(0.5)
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z).Unit
	local pos = root.Position + flat * DISTANCE
	spawnCFrame = CFrame.lookAt(pos, Vector3.new(root.Position.X, pos.Y, root.Position.Z))
	spawnDummy()
end

local function onPlayer(player: Player)
	if player.Character then task.spawn(onCharacter, player.Character) end
	player.CharacterAdded:Connect(onCharacter)
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in Players:GetPlayers() do onPlayer(p) end
