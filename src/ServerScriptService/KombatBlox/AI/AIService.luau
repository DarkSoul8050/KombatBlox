--!strict
-- AIService (servidor): orquesta los "cerebros" (DummyBrain) de los NPC de la partida.
-- Lee el snapshot de MatchService y, SOLO durante Fighting, decide por cada Fighter NPC.
-- No conoce las reglas del combate: cada decision se ejecuta via CombatService.PerformAction.
--
-- v1.2: dificultad seleccionable en caliente por el atributo de Workspace
-- KB_AIDifficulty ("Easy"/"Normal"/"Hard"). Si cambia, se recrean los cerebros.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local AIConfig = require(KB.Config.AIConfig)
local Registry = require(script.Parent.Parent.Services.ServiceRegistry)
local DummyBrain = require(script.Parent.DummyBrain)

local TAG = "AI"
local AIService = {}

local MatchService: any = nil
local CombatService: any = nil

local currentProfile = AIConfig.Difficulties[AIConfig.Default]
local currentName = AIConfig.Default

-- Cerebros activos, keyed por el Model del NPC.
local brains: {[Model]: any} = {}

local function dropBrain(model: Model)
	local brain = brains[model]
	if brain then
		brain:Stop()
		brains[model] = nil
	end
	if CombatService and CombatService.ClearActor then
		pcall(CombatService.ClearActor, model)
	end
end

local function dropAll()
	for model in brains do
		dropBrain(model)
	end
end

-- Lee el atributo de dificultad de Workspace y actualiza el perfil activo.
-- Si el valor no existe o es invalido, usa el Default. Devuelve true si cambio.
local function refreshDifficulty(): boolean
	local raw = workspace:GetAttribute(AIConfig.DifficultyAttribute)
	local name = typeof(raw) == "string" and raw or AIConfig.Default
	local profile = AIConfig.Difficulties[name]
	if not profile then
		name = AIConfig.Default
		profile = AIConfig.Difficulties[name]
	end
	if name ~= currentName then
		currentName = name
		currentProfile = profile
		SharedUtil.Log(TAG, "Dificultad -> " .. name)
		return true
	end
	return false
end

local function reconcile(fighters: { A: any?, B: any? })
	local alive: {[Model]: boolean} = {}

	for _, id in { "A", "B" } do
		local f = fighters[id]
		if f and f.IsNPC and typeof(f.Model) == "Instance" then
			local model = f.Model :: Model
			alive[model] = true
			if not brains[model] then
				brains[model] = DummyBrain.new(model, { Combat = CombatService, Profile = currentProfile })
				SharedUtil.Log(TAG, "Cerebro creado para " .. model.Name)
			end
		end
	end

	for model in brains do
		if not alive[model] then
			dropBrain(model)
		end
	end
end

local function rivalOf(fighters: { A: any?, B: any? }, npcModel: Model): Model?
	local a, b = fighters.A, fighters.B
	if a and a.Model == npcModel then
		return b and b.Model
	end
	if b and b.Model == npcModel then
		return a and a.Model
	end
	return nil
end

function AIService:Init()
end

function AIService:Start()
	local okM, m = pcall(Registry.Get, "MatchService")
	local okC, c = pcall(Registry.Get, "CombatService")
	if not okM or not okC then
		SharedUtil.Warn(TAG, "Faltan MatchService/CombatService: la IA no se inicia")
		return
	end
	MatchService = m
	CombatService = c

	if not (currentProfile and MatchService.GetSnapshot) then
		SharedUtil.Warn(TAG, "AIConfig o MatchService.GetSnapshot no disponibles: IA inactiva")
		return
	end

	-- Deja el atributo visible/editable en Studio (Workspace -> Attributes) con el default.
	if workspace:GetAttribute(AIConfig.DifficultyAttribute) == nil then
		workspace:SetAttribute(AIConfig.DifficultyAttribute, AIConfig.Default)
	end
	refreshDifficulty()

	-- Remote para que la UI de practica cambie la dificultad (el servidor es la autoridad).
	-- Se crea en runtime bajo Remotes/AI (no vive en el place). Se valida el valor recibido.
	local remotes = KB:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = KB
	end
	local aiFolder = remotes:FindFirstChild("AI")
	if not aiFolder then
		aiFolder = Instance.new("Folder")
		aiFolder.Name = "AI"
		aiFolder.Parent = remotes
	end
	local setDifficulty = aiFolder:FindFirstChild("SetDifficulty")
	if not setDifficulty then
		setDifficulty = Instance.new("RemoteEvent")
		setDifficulty.Name = "SetDifficulty"
		setDifficulty.Parent = aiFolder
	end
	;(setDifficulty :: RemoteEvent).OnServerEvent:Connect(function(_player, name)
		if typeof(name) == "string" and AIConfig.Difficulties[name] then
			workspace:SetAttribute(AIConfig.DifficultyAttribute, name)
		end
	end)

	-- Cambio de dificultad en caliente: recrea los cerebros con el nuevo perfil.
	workspace:GetAttributeChangedSignal(AIConfig.DifficultyAttribute):Connect(function()
		if refreshDifficulty() then
			dropAll()
		end
	end)

	local accum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accum += dt
		if accum < currentProfile.DecisionInterval then
			return
		end
		accum = 0

		local snap = MatchService.GetSnapshot()
		local fighters = snap and snap.Fighters

		if not (snap and snap.State == "Fighting" and fighters) then
			if next(brains) ~= nil then
				dropAll()
			end
			return
		end

		reconcile(fighters)

		for model, brain in brains do
			local rival = rivalOf(fighters, model)
			local ok, err = pcall(function()
				brain:Update(rival)
			end)
			if not ok then
				SharedUtil.Warn(TAG, "Update: " .. tostring(err))
			end
		end
	end)

	SharedUtil.Log(TAG, "AIService v1.2 listo (dificultad " .. currentName .. ")")
end

return AIService
