--!strict
-- Characters: definiciones de personaje (dato compartido cliente+servidor).
--
-- Un personaje = Stats + MoveSet. El MoveSet es la fuente de acciones del ACTOR:
-- CombatService deja de leer un moveset global y resuelve el del personaje.
--
--   Character
--    |- Id, DisplayName
--    |- Stats   { MaxHealth, WalkSpeed, MaxEnergy, RegenRate }
--    \- MoveSet { InputActions, Actions, Block, Dash }
--
-- "Default" reutiliza EXACTAMENTE el moveset actual de CombatConfig (mismos valores,
-- mismas referencias) => el combate v1.3 queda intacto por construccion.
-- Tipos de accion: Type = "Combo" (cadena M1) | "Special" (habilidad suelta).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local CombatConfig = require(KB.Modules.CombatConfig)

-- Atributo que marca el personaje de un fighter (lo fija MatchService al preparar la ronda).
local CHARACTER_ATTR = "KB_CharacterId"

------------------------------------------------------------------
-- Default: el combate actual, sin cambios
------------------------------------------------------------------
local Default = {
	Id = "Default",
	DisplayName = "Default",
	Stats = {
		MaxHealth = 100,
		WalkSpeed = 16,
		MaxEnergy = 100,
		RegenRate = 12,      -- energia por segundo
	},
	MoveSet = {
		InputActions = CombatConfig.InputActions,
		Actions = CombatConfig.Actions,
		Block = CombatConfig.Block,
		Dash = CombatConfig.Dash,
	},
}

------------------------------------------------------------------
-- Kaito: personaje de prueba con MoveSet completo (M1 + Block + Dash + 2 skills)
------------------------------------------------------------------
-- Skill1 "Heavy Palm": habilidad ESTACIONARIA (caso simple del pipeline).
local Skill1 = {
	Type = "Special",
	Damage = 18,
	Cost = 30,
	Cooldown = 4,
	Startup = 0.18,
	ActiveTime = 0.10,
	Recovery = 0.35,
	Hitstun = 0.5,
	HitboxSize = Vector3.new(7, 5, 5),
	HitboxOffset = Vector3.new(0, 0, -3.5),
	Animation = "M1_4",          -- placeholder: reutiliza anim existente (VFX/anim propios: v1.6)
	AttackSFX = "M1_4_Swing",
	HitSFX = "M1_4_Hit",
	GuardBreak = true,
	GuardBreakStun = 1.0,
}

-- Skill2 "Dash Strike": habilidad con MOVIMIENTO (lunge). Demuestra que el pipeline
-- soporta acciones que NO son "M1 con otro nombre": avanza y luego golpea.
local Skill2 = {
	Type = "Special",
	Damage = 14,
	Cost = 40,
	Cooldown = 6,
	Startup = 0.10,
	ActiveTime = 0.12,
	Recovery = 0.30,
	Hitstun = 0.4,
	HitboxSize = Vector3.new(6, 5, 6),
	HitboxOffset = Vector3.new(0, 0, -4),
	Animation = "M1_3",          -- placeholder
	AttackSFX = "M1_3_Swing",
	HitSFX = "M1_3_Hit",
	-- Componente de movimiento (reutiliza el LinearVelocity del Dash):
	LungeDistance = 14,
	LungeDuration = 0.18,
}

local kaitoActions = {}
for id, cfg in CombatConfig.Actions do
	kaitoActions[id] = cfg          -- M1_1..M1_4 iguales que Default
end
kaitoActions.Skill1 = Skill1
kaitoActions.Skill2 = Skill2

local Kaito = {
	Id = "Kaito",
	DisplayName = "Kaito",
	Stats = {
		MaxHealth = 100,
		WalkSpeed = 16,
		MaxEnergy = 100,
		RegenRate = 12,
	},
	MoveSet = {
		InputActions = {
			LightAttack = "M1_1",
			Skill1 = "Skill1",
			Skill2 = "Skill2",
		},
		Actions = kaitoActions,
		Block = CombatConfig.Block,
		Dash = CombatConfig.Dash,
	},
}

------------------------------------------------------------------
-- Registro + resolucion
------------------------------------------------------------------
local Characters = {
	Attribute = CHARACTER_ATTR,
	DefaultId = "Default",
	PracticeId = "Kaito",       -- personaje asignado en Practice (jugador y NPC)
	List = {
		Default = Default,
		Kaito = Kaito,
	},
}

function Characters.Get(id: string?)
	return Characters.List[id or ""] or Default
end

-- Resuelve el personaje de un actor (Player o Model) leyendo el atributo del modelo.
-- Fuera de partida (sin atributo) devuelve Default => combate libre sin cambios.
function Characters.Resolve(ref: any)
	local model: Instance? = nil
	if typeof(ref) == "Instance" then
		if ref:IsA("Player") then
			model = ref.Character
		elseif ref:IsA("Model") then
			model = ref
		end
	end
	if model then
		local id = model:GetAttribute(CHARACTER_ATTR)
		if typeof(id) == "string" then
			return Characters.Get(id)
		end
	end
	return Default
end

return Characters
