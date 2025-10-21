local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = game:GetService("Workspace")

local GRID_SIZE = 6
local JUMP_HEIGHT = 150
local CHECK_INTERVAL = 0.1
local OBSTACLE_CHECK_DISTANCE = 5
local MOVETO_TIMEOUT = 5
local TOKEN_CLEAR_INTERVAL = 5

local toggles = {
    field = "Ant Field",
    dig = false,
    autoFarm = false,
    autoSprinklers = false,
    hasWalked = false,
    converting = false,
    hasWalkedToHive = false,
    visitedTokens = {},
    convertPercentage = 95,
    walkspeedEnabled = false,
    walkspeed = 50,
    avoidMobs = false,
    sprinklersPlaced = false,
    placingSprinklers = false,
    lastTokenClearTime = tick(),
    lastTokenCheckTime = tick()
}

local player = Players.LocalPlayer
local events = ReplicatedStorage:WaitForChild("Events", 10)
local flowerZones = workspace:WaitForChild("FlowerZones")
local collectibles = workspace:WaitForChild("Collectibles")
local honeycombs = workspace:WaitForChild("Honeycombs")
local fieldsTable = {}

for _, field in ipairs(flowerZones:GetChildren()) do
    field.Size += Vector3.new(0, 60, 0)
    table.insert(fieldsTable, field.Name)
end
table.sort(fieldsTable, function(a, b) return a:lower() < b:lower() end)

local function modifier(position, size, var)
    local part = Instance.new("Part")
    part.Size = size
    part.Position = position
    part.Anchored = true
    part.CanCollide = false
    part.Transparency = 1
    part.CastShadow = false
    part.Parent = Workspace

    local modifier = Instance.new("PathfindingModifier")
    modifier.PassThrough = var
    modifier.Label = "WalkThrough"
    modifier.Parent = part

    return part
end

local function modifierFences(cframe, size)
    local part = Instance.new("Part")
    part.Size = size
    part.CFrame = cframe
    part.Anchored = true
    part.CanCollide = false
    part.Transparency = 1
    part.Color = Color3.new(1,0,0)
    part.Parent = Workspace
    local modifier = Instance.new("PathfindingModifier")
    modifier.PassThrough = false
    modifier.Label = "DontWalkThrough"
    modifier.Parent = part
    return part
end

for _, part in next, workspace:FindFirstChild("FieldDecos"):GetDescendants() do if part:IsA("BasePart") then part.CanCollide = false part.Transparency = part.Transparency < 0.5 and 0.5 or part.Transparency task.wait() end end
for _, part in next, workspace:FindFirstChild("Decorations"):GetDescendants() do if part:IsA("BasePart") and (part.Parent.Name == "Bush" or part.Parent.Name == "Blue Flower") then part.CanCollide = false part.Transparency = part.Transparency < 0.5 and 0.5 or part.Transparency task.wait() end end
for i,v in next, workspace.Decorations.Misc:GetDescendants() do if v.Parent.Name == "Mushroom" then v.CanCollide = false v.Transparency = 0.5 end end

local flowers = Workspace:WaitForChild("Flowers")
for _, flower in ipairs(flowers:GetDescendants()) do
    if flower:IsA("BasePart") then
        modifier(flower.Position, (flower.Size + Vector3.new(3,3,3)), true)
    end
end

for _, zone in ipairs(flowerZones:GetDescendants()) do
    if zone:IsA("BasePart") then
        modifier(zone.Position, (zone.Size + Vector3.new(20, 20, 20)), true)
    end
end

workspace.Map.Fences:Destroy()

local function formatNumber(num)
    local suffixes = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qad", "Qid"}
    local i = 1
    while num >= 1000 and i < #suffixes do
        num = num / 1000
        i = i + 1
    end
    return i == 1 and tostring(num) or string.format("%.1f%s", num, suffixes[i])
end

local function formatTime(seconds)
    local days = math.floor(seconds / (24 * 3600))
    seconds = seconds % (24 * 3600)
    local hours = math.floor(seconds / 3600)
    seconds = seconds % 3600
    local minutes = math.floor(seconds / 60)
    seconds = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d:%02d", days, hours, minutes, seconds)
end

local function grabStats()
    return events.RetrievePlayerStats:InvokeServer() or {}
end

local function isPathBlocked(humanoidRootPart, nextWaypoint)
    if not humanoidRootPart or not nextWaypoint then return false end
    local rayOrigin = humanoidRootPart.Position
    local rayDirection = (nextWaypoint.Position - rayOrigin).Unit * OBSTACLE_CHECK_DISTANCE
    local raycastParams = RaycastParams.new()
    raycastParams.FilterDescendantsInstances = {humanoidRootPart.Parent}
    raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
    raycastParams.IgnoreWater = true

    local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
    return raycastResult and raycastResult.Instance.Transparency < 0.5
end

local function moveAlongPath(humanoid, waypoints, targetPos)
    if not humanoid or not humanoid.Parent then return false end
    local character = humanoid.Parent
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
    if not humanoidRootPart then return false end

    for _, waypoint in ipairs(waypoints) do
        local pos = waypoint.Position
        if waypoint.Action == Enum.PathWaypointAction.Jump then
            local state = humanoid:GetState()
            if state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.RunningNoPhysics or state == Enum.HumanoidStateType.Landed then
                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            end
            pos += Vector3.new(0, JUMP_HEIGHT, 0)
        end
        humanoid:MoveTo(pos)
        local moveFinished = humanoid.MoveToFinished:Wait(MOVETO_TIMEOUT)
        if not moveFinished and isPathBlocked(humanoidRootPart, waypoint) then
            return false
        end
    end
    return true
end

local function computePath(targetPos)
    local character = player.Character
    if not character or not character:FindFirstChild("HumanoidRootPart") or not character:FindFirstChild("Humanoid") then
        return false
    end
    local humanoid = character:FindFirstChild("Humanoid")
    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = true,
        AgentCanClimb = true,
        AgentJumpHeight = 70,
        Costs = {
            Jump = 1,
            Climbable = 2,
            WalkThrough = 1,
        },
        WaypointSpacing = GRID_SIZE,
        MaxSlope = math.rad(90)
    })
    local success, errorMessage = pcall(function()
        path:ComputeAsync(humanoidRootPart.Position, targetPos)
    end)
    if not success or path.Status ~= Enum.PathStatus.Success or #path:GetWaypoints() <= 1 then
        task.wait(CHECK_INTERVAL)
        return false
    end
    return moveAlongPath(humanoid, path:GetWaypoints(), targetPos)
end

local function moveToPosition(targetPos, duration)
    local character = player.Character
    local humanoid = character and character:FindFirstChild("Humanoid")
    local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not humanoidRootPart then return false end

    local startPos = humanoidRootPart.Position
    local startTime = tick()
    local alpha = 0

    while alpha < 1 and humanoid.Parent and humanoidRootPart.Parent do
        local elapsed = tick() - startTime
        alpha = math.clamp(elapsed / duration, 0, 1)
        humanoidRootPart.CFrame = CFrame.new(startPos:Lerp(targetPos, alpha))
        if (targetPos.Y - humanoidRootPart.Position.Y) > 2 then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
        RunService.Heartbeat:Wait()
    end

    if humanoid.Parent and humanoidRootPart.Parent then
        humanoidRootPart.CFrame = CFrame.new(targetPos)
        return true
    end
    return false
end

local function hasHiveClaimed()
    for i = 6, 1, -1 do
        local hive = honeycombs:FindFirstChild("Hive" .. i)
        if hive and hive:FindFirstChild("Owner") and hive.Owner.Value == player then
            return true
        end
    end
    return false
end

local function claimHive()
    if hasHiveClaimed() then return true end
    for i = 6, 1, -1 do
        local hive = honeycombs:FindFirstChild("Hive" .. i)
        if hive and hive:FindFirstChild("Owner") and not hive.Owner.Value then
            local targetPos = (hive.SpawnPos.Value * CFrame.fromEulerAnglesXYZ(0, math.rad(110), 0) + Vector3.new(0, 3, 9)).Position
            local controlScript = player:WaitForChild("PlayerScripts"):WaitForChild("ControlScript")
            controlScript.Enabled = false
            if computePath(targetPos) then
                events.ClaimHive:FireServer(hive.HiveID.Value)
            end
            controlScript.Enabled = true
            return true
        end
    end
    return false
end

local function dig()
    if not toggles.dig or not hasHiveClaimed() then return end
    local toolCollectEvent = events:FindFirstChild("ToolCollect")
    local character = player.Character
    local humanoid = character and character:FindFirstChild("Humanoid")
    if not toolCollectEvent or not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
    for _, animTrack in pairs(animator:GetPlayingAnimationTracks()) do
        if animTrack.Animation.AnimationId == "rbxassetid://522635514" then
            return
        end
    end

    toolCollectEvent:FireServer()
    local animation = Instance.new("Animation")
    animation.AnimationId = "rbxassetid://522635514"
    local animationTrack = animator:LoadAnimation(animation)
    animationTrack:Play()
    animationTrack.Stopped:Connect(function() animation:Destroy() end)
end

local function isPlayerInField(field)
    local humanoidRootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not humanoidRootPart or not field then return false end
    local region = Region3.new(field.Position - field.Size / 2, field.Position + field.Size / 2)
    for _, part in ipairs(workspace:FindPartsInRegion3(region, nil, 1000)) do
        if part:IsDescendantOf(player.Character) then return true end
    end
    return false
end

local function convertHoney()
    if not hasHiveClaimed() or toggles.converting or toggles.hasWalkedToHive then return end
    local coreStats = player:FindFirstChild("CoreStats")
    if not coreStats or coreStats.Pollen.Value < (toggles.convertPercentage / 100) * coreStats.Capacity.Value then return end

    toggles.converting = true
    toggles.hasWalked = false
    toggles.hasWalkedToHive = true
    toggles.sprinklersPlaced = false
    toggles.placingSprinklers = false

    local humanoidRootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not humanoidRootPart then
        toggles.converting = false
        toggles.hasWalkedToHive = false
        return
    end

    local spawnPos = (player.SpawnPos.Value * CFrame.fromEulerAnglesXYZ(0, math.rad(110), 0) + Vector3.new(0, 3, 9)).Position
    if not moveToPosition(spawnPos, 3) then
        toggles.converting = false
        toggles.hasWalkedToHive = false
        return
    end

    local activateButton = player.PlayerGui.ScreenGui.ActivateButton
    local maxAttempts = 10
    local attemptCount = 0
    while activateButton.TextBox.Text ~= "Stop Making Honey" and activateButton.BackgroundColor3 ~= Color3.fromRGB(201, 39, 28) and attemptCount < maxAttempts do
        if (player.SpawnPos.Value.Position - humanoidRootPart.Position).Magnitude <= 13 then
            events.PlayerHiveCommand:FireServer("ToggleHoneyMaking")
            task.wait(0.5)
            attemptCount += 1
        else
            moveToPosition(spawnPos, 3)
        end
    end

    local startTime = tick()
    while coreStats.Pollen.Value > 0 and tick() - startTime < 30 do
        task.wait(0.1)
    end
    if coreStats.Pollen.Value == 0 then task.wait(5)  end

    toggles.converting = false
    toggles.hasWalkedToHive = false

    if toggles.autoFarm then
        local targetField = flowerZones:FindFirstChild(toggles.field)
        if targetField then
            moveToPosition(targetField.Position + Vector3.new(0, 3, 0), 3)
            toggles.hasWalked = true
        end
    end
end

local function farm()
    if not hasHiveClaimed() or not toggles.autoFarm or toggles.converting then return end
    local targetField = flowerZones:FindFirstChild(toggles.field)
    if not targetField then return end

    if not isPlayerInField(targetField) and not toggles.hasWalked and not toggles.hasWalkedToHive then
        moveToPosition(targetField.Position + Vector3.new(0, 3, 0), 3)
        toggles.hasWalked = true
        toggles.sprinklersPlaced = false
        toggles.placingSprinklers = false
    elseif isPlayerInField(targetField) then
        toggles.hasWalked = false
    end

    convertHoney()
end

local function collectTokens()
    if not hasHiveClaimed() or not toggles.autoFarm or toggles.converting or toggles.placingSprinklers then return end
    if tick() - toggles.lastTokenCheckTime < 0.1 then return end
    toggles.lastTokenCheckTime = tick()

    local character = player.Character
    local humanoid = character and character:FindFirstChild("Humanoid")
    local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not humanoidRootPart or not collectibles then return end

    local targetField = flowerZones:FindFirstChild(toggles.field)
    if not targetField then return end
    local region = Region3.new(targetField.Position - targetField.Size / 2, targetField.Position + targetField.Size / 2)

    local closestToken, closestDistance = nil, math.huge
    local maxDistance = 50
    for _, token in ipairs(collectibles:GetChildren()) do
        if token:IsA("BasePart") and not toggles.visitedTokens[token] then
            local tokenPos = token.Position
            local distance = (humanoidRootPart.Position - tokenPos).Magnitude
            if distance < maxDistance and
               tokenPos.X >= region.CFrame.X - region.Size.X / 2 and
               tokenPos.X <= region.CFrame.X + region.Size.X / 2 and
               tokenPos.Y >= region.CFrame.Y - region.Size.Y / 2 and
               tokenPos.Y <= region.CFrame.Y + region.Size.Y / 2 and
               tokenPos.Z >= region.CFrame.Z - region.Size.Z / 2 and
               tokenPos.Z <= region.CFrame.Z + region.Size.Z / 2 then
                if distance < closestDistance then
                    closestDistance = distance
                    closestToken = token
                end
            end
        end
    end

    if closestToken then
        humanoid:MoveTo(closestToken.Position)
        local startTime = tick()
        while (humanoidRootPart.Position - closestToken.Position).Magnitude > 4 and tick() - startTime < 5 do
            if not closestToken.Parent then
                toggles.visitedTokens[closestToken] = nil
                break
            end
            RunService.Heartbeat:Wait()
        end
        if closestToken.Parent and (humanoidRootPart.Position - closestToken.Position).Magnitude <= 4 then
            toggles.visitedTokens[closestToken] = true
        end
    end
end

local function placeSprinklers()
    if not hasHiveClaimed() or not toggles.autoFarm or not toggles.autoSprinklers or toggles.converting or toggles.placingSprinklers or toggles.sprinklersPlaced then return end
    local character = player.Character
    local humanoid = character and character:FindFirstChild("Humanoid")
    local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not humanoidRootPart then return end

    local targetField = flowerZones:FindFirstChild(toggles.field)
    if not targetField or not isPlayerInField(targetField) then return end

    toggles.placingSprinklers = true
    local sprinkler = grabStats().EquippedSprinkler
    local moves = ({["Silver Soakers"] = 2, ["Golden Gushers"] = 3, ["Diamond Drenchers"] = 4})[sprinkler] or 1
    local positions = {
        targetField.Position + Vector3.new(0, 3, 0),
        targetField.Position + Vector3.new(-10, 3, 0),
        targetField.Position + Vector3.new(10, 3, 0),
        targetField.Position + Vector3.new(0, 3, 10)
    }

    local allSprinklersPlaced = true

    for i = 1, math.min(moves, #positions) do
        local targetPos = positions[i]
        while humanoid:GetState() ~= Enum.HumanoidStateType.Running and humanoid:GetState() ~= Enum.HumanoidStateType.Landed do
            RunService.Heartbeat:Wait()
        end
        humanoid:MoveTo(targetPos)
        local startTime = tick()
        while (humanoidRootPart.Position - targetPos).Magnitude > 4 and tick() - startTime < 5 do
            if not isPlayerInField(targetField) then
                toggles.placingSprinklers = false
                return
            end
            RunService.Heartbeat:Wait()
        end
        if (humanoidRootPart.Position - targetPos).Magnitude <= 4 then
            local originalJumpPower = humanoid.JumpPower
            humanoid.JumpPower = 70
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            repeat RunService.Heartbeat:Wait() until humanoid:GetState() == Enum.HumanoidStateType.Freefall
            repeat RunService.Heartbeat:Wait() until humanoid:GetState() == Enum.HumanoidStateType.Landed or humanoid:GetState() == Enum.HumanoidStateType.Running
            humanoid.JumpPower = originalJumpPower
            events.PlayerActivesCommand:FireServer({["Name"] = "Sprinkler Builder"})
            task.wait(0.5)
        else
            allSprinklersPlaced = false
        end
    end
    toggles.sprinklersPlaced = allSprinklersPlaced
    toggles.placingSprinklers = false
end

local function avoidMobs()
    if not toggles.avoidMobs or not hasHiveClaimed() then return end
    for _, mob in ipairs(workspace.Monsters:GetChildren()) do
        if mob:FindFirstChild("Head") and (mob.Head.Position - player.Character.HumanoidRootPart.Position).Magnitude < 30 and player.Character.Humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
            player.Character.Humanoid.Jump = true
        end
    end
end

local function updateWalkspeed()
    if not hasHiveClaimed() or not toggles.walkspeedEnabled then return end
    local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
    if humanoid then humanoid.WalkSpeed = toggles.walkspeed end
end

local function clearVisitedTokens()
    if tick() - toggles.lastTokenClearTime >= TOKEN_CLEAR_INTERVAL then
        toggles.visitedTokens = {}
        toggles.lastTokenClearTime = tick()
    end
end

local function resetOnDeath()
    toggles.hasWalked = false
    toggles.hasWalkedToHive = false
    toggles.converting = false
    toggles.sprinklersPlaced = false
    toggles.placingSprinklers = false
    toggles.visitedTokens = {}
end

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"))()
local ThemeManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/addons/SaveManager.lua"))()

local Window = Library:CreateWindow({
    Title = "Faygoware",
    Footer = "v1.0.0",
    ToggleKeybind = Enum.KeyCode.RightControl,
    Center = true,
    AutoShow = true,
    ShowCustomCursor = false,
    Size = UDim2.fromOffset(720, 300),
    Resizable = false
})

local HomeTab = Window:AddTab("Home", "house")
local HomeLeftGroupbox = HomeTab:AddLeftGroupbox("Stats")
local WrappedLabel = HomeLeftGroupbox:AddLabel({ Text = "", DoesWrap = true })

local MainTab = Window:AddTab("Farming", "shovel")
local FarmingGroupbox = MainTab:AddLeftGroupbox("Farming")
FarmingGroupbox:AddDropdown("FieldDropdown", {
    Values = fieldsTable,
    Default = 1,
    Multi = false,
    Text = "Fields",
    Tooltip = "Select a field.",
    Callback = function(Value)
        toggles.field = Value
        toggles.hasWalked = false
        toggles.hasWalkedToHive = false
        toggles.sprinklersPlaced = false
        toggles.placingSprinklers = false
    end
})
FarmingGroupbox:AddToggle("AutoFarmToggle", {
    Text = "Initiate Farm",
    Default = false,
    Tooltip = "Automatically farms.",
    Callback = function(Value)
        toggles.autoFarm = Value
        toggles.hasWalked = false
        toggles.hasWalkedToHive = false
        toggles.sprinklersPlaced = false
        toggles.placingSprinklers = false
    end
})
FarmingGroupbox:AddToggle("AutoToolToggle", {
    Text = "Auto Tool",
    Default = false,
    Tooltip = "Auto collects pollen.",
    Callback = function(Value) toggles.dig = Value end
})
FarmingGroupbox:AddToggle("AutoSprinklersToggle", {
    Text = "Auto Sprinklers",
    Default = false,
    Tooltip = "Places sprinklers in a pattern when entering field.",
    Callback = function(Value)
        toggles.autoSprinklers = Value
        toggles.sprinklersPlaced = false
        toggles.placingSprinklers = false
    end
})
FarmingGroupbox:AddToggle("AvoidMobsToggle", {
    Text = "Avoid Mobs",
    Default = false,
    Tooltip = "Avoids nearby mobs by jumping.",
    Callback = function(Value) toggles.avoidMobs = Value end
})

local SettingsGroupbox = MainTab:AddRightGroupbox("Settings")
SettingsGroupbox:AddSlider("ConvertSlider", {
    Text = "Convert at",
    Default = 95,
    Min = 1,
    Max = 100,
    Suffix = "%",
    Rounding = 1,
    Compact = false,
    Tooltip = "Set the pollen percentage to convert at hive.",
    Callback = function(Value) toggles.convertPercentage = Value end
})
SettingsGroupbox:AddToggle("WalkspeedToggle", {
    Text = "Enable Walkspeed",
    Default = false,
    Tooltip = "Enable custom walkspeed adjustment.",
    Callback = function(Value)
        toggles.walkspeedEnabled = Value
        if not Value and player.Character then
            local humanoid = player.Character:FindFirstChild("Humanoid")
            if humanoid then humanoid.WalkSpeed = 16 end
        end
    end
})
SettingsGroupbox:AddSlider("WalkspeedSlider", {
    Text = "Walkspeed",
    Default = 50,
    Min = 40,
    Max = 100,
    Rounding = 1,
    Compact = false,
    Tooltip = "Adjust player walkspeed.",
    Callback = function(Value) toggles.walkspeed = Value end
})

local UISettingsTab = Window:AddTab("UI Settings", "settings")
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
SaveManager:BuildConfigSection(UISettingsTab)
ThemeManager:ApplyToTab(UISettingsTab)
SaveManager:LoadAutoloadConfig()

player.Idled:Connect(function()
    VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    task.wait(1)
    VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

player.CharacterAdded:Connect(resetOnDeath)

local initialHoney = grabStats().Honey or 0
local sessionStartTime = tick()

RunService.Heartbeat:Connect(function()
    if hasHiveClaimed() then
        dig()
        farm()
        collectTokens()
        updateWalkspeed()
        avoidMobs()
        placeSprinklers()
        clearVisitedTokens()
    end
end)

coroutine.wrap(function()
    while task.wait(1) do
        local stats = grabStats()
        local sessionHoney = stats.Honey - initialHoney
        local sessionTime = tick() - sessionStartTime
        local honeyPerHour = sessionTime > 0 and (sessionHoney / sessionTime * 3600) or 0
        WrappedLabel:SetText(string.format(
            "Windy Favor 💖: %s\nAll-Time Honey 🍯: %s\nCurrent Honey 🍯: %s\nSession Honey 🍯: %s\nHoney Per Hour 🍯: %s\nSession Playtime ⏳: %s",
            formatNumber(stats.WindShrine and stats.WindShrine.WindyFavor or 0),
            formatNumber(stats.Totals and stats.Totals.Honey or 0),
            formatNumber(stats.Honey or 0),
            formatNumber(sessionHoney),
            formatNumber(honeyPerHour),
            formatTime(sessionTime)
        ))
    end
end)()

claimHive()