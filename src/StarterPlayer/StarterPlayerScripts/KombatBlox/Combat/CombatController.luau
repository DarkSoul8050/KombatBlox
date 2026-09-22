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
local InputController = require(script.Parent.Parent.Input.InputController)

local RequestAction = SharedUtil.GetRemote("Combat", "RequestAction") :: RemoteEvent
local CombatEvent = SharedUtil.GetRemote("Combat", "CombatEvent") :: RemoteEvent

local LocalPlayer = Players.LocalPlayer
local CombatController = {}

local BLOCK = CombatConfig.Block
local DASH = CombatConfig.Dash
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

function CombatController.CameraShake(intensity: number?, duration: number?)
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local power = intensity or CombatConfig.CameraShakeIntensity
	local time = duration or CombatConfig.CameraShakeDuration
	local elapsed = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= time or humanoid.Health <= 0 then
			humanoid.CameraOffset = Vector3.zero
			conn:Disconnect()
			return
		end
		local decay = 1 - (elapsed / time)
		humanoid.CameraOffset = Vector3.new(
			(math.random() - 0.5) * power * decay,
			(math.random() - 0.5) * power * decay,
			0
		)
	end)
end

function CombatController.Hitstop(track: AnimationTrack?)
	local duration = CombatConfig.Hitstop
	if not track or duration <= 0 then
		return
	end
	task.spawn(function()
		track:AdjustSpeed(0)
		task.wait(duration)
		if track.IsPlaying then
			track:AdjustSpeed(1)
		end
	end)
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
local fovToken = 0
local baseFov: number? = nil
local fovUpTween: Tween? = nil
local fovDownTween: Tween? = nil

local function fovKick()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	-- Cancelar cualquier kick anterior antes de empezar (dashes consecutivos)
	if fovUpTween then
		fovUpTween:Cancel()
		fovUpTween = nil
	end
	if fovDownTween then
		fovDownTween:Cancel()
		fovDownTween = nil
	end

	fovToken += 1
	local token = fovToken
	-- baseFov solo se captura en reposo: un kick encadenado reutiliza el FOV original
	if not baseFov then
		baseFov = camera.FieldOfView
	end
	local base = baseFov :: number

	local up = TweenService:Create(
		camera,
		TweenInfo.new(DASH_FX.FovIn, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = base + DASH_FX.FovKick }
	)
	up.Completed:Connect(function(state)
		if state ~= Enum.PlaybackState.Completed or fovToken ~= token then
			return
		end
		local down = TweenService:Create(
			camera,
			TweenInfo.new(DASH_FX.FovOut, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ FieldOfView = base }
		)
		down.Completed:Connect(function(downState)
			if downState == Enum.PlaybackState.Completed and fovToken == token then
				baseFov = nil
				fovDownTween = nil
			end
		end)
		fovDownTween = down
		down:Play()
	end)
	fovUpTween = up
	up:Play()
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

local function playDashFx(player: Player, direction: any, duration: number)
	local character = player.Character
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

	-- Sensacion de velocidad (solo quien dashea)
	if player == LocalPlayer then
		playSFX(DASH_FX.SFX)
		fovKick()
		CombatController.CameraShake(DASH_FX.ShakeIntensity, DASH_FX.ShakeDuration)
	end
end

------------------------------------------------------------------
-- Envio de acciones
------------------------------------------------------------------
local function requestAction(action: string)
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

	-- Ataques: solo acciones de input conocidas. El SERVIDOR decide el eslabon.
	if not CombatConfig.InputActions[action] then
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

local function onCombatEvent(data: any)
	if typeof(data) ~= "table" then
		return
	end

	if data.Type == "ActionStarted" then
		local character = characterOf(data.Attacker)
		if character then
			local track = CombatController.PlayAttackAnimation(character, data.Animation)
			if data.Attacker == LocalPlayer then
				attackTrack = track
				CombatController.PlayAttackSFX(data.AttackSFX)
			end
		end

	elseif data.Type == "DashStarted" then
		if typeof(data.Target) == "Instance" and data.Target:IsA("Player") then
			if data.Target == LocalPlayer then
				SharedUtil.Log("Combat", "DASH")
			end
			playDashFx(data.Target, data.Direction, data.Duration or DASH.Duration)
		end

	elseif data.Type == "BlockChanged" then
		local character = characterOf(data.Target)
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
		CombatController.CameraShake()
		CombatController.Hitstop(attackTrack)

	elseif data.Type == "HitBlocked" then
		CombatController.SpawnHitVFX(data.HitPosition, COLOR_BLOCK, 2.2)
		CombatController.PlayHitSFX(BLOCK.BlockSFX)
		CombatController.CameraShake(0.15, 0.08)
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
		CombatController.CameraShake(0.8, 0.2)
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
		CombatController.CameraShake(0.6, 0.15)
	end
end

function CombatController:Init()
end

function CombatController:Start()
	InputController:OnAction(requestAction)
	CombatEvent.OnClientEvent:Connect(onCombatEvent)
end

return CombatController
