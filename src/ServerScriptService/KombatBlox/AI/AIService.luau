--!strict
-- AIService (servidor): orquesta los "cerebros" (DummyBrain) de los NPC de la partida.
-- Lee el snapshot de MatchService y, SOLO durante Fighting, decide por cada Fighter NPC.
-- No conoce las reglas del combate: cada decision se ejecuta via CombatService.PerformAction.
--
-- Integracion con la partida (sin acoplarse a internals de MatchService):
--   * Usa MatchService.GetSnapshot() -> Fighters {A,B} con Model / Player / IsNPC / Id.
--   * El rival de un NPC es el OTRO Fighter del match (por Id), no "el mas cercano".
--   * Fuera de Fighting: detiene y descarta los cerebros. NPC reconstruido cada round
--     => Model nuevo => cerebro nuevo (se limpia el estado del Model anterior).

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
local profile = AIConfig.Difficulties[AIConfig.Default]

-- Cerebros activos, keyed por el Model del NPC.
local brains: {[Model]: any} = {}

-- Descarta un cerebro y libera el estado de combate del Model.
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

-- Empareja el estado interno con el snapshot: crea cerebros para NPC nuevos,
-- descarta los que ya no correspondan.
local function reconcile(fighters: { A: any?, B: any? })
	local alive: {[Model]: boolean} = {}

	for _, id in { "A", "B" } do
		local f = fighters[id]
		if f and f.IsNPC and typeof(f.Model) == "Instance" then
			local model = f.Model :: Model
			alive[model] = true
			if not brains[model] then
				brains[model] = DummyBrain.new(model, { Combat = CombatService, Profile = profile })
				SharedUtil.Log(TAG, "Cerebro creado para " .. model.Name)
			end
		end
	end

	-- Descartar cerebros cuyo Model ya no esta en la partida (round nuevo, KO, etc.)
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

	if not (profile and MatchService.GetSnapshot) then
		SharedUtil.Warn(TAG, "AIConfig o MatchService.GetSnapshot no disponibles: IA inactiva")
		return
	end

	local accum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accum += dt
		if accum < profile.DecisionInterval then
			return
		end
		accum = 0

		local snap = MatchService.GetSnapshot()
		local fighters = snap and snap.Fighters

		-- Solo se decide durante Fighting; en cualquier otro estado, cerebros parados.
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

	SharedUtil.Log(TAG, "AIService listo (dificultad " .. AIConfig.Default .. ")")
end

return AIService
