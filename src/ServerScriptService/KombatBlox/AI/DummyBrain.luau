--!strict
-- DummyBrain: "cerebro" de UN NPC. Decide acciones; NO implementa combate.
-- Todas las acciones se inyectan por CombatService.PerformAction(model, ...) EXACTAMENTE
-- como lo haria un jugador ("LightAttack", "BlockStart"/"BlockEnd", "Dash").
-- Respeta el estado real del combate via CombatService.GetActorState(model):
-- solo decide cuando esta Idle; Attacking/Hitstun/Stunned/Dashing lo congelan solos.
--
-- v1.2 polish:
--   * Giro suave con AlignOrientation (sin jitter; independiente del DecisionInterval).
--   * Histeresis Approach/Engage (no flip-flop en el borde del rango).
--   * StopDistance al acercarse (no empuja al jugador).
--   * Reposition tras combo (no solo spamea M1).
--   * Bloqueo sostenido y natural (BlockMinHold).
--   * Sesgo defensivo tras recibir golpe (PostHitBias).
--   * Sigue 100% apoyado en CombatService (sin segunda autoridad de combate).

local DummyBrain = {}
DummyBrain.__index = DummyBrain

type Deps = {
	Combat: any,
	Profile: any,
}

function DummyBrain.new(model: Model, deps: Deps)
	local self = setmetatable({}, DummyBrain)
	self.Model = model
	self.Combat = deps.Combat
	self.P = deps.Profile

	self.mode = "Approach"       -- "Approach" | "Engage" (con histeresis)
	self.comboStep = 0           -- 0 = sin combo; 1..4 = eslabon lanzado
	self.lastAttackAt = 0
	self.blocking = false
	self.blockUntil = 0
	self.blockSince = 0
	self.nextReactAt = 0
	self.repositionUntil = 0
	self.postHitUntil = 0
	self.prevState = "Idle"
	self.lastMoveTarget = nil :: Vector3?

	self.align = nil :: AlignOrientation?
	self.alignAtt = nil :: Attachment?
	return self
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Crea (una vez) la AlignOrientation que gira el NPC de forma suave hacia el rival.
function DummyBrain:_ensureAlign(root: BasePart, hum: Humanoid)
	if self.align and self.align.Parent then
		return
	end
	hum.AutoRotate = false   -- el giro lo controla AlignOrientation, no la locomocion

	local att = Instance.new("Attachment")
	att.Name = "KB_AIAlign"
	att.Parent = root

	local align = Instance.new("AlignOrientation")
	align.Name = "KB_AIOrientation"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false
	align.Responsiveness = self.P.TurnResponsiveness
	align.MaxTorque = 1e6
	align.PrimaryAxisOnly = true         -- solo yaw (no vuelca el cuerpo)
	align.Parent = root

	self.alignAtt = att
	self.align = align
end

-- Actualiza el objetivo de giro (yaw) hacia una posicion. Suave, cada tick.
function DummyBrain:_faceTowards(root: BasePart, targetPos: Vector3)
	local align = self.align
	if not align then
		return
	end
	local pos = root.Position
	local look = flat(targetPos - pos)
	if look.Magnitude < 0.05 then
		return
	end
	align.CFrame = CFrame.lookAt(pos, pos + look.Unit)
end

function DummyBrain:_read(rivalModel: Model?)
	local model = self.Model
	if not (model and model.Parent) then
		return nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (hum and root and hum.Health > 0) then
		return nil
	end
	local rivalRoot = rivalModel and rivalModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root, hum, rivalRoot
end

function DummyBrain:_releaseBlock()
	if self.blocking then
		self.blocking = false
		self.Combat.PerformAction(self.Model, "BlockEnd")
	end
end

local function stopMove(hum: Humanoid)
	hum:Move(Vector3.zero, false)
end

function DummyBrain:_moveTo(hum: Humanoid, root: BasePart, targetPos: Vector3)
	local target = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
	local last = self.lastMoveTarget
	if last and (last - target).Magnitude < 0.75 then
		return   -- evita re-emitir MoveTo casi identico (anti-stutter)
	end
	self.lastMoveTarget = target
	hum:MoveTo(target)
end

-- Llamada por AIService en cada tick de decision (solo durante Fighting).
function DummyBrain:Update(rivalModel: Model?)
	local model = self.Model
	local P = self.P
	local Combat = self.Combat

	local root, hum, rivalRoot = self:_read(rivalModel)
	if not (root and hum) then
		self:_releaseBlock()
		return
	end
	self:_ensureAlign(root, hum)

	local myState = Combat.GetActorState(model)
	local now = os.clock()

	-- Giro suave SIEMPRE hacia el rival (aunque este en otro estado).
	if rivalRoot then
		self:_faceTowards(root, rivalRoot.Position)
	end

	-- Deteccion de salida de hitstun/stun -> sesgo defensivo un instante.
	if (self.prevState == "Hitstun" or self.prevState == "Stunned")
		and myState ~= "Hitstun" and myState ~= "Stunned"
	then
		self.postHitUntil = now + P.PostHitBias
		self.comboStep = 0
	end
	self.prevState = myState

	-- Guardia en curso: mantener minimo, soltar cuando el rival deja de amenazar.
	if self.blocking then
		local rivalThreat = rivalModel and Combat.GetActorState(rivalModel) == "Attacking"
		local heldEnough = now - self.blockSince >= P.BlockMinHold
		if myState ~= "Blocking" or now >= self.blockUntil or (heldEnough and not rivalThreat) then
			self:_releaseBlock()
		else
			return
		end
	end

	-- Estados que congelan la decision (respeta el combate real).
	if myState ~= "Idle" then
		return
	end
	if not rivalRoot then
		stopMove(hum)
		return
	end

	if self.comboStep > 0 and now - self.lastAttackAt > P.ComboResetTime then
		self.comboStep = 0
	end

	local dist = (flat(rivalRoot.Position - root.Position)).Magnitude

	-- Reposicion activa: retroceder/spacing durante un momento.
	if now < self.repositionUntil then
		local away = flat(root.Position - rivalRoot.Position)
		away = if away.Magnitude > 0.05 then away.Unit else -root.CFrame.LookVector
		self:_moveTo(hum, root, root.Position + away * 3)
		return
	end

	if dist > P.DetectionRange then
		stopMove(hum)
		return
	end

	-- Histeresis Approach <-> Engage.
	if self.mode == "Engage" and dist > P.DisengageRange then
		self.mode = "Approach"
	elseif self.mode == "Approach" and dist <= P.EngageRange then
		self.mode = "Engage"
	end

	local defensive = now < self.postHitUntil

	-- Reaccion defensiva: bloquear si el rival ataca en rango (mas probable si postHit).
	if now >= self.nextReactAt
		and dist <= P.BlockReactRange
		and rivalModel
		and Combat.GetActorState(rivalModel) == "Attacking"
	then
		self.nextReactAt = now + math.max(P.ReactionDelay, P.MinReactionDelay)
		local chance = if defensive then math.min(1, P.BlockChance + 0.35) else P.BlockChance
		if math.random() < chance then
			self.blocking = true
			self.blockSince = now
			self.blockUntil = now + P.BlockMinHold + math.random() * (P.BlockMaxHold - P.BlockMinHold)
			Combat.PerformAction(model, "BlockStart")
			return
		end
	end

	-- Tras un golpe: preferir reposicionar antes que atacar.
	if defensive and self.mode == "Engage" then
		self.repositionUntil = now + P.RepositionTime
		return
	end

	if self.mode == "Engage" then
		stopMove(hum)

		local step = self.comboStep
		if step == 0 then
			self.comboStep = 1
			self.lastAttackAt = now
			Combat.PerformAction(model, "LightAttack")
		elseif step < 4 then
			local chance = P.ComboContinuationChance[step] or 0.8
			if math.random() < chance then
				self.comboStep = step + 1
				self.lastAttackAt = now
				Combat.PerformAction(model, "LightAttack")
			else
				self.comboStep = 0
				if math.random() < P.RepositionChance then
					self.repositionUntil = now + P.RepositionTime
				end
			end
		else
			self.comboStep = 0
			if math.random() < P.RepositionChance then
				self.repositionUntil = now + P.RepositionTime
			end
		end
		return
	end

	-- Approach: cerrar hueco (dash a veces) hasta StopDistance (sin empujar).
	self.comboStep = 0
	local toRival = flat(rivalRoot.Position - root.Position)
	local dir = if toRival.Magnitude > 0.05 then toRival.Unit else root.CFrame.LookVector

	if dist >= P.DashGapMin and math.random() < P.DashChance then
		Combat.PerformAction(model, "Dash", dir)
		return
	end

	self:_moveTo(hum, root, rivalRoot.Position - dir * P.StopDistance)
end

-- Detiene al NPC, suelta guardia y limpia los constraints de la IA.
function DummyBrain:Stop()
	self:_releaseBlock()
	local hum = self.Model and self.Model:FindFirstChildOfClass("Humanoid")
	if hum then
		stopMove(hum)
	end
	if self.align then
		self.align:Destroy()
		self.align = nil
	end
	if self.alignAtt then
		self.alignAtt:Destroy()
		self.alignAtt = nil
	end
end

return DummyBrain
