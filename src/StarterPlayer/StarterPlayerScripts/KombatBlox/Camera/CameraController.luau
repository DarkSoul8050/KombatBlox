--!strict
-- CameraController (cliente): UNICO dueño de la camara y el FOV.
-- Lock-on de combate: durante Fighting enmarca a los DOS fighters (self + rival),
-- identificados por el snapshot de MatchService (NUNCA por proximidad).
-- Expone Shake() y FovPunch() para que CombatController delegue el feel aqui
-- (asi el shake sigue funcionando con la camara Scriptable; ver auditoria B1).
--
-- Auto-lock al entrar en Fighting + toggle manual (accion "LockToggle" del InputController).
-- KO/RoundEnd/MatchEnd/Waiting -> vuelve a camara normal. Round nuevo -> re-adquiere Model.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KB = ReplicatedStorage:WaitForChild("KombatBlox")
local SharedUtil = require(KB.Modules.SharedUtil)
local CameraConfig = require(KB.Config.CameraConfig)
local InputController = require(script.Parent.Parent.Input.InputController)

local MatchStateChanged = SharedUtil.GetRemote("Match", "MatchStateChanged")
local GetMatchState = SharedUtil.GetRemote("Match", "GetMatchState")

local LocalPlayer = Players.LocalPlayer

local CameraController = {}

-- Estado de partida (via snapshot)
local snapshot: any = nil
local lockEnabled = CameraConfig.LockDefault

-- Suavizado de la camara con script
local curPos: Vector3? = nil
local curLook: Vector3? = nil
local scripting = false          -- true mientras controlamos la camara (Scriptable)

-- Shake (acumulador con decaimiento)
local shakeMag = 0
local shakeDur = 0
local shakeElapsed = 0

-- FOV punch (maquina simple in -> out)
local fovValue = 0
local fovDelta = 0
local fovInRate = 0
local fovOutRate = 0
local fovStage = "idle"          -- "in" | "out" | "idle"

------------------------------------------------------------------
-- API publica de feel (dueño de camara/FOV)
------------------------------------------------------------------
function CameraController.Shake(intensity: number?, duration: number?)
	local i = intensity or 0.3
	local d = duration or 0.12
	-- El impulso mas fuerte manda; reinicia el decaimiento.
	if i >= shakeMag or shakeElapsed >= shakeDur then
		shakeMag = i
	else
		shakeMag = math.max(shakeMag, i)
	end
	shakeDur = d
	shakeElapsed = 0
end

function CameraController.FovPunch(delta: number, inTime: number?, outTime: number?)
	fovDelta = delta
	fovInRate = delta / math.max(inTime or 0.05, 0.01)
	fovOutRate = delta / math.max(outTime or 0.2, 0.01)
	fovStage = "in"
end

------------------------------------------------------------------
-- Fighters desde el snapshot (self + rival, o A/B si soy espectador)
------------------------------------------------------------------
local function rootOf(fighter: any): BasePart?
	local model = fighter and fighter.Model
	if typeof(model) == "Instance" and model:IsDescendantOf(workspace) then
		return model:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

-- Devuelve (p1, p2): p1 = mi fighter (o A), p2 = el rival (o B).
local function resolveRoots(): (BasePart?, BasePart?)
	local fighters = snapshot and snapshot.Fighters
	if not fighters then
		return nil, nil
	end
	local A, B = fighters.A, fighters.B
	if not (A and B) then
		return nil, nil
	end
	if A.Player == LocalPlayer then
		return rootOf(A), rootOf(B)
	elseif B.Player == LocalPlayer then
		return rootOf(B), rootOf(A)
	end
	-- Espectador: A a un lado, B al otro
	return rootOf(A), rootOf(B)
end

local function humanoidOfLocal(): Humanoid?
	local char = LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

------------------------------------------------------------------
-- Framing
------------------------------------------------------------------
local function framing(p1: BasePart, p2: BasePart): (Vector3, Vector3)
	local pos1 = p1.Position
	local pos2 = p2.Position
	local flat1 = Vector3.new(pos1.X, 0, pos1.Z)
	local flat2 = Vector3.new(pos2.X, 0, pos2.Z)

	local axis = flat2 - flat1
	local separation = axis.Magnitude
	local dir = if separation > 0.05 then axis / separation else Vector3.new(0, 0, -1)
	local right = dir:Cross(Vector3.yAxis)

	local backDist = math.clamp(
		CameraConfig.BaseDist + separation * CameraConfig.SepFactor,
		CameraConfig.MinDist,
		CameraConfig.MaxDist
	)

	local camPos = pos1
		- dir * backDist
		+ Vector3.yAxis * CameraConfig.Height
		+ right * CameraConfig.ShoulderOffset

	local mid = pos1:Lerp(pos2, CameraConfig.LookBias)
	local lookAt = Vector3.new(mid.X, mid.Y + CameraConfig.LookHeight, mid.Z)
	return camPos, lookAt
end

-- Retrae la camara si choca con geometria entre lookAt y camPos.
local function antiClip(lookAt: Vector3, camPos: Vector3, ignore: {Instance}): Vector3
	local dir = camPos - lookAt
	local dist = dir.Magnitude
	if dist < 0.01 then
		return camPos
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(lookAt, dir, params)
	if result then
		local safe = (result.Position - lookAt).Magnitude - CameraConfig.RaycastMargin
		safe = math.max(safe, 2)
		return lookAt + dir.Unit * safe
	end
	return camPos
end

------------------------------------------------------------------
-- Actualizacion de feel (shake + fov) por frame
------------------------------------------------------------------
local function stepShake(dt: number): Vector3
	if shakeElapsed >= shakeDur then
		return Vector3.zero
	end
	local k = 1 - shakeElapsed / shakeDur
	shakeElapsed += dt
	return Vector3.new((math.random() * 2 - 1), (math.random() * 2 - 1) * 0.6, 0) * shakeMag * k
end

local function stepFov(dt: number)
	if fovStage == "in" then
		fovValue += fovInRate * dt
		if fovValue >= fovDelta then
			fovValue = fovDelta
			fovStage = "out"
		end
	elseif fovStage == "out" then
		fovValue -= fovOutRate * dt
		if fovValue <= 0 then
			fovValue = 0
			fovStage = "idle"
		end
	end
end

------------------------------------------------------------------
-- Bucle principal
------------------------------------------------------------------
local function update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	stepFov(dt)
	local shakeVec = stepShake(dt)

	-- FOV lo poseemos siempre (funciona en Custom y en Scriptable).
	camera.FieldOfView = CameraConfig.BaseFov + fovValue

	local p1, p2 = resolveRoots()
	local fighting = snapshot and snapshot.State == "Fighting"
	local wantLock = fighting and lockEnabled and p1 ~= nil and p2 ~= nil

	if not wantLock then
		-- Camara normal. El shake se aplica por Humanoid.CameraOffset (sin cortar el feel).
		if scripting then
			scripting = false
			curPos, curLook = nil, nil
			camera.CameraType = Enum.CameraType.Custom
		end
		local hum = humanoidOfLocal()
		if hum then
			hum.CameraOffset = shakeVec
		end
		return
	end

	-- Lock-on activo: nosotros controlamos la camara.
	scripting = true
	camera.CameraType = Enum.CameraType.Scriptable
	local hum = humanoidOfLocal()
	if hum then
		hum.CameraOffset = Vector3.zero   -- el shake va en el CFrame, no aqui
	end

	local desiredPos, desiredLook = framing(p1 :: BasePart, p2 :: BasePart)
	desiredPos = antiClip(desiredLook, desiredPos, { (p1 :: BasePart).Parent :: Instance, (p2 :: BasePart).Parent :: Instance })

	curPos = curPos or camera.CFrame.Position
	curLook = curLook or (camera.CFrame.Position + camera.CFrame.LookVector * 10)

	local alpha = 1 - math.exp(-dt * CameraConfig.Responsiveness)
	curPos = (curPos :: Vector3):Lerp(desiredPos, alpha)
	curLook = (curLook :: Vector3):Lerp(desiredLook, alpha)

	local baseCF = CFrame.lookAt(curPos :: Vector3, curLook :: Vector3)
	camera.CFrame = baseCF * CFrame.new(shakeVec)
end

------------------------------------------------------------------
-- Ciclo de vida
------------------------------------------------------------------
local function onSnapshot(snap: any)
	if typeof(snap) == "table" then
		snapshot = snap
	end
end

local function onAction(action: string)
	if action == "LockToggle" then
		lockEnabled = not lockEnabled
		SharedUtil.Log("Camera", "Lock-on " .. (if lockEnabled then "ON" else "OFF"))
	end
end

function CameraController:Init()
end

function CameraController:Start()
	MatchStateChanged.OnClientEvent:Connect(onSnapshot)
	InputController:OnAction(onAction)

	-- Entrada tardia: estado actual.
	task.spawn(function()
		local ok, snap = pcall(function()
			return GetMatchState:InvokeServer()
		end)
		if ok and snap and not snapshot then
			onSnapshot(snap)
		end
	end)

	RunService:BindToRenderStep("KB_Camera", Enum.RenderPriority.Camera.Value, update)
	SharedUtil.Log("Camera", "CameraController v1.3 listo")
end

return CameraController
