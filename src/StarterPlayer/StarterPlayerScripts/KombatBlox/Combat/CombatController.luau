--!strict
-- CombatController (cliente): pide acciones y reproduce animacion y feedback.
-- El cliente NUNCA decide dano, objetivo, rango, si hubo hit, si bloqueo ni que eslabon sale.
-- Para Dash solo envia la DIRECCION en la que se mueve; el servidor decide el resto.
-- v0.8.1: DASH_FX (animacion, estela, destello, sonido, FOV) a partir de DashStarted.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local CombatConfig = require(KB.Modules.CombatConfig)
local FeelConfig = require(KB.Config.FeelConfig)
local InputController = require(script.Parent.Parent.Input.InputController)
local CameraController = require(script.Parent.Parent.Camera.CameraController)

local RequestAction = SharedUtil.GetRemote("Combat", "RequestAction") :: RemoteEvent
local CombatEvent = SharedUtil.GetRemote("Combat", "CombatEvent") :: RemoteEvent

local LocalPlayer = Players.LocalPlayer
local CombatController = {}

local BLOCK = CombatConfig.Block
local DASH = CombatConfig.Dash
-- Inputs de combate que el cliente reenvia al servidor (el servidor valida contra
-- el MoveSet del personaje: v1.4 ya no hay un moveset global en el cliente).
local FORWARDED_INPUTS: {[string]: boolean} = {
	LightAttack = true,
	Skill1 = true,
	Skill2 = true,
}

local COLOR_HIT = Color3.fromRGB(255, 230, 150)
local COLOR_BLOCK = Color3.fromRGB(120, 190, 255)
local COLOR_BREAK = Color3.fromRGB(255, 120, 40)

-- Presentacion del Dash (solo cliente; no afecta a la jugabilidad)
local DASH_FX = {
	AnimationFolder = "Dash",
	ForwardAnim = "Dash_Forward",
	BackAnim = "Dash_Back",
	BackDot = -0.3,          -- direccion . mirada por debajo de esto = dash hacia atras
	SFX = "Dash_Whoosh",
	TrailLifetime = 0.18,
	TrailColor = Color3.fromRGB(190, 225, 255),
	PuffColor = Color3.fromRGB(220, 235, 255),
	PuffSize = 5,
	PuffTime = 0.25,
	FovKick = 8,
	FovIn = 0.06,
	FovOut = 0.25,
	ShakeIntensity = 0.12,
	ShakeDuration = 0.08,
}

local lastSend = 0
local lastDashSend = 0
local tracks: {[Humanoid]: {[string]: AnimationTrack}} = {}
local warned: {[string]: boolean} = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	SharedUtil.Warn("Combat", message)
end

------------------------------------------------------------------
-- Animaciones
------------------------------------------------------------------
local function getAnimation(folderName: string, name: string): Animation?
	local folder = KB:FindFirstChild("Assets")
	folder = folder and folder:FindFirstChild("Animations")
	folder = folder and folder:FindFirstChild(folderName)
	local anim = folder and folder:FindFirstChild(name)
	if anim and anim:IsA("Animation") then
		return anim
	end
	return nil
end

-- Studio: si la animacion no tiene AnimationId publicado, registra su Source
-- (KeyframeSequence) en el momento de reproducirla. Nunca pisa ids reales.
local function ensurePreviewId(anim: Animation)
	if not RunService:IsStudio() or anim.AnimationId ~= "" then
		return
	end
	local ks = anim:FindFirstChildOfClass("KeyframeSequence")
	if not ks then
		warnOnce("src_" .. anim.Name, "Animacion '" .. anim.Name .. "' no tiene Source (KeyframeSequence)")
		return
	end
	local ok, id = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(ks)
	end)
	if ok and id then
		anim.AnimationId = id
		SharedUtil.Log("Combat", "Preview local de " .. anim.Name)
	else
		warnOnce("reg_" .. anim.Name, "No se pudo registrar '" .. anim.Name .. "': " .. tostring(id))
	end
end

local function playTrack(character: Model, folderName: string, name: string): AnimationTrack?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not (humanoid and animator) then
		return nil
	end

	local anim = getAnimation(folderName, name)
	if anim then
		ensurePreviewId(anim)
	end
	if not anim or anim.AnimationId == "" then
		warnOnce("anim_" .. name, ("Animacion '%s' sin AnimationId. Asignalo en Assets/Animations/%s/%s")
			:format(name, folderName, name))
		return nil
	end

	local byName = tracks[humanoid]
	if not byName then
		byName = {}
		tracks[humanoid] = byName
		humanoid.Died:Connect(function()
			tracks[humanoid] = nil
		end)
	end

	for otherName, otherTrack in byName do
		if otherName ~= name and otherTrack.IsPlaying then
			otherTrack:Stop(0.05)
		end
	end

	local track = byName[name]
	if not track then
		track = animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
		byName[name] = track
	end
	track:Play(0.05)
	return track
end

local function stopTrack(character: Model, name: string)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local byName = humanoid and tracks[humanoid]
	local track = byName and byName[name]
	if track and track.IsPlaying then
		track:Stop(0.1)
	end
end

function CombatController.PlayAttackAnimation(character: Model, animationName: string?): AnimationTrack?
	return playTrack(character, CombatConfig.AnimationFolder, animationName or "M1_1")
end

------------------------------------------------------------------
-- Hooks de feedback
------------------------------------------------------------------
local function playSFX(name: string?)
	if not name then
		return
	end
	local sfxFolder = KB:FindFirstChild("Assets")
	sfxFolder = sfxFolder and sfxFolder:FindFirstChild("SFX")
	local sound = sfxFolder and sfxFolder:FindFirstChild(name)
	if not (sound and sound:IsA("Sound")) or sound.SoundId == "" then
		warnOnce("sfx_" .. name, ("Sonido '%s' sin SoundId. Asignalo en Assets/SFX/%s"):format(name, name))
		return
	end
	SoundService:PlayLocalSound(sound)
end

function CombatController.PlayAttackSFX(name: string?)
	playSFX(name)
end

function CombatController.PlayHitSFX(name: string?)
	playSFX(name)
end

function CombatController.SpawnHitVFX(position: Vector3?, color: Color3?, size: number?)
	if not (CombatConfig.PlaceholderVFX and position) then
		return
	end
	local s = size or 1.6
	local p = Instance.new("Part")
	p.Name = "HitVFX"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(s, s, s)
	p.Position = position
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color or COLOR_HIT
	p.Transparency = 0.25
	p.Parent = workspace
	Debris:AddItem(p, 0.12)
end

-- Delega en CameraController (dueño unico de camara/FOV). Ver auditoria v1.3 B1:
-- asi el shake sigue funcionando aunque la camara pase a Scriptable (lock-on).
function CombatController.CameraShake(intensity: number?, duration: number?)
	CameraController.Shake(
		intensity or CombatConfig.CameraShakeIntensity,
		duration or CombatConfig.CameraShakeDuration
	)
end

-- Hitstop client-only: congela brevemente el track del impacto para dar "peso".
-- La duracion viene de FeelConfig (por accion). NUNCA toca el servidor.
function CombatController.Hitstop(track: AnimationTrack?, duration: number?)
	local d = duration or 0
	if not track or d <= 0 then
		return
	end
	task.spawn(function()
		track:AdjustSpeed(0)
		task.wait(d)
		if track.IsPlaying then
			track:AdjustSpeed(1)
		end
	end)
end

-- Hitstop de una accion segun FeelConfig (M1_1..M1_4 / GuardBreak), opcionalmente recibido.
local function hitstopFor(action: string?, isGuardBreak: boolean, received: boolean): number
	local d = 0
	if isGuardBreak then
		d = FeelConfig.Hitstop.GuardBreak
	elseif action then
		d = FeelConfig.Hitstop.Actions[action] or 0
	end
	if received then
		d *= FeelConfig.Hitstop.ReceivedMultiplier
	end
	return d
end

local function flash(character: Model, color: Color3)
	if character:FindFirstChild("HitFlash") then
		return
	end
	local hl = Instance.new("Highlight")
	hl.Name = "HitFlash"
	hl.FillColor = color
	hl.FillTransparency = 0.6
	hl.OutlineTransparency = 1
	hl.Parent = character
	Debris:AddItem(hl, 0.12)
end

function CombatController.PlayHitReaction(character: Model)
	local track = playTrack(character, CombatConfig.HitReactionFolder, CombatConfig.HitReaction)
	if track then
		return
	end
	flash(character, Color3.fromRGB(255, 255, 255))
end

------------------------------------------------------------------
-- Dash FX (solo presentacion)
------------------------------------------------------------------
-- FOV del dash: delega en CameraController (dueño unico del FOV). Ver auditoria v1.3 B6.
local function fovKick()
	CameraController.FovPunch(DASH_FX.FovKick, DASH_FX.FovIn, DASH_FX.FovOut)
end

local function spawnTrail(root: BasePart, duration: number)
	local top = Instance.new("Attachment")
	top.Name = "KB_DashTrailTop"
	top.Position = Vector3.new(0, 0.9, 0)
	top.Parent = root

	local bottom = Instance.new("Attachment")
	bottom.Name = "KB_DashTrailBottom"
	bottom.Position = Vector3.new(0, -0.9, 0)
	bottom.Parent = root

	local trail = Instance.new("Trail")
	trail.Name = "KB_DashTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = DASH_FX.TrailLifetime
	trail.Color = ColorSequence.new(DASH_FX.TrailColor)
	trail.Transparency = NumberSequence.new(0.3, 1)
	trail.LightEmission = 0.6
	trail.FaceCamera = true
	trail.Parent = root

	-- Deja de emitir al acabar el dash; se destruye cuando la estela ya se ha desvanecido
	task.delay(duration, function()
		if trail.Parent then
			trail.Enabled = false
		end
	end)
	local life = duration + DASH_FX.TrailLifetime + 0.05
	Debris:AddItem(trail, life)
	Debris:AddItem(top, life)
	Debris:AddItem(bottom, life)
end

local function spawnPuff(position: Vector3)
	local p = Instance.new("Part")
	p.Name = "DashPuff"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(1, 1, 1)
	p.Position = position
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = DASH_FX.PuffColor
	p.Transparency = 0.4
	p.Parent = workspace

	TweenService:Create(
		p,
		TweenInfo.new(DASH_FX.PuffTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(DASH_FX.PuffSize, 0.4, DASH_FX.PuffSize), Transparency = 1 }
	):Play()
	Debris:AddItem(p, DASH_FX.PuffTime + 0.05)
end

-- character puede ser el personaje de un jugador o el Model de un NPC.
-- isLocal = true solo cuando dashea el jugador local (efectos de camara/sonido propios).
local function playDashFx(character: Model?, direction: any, duration: number, isLocal: boolean)
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and root and humanoid) then
		return
	end

	-- Animacion segun la direccion respecto a donde mira
	local look = root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local animName = DASH_FX.ForwardAnim
	if typeof(direction) == "Vector3" and flatLook.Magnitude > 0.01 then
		if (direction :: Vector3):Dot(flatLook.Unit) < DASH_FX.BackDot then
			animName = DASH_FX.BackAnim
		end
	end
	playTrack(character, DASH_FX.AnimationFolder, animName)

	-- Estela y destello de salida (todos los clientes)
	spawnTrail(root, duration)
	local feetOffset = humanoid.HipHeight + root.Size.Y / 2
	spawnPuff(root.Position - Vector3.new(0, feetOffset, 0))

	-- Sensacion de velocidad (solo quien dashea, si es el jugador local)
	if isLocal then
		playSFX(DASH_FX.SFX)
		fovKick()
		CombatController.CameraShake(DASH_FX.ShakeIntensity, DASH_FX.ShakeDuration)
	end
end

------------------------------------------------------------------
-- Envio de acciones
------------------------------------------------------------------
local function requestAction(action: string)
	-- Acciones no-combate (p.ej. LockToggle de camara) no van al servidor: ignorar sin warn.
	if action == "LockToggle" then
		return
	end

	-- Block: se envia SIEMPRE, sin filtro anti-spam (soltar nunca debe perderse).
	if action == "BlockStart" or action == "BlockEnd" then
		RequestAction:FireServer(action)
		return
	end

	-- Dash: solo se envia la direccion de movimiento. Cooldown y estado: servidor.
	if action == "Dash" then
		local now = os.clock()
		if now - lastDashSend < DASH.ClientMinInterval then
			return
		end
		lastDashSend = now

		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local direction = humanoid and humanoid.MoveDirection or Vector3.zero

		SharedUtil.Log("Combat", "Dash requested")
		RequestAction:FireServer("Dash", direction)
		return
	end

	-- Ataques y habilidades: el cliente solo comprueba que es una accion conocida.
	-- Quien valida contra el MoveSet del personaje (y energia/cooldown) es el SERVIDOR.
	if not FORWARDED_INPUTS[action] then
		SharedUtil.Warn("Combat", "Accion de input no definida: " .. action)
		return
	end

	local now = os.clock()
	if now - lastSend < CombatConfig.ClientMinSendInterval then
		return
	end
	lastSend = now

	SharedUtil.Log("Combat", action .. " requested")
	RequestAction:FireServer(action)
end

local attackTrack: AnimationTrack? = nil

local function characterOf(player: any): Model?
	if typeof(player) == "Instance" and player:IsA("Player") then
		return player.Character
	end
	return nil
end

-- Resuelve el Model de un actor a partir de los campos del evento: personaje del
-- Player si lo hay, o el Model directo (NPC). Asi el Dummy tambien se anima.
local function modelOf(playerField: any, modelField: any): Model?
	local character = characterOf(playerField)
	if character then
		return character
	end
	if typeof(modelField) == "Instance" and modelField:IsA("Model") then
		return modelField
	end
	return nil
end

local function onCombatEvent(data: any)
	if typeof(data) ~= "table" then
		return
	end

	if data.Type == "ActionStarted" then
		local character = modelOf(data.Attacker, data.AttackerModel)
		if character then
			local track = CombatController.PlayAttackAnimation(character, data.Animation)
			if data.Attacker == LocalPlayer then
				attackTrack = track
				CombatController.PlayAttackSFX(data.AttackSFX)
			end
		end

	elseif data.Type == "DashStarted" then
		local character = modelOf(data.Target, data.Model)
		if character then
			if data.Target == LocalPlayer then
				SharedUtil.Log("Combat", "DASH")
			end
			playDashFx(character, data.Direction, data.Duration or DASH.Duration, data.Target == LocalPlayer)
		end

	elseif data.Type == "HitReactionModel" then
		-- Reaccion de golpe de un NPC (no tiene cliente propio)
		local character = modelOf(nil, data.Model)
		if character then
			CombatController.PlayHitReaction(character)
		end

	elseif data.Type == "BlockChanged" then
		local character = modelOf(data.Target, data.Model)
		if character then
			if data.Blocking then
				playTrack(character, BLOCK.AnimationFolder, BLOCK.Animation)
			else
				stopTrack(character, BLOCK.Animation)
			end
		end

	elseif data.Type == "HitConfirmed" then
		local cfg = CombatConfig.Actions[data.Action]
		CombatController.SpawnHitVFX(data.HitPosition, COLOR_HIT)
		CombatController.PlayHitSFX(cfg and cfg.HitSFX)
		-- Peso por accion: finisher = shake fuerte + FOV punch; resto = shake leve.
		local heavy = FeelConfig.FinisherActions[data.Action] == true
		local shake = if heavy then FeelConfig.Shake.Heavy else FeelConfig.Shake.Light
		CombatController.CameraShake(shake.Intensity, shake.Duration)
		if heavy then
			local f = FeelConfig.Fov.Heavy
			CameraController.FovPunch(f.Delta, f.In, f.Out)
		end
		CombatController.Hitstop(attackTrack, hitstopFor(data.Action, false, false))

	elseif data.Type == "HitBlocked" then
		CombatController.SpawnHitVFX(data.HitPosition, COLOR_BLOCK, 2.2)
		CombatController.PlayHitSFX(BLOCK.BlockSFX)
		local s = FeelConfig.Shake.Blocked
		CombatController.CameraShake(s.Intensity, s.Duration)
		if data.Attacker ~= LocalPlayer then
			local character = LocalPlayer.Character
			if character then
				flash(character, COLOR_BLOCK)
			end
		end

	elseif data.Type == "GuardBroken" then
		SharedUtil.Log("Combat", "GUARD BREAK")
		CombatController.SpawnHitVFX(data.HitPosition, COLOR_BREAK, 3)
		CombatController.PlayHitSFX(BLOCK.GuardBreakSFX)
		local s = FeelConfig.Shake.Break
		CombatController.CameraShake(s.Intensity, s.Duration)
		local f = FeelConfig.Fov.Break
		CameraController.FovPunch(f.Delta, f.In, f.Out)
		if data.Attacker == LocalPlayer then
			CombatController.Hitstop(attackTrack, hitstopFor(nil, true, false))
		end
		if data.Attacker ~= LocalPlayer then
			local character = LocalPlayer.Character
			if character then
				flash(character, COLOR_BREAK)
			end
		end

	elseif data.Type == "AttackResult" then
		if data.Hit then
			SharedUtil.Log("Combat", ("%s HIT (%d target/s)"):format(data.Action, data.Targets or 0))
		elseif (data.Blocked or 0) > 0 then
			SharedUtil.Log("Combat", data.Action .. " BLOCKED")
		else
			SharedUtil.Log("Combat", data.Action .. " missed")
		end

	elseif data.Type == "HitReceived" then
		local name = typeof(data.Attacker) == "Instance" and (data.Attacker :: Player).Name or "?"
		SharedUtil.Log("Combat", ("Received %s from %s (-%s)"):format(data.Action, name, tostring(data.Damage)))
		local character = LocalPlayer.Character
		if character then
			CombatController.PlayHitReaction(character)
		end
		local heavy = FeelConfig.FinisherActions[data.Action] == true
		local s = if heavy then FeelConfig.Shake.Heavy else FeelConfig.Shake.Received
		CombatController.CameraShake(s.Intensity, s.Duration)
	end
end

function CombatController:Init()
end

function CombatController:Start()
	InputController:OnAction(requestAction)
	CombatEvent.OnClientEvent:Connect(onCombatEvent)
end

return CombatController
