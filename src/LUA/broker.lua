local iBaseChan = 700
local sBaseModem = "front"
local pModem
local sBaseWiFi = "right"
local pWiFi

local tControls = {{0, 0}, {0, 0}}
local iIgnoreL = 0
local iIgnoreB = 0


local function handleMsg(aPlayer, aMsg)
	local sStr = ""
	local tButtons = {}

	for sStr in string.gmatch(aMsg, "([^,]+)") do
		table.insert(tButtons, tonumber(sStr))
	end

	tControls[aPlayer][1] = tButtons[1]
	tControls[aPlayer][2] = tButtons[2]
end

local function threadMain()
--	while true do

	if  rs.getInput("left") then
		if iIgnoreL == 0 then
			print("RESET!")
			pModem.transmit(iBaseChan + 50, iBaseChan + 51, "0")
		end

		iIgnoreL = 10
	elseif rs.getInput("back") then
		if iIgnoreB == 0 then
			print("PLAY/PAUSE!")
			pModem.transmit(iBaseChan + 50, iBaseChan + 51, "1")
		end

		iIgnoreB = 10
	else
		sMsg = tostring(tControls[1][1])..","..tostring(tControls[1][2])..","..tostring(tControls[2][1])..","..tostring(tControls[2][2])

		if  tControls[1][1] ~= 0
		or tControls[1][2] ~= 0
		or  tControls[2][1] ~= 0
		or tControls[2][2] ~= 0 then
			print("OUTGOING: ".. sMsg)
		end

		pModem.transmit(iBaseChan + 40, iBaseChan + 41, sMsg)
		tControls[1][1] = 0
		tControls[1][2] = 0
		tControls[2][1] = 0
		tControls[2][2] = 0
	end

	if iIgnoreL > 0 then
		iIgnoreL = iIgnoreL - 1
	end

	if iIgnoreB > 0 then
		iIgnoreB = iIgnoreB - 1
	end

	os.sleep(0.05)

--	end
end

local function threadComms()
    local event, side, channel, replyChannel, message, distance

    event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

	print("INCOMING: "..message)

    if channel == (iBaseChan + 10) then
        handleMsg(1, message)
    elseif channel == (iBaseChan + 20) then
		handleMsg(2, message)
	end
end

pModem = peripheral.wrap(sBaseModem) or error("Unable to attach modem!", 0)
pWiFi = peripheral.wrap(sBaseWiFi) or error("Unable to attach wifi!", 0)

pWiFi.open(iBaseChan + 10)
pWiFi.open(iBaseChan + 20)

while true do
	parallel.waitForAny(threadMain, threadComms)
--	os.sleep(0.05)
end
