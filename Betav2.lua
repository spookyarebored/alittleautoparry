--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Camera = workspace.CurrentCamera

-- Helper function to filter a table
local function FilterTable(tbl, fn)
    local result = {}
    for k, v in pairs(tbl) do
        if fn(v, k) then
            table.insert(result, v)
        end
    end
    return result
end

--// Player
local Player = Players.LocalPlayer

--// Settings
local Settings = {
    -- Paramètres de timing adaptatifs
    BaseParryETAThreshold = 0.26, -- Légèrement réduit pour une anticipation accrue
    ParryWindowDuration = 0.49,

    -- Fenêtres adaptatives selon vitesse et distance
    AdaptiveWindows = {
        -- Format: {minSpeed, maxSpeed, baseWindow, distanceFactor}
        { 0,    50,        0.55, 1.2 }, -- Très lent (fenêtre un peu plus courte)
        { 50,   100,       0.45, 1.0 }, -- Lent (fenêtre un peu plus courte)
        { 100,  200,       0.38, 0.86 }, -- Moyen
        { 200,  400,       0.33, 0.74 }, -- Rapide
        { 400,  800,       0.28, 0.65 }, -- Très rapide
        { 800,  1500,      0.20, 0.53 }, -- Extrême (encore plus réactif)
        { 1500, math.huge, 0.15, 0.45 }  -- Godlike (très agressif)
    },

    -- Détection de courbes
    CurveDetection = {
        Enabled = true,
        SampleRate = 0.04,  -- Échantillonnage un peu plus fréquent (de 0.05)
        MinSamples = 6,     -- Moins d'échantillons pour une détection plus rapide (de 5)
        CurveThreshold = 5, 
        MaxCurveAngle = 180, 
    },

    -- Facteurs de compensation pour les courbes
    CurveCompensation = {
        left = { timing = 0.08, window = 1.15 }, -- Courbe à gauche
        right = { timing = 0.08, window = 1.15 }, -- Courbe à droite
        up = { timing = 0.1, window = 1.2 },    -- Courbe vers le haut
        behind = { timing = 0.15, window = 1.48 }, -- Courbe derrière
        straight = { timing = 0, window = 1.0 } -- Pas de courbe
    },

    -- Facteurs de distance
    DistanceFactors = {
        close = { range = 50, factor = 0.8 }, -- Très proche
        medium = { range = 100, factor = 1.0 }, -- Distance moyenne
        far = { range = 200, factor = 1.2 },  -- Loin
        veryFar = { range = 300, factor = 1.4 } -- Très loin
    },

    -- Protection cooldown
    CooldownProtectionEnabled = true,
    EmergencyThreshold = 0.09, -- Encore réduit pour urgence plus rapide (de 0.10)
    BackupCooldown = 0.8, -- Cooldown de la capacité d'urgence réduit (de 1.0)

    -- Auto parry
    AutoParryEnabled = true,

    -- Visée
    ManualAimMode = true,
    PreserveAiming = true,
    ShowMousePosition = true,

    -- Debug
    DebugMode = true
}

--// Variables
local GameState = {
    hasParried = false,
    manualParryDetected = false,
    lastParryTime = 0,
    lastManualParryTime = 0,
    backupParryUsed = false,
    lastBackupTime = 0,
    lastDistance = math.huge,
    lastBallPosition = nil,
    gameActive = false,
    mouseLocked = false
}

-- Historique pour analyses
local History = {
    ballSpeed = {},
    ballPositions = {},
    curveData = {
        type = "straight",
        angle = 0,
        confidence = 0
    }
}

-- Connections
local Connections = {}

--// Helper Functions
local function DebugPrint(...)
    if Settings.DebugMode then
        print("[Blade Ball Adaptive]", ...)
    end
end

--// Calcul de la distance factor
local function GetDistanceFactor(distance)
    local factors = Settings.DistanceFactors

    if distance < factors.close.range then
        return factors.close.factor
    elseif distance < factors.medium.range then
        return factors.medium.factor
    elseif distance < factors.far.range then
        return factors.far.factor
    else
        return factors.veryFar.factor
    end
end

--// Obtenir la fenêtre adaptative selon vitesse
local function GetAdaptiveWindow(speed)
    for _, window in ipairs(Settings.AdaptiveWindows) do
        if speed >= window[1] and speed < window[2] then
            return window[3], window[4]
        end
    end
    return 0.35, 1.0 -- Valeurs par défaut
end

--// Détection de courbe améliorée
local function DetectCurve()
    local positions = History.ballPositions
    if #positions < Settings.CurveDetection.MinSamples then
        return "straight", 0, 0
    end

    -- Prendre les derniers échantillons
    local samples = {}
    for i = math.max(1, #positions - Settings.CurveDetection.MinSamples + 1), #positions do
        table.insert(samples, positions[i])
    end

    -- Calculer la trajectoire
    local vectors = {}
    for i = 2, #samples do
        local dir = (samples[i].position - samples[i - 1].position).Unit
        table.insert(vectors, dir)
    end

    if #vectors < 2 then
        return "straight", 0, 0
    end

    -- Analyser les changements de direction
    local totalAngle = 0
    local horizontalAngle = 0
    local verticalAngle = 0

    for i = 2, #vectors do
        local angle = math.deg(math.acos(math.clamp(vectors[i]:Dot(vectors[i - 1]), -1, 1)))
        totalAngle = totalAngle + angle

        -- Décomposer en horizontal et vertical
        local horizontal = Vector3.new(vectors[i].X, 0, vectors[i].Z).Unit
        local prevHorizontal = Vector3.new(vectors[i - 1].X, 0, vectors[i - 1].Z).Unit
        horizontalAngle = horizontalAngle + math.deg(math.acos(math.clamp(horizontal:Dot(prevHorizontal), -1, 1)))

        verticalAngle = verticalAngle + math.abs(vectors[i].Y - vectors[i - 1].Y) * 90
    end

    -- Déterminer le type de courbe
    local avgAngle = totalAngle / (#vectors - 1)
    local confidence = math.min(avgAngle / Settings.CurveDetection.MaxCurveAngle, 1)

    if avgAngle < Settings.CurveDetection.CurveThreshold then
        return "straight", avgAngle, confidence
    end

    -- Analyser la direction de la courbe
    local lastVector = vectors[#vectors]
    local firstVector = vectors[1]
    local cross = firstVector:Cross(lastVector)

    if verticalAngle > horizontalAngle * 1.5 then
        if lastVector.Y > firstVector.Y then
            return "up", avgAngle, confidence
        else
            return "behind", avgAngle, confidence
        end
    else
        if cross.Y > 0 then
            return "right", avgAngle, confidence
        else
            return "left", avgAngle, confidence
        end
    end
end

--// Calculer la fenêtre de parry adaptative
local function CalculateAdaptiveParryWindow(speed, distance, curveType)
    -- Obtenir la fenêtre de base selon la vitesse
    local baseWindow, distanceFactor = GetAdaptiveWindow(speed)

    -- Appliquer le facteur de distance
    local distanceMultiplier = GetDistanceFactor(distance) * distanceFactor

    -- Appliquer la compensation de courbe
    local curveCompensation = Settings.CurveCompensation[curveType] or Settings.CurveCompensation.straight

    -- Calculer le timing optimal
    local optimalTiming = Settings.BaseParryETAThreshold * distanceMultiplier
    optimalTiming = optimalTiming + curveCompensation.timing

    -- Calculer la durée de la fenêtre
    local windowDuration = baseWindow * curveCompensation.window

    -- Ajuster selon la vitesse extrême
    if speed > 1000 then
        windowDuration = windowDuration * 0.9
        optimalTiming = optimalTiming * 0.95
    elseif speed > 1500 then
        windowDuration = windowDuration * 0.8
        optimalTiming = optimalTiming * 0.9
    end

    -- Calculer les bornes de la fenêtre
    local windowStart = optimalTiming + (windowDuration / 2)
    local windowEnd = optimalTiming - (windowDuration / 2)

    -- S'assurer que la fenêtre est valide
    windowEnd = math.max(windowEnd, 0.05)

    -- Calculer l'ETA
    local eta = distance / math.max(speed, 1.1)

    return {
        optimal = optimalTiming,
        windowStart = windowStart,
        windowEnd = windowEnd,
        windowDuration = windowDuration,
        eta = eta,
        inWindow = eta <= windowStart and eta >= windowEnd,
        speed = speed,
        distance = distance,
        curveType = curveType,
        curveCompensation = curveCompensation
    }
end

--// Get Ball
function GetBall()
    local ballsFolder = Workspace:FindFirstChild("Balls")
    if not ballsFolder then return nil end

    for _, Ball in ipairs(ballsFolder:GetChildren()) do
        if Ball:GetAttribute("realBall") and Ball:IsA("BasePart") then
            return Ball
        end
    end
    return nil
end

--// Check if game is active
local function IsGameActive()
    local Ball = GetBall()
    if not Ball then return false end

    local Target = Ball:GetAttribute("target")
    return Target ~= nil and Target ~= ""
end

--// Can Parry check
local function CanParry()
    local character = Player.Character
    if not character then return false end

    local humanoid = character:FindFirstChild("Humanoid")
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")

    if not humanoid or not humanoidRootPart then return false end
    if humanoid.Health <= 0 then return false end
    if humanoid.PlatformStand or humanoid.Sit then return false end

    return true
end

--// Update ball position history
local function UpdateBallHistory(ball, speed)
    -- Ajouter à l'historique de vitesse
    table.insert(History.ballSpeed, speed)
    if #History.ballSpeed > 10 then
        table.remove(History.ballSpeed, 1)
    end

    -- Ajouter à l'historique de position
    table.insert(History.ballPositions, {
        position = ball.Position,
        time = tick()
    })

    -- Limiter la taille de l'historique
    local maxAge = Settings.CurveDetection.SampleRate * Settings.CurveDetection.MinSamples * 2
    local currentTime = tick()

    History.ballPositions = FilterTable(History.ballPositions, function(entry)
        return currentTime - entry.time < maxAge
    end)
end

--// Get average speed
local function GetAverageSpeed()
    if #History.ballSpeed == 0 then return 10 end -- Modifié de 75 à 10

    local sum = 0
    for _, speed in ipairs(History.ballSpeed) do
        sum = sum + speed
    end
    return sum / #History.ballSpeed
end

--// Execute parry with aim preservation
local function ExecuteParry()
    if not Settings.AutoParryEnabled then return end
    if not IsGameActive() then return end

    local currentTime = tick()
    local Mouse = Player:GetMouse()
    local mouseX = Mouse.X
    local mouseY = Mouse.Y

    -- Click à la position actuelle de la souris
    game:GetService("VirtualInputManager"):SendKeyEvent(true, Enum.KeyCode.F, false, game)
    task.wait(0.01)
    game:GetService("VirtualInputManager"):SendKeyEvent(false, Enum.KeyCode.F, false, game)

    GameState.hasParried = true
    GameState.lastParryTime = currentTime

    DebugPrint(string.format("AUTO PARRY - Position: %d,%d | Curve: %s",
        mouseX, mouseY, History.curveData.type))
end

--// Emergency ability
local function UseEmergencyAbility()
    if not IsGameActive() then return end

    local currentTime = tick()
    if (currentTime - GameState.lastBackupTime) < Settings.BackupCooldown then
        return
    end

    local Mouse = Player:GetMouse()
    local mouseX = Mouse.X
    local mouseY = Mouse.Y

    -- Right click pour Rapture
    VirtualInputManager:SendMouseButtonEvent(mouseX, mouseY, 1, true, game, 0)
    task.wait(0.01)
    VirtualInputManager:SendMouseButtonEvent(mouseX, mouseY, 1, false, game, 0)

    -- Q key backup
    task.wait(0.01)
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game)
    task.wait(0.01)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)

    GameState.backupParryUsed = true
    GameState.lastBackupTime = currentTime

    DebugPrint("🚨 EMERGENCY ABILITY USED 🚨")
end

--// Reset states
local function ResetStates()
    GameState.hasParried = false
    GameState.manualParryDetected = false
    GameState.backupParryUsed = false
    GameState.lastDistance = math.huge
    GameState.lastBallPosition = nil
    History.ballPositions = {}
    History.curveData = { type = "straight", angle = 0, confidence = 0 }
end

--// Main loop
local function MainLoop()
    local Ball = GetBall()
    local Character = Player.Character
    local HRP = Character and Character:FindFirstChild("HumanoidRootPart")

    local currentGameActive = IsGameActive()

    if not currentGameActive then
        if GameState.gameActive then
            ResetStates()
            GameState.gameActive = false
            DebugPrint("Game ended, states reset")
        end
        return
    end

    GameState.gameActive = true

    if not Ball or not HRP or not CanParry() then return end

    -- Get ball data
    local Zoomies = Ball:FindFirstChild("zoomies")
    local VelocityObj = Zoomies and Zoomies:FindFirstChild("VectorVelocity")
    local Velocity = VelocityObj and VelocityObj.VectorVelocity or Ball.AssemblyLinearVelocity
    local Speed = Velocity.Magnitude

    if Speed < 10 then
        Speed = GetAverageSpeed()
    end

    -- Update history
    UpdateBallHistory(Ball, Speed)

    -- Detect curve
    local curveType, curveAngle, curveConfidence = DetectCurve()
    History.curveData = {
        type = curveType,
        angle = curveAngle,
        confidence = curveConfidence
    }

    -- Calculate distance
    local Distance = (HRP.Position - Ball.Position).Magnitude
    local Target = Ball:GetAttribute("target")

    -- Check if we're the target
    if Target == Player.Name then
        local parryData = CalculateAdaptiveParryWindow(Speed, Distance, curveType)

        -- Si la balle s'éloigne APRES un parry réussi, ou si l'ETA redevient grand,
        -- on peut considérer que le parry est terminé et se préparer au suivant.
        if GameState.hasParried and (Distance > GameState.lastDistance + 5 or parryData.eta > 0.5) then
            DebugPrint("Réinitialisation de hasParried car la balle s'éloigne après parry ou ETA élevé.")
            GameState.hasParried = false
            GameState.backupParryUsed = false -- On pourrait aussi reset le backup ici si besoin
        end

        -- Auto parry logic
        if Settings.AutoParryEnabled and parryData.inWindow and not GameState.hasParried then
            local ballDirection = (HRP.Position - Ball.Position).Unit
            local ballVelocityDirection = Velocity.Unit
            local dotProduct = ballDirection:Dot(ballVelocityDirection)

            if dotProduct > 0.5 and Speed > 5 and Distance < 300 then 
                ExecuteParry()
                GameState.lastDistance = Distance -- Enregistrer la distance au moment du parry
                DebugPrint(string.format("✅ ADAPTIVE PARRY - ETA: %.3f | Window: %.3f-%.3f | Curve: %s",
                    parryData.eta, parryData.windowStart, parryData.windowEnd, curveType))
            end
        end

        -- Emergency protection
        if Settings.CooldownProtectionEnabled and parryData.eta <= Settings.EmergencyThreshold then
            if not GameState.hasParried and not GameState.backupParryUsed then
                UseEmergencyAbility()
            end
        end

        -- Reset when ball is far OR if we are no longer the target immediately
        -- La condition Target ~= Player.Name est gérée plus bas
        if parryData.eta > 1.0 then -- Réduit de 1.5 pour une réinitialisation plus rapide
            GameState.hasParried = false
            GameState.backupParryUsed = false
        end

        -- GameState.lastDistance = Distance -- Déplacé dans ExecuteParry pour être plus précis
    else
        -- Si nous ne sommes plus la cible, réinitialiser immédiatement
        if GameState.hasParried or GameState.backupParryUsed then
            DebugPrint("Réinitialisation car plus la cible.")
            GameState.hasParried = false
            GameState.backupParryUsed = false
        end
        GameState.lastDistance = math.huge -- Réinitialiser lastDistance si pas cible
    end
end

--// Setup connections
Connections.MainLoop = RunService.PreSimulation:Connect(MainLoop)

--// GUI Debug
local ScreenGui = nil
if Settings.DebugMode then
    local existingGui = Player.PlayerGui:FindFirstChild("BladeBallAdaptive")
    if existingGui then existingGui:Destroy() end

    ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Parent = Player.PlayerGui
    ScreenGui.Name = "BladeBallAdaptive"
    ScreenGui.ResetOnSpawn = false

    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(0, 420, 0, 280)
    Frame.Position = UDim2.new(0, 10, 0, 10)
    Frame.BackgroundColor3 = Color3.new(0, 0, 0)
    Frame.BackgroundTransparency = 0.3
    Frame.Parent = ScreenGui

    local TitleLabel = Instance.new("TextLabel")
    TitleLabel.Size = UDim2.new(1, 0, 0, 25)
    TitleLabel.Position = UDim2.new(0, 0, 0, 0)
    TitleLabel.BackgroundColor3 = Color3.new(0.2, 0.2, 0.2)
    TitleLabel.TextColor3 = Color3.new(1, 1, 0)
    TitleLabel.TextScaled = true
    TitleLabel.Font = Enum.Font.SourceSansBold
    TitleLabel.Text = "🗡️ BLADE BALL ADAPTIVE SYSTEM 🗡️"
    TitleLabel.Parent = Frame

    local InfoLabel = Instance.new("TextLabel")
    InfoLabel.Size = UDim2.new(1, -10, 1, -30)
    InfoLabel.Position = UDim2.new(0, 5, 0, 30)
    InfoLabel.BackgroundTransparency = 1
    InfoLabel.TextColor3 = Color3.new(1, 1, 1)
    InfoLabel.TextSize = 11
    InfoLabel.Font = Enum.Font.Code
    InfoLabel.TextXAlignment = Enum.TextXAlignment.Left
    InfoLabel.TextYAlignment = Enum.TextYAlignment.Top
    InfoLabel.Parent = Frame

    Connections.DebugUpdate = RunService.RenderStepped:Connect(function()
        if not ScreenGui or not ScreenGui.Parent then return end

        local Ball = GetBall()
        local HRP = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")

        if Ball and HRP and GameState.gameActive then
            local Distance = (HRP.Position - Ball.Position).Magnitude
            local Zoomies = Ball:FindFirstChild("zoomies")
            local VelocityObj = Zoomies and Zoomies:FindFirstChild("VectorVelocity")
            local Speed = VelocityObj and VelocityObj.VectorVelocity.Magnitude or GetAverageSpeed()
            local Target = Ball:GetAttribute("target")

            local curveData = History.curveData
            local parryData = CalculateAdaptiveParryWindow(Speed, Distance, curveData.type)

            local Mouse = Player:GetMouse()

            InfoLabel.Text = string.format(
                "🎮 État: ACTIF | Cible: %s\n" ..
                "⚡ Vitesse: %.1f | Distance: %.1f | ETA: %.3f\n" ..
                "📊 Fenêtre adaptative: %.3f - %.3f (durée: %.3f)\n" ..
                "🌀 Courbe détectée: %s (angle: %.1f° | confiance: %.0f%%)\n" ..
                "🔧 Compensation courbe: +%.3fs timing | x%.2f fenêtre\n" ..
                "📏 Facteur distance: x%.2f\n" ..
                "🎯 Dans la fenêtre: %s | Parry effectué: %s\n" ..
                "🖱️ Position souris: %d, %d\n" ..
                "⏱️ Cooldown backup: %.1fs\n" ..
                "📈 Vitesse moyenne: %.1f\n\n" ..
                "💡 Système adaptatif activé ✅",
                tostring(Target),
                Speed, Distance, parryData.eta,
                parryData.windowStart, parryData.windowEnd, parryData.windowDuration,
                curveData.type:upper(), curveData.angle, curveData.confidence * 100,
                parryData.curveCompensation.timing, parryData.curveCompensation.window,
                GetDistanceFactor(Distance),
                tostring(parryData.inWindow), tostring(GameState.hasParried),
                Mouse.X, Mouse.Y,
                math.max(0, Settings.BackupCooldown - (tick() - GameState.lastBackupTime)),
                GetAverageSpeed()
            )
        else
            InfoLabel.Text = string.format(
                "🎮 État: EN ATTENTE\n\n" ..
                "📊 FENÊTRES ADAPTATIVES:\n" ..
                "🟢 0-50: 0.6s | 🟡 50-100: 0.5s\n" ..
                "🟠 100-200: 0.4s | 🔴 200-400: 0.35s\n" ..
                "🟣 400-800: 0.3s | ⚫ 800-1500: 0.25s\n" ..
                "⚡ 1500+: 0.2s\n\n" ..
                "🌀 DÉTECTION DE COURBES:\n" ..
                "• Gauche/Droite: +0.08s\n" ..
                "• Haut: +0.1s | Derrière: +0.15s\n\n" ..
                "💡 Système adaptatif prêt..."
            )
        end
    end)
end

--// Chat commands
Player.Chatted:Connect(function(message)
    local msg = message:lower()

    if msg == "/e stop" then
        for _, connection in pairs(Connections) do
            if connection then connection:Disconnect() end
        end
        ResetStates()
        if ScreenGui then ScreenGui:Destroy() end
        print("[Blade Ball Adaptive] Script arrêté!")
    elseif msg == "/e toggle" then
        Settings.AutoParryEnabled = not Settings.AutoParryEnabled
        print("[Blade Ball Adaptive] Auto Parry:", Settings.AutoParryEnabled)
    elseif msg == "/e curve" then
        Settings.CurveDetection.Enabled = not Settings.CurveDetection.Enabled
        print("[Blade Ball Adaptive] Détection de courbes:", Settings.CurveDetection.Enabled)
    end
end)

-- Message de bienvenue
print("╔════════════════════════════════════════╗")
print("║  🗡️ BLADE BALL SYSTÈME ADAPTATIF 🗡️   ║")
print("╠════════════════════════════════════════╣")
print("║ ✅ Fenêtre de parry adaptative         ║")
print("║ ✅ Détection de courbes en temps réel  ║")
print("║ ✅ Compensation distance/vitesse        ║")
print("║ ✅ Protection cooldown intégrée         ║")
print("╠════════════════════════════════════════╣")
print("║ Commandes:                             ║")
print("║ /e stop - Arrêter le script            ║")
print("║ /e toggle - On/Off Auto Parry          ║")
print("║ /e curve - On/Off Détection courbes    ║")
print("╚════════════════════════════════════════╝")

-- FOV
game.Workspace.CurrentCamera.FieldOfView = 110
