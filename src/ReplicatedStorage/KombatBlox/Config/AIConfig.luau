--!strict
-- AIConfig: parametros de comportamiento del NPC (Practice Dummy).
-- v1.1: UNA dificultad funcional ("Normal"). La estructura Difficulties queda
-- preparada para Easy/Hard mas adelante sin tocar la IA.
--
-- IMPORTANTE (decision de diseño v1.1):
--   NO hay cooldown de ataque propio de la IA. El unico arbitro del ritmo es el
--   estado real de CombatService: la IA solo actua cuando GetActorState == Idle
--   y respeta Attacking/Blocking/Dashing/Hitstun/Stunned automaticamente.
--   Asi el Dummy nunca se siente artificialmente lento.

local Normal = {
	-- Frecuencia de decision (anti-spam, determinista). NO es un cooldown de ataque.
	DecisionInterval = 0.15,     -- s entre decisiones de la IA
	ReactionDelay = 0.20,        -- s de margen antes de reaccionar (p.ej. bloquear)

	-- Percepcion y distancias (studs)
	DetectionRange = 80,         -- a mas distancia, el Dummy espera (Idle)
	AttackRange = 6.5,           -- <= inicia M1 (coherente con Hitbox del combate)
	PreferredRange = 5.0,        -- distancia objetivo al acercarse
	GiveUpChaseRange = 100,      -- si el rival se aleja mas, vuelve a Idle

	-- Combo M1: probabilidad de CONTINUAR tras cada eslabon (M1_1->2, 2->3, 3->4).
	-- El CombatService decide que eslabon sale; la IA solo decide si sigue.
	ComboContinuationChance = { 0.90, 0.85, 0.80 },
	ComboResetTime = 1.0,        -- s sin atacar -> se considera el combo terminado

	-- Defensa
	BlockChance = 0.35,          -- prob. de bloquear cuando el rival ataca en rango
	BlockMaxHold = 1.2,          -- s maximos manteniendo la guardia
	BlockReactRange = 9.0,       -- studs dentro de los cuales reacciona a un ataque

	-- Dash
	DashChance = 0.15,           -- prob. de usar dash para cerrar hueco
	DashGapMin = 12,             -- studs a partir de los cuales considera dash

	-- Locomocion (v1.1: MoveTo simple, sin Pathfinding)
	FacePlayer = true,           -- orienta al rival en rango de ataque
}

return table.freeze({
	Default = "Normal",
	Difficulties = {
		Normal = Normal,
	},
})
