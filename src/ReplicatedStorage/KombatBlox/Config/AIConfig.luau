--!strict
-- AIConfig: parametros de comportamiento del NPC (Practice Dummy).
-- v1.2: tres dificultades (Easy/Normal/Hard) sobre la MISMA IA (DummyBrain no
-- cambia su logica; solo lee otro perfil). Seleccion via atributo de Workspace
-- KB_AIDifficulty (lo lee AIService), con "Normal" por defecto.
--
-- DISEÑO:
--   * NO hay cooldown de ataque propio: el arbitro del ritmo es CombatService
--     (la IA solo actua cuando GetActorState == Idle).
--   * Hard NO hace trampas: ReactionDelay tiene un suelo > 0 (nunca instantaneo)
--     y la IA solo conoce lo que un jugador veria (posicion y estado publico del
--     rival), nunca inputs, intenciones ni el eslabon de combo que va a salir.

export type Profile = {
	DecisionInterval: number,   -- s entre decisiones (tambien marca el tick del AIService)
	ReactionDelay: number,      -- s antes de reaccionar (p.ej. bloquear)
	MinReactionDelay: number,   -- suelo anti-trampas: nunca por debajo de esto

	DetectionRange: number,     -- a mas distancia, espera (Idle)
	EngageRange: number,        -- <= entra a pelear (histeresis)
	DisengageRange: number,     -- > vuelve a acercarse (histeresis)
	StopDistance: number,       -- distancia de parada al acercarse (anti-empuje)
	GiveUpChaseRange: number,

	ComboContinuationChance: { number },  -- continuar M1_1->2, 2->3, 3->4
	ComboResetTime: number,     -- s sin atacar -> combo terminado

	BlockChance: number,
	BlockMinHold: number,       -- s minimos de guardia (evita parpadeo)
	BlockMaxHold: number,
	BlockReactRange: number,

	DashChance: number,
	DashGapMin: number,

	RepositionChance: number,   -- prob. de reposicionar tras un combo
	RepositionTime: number,     -- s de retroceso/spacing
	PostHitBias: number,        -- s de sesgo defensivo al salir de hitstun/stun

	FacePlayer: boolean,
	TurnResponsiveness: number, -- AlignOrientation: mayor = giro mas firme
}

local Easy: Profile = {
	DecisionInterval = 0.22,
	ReactionDelay = 0.35,
	MinReactionDelay = 0.10,

	DetectionRange = 70,
	EngageRange = 6.0,
	DisengageRange = 9.0,
	StopDistance = 4.5,
	GiveUpChaseRange = 90,

	ComboContinuationChance = { 0.70, 0.60, 0.50 },
	ComboResetTime = 1.0,

	BlockChance = 0.15,
	BlockMinHold = 0.30,
	BlockMaxHold = 1.0,
	BlockReactRange = 8.0,

	DashChance = 0.05,
	DashGapMin = 14,

	RepositionChance = 0.60,
	RepositionTime = 0.8,
	PostHitBias = 0.50,

	FacePlayer = true,
	TurnResponsiveness = 25,
}

local Normal: Profile = {
	DecisionInterval = 0.15,
	ReactionDelay = 0.20,
	MinReactionDelay = 0.10,

	DetectionRange = 80,
	EngageRange = 6.0,
	DisengageRange = 8.5,
	StopDistance = 4.5,
	GiveUpChaseRange = 100,

	ComboContinuationChance = { 0.90, 0.85, 0.80 },
	ComboResetTime = 1.0,

	BlockChance = 0.35,
	BlockMinHold = 0.35,
	BlockMaxHold = 1.2,
	BlockReactRange = 9.0,

	DashChance = 0.15,
	DashGapMin = 12,

	RepositionChance = 0.40,
	RepositionTime = 0.6,
	PostHitBias = 0.30,

	FacePlayer = true,
	TurnResponsiveness = 40,
}

local Hard: Profile = {
	DecisionInterval = 0.10,
	ReactionDelay = 0.10,
	MinReactionDelay = 0.08,

	DetectionRange = 90,
	EngageRange = 6.0,
	DisengageRange = 8.0,
	StopDistance = 4.0,
	GiveUpChaseRange = 120,

	ComboContinuationChance = { 0.95, 0.92, 0.90 },
	ComboResetTime = 1.2,

	BlockChance = 0.55,
	BlockMinHold = 0.40,
	BlockMaxHold = 1.4,
	BlockReactRange = 10.0,

	DashChance = 0.30,
	DashGapMin = 10,

	RepositionChance = 0.25,
	RepositionTime = 0.5,
	PostHitBias = 0.15,

	FacePlayer = true,
	TurnResponsiveness = 60,
}

return table.freeze({
	Default = "Normal",
	-- Atributo de Workspace que elige la dificultad en caliente (Studio -> Workspace -> Attributes).
	DifficultyAttribute = "KB_AIDifficulty",
	Difficulties = {
		Easy = Easy,
		Normal = Normal,
		Hard = Hard,
	},
})
