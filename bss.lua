--// v0.03 \\--
-- added patterns, fixed sprinklers

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
	lerpSpeed = 3,
	avoidMobs = false,
	sprinklersPlaced = false,
	placingSprinklers = false,
	lastTokenClearTime = tick(),
	lastTokenCheckTime = tick(),
	pattern = "Collect Tokens",
	isTweeningToField = false
}

local player = Players.LocalPlayer
local events = ReplicatedStorage:WaitForChild("Events", 10)
local flowerZones = Workspace:WaitForChild("FlowerZones")
local collectibles = Workspace:WaitForChild("Collectibles")
local honeycombs = Workspace:WaitForChild("Honeycombs")
local fieldsTable = {}

for _, field in ipairs(flowerZones:GetChildren()) do
	field.Size += Vector3.new(0, 120, 0)
	table.insert(fieldsTable, field.Name)
end
table.sort(fieldsTable, function(a, b) return a:lower() < b:lower() end)

if Workspace.Map:FindFirstChild("Fences") then
	Workspace.Map.Fences:Destroy()
end

local function formatNumber(num)
	local suffixes = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qad", "Qid"}
	local i = 1
	while num >= 1000 and i < #suffixes do
		num /= 1000
		i += 1
	end
	return i == 1 and tostring(num) or string.format("%.1f%s", num, suffixes[i])
end

local function formatTime(seconds)
	local days = math.floor(seconds / (24 * 3600))
	seconds %= (24 * 3600)
	local hours = math.floor(seconds / 3600)
	seconds %= 3600
	local minutes = math.floor(seconds / 60)
	seconds = math.floor(seconds % 60)
	return string.format("%02d:%02d:%02d:%02d", days, hours, minutes, seconds)
end

local function grabStats()
	return events.RetrievePlayerStats:InvokeServer() or {}
end

local PATH = PathfindingService:CreatePath({
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	AgentCanClimb = true,
	AgentJumpHeight = 150,
	Costs = { WalkThrough = 1, DontWalkThrough = math.huge, Default = 10 }
})

local function makeModifier(pos, size, passThrough)
	local part = Instance.new("Part")
	part.Size = size
	part.Position = pos
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.CastShadow = false
	part.Parent = Workspace
	local mod = Instance.new("PathfindingModifier")
	mod.PassThrough = passThrough
	mod.Label = passThrough and "WalkThrough" or "DontWalkThrough"
	mod.Parent = part
	return part
end

local function makeFence(cframe, size)
	local part = Instance.new("Part")
	part.CFrame = cframe
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 0.5
	part.Color = Color3.new(1, 0, 0)
	part.Parent = Workspace
	local mod = Instance.new("PathfindingModifier")
	mod.PassThrough = false
	mod.Label = "DontWalkThrough"
	mod.Parent = part
	return part
end

local function followPath(character, goal)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root) then return end
	PATH:ComputeAsync(root.Position, goal)
	if PATH.Status ~= Enum.PathStatus.Success then return end
	local waypoints = PATH:GetWaypoints()
	for i, wp in ipairs(waypoints) do
		if humanoid.Health <= 0 then break end
		if wp.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(wp.Position)
		local reached = humanoid.MoveToFinished:Wait(5)
		if not reached then
			local nextWp = waypoints[i + 1]
			if nextWp then
				humanoid:MoveTo(nextWp.Position)
				humanoid.MoveToFinished:Wait(3)
			else
				followPath(character, goal)
			end
			break
		end
	end
end

local function movePlayerTo(targetPos)
	local character = player.Character or player.CharacterAdded:Wait()
	followPath(character, targetPos)
end

local function buildModifiers()
	for _, folder in {Workspace:WaitForChild("Flowers"), Workspace:WaitForChild("FlowerZones")} do
		for _, obj in ipairs(folder:GetDescendants()) do
			if obj:IsA("BasePart") then
				makeModifier(obj.Position, obj.Size + Vector3.new(10, 2, 10), true)
			end
		end
	end
	local gates = Workspace:WaitForChild("Gates")
	for _, obj in ipairs(gates:GetDescendants()) do
		if obj:IsA("BasePart") or obj:IsA("MeshPart") then
			obj.Transparency = 0.5
			obj.CanCollide = false
		end
	end
end

buildModifiers()

local function moveToPosition(targetPos, duration)
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return false end
	local startPos = root.Position
	local startTime = tick()
	local alpha = 0
	while alpha < 1 and humanoid.Parent and root.Parent do
		local elapsed = tick() - startTime
		alpha = math.clamp(elapsed / duration, 0, 1)
		root.CFrame = CFrame.new(startPos:Lerp(targetPos, alpha))
		if (targetPos.Y - root.Position.Y) > 2 then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		RunService.Heartbeat:Wait()
	end
	if humanoid.Parent and root.Parent then
		root.CFrame = CFrame.new(targetPos)
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
			movePlayerTo(targetPos)
			events.ClaimHive:FireServer(hive.HiveID.Value)
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
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not field then return false end
	local playerPos = root.Position
	local fieldPos = field.Position
	local fieldSize = field.Size
	local buffer = 5
	local minX = fieldPos.X - (fieldSize.X / 2 + buffer)
	local maxX = fieldPos.X + (fieldSize.X / 2 + buffer)
	local minY = fieldPos.Y - (fieldSize.Y / 2 + buffer)
	local maxY = fieldPos.Y + (fieldSize.Y / 2 + buffer)
	local minZ = fieldPos.Z - (fieldSize.Z / 2 + buffer)
	local maxZ = fieldPos.Z + (fieldSize.Z / 2 + buffer)
	return playerPos.X >= minX and playerPos.X <= maxX and
	       playerPos.Y >= minY and playerPos.Y <= maxY and
	       playerPos.Z >= minZ and playerPos.Z <= maxZ
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
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		toggles.converting = false
		toggles.hasWalkedToHive = false
		return
	end
	local spawnPos = (player.SpawnPos.Value * CFrame.fromEulerAnglesXYZ(0, math.rad(110), 0) + Vector3.new(0, 3, 9)).Position
	if not moveToPosition(spawnPos, toggles.lerpSpeed) then
		toggles.converting = false
		toggles.hasWalkedToHive = false
		return
	end
	local activateButton = player.PlayerGui.ScreenGui.ActivateButton
	local maxAttempts = 10
	local attemptCount = 0
	while activateButton.TextBox.Text ~= "Stop Making Honey" and activateButton.BackgroundColor3 ~= Color3.fromRGB(201, 39, 28) and attemptCount < maxAttempts do
		if (player.SpawnPos.Value.Position - root.Position).Magnitude <= 13 then
			events.PlayerHiveCommand:FireServer("ToggleHoneyMaking")
			root.Anchored = false
			task.wait(0.5)
			attemptCount += 1
		else
			moveToPosition(spawnPos, toggles.lerpSpeed)
			root.Anchored = true
		end
	end
	local startTime = tick()
	while coreStats.Pollen.Value > 0 and tick() - startTime < 30 do
		task.wait(0.1)
	end
	if coreStats.Pollen.Value == 0 then task.wait(5) end
	toggles.converting = false
	toggles.hasWalkedToHive = false
	if toggles.autoFarm then
		local targetField = flowerZones:FindFirstChild(toggles.field)
		if targetField then
			moveToPosition(targetField.Position + Vector3.new(0, 7, 0), toggles.lerpSpeed)
			toggles.hasWalked = true
			toggles.isTweeningToField = false
		end
	end
end

local function collectTokens()
	if not hasHiveClaimed() or not toggles.autoFarm or toggles.converting or toggles.placingSprinklers then return end
	if tick() - toggles.lastTokenCheckTime < 0.1 then return end
	toggles.lastTokenCheckTime = tick()
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not collectibles then return end
	local targetField = flowerZones:FindFirstChild(toggles.field)
	if not targetField then return end
	local region = Region3.new(targetField.Position - targetField.Size / 2, targetField.Position + targetField.Size / 2)
	local closestToken, closestDistance = nil, math.huge
	local maxDistance = 50
	for _, token in ipairs(collectibles:GetChildren()) do
		if token:IsA("BasePart") and not toggles.visitedTokens[token] then
			local tokenPos = token.Position
			local distance = (root.Position - tokenPos).Magnitude
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
		while (root.Position - closestToken.Position).Magnitude > 4 and tick() - startTime < 5 do
			if not closestToken.Parent then
				toggles.visitedTokens[closestToken] = nil
				break
			end
			RunService.Heartbeat:Wait()
		end
		if closestToken.Parent and (root.Position - closestToken.Position).Magnitude <= 4 then
			toggles.visitedTokens[closestToken] = true
		end
	end
end

local function placeSprinklers()
	if not hasHiveClaimed() or not toggles.autoFarm or not toggles.autoSprinklers or toggles.converting or toggles.placingSprinklers or toggles.sprinklersPlaced then return end
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end
	local targetField = flowerZones:FindFirstChild(toggles.field)
	if not targetField or not isPlayerInField(targetField) then return end
	toggles.placingSprinklers = true
	local sprinkler = grabStats().EquippedSprinkler
	if not sprinkler then
		toggles.placingSprinklers = false
		return
	end
	local sprinklerCoverage = {
		["Basic Sprinkler"] = 16,
		["Silver Soakers"] = 20,
		["Golden Gushers"] = 24,
		["Diamond Drenchers"] = 28,
		["The Supreme Saturator"] = 32
	}
	local maxSprinklers = {
		["Basic Sprinkler"] = 1,
		["The Supreme Saturator"] = 1,
		["Silver Soakers"] = 2,
		["Golden Gushers"] = 3,
		["Diamond Drenchers"] = 4
	}
	local coverageRadius = sprinklerCoverage[sprinkler] or 16
	local maxSprinklersAllowed = maxSprinklers[sprinkler] or 0
	if maxSprinklersAllowed == 0 then
		toggles.placingSprinklers = false
		return
	end
	local fieldSize = targetField.Size
	local fieldCenter = targetField.Position
	local positions = {}
	if sprinkler == "Basic Sprinkler" or sprinkler == "The Supreme Saturator" then
		table.insert(positions, fieldCenter + Vector3.new(0, 3, 0))
	elseif sprinkler == "Silver Soakers" then
		local offsetZ = coverageRadius * 0.5
		table.insert(positions, fieldCenter + Vector3.new(0, 3, -offsetZ))
		table.insert(positions, fieldCenter + Vector3.new(0, 3, offsetZ))
	elseif sprinkler == "Golden Gushers" then
		local radius = coverageRadius * 0.5
		table.insert(positions, fieldCenter + Vector3.new(0, 3, -radius))
		table.insert(positions, fieldCenter + Vector3.new(-radius * math.sqrt(3) / 2, 3, radius / 2))
		table.insert(positions, fieldCenter + Vector3.new(radius * math.sqrt(3) / 2, 3, radius / 2))
	elseif sprinkler == "Diamond Drenchers" then
		local offset = coverageRadius * 0.5
		table.insert(positions, fieldCenter + Vector3.new(-offset, 3, -offset))
		table.insert(positions, fieldCenter + Vector3.new(-offset, 3, offset))
		table.insert(positions, fieldCenter + Vector3.new(offset, 3, -offset))
		table.insert(positions, fieldCenter + Vector3.new(offset, 3, offset))
	end
	for i, pos in ipairs(positions) do
		humanoid:MoveTo(pos)
		local moveFinished = humanoid.MoveToFinished:Wait(MOVETO_TIMEOUT)
		if not moveFinished then
			toggles.placingSprinklers = false
			return
		end
		task.wait(0.15)
		local originalJump = humanoid.JumpPower
		if maxSprinklersAllowed > 1 then
			if humanoid:GetState() == Enum.HumanoidStateType.Landed or humanoid:GetState() == Enum.HumanoidStateType.Running then
				humanoid.JumpPower = 70
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				task.wait(0.8)
			end
		end
		ReplicatedStorage.Events.PlayerActivesCommand:FireServer({["Name"] = "Sprinkler Builder"})
		if maxSprinklersAllowed > 1 then
			humanoid.JumpPower = originalJump
			task.wait(0.5)
		end
	end
	toggles.sprinklersPlaced = true
	toggles.placingSprinklers = false
end

local tiggle = false
local patterns = {
	["Collect Tokens"] = function(targetField)
		collectTokens()
	end,
	["Spiral"] = function(targetField, offset)
		offset = offset or 5
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not targetField then return end
		tiggle = true
		local fieldCenter = targetField.Position
		local fieldSize = targetField.Size
		local effectiveSizeX = fieldSize.X - 2 * offset
		local effectiveSizeZ = fieldSize.Z - 2 * offset
		local radius = math.min(effectiveSizeX, effectiveSizeZ) / 4
		local steps = 20
		local angleStep = 2 * math.pi / steps
		local maxLoops = 3
		for loop = 1, maxLoops do
			for i = 1, steps do
				local angle = i * angleStep
				local r = radius * (loop / maxLoops)
				local x = r * math.cos(angle)
				local z = r * math.sin(angle)
				local targetPos = fieldCenter + Vector3.new(x, 3, z)
				humanoid:MoveTo(targetPos)
				humanoid.MoveToFinished:Wait()
			end
		end
		tiggle = false
	end,
	["ZigZag"] = function(targetField, offset)
		offset = offset or 5
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not targetField then return end
		tiggle = true
		local fieldCenter = targetField.Position
		local fieldSize = targetField.Size
		local effectiveSizeX = fieldSize.X - 2 * offset
		local effectiveSizeZ = fieldSize.Z - 2 * offset
		local stepSize = 10
		local xSteps = math.floor(effectiveSizeX / stepSize)
		local zSteps = math.floor(effectiveSizeZ / stepSize)
		for x = -xSteps / 2, xSteps / 2 do
			local zStart = -zSteps / 2
			local zEnd = zSteps / 2
			if x % 2 == 0 then
				for z = zStart, zEnd do
					local targetPos = fieldCenter + Vector3.new(x * stepSize, 3, z * stepSize)
					humanoid:MoveTo(targetPos)
					humanoid.MoveToFinished:Wait()
				end
			else
				for z = zEnd, zStart, -1 do
					local targetPos = fieldCenter + Vector3.new(x * stepSize, 3, z * stepSize)
					humanoid:MoveTo(targetPos)
					humanoid.MoveToFinished:Wait()
				end
			end
		end
		tiggle = false
	end,
	["Square"] = function(targetField, offset)
		offset = offset or 5
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not targetField then return end
		tiggle = true
		local fieldCenter = targetField.Position
		local fieldSize = targetField.Size
		local effectiveSizeX = fieldSize.X - 2 * offset
		local effectiveSizeZ = fieldSize.Z - 2 * offset
		local squareSize = math.min(effectiveSizeX, effectiveSizeZ) / 4
		local halfSize = squareSize / 2
		local corners = {
			fieldCenter + Vector3.new(halfSize, 3, halfSize),
			fieldCenter + Vector3.new(halfSize, 3, -halfSize),
			fieldCenter + Vector3.new(-halfSize, 3, -halfSize),
			fieldCenter + Vector3.new(-halfSize, 3, halfSize)
		}
		for _, corner in ipairs(corners) do
			humanoid:MoveTo(corner)
			humanoid.MoveToFinished:Wait(MOVETO_TIMEOUT)
		end
		tiggle = false
	end,
	["CornerxSnake"] = function(targetField, offset)
		offset = offset or 5
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not targetField then return end
		tiggle = true
		local fieldCenter = targetField.Position
		local fieldSize = targetField.Size
		local effectiveSizeX = fieldSize.X - 2 * offset
		local effectiveSizeZ = fieldSize.Z - 2 * offset
		local stepSize = 10
		local xSteps = math.floor(effectiveSizeX / stepSize / 2)
		local zSteps = math.floor(effectiveSizeZ / stepSize / 2)
		local startCornerX = -effectiveSizeX / 2
		local startCornerZ = -effectiveSizeZ / 2
		for x = 0, xSteps - 1 do
			local zStart, zEnd, zInc
			if x % 2 == 0 then
				zStart = startCornerZ
				zEnd = startCornerZ + effectiveSizeZ / 2
				zInc = stepSize
			else
				zStart = startCornerZ + effectiveSizeZ / 2
				zEnd = startCornerZ
				zInc = -stepSize
			end
			for z = zStart, zEnd, zInc do
				local targetPos = fieldCenter + Vector3.new(startCornerX + x * stepSize, 3, z)
				humanoid:MoveTo(targetPos)
				humanoid.MoveToFinished:Wait()
			end
		end
		tiggle = false
	end,
	["e_lol"] = function(targetField, offset)
		offset = offset or 5
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not targetField then return end
		tiggle = true
		local fieldCenter = targetField.Position
		local fieldSize = targetField.Size
		local effectiveSizeX = fieldSize.X - 2 * offset
		local effectiveSizeZ = fieldSize.Z - 2 * offset
		local stepSize = 10
		local zSteps = math.floor(effectiveSizeZ / stepSize / 3)
		local startCornerX = effectiveSizeX / 2
		local startCornerZ = -effectiveSizeZ / 2
		local xPositions = {
			startCornerX - effectiveSizeX / 2,
			startCornerX - (effectiveSizeX * 3 / 4),
			startCornerX - effectiveSizeX
		}
		for i, x in ipairs(xPositions) do
			for z = startCornerZ, startCornerZ + effectiveSizeZ / 3, stepSize do
				local targetPos = fieldCenter + Vector3.new(x, 3, z)
				humanoid:MoveTo(targetPos)
				humanoid.MoveToFinished:Wait()
			end
			if i < #xPositions then
				local nextX = xPositions[i + 1]
				local targetPos = fieldCenter + Vector3.new(nextX, 3, startCornerZ + effectiveSizeZ / 3)
				humanoid:MoveTo(targetPos)
				humanoid.MoveToFinished:Wait()
			end
		end
		local targetPos = fieldCenter + Vector3.new(xPositions[1], 3, startCornerZ)
		humanoid:MoveTo(targetPos)
		humanoid.MoveToFinished:Wait()
		tiggle = false
	end
}

local function farm()
	if not hasHiveClaimed() or not toggles.autoFarm or toggles.converting then
		local controlScript = player:WaitForChild("PlayerScripts"):WaitForChild("ControlScript")
		controlScript.Enabled = true
		return
	end
	local targetField = flowerZones:FindFirstChild(toggles.field)
	if not targetField then return end
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid then return end
	if not isPlayerInField(targetField) and not toggles.hasWalked and not toggles.hasWalkedToHive and not toggles.placingSprinklers and not toggles.isTweeningToField then
		toggles.isTweeningToField = true
		tiggle = true
		if moveToPosition(targetField.Position + Vector3.new(0, 7, 0), toggles.lerpSpeed) then
			toggles.hasWalked = true
			toggles.sprinklersPlaced = false
			toggles.placingSprinklers = false
		end
		toggles.isTweeningToField = false
		tiggle = false
	elseif isPlayerInField(targetField) then
		local controlScript = player:WaitForChild("PlayerScripts"):WaitForChild("ControlScript")
		controlScript.Enabled = false
		toggles.hasWalked = true
		if toggles.autoSprinklers and not toggles.sprinklersPlaced and not toggles.placingSprinklers then
			placeSprinklers()
		end
		local patternFunc = patterns[toggles.pattern]
		if patternFunc and not tiggle then
			if not toggles.placingSprinklers then
				patternFunc(targetField)
			end
		end
	end
	convertHoney()
end

local function avoidMobs()
	if not toggles.avoidMobs or not hasHiveClaimed() then return end
	for _, mob in ipairs(Workspace.Monsters:GetChildren()) do
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
	toggles.isTweeningToField = false
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
		toggles.isTweeningToField = false
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
		toggles.isTweeningToField = false
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
	Tooltip = "Places sprinklers.",
	Callback = function(Value)
		toggles.autoSprinklers = Value
		toggles.sprinklersPlaced = false
		toggles.placingSprinklers = false
	end
})
FarmingGroupbox:AddToggle("AvoidMobsToggle", {
	Text = "Avoid Mobs",
	Default = false,
	Tooltip = "Avoids nearby mobs.",
	Callback = function(Value) toggles.avoidMobs = Value end
})
FarmingGroupbox:AddDropdown("PatternDropdown", {
	Values = { "Collect Tokens", "Spiral", "ZigZag", "Square", "CornerxSnake", "e_lol" },
	Default = "Collect Tokens",
	Multi = false,
	Text = "Pattern",
	Tooltip = "Select a farming pattern.",
	Callback = function(Value) toggles.pattern = Value end
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
SettingsGroupbox:AddSlider("LerpSpeedSlider", {
	Text = "Tween Speed",
	Default = 3,
	Min = 2,
	Max = 10,
	Suffix = "s",
	Rounding = 1,
	Compact = false,
	Tooltip = "Adjust tween speed.",
	Callback = function(Value) toggles.lerpSpeed = Value end
})

local UISettingsTab = Window:AddTab("UI Settings", "settings")
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
SaveManager:BuildConfigSection(UISettingsTab)
ThemeManager:ApplyToTab(UISettingsTab)
SaveManager:LoadAutoloadConfig()

player.Idled:Connect(function()
	VirtualUser:Button2Down(Vector2.new(0, 0), Workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), Workspace.CurrentCamera.CFrame)
end)

player.CharacterAdded:Connect(resetOnDeath)

local initialHoney = grabStats().Honey or 0
local sessionStartTime = tick()

RunService.Heartbeat:Connect(function()
	if hasHiveClaimed() then
		dig()
		farm()
		updateWalkspeed()
		avoidMobs()
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

local TRANSPARENCY = 0.9
local HIGHLIGHT_PROPERTIES = {
	FillColor = Color3.fromRGB(255, 255, 0),
	OutlineColor = Color3.fromRGB(255, 215, 0),
	FillTransparency = 0.5,
	OutlineTransparency = 0
}

local function applyEffectToPart(part)
	if part:IsA("BasePart") then
		part.CanCollide = false
		part.Transparency = TRANSPARENCY
		local highlight = Instance.new("Highlight")
		highlight.FillColor = HIGHLIGHT_PROPERTIES.FillColor
		highlight.OutlineColor = HIGHLIGHT_PROPERTIES.OutlineColor
		highlight.FillTransparency = HIGHLIGHT_PROPERTIES.FillTransparency
		highlight.OutlineTransparency = HIGHLIGHT_PROPERTIES.OutlineTransparency
		highlight.Parent = part
		highlight.Enabled = true
	end
end

local fieldDecos = Workspace:FindFirstChild("FieldDecos")
if fieldDecos then
	for _, part in ipairs(fieldDecos:GetDescendants()) do
		applyEffectToPart(part)
	end
end

local decorations = Workspace:FindFirstChild("Decorations")
if decorations then
	for _, part in ipairs(decorations:GetDescendants()) do
		if part:IsA("BasePart") and (part.Parent.Name == "Bush" or part.Parent.Name == "Blue Flower") then
			applyEffectToPart(part)
		end
	end
end

local miscDecos = decorations and decorations:FindFirstChild("Misc")
if miscDecos then
	for _, part in ipairs(miscDecos:GetDescendants()) do
		if part:IsA("BasePart") and part.Parent.Name == "Mushroom" then
			applyEffectToPart(part)
		end
	end
end
