--!strict
-- FeelConfig: parametros de "peso" del combate (cliente, solo presentacion).
-- NO toca dano/timings/estado (eso es del servidor). Hitstop, shake y FOV punch
-- se aplican localmente. CombatConfig NO se modifica; el feel vive aqui.

return table.freeze({
	-- Hitstop: congela brevemente la animacion del impacto (client-only).
	Hitstop = {
		Actions = {
			M1_1 = 0.022,
			M1_2 = 0.025,
			M1_3 = 0.030,
			M1_4 = 0.055,
			-- v1.4: habilidades
			Skill1 = 0.060,
			Skill2 = 0.040,
		},
		GuardBreak = 0.060,
		ReceivedMultiplier = 0.7,   -- el golpe recibido pesa algo menos que el dado
	},

	-- Acciones consideradas "pesadas" (finisher) para shake/FOV fuertes.
	FinisherActions = {
		M1_4 = true,
		Skill1 = true,   -- v1.4: Heavy Palm pesa como finisher (shake fuerte + FOV)
	},

	-- Camera shake por evento: { Intensity, Duration }.
	Shake = {
		Light = { Intensity = 0.25, Duration = 0.10 },   -- M1_1..M1_3 confirmados
		Heavy = { Intensity = 0.50, Duration = 0.16 },   -- finisher (M1_4)
		Break = { Intensity = 0.90, Duration = 0.22 },   -- guard break
		Blocked = { Intensity = 0.18, Duration = 0.08 }, -- golpe bloqueado
		Received = { Intensity = 0.40, Duration = 0.14 },-- golpe recibido
	},

	-- FOV punch (solo impactos pesados y dash): { Delta, In, Out } en segundos.
	Fov = {
		Heavy = { Delta = 4, In = 0.05, Out = 0.18 },
		Break = { Delta = 7, In = 0.05, Out = 0.25 },
		Dash  = { Delta = 8, In = 0.06, Out = 0.25 },
	},
})
