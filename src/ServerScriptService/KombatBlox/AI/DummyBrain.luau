--!strict
-- DummyBrain: "cerebro" de UN NPC. Decide acciones; NO implementa combate.
-- Todas las acciones se inyectan por CombatService.PerformAction(model, ...) EXACTAMENTE
-- como lo haria un jugador ("LightAttack", "BlockStart"/"BlockEnd", "Dash").
-- Respeta el estado real del combate via CombatService.GetActorState(model):
-- solo decide cuando esta Idle; Attacking/Hitstun/Stunned/Dashing lo congelan solos.
--
-- v1.2 polish + smarts:
--   * Giro suave con AlignOrientation (sin jitter).
--   * Histeresis Approach/Engage (no flip-flop). StopDistance (no empuja).
--   * PUNISH: si el rival termina/falla un ataque, contraataca en esa apertura
--     (incluye dash de acercamiento). Solo lee estado publico -> sin trampas.
--   * Bloqueo sostenido + presion tras bloquear. Reposition con STRAFE (rodea).
--   * Sesgo defensivo tras recibir golpe. 100% apoyado en CombatService.

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
	self.comboStep = 0
	self.lastAttackAt = 0
	self.blocking = false
	self.blockUntil = 0
	self.blockSince = 0
	self.nextReactAt = 0
	self.repositionUntil = 0
	self.postHitUntil = 0
	self.punishUntil = 0
	self.prevState = "Idle"
	self.rivalPrevState = "Idle"
	self.strafeSign = 1
	self.nextStrafeFlip = 0
	self.lastMoveTarget = nil :: Vector3?

	self.align = nil :: AlignOrientation?
	self.alignAtt = nil :: Attachment?
	return self
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function DummyBrain:_ensureAlign(root: BasePart, hum: Humanoid)
	if self.align and self.align.Parent then
		return
	end
	hum.AutoRotate = false

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
	align.PrimaryAxisOnly = true
	align.Parent = root

	self.alignAtt = att
	self.align = align
end

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
		return
	end
	self.lastMoveTarget = target
	hum:MoveTo(target)
end

function DummyBrain:_attack(model: Model, now: number)
	self.comboStep = 1
	self.lastAttackAt = now
	self.punishUntil = 0
	self.Combat.PerformAction(model, "LightAttack")
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

	if rivalRoot then
		self:_faceTowards(root, rivalRoot.Position)
	end

	-- Salida de hitstun/stun -> sesgo defensivo un instante.
	if (self.prevState == "Hitstun" or self.prevState == "Stunned")
		and myState ~= "Hitstun" and myState ~= "Stunned"
	then
		self.postHitUntil = now + P.PostHitBias
		self.comboStep = 0
	end
	self.prevState = myState

	-- Seguimiento del rival: si acaba de terminar/fallar un ataque, abrir ventana de castigo.
	local rivalState = if rivalModel then Combat.GetActorState(rivalModel) else "Idle"
	if self.rivalPrevState == "Attacking" and rivalState ~= "Attacking" then
		self.punishUntil = now + P.PunishWindow
	end
	self.rivalPrevState = rivalState

	-- Guardia en curso.
	if self.blocking then
		local rivalThreat = rivalState == "Attacking"
		local heldEnough = now - self.blockSince >= P.BlockMinHold
		if myState ~= "Blocking" or now >= self.blockUntil or (heldEnough and not rivalThreat) then
			self:_releaseBlock()
			-- Tras bloquear, presiona: abre ventana de castigo.
			self.punishUntil = now + P.PunishWindow
		else
			return
		end
	end

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

	local toRival = flat(rivalRoot.Position - root.Position)
	local dist = toRival.Magnitude
	local dir = if dist > 0.05 then toRival.Unit else root.CFrame.LookVector
	local defensive = now < self.postHitUntil

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

	-- 1) Defensa: bloquear si el rival ataca en rango (mas probable si acabo de comer un golpe).
	if now >= self.nextReactAt
		and dist <= P.BlockReactRange
		and rivalState == "Attacking"
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

	-- 2) Recien golpeado: preferir espaciar antes que atacar.
	if defensive and self.mode == "Engage" then
		self.repositionUntil = now + P.RepositionTime
		self.punishUntil = 0
	end

	-- 3) Castigo: el rival dejo una apertura. Golpear ya, o dashear para llegar.
	if now < self.punishUntil and not defensive then
		if self.mode == "Engage" then
			stopMove(hum)
			self:_attack(model, now)
			return
		elseif dist <= P.DashGapMin then
			self.punishUntil = 0
			Combat.PerformAction(model, "Dash", dir)
			return
		end
	end

	-- 4) Reposicion activa: rodear (strafe) o retroceder.
	if now < self.repositionUntil then
		local away = if toRival.Magnitude > 0.05 then -dir else -root.CFrame.LookVector
		local move = away * 0.6
		if math.random() < P.StrafeChance or now < self.nextStrafeFlip then
			if now >= self.nextStrafeFlip then
				self.nextStrafeFlip = now + 0.5
				self.strafeSign = if math.random() < 0.5 then 1 else -1
			end
			local lateral = Vector3.new(-away.Z, 0, away.X) * self.strafeSign
			move = away * 0.4 + lateral * 0.9
		end
		self:_moveTo(hum, root, root.Position + move * 3)
		return
	end

	-- 5) En rango: pelear (combo M1 con continuacion probabilistica).
	if self.mode == "Engage" then
		stopMove(hum)

		-- v1.4: a veces lanza una habilidad (misma interfaz que un jugador).
		-- No comprueba energia ni cooldown: esa autoridad es del servidor, que
		-- rechaza en silencio si no procede.
		if self.comboStep == 0 and math.random() < (P.SkillChance or 0) then
			local skill = if math.random() < 0.5 then "Skill1" else "Skill2"
			self.lastAttackAt = now
			Combat.PerformAction(model, skill)
			return
		end

		local step = self.comboStep
		if step == 0 then
			self:_attack(model, now)
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

	-- 6) Approach: cerrar hueco (dash a veces) hasta StopDistance.
	self.comboStep = 0
	if dist >= P.DashGapMin and math.random() < P.DashChance then
		Combat.PerformAction(model, "Dash", dir)
		return
	end
	self:_moveTo(hum, root, rivalRoot.Position - dir * P.StopDistance)
end

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
