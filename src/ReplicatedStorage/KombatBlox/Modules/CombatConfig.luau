--!strict
-- CombatConfig: datos del combate. El SERVIDOR los aplica.
-- Combo M1: el cliente solo envia "LightAttack". El servidor resuelve el eslabon.
-- Block: el cliente envia "BlockStart"/"BlockEnd". El servidor decide si puede bloquear.
-- Dash: el cliente envia "Dash" + direccion de movimiento. El servidor decide todo lo demas.
return table.freeze({
	-- Acciones de ataque que el CLIENTE puede solicitar.
	InputActions = {
		LightAttack = "M1_1",
	},

	Actions = {
		M1_1 = {
			Damage = 8,
			Cooldown = 0.35,
			Startup = 0.12,
			ActiveTime = 0.08,
			Recovery = 0.18,
			Hitstun = 0.20,
			ComboWindow = 0.55,
			HitboxSize = Vector3.new(5, 5, 4),
			HitboxOffset = Vector3.new(0, 0, -3),
			Animation = "M1_1",
			AttackSFX = "M1_1_Swing",
			HitSFX = "M1_1_Hit",
			ComboNext = "M1_2",
		},

		M1_2 = {
			Damage = 8,
			Cooldown = 0,
			Startup = 0.12,
			ActiveTime = 0.08,
			Recovery = 0.18,
			Hitstun = 0.20,
			ComboWindow = 0.55,
			HitboxSize = Vector3.new(5, 5, 4),
			HitboxOffset = Vector3.new(0, 0, -3),
			Animation = "M1_2",
			AttackSFX = "M1_2_Swing",
			HitSFX = "M1_2_Hit",
			ComboNext = "M1_3",
		},

		M1_3 = {
			Damage = 10,
			Cooldown = 0,
			Startup = 0.15,
			ActiveTime = 0.09,
			Recovery = 0.22,
			Hitstun = 0.25,
			ComboWindow = 0.55,
			HitboxSize = Vector3.new(5.5, 5, 4.5),
			HitboxOffset = Vector3.new(0, 0, -3.2),
			Animation = "M1_3",
			AttackSFX = "M1_3_Swing",
			HitSFX = "M1_3_Hit",
			ComboNext = "M1_4",
		},

		M1_4 = {
			Damage = 14,
			Cooldown = 0,
			Startup = 0.22,
			ActiveTime = 0.10,
			Recovery = 0.40,
			Hitstun = 0.40,
			ComboWindow = 0,
			HitboxSize = Vector3.new(6, 5, 5),
			HitboxOffset = Vector3.new(0, 0, -3.5),
			Animation = "M1_4",
			AttackSFX = "M1_4_Swing",
			HitSFX = "M1_4_Hit",
			ComboNext = nil,
			GuardBreak = true,
			GuardBreakStun = 1.0,
		},
	},

	Block = {
		WalkSpeed = 8,
		FrontDot = 0.1,
		DamageMultiplier = 0,
		AnimationFolder = "Block",
		Animation = "Block_Hold",
		BlockSFX = "Block_Hit",
		GuardBreakSFX = "Guard_Break",
	},

	Dash = {
		Distance = 7,              -- studs recorridos
		Duration = 0.18,           -- segundos de impulso
		Cooldown = 1.0,            -- segundos entre dashes (servidor)
		MaxForce = 100000,         -- fuerza maxima del LinearVelocity
		ClientMinInterval = 0.1,   -- anti-spam local (NO es el cooldown)
	},

	AnimationFolder = "LightAttack",
	HitReactionFolder = "HitReactions",
	HitReaction = "Hit_1",

	HitboxTickRate = 0.05,
	MaxRequestsPerSecond = 15,

	ClientMinSendInterval = 0.08,

	States = {
		Idle = "Idle",
		Attacking = "Attacking",
		Hitstun = "Hitstun",
		Blocking = "Blocking",
		Stunned = "Stunned",
		Dashing = "Dashing",
		Dead = "Dead",
	},

	DebugShowHitboxes = true,

	PlaceholderVFX = true,
	CameraShakeIntensity = 0.35,
	CameraShakeDuration = 0.12,
	Hitstop = 0,
})
