--!strict
-- CombatService (servidor): UNICA autoridad del combate.
-- Ataque: RequestAction -> combo -> STARTUP -> ACTIVE -> RECOVERY -> encadenado.
-- Block:  BlockStart/BlockEnd -> estado Blocking + atributo KB_Blocking.
-- Dash:   Dash + direccion (saneada) -> estado Dashing + LinearVelocity temporal.
-- v1.0a:  consulta a MatchService (CanAct / CanDealDamage / CanReceiveDamage),
--         expone ResetFighter y ActionToken invalida ataques en curso tras un reset.
-- v1.1:   ACTOR = Player (jugador) o Model (NPC). Misma tuberia de combate para ambos.
--         API publica PerformAction / GetActorState / ResetFighter / ClearActor para que
--         la IA use el combate real. Dano validado con MatchService.CanHit (seguridad PvP).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local CombatConfig = require(KB.Modules.CombatConfig)
local Registry = require(script.Parent.Parent.Services.ServiceRegistry)

local RequestAction = SharedUtil.GetRemote("Combat", "RequestAction") :: RemoteEvent
local CombatEvent = SharedUtil.GetRemote("Combat", "CombatEvent") :: RemoteEvent

local TAG = "Combat"
local S = CombatConfig.States
local BLOCK = CombatConfig.Block
local DASH = CombatConfig.Dash
local BLOCK_ATTR = "KB_Blocking"
local CombatService = {}

-- Se resuelve en Start. Si no existe, el combate funciona libre (sin partidas).
local MatchService: any = nil

------------------------------------------------------------------
-- Actor: Player (jugador) o Model (NPC).
-- La clave de estado es el propio ref. Para un jugador es estable entre respawns;
-- para un NPC es su Model (se reconstruye cada round -> estado fresco, que es lo deseado).
------------------------------------------------------------------
type Actor = Player | Model

-- Devuelve (player?, model?). player es nil para NPC.
local function actorInfo(ref: any): (Player?, Model?)
	if typeof(ref) == "Instance" then
		if ref:IsA("Player") then
			return ref, ref.Character
		elseif ref:IsA("Model") then
			return nil, ref
		end
	end
	return nil, nil
end

local function refName(ref: any): string
	local player, model = actorInfo(ref)
	if player then
		return player.Name
	end
	if model then
		return model.Name
	end
	return "?"
end

local function canAct(ref: any): boolean
	return MatchService == nil or MatchService.CanAct(ref)
end

local function canDealDamage(ref: any): boolean
	return MatchService == nil or MatchService.CanDealDamage(ref)
end

-- Autoridad de dano v1.1: valida atacante Y victima por Model (cierra el agujero PvP).
local function canHit(attackerModel: Model?, victimModel: Model): boolean
	if MatchService == nil then
		return true
	end
	if not attackerModel then
		return false
	end
	return MatchService.CanHit(attackerModel, victimModel)
end

type ActorState = {
	State: string,
	ComboIndex: number,
	ComboNext: string?,
	ComboExpires: number,
	BufferOpen: boolean,
	Buffered: boolean,
	SavedWalkSpeed: number?,
	StunToken: number,
	DashToken: number,
	ActionToken: number,         -- invalida cualquier executeAction en curso tras un reset
	DashAttachment: Attachment?,
	LastDash: number?,
	LastAction: {[string]: number},
	WindowStart: number,
	WindowCount: number,
}
local states: {[any]: ActorState} = {}

local function getState(ref: any): ActorState
	local s = states[ref]
	if not s then
		s = {
			State = S.Idle,
			ComboIndex = 0,
			ComboNext = nil,
			ComboExpires = 0,
			BufferOpen = false,
			Buffered = false,
			SavedWalkSpeed = nil,
			StunToken = 0,
			DashToken = 0,
			ActionToken = 0,
			DashAttachment = nil,
			LastDash = nil,
			LastAction = {},
			WindowStart = os.clock(),
			WindowCount = 0,
		}
		states[ref] = s
	end
	return s
end

local function resetCombo(state: ActorState)
	state.ComboIndex = 0
	state.ComboNext = nil
	state.ComboExpires = 0
	state.Buffered = false
	state.BufferOpen = false
end

local function passesRateLimit(state: ActorState): boolean
	local now = os.clock()
	if now - state.WindowStart >= 1 then
		state.WindowStart = now
		state.WindowCount = 0
	end
	state.WindowCount += 1
	return state.WindowCount <= CombatConfig.MaxRequestsPerSecond
end

local function getLiving(ref: any): (Model?, BasePart?)
	local _, model = actorInfo(ref)
	if not model then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return nil
	end
	if humanoid.Health <= 0 then
		return nil
	end
	return model, root
end

------------------------------------------------------------------
-- Block
------------------------------------------------------------------
local function clearBlock(ref: any)
	local s = getState(ref)
	local player, model = actorInfo(ref)
	if model then
		model:SetAttribute(BLOCK_ATTR, false)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and s.SavedWalkSpeed then
			humanoid.WalkSpeed = s.SavedWalkSpeed
		end
	end
	s.SavedWalkSpeed = nil
	CombatEvent:FireAllClients({
		Type = "BlockChanged",
		Target = player,
		Model = model,
		Blocking = false,
	})
end

local function startBlock(ref: any)
	local s = getState(ref)
	if s.State ~= S.Idle then
		return
	end
	local model = getLiving(ref)
	if not model then
		return
	end
	local player = actorInfo(ref)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid

	s.State = S.Blocking
	resetCombo(s)
	s.SavedWalkSpeed = humanoid.WalkSpeed
	humanoid.WalkSpeed = BLOCK.WalkSpeed
	model:SetAttribute(BLOCK_ATTR, true)
	SharedUtil.Log(TAG, refName(ref) .. " block ON")

	CombatEvent:FireAllClients({
		Type = "BlockChanged",
		Target = player,
		Model = model,
		Blocking = true,
	})
end

local function endBlock(ref: any)
	local s = getState(ref)
	if s.State ~= S.Blocking then
		return
	end
	clearBlock(ref)
	s.State = S.Idle
	SharedUtil.Log(TAG, refName(ref) .. " block OFF")
end

local function isBlockingFrom(victimModel: Model, attackerRoot: BasePart): boolean
	if victimModel:GetAttribute(BLOCK_ATTR) ~= true then
		return false
	end
	local victimRoot = victimModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not victimRoot then
		return false
	end

	local toAttacker = attackerRoot.Position - victimRoot.Position
	toAttacker = Vector3.new(toAttacker.X, 0, toAttacker.Z)
	if toAttacker.Magnitude < 0.01 then
		return true
	end

	local look = victimRoot.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 0.01 then
		return false
	end

	return look.Unit:Dot(toAttacker.Unit) > BLOCK.FrontDot
end

------------------------------------------------------------------
-- Dash
------------------------------------------------------------------
local function sanitizeDirection(raw: any, root: BasePart): Vector3
	if typeof(raw) == "Vector3" then
		local flat = Vector3.new(raw.X, 0, raw.Z)
		local mag = flat.Magnitude
		if mag == mag and mag < math.huge and mag > 0.05 then
			return flat / mag
		end
	end
	local look = root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 0.01 then
		return Vector3.new(0, 0, -1)
	end
	return flatLook.Unit
end

local function stopDash(ref: any)
	local s = getState(ref)
	s.DashToken += 1
	if s.DashAttachment then
		s.DashAttachment:Destroy()
		s.DashAttachment = nil
	end
end

local function startDash(ref: any, rawDirection: any)
	local s = getState(ref)
	if s.State ~= S.Idle then
		return
	end
	local model, root = getLiving(ref)
	if not (model and root) then
		return
	end
	local player = actorInfo(ref)

	local now = os.clock()
	if s.LastDash and now - s.LastDash < DASH.Cooldown then
		return
	end
	s.LastDash = now

	resetCombo(s)
	stopDash(ref)
	s.State = S.Dashing
	local token = s.DashToken

	local direction = sanitizeDirection(rawDirection, root)
	local speed = DASH.Distance / DASH.Duration

	local attachment = Instance.new("Attachment")
	attachment.Name = "KB_DashAttachment"

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "KB_Dash"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.xAxis
	velocity.SecondaryTangentAxis = Vector3.zAxis
	velocity.PlaneVelocity = Vector2.new(direction.X * speed, direction.Z * speed)
	velocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	velocity.MaxForce = DASH.MaxForce
	velocity.Parent = attachment

	attachment.Parent = root
	s.DashAttachment = attachment

	SharedUtil.Log(TAG, refName(ref) .. " DASH")
	CombatEvent:FireAllClients({
		Type = "DashStarted",
		Target = player,
		Model = model,
		Direction = direction,
		Duration = DASH.Duration,
	})

	task.delay(DASH.Duration, function()
		local current = states[ref]
		if not current or current.DashToken ~= token then
			return
		end
		stopDash(ref)
		if current.State == S.Dashing then
			current.State = S.Idle
		end
	end)
end

------------------------------------------------------------------
-- Hitbox
------------------------------------------------------------------
local function debugBox(cf: CFrame, size: Vector3, life: number)
	if not (SharedUtil.IsDebug() and CombatConfig.DebugShowHitboxes) then
		return
	end
	local p = Instance.new("Part")
	p.Name = "DebugHitbox"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 0.7
	p.Color = Color3.fromRGB(255, 60, 60)
	p.Material = Enum.Material.ForceField
	p.CFrame = cf
	p.Size = size
	p.Parent = workspace
	Debris:AddItem(p, life)
end

local function queryHitbox(attackerChar: Model, root: BasePart, cfg: any): {Humanoid}
	local cf = root.CFrame * CFrame.new(cfg.HitboxOffset)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attackerChar }

	local found: {Humanoid} = {}
	local seen: {[Humanoid]: boolean} = {}
	for _, part in workspace:GetPartBoundsInBox(cf, cfg.HitboxSize, params) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		local hum = model and model:FindFirstChildOfClass("Humanoid")
		if hum and not seen[hum] and hum.Health > 0 then
			seen[hum] = true
			table.insert(found, hum)
		end
	end
	return found
end

------------------------------------------------------------------
-- Impacto
------------------------------------------------------------------
-- victimRef es el Player de la victima si lo hay; si no (NPC), su Model.
local function applyStun(victimRef: any, duration: number, stunState: string)
	local s = getState(victimRef)
	if s.State == S.Blocking then
		clearBlock(victimRef)
	end
	if s.State == S.Dashing then
		stopDash(victimRef)
	end
	resetCombo(s)
	s.State = stunState
	s.StunToken += 1
	local token = s.StunToken

	task.delay(duration, function()
		local current = states[victimRef]
		if current and current.StunToken == token and current.State == stunState then
			current.State = S.Idle
		end
	end)
end

-- Devuelve "hit", "blocked", "guardbreak" o "none" (la partida no permite dano)
local function onHit(ref: any, attackerModel: Model, action: string, cfg: any, hum: Humanoid, attackerRoot: BasePart): string
	local victimModel = hum.Parent :: Model
	if not canHit(attackerModel, victimModel) then
		return "none"
	end

	local player = actorInfo(ref)   -- atacante (nil si NPC): solo para feedback de cliente
	local victimRoot = victimModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hitPosition = victimRoot and victimRoot.Position or Vector3.zero
	local victim = Players:GetPlayerFromCharacter(victimModel)
	local victimRef: any = victim or victimModel   -- para hitstun (jugador o NPC)

	if isBlockingFrom(victimModel, attackerRoot) then
		if cfg.GuardBreak then
			applyStun(victimRef, cfg.GuardBreakStun or 1, S.Stunned)
			if not victim then
				victimModel:SetAttribute(BLOCK_ATTR, false)
			end
			hum:TakeDamage(cfg.Damage)
			SharedUtil.Log(TAG, ("GUARD BREAK on %s (%s, %d)"):format(victimModel.Name, action, cfg.Damage))

			local payload = {
				Type = "GuardBroken",
				Action = action,
				Victim = victimModel.Name,
				Attacker = player,
				Damage = cfg.Damage,
				HitPosition = hitPosition,
			}
			if player then
				CombatEvent:FireClient(player, payload)
			end
			if victim then
				CombatEvent:FireClient(victim, payload)
			end
			return "guardbreak"
		end

		local chip = cfg.Damage * BLOCK.DamageMultiplier
		if chip > 0 then
			hum:TakeDamage(chip)
		end
		SharedUtil.Log(TAG, ("%s BLOCKED %s"):format(victimModel.Name, action))

		local payload = {
			Type = "HitBlocked",
			Action = action,
			Victim = victimModel.Name,
			Attacker = player,
			HitPosition = hitPosition,
		}
		if player then
			CombatEvent:FireClient(player, payload)
		end
		if victim then
			CombatEvent:FireClient(victim, payload)
		end
		return "blocked"
	end

	hum:TakeDamage(cfg.Damage)
	SharedUtil.Log(TAG, ("Hit %s for %d (%s)"):format(victimModel.Name, cfg.Damage, action))

	if player then
		CombatEvent:FireClient(player, {
			Type = "HitConfirmed",
			Action = action,
			Damage = cfg.Damage,
			Victim = victimModel.Name,
			HitPosition = hitPosition,
		})
	end

	applyStun(victimRef, cfg.Hitstun or 0.2, S.Hitstun)
	if victim then
		CombatEvent:FireClient(victim, {
			Type = "HitReceived",
			Action = action,
			Attacker = player,
			Damage = cfg.Damage,
			HitPosition = hitPosition,
			Hitstun = cfg.Hitstun or 0.2,
		})
	else
		-- NPC golpeado: reaccion visible para todos (el dummy no tiene cliente propio)
		CombatEvent:FireAllClients({
			Type = "HitReactionModel",
			Model = victimModel,
			HitPosition = hitPosition,
		})
	end
	return "hit"
end

------------------------------------------------------------------
-- Ataque
------------------------------------------------------------------
local executeAction

executeAction = function(ref: any, action: string, cfg: any)
	local state = getState(ref)
	state.ActionToken += 1
	local token = state.ActionToken   -- si cambia (ResetFighter/respawn), este ataque queda anulado

	local player, model = actorInfo(ref)

	state.State = S.Attacking
	state.BufferOpen = false
	state.Buffered = false
	state.ComboIndex += 1
	SharedUtil.Log(TAG, ("%s started (combo %d)"):format(action, state.ComboIndex))

	CombatEvent:FireAllClients({
		Type = "ActionStarted",
		Action = action,
		Animation = cfg.Animation,
		AttackSFX = cfg.AttackSFX,
		ComboIndex = state.ComboIndex,
		Attacker = player,
		AttackerModel = model,
	})

	task.wait(cfg.Startup)
	if state.ActionToken ~= token then
		return
	end

	local hitSet: {[Humanoid]: boolean} = {}
	local hitCount = 0
	local blockedCount = 0
	local char, root = getLiving(ref)
	if char and root and canDealDamage(ref) then
		debugBox(root.CFrame * CFrame.new(cfg.HitboxOffset), cfg.HitboxSize, cfg.ActiveTime)
		local elapsed = 0
		while elapsed < cfg.ActiveTime do
			if state.ActionToken ~= token then
				return
			end
			local c, r = getLiving(ref)
			if not (c and r) then
				break
			end
			-- Corte irreversible: si la ronda deja de estar en Fighting, el golpe deja de danar
			if not canDealDamage(ref) then
				break
			end
			for _, hum in queryHitbox(c, r, cfg) do
				if not hitSet[hum] then
					hitSet[hum] = true
					local outcome = onHit(ref, c, action, cfg, hum, r)
					if outcome == "blocked" then
						blockedCount += 1
					elseif outcome ~= "none" then
						hitCount += 1
					end
				end
			end
			elapsed += task.wait(CombatConfig.HitboxTickRate)
		end
	end

	if player then
		CombatEvent:FireClient(player, {
			Type = "AttackResult",
			Action = action,
			Hit = hitCount > 0,
			Targets = hitCount,
			Blocked = blockedCount,
		})
	end

	state.BufferOpen = true
	task.wait(cfg.Recovery)
	if state.ActionToken ~= token then
		return   -- un reset ya dejo el estado limpio: no tocar nada de la ronda nueva
	end
	state.BufferOpen = false

	if state.State ~= S.Attacking then
		return
	end

	local nextAction = cfg.ComboNext
	local nextCfg = nextAction and CombatConfig.Actions[nextAction]

	if state.Buffered and nextCfg and canAct(ref) then
		state.Buffered = false
		local c, r = getLiving(ref)
		if c and r then
			executeAction(ref, nextAction, nextCfg)
			return
		end
	end

	state.Buffered = false
	state.State = S.Idle

	if nextCfg then
		state.ComboNext = nextAction
		state.ComboExpires = os.clock() + (cfg.ComboWindow or 0)
	else
		resetCombo(state)
	end
end

local function resolveNextAction(state: ActorState, rootAction: string): string
	if state.ComboNext and os.clock() <= state.ComboExpires then
		return state.ComboNext
	end
	state.ComboIndex = 0
	return rootAction
end

-- Nucleo de despacho de acciones. Lo usan tanto los jugadores (via Remote) como la IA
-- (via CombatService.PerformAction). NO aplica el rate-limit del Remote (eso es del wrapper).
local function performAction(ref: any, action: string, payload: any)
	-- BlockEnd NUNCA pasa por la partida (perderlo dejaria al actor bloqueando).
	if action == "BlockEnd" then
		endBlock(ref)
		return
	end

	-- La partida decide si se puede actuar (Countdown, RoundEnd, MatchEnd, K.O. pendiente: no)
	if not canAct(ref) then
		return
	end

	if action == "BlockStart" then
		startBlock(ref)
		return
	end

	if action == "Dash" then
		startDash(ref, payload)
		return
	end

	local rootAction = CombatConfig.InputActions[action]
	if not rootAction then
		SharedUtil.Warn(TAG, refName(ref) .. " unknown action: " .. action)
		return
	end

	local state = getState(ref)

	if state.State == S.Attacking then
		if state.BufferOpen then
			state.Buffered = true
		end
		return
	end

	if state.State ~= S.Idle then
		return
	end

	local character, root = getLiving(ref)
	if not character or not root then
		return
	end

	local nextAction = resolveNextAction(state, rootAction)
	local cfg = CombatConfig.Actions[nextAction]
	if not cfg then
		return
	end

	local now = os.clock()
	local last = state.LastAction[nextAction]
	if cfg.Cooldown > 0 and last and now - last < cfg.Cooldown then
		return
	end
	state.LastAction[nextAction] = now

	SharedUtil.Log(TAG, refName(ref) .. " " .. nextAction .. " requested")
	task.spawn(executeAction, ref, nextAction, cfg)
end

-- Wrapper del Remote: valida entrada + rate-limit y delega en performAction.
local function onRequestAction(player: Player, action: any, payload: any)
	if typeof(action) ~= "string" then
		return
	end

	-- BlockEnd NUNCA pasa por rate limit (soltar la guardia no debe perderse jamas).
	if action == "BlockEnd" then
		endBlock(player)
		return
	end

	local state = getState(player)
	if not passesRateLimit(state) then
		return
	end

	performAction(player, action, payload)
end

------------------------------------------------------------------
-- API publica (jugadores via Remote; IA via estas funciones)
------------------------------------------------------------------
-- La IA del NPC inyecta acciones EXACTAMENTE como un jugador: "LightAttack",
-- "BlockStart"/"BlockEnd", "Dash" (+ direccion). Cero reglas de combate en la IA.
function CombatService.PerformAction(actorRef: Actor, action: string, payload: any?)
	if typeof(action) ~= "string" then
		return
	end
	performAction(actorRef, action, payload)
end

-- Estado de combate real de un actor (solo lectura). La IA lo consulta para no pisarse:
-- solo decide cuando esta "Idle"; respeta Attacking/Blocking/Dashing/Hitstun/Stunned.
function CombatService.GetActorState(actorRef: Actor): string
	local s = states[actorRef]
	return s and s.State or S.Idle
end

------------------------------------------------------------------
-- API para MatchService
------------------------------------------------------------------
-- Reset atomico: combo, bloqueo (atributo + WalkSpeed), dash, hitstun, stun y ataques en curso.
-- Acepta Player (jugador) o Model (NPC).
function CombatService.ResetFighter(actorRef: Actor)
	local s = getState(actorRef)
	local _, model = actorInfo(actorRef)
	if s.State == S.Blocking or (model and model:GetAttribute(BLOCK_ATTR) == true) then
		clearBlock(actorRef)
	end
	stopDash(actorRef)
	resetCombo(s)
	s.StunToken += 1
	s.ActionToken += 1
	s.State = S.Idle
end

-- Libera el estado asociado a un actor (evita fugas al descartar el Model de un NPC).
function CombatService.ClearActor(actorRef: Actor)
	CombatService.ResetFighter(actorRef)
	states[actorRef] = nil
end

------------------------------------------------------------------
-- Ciclo de vida
------------------------------------------------------------------
local function onCharacterAdded(player: Player)
	local s = getState(player)
	resetCombo(s)
	s.SavedWalkSpeed = nil
	s.StunToken += 1
	s.DashToken += 1
	s.ActionToken += 1
	s.DashAttachment = nil
	s.State = S.Idle
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
end

function CombatService:Init()
end

function CombatService:Start()
	local ok, service = pcall(Registry.Get, "MatchService")
	if ok then
		MatchService = service
	else
		SharedUtil.Warn(TAG, "MatchService no registrado: combate libre sin partidas")
	end

	RequestAction.OnServerEvent:Connect(onRequestAction)

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

return CombatService
