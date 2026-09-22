--!strict
-- DummyBrain: "cerebro" de UN NPC. Decide acciones; NO implementa combate.
-- Todas las acciones se inyectan por CombatService.PerformAction(model, ...) EXACTAMENTE
-- como lo haria un jugador ("LightAttack", "BlockStart"/"BlockEnd", "Dash").
-- Respeta el estado real del combate via CombatService.GetActorState(model):
-- solo decide cuando esta Idle; Attacking/Hitstun/Stunned/Dashing lo congelan solos.
--
-- Maquina de estados (conceptual):
--   Inactive -> (Fighting) -> AcquireTarget -> Approach -> Engage(Attack/Block/Dash) -> Reposition
-- Reactivos (implicitos, leidos del combate): Hitstun / Stunned / KO.

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
	self.comboStep = 0          -- 0 = sin combo en curso; 1..4 = eslabon lanzado
	self.lastAttackAt = 0
	self.blocking = false
	self.blockUntil = 0
	self.nextReactAt = 0
	return self
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Orienta el HumanoidRootPart hacia una posicion (solo yaw). Simple, suficiente para 1v1.
local function faceTowards(root: BasePart, targetPos: Vector3)
	local pos = root.Position
	local look = flat(targetPos - pos)
	if look.Magnitude < 0.05 then
		return
	end
	root.CFrame = CFrame.lookAt(pos, pos + look.Unit)
end

-- Devuelve (myRoot, myHum, rivalRoot) o nil si algo no esta vivo/valido.
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

	local myState = Combat.GetActorState(model)
	local now = os.clock()

	-- Gestion de guardia en curso: soltarla al vencer el tiempo o si ya no procede.
	if self.blocking then
		local rivalAttacking = rivalModel and Combat.GetActorState(rivalModel) == "Attacking"
		if myState ~= "Blocking" or now >= self.blockUntil or not rivalAttacking then
			self:_releaseBlock()
		else
			if rivalRoot then
				faceTowards(root, rivalRoot.Position)
			end
			return
		end
	end

	-- Estados que congelan la IA (respeta el combate real: no decide durante estos).
	if myState == "Hitstun" or myState == "Stunned" or myState == "Attacking" or myState == "Dashing" then
		return
	end
	if myState ~= "Idle" then
		return
	end

	-- Sin rival valido: nada que hacer.
	if not rivalRoot then
		return
	end

	-- Combo caducado: reiniciar el contador local.
	if self.comboStep > 0 and now - self.lastAttackAt > P.ComboResetTime then
		self.comboStep = 0
	end

	local dist = (flat(rivalRoot.Position - root.Position)).Magnitude

	-- Fuera de deteccion: esperar quieto.
	if dist > P.DetectionRange then
		hum:Move(Vector3.zero)
		return
	end

	-- Reaccion defensiva: si el rival ataca dentro de rango, quiza bloquear.
	if now >= self.nextReactAt
		and dist <= P.BlockReactRange
		and rivalModel
		and Combat.GetActorState(rivalModel) == "Attacking"
	then
		self.nextReactAt = now + P.ReactionDelay
		if math.random() < P.BlockChance then
			faceTowards(root, rivalRoot.Position)
			self.blocking = true
			self.blockUntil = now + math.random() * P.BlockMaxHold
			Combat.PerformAction(model, "BlockStart")
			return
		end
	end

	-- En rango de ataque: pelear.
	if dist <= P.AttackRange then
		if P.FacePlayer then
			faceTowards(root, rivalRoot.Position)
		end
		hum:Move(Vector3.zero)

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
				self.comboStep = 0   -- corta el combo a proposito (variacion)
			end
		else
			self.comboStep = 0       -- tras M1_4, reinicia
		end
		return
	end

	-- Fuera de rango: acercarse (y quiza dash para cerrar hueco).
	self.comboStep = 0
	local dir = flat(rivalRoot.Position - root.Position)
	if dir.Magnitude > 0.05 then
		dir = dir.Unit
	else
		dir = root.CFrame.LookVector
	end

	if dist >= P.DashGapMin and math.random() < P.DashChance then
		Combat.PerformAction(model, "Dash", dir)
		return
	end

	-- MoveTo hacia un punto a PreferredRange del rival (no encima).
	local targetPos = rivalRoot.Position - dir * P.PreferredRange
	hum:MoveTo(Vector3.new(targetPos.X, root.Position.Y, targetPos.Z))
end

-- Detiene al NPC y limpia su estado de combate.
function DummyBrain:Stop()
	self:_releaseBlock()
	local hum = self.Model and self.Model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum:Move(Vector3.zero)
	end
end

return DummyBrain
