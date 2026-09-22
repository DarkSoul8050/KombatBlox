--!strict
-- MatchConfig: UNICA fuente de valores de partida (servidor y cliente).
return table.freeze({
	RoundsToWin = 2,            -- BO3: primero a 2
	CountdownTime = 3,          -- segundos (entero: se anuncia 3, 2, 1)
	RoundTime = 99,             -- segundos de combate por ronda
	RoundEndTime = 2.5,         -- pausa tras el resultado de una ronda
	MatchEndTime = 5,           -- pausa tras el resultado de la partida
	DoubleKOWindow = 0.2,       -- margen para considerar doble K.O.
	MaxConsecutiveDraws = 5,    -- empates seguidos antes de cerrar la partida en empate
	ForcePractice = false,      -- true: siempre Practice (jugador vs NPC)
	PracticeNpcName = "TestDummy",
	PracticeNpcHealth = 100,
})
