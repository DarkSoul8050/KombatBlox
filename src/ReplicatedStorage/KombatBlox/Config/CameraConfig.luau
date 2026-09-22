--!strict
-- CameraConfig: parametros de la camara de combate (cliente). Solo presentacion.
-- El framing enmarca a los DOS fighters (self + rival) durante Fighting.

return table.freeze({
	LockDefault = true,          -- lock-on activo por defecto al entrar en Fighting

	BaseFov = 70,                -- FOV base (los FovPunch se suman a este)

	-- Distancia camara-jugador (crece con la separacion entre fighters)
	BaseDist = 15,
	MinDist = 13,
	MaxDist = 32,
	SepFactor = 0.85,            -- backDist = clamp(BaseDist + separacion*SepFactor, Min, Max)

	Height = 5.5,                -- altura de la camara sobre el jugador
	ShoulderOffset = 2.5,        -- desplazamiento lateral (over-the-shoulder)
	LookHeight = 3.0,            -- altura del punto al que mira
	LookBias = 0.55,             -- 0 = mira al self, 1 = al rival (enfatiza al rival)

	Responsiveness = 10,         -- suavizado de posicion/mira (mayor = mas firme)
	TransitionSpeed = 6,         -- suavizado de entrada/salida lock <-> normal

	RaycastMargin = 1.2,         -- retroceso extra al chocar la camara con geometria
})
