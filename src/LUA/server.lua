-- ----------------------------------------------------------------------------
-- SNAKE CHALLENGE DUO
--
-- SERVER
-- VERSION 1.0a
--
-- COPYRIGHT 2023, DANIEL ENGLAND.  ALL RIGHTS RESERVED.
-- LGPL?
--
-- HISTORY
-- 19APR2024		1.0a	dengland
--		Fix bug causing loss of player id
--		Increase growth in battles
--		Increase speed in battles
-- 18APR2024		1.0	dengland
--		Add scoreboard support
--		Change bonus life point
--		More bees
--		Double size snake in battles
-- 25AUG2023	0.9a	dengland
--		"Screen saver" when not started
--		"Screen saver" after 2mins in attract
--		"Panic" speed in attract
--		Assert bGameStart when receive server reset command
--		Async fill block and clear text
-- 24AUG2023	0.9	dengland
--		Rebalance game speed
--		Rebalance food scores, effects, duration
--		Time and score animations
--		Speed meter
--		Fixes (HUD droppings, start freezing, level rushing)
--	23AUG2023	0.8	dengland
--		Beta testing
-- ----------------------------------------------------------------------------

--todo use commands.getBlockPosition() in early init?

local iBaseChan = 700
local sBaseModem = "front"
local pModem

local tCmdPos
local tCurTiles = {}
local tUpdTiles = {}

--dengland DO NOT USE turbo settings, especially turbo2!
local tGAMESPEED = {slow = 4, normal = 3, fast = 2, turbo1 = 1, turbo2 = 0}
local tGAMEDIFFICULTY = {training = 0, easy = 1, normal = 2, hard = 3, expert = 4}

local tGAMEMODE = {attract = 0, single = 1, battle = 2}

local bGameReset = true
local bGameStart = false
local bGameRun = false
local bGameOver = false
local bGameNext = false
local iGameDebug = 0
local iGameTick = 0
local tGameSaverS = {1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0}
local iGameSaverA = 4
local iGameSaverB = 3
local iGameSaverD = 1
local sGameBanner = "PRESS START"
local tGameStrobe = {0, 0, 0, 1, 1, 1, 3, 3, 3, 9, 9, 11, 11, 7, 7, 15, 15, 15}
local iGameStrbIdx = 1
local iGameStrbDelta = 1
local iGameMode = tGAMEMODE.attract
local iGameHighScore = 50000
local iGameBonusLife = 50000
local iGameSpeed = tGAMESPEED.normal
local iGameDifficulty = tGAMEDIFFICULTY.normal

local bHUD = false
local bHUDTitleText = false
local bHUDScoreText = false
local iHUDScoreStrbIdx = 0
local bHUDAnnounce = false
local sHUDAnnounce = ""
local bHUDAnnounceText = false
local iHUDAnnceStrbIdx = 0
local iHUDAnnceTick = 0

local tTitle1Strobe = {0, 0, 0, 4, 4, 4, 6, 6, 6, 12, 12, 14, 14, 7, 7, 15, 15, 15}
local iTitle1StrbIdx = 1
local iTitle1StrbDelta = 1
local tTitle2Strobe = {0, 0, 0, 8, 8, 7, 7, 15, 15, 15}
local iTitle2StrbIdx = 1
local iTitle2StrbDelta = 1

local bLevelGen = false
local iLevelCurrent = 0
local iLevelProgress = iGameDifficulty
local iLevelIdx = 0
local iLevelMax = 3
local iLevelTick = iLevelMax + 1
local iLevelBonus = 0
local iLevelTimer = 600
local iLevelTimeTick = 4
local tLevelTimeStrobe = {0, 8, 8, 7, 15}
local sLevelTime = ""
local tLevelTiles = {}
local iLevelBeesMax = 5
local iLevelBees = 0

local tPlayer1 = {}
local tPlayer2 = {}

local tSNAKEDIR = {up = 1, down = 2, left = 4, right = 8}

local tSnakeLook = {
	[tSNAKEDIR.up] = 1,
	[tSNAKEDIR.down] = 4,
	[tSNAKEDIR.left] = 3,
	[tSNAKEDIR.right] = 2}

local tSnakeMove = {
	[tSNAKEDIR.up] = {0, -1},
	[tSNAKEDIR.down] = {0, 1},
	[tSNAKEDIR.left] = {-1, 0},
	[tSNAKEDIR.right] = {1, 0}}

local tSnakeFace = {
	[tSNAKEDIR.up] = {tSNAKEDIR.left, tSNAKEDIR.right},
	[tSNAKEDIR.down] = {tSNAKEDIR.right, tSNAKEDIR.left},
	[tSNAKEDIR.left] = {tSNAKEDIR.down, tSNAKEDIR.up},
	[tSNAKEDIR.right] = {tSNAKEDIR.up, tSNAKEDIR.down}}

local tSnakePts = {600, 200, 400, 500, 750}

local iSnakeMoveMax = iGameSpeed

local tSnake1P = {}
local tSnake2P = {}

-- These MUST be set to the locations (top left) of the client control areas
local tControls = {
	{x = 127, y = 4, z = 48},
	{x = 140, y = 4, z = 48}}
--local tControls = {
--	{x = 216, y = 102, z = -957},
--	{x = 229, y = 102, z = -957}}

local tEntities = {}


-- ----------------------------------------------------------------------------
-- COMMAND HELPERS
-- ----------------------------------------------------------------------------


local function entitiesGetNumber(aString)
    local e = string.find(aString, "d")
    local n = string.sub(aString, 1, e - 1)

    return tonumber(n), string.sub(aString, e + 3)
end

local function entitiesBuildList(aList)
    tEntities = {}

    for i = 1, #aList do
        s = string.sub(aList[i], 1, string.find(aList[i], " ") - 1)
        table.insert(tEntities, {id = s, pos = {x = 0, y = 0, z = 0}})

        s = string.sub(aList[i], string.find(aList[i], "%[") + 1)

        tEntities[i].pos.x, s = entitiesGetNumber(s)
        tEntities[i].pos.y, s = entitiesGetNumber(s)
        tEntities[i].pos.z = entitiesGetNumber(s)
    end
end

local function entitiesInControl(aPos)
    tEntities = {}

    res, t = commands.exec("execute as @e[type=minecraft:player,x="..tostring(aPos.x)..",y="..tostring(aPos.y)..",z="..tostring(aPos.z)..",dx=2,dz=2] run data get entity @s Pos")

    if res then
        entitiesBuildList(t)
    end
end

local function formPosTextStr(aX, aY, aZ)
	return "X:"..tostring(aX).. ",Y:".. tostring(aY).. ",Z:".. tostring(aZ)
end

local function formPosString(aX, aY, aZ)
	return tostring(aX).. " ".. tostring(aY).. " ".. tostring(aZ)
end

local function formFromToPos(aX1, aY1, aZ1, aX2, aY2, aZ2)
	return formPosString(aX1, aY1, aZ1).. " ".. formPosString(aX2, aY2, aZ2)
end

local function formLayerPos(aLayer, aRect)
	return formFromToPos(aRect[1], aRect[2], tCmdPos[3] - (3 - aLayer), aRect[3], aRect[4], tCmdPos[3] - (3 - aLayer))
end

local function formLayerPoint(aLayer, aPoint)
	return formPosString(aPoint[1], aPoint[2], tCmdPos[3] - (3 - aLayer))
end

local function formTexturePoint(aIndex, aPoint)
	return formPosString(aPoint[1] + aIndex, aPoint[2], tCmdPos[3] - 6)
end

-- ----------------------------------------------------------------------------
-- API
-- ----------------------------------------------------------------------------

local function initScoreboard()
	commands.execAsync("scoreboard objectives add snakeduo dummy {\"text\":\"Snake Challenge Duo\",\"color\":\"yellow\"}")
	local iScore = 0
	local bRes, tRes = commands.exec("scoreboard players get #highscore snakeduo")

	if bRes then
		local iE = string.find(tRes[1], "has ")
		local sSub = string.sub(tRes[1], iE + 4)
		iE = string.find(sSub, "%[")
		sSub = string.sub(sSub, 1, iE - 1)

		iScore = tonumber(sSub)
	end

	if iScore < iGameBonusLife then
		iGameHighScore = iGameBonusLife
	else
		iGameHighScore = iScore
	end
end

local function notifyPlayerEntry(aId)
	if  tPlayer1.alive then
		commands.execAsync("title "..tPlayer1.id.." title {\"text\":\"Snake Challenge Duo\",\"bold\":true,\"color\":\"yellow\"}")
		commands.execAsync("title "..tPlayer1.id.." subtitle {\"text\":\""..aId.." entered the game!\",\"bold\":false,\"color\":\"white\"}")
	end

	if  tPlayer2.alive then
		commands.execAsync("title "..tPlayer2.id.." title {\"text\":\"Snake Challenge Duo\",\"bold\":true,\"color\":\"yellow\"}")
		commands.execAsync("title "..tPlayer2.id.." subtitle {\"text\":\""..aId.." entered the game!\",\"bold\":false,\"color\":\"white\"}")
	end
end

local function getPlayerBestScore(aId)
	local iScore = 0
	local bRes, tRes = commands.exec("scoreboard players get "..aId.." snakeduo")

	if bRes then
		local iE = string.find(tRes[1], "has ")
		local sSub = string.sub(tRes[1], iE + 4)
		iE = string.find(sSub, "%[")
		sSub = string.sub(sSub, 1, iE - 1)

		iScore = tonumber(sSub)
	end

	return iScore
end


-- ----------------------------------------------------------------------------
local function getLayerRect()
-- ----------------------------------------------------------------------------
	return {tCmdPos[1], tCmdPos[2] + 25, tCmdPos[1] + 31, tCmdPos[2] + 1}
end

local cmdFillLayer

-- ----------------------------------------------------------------------------
local function getScreenRect()
-- ----------------------------------------------------------------------------
	return {tCmdPos[1] + 1, tCmdPos[2] + 22, tCmdPos[1] + 30, tCmdPos[2] + 5}
end

-- ----------------------------------------------------------------------------
local function offsetRect(aRect, aOffsets)
-- ----------------------------------------------------------------------------
	aRect[1] = aRect[1] + aOffsets[1]
	aRect[2] = aRect[2] + aOffsets[2]
	aRect[3] = aRect[3] + aOffsets[3]
	aRect[4] = aRect[4] + aOffsets[4]
end

-- ----------------------------------------------------------------------------
local function getScreenPoint(aPoint)
-- ----------------------------------------------------------------------------
	return {aPoint[1] + tCmdPos[1] + 1, tCmdPos[2] + 22 - aPoint[2]}
end

-- ----------------------------------------------------------------------------
local function getTexturePoint(aSheet)
-- ----------------------------------------------------------------------------
	return {tCmdPos[1], tCmdPos[2] + 1 + aSheet}
end

local cmdCloneText
local cmdFillText
local cmdClearText
local cmdDataText
local cmdDataTextStyles

-- ----------------------------------------------------------------------------
local function realiseText(aPoint, aWidth, aText)
-- ----------------------------------------------------------------------------
	local tPosEnd = getScreenPoint(aPoint)
	local tPosBegin = getScreenPoint(aPoint)

	tPosEnd[1] = tPosEnd[1] + aWidth

	cmdCloneText(tPosEnd)
	cmdFillText(tPosBegin, tPosEnd, aText)
end

-- ----------------------------------------------------------------------------
local function clearText(aPoint, aWidth)
-- ----------------------------------------------------------------------------
	local tPosEnd = getScreenPoint(aPoint)
	local tPosBegin = getScreenPoint(aPoint)

	tPosEnd[1] = tPosEnd[1] + aWidth

	cmdClearText(tPosBegin, tPosEnd)
end

-- ----------------------------------------------------------------------------
local function updateText(aPoint, aText)
-- ----------------------------------------------------------------------------
	local tPosBegin = getScreenPoint(aPoint)
	cmdDataText(tPosBegin, aText)
end

-- ----------------------------------------------------------------------------
local function colourText(aPoint, aWidth, aColour)
-- ----------------------------------------------------------------------------
	local tPosBegin = getScreenPoint(aPoint)
	local sStyles = ""

	for i = 1, aWidth do
		sStyles = sStyles.. tostring(aColour)
		if i < aWidth then
			sStyles = sStyles.. ","
		end
	end

	cmdDataTextStyles(tPosBegin, sStyles)
end

local cmdCloneTile

-- ----------------------------------------------------------------------------
local function updateTile(aPoint, aSheet, aIndex)
-- ----------------------------------------------------------------------------
	tUpdTiles[aPoint[2] + 1][aPoint[1] + 1][1] = aSheet
	tUpdTiles[aPoint[2] + 1][aPoint[1] + 1][2] = aIndex
end

-- ----------------------------------------------------------------------------
local function realiseTiles()
-- ----------------------------------------------------------------------------
	for y = 1, 18 do
		for x = 1, 30 do
			if  tCurTiles[y][x][1] ~= tUpdTiles[y][x][1]
			or tCurTiles[y][x][2] ~= tUpdTiles[y][x][2] then
				tCurTiles[y][x][1] = tUpdTiles[y][x][1]
				tCurTiles[y][x][2] = tUpdTiles[y][x][2]

				cmdCloneTile({x, y}, tCurTiles[y][x][1], tCurTiles[y][x][2])
			end
		end
	end
end

-- ----------------------------------------------------------------------------
-- COMMAND CALLS
-- ----------------------------------------------------------------------------

function cmdCloneText(aAnchor)
	local tSrc = getTexturePoint(14)
	local sSrc = formTexturePoint(9, tSrc)
	local sDst = formLayerPoint(3, aAnchor)

--	print("clone ".. sSrc.. " ".. sSrc.. " ".. sDst.. " replace")
	_, tLines = commands.exec("clone ".. sSrc.. " ".. sSrc.. " ".. sDst.. " replace")
--	print(tLines[1])
--	error("blah", 0)
end

function cmdFillText(aBegin, aEnd, aText)
	local sDst = formLayerPoint(3, aBegin)
	local sAnchor = formPosTextStr(aEnd[1], aEnd[2], tCmdPos[3])

	commands.exec("fill ".. sDst.. " ".. sDst.. " fairylights:fastener[facing=south]{ForgeCaps:{\"fairylights:fastener\":{outgoing:[{connection:{destination:{data:{"..sAnchor.."},type:\"block\" },logic:{text:{value:\""..aText.."\" }}},type:\"fairylights:letter_bunting\"}]}}}")
end

local function cmdKillText()
	local sKillLoc = "x="..tostring(tCmdPos[1])..",y="..tostring(tCmdPos[2] + 1)..",z="..tostring(tCmdPos[3] - 3)
	local sKillDelta = "dx=32,dy=25,dz=10"
	commands.execAsync("kill @e[type=item,name=\"Letter Bunting\","..sKillDelta..","..sKillLoc.."]")
end

function cmdClearText(aBegin, aEnd)
	local sBegin = formLayerPoint(3, aBegin)
	local sEnd = formLayerPoint(3, aEnd)

--	local sKillLoc = "x="..tostring(aBegin[1])..",y="..tostring(aBegin[2])..",z="..tostring(tCmdPos[3])

	commands.execAsync("fill ".. sBegin.. " ".. sEnd.. " minecraft:air replace")

--dengland Wasn't working
--	commands.exec("kill @e[type=item,name=\"Letter Bunting\",distance=0..5,"..sKillLoc.."]")

--dengland This isn't working
--	local sKillLoc = "x="..tostring(tCmdPos[1])..",y="..tostring(tCmdPos[2] + 1)..",z="..tostring(tCmdPos[3] - 3)
--	local sKillDelta = "dx=32,dy=25,dz=10"
--	bRes, tLines = commands.exec("kill @e[type=item,name=\"Letter Bunting\","..sKillDelta..","..sKillLoc.."]")

--dengland This won't either I'm guessing
	cmdKillText()
end

function cmdDataText(aBegin, aText)
	local sDst = formLayerPoint(3, aBegin)
	commands.execAsync("data modify block ".. sDst.. " ForgeCaps.\"fairylights:fastener\".outgoing[].connection.logic.text.value set value \"".. aText.. "\"")
end

function cmdDataTextStyles(aBegin, aStyles)
	local sDst = formLayerPoint(3, aBegin)
	commands.execAsync("data modify block ".. sDst.. " ForgeCaps.\"fairylights:fastener\".outgoing[].connection.logic.text.styling set value [I;".. aStyles.. "]")
end

function cmdFillLayer(aLayer, aRect, aBlock)
	local sPos = formLayerPos(aLayer, aRect)
	commands.execAsync("fill ".. sPos.. " ".. aBlock.. " replace")
--	bRes, tLines = commands.exec("fill ".. sPos.. " ".. aBlock.. " replace")
--	print(tLines[1])
end

function cmdCloneTile(aPoint, aSheet, aIndex)
	local tDest = getScreenPoint(aPoint)
	local sDest = formLayerPoint(2, tDest)

	local tSrc = getTexturePoint(aSheet)
	local sSrc = formTexturePoint(aIndex, tSrc)

	commands.execAsync("clone ".. sSrc.. " ".. sSrc.. " ".. sDest.. " replace")
end

-- ----------------------------------------------------------------------------
-- INITIALISATIONS
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
local function initCmdPos()
-- ----------------------------------------------------------------------------
	bRes, tLines = commands.exec("data get block ~ ~ ~ x")

	print(tostring(#tLines))

	for i = 1, #tLines do
		print(tLines[i])
	end

--if bRes then
	_, _, sX, sY, sZ = string.find(tLines[1], "([-]*%d+),%s([-]*%d+),%s([-]*%d+)")

	print(sX.." "..sY.." "..sZ)
	tCmdPos = {tonumber(sX), tonumber(sY), tonumber(sZ)}

	sPos = formFromToPos(tCmdPos[1], tCmdPos[2] + 1, tCmdPos[3], tCmdPos[1] + 31, tCmdPos[2] + 25, tCmdPos[3] - 3)
	bRes, tLines = commands.exec("fill ".. sPos.. " minecraft:stone_bricks replace")
	print(tLines[1])

--dengland Hopefully redundant
--	local sKillLoc = "x="..tostring(tCmdPos[1])..",y="..tostring(tCmdPos[2] + 1)..",z="..tostring(tCmdPos[3] - 3)
--	local sKillDelta = "dx=32,dy=25,dz=10"
--	bRes, tLines = commands.exec("kill @e[type=item,name=\"Letter Bunting\","..sKillDelta..","..sKillLoc.."]")
--	print(tLines[1])
end

-- ----------------------------------------------------------------------------
local function initScreen()
-- ----------------------------------------------------------------------------
	tRect = getLayerRect()
	cmdFillLayer(3, tRect, "minecraft:air")
	cmdFillLayer(2, tRect, "minecraft:stone_bricks")

	tRect = getScreenRect()
	cmdFillLayer(2, tRect, "rechiseled:glowstone_smooth_connecting")

	tRect = getScreenRect()
	cmdFillLayer(1, tRect, "minecraft:green_concrete")

	offsetRect(tRect, {1, -1, -1, 1})
	cmdFillLayer(2, tRect, "minecraft:air")

--dengland Try to clean up
	cmdKillText()
end

-- ----------------------------------------------------------------------------
local function initTiles()
-- ----------------------------------------------------------------------------
	tCurTiles = {}
	tUpdTiles = {}

	for y = 1, 18 do
		table.insert(tCurTiles, {})
		table.insert(tUpdTiles, {})

		for x = 1, 30 do
			table.insert(tCurTiles[y], {-1, 0})
			table.insert(tUpdTiles[y], {-1, 0})
		end
	end
end

-- ----------------------------------------------------------------------------
local function initPlayers()
-- ----------------------------------------------------------------------------
	tPlayer1= {
		alive = false,
		lives = 3,
		livesPush = 3,
		score = 0,
		best = 0,
		textScore = false,
		bonus = 0,
		textStart = false,
		input = 0,
		reqStart = false,
		levelCurr = 0,
		levelProg = iGameDifficulty,
		levelIdx = 0,
		id = ""}

	tPlayer2= {
		alive = false,
		lives = 3,
		livesPush = 3,
		score = 0,
		best = 0,
		textScore = false,
		bonus = 0,
		textStart = false,
		input = 0,
		reqStart  = false,
		levelCurr = 0,
		levelProg = iGameDifficulty,
		levelIdx = 0,
		id = ""}
end

-- ----------------------------------------------------------------------------
local function initSnakes()
-- ----------------------------------------------------------------------------
	tSnake1P = {
		visible = false,
		look = tSNAKEDIR.right,
		move = tSNAKEDIR.right,
		invun = true,
		invunTicks = 18,
		moveFast = 9,
		moveTick = iSnakeMoveMax,
		grow = false,
		growNone = 0,
		growEx = 0,
		collide = false}

	tSnake2P = {
		visible = false,
		look = tSNAKEDIR.left,
		move = tSNAKEDIR.left,
		invun = true,
		invunTicks = 18,
		moveFast = 9,
		moveTick = iSnakeMoveMax,
		grow = false,
		growNone = 0,
		growEx = 0,
		collide = false}

	if  iGameMode == tGAMEMODE.battle then
		iSnakeMoveMax = iGameSpeed - 1
		tSnake1P.body = {{9, 14}, {8, 14}, {7, 14}, {6, 14}, {5, 14}, {4, 14}, {3, 14}, {2, 14}, {1, 14}}
		tSnake2P.body = {{18, 1}, {19, 1}, {20, 1}, {21, 1}, {22, 1}, {23, 1}, {24, 1}, {25, 1}, {26, 1}}
	else
		iSnakeMoveMax = iGameSpeed
		tSnake1P.body = {{5, 14}, {4, 14}, {3, 14}, {2, 14}, {1, 14}}
		tSnake2P.body = {{22, 1}, {23, 1}, {24, 1}, {25, 1}, {26, 1}}
	end
end


local levelGenA
local levelGenB
local levelGenC
local levelGenD

-- ----------------------------------------------------------------------------
local function realiseLives()
-- ----------------------------------------------------------------------------
	local tPos
	local tTex

	if iGameMode == tGAMEMODE.single then
		tPos= {0, 19}

		for i = 1, 10 do
			tTex = {2, 0}
			if tPlayer1.alive then
				if tPlayer1.lives == i then
					tTex = {0, 5}
				elseif  tPlayer1.lives > i then
					tTex = {0, 0}
				end
			end
			cmdCloneTile(tPos, tTex[1], tTex[2])

			tPos[1] = tPos[1] + 1
		end

		tPos= {20, 19}

		for i = 1, 10 do
			tTex = {2, 0}
			if tPlayer2.alive then
				if  tPlayer2.lives == i then
					tTex = {1, 5}
				elseif  tPlayer2.lives > i then
					tTex = {1, 0}
				end
			end
			cmdCloneTile(tPos, tTex[1], tTex[2])

			tPos[1] = tPos[1] + 1
		end
	elseif iGameMode == tGAMEMODE.battle then
		local iCnt

		tPos= {0, 19}
		iCnt = 2 - tPlayer2.lives

		for i = 1, 10 do
			if iCnt >= i then
				tTex = {0, 5}
			else
				tTex = {2, 0}
			end

			cmdCloneTile(tPos, tTex[1], tTex[2])

			tPos[1] = tPos[1] + 1
		end

		tPos= {20, 19}
		iCnt = 2 - tPlayer1.lives

		for i = 1, 10 do
			if  iCnt >= i then
				tTex = {1, 5}
			else
				tTex = {2, 0}
			end

			cmdCloneTile(tPos, tTex[1], tTex[2])

			tPos[1] = tPos[1] + 1
		end
	end
end

-- ----------------------------------------------------------------------------
local function realiseScores()
-- ----------------------------------------------------------------------------
	if tPlayer1.alive then
		if  math.floor(tPlayer1.score / iGameBonusLife) ~= tPlayer1.bonus then
			tPlayer1.bonus = tPlayer1.bonus + 1
			if iGameMode == tGAMEMODE.single then
				tPlayer1.lives = tPlayer1.lives + 1
				realiseLives()
			end
		end
	end

	if tPlayer2.alive then
		if  math.floor(tPlayer2.score / iGameBonusLife) ~= tPlayer2.bonus then
			tPlayer2.bonus = tPlayer2.bonus + 1

			if iGameMode == tGAMEMODE.single then
				tPlayer2.lives = tPlayer2.lives + 1
				realiseLives()
			end
		end
	end

	if iGameMode ~= tGAMEMODE.attract then
		if tPlayer1.alive then
			if  tPlayer1.textScore then
				updateText({0, 20}, string.format("%09d", tPlayer1.score))
			else
				realiseText({0, 20}, 9, string.format("%09d", tPlayer1.score))
				colourText({0, 20}, 9, 0)
				tPlayer1.textScore = true
			end

			if tPlayer1.score > tPlayer1.best then
				tPlayer1.best = tPlayer1.score
				commands.execAsync("scoreboard players set "..tPlayer1.id.." snakeduo "..tostring(tPlayer1.score))
			end
		end

		if tPlayer2.alive then
			if  tPlayer2.textScore then
				updateText({20, 20}, string.format("%09d", tPlayer2.score))
			else
				realiseText({20, 20}, 9, string.format("%09d", tPlayer2.score))
				colourText({20, 20}, 9, 0)
				tPlayer2.textScore = true
			end

			if tPlayer2.score > tPlayer2.best then
				tPlayer2.best = tPlayer2.score
				commands.execAsync("scoreboard players set "..tPlayer2.id.." snakeduo "..tostring(tPlayer2.score))
			end
		end

		commands.execAsync("scoreboard players operation #highscore snakeduo > @a snakeduo")

		if tPlayer1.score > iGameHighScore then
			iGameHighScore = tPlayer1.score
			if bHUDScoreText then
				updateText({10, 18}, string.format("%09d", iGameHighScore))
			end
		end

		if tPlayer2.score > iGameHighScore then
			iGameHighScore = tPlayer2.score
			if bHUDScoreText then
				updateText({10, 18}, string.format("%09d", iGameHighScore))
			end
		end
	end
end

-- ----------------------------------------------------------------------------
local function realiseSpeed(aPos, aSnake)
-- ----------------------------------------------------------------------------
	if iGameMode ~= tGAMEMODE.attract then
		for i = 1, 5 do
			tTex = {2, 0}
--			if tPlayer1.alive then
				if aSnake.moveTick > iGameSpeed then
					if  ((aSnake.moveTick - iGameSpeed) + 1) >= i then
						tTex = {2, 1}
					end
				elseif  (iGameSpeed - aSnake.moveTick) >= i then
					tTex = {2, 2}
				end
--			end
			cmdCloneTile(aPos, tTex[1], tTex[2])
			aPos[1] = aPos[1] + 1
		end
	end
end

-- ----------------------------------------------------------------------------
local function initLevel()
-- ----------------------------------------------------------------------------
	tPlayer1.textStart = false
	tPlayer2.textStart = false

	tPlayer1.textScore = false
	tPlayer2.textScore = false

	tPlayer1.input = 0
	tPlayer2.input = 0

	initScreen()
	initTiles()

	bHUD = false
	bHUDTitleText = false
	bHUDScoreText = false

	bLevelGen = false

	iLevelMax = 3
	iLevelTick = iLevelMax + 1
	iLevelBonus = 0
	iLevelTimer = 600
	iLevelTimeTick = 4
	iLevelBees = 0

	iLevelBeesMax = 5 + (iLevelProgress * 3)

	tLevelTiles = {}

	for y = 1, 18 do
		table.insert(tLevelTiles, {})
		for x = 1, 30 do
			table.insert(tLevelTiles[y], 0)
		end
	end

	if iGameMode == tGAMEMODE.single then
		if  tPlayer1.alive then
			tPlayer1.levelCurr = iLevelCurrent
			tPlayer1.levelProg = iLevelProgress
			tPlayer1.levelIdx = iLevelIdx
		else
			tPlayer2.levelCurr = iLevelCurrent
			tPlayer2.levelProg = iLevelProgress
			tPlayer2.levelIdx = iLevelIdx
		end
	end

	if  iGameMode ~= tGAMEMODE.attract then
		if  iLevelCurrent == 4 then
			iLevelCurrent = 0
			iLevelProgress = iLevelProgress + 1
		end

		if  iLevelCurrent == 0 then
			levelGenA(iLevelProgress, 2, 0)
		elseif iLevelCurrent == 1 then
			levelGenB(iLevelProgress, 2, 0)
		elseif iLevelCurrent == 2 then
			levelGenC(iLevelProgress, 2, 0)
		elseif iLevelCurrent == 3 then
			levelGenD(iLevelProgress, 2, 0)
		end

		iLevelCurrent = iLevelCurrent + 1
		iLevelIdx = iLevelIdx + 1

		bHUDAnnounce = true

		if  iGameMode == tGAMEMODE.single then
			sHUDAnnounce = "LEVEL ".. tostring(iLevelIdx)
		else
			sHUDAnnounce = "ROUND ".. tostring(iLevelIdx)
		end

		bGameRun = false
	end

	bLevelGen = true

	initSnakes()

	if  iGameMode == tGAMEMODE.attract then
		tSnake1P.visible = true
		tSnake2P.visible = true
	else
		if tPlayer1.alive then
			tSnake1P.visible = true
		end

		if tPlayer2.alive then
			tSnake2P.visible = true
		end
	end

	realiseScores()
	realiseLives()
end

-- ----------------------------------------------------------------------------
-- ROUTINES - SNAKE
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
local function realiseSnake(aSnake, aSheet)
-- ----------------------------------------------------------------------------
	if aSnake.visible then
		local iTexIdx = tSnakeLook[aSnake.look]

		updateTile(aSnake.body[1], aSheet, iTexIdx)

		iTexIdx = 0

		if aSnake.invun then
			if aSnake.invunTicks % 2 == 0 then
				iTexIdx = 5
			end
		end

		for i = 2, #aSnake.body do
			updateTile(aSnake.body[i], aSheet, iTexIdx)
		end
	end
end

-- ----------------------------------------------------------------------------
local function clearSnake(aSnake)
-- ----------------------------------------------------------------------------
	for i = 1, #aSnake.body do
		updateTile(aSnake.body[i], -1, 0)
	end
end

-- ----------------------------------------------------------------------------
local function snakeMenu(aSnake)
-- ----------------------------------------------------------------------------
	if  aSnake.body[1][1] == 1
	and aSnake.body[1][2] == 14 then
		aSnake.look = tSNAKEDIR.right
	elseif aSnake.body[1][1] == 26
	and aSnake.body[1][2] == 14 then
		aSnake.look = tSNAKEDIR.up
	elseif aSnake.body[1][1] == 26
	and aSnake.body[1][2] == 1 then
		aSnake.look = tSNAKEDIR.left
	elseif aSnake.body[1][1] == 1
	and aSnake.body[1][2] == 1 then
		aSnake.look = tSNAKEDIR.down
	end
end

-- ----------------------------------------------------------------------------
local function snakeCheckCollide(aSnake, aPos1, aPlayer)
-- ----------------------------------------------------------------------------
	if  (aPos1[1] >= 0)
	and (aPos1[1] <= 27)
	and (aPos1[2] >= 0)
	and (aPos1[2] <= 15) then
		local tTile = tUpdTiles[aPos1[2] + 1][aPos1[1] + 1]

		if (tTile[1] ~= -1)
		and (tTile[1] < 3) then
			aSnake.collide = true

			if (tTile[1] == 2)
			and (tTile[2] == 2) then
				updateTile(aPos1, -1, 0)
				tLevelTiles[aPos1[2] + 1][aPos1[1] + 1] = 0

				iLevelBees = iLevelBees - 1

				if aPlayer.alive
				and aSnake.invun then
					if iGameMode == tGAMEMODE.battle then
						aPlayer.score = aPlayer.score + tSnakePts[5]  * 2
					elseif iGameMode == tGAMEMODE.single then
						aPlayer.score = aPlayer.score + tSnakePts[5]
					end
					realiseScores()
				end
			end
		end
	else
		aSnake.collide = true
	end
end

-- ----------------------------------------------------------------------------
local function snakeCheckEat(aSnake, aPos1, aPlayer)
-- ----------------------------------------------------------------------------
	local iPts = 0

	if  not aSnake.collide then
		local tTile = tUpdTiles[aPos1[2] + 1][aPos1[1] + 1]

		if (tTile[1] == 3) then
			iPts = tSnakePts[tTile[2] + 1]
			if  iGameMode == tGAMEMODE.battle then
				iPts = iPts * 2
			end

			if tTile[2] == 0 then
				if aSnake.growEx > 0 then
					aSnake.growEx = 0
				else
					if  iGameMode == tGAMEMODE.battle then
						aSnake.growNone = 9
					else
						aSnake.growNone = 18
					end
				end
				aSnake.moveFast = aSnake.moveFast + 9
			elseif tTile[2] == 1 then
				if aSnake.growNone > 0 then
					aSnake.growNone = 0
				else
					if  iGameMode == tGAMEMODE.battle then
						aSnake.growEx = 24
					else
						aSnake.growEx = 12
					end
				end
				aSnake.moveFast = aSnake.moveFast - 6
			elseif tTile[2] == 2 then
				aSnake.moveFast = aSnake.moveFast + 24
			elseif tTile[2] == 3 then
				aSnake.invun = true
				aSnake.invunTicks = aSnake.invunTicks + 24
				aSnake.moveFast = aSnake.moveFast + 12
			end

			if aSnake.invunTicks > 30 then
				aSnake.invunTicks = 30
			end

			if  aSnake.moveFast > 30 then
				aSnake.moveFast = 30
			elseif aSnake.moveFast < -12 then
				aSnake.moveFast = -12
			end

			updateTile(aPos1, -1, 0)
			tLevelTiles[aPos1[2] + 1][aPos1[1] + 1] = 0

			iLevelBonus = iLevelBonus - 1
			aSnake.grow = true

			aPlayer.score = aPlayer.score + iPts
			realiseScores()
		end
	end
end

-- ----------------------------------------------------------------------------
local function snakeCheckMove(aSnake, aPos)
-- ----------------------------------------------------------------------------
	local bResult = false

--	if  (aPos[1] >= 0)
--	and (aPos[1] <= 27)
--	and (aPos[2] >= 0)
--	and (aPos[2] <= 15) then
--		bResult = true
--	end

--	if bResult then
		bResult = (not aSnake.collide) and (tUpdTiles[aPos[2] + 1][aPos[1] + 1][1] == -1)
--	end

	return bResult
end

-- ----------------------------------------------------------------------------
local function snakeMove(aSnake, aPos)
-- ----------------------------------------------------------------------------
	if aSnake.visible then
		aSnake.move = aSnake.look

		if  snakeCheckMove(aSnake, aPos) then
			if (not aSnake.grow)
			or (aSnake.growNone > 0)	then
				updateTile(aSnake.body[#aSnake.body], -1, 0)
				table.remove(aSnake.body, #aSnake.body)
			end

			if  aSnake.growEx == 0 then
				aSnake.grow = false
			end

			table.insert(aSnake.body, 1, aPos)
		end
	end
end

-- ----------------------------------------------------------------------------
local function snakeApplyCollide(aBoth)
-- ----------------------------------------------------------------------------
	if  tSnake1P.visible
	and tSnake1P.collide
	and not tSnake1P.invun then
		if tPlayer1.alive then
			if  iGameMode == tGAMEMODE.single then
				tPlayer1.lives = tPlayer1.lives - 1
			elseif not tSnake2P.collide then
				tPlayer1.lives = tPlayer1.lives - 1

				bHUDAnnounce = true
				sHUDAnnounce = "1P LOSES"
				bGameNext = true
				bGameRun = false
			end

			realiseLives()
		end
		tSnake1P.moveFast = 0
		tSnake1P.growEx = 0
		tSnake1P.growNone = 0
		tSnake1P.grow = false

		tSnake1P.invun = true
		tSnake1P.invunTicks = 18
	else
		tSnake1P.collide = false
	end

	if tSnake2P.visible
	and tSnake2P.collide
	and not tSnake2P.invun then
		if tPlayer2.alive then
			if  iGameMode == tGAMEMODE.single then
				tPlayer2.lives = tPlayer2.lives - 1
			elseif not tSnake1P.collide then
				tPlayer2.lives = tPlayer2.lives - 1

				bHUDAnnounce = true
				sHUDAnnounce = "2P LOSES"
				bGameNext = true
				bGameRun = false
			end

			realiseLives()
		end

		tSnake2P.moveFast = 0
		tSnake2P.growEx = 0
		tSnake2P.growNone = 0
		tSnake2P.grow = false

		tSnake2P.invun = true
		tSnake2P.invunTicks = 18
	else
		tSnake2P.collide = false
	end

	if  iGameMode == tGAMEMODE.battle then
		if tSnake1P.collide
		and tSnake2P.collide then
			bHUDAnnounce = true
			sHUDAnnounce = "YOU LOSE"
			bGameRun = false
			bGameNext = true
		end
	end

	tSnake1P.collide = false
	tSnake2P.collide = false
end

-- ----------------------------------------------------------------------------
local function snakeInvunExp(aSnake)
-- ----------------------------------------------------------------------------
	if  aSnake.invun then
		aSnake.invunTicks = aSnake.invunTicks - 1

		if  aSnake.invunTicks == 0 then
			aSnake.invun = false
		end
	end
end

-- ----------------------------------------------------------------------------
local function snakeFastExp(aSnake)
-- ----------------------------------------------------------------------------
	if  aSnake.moveFast > 0 then
		aSnake.moveFast = aSnake.moveFast - 1
	elseif aSnake.moveFast < 0 then
		aSnake.moveFast = aSnake.moveFast + 1
	end
end

-- ----------------------------------------------------------------------------
local function snakeGrowExp(aSnake)
-- ----------------------------------------------------------------------------
	if  aSnake.growNone > 0 then
		aSnake.growNone = aSnake.growNone - 1
	end

	if  aSnake.growEx > 0 then
		aSnake.growEx = aSnake.growEx - 1
		if  aSnake.growEx == 0 then
			aSnake.grow = false
		end
	end
end

-- ----------------------------------------------------------------------------
-- ROUTINES - HUD
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
local function realiseLevelTime()
-- ----------------------------------------------------------------------------
	local iSeconds = math.floor(iLevelTimer / 5)
	local iMins = math.floor(iSeconds / 60)
	iSeconds = iSeconds - (iMins * 60)
	local iSecTens = math.floor(iSeconds / 10)
	local iSecOnes = iSeconds - (iSecTens * 10)

	sLevelTime = string.format("%1d   %1d %1d", iMins, iSecTens, iSecOnes)
end

--local function updateHUD()
--	realiseLevelTime()
--	updateText({10, -2}, sLevelTime)
--end

-- ----------------------------------------------------------------------------
local function realiseHUD()
-- ----------------------------------------------------------------------------
	if  iGameMode ~= tGAMEMODE.attract then
		if bHUDTitleText then
			clearText({10, -3}, 9)
			clearText({10, -2}, 9)
			bHUDTitleText = false
		end

		realiseLevelTime()

		if  not bHUD then
			realiseText({10, -2}, 9, sLevelTime)
			colourText({10, -2}, 7, tLevelTimeStrobe[iLevelTimeTick + 1])
			bHUD = true
		else
			updateText({10, -2}, sLevelTime)
		end

		if bHUDAnnounce then
			if not bHUDAnnounceText then
				iHUDAnnceStrbIdx = #tTitle1Strobe - 5
				iHUDAnnceTick = 0

				realiseText({10, 8}, 9, sHUDAnnounce)
				colourText({10, 8}, string.len(sHUDAnnounce), tTitle1Strobe[iHUDAnnceStrbIdx])
				bHUDAnnounceText = true
			else
				iHUDAnnceTick = iHUDAnnceTick + 1
				if iHUDAnnceTick == 3 then
					iHUDAnnceStrbIdx = iHUDAnnceStrbIdx - 1
					iHUDAnnceTick = 0
					colourText({10, 8}, string.len(sHUDAnnounce), tTitle1Strobe[iHUDAnnceStrbIdx])
				end

				if  iHUDAnnceStrbIdx == 0 then
					bHUDAnnounce = false

					bGameRun = true

					if bHUDAnnounceText then
						clearText({10, 8}, 9)
						bHUDAnnounceText = false
					end
				end
			end
		end
	else
		if not bHUDTitleText then
			realiseText({10, -3}, 9, "SNAKE CHALLENGE")
			colourText({10, -3}, 15, tTitle1Strobe[iTitle1StrbIdx])
			realiseText({10, -2}, 9, "DUO")
			colourText({10, -2}, 3, tTitle2Strobe[iTitle2StrbIdx])
			bHUDTitleText = true
		else
			iTitle1StrbIdx = iTitle1StrbIdx + iTitle1StrbDelta
			if iTitle1StrbIdx == 0 then
				iTitle1StrbIdx = 2
				iTitle1StrbDelta = 1
			elseif iTitle1StrbIdx > #tTitle1Strobe then
				iTitle1StrbIdx = #tTitle1Strobe - 1
				iTitle1StrbDelta = -1
			end

			colourText({10, -3}, 15, tTitle1Strobe[iTitle1StrbIdx])
			colourText({10, -2}, 3, tTitle2Strobe[iTitle2StrbIdx])
		end
	end

	if not bHUDScoreText then
		realiseText({10, 18}, 9, string.format("%09d", iGameHighScore))
		colourText({10, 18}, 9, tTitle2Strobe[iTitle2StrbIdx])
		bHUDScoreText = true
	else
		colourText({10, 18}, 9, tTitle2Strobe[iTitle2StrbIdx])
	end

	if  (tPlayer1.alive
	and bGameRun)
	or bHUDAnnounce then
		if tPlayer1.textStart then
			clearText({0, 18}, 9)
			tPlayer1.textStart = false
		end
	else
		if not tPlayer1.textStart then
			realiseText({0, 18}, 9, sGameBanner)
			tPlayer1.textStart = true
		end
		colourText({0, 18}, string.len(sGameBanner), tGameStrobe[iGameStrbIdx])
	end

	if  (tPlayer2.alive
	and bGameRun)
	or bHUDAnnounce then
		if tPlayer2.textStart then
			clearText({20, 18}, 9)
			tPlayer2.textStart = false
		end
	else
		if not tPlayer2.textStart then
			realiseText({20, 18}, 9, sGameBanner)
			tPlayer2.textStart = true
		end
		colourText({20, 18}, string.len(sGameBanner), tGameStrobe[iGameStrbIdx])
	end

--	if bGameRun then
		if tPlayer1.textScore then
			colourText({0, 20}, 9, tTitle2Strobe[iTitle2StrbIdx])
		end

		if tPlayer2.textScore then
			colourText({20, 20}, 9, tTitle2Strobe[iTitle2StrbIdx])
		end
--	end

	iGameStrbIdx = iGameStrbIdx + iGameStrbDelta
	if iGameStrbIdx == 0 then
		iGameStrbIdx = 2
		iGameStrbDelta = 1
	elseif iGameStrbIdx > #tGameStrobe then
		iGameStrbIdx = #tGameStrobe - 1
		iGameStrbDelta = -1
	end

	iTitle2StrbIdx = iTitle2StrbIdx + iTitle2StrbDelta
	if iTitle2StrbIdx == 0 then
		iTitle2StrbIdx = 2
		iTitle2StrbDelta = 1
	elseif iTitle2StrbIdx > #tTitle2Strobe then
		iTitle2StrbIdx = #tTitle2Strobe - 1
		iTitle2StrbDelta = -1
	end
end

-- ----------------------------------------------------------------------------
-- ROUTINES - LEVEL
-- ----------------------------------------------------------------------------


-- ----------------------------------------------------------------------------
local function levelDrawLine(aPos1, aPos2, c)
-- ----------------------------------------------------------------------------
--
-- source: rosettacode.org
--
-- ----------------------------------------------------------------------------
	local dx, sx = math.abs(aPos2[1] - aPos1[1]), aPos1[1] < aPos2[1] and 1 or -1
	local dy, sy = math.abs(aPos2[2] - aPos1[2]), aPos1[2] < aPos2[2] and 1 or -1
	local err = math.floor((dx > dy and dx or -dy) / 2)

	while true do
		tUpdTiles[aPos1[2] + 1][aPos1[1] + 1] = {2, c}

		if (aPos1[1] == aPos2[1] and aPos1[2] == aPos2[2]) then
			break
		end

		if (err > -dx) then
			err, aPos1[1] = err - dy, aPos1[1] + sx
			if (aPos1[1] == aPos2[1] and aPos1[2] == aPos2[2]) then
				tUpdTiles[aPos1[2] + 1][aPos1[1] + 1] = {2, c}
				break
			end
		end

		if (err < dy) then
			err, aPos1[2] = err + dx, aPos1[2] + sy
		end
	end
end

-- ----------------------------------------------------------------------------
function levelGenA(aProgress, aPlayerCnt, aActive)
-- ----------------------------------------------------------------------------
	local iLenX = math.min((aProgress + 1) * 2, 8) - 1
	local iLenY = math.min(aProgress + 1, 5) - 1

	local tPos1 = {3, 7}
	local tPos2 = {3 + iLenX, 7}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {24, 8}
	tPos2 = {24 - iLenX, 8}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {14, 2}
	tPos2 = {14, 2 + iLenY}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {13, 13}
	tPos2 = {13, 13 - iLenY}
	levelDrawLine(tPos1, tPos2, 1)
end

-- ----------------------------------------------------------------------------
function levelGenB(aProgress, aPlayerCnt, aActive)
-- ----------------------------------------------------------------------------
	local iLenY = math.min((aProgress + 1) * 2, 8) - 1
	local iLenX = math.min(aProgress + 1, 5) - 1

	local tPos1 = {5, 2}
	local tPos2 = {5, 2 + iLenY}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {22, 13}
	tPos2 = {22, 13 - iLenY}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {15, 7}
	tPos2 = {15 + iLenX, 7}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {12, 8}
	tPos2 = {12 - iLenX, 8}
	levelDrawLine(tPos1, tPos2, 1)
end

-- ----------------------------------------------------------------------------
function levelGenC(aProgress, aPlayerCnt, aActive)
-- ----------------------------------------------------------------------------
	local iLenY = math.min(aProgress + 1, 5) - 1
	local iLenX = math.min((aProgress + 1) * 2, 9)

	local iLenY2 = math.ceil(iLenX / 3)
	iLenX = iLenX - 1

	local tPos1 = {2, 13}
	local tPos2 = {2 + iLenX, 13 - iLenY2}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {25, 2}
	tPos2 = {25 - iLenX, 2 + iLenY2}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {6, 2}
	tPos2 = {6, 2 + iLenY}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {21, 13}
	tPos2 = {21, 13 - iLenY}
	levelDrawLine(tPos1, tPos2, 1)
end

-- ----------------------------------------------------------------------------
function levelGenD(aProgress, aPlayerCnt, aActive)
-- ----------------------------------------------------------------------------
	local iLenY = math.min(aProgress + 1, 5) - 1
	local iLenX = math.min((aProgress + 1) * 2, 9)

	local iLenY2 = math.ceil(iLenX / 3)
	iLenX = iLenX - 1

	local tPos1 = {2, 2}
	local tPos2 = {2 + iLenX, 2 + iLenY2}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {25, 13}
	tPos2 = {25 - iLenX, 13 - iLenY2}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {6, 13}
	tPos2 = {6, 13 - iLenY}
	levelDrawLine(tPos1, tPos2, 1)

	tPos1 = {21, 2}
	tPos2 = {21, 2 + iLenY}
	levelDrawLine(tPos1, tPos2, 1)
end

local gameUpdateMode

-- ----------------------------------------------------------------------------
local function realiseLevel()
-- ----------------------------------------------------------------------------
	if bGameRun then
		if bGameOver then
			if iGameMode == tGAMEMODE.battle then
				if  tPlayer1.alive then
					gameUpdateMode(tPlayer1, tGAMEMODE.single)
				else
					gameUpdateMode(tPlayer2, tGAMEMODE.single)
				end
			else
				bGameRun = false
				bGameReset = true
			end
		elseif bGameNext then
			bGameNext = false

			if (iGameMode == tGAMEMODE.single)
			or ((iGameMode == tGAMEMODE.battle)
			and (tPlayer1.lives > 0)
			and (tPlayer2.lives > 0)) then
				initLevel()
			end
		end
	end

	if iGameMode == tGAMEMODE.attract then
		if tPlayer1.reqStart then
			iGameMode = tGAMEMODE.single

			tPlayer1.score = 0
			tPlayer1.bonus = 0
			tPlayer1.lives = 3
			tPlayer1.livesPush = 3

			tPlayer1.alive = true

			commands.execAsync("title "..tPlayer1.id.." times 0.5s 5s 0.5s")
			notifyPlayerEntry(tPlayer1.id)
			tPlayer1.best = getPlayerBestScore(tPlayer1.id)

			initLevel()
		elseif tPlayer2.reqStart then
			iGameMode = tGAMEMODE.single

			tPlayer2.score = 0
			tPlayer2.bonus = 0
			tPlayer1.lives = 3
			tPlayer1.livesPush = 3

			tPlayer2.alive = true

			commands.execAsync("title "..tPlayer2.id.." times 0.5s 5s 0.5s")
			notifyPlayerEntry(tPlayer2.id)
			tPlayer2.best = getPlayerBestScore(tPlayer2.id)

			initLevel()
		end

		if  (iLevelTimer == 0) then
			bGameReset = true
			bGameStart = false
		end

		iSnakeMoveMax = iGameSpeed - 1
	elseif bGameRun then
		if (tPlayer1.alive)
		and (tPlayer1.lives == 0) then
			tPlayer1.alive = false

			bHUDAnnounce = true
			if iGameMode == tGAMEMODE.single then
				sHUDAnnounce = "GAME OVER"
			else
				sHUDAnnounce = "2P WINS"
			end

			bGameOver = true
			bGameRun = false
		end

		if (tPlayer2.alive)
		and (tPlayer2.lives == 0) then
			tPlayer2.alive = false

			bHUDAnnounce = true
			if iGameMode == tGAMEMODE.single then
				sHUDAnnounce = "GAME OVER"
			else
				sHUDAnnounce = "1P WINS"
			end

			bGameOver = true
			bGameRun = false
		end

		if	(not bGameReset)
		and (not bGameOver) then
			if  (iGameMode == tGAMEMODE.single)
			and not tPlayer1.alive
			and tPlayer1.reqStart then
				gameUpdateMode(tPlayer2, tGAMEMODE.battle)
				commands.execAsync("title "..tPlayer1.id.." times 0.5s 5s 0.5s")
				notifyPlayerEntry(tPlayer1.id)
				tPlayer1.best = getPlayerBestScore(tPlayer1.id)
			end

			if  (iGameMode == tGAMEMODE.single)
			and not tPlayer2.alive
			and tPlayer2.reqStart then
				gameUpdateMode(tPlayer1, tGAMEMODE.battle)

				commands.execAsync("title "..tPlayer2.id.." times 0.5s 5s 0.5s")
				notifyPlayerEntry(tPlayer2.id)
				tPlayer2.best = getPlayerBestScore(tPlayer2.id)
			end
		end
	end

	if (iGameMode ~= tGAMEMODE.attract)
	and (not bHUDAnnounce) then
		if tPlayer1.alive
		and tPlayer1.reqStart then
--			if tPlayer2.alive and tPlayer2.reqStart then
--				TOASTIE!
--			end
			bGameRun = not bGameRun
		elseif tPlayer2.alive
		and tPlayer2.reqStart then
			bGameRun = not bGameRun
		end
	end

	tPlayer1.reqStart = false
	tPlayer2.reqStart = false
end

-- ----------------------------------------------------------------------------
-- ROUTINES - GAME
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
function gameUpdateMode(aTarget, aMode)
-- ----------------------------------------------------------------------------
	iGameDebug = 0
	iGameTick = 0

	if aMode == tGAMEMODE.attract then
		bGameRun = true

		iGameMode = tGAMEMODE.attract
		bGameOver = false
		bGameNext = false

		iLevelCurrent = 0
		iLevelProgress = iGameDifficulty
		iLevelIdx = 0

		initPlayers()
		initLevel()
	elseif aMode == tGAMEMODE.single then
--		Coming back to single from battle
		iLevelCurrent = aTarget.levelCurr
		iLevelProgress = aTarget.levelProg
		iLevelIdx = aTarget.levelIdx
		aTarget.lives = aTarget.livesPush

		iGameMode = tGAMEMODE.single
		bGameOver = false
		bGameNext = false

		initLevel()
	else
--		Going to battle from single
--		aTarget.levelCurr = iLevelCurrent
--		aTarget.levelProg = iLevelProgress
--		aTarget.levelIdx = iLevelIdx
		aTarget.livesPush = aTarget.lives

		iLevelCurrent = 0
		iLevelProgress = iGameDifficulty
		iLevelIdx = 0

		tPlayer1.lives = 2
		tPlayer2.lives = 2

		if not tPlayer1.alive then
			tPlayer1.alive = true
			tPlayer1.score = 0
			tPlayer1.textScore = false
			tPlayer1.bonus = 0
			tPlayer1.levelCurr = 0
			tPlayer1.levelProg = iGameDifficulty
			tPlayer1.levelIdx = 0
--			tPlayer1.id = ""
		else
			tPlayer2.alive = true
			tPlayer2.score = 0
			tPlayer2.textScore = false
			tPlayer2.bonus = 0
			tPlayer2.levelCurr = 0
			tPlayer2.levelProg = iGameDifficulty
			tPlayer2.levelIdx = 0
--			tPlayer2.id = ""
		end

		iGameMode = tGAMEMODE.battle
		bGameOver = false
		bGameNext = false

		initLevel()
	end
end

-- ----------------------------------------------------------------------------
local function resetTick()
-- ----------------------------------------------------------------------------
	bGameReset = false

	bHUD = false
	bHUDAnnounce = false
	sHUDAnnounce = ""
	bHUDAnnounceText = false
	iHUDAnnceStrbIdx = 0
	iHUDAnnceTick = 0

	gameUpdateMode(aPlayer1, tGAMEMODE.attract)
end

-- ----------------------------------------------------------------------------
local function effectsTick()
-- ----------------------------------------------------------------------------
	snakeInvunExp(tSnake1P)
	snakeInvunExp(tSnake2P)

	snakeFastExp(tSnake1P)
	snakeFastExp(tSnake2P)

	snakeGrowExp(tSnake1P)
	snakeGrowExp(tSnake2P)
end

-- ----------------------------------------------------------------------------
local function playersTick()
-- ----------------------------------------------------------------------------
	local iTexIdx

	if tPlayer1.alive
	and (tPlayer1.input ~= 0) then
		if  tSnake1P.visible then
			tSnake1P.look = tSnakeFace[tSnake1P.move][tPlayer1.input]
			iTexIdx = tSnakeLook[tSnake1P.look]
			updateTile(tSnake1P.body[1], 0, iTexIdx)

--			tPlayer1.input = 0
		end
	end

	if tPlayer2.alive
	and (tPlayer2.input ~= 0) then
		if  tSnake2P.visible then
			tSnake2P.look = tSnakeFace[tSnake2P.move][tPlayer2.input]
			iTexIdx = tSnakeLook[tSnake2P.look]
			updateTile(tSnake2P.body[1], 1, iTexIdx)

--			tPlayer2.input = 0
		end
	end
end

-- ----------------------------------------------------------------------------
local function objectsTick()
-- ----------------------------------------------------------------------------
	local bCollideEachOther = false

	local tPos1 = {0, 0}
	tPos1[1] = tSnake1P.body[1][1]
	tPos1[2] = tSnake1P.body[1][2]

	local tPos2 = {0, 0}
	tPos2[1] = tSnake2P.body[1][1]
	tPos2[2] = tSnake2P.body[1][2]

	tPos1[1] = tPos1[1] + tSnakeMove[tSnake1P.look][1]
	tPos1[2] = tPos1[2] + tSnakeMove[tSnake1P.look][2]
	tPos2[1] = tPos2[1] + tSnakeMove[tSnake2P.look][1]
	tPos2[2] = tPos2[2] + tSnakeMove[tSnake2P.look][2]

--	clearSnake(tSnake1P)
--	clearSnake(tSnake2P)

	if tSnake1P.visible then
		if tSnake1P.moveTick == 0 then
			if  tPos1[1] == tPos2[1]
			and tPos1[2] == tPos2[2] then
				if tSnake2P.visible then
					tSnake1P.collide = true
					bCollideEachOther = true
				end
			end

			snakeCheckCollide(tSnake1P, tPos1, tPlayer1)
			snakeCheckEat(tSnake1P, tPos1, tPlayer1)
			snakeMove(tSnake1P, tPos1)

			tSnake1P.moveTick = iSnakeMoveMax
			if tSnake1P.moveFast >= 18 then
				tSnake1P.moveTick = tSnake1P.moveTick - 2
			elseif  tSnake1P.moveFast > 0 then
				tSnake1P.moveTick = tSnake1P.moveTick - 1
			elseif tSnake1P.moveFast < 0 then
				tSnake1P.moveTick = tSnake1P.moveTick + 1
			end

			if  tSnake1P.moveTick < 0 then
				tSnake1P.moveTick = 0
			end

			realiseSpeed({0, 20}, tSnake1P)

			tPlayer1.input = 0
		else
			tSnake1P.moveTick = tSnake1P.moveTick - 1
		end
	end

	if tSnake2P.visible then
		if tSnake2P.moveTick == 0 then
			if  tPos1[1] == tPos2[1]
			and tPos1[2] == tPos2[2] then
				if tSnake1P.visible then
					tSnake2P.collide = true
					bCollideEachOther = true
				end
			end

			snakeCheckCollide(tSnake2P, tPos2, tPlayer2)
			snakeCheckEat(tSnake2P, tPos2, tPlayer2)
			snakeMove(tSnake2P, tPos2)

			tSnake2P.moveTick = iSnakeMoveMax
			if tSnake2P.moveFast >= 18 then
				tSnake2P.moveTick = tSnake2P.moveTick - 2
			elseif  tSnake2P.moveFast > 0 then
				tSnake2P.moveTick = tSnake2P.moveTick - 1
			elseif tSnake2P.moveFast < 0 then
				tSnake2P.moveTick = tSnake2P.moveTick + 1
			end

			if  tSnake2P.moveTick < 0 then
				tSnake2P.moveTick = 0
			end

			realiseSpeed({20, 20}, tSnake2P)

			tPlayer2.input = 0
		else
			tSnake2P.moveTick = tSnake2P.moveTick - 1
		end
	end

	snakeApplyCollide(bCollideEachOther)

	if  #tSnake1P.body >= #tSnake2P.body then
		realiseSnake(tSnake2P, 1)
		realiseSnake(tSnake1P, 0)
	else
		realiseSnake(tSnake1P, 0)
		realiseSnake(tSnake2P, 1)
	end
end

-- ----------------------------------------------------------------------------
local function levelExpireTiles()
-- ----------------------------------------------------------------------------
	for y = 1, 18 do
		for x = 1, 30 do
			local iTile = tLevelTiles[y][x]

			if  iTile == 1 then
				if tUpdTiles[y][x][1] == 2 then
					iLevelBees = iLevelBees - 1
				else
					iLevelBonus = iLevelBonus - 1
				end

				tLevelTiles[y][x] = 0
				tUpdTiles[y][x] = {-1, 0}
			elseif iTile > 1 then
				tLevelTiles[y][x] = iTile - 1
			end
		end
	end
end

-- ----------------------------------------------------------------------------
local function isOutsideRect(aRect, aPos)
-- ----------------------------------------------------------------------------
	if  (aPos[1] < aRect[1]
	or aPos[1] > aRect[3])
	and (aPos[2] < aRect[2]
	or aPos[2] > aRect[4]) then
		return true
	else
		return false
	end
end

-- ----------------------------------------------------------------------------
local function checkPlaceBee(aPos)
-- ----------------------------------------------------------------------------
	local bResult = (tUpdTiles[aPos[2] + 1][aPos[1] + 1][1] == -1)
	local tRect = {}

	if  tSnake1P.visible then
		tRect = {tSnake1P.body[1][1] - 2, tSnake1P.body[1][2] - 2,
				tSnake1P.body[1][1] + 2, tSnake1P.body[1][2] + 2}
		if bResult then
			bResult = isOutsideRect(tRect, aPos)
		end
	end

	if tSnake2P.visible then
		tRect = {tSnake2P.body[1][1] - 2, tSnake2P.body[1][2] - 2,
				tSnake2P.body[1][1] + 2, tSnake2P.body[1][2] + 2}
		if bResult then
			bResult = isOutsideRect(tRect, aPos)
		end
	end

	return bResult
end

-- ----------------------------------------------------------------------------
local function levelTick()
-- ----------------------------------------------------------------------------
	local tPos = {}

	if (not bGameOver)
	and (not bGameNext) then
		iLevelTimer = iLevelTimer - 1

		if  iGameMode == tGAMEMODE.attract then
			snakeMenu(tSnake1P)
			snakeMenu(tSnake2P)
		else
			if bHUD then
				colourText({10, -2}, 7, tLevelTimeStrobe[iLevelTimeTick + 1])
			end

			if  (iLevelTimer == 0) then
				bGameNext = true
			end

			if  iLevelTimer == 150 then
				iLevelBeesMax = iLevelBeesMax + 2
				iSnakeMoveMax = iGameSpeed - 1
			end

			iLevelTimeTick = iLevelTimeTick - 1
			if iLevelTimeTick == -1 then
				iLevelTimeTick = 4
			end
		end

		if iLevelTick > iLevelMax then
			iLevelTick = 0
			levelExpireTiles()
		else
			iLevelTick = iLevelTick + 1
		end

		if iLevelBonus < 5 then
			if  math.random(0, (iLevelMax + 1) * 2 - 1) == 0 then
				tPos = {0, 0}

				tPos[1] = math.random(0, 27)
				tPos[2] = math.random(0, 15)

				if  tUpdTiles[tPos[2] + 1][tPos[1] + 1][1] == -1 then
					iLevelBonus = iLevelBonus + 1

					updateTile(tPos, 3, math.random(0, 3))
					tLevelTiles[tPos[2] + 1][tPos[1] + 1] = math.random(16,28)
				end
			end
		end

		if iLevelBees < iLevelBeesMax then
			if math.random(0, (iLevelMax + 1) * 2 - 1) == 0 then
				tPos = {0, 0}

				tPos[1] = math.random(0, 27)
				tPos[2] = math.random(0, 15)

				if  checkPlaceBee(tPos) then
					iLevelBees = iLevelBees + 1

					updateTile(tPos, 2, 2)
					tLevelTiles[tPos[2] + 1][tPos[1] + 1] = math.random(8,16)
				end
			end
		end
	end
end

local function startTick()
	local tRectL = getLayerRect()

	for i = 1, 28 do
		tCurTiles[11][i] = {-1, 1}
		tCurTiles[12][i] = {-1, 1}
	end

	for i = 1, #tGameSaverS do
		local tRectO = {tRectL[1] + 2 + i * 2, tRectL[2] - 14, tRectL[1] + 3 + i * 2, tRectL[2] - 15}
		if tGameSaverS[i] == 1 then
			cmdFillLayer(2, tRectO, "rechiseled:glowstone_smooth_connecting")
		else
			cmdFillLayer(2, tRectO, "minecraft:air")
		end
	end

	if  iGameSaverD == 1 then
		if iGameSaverA == (iGameSaverB + 9) then
			if  iGameSaverB == 0 then
				iGameSaverD = -1
				iGameSaverA = 9
				iGameSaverB = 10
			else
				iGameSaverA = iGameSaverB
				iGameSaverB = iGameSaverB - 1
			end
		else
			tGameSaverS[iGameSaverA] = 0
			iGameSaverA = iGameSaverA + 1
			tGameSaverS[iGameSaverA] = 1
		end
	else
		if iGameSaverA == (iGameSaverB - 9) then
			if  iGameSaverB == 13 then
				iGameSaverD = 1
				iGameSaverA = 4
				iGameSaverB = 3
			else
				iGameSaverA = iGameSaverB
				iGameSaverB = iGameSaverB + 1
			end
		else
			tGameSaverS[iGameSaverA] = 0
			iGameSaverA = iGameSaverA - 1
			tGameSaverS[iGameSaverA] = 1
		end
	end
end

-- ----------------------------------------------------------------------------
-- THREAD - GAME
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
local function threadGame()
-- ----------------------------------------------------------------------------
	if bGameReset then
		resetTick()
	end

	if bGameStart then
		realiseHUD()
		realiseLevel()

		if  bGameRun then
			if iGameTick == 0 then
				effectsTick()
				playersTick()
			elseif iGameTick == 1 then
				playersTick()
			elseif iGameTick == 2 then
				playersTick()
				objectsTick()
			elseif iGameTick == 3 then
				levelTick()
			else
				iGameTick = -1
			end

			iGameTick = iGameTick + 1
		end

		realiseTiles()
--		os.sleep(0.05)
	else
		startTick()
--		os.sleep(0.05)
	end
end

-- ----------------------------------------------------------------------------
-- THREAD - COMMS
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
local function handleClientMsg(aMessage)
-- ----------------------------------------------------------------------------
	local sStr = ""
	local tClient = {}

	for sStr in string.gmatch(aMessage, "([^,]+)") do
		table.insert(tClient, tonumber(sStr))
	end

	if  tClient[1] ~= 0 then
		tPlayer1.input = tClient[1]
	end

	if  tClient[2] == 1 then
		entitiesInControl(tControls[1])

		if  #tEntities == 1 then
			tPlayer1.reqStart = true
			tPlayer1.id = tEntities[1].id
		end

		tPlayer1.input = 0
	end

	if  tClient[3] ~= 0 then
		tPlayer2.input = tClient[3]
	end

	if  tClient[4] == 1 then
		entitiesInControl(tControls[2])

		if  #tEntities == 1 then
			tPlayer2.reqStart = true
			tPlayer2.id = tEntities[1].id
		end

		tPlayer2.input = 0
	end

	if  tClient[1] ~= 0
	or tClient[2] ~= 0
	or tClient[3] ~= 0
	or tClient[4] ~= 0 then
		print("INCOMING:  ".. tostring(tClient[1]).." ".. tostring(tClient[2]).. tostring(tClient[3]).." ".. tostring(tClient[4]))
	else
--		term.write(".")
	end
end

-- ----------------------------------------------------------------------------
local function threadComms()
-- ----------------------------------------------------------------------------
	local event, side, channel, replyChannel, message, distance

	event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

	if channel == (iBaseChan + 40) then
		handleClientMsg(message)
	elseif channel == (iBaseChan + 50) then
		_, _, sMsg = string.find(message, "(%d+)")
		iMsg = tonumber(sMsg)
		if  iMsg == 1 then
			bGameStart = not bGameStart
		else
			bGameReset = true
			bGameStart = true
		end
	end
end

-- ----------------------------------------------------------------------------
-- MAIN
-- ----------------------------------------------------------------------------

initScoreboard()

pModem = peripheral.wrap(sBaseModem) or error("Unable to attach modem!", 0)
pModem.open(iBaseChan + 40)
pModem.open(iBaseChan + 50)

initCmdPos()

while true do
	parallel.waitForAll(threadGame, threadComms)
--	os.sleep(0.05)
end
