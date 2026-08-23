local iBaseChan = 700
local sBaseWiFi = "right"
local pWiFi

local tInputs = {false, false, false}
local iLastInp = 0
local iLastBtn = 0
local bInpDebug = false
local iInpYield = 0

pWiFi = peripheral.wrap(sBaseWiFi) or error("Unable to attach wifi!", 0)

while true do
	local sMsg = ""
	local bRs = false
	local bPressed = false

	iLastInp = 0
	iLastBtn = 0

	bInpDebug = false

	bRS = rs.getInput("left")
	bPressed = bPressed or bRS

	if  (not tInputs[1])
	and bRS then
		tInputs[1] = true
		iLastInp = 1
		bInpDebug = true
	elseif not bRS then
		tInputs[1] = false
	end

	bRS = rs.getInput("right")
	bPressed = bPressed or bRS

	if  (not tInputs[2])
	and bRS then
		tInputs[2] = true
		iLastInp = 2
		bInpDebug = true
	elseif not bRS then
		tInputs[2] = false
	end

--	if  (not tInputs[1])
--	and (not tInputs[2]) then
--		iLastInp = 0
--	end

	bRS = rs.getInput("back")
	bPressed = bPressed or bRS

	if  (not tInputs[3])
	and bRS then
		tInputs[3] = true
		iLastBtn = 1
		bInpDebug = true
	elseif not bRS then
		tInputs[3] = false
	end

	if (iLastInp ~= 0)
	or (iLastBtn ~= 0) then
		sMsg = tostring(iLastInp)..","..tostring(iLastBtn)
		print(sMsg)
		pWiFi.transmit(iBaseChan + 20, iBaseChan + 21, sMsg)
		iInpYield = 1000
	end

	if bPressed then
		rs.setOutput("front", true)
	else
		rs.setOutput("front", false)
	end

	if  iInpYield  >= 1000 then
		iInpYield = 0
		os.sleep(0.05)
	end

	iInpYield = iInpYield + 1
end
