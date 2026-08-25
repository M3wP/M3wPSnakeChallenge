;===============================================================================
; snake_game.s - Snake Challenge QUADRO, game-specific content
;
; Everything in framework/*.s is generic across games; everything here is
; specific to THIS game. Scaffolding pass plus the board row-fetch sync
; protocol (2026-08-24) - still not the real tile/movement simulation,
; see the project's own design-decision notes (spectator/4-corner slot
; model, 6 ticks/sec, delta broadcast, 30x18 board). Defines the six
; things framework/*.s expects a game to provide:
;
;   gameTilesLoadHack  - load tile/sprite graphics into VRAM at boot
;                        (fw_startup.s) - stub, no tile art yet.
;   gameLoadPalette    - unpack this game's palette into $D100-$D3FF
;                        (fw_startup.s) - stub, no palette asset yet.
;   gameStateInit      - zero this game's own BSS state at boot
;                        (fw_startup.s, via initCore).
;   gameResetPlayGame  - reset local UI state on disconnect/leave
;                        (fw_ctrls_net.s).
;   gameProcPlayMsg    - mcPlay message dispatch for everything except
;                        chat, which framework already handles generically
;                        (fw_ctrls_net.s's clientProcPlayMsg). Handles
;                        GameStatus/$06, SlotStatus/$07, BoardRowsData/
;                        $0B - see the BOARD SYNC section below.
;   gamePollTick       - called once per main-loop iteration, regardless
;                        of state (fw_ctrls_net.s's main/@loop) - used
;                        here to notice a dropped BoardRowsReq and retry.
;
; Also defines page_ovrvw and page_detail - framework's page_play always
; navigates to a page named page_ovrvw (see fw_ui_shell.s), and this
; game's own page_ovrvw navigates on to page_detail, mirroring chess's
; original page-name contract. Both are placeholder content only - the
; real 4-corner spectator overview and the actual board rendering are
; still follow-up work; what IS real now is the board data itself being
; synced into boardTiles behind the scenes, ready for that rendering
; work to read once it exists.
;===============================================================================


;===============================================================================
; GAME HOOKS
;===============================================================================

;-------------------------------------------------------------------------------
;	gameTilesLoadHack - stub. No Snake QUADRO tile/sprite asset exists
;	yet (see the project's PETSCII-only note - the custom font/tileset
;	is being redone for this game, not reused from chess). Chess's
;	original (piecesLoadHack) DMA-copied ChessPiecesArray.bin's 3072
;	bytes from the tail of CODE to $010800 - a future version of this
;	hook does the equivalent for Snake's own tile sheet.
;-------------------------------------------------------------------------------
gameTilesLoadHack:
;-------------------------------------------------------------------------------
		RTS


;-------------------------------------------------------------------------------
;	gameLoadPalette - stub. No Snake QUADRO palette asset exists yet -
;	see chess's original palloop (removed from fw_startup.s) for the
;	$D100/$D200/$D300 unpack shape a future version of this hook should
;	follow once there's a real .pal file to .incbin.
;-------------------------------------------------------------------------------
gameLoadPalette:
;-------------------------------------------------------------------------------
		RTS


;-------------------------------------------------------------------------------
;	gameStateInit - zeroes this file's own BSS state (see the BOARD
;	SYNC section below). Called from initCore, after initScreen/
;	initSprites, before initUser. Doesn't touch boardTiles itself (600
;	bytes, not worth the cycles to clear at boot) - it gets overwritten
;	row-pair at a time as the real sync fills it in, and nothing reads
;	it before that anyway (page_detail is still a placeholder).
;-------------------------------------------------------------------------------
gameStateInit:
;-------------------------------------------------------------------------------
		LDA	#$00
		STA	boardSyncPair
		STA	boardSyncWaiting
		STA	boardSyncDone
		STA	boardSyncReqFrame
		STA	gameState
		STA	gameJoinDone
		STA	gameWatching
		STA	gameBkgPresented
		STA	gameBoardSyncPending

		LDX	#BOARD_ROW_PAIRS - 1
@clrfetched:
		STA	boardFetched, X
		DEX
		BPL	@clrfetched

		LDX	#$03
@clrslots:
		STA	slotStates, X
		STA	slotLives, X
		STA	slotSpeed, X
		DEX
		BPL	@clrslots

;	Not zero - $FF is "none" for both of these, and slot 0 is a real
;	corner. See gameSlotWanted/gameMySlot.
		LDA	#SLOT_CLAIM_NONE
		STA	gameSlotWanted
		STA	gameMySlot

		LDA	#SNAKE_DIR_NONE
		STA	gameLastDir
		STA	gameJoyLast

		RTS


;-------------------------------------------------------------------------------
;	gameResetPlayGame - called on disconnect (inetDisconnected) and
;	after sending Part (clientSendPlayPart) to reset local UI state -
;	chess's original reset ready/colour checkboxes and player-name
;	labels here. Nothing on page_ovrvw/page_detail needs resetting yet,
;	but a sync that's mid-flight (or already believed complete) when
;	the connection drops is stale the moment we reconnect, so stop
;	gamePollTick from retrying against a dead connection and make sure
;	the next GameStatus properly restarts the sync from scratch.
;
;	Also flips button_play_part/button_play_join back (clientPlayPartedSelf,
;	fw_ctrls_net.s) - safe to call unconditionally even on a path where
;	we were never actually joined (e.g. a disconnect before ever
;	joining a board), since toggling an already-correct button state is
;	a no-op, not a double-flip.
;-------------------------------------------------------------------------------
gameResetPlayGame:
;-------------------------------------------------------------------------------
		LDA	#$00
		STA	boardSyncWaiting
		STA	boardSyncDone

;	The next connection's first GameStatus is a fresh join, so the latch
;	has to be armed again or clientPlayJoinedSelf never fires for it.
		STA	gameJoinDone

;	Also forget whatever we'd last told the server about watching -
;	the connection that heard WatchStart is gone, so gamePollTick needs
;	to re-send it (rather than assuming the now-dead server already
;	knows) the moment a fresh connection sees page_detail is current.
		STA	gameWatching
		STA	gameBkgPresented
		STA	gameBoardSyncPending

		JMP	clientPlayPartedSelf
;		RTS


;-------------------------------------------------------------------------------
;	gameProcPlayMsg - clientProcPlayMsg (fw_ctrls_net.s) already
;	handles mcPlay/$0E (GameChat) generically and routes everything
;	else here. Handles the board-sync-related methods that exist so far
;	(see the BOARD SYNC section below); slot-claim and direction input
;	are still TODO, so anything else still falls through to
;	clientProcUnknownMsg.
;-------------------------------------------------------------------------------
gameProcPlayMsg:
;-------------------------------------------------------------------------------
		LDA	imsgdat2
		CMP	#$06
		BEQ	@gamestat

		CMP	#$07
		BEQ	@slotstat

		CMP	#$09
		BEQ	@tiledelta

		CMP	#$0B
		BEQ	@boardrows

		CMP	#$0C
		BEQ	@shake

		JMP	clientProcUnknownMsg
;		RTS

@shake:
		JMP	gameProcShakeMsg

@gamestat:
		JMP	gameProcGameStatusMsg

@slotstat:
		JMP	gameProcSlotStatusMsg

@tiledelta:
		JMP	gameProcTileDeltaMsg

@boardrows:
		JMP	gameProcBoardRowsMsg


;===============================================================================
; BOARD SYNC - row-paginated full-board fetch. A fresh join needs the
; whole 30x18 grid, but the 254-byte payload cap means it can't go in
; one message (600 tile bytes), so the client asks for it 2 rows (60
; bytes) at a time via BoardRowsReq/BoardRowsData (mcPlay/$0A and /$0B -
; see SendBoardRows, SnakeServer.pas), tracking which pairs have arrived
; with boardFetched and retrying a pair that doesn't get answered in
; time (gamePollTick, via FRAMECOUNT). User's own call (2026-08-24): 2
; rows/message, and a client-side retry-on-timeout since TCP alone
; doesn't guarantee THIS layer gets an answer back in a timely way even
; though the underlying transport is reliable.
;
; None of this is read by anything yet - page_detail below is still
; just a placeholder label. This is purely the sync half of the
; pipeline; the render half is follow-up work.
;===============================================================================
BOARD_COLS      = 30
BOARD_ROWS      = 20

;	SlotClaim payload values (see gameSendSlotClaim). ANY asks the
;	server for whichever corner is free; NONE is this client's own
;	"nothing outstanding" marker for gameSlotWanted and never goes on
;	the wire. Same value - they can't be confused because one is only
;	ever sent and the other only ever stored.
SLOT_CLAIM_ANY  = $FF
SLOT_CLAIM_NONE = $FF

;	Direction ordinals - MUST match TSnakeDir's declaration order in
;	SnakeServer.pas (sdUp, sdDown, sdLeft, sdRight), since the ordinal
;	itself is what goes on the wire. NONE is this client's own "stick
;	centred, nothing sent yet" marker and never leaves the machine.
SNAKE_DIR_UP    = 0
SNAKE_DIR_DOWN  = 1
SNAKE_DIR_LEFT  = 2
SNAKE_DIR_RIGHT = 3
SNAKE_DIR_NONE  = $FF

;	LIVES PIPS. dengland picked $DC (2026-08-25) and asked for up to 10,
;	drawn right to left.
;
;	Drawn straight to screen RAM rather than put in the label's text,
;	Written straight to screen RAM by gameLivesPresent, because it CANNOT
;	go through a label: screenASCIIToScreen folds everything from $7F up
;	onto $66, so the reachable output range for label text is only
;	$00..$3F. $DC is not expressible that way at all.
;
;	10 fits the HUD column exactly (each block is $0A wide). A bonus life
;	can push a corner past it, so the present hook clamps.
LIVES_PIP_CHAR  = $DC
LIVES_PIP_MAX   = 10

;	SPEED BAR. The corner's PWR2 row is a left-to-right gauge of how fast
;	that snake is currently moving - one $00A0 solid block per cell
;	(dengland, 2026-08-25). Written straight to screen RAM for the same
;	reason the lives pips are: $A0 is well past what label text can
;	reach.
;
;	The server sends the GEAR (ticks per step, so SMALLER IS FASTER - see
;	SendSlotStatus), not a cell count: how many cells a gear lights up is
;	a display decision and belongs on this side.
;
;	The progression is dengland's own - 1, 1, 1, 2, 2, 3 more cells per
;	gear, i.e. 1, 2, 3, 5, 7, 10 lit. It ACCELERATES on purpose: the six
;	gears are 2.0, 2.4, 3.0, 4.0, 6.0 and 12.0 steps/sec, so an even
;	six-step ramp would badly understate what top gear feels like. It
;	fills the whole 10-wide block exactly at TOP.
;
;	Indexed by the gear byte directly, so entry 0 is the "nobody is
;	playing this corner" case and lights nothing.
SPEED_BAR_CHAR  = $A0

;	COLOURED BY GEAR (dengland, 2026-08-25), not one fixed colour - so
;	the row says how fast you are twice over, by length and by hue, and
;	a speed food reads at a glance without counting cells.
;
;	Red at the bottom through to white at the top, which is a heat ramp:
;	the bar looks like it is being driven harder as it fills. Note two
;	gears deliberately SHARE light green - dengland's own list - so the
;	colour changes at four points along a six-gear ladder rather than
;	every gear, and the ones that do change land where the speed jumps
;	are biggest.
;
;	Raw palette values, not scheme indices - see gameHudFillClr.
gameSpeedClrs:
		.byte	$00				;0 - unclaimed, unused
		.byte	CLR_LOG_C64_WHITE		;1 - TOP      12.0/sec
		.byte	CLR_LOG_C64_LIGHTGREEN		;2 - FASTEST   6.0
		.byte	CLR_LOG_C64_LIGHTGREEN		;3 - FAST      4.0
		.byte	CLR_LOG_C64_YELLOW		;4 - NORMAL    3.0
		.byte	CLR_LOG_C64_ORANGE		;5 - SLOW      2.4
		.byte	CLR_LOG_C64_RED			;6 - VSLOW     2.0

gameSpeedCells:
		.byte	$00			;0 - unclaimed
		.byte	10			;1 - TOP      12.0/sec
		.byte	7			;2 - FASTEST   6.0
		.byte	5			;3 - FAST      4.0
		.byte	3			;4 - NORMAL    3.0
		.byte	2			;5 - SLOW      2.4
		.byte	1			;6 - VSLOW     2.0
SPEED_GEAR_MAX  = 6

;	TPlayerState's psPlaying ordinal (SnakeClasses.pas: psNone, psIdle,
;	psReady, psPreparing, psWaiting, psPlaying, ...) - what SlotStatus
;	reports for a claimed corner.
PLAYER_STATE_PLAYING = 5

;	First snake tile - TILE_SNAKE_BASE in SnakeServer.pas, and the same
;	3 non-snake tiles (floor, wall, attract) that gameTileChars/
;	gameTileColrs open with. Only needed to find a player's own body
;	colour in those tables; the board render itself never needs it,
;	since it indexes by the raw tile value the server sends.
TILE_SNAKE_BASE = 3

BOARD_ROW_PAIRS = 10			;BOARD_ROWS / 2 - fetched 2 rows at a time.
					;	BOARD_ROWS is deliberately EVEN so this
					;	divides exactly and no short final
					;	message or half-pair case exists
					;	anywhere - see SnakeServer.pas' own
					;	board-size comment.

;-------------------------------------------------------------------------------
;	boardTiles - this client's local mirror of the server's tile grid,
;	[row][col], row 0 at the top. Filled in a row-pair at a time by
;	gameProcBoardRowsMsg.
;-------------------------------------------------------------------------------
boardTiles:
		.res	BOARD_ROWS * BOARD_COLS

;	One flag per row-pair (not per row - matches how they're actually
;	fetched/acked). 0 = not yet fetched, 1 = fetched.
boardFetched:
		.res	BOARD_ROW_PAIRS

;	Row-pair index (0..8) a BoardRowsReq is currently in flight for -
;	only meaningful while boardSyncWaiting is set.
boardSyncPair:
		.byte	$00

;	1 = a BoardRowsReq is in flight, waiting on a reply or a timeout.
boardSyncWaiting:
		.byte	$00

;	1 = every row-pair has been fetched at least once - boardTiles is a
;	complete mirror of the server's board. Cleared at the start of
;	every fresh sync (gameBoardSyncStart), e.g. on (re)join.
boardSyncDone:
		.byte	$00

;	FRAMECOUNT ($D7FA, a free-running MEGA65 hardware frame counter -
;	see gamePollTick) snapshot taken when the current in-flight request
;	was sent, so gamePollTick can tell how long it's been waiting.
boardSyncReqFrame:
		.byte	$00

;	Scratch byte for gameSendBoardRowsReq - A doesn't survive
;	inetGetNextSend, so the row index it's asked to send has to be
;	parked somewhere across that call.
gameSendRowTmp:
		.byte	$00

;	Same scratch problem for gameSendSlotClaim's [slot] payload byte.
;	Deliberately NOT sharing gameSendRowTmp: gamePollTick reuses that
;	one as a timeout scratch, and a claim landing between those two
;	uses would corrupt it.
gameSendSlotTmp:
		.byte	$00

;	Which corner this client has asked the server for, or $FF if none is
;	outstanding. Only used to avoid firing a second claim while one is
;	still unanswered - the authoritative answer is always gameMySlot,
;	filled in from the server's own SlotStatus broadcast.
gameSlotWanted:
		.byte	$FF

;	Which corner this client actually HOLDS (0..3), or $FF for none.
;	Set only from SlotStatus's "isyou" byte - never optimistically on
;	send, because a claim can be refused (the corner may have been taken
;	between the press and the message arriving) and a client that
;	assumed success would then show a corner it does not own.
gameMySlot:
		.byte	$FF

;	Which corner's START control is being handled right now - parked by
;	the four per-corner handlers so gameSlotChanged's shared tail knows
;	which one it is. A can't carry it: the STATE_DOWN gate has to read
;	the element and call ctrlsControlDefChanged in between.
gameSlotPressed:
		.byte	$00

;	Scratch for gameSendDirection's payload byte, for the same reason
;	gameSendRowTmp exists - A doesn't survive inetGetNextSend.
gameSendDirTmp:
		.byte	$00

;	The last direction actually SENT, by either input. Shared between
;	gamePollJoystick and gameKeyPress so the two can't each spend a
;	message saying what the other already said.
gameLastDir:
		.byte	$FF

;	The stick's own last position, for edge detection - kept apart from
;	gameLastDir because the stick reads centred the whole time somebody
;	is playing on the keys, and letting that clear the shared record
;	would put a message on the wire for every key auto-repeat.
gameJoyLast:
		.byte	$FF

;	The status line above the board - "LEVEL  1   TIME 1:59" - as the
;	server formatted it (see SendGameStatus). Fixed width, so this is a
;	straight copy with no terminator to write: the NUL is part of the
;	initialised data and never moves.
;
;	label_detail_status points permanently in here, the same arrangement
;	the score rows use.
STATUS_TEXT_LEN = 20

statusText:
		.asciiz	"                    "

;	1 once this client has been told it is in the game. GameStatus used
;	to arrive exactly ONCE, on join, so its arrival WAS the confirmation -
;	but it now carries the level clock and arrives every second, so the
;	join half has to fire only on the first one (see
;	gameProcGameStatusMsg).
gameJoinDone:
		.byte	$00

;	Seconds at or below which the status line turns red. Matches
;	PLAY_STATUS_WARN_SECS on the server - the last 30 seconds are when
;	the level ramps (an extra bee and a gear quicker), so the colour is
;	reporting a real change, not just counting down.
STATUS_WARN_SECS = 30

;	Each corner's score, as the SIX ASCII DIGITS the server sent (see
;	TSnakeGame.SendSlotStatus - the score goes on the wire already
;	formatted, so nothing here has to divide anything).
;
;	These are the actual TEXT of the four score labels, not a copy of it:
;	label_detail_scoreN's textptr points straight in here, so updating a
;	score is a 6-byte copy plus an invalidate, with no separate render
;	step. Initialised rather than .res'd because they are live text from
;	the moment the page first draws, which is before any SlotStatus has
;	necessarily arrived.
;
;	SCORE_TEXT_SIZE is 7, not 6 - the NUL each .asciiz adds is what the
;	label's own draw stops on.
SCORE_TEXT_LEN  = 6
SCORE_TEXT_SIZE = SCORE_TEXT_LEN + 1

slotScoreText:
		.asciiz	"000000"
		.asciiz	"000000"
		.asciiz	"000000"
		.asciiz	"000000"

;	Where each corner's digits start. A table rather than a multiply by
;	SCORE_TEXT_SIZE, which is neither a shift nor worth a loop for four
;	entries.
gameScoreTexts:
		.word	slotScoreText + (0 * SCORE_TEXT_SIZE)
		.word	slotScoreText + (1 * SCORE_TEXT_SIZE)
		.word	slotScoreText + (2 * SCORE_TEXT_SIZE)
		.word	slotScoreText + (3 * SCORE_TEXT_SIZE)

;	Lives remaining and current speed gear on each corner, from
;	SlotStatus's last three payload bytes (see gameProcSlotStatusMsg).
;	Drawn as bars by gameLivesPresent/gameSpeedPresent.
;
;	These have to be KEPT, not just drawn once and forgotten: a present
;	hook can run at any time - a page re-entry, a panel repaint by some
;	unrelated control - and it has to be able to redraw the row from
;	scratch without a fresh message from the server.
slotLives:
		.res	$04
slotSpeed:
		.res	$04

;	Scratch for gameHudBarPresent and its two DMA helpers. A present hook
;	has both index registers busy (one for the screen row, one for table
;	lookups) and cannot keep any of this in registers.
gameHudKind:
		.byte	$00
gameHudCorner:
		.byte	$00
gameHudCount:
		.byte	$00
gameHudGap:
		.byte	$00
gameHudChar:
		.byte	$00
gameHudClr:
		.byte	$00
gameHudRow:
		.byte	$00
gameHudLeft:
		.byte	$00
gameHudWidth:
		.byte	$00
gameHudCol:
		.byte	$00
gameHudLen:
		.byte	$00
gameHudFillVal:
		.byte	$00
gameHudTmp:
		.byte	$00

;	1 once WatchStart (mcPlay/$0C) has been sent to the server - i.e.
;	the client believes page_detail is the active page and the server
;	has been told so - 0 otherwise. gamePollTick keeps this in sync
;	with the actual current page every iteration (see its own comment)
;	and is the only thing that ever changes it.
gameWatching:
		.byte	$00

;	1 once panel_detail_bkg has actually run its own background fill
;	for the current page-entry, 0 otherwise - gameDetailBkgPresent sets
;	it, gamePollTick clears it unconditionally whenever page_detail
;	isn't the current page. Exists to fix a real race (caught live,
;	2026-08-24): gamePollTick's watching edge-detect and
;	panel_detail_bkg's own STATE_DIRTY-triggered present run on
;	independent schedules, so without this, gameBoardSyncStart's clear+
;	draw could run BEFORE panel_detail_bkg's background fill, which -
;	since that fill covers the whole page including the board area -
;	would then wipe out tiles already drawn. gameBoardSyncPending below
;	is what actually waits on this flag.
gameBkgPresented:
		.byte	$00

;	1 when gamePollTick has decided a fresh board sync should start
;	(the watching edge fired) but is still waiting on gameBkgPresented
;	before actually calling gameBoardSyncStart - see both flags' use in
;	gamePollTick.
gameBoardSyncPending:
		.byte	$00

;	Scratch byte for gameDetailBkgPresent - remembers whether
;	panel_detail_bkg was actually dirty (i.e. about to really fill,
;	not just get a present call that no-ops) across the JSR into
;	ctrlsPanelDefPresent.
gameBkgPresentTmp:
		.byte	$00

;	Raw [slot, state] pairs from SlotStatus (mcPlay/$07), stored by
;	gameProcSlotStatusMsg. Nothing reads this yet - the 4-corner status
;	display is follow-up work - this just stops SlotStatus from
;	tripping clientProcUnknownMsg's log spam in the meantime.
slotStates:
		.res	4

;	Scratch bytes for gameDrawBoardRows/gameClearBoardArea (see the
;	BOARD RENDER section below) - hold a row number across a JSR-free
;	inner loop where a register alone would do, but a named byte reads
;	more clearly at the call site than "whichever of A/X/Y happens to
;	still be free".
gameDrawRowTmp:
		.byte	$00
gameDrawRowTmp2:
		.byte	$00

;	Which row of the current pair gameDrawBoardRows is building (0 or
;	1) - a plain byte rather than X, so X stays free inside the
;	per-cell build loop for the gameTileChars/gameTileColrs lookup.
gameDrawRowInPair:
		.byte	$00

;	One row's worth of screen chars/colours, built cell by cell from
;	boardTiles (see gameDrawBoardRows) so the actual hardware writes
;	can go in as 2 DMA bursts (dmaCopyRow16, fw_ctrls_net.s) instead of
;	60 individual STCELL16/STCOLR16 writes - the per-cell CPU work of
;	deciding each tile's char/colour is unavoidable, but landing it in
;	a small local buffer first, then DMA-copying the whole row, is
;	much cheaper than hitting far-pointer screen/colour RAM 30 times.
gameRowCharBuf:
		.res	BOARD_COLS
gameRowColrBuf:
		.res	BOARD_COLS

;	Scratch bytes for gameProcTileDeltaMsg - one delta's row/col/tile,
;	and how many deltas are left to process in the current message.
gameDeltaRow:
		.byte	$00
gameDeltaCol:
		.byte	$00
gameDeltaTile:
		.byte	$00
gameDeltaCount:
		.byte	$00

;	Absolute screen row (board row + 5) for the delta currently being
;	drawn - held here rather than just in Y, since Y gets reused for
;	the gameTileChars/gameTileColrs lookup in between the screen and
;	colour pointer setups (see gameProcTileDeltaMsg).
gameDeltaScreenRow:
		.byte	$00

;	SCREEN SHAKE (mcPlay/$0C). The server sends a DURATION and nothing
;	else - one message, then the client owns the whole effect and stops
;	on its own. Sending per-frame offsets from the server instead would
;	put a 50Hz visual on a 12Hz tick and spend the delta budget on
;	something that can be generated here for free (dengland's own call,
;	2026-08-25: "we can just send a message 'shake now' and have it
;	last that long on the client").
;
;	gameShakeFrames counts DOWN once per frame; gameShakeLastFrame is
;	the FRAMECOUNT snapshot that paces it, since gamePollTick runs once
;	per main-loop iteration and that is not the same thing as once per
;	frame. gameShakeSaveY/X hold the scroll bits from before the shake
;	started, so the display goes back exactly where it was rather than
;	to an assumed default.
gameShakeFrames:
		.byte	$00
gameShakeLastFrame:
		.byte	$00
gameShakeSaveY:
		.byte	$00
gameShakeSaveX:
		.byte	$00
gameShakeActive:
		.byte	$00
gameShakeTmp:
		.byte	$00
gameShakeTmp2:
		.byte	$00

;	Shake amplitude, in pixels, as a mask on the random offset. The
;	registers take 0-7, but dengland's call (2026-08-25) is the low TWO
;	bits only - 0-3 - "to make the shake not too dramatic". Raise to
;	VAL_VIC_SCROLLMASK for the full 8-pixel throw.
GAME_SHAKE_AMP		= %00000011

;	This game's own GameState byte from GameStatus (mcPlay/$06) -
;	stored but not acted on yet, no UI distinguishes gsWaiting/
;	gsPlaying/etc for QUADRO's spectator model (see SnakeClasses.pas'
;	TODO). Kept for parity with chess's equivalent
;	(clientProcPlayGameStatMsg -> chessGameState).
gameState:
		.byte	$00

;	Byte offset into boardTiles for each row-pair index (0..8) -
;	pairIndex * BOARD_COLS * 2 (2 rows of 30 cols each). A lookup table
;	beats a runtime multiply for just 9 fixed values.
boardPairOffsetLo:
		.byte	<(0 * BOARD_COLS * 2), <(1 * BOARD_COLS * 2), <(2 * BOARD_COLS * 2)
		.byte	<(3 * BOARD_COLS * 2), <(4 * BOARD_COLS * 2), <(5 * BOARD_COLS * 2)
		.byte	<(6 * BOARD_COLS * 2), <(7 * BOARD_COLS * 2), <(8 * BOARD_COLS * 2)
		.byte	<(9 * BOARD_COLS * 2)
boardPairOffsetHi:
		.byte	>(0 * BOARD_COLS * 2), >(1 * BOARD_COLS * 2), >(2 * BOARD_COLS * 2)
		.byte	>(3 * BOARD_COLS * 2), >(4 * BOARD_COLS * 2), >(5 * BOARD_COLS * 2)
		.byte	>(6 * BOARD_COLS * 2), >(7 * BOARD_COLS * 2), >(8 * BOARD_COLS * 2)
		.byte	>(9 * BOARD_COLS * 2)

;	Byte offset into boardTiles for each individual row (0..19) -
;	row * BOARD_COLS. Same idea as boardPairOffsetLo/Hi above, but per
;	row rather than per row-pair - TileDelta (gameProcTileDeltaMsg)
;	names one row at a time, unlike BoardRowsData's always-2-rows shape.
boardRowOffsetLo:
		.byte	<(0 * BOARD_COLS), <(1 * BOARD_COLS), <(2 * BOARD_COLS), <(3 * BOARD_COLS)
		.byte	<(4 * BOARD_COLS), <(5 * BOARD_COLS), <(6 * BOARD_COLS), <(7 * BOARD_COLS)
		.byte	<(8 * BOARD_COLS), <(9 * BOARD_COLS), <(10 * BOARD_COLS), <(11 * BOARD_COLS)
		.byte	<(12 * BOARD_COLS), <(13 * BOARD_COLS), <(14 * BOARD_COLS), <(15 * BOARD_COLS)
		.byte	<(16 * BOARD_COLS), <(17 * BOARD_COLS), <(18 * BOARD_COLS), <(19 * BOARD_COLS)
boardRowOffsetHi:
		.byte	>(0 * BOARD_COLS), >(1 * BOARD_COLS), >(2 * BOARD_COLS), >(3 * BOARD_COLS)
		.byte	>(4 * BOARD_COLS), >(5 * BOARD_COLS), >(6 * BOARD_COLS), >(7 * BOARD_COLS)
		.byte	>(8 * BOARD_COLS), >(9 * BOARD_COLS), >(10 * BOARD_COLS), >(11 * BOARD_COLS)
		.byte	>(12 * BOARD_COLS), >(13 * BOARD_COLS), >(14 * BOARD_COLS), >(15 * BOARD_COLS)
		.byte	>(16 * BOARD_COLS), >(17 * BOARD_COLS), >(18 * BOARD_COLS), >(19 * BOARD_COLS)

;	Screen char/colour per tile value (the TILE_* constants,
;	SnakeServer.pas) - shared by gameDrawBoardRows (building a whole
;	row buffer) and gameProcTileDeltaMsg (a single cell at a time), so
;	both draw identically from one place instead of two separate
;	branches that could drift apart. Extend here, not with more
;	branches, when a real tile set exists.
;
;	Snakes are drawn as a CONNECTED PIPE - each cell's character
;	depends on which way the snake entered it and which way it left,
;	so turning leaves a corner piece behind. The six shapes are named
;	by the compass directions the pipe OPENS TOWARD, after dengland's
;	own point (2026-08-24) that describing them as left/right turns
;	"is a bit odd" - which turn it is depends on which way you were
;	already going, but what the pipe connects to never changes:
;
;		SHAPE_HORZ $C0	opens E-W	SHAPE_NE $CA	opens N+E
;		SHAPE_VERT $DD	opens N-S	SHAPE_NW $CB	opens N+W
;		SHAPE_WS   $C9	opens W+S	SHAPE_ES $D5	opens E+S
;
;	Head and body use the SAME six shapes and differ only in COLOUR.
;	A turning head shows the CORNER piece one step early - the server
;	shapes it by where the snake came from and the turn it's already
;	committed to (TDemoSnake.Look), the way a Pac-Man ghost's eyes
;	commit to a corner before its body does. When the head then moves
;	on, that cell keeps the identical character and only changes to
;	the body colour, so the hand-off is invisible.
;
;	That's why the character set has one "looking left or right" and
;	one "looking up or down" rather than four facings - a head running
;	straight is just a straight pipe.
;
;	Tile value = TILE_SNAKE_BASE + ((player * 2) + role) * 6 + shape
;	(SnakeServer.pas) - 8 blocks of 6 in player order, body block then
;	head block, followed by ONE more block of 6 (51-56) for the
;	invulnerability flash. The order here must match that numbering
;	exactly: these are indexed by raw tile value with no bounds check
;	on this side (gameProcTileDeltaMsg's range check on row/col is what
;	guarantees only real board cells ever reach a lookup). All 48 are
;	reachable - heads take corner shapes too, one step before turning.
;
;	57 entries total, and the server has a TILE_COUNT constant that
;	must agree - if a block is added there, add it here too.
;
;	Colours are dengland's own pick (2026-08-24), light body / dark
;	head per player: P1 $0E/$06, P2 $0A/$02, P3 $0D/$05, P4 $07/$08.
gameTileChars:
;		floor  wall   attract
		.byte	$20,   $66,   $66
;	The same six shapes for all 11 snake-ish blocks: 4 players x
;	body/head, then the BOSS's body/head, then the invulnerability
;	flash block.
		.repeat	11
		.byte	$C0, $DD, $C9, $CA, $CB, $D5
		.endrepeat
;	Lava (69-71) - three age tiers, same character, colour only.
;	$AA is dengland's pick (2026-08-24).
		.byte	$AA, $AA, $AA
;	Bee (72) - dengland's pick.
		.byte	$DA
;	Food (73-76) in the original's type order: no-grow+fast,
;	grow+slow, speed burst, invulnerability. dengland's characters,
;	bit 7 CLEAR - the plain forms, not the reversed ones.
		.byte	$58, $51, $57, $53

gameTileColrs:
		.byte	CLR_LOG_C64_BLACK
		.byte	CLR_LOG_C64_LIGHTGREEN
		.byte	CLR_LOG_C64_WHITE

;	One colour per block of 6 shapes, in tile-value order.
		.repeat	6
		.byte	CLR_LOG_C64_LIGHTBLUE		;$0E - P1 body
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_BLUE		;$06 - P1 head
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_LIGHTRED		;$0A - P2 body
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_RED			;$02 - P2 head
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_LIGHTGREEN		;$0D - P3 body
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_GREEN		;$05 - P3 head
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_YELLOW		;$07 - P4 body
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_ORANGE		;$08 - P4 head
		.endrepeat

;	The BOSS (51-62) - purple body, cyan head (dengland swapped these
;	2026-08-25). A fifth render slot after the four players, so it
;	renders through exactly the same encoding and shaping as a player
;	snake. Note purple is also the bee, but the characters differ.
		.repeat	6
		.byte	CLR_LOG_C64_PURPLE		;$04 - boss body
		.endrepeat
		.repeat	6
		.byte	CLR_LOG_C64_CYAN		;$03 - boss head
		.endrepeat

;	Invulnerability flash body (63-68) - white, and deliberately NOT
;	per player: the whole point is that it overrides the player colour
;	while it's on. Same six characters as any other body block, so a
;	flashing snake keeps its pipe joints instead of coming apart into
;	loose blocks for half of every cycle. Only the BODY ever uses these
;	- the head keeps its own colour throughout, as in the original.
		.repeat	6
		.byte	CLR_LOG_C64_WHITE		;$01 - invulnerable body
		.endrepeat

;	Spreading lava (69-71), oldest cell to newest: hot core through
;	cooling crust. Character $AA for all three, so they never read as
;	snake pipe even though P4 shares the yellow and orange. The three
;	COLOURS here are still mine, not dengland's - easy to respecify,
;	they're three bytes.
		.byte	CLR_LOG_C64_YELLOW		;$07 - core (laid down first)
		.byte	CLR_LOG_C64_ORANGE		;$08 - mid
		.byte	CLR_LOG_C64_BROWN		;$09 - crust (newest, goes first)

;	Bee (72) - one tile, no shapes and no ageing, it just moves.
;	Purple $04 is also the BOSS head, but the characters differ ($DA vs
;	a pipe shape) so the two never read as each other. Worth knowing if
;	either is ever recoloured.
		.byte	CLR_LOG_C64_PURPLE		;$04

;	Food (73-76). These COLOURS are mine, not dengland's - he picked
;	the characters only. Chosen to stay clear of the player colours
;	where it matters; the heart shares P2's light red, but a heart
;	against a pipe segment is never ambiguous.
		.byte	CLR_LOG_C64_LIGHTGREY		;$0F - clubs, no-grow + fast
		.byte	CLR_LOG_C64_GREY		;$0C - solid circle, grow + slow
		.byte	CLR_LOG_C64_CYAN		;$03 - open circle, speed burst
		.byte	CLR_LOG_C64_LIGHTRED		;$0A - heart, invulnerability


;-------------------------------------------------------------------------------
;	gameRowReqTimeoutFrames - how many frames to wait for a
;	BoardRowsData reply before assuming it was dropped and re-sending
;	the request. Not a precise game-tick count - the server is
;	authoritative regardless of what the client does locally, so this
;	only has to be "plausibly long enough", not exact. Same NTSC/PAL
;	split as crsrBlinkDelay (fw_font_input.s): ~2 ticks' worth, 20
;	frames on NTSC (~333ms), 16 on PAL (~320ms).
;	OUT	.A		frame count
;-------------------------------------------------------------------------------
gameRowReqTimeoutFrames:
;-------------------------------------------------------------------------------
		LDA	sys_ntsc_flag
		BEQ	@pal

		LDA	#20
		RTS

@pal:
		LDA	#16
		RTS


;-------------------------------------------------------------------------------
;	gamePollTick - GAME HOOK (see fw_ctrls_net.s's main/@loop). Two
;	unrelated jobs, both cheap enough to run every single main-loop
;	iteration:
;
;	1. Watching edge-detect - compares pageptr0 (the framework's own
;	   "current page" pointer) against page_detail's address to notice
;	   when the client's UI has entered or left the board page, and
;	   tells the server accordingly (WatchStart/WatchStop, mcPlay/$0C
;	   and /$0D) so it knows whether to bother sending this player board
;	   updates - see TSnakeGame.Watchers, SnakeServer.pas. Polled rather
;	   than hooked (no page-leave callback exists in the framework)
;	   since comparing pageptr0 catches every way of leaving page_detail
;	   uniformly - tab switch, back button, disconnect. gameWatching
;	   tracks what was last told to the server, so a message only goes
;	   out on an actual transition, not every iteration. Entering
;	   page_detail also (re)starts the row-fetch sync from scratch
;	   (gameBoardSyncStart) - this replaces the old join-triggered sync,
;	   see gameProcGameStatusMsg's own comment.
;
;	2. Row-fetch retry - while a BoardRowsReq is in flight, checks
;	   whether gameRowReqTimeoutFrames worth of frames have passed since
;	   it was sent and, if so, re-sends the same row-pair rather than
;	   waiting forever for a reply that may have been dropped. The
;	   happy path (reply arrives in time) never touches this at all -
;	   see gameProcBoardRowsMsg, which chains straight to the next
;	   request.
;-------------------------------------------------------------------------------
gamePollTick:
;-------------------------------------------------------------------------------
;	Nothing below here can reach the server without a live connection.
;	INET_PROC_EXEC is the steady state while connected (main's own
;	dispatch calls inetExecute every pass while it holds); anything
;	else means halted, idle, connecting or errored. Without this gate,
;	sitting on page_detail while disconnected still sets gameWatching,
;	sends a WatchStart nobody receives, and then re-sends a
;	BoardRowsReq on every single timeout, forever - caught live by the
;	user (2026-08-24): "there is a bug where when not connected, it
;	polls for the screen lines even though it fails", confirmed in the
;	same session with inetproc=$01 (HALT) and inetstat=$01 (ERR) while
;	boardSyncWaiting and gameWatching were both still $01.
;
;	Clear the state here rather than falling into @notwatching's
;	normal leaving-edge path - that path sends a WatchStop, and
;	there's nobody to send it to. Everything re-arms by itself if the
;	connection comes back while page_detail is still up, since
;	gameWatching being 0 is exactly what makes the entry block below
;	run again.
;	The shake runs ABOVE the connection gate on purpose. It's a purely
;	local visual with a duration already in hand, so losing the
;	connection mid-shake must still let it finish and put the scroll
;	registers back - bailing out early would leave the whole display
;	permanently offset by a few pixels with nothing to correct it.
		JSR	gameShakeTick

;	The joystick stops doubling as a mouse the moment this client holds
;	a corner, and starts again the moment it doesn't. Recomputed every
;	pass rather than toggled on the transitions, so there is no path -
;	disconnect, drop, refused claim - that can leave the pointer
;	permanently dead. Above the connection gate for that same reason:
;	losing the connection while playing must still give the mouse back.
		LDA	#$01
		LDX	gameMySlot
		CPX	#SLOT_CLAIM_NONE
		BEQ	@setjoymouse

		LDA	#$00

@setjoymouse:
		STA	joyAsMouse

		LDA	inetproc
		CMP	#INET_PROC_EXEC
		BEQ	@connected

		LDA	#$00
		STA	gameWatching
		STA	gameBkgPresented
		STA	gameBoardSyncPending
		STA	boardSyncWaiting

		RTS

@connected:
;	Steer the snake, but only while this client actually holds a corner.
;	Gated on gameMySlot rather than on the page, so the stick is live
;	the moment the server confirms the claim and dead the moment it is
;	given up - a spectator's joystick must not be able to turn anyone.
;
;	Above the page test on purpose: a player who tabs away from the
;	board page is still ON the board, and their snake keeps moving. If
;	their controls went dead with the page they'd come back to a corpse.
		LDA	gameMySlot
		CMP	#SLOT_CLAIM_NONE
		BEQ	@nojoy

		JSR	gamePollJoystick

@nojoy:
		LDA	pageptr0
		CMP	#<page_detail
		BNE	@notwatching
		LDA	pageptr0 + 1
		CMP	#>page_detail
		BNE	@notwatching

;	Currently on page_detail.
		LDA	gameWatching
		BNE	@syncgate			;already told the server

		LDA	#$01
		STA	gameWatching

		JSR	gameSendWatchStart

;	Don't call gameBoardSyncStart directly here - panel_detail_bkg's
;	own STATE_DIRTY-triggered background fill (ctrlsPagePrepare/
;	gameDetailBkgPresent) runs on an independent schedule and hasn't
;	necessarily happened yet, so drawing the board now risks it getting
;	wiped by that fill arriving late (see gameBkgPresented's own
;	comment). Just flag that a sync is wanted; @syncgate below only
;	actually starts it once the background's confirmed drawn.
		LDA	#$00
		STA	gameBkgPresented
		LDA	#$01
		STA	gameBoardSyncPending

		JMP	@syncgate

@notwatching:
;	Not on page_detail - gameBkgPresented has to go back to false
;	unconditionally here (not just on the leaving-edge below), so a
;	stale "yes, presented" from the last visit can never survive into
;	the next one.
		LDA	#$00
		STA	gameBkgPresented

		LDA	gameWatching
		BEQ	@retry				;already not watching

		LDA	#$00
		STA	gameWatching
		STA	gameBoardSyncPending

		JSR	gameSendWatchStop

		JMP	@retry

@syncgate:
		LDA	gameBoardSyncPending
		BEQ	@retry

		LDA	gameBkgPresented
		BEQ	@retry				;still waiting on the background fill

		LDA	#$00
		STA	gameBoardSyncPending

		JSR	gameBoardSyncStart

@retry:
		LDA	boardSyncWaiting
		BEQ	@done

		JSR	gameRowReqTimeoutFrames
		STA	gameSendRowTmp			;reuse as a timeout scratch

		LDA	FRAMECOUNT
		SEC
		SBC	boardSyncReqFrame		;elapsed frames (wraps fine
							;	as an 8-bit delta)
		CMP	gameSendRowTmp
		BCC	@done				;elapsed < timeout, keep waiting

		LDA	boardSyncPair
		ASL	A				;pairIndex * 2 = start row
		JSR	gameSendBoardRowsReq

		LDA	FRAMECOUNT
		STA	boardSyncReqFrame

@done:
		RTS


;-------------------------------------------------------------------------------
;	gameDetailBkgPresent - panel_detail_bkg's own present routine (in
;	place of the generic ctrlsPanelDefPresent) - does exactly the same
;	background-fill work, just also sets gameBkgPresented once that
;	fill has genuinely happened, so gamePollTick knows it's safe to
;	start drawing the board without panel_detail_bkg's own fill (which
;	covers the whole page, board included) landing on top of it later.
;	Checks STATE_DIRTY itself before the call, rather than trusting
;	that ctrlsPanelDefPresent having run at all means it actually
;	filled anything - ctrlsPanelDefPresent is a no-op whenever
;	STATE_DIRTY isn't set, same as any other panel using it.
;	IN	elemptr0	panel_detail_bkg (present's normal calling convention)
;-------------------------------------------------------------------------------
gameDetailBkgPresent:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DIRTY
		STA	gameBkgPresentTmp

		JSR	ctrlsPanelDefPresent

		LDA	gameBkgPresentTmp
		BEQ	@exit

		LDA	#$01
		STA	gameBkgPresented

@exit:
		RTS


;-------------------------------------------------------------------------------
;	THE HUD ROWS.
;
;	Each corner's 5-row block on page_detail is [START button, score,
;	lives, speed, blank]. The SCORE row is ordinary label text; the LIVES
;	and SPEED rows are graphic bars, drawn by the present hooks below
;	INSTEAD OF the framework's default one.
;
;	WHY NOT LABEL TEXT: screenASCIIToScreen folds every character from
;	$7F up onto $66, so label text cannot reach $A0 (solid block) or $DC
;	(pip) at all. Giving those two codes an ASCII name in
;	screenASCIIXLAT was tried and backed out (dengland, 2026-08-25) - it
;	claims two printable characters framework-wide, INCLUDING inside
;	usernames and chat, which go through the same translation, and it
;	puts two more comparisons in front of every ordinary character drawn.
;	A control that wants graphics fills them itself.
;
;	WHY NOT ctrlsControlDefPresent AND THEN OVERDRAW: that erases the row
;	with one DMA job and then paints part of it again, doing the same
;	cells twice and briefly showing the wrong thing. These hooks REPLACE
;	the default present and lay the row down in one pass - two character
;	fills (the bar, and the gap beside it) and one colour fill, all DMA,
;	no per-cell writes and nothing drawn twice.
;-------------------------------------------------------------------------------

;	Which of the two bars a present call is for. Parked by the two entry
;	points below for their shared tail, since .A cannot carry it across
;	the state and tag reads.
HUD_KIND_LIVES  = $00
HUD_KIND_SPEED  = $01

;	Screen code for an empty cell - what the gap beside a bar is filled
;	with. Not $20-the-character: this goes straight to screen RAM without
;	passing through any translation, so it is a SCREEN CODE, and it only
;	happens to be the same number.
HUD_BLANK_CHAR  = $20

;-------------------------------------------------------------------------------
;	gameLivesPresent / gameSpeedPresent - present hooks for the four
;	corners' lives and speed rows. Each control's TAG byte says which
;	corner it is, so one pair of handlers covers all eight rows.
;
;	Present hooks rather than a one-off draw, because the HUD panel
;	repaints its own background on every dirty pass - anything painted
;	over the top from outside would be wiped by the next repaint. This
;	way the bar is drawn by the same pass that would have erased it,
;	which is also how the label they replace worked.
;-------------------------------------------------------------------------------
gameLivesPresent:
;-------------------------------------------------------------------------------
		LDA	#HUD_KIND_LIVES
		JMP	gameHudBarPresent

;-------------------------------------------------------------------------------
gameSpeedPresent:
;-------------------------------------------------------------------------------
		LDA	#HUD_KIND_SPEED
;		JMP	gameHudBarPresent

;-------------------------------------------------------------------------------
;	gameHudBarPresent - the shared tail. Works out how long this corner's
;	bar is and what colour, then lays the whole row down in three DMA
;	jobs.
;
;	The VISIBLE/DIRTY gates are ctrlsControlDefPresent's own, repeated
;	here because this REPLACES it rather than calling it. The dirty flag
;	itself is cleared by the caller after the hook returns (see
;	ctrlsPanelDefPresent), so nothing here touches it.
;
;	The control's own colour byte is deliberately NOT consulted - both
;	kinds work theirs out below. That leaves CLR_PAPER sitting unused in
;	these four defs, which is honest: it is what the row would be if the
;	default present ever ran on it.
;	IN	elemptr0	the control
;		.A		HUD_KIND_*
;-------------------------------------------------------------------------------
gameHudBarPresent:
;-------------------------------------------------------------------------------
		STA	gameHudKind

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		LBEQ	@exit

		LDA	(elemptr0), Y
		AND	#STATE_DIRTY
		LBEQ	@exit

		LDY	#ELEMENT::tag
		LDA	(elemptr0), Y
		CMP	#$04
		LBCS	@exit				;bad tag - shouldn't happen

		STA	gameHudCorner
		TAX

;	An unclaimed corner shows nothing at all. That falls out of a count
;	of zero - the gap fill then covers the whole row - so there is no
;	separate "erase it" path to keep in step with this one.
		LDA	slotStates, X
		CMP	#PLAYER_STATE_PLAYING
		BNE	@empty

		LDA	gameHudKind
		BEQ	@lives

;-------------------------------------------------------------------------------
;	SPEED. The gear comes straight off the wire, so it is bounds-checked
;	against the table rather than trusted.
;
;	Coloured by GEAR, deliberately not by corner like the lives row: this
;	bar is not meant to identify whose row it is, it is meant to say how
;	fast. X still holds the gear from the bounds check, which is the same
;	index both tables want.
;-------------------------------------------------------------------------------
		LDA	slotSpeed, X
		CMP	#SPEED_GEAR_MAX + 1
		BCS	@empty

		TAX
		LDA	gameSpeedCells, X
		STA	gameHudCount

		LDA	#SPEED_BAR_CHAR
		STA	gameHudChar

		LDA	gameSpeedClrs, X
		STA	gameHudClr

		JMP	@geom

;-------------------------------------------------------------------------------
;	LIVES. Clamped because a bonus life can push a corner past what the
;	block is wide.
;
;	Coloured as that corner's snake BODY, taken from gameTileColrs rather
;	than hardcoded per control, so a palette change moves the HUD and the
;	board together. Body tile for player p is TILE_SNAKE_BASE +
;	(p * SNAKE_ROLE_COUNT + SNAKE_ROLE_BODY) * SHAPE_COUNT; every shape
;	in the block shares one colour, and SNAKE_ROLE_BODY is 0, so that
;	reduces to base + p * 12.
;
;	Those table entries are RAW PALETTE values (CLR_LOG_C64_*), which is
;	exactly what colour RAM wants - no scheme lookup, and none of the
;	CLR_SPEC_TEXT business a control colour byte would have needed.
;-------------------------------------------------------------------------------
@lives:
		LDA	slotLives, X
		CMP	#LIVES_PIP_MAX + 1
		BCC	@count

		LDA	#LIVES_PIP_MAX

@count:
		STA	gameHudCount

		LDA	#LIVES_PIP_CHAR
		STA	gameHudChar

		LDA	gameHudCorner
		ASL	A
		ASL	A
		ASL	A				;p * 8
		STA	gameHudTmp
		LDA	gameHudCorner
		ASL	A
		ASL	A				;p * 4
		CLC
		ADC	gameHudTmp			;p * 12
		CLC
		ADC	#TILE_SNAKE_BASE
		TAX

		LDA	gameTileColrs, X
		STA	gameHudClr

		JMP	@geom

;	Nothing to show. Colour still matters - the row is about to be filled
;	edge to edge with blanks, and they have to be SOME colour.
@empty:
		LDA	#$00
		STA	gameHudCount
		STA	gameHudChar
		STA	gameHudClr

@geom:
		LDY	#ELEMENT::posy
		LDA	(elemptr0), Y
		STA	gameHudRow

		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		STA	gameHudLeft

		LDY	#ELEMENT::width
		LDA	(elemptr0), Y
		STA	gameHudWidth

;	A bar can never be longer than its own block, whatever the tables
;	say - and if it were, the gap subtraction below would go negative and
;	hand dmaFillRow a count of ~250.
		CMP	gameHudCount
		BCS	@fill

		STA	gameHudCount

@fill:
;	Colour across the WHOLE width first, so the gap beside the bar is the
;	same colour as the bar. It is one row, not a bar sitting on some
;	other background - and it means the colour job is one fill whichever
;	way the bar is aligned.
		JSR	gameHudFillClr

;	Then the two character runs. Which one is on the left depends on the
;	bar: lives drain RIGHT TO LEFT, so the row reads as a gauge emptying
;	toward the left, and speed fills LEFT TO RIGHT, so a longer bar means
;	faster at a glance. One gauge going down, one going up - both
;	dengland's own call.
		LDA	gameHudWidth
		SEC
		SBC	gameHudCount
		STA	gameHudGap

		LDA	gameHudKind
		BEQ	@right

;	Speed - bar at the left edge, gap after it.
		LDA	gameHudLeft
		STA	gameHudCol
		LDA	gameHudCount
		STA	gameHudLen
		LDA	gameHudChar
		JSR	gameHudFillChars

		LDA	gameHudLeft
		CLC
		ADC	gameHudCount
		STA	gameHudCol
		LDA	gameHudGap
		STA	gameHudLen
		LDA	#HUD_BLANK_CHAR

		JMP	gameHudFillChars
;		RTS

;	Lives - gap first, bar hard against the right edge.
@right:
		LDA	gameHudLeft
		STA	gameHudCol
		LDA	gameHudGap
		STA	gameHudLen
		LDA	#HUD_BLANK_CHAR
		JSR	gameHudFillChars

		LDA	gameHudLeft
		CLC
		ADC	gameHudGap
		STA	gameHudCol
		LDA	gameHudCount
		STA	gameHudLen
		LDA	gameHudChar

		JMP	gameHudFillChars
;		RTS

@exit:
		RTS


;-------------------------------------------------------------------------------
;	gameHudFillChars - one DMA fill: gameHudLen cells of screen code .A,
;	starting at column gameHudCol on row gameHudRow.
;
;	Columns are doubled because CHR16 cells are 2 bytes wide; dmaFillRow's
;	own dest-skip of 2 then writes only the LOW byte of each, leaving the
;	$00 high byte initMem put there - the same trick ctrlsEraseBkg uses,
;	and the reason a 16-bit screen can be filled with an 8-bit job.
;
;	A count of ZERO IS NOT DRAWN. That is not an optimisation: a DMA job
;	count of 0 is a real hardware hazard on this platform, not a harmless
;	no-op, which is why ctrlsEraseBkg guards its own call the same way.
;	Both callers above genuinely produce zero - an empty bar has no bar,
;	a full one has no gap.
;	IN	gameHudRow	screen row
;		gameHudCol	first column
;		gameHudLen	cells
;		.A		screen code to fill with
;-------------------------------------------------------------------------------
gameHudFillChars:
;-------------------------------------------------------------------------------
		STA	gameHudFillVal

		LDA	gameHudLen
		BEQ	@exit

		LDX	gameHudRow

		LDA	gameHudCol
		ASL	A				;2 bytes per cell
		STA	gameHudTmp

		LDA	screenRowsLo, X
		CLC
		ADC	gameHudTmp
		STA	dmaDst
		LDA	screenRowsHi, X
		ADC	#$00
		STA	dmaDst + 1

		LDA	#$01				;screen RAM is at $010000
		STA	dmaDstBank

		LDA	gameHudLen
		STA	dmaCnt

		LDA	gameHudFillVal

		JMP	dmaFillRow
;		RTS

@exit:
		RTS


;-------------------------------------------------------------------------------
;	gameHudFillClr - one DMA fill of gameHudClr across the control's whole
;	width, on row gameHudRow starting at column gameHudLeft.
;
;	+1 on the byte offset because under FCLRHI the system colour value
;	lives in the HIGH byte of a colour cell (see STCOLR16) - the low byte
;	stays whatever initMem's boot-time zero-fill left it as. Colour rows
;	share the SCREEN row's low byte and take their high byte from
;	colourRowsHiPhys, because colour RAM's real physical address is
;	$01F800, not $D800.
;	IN	gameHudRow	screen row
;		gameHudLeft	first column
;		gameHudWidth	cells
;		gameHudClr	raw palette colour
;-------------------------------------------------------------------------------
gameHudFillClr:
;-------------------------------------------------------------------------------
		LDA	gameHudWidth
		BEQ	@exit				;zero-count DMA is a hazard

		LDX	gameHudRow

		LDA	gameHudLeft
		ASL	A				;2 bytes per cell
		CLC
		ADC	#$01				;colour is the HIGH byte
		STA	gameHudTmp

		LDA	screenRowsLo, X
		CLC
		ADC	gameHudTmp
		STA	dmaDst
		LDA	colourRowsHiPhys, X
		ADC	#$00
		STA	dmaDst + 1

		LDA	#$01				;colour RAM is at $01F800
		STA	dmaDstBank

		LDA	gameHudWidth
		STA	dmaCnt

		LDA	gameHudClr
		AND	#$0F

		JMP	dmaFillRow
;		RTS

@exit:
		RTS


;-------------------------------------------------------------------------------
;	gameLivesInvalidate - mark one corner's lives row for redraw.
;	Preserves X, which the caller (gameProcSlotStatusMsg) is still using
;	as the corner index afterwards.
;
;	Three near-identical routines here rather than one taking a table
;	pointer: the pointer would have to live in zero page to be indexed
;	indirectly, and borrowing a framework temp for it across
;	ctrlsControlInvalidate is not worth saving a dozen bytes.
;	IN	.X		corner 0..3
;-------------------------------------------------------------------------------
gameLivesInvalidate:
;-------------------------------------------------------------------------------
		CPX	#$04
		BCS	@exit				;defensive - shouldn't happen

		TXA
		PHA

		ASL	A				;word table
		TAX

		LDA	gameLivesCtrls, X
		STA	elemptr0
		LDA	gameLivesCtrls + 1, X
		STA	elemptr0 + 1

		JSR	ctrlsControlInvalidate

		PLA
		TAX

@exit:
		RTS

gameLivesCtrls:
		.word	label_detail_pwr1_0
		.word	label_detail_pwr1_1
		.word	label_detail_pwr1_2
		.word	label_detail_pwr1_3


;-------------------------------------------------------------------------------
;	gameScoreInvalidate - as above, for the score row.
;
;	No present hook to go with this one: the score really IS label text.
;	Each score label points permanently at its own slotScoreText buffer,
;	which gameProcSlotStatusMsg writes the server's digits into, so all
;	this has to do is set the dirty flag.
;	IN	.X		corner 0..3
;-------------------------------------------------------------------------------
gameScoreInvalidate:
;-------------------------------------------------------------------------------
		CPX	#$04
		BCS	@exit				;defensive - shouldn't happen

		TXA
		PHA

		ASL	A				;word table
		TAX

		LDA	gameScoreCtrls, X
		STA	elemptr0
		LDA	gameScoreCtrls + 1, X
		STA	elemptr0 + 1

		JSR	ctrlsControlInvalidate

		PLA
		TAX

@exit:
		RTS

gameScoreCtrls:
		.word	label_detail_score0
		.word	label_detail_score1
		.word	label_detail_score2
		.word	label_detail_score3


;-------------------------------------------------------------------------------
;	gameSpeedInvalidate - as above, for the speed row.
;	IN	.X		corner 0..3
;-------------------------------------------------------------------------------
gameSpeedInvalidate:
;-------------------------------------------------------------------------------
		CPX	#$04
		BCS	@exit				;defensive - shouldn't happen

		TXA
		PHA

		ASL	A				;word table
		TAX

		LDA	gameSpeedCtrls, X
		STA	elemptr0
		LDA	gameSpeedCtrls + 1, X
		STA	elemptr0 + 1

		JSR	ctrlsControlInvalidate

		PLA
		TAX

@exit:
		RTS

gameSpeedCtrls:
		.word	label_detail_pwr2_0
		.word	label_detail_pwr2_1
		.word	label_detail_pwr2_2
		.word	label_detail_pwr2_3


;-------------------------------------------------------------------------------
;	gameSendBoardRowsReq - sends mcPlay/$0A (BoardRowsReq), the client
;	half of the row-paginated full-board sync (see SendBoardRows,
;	SnakeServer.pas). Payload is just the requested pair's starting row
;	index (0, 2, 4 ... 16) - the server replies with that row and the
;	one after it (mcPlay/$0B, BoardRowsData - see gameProcBoardRowsMsg).
;	IN	.A		starting row of the pair (even, 0..18)
;-------------------------------------------------------------------------------
gameSendBoardRowsReq:
;-------------------------------------------------------------------------------
		STA	gameSendRowTmp

		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$0A
		JSR	strsAppendChar

		LDA	gameSendRowTmp
		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS


;-------------------------------------------------------------------------------
;	gameSendDirection - sends mcPlay/$0E (Direction), payload [dir],
;	one TSnakeDir ordinal (SNAKE_DIR_UP/DOWN/LEFT/RIGHT).
;
;	The highest-frequency message this client sends, so it is the
;	smallest thing that works - no sequence number and no reply. A lost
;	turn needs no recovery because the next one replaces it outright;
;	there is no accumulated state to drift.
;	IN	.A		direction 0..3
;-------------------------------------------------------------------------------
gameSendDirection:
;-------------------------------------------------------------------------------
		STA	gameSendDirTmp

		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$0E
		JSR	strsAppendChar

		LDA	gameSendDirTmp
		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
;	Deliberately does NOT call clientNotifyFail. A direction is sent on
;	every change while playing, so a transient send failure here would
;	spray the log during exactly the moment the player is busiest. The
;	next turn re-sends anyway.
		RTS


;-------------------------------------------------------------------------------
;	gameKeyPress - GAME HOOK, called from ctrlsPageKeyPress
;	(fw_ctrls_net.s) before any framework key handling at all.
;	IN	.A		key code (also parked in msgsdat0)
;	OUT	carry set if the key was consumed
;
;	While this client holds a corner the cursor keys ARE the controls,
;	and are sent as Directions instead of navigating the UI. dengland
;	asked for this because his joystick is forty years old and showing
;	it (2026-08-25) - it also makes the game playable on a machine with
;	nothing plugged into port 2 at all.
;
;	Gated on gameMySlot, so a spectator's cursor keys still navigate
;	normally and nothing is stolen from the UI when there is no snake
;	to steer. Every other key falls straight through, so accelerators,
;	TAB and chat typing all keep working while playing.
;-------------------------------------------------------------------------------
gameKeyPress:
;-------------------------------------------------------------------------------
		LDX	gameMySlot
		CPX	#SLOT_CLAIM_NONE
		BEQ	@notours

		CMP	#KEY_C64_CUP
		BEQ	@up
		CMP	#KEY_C64_CDOWN
		BEQ	@down
		CMP	#KEY_C64_CLEFT
		BEQ	@left
		CMP	#KEY_C64_CRIGHT
		BEQ	@right

@notours:
		CLC					;not ours - let the UI have it
		RTS

@up:
		LDA	#SNAKE_DIR_UP
		JMP	@send

@down:
		LDA	#SNAKE_DIR_DOWN
		JMP	@send

@left:
		LDA	#SNAKE_DIR_LEFT
		JMP	@send

@right:
		LDA	#SNAKE_DIR_RIGHT

@send:
;	Keys auto-repeat and the server would only re-apply the heading it
;	already has, so drop a repeat of whatever was last sent. Shares
;	gameLastDir with gamePollJoystick deliberately - the stick and the
;	keys are two ways of saying the same thing, and one record of what
;	actually went out stops them fighting over it.
		CMP	gameLastDir
		BEQ	@done

		STA	gameLastDir

		JSR	gameSendDirection

@done:
		SEC					;consumed either way
		RTS


;-------------------------------------------------------------------------------
;	gamePollJoystick - turn control port 2 into Direction messages.
;	Called from gamePollTick while this client holds a corner.
;
;	Sends only on CHANGE, not every frame: at 50Hz a held stick would
;	otherwise be ~50 messages a second per player, which is both
;	pointless (the server keeps the last one) and enough to matter on a
;	board with four of them.
;
;	Diagonals resolve to whichever axis is tested first rather than
;	being rejected. Rejecting them makes a stick feel dead in the
;	corners, where a player rolling from one direction to the next
;	passes through a diagonal every single time.
;-------------------------------------------------------------------------------
gamePollJoystick:
;-------------------------------------------------------------------------------
		LDA	joyDirs
		AND	#%00001111
		BEQ	@centred			;stick at rest - nothing to send

		LDX	#SNAKE_DIR_UP
		LSR	A				;bit0 - up
		BCS	@have

		LDX	#SNAKE_DIR_DOWN
		LSR	A				;bit1 - down
		BCS	@have

		LDX	#SNAKE_DIR_LEFT
		LSR	A				;bit2 - left
		BCS	@have

		LDX	#SNAKE_DIR_RIGHT		;bit3 - right, all that's left

@have:
;	Stick unmoved since the last poll - nothing to do. This is the
;	STICK's own edge detection and is separate from gameLastDir below,
;	which records what was actually transmitted.
		CPX	gameJoyLast
		BEQ	@done

		STX	gameJoyLast

;	Moved, but possibly onto a heading already sent (by the keys, or by
;	the stick before a release). The server would only re-apply what it
;	has, so don't spend a message on it.
		CPX	gameLastDir
		BEQ	@done

		STX	gameLastDir

		TXA
		JMP	gameSendDirection
;		RTS

@centred:
;	Releasing the stick doesn't stop the snake - it keeps its heading,
;	as snakes do. Only the stick's own edge state is cleared here.
;
;	gameLastDir is deliberately NOT touched: it is shared with
;	gameKeyPress, and the stick sits centred the entire time somebody
;	is playing on the cursor keys. Clearing it here would defeat the
;	keys' repeat suppression completely and put a message on the wire
;	for every auto-repeat.
		LDA	#SNAKE_DIR_NONE
		STA	gameJoyLast

@done:
		RTS


;-------------------------------------------------------------------------------
;	gameSendSlotClaim - sends mcPlay/$05 (SlotClaim), asking the server
;	for one of the 4 corners. Payload is a single [slot] byte: 0..3 for
;	a specific corner, or SLOT_CLAIM_ANY ($FF) for whichever is free.
;
;	$05 and not $04, which would be the obvious next free number: the
;	server still has method 4 bound to the dead chess-era RoomPeer chat
;	handler, which matches FIRST and would swallow the claim. See
;	ProcessPlayerMessage (SnakeServer.pas).
;
;	The reply is a SlotStatus broadcast (mcPlay/$07) if it worked, or a
;	server error if it didn't - nothing is assumed here, so slotStates
;	only ever reflects what the server actually confirmed.
;	IN	.A		slot 0..3, or SLOT_CLAIM_ANY
;-------------------------------------------------------------------------------
gameSendSlotClaim:
;-------------------------------------------------------------------------------
		STA	gameSendSlotTmp

		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$05
		JSR	strsAppendChar

		LDA	gameSendSlotTmp
		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
;	The claim never left, so nothing will ever come back to settle it -
;	drop the outstanding marker here or gameSlotPress's don't-stack
;	guard would block every future claim for the rest of the session.
		LDA	#SLOT_CLAIM_NONE
		STA	gameSlotWanted

		JSR	clientNotifyFail

		RTS


;-------------------------------------------------------------------------------
;	gameSendSlotRelease - sends mcPlay/$08 (SlotRelease), giving up
;	whichever corner this client holds. Payload-less, same shape as
;	WatchStop below - the server knows who we are and looks the slot up
;	itself, and it stays silent if we held none, so this is safe to fire
;	without tracking whether a claim ever succeeded.
;-------------------------------------------------------------------------------
gameSendSlotRelease:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$08
		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS


;-------------------------------------------------------------------------------
;	gameSendWatchStart/gameSendWatchStop - sends mcPlay/$0C or /$0D,
;	telling the server this client's UI has entered or left the board
;	page (see gamePollTick's edge-detect). Payload-less - just the
;	category|method header byte, same shape as any other zero-payload
;	message in this codebase (e.g. clientSendPlayJoin's header before
;	its own payload is appended). ProcessPlayerMessage
;	(SnakeServer.pas) only reaches a player already in this game, so
;	there's nothing else to identify.
;-------------------------------------------------------------------------------
gameSendWatchStart:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$0C
		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS

gameSendWatchStop:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$0D
		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS


;-------------------------------------------------------------------------------
;	gameBoardSyncStart - (re)starts a full row-paginated board sync:
;	clears the board area on screen (gameClearBoardArea - "first we
;	need to clear the area", so stale tiles from whatever was drawn
;	before don't linger while the new board streams in), then clears
;	every fetched flag and boardSyncDone, then kicks off the first
;	request. Called when the client starts watching the board page
;	(see gamePollTick's edge-detect) - a fresh board copy is exactly
;	what's needed the moment the player actually looks at it.
;-------------------------------------------------------------------------------
gameBoardSyncStart:
;-------------------------------------------------------------------------------
		JSR	gameClearBoardArea

		LDA	#$00
		STA	boardSyncDone
		STA	boardSyncWaiting

		LDX	#BOARD_ROW_PAIRS - 1
@clr:
		STA	boardFetched, X
		DEX
		BPL	@clr

		JMP	gameBoardSyncRequestNext
;		RTS


;-------------------------------------------------------------------------------
;	gameBoardSyncRequestNext - finds the first not-yet-fetched row-pair
;	and requests it; if every pair is already fetched, marks the sync
;	complete instead. Called both to kick off a fresh sync
;	(gameBoardSyncStart) and to chain on to the next pair once a reply
;	arrives (gameProcBoardRowsMsg).
;-------------------------------------------------------------------------------
gameBoardSyncRequestNext:
;-------------------------------------------------------------------------------
		LDX	#$00
@scan:
		LDA	boardFetched, X
		BEQ	@found

		INX
		CPX	#BOARD_ROW_PAIRS
		BCC	@scan

;	Every pair fetched - sync complete.
		LDA	#$01
		STA	boardSyncDone

		LDA	#$00
		STA	boardSyncWaiting

		RTS

@found:
		STX	boardSyncPair

		TXA
		ASL	A				;pairIndex * 2 = start row
		JSR	gameSendBoardRowsReq

		LDA	#$01
		STA	boardSyncWaiting

		LDA	FRAMECOUNT
		STA	boardSyncReqFrame

		RTS


;-------------------------------------------------------------------------------
;	gameProcGameStatusMsg - mcPlay/$06 (GameStatus). Payload is a
;	single TGameState byte (see TSnakeGame.SendGameStatus) - stored (see
;	gameState's own comment above), and also treated as this client's
;	"you successfully joined the board" confirmation, since
;	TSnakeGame.Add (SnakeServer.pas) only ever sends GameStatus once, to
;	the newcomer, right after a successful join - there's no separate
;	Join broadcast the way chess's 2-seat model had one. Flips
;	button_play_join/button_play_part accordingly (clientPlayJoinedSelf,
;	fw_ctrls_net.s) - this was missing entirely until 2026-08-24 (see
;	that routine's own comment), which is why the Join button never
;	visibly changed to Part. Doesn't kick off a board sync any more -
;	that used to happen here too (on every join, regardless of what the
;	client was actually looking at), but now waits for gamePollTick to
;	notice the client has actually navigated to page_detail (WatchStart)
;	instead, so a spectator who joins and stays on the highscore/
;	overview page never pulls board data it doesn't need.
;-------------------------------------------------------------------------------
gameProcGameStatusMsg:
;-------------------------------------------------------------------------------
		LDA	readmsg0 + 2
		STA	gameState

;	Status line - STATUS_TEXT_LEN characters, already formatted by the
;	server, straight into the label's own text.
		LDY	#STATUS_TEXT_LEN - 1
@copystatus:
		LDA	readmsg0 + 5, Y
		STA	statusText, Y
		DEY
		BPL	@copystatus

;	Red for the last STATUS_WARN_SECS, ordinary text colour otherwise.
;	Set on the control here rather than from a present hook because it is
;	a plain label - the framework's own draw picks the colour up, and
;	CLR_SPEC_TEXT is what lets a raw palette value ride in the control's
;	colour byte (see gameHudBarPresent for the full note).
;
;	The seconds arrive as a separate 16-bit count precisely so this test
;	needs no digit parsing.
		LDA	readmsg0 + 4			;seconds, high byte
		BNE	@normal				;over 255 left - plenty

		LDA	readmsg0 + 3			;seconds, low byte
		CMP	#STATUS_WARN_SECS + 1
		BCS	@normal

		LDA	#CLR_LOG_C64_RED | CLR_SPEC_TEXT
		BRA	@setclr

@normal:
		LDA	#CLR_LOG_C64_WHITE | CLR_SPEC_TEXT

@setclr:
		LDX	#<label_detail_status
		STX	elemptr0
		LDX	#>label_detail_status
		STX	elemptr0 + 1

		LDY	#ELEMENT::colour
		STA	(elemptr0), Y

		JSR	ctrlsControlInvalidate

;	The JOIN half fires only on the FIRST GameStatus. This message used
;	to arrive exactly once, so its arrival was the confirmation; it now
;	carries the level clock and arrives every second, and re-running the
;	join handling on each one would flip the Join/Part buttons about
;	once a second forever.
		LDA	gameJoinDone
		BNE	@exit

		LDA	#$01
		STA	gameJoinDone

		JMP	clientPlayJoinedSelf

@exit:
		RTS


;-------------------------------------------------------------------------------
;	gameProcSlotStatusMsg - mcPlay/$07 (SlotStatus). Payload is [slot,
;	state, isyou] (see TSnakeGame.SendSlotStatus) - the state is stored
;	in slotStates (see its own comment above), and the third byte is
;	what maintains gameMySlot.
;
;	The isyou byte is per-RECIPIENT, not per-slot: the server sends this
;	message once to each player in the zone and sets the flag only for
;	whoever actually holds the corner. So this is the only place that
;	ever learns which corner is ours, and it is authoritative - a claim
;	is never assumed to have worked at the point of sending.
;-------------------------------------------------------------------------------
gameProcSlotStatusMsg:
;-------------------------------------------------------------------------------
		LDA	readmsg0 + 2			;slot (0..3)
		TAX
		CPX	#$04
		BCS	@bad				;defensive - shouldn't happen

		LDA	readmsg0 + 3			;state
		STA	slotStates, X

;	Score - SCORE_TEXT_LEN ASCII digits, copied straight into this
;	corner's label text. The server sends it already formatted and
;	zero-padded to a fixed width, so there is nothing to convert and no
;	terminator to write: the NUL after each buffer is part of the
;	initialised data and never moves.
;
;	Done BEFORE any JSR below, so nothing can be using tempptr0 in
;	between.
		TXA
		ASL	A				;word table
		TAY

		LDA	gameScoreTexts, Y
		STA	tempptr0
		LDA	gameScoreTexts + 1, Y
		STA	tempptr0 + 1

		LDY	#SCORE_TEXT_LEN - 1
@copyscore:
		LDA	readmsg0 + 6, Y
		STA	(tempptr0), Y
		DEY
		BPL	@copyscore

		LDA	readmsg0 + 5			;lives
		STA	slotLives, X

;	Speed gear - the byte after the score digits. Ticks per step, so
;	smaller is faster; gameSpeedPresent turns it into a bar length.
		LDA	readmsg0 + 6 + SCORE_TEXT_LEN
		STA	slotSpeed, X

;	All three rows are only redrawn by their own present hook (or, for
;	the score, its own label draw), so each has to be invalidated or it
;	keeps showing the old value until something unrelated dirties the
;	panel. All three preserve X.
		JSR	gameLivesInvalidate
		JSR	gameScoreInvalidate
		JSR	gameSpeedInvalidate

;	If this is OUR corner, forget what direction we last sent. A death
;	respawns the snake on a fresh heading chosen by the server, and
;	gameLastDir still holds whatever we were steering with when we
;	died - so pressing that same direction again would be deduped away
;	and the snake would keep the spawn heading instead of turning
;	(dengland, 2026-08-25).
;
;	Done on any SlotStatus for our own corner rather than only on a
;	death: claim, death and respawn all land here, and the worst case
;	of over-triggering is one redundant direction message.
		CPX	gameMySlot
		BNE	@nodirreset

		LDA	#SNAKE_DIR_NONE
		STA	gameLastDir
		STA	gameJoyLast

@nodirreset:

;	Whatever the server says about this corner settles any claim we had
;	outstanding for it, granted or refused.
		CPX	gameSlotWanted
		BNE	@notours

		LDA	#SLOT_CLAIM_NONE
		STA	gameSlotWanted

@notours:
		LDA	readmsg0 + 4			;isyou
		BEQ	@notmine

		STX	gameMySlot

		RTS

@notmine:
;	Not ours. Only clear gameMySlot if this message is about the very
;	corner we thought we held - a report about somebody else's corner
;	says nothing about ours, and clearing on it would drop our own the
;	moment any other player claimed one.
		CPX	gameMySlot
		BNE	@bad

		LDA	#SLOT_CLAIM_NONE
		STA	gameMySlot

@bad:
		RTS


;-------------------------------------------------------------------------------
;	gameProcShakeMsg - mcPlay/$0C (Shake). Payload is [frames], and that
;	is the whole message: the server says how long, the client does the
;	rest. Zero frames stops a shake early.
;-------------------------------------------------------------------------------
gameProcShakeMsg:
		LDA	readmsg0 + 2
		BEQ	@stop

		LDX	gameShakeActive
		BNE	@setlen

;	Starting fresh - snapshot the character-generator position so the
;	display can be put back exactly where it was, rather than to an
;	assumed default. The framework sets these up during its own video
;	init and nothing here knows what it chose, so guessing would leave
;	the whole screen permanently offset.
		LDA	VAL_VIC_TEXTYPOS
		STA	gameShakeSaveY

		LDA	VAL_VIC_TEXTXPOS
		STA	gameShakeSaveX

		LDA	#$01
		STA	gameShakeActive

		LDA	FRAMECOUNT
		STA	gameShakeLastFrame

@setlen:
		LDA	readmsg0 + 2
		STA	gameShakeFrames

		RTS

@stop:
		JMP	gameShakeRestore


;-------------------------------------------------------------------------------
;	gameShakeTick - advance the shake by at most one frame. Called from
;	gamePollTick, which runs once per MAIN LOOP iteration - that is NOT
;	once per frame, so the countdown is paced off FRAMECOUNT instead of
;	off call count, or the shake would run at whatever speed the loop
;	happens to be going.
;	USED	.A, .X
;-------------------------------------------------------------------------------
gameShakeTick:
		LDA	gameShakeActive
		BNE	@active

		RTS

@active:
		LDA	FRAMECOUNT
		CMP	gameShakeLastFrame
		BNE	@newframe

		RTS					;same frame - nothing to do yet

@newframe:
		STA	gameShakeLastFrame

		DEC	gameShakeFrames
		BEQ	gameShakeRestore

;	EOR with FRAMECOUNT as well as reading the hardware RNG: the RNG is
;	not checked for readiness here (a bounded wait every frame would be
;	silly for a cosmetic effect), and an unready RNG hands back the same
;	byte repeatedly - which would freeze the screen at one offset and
;	look like a bug rather than a shake.
		LDA	VAL_M65_RANDOM
		EOR	FRAMECOUNT
		STA	gameShakeTmp

;	Offsets are added to the SAVED position rather than written
;	absolutely, so the shake is about wherever the framework put the
;	display rather than about a hardcoded origin. GAME_SHAKE_AMP keeps
;	the throw small.
		AND	#GAME_SHAKE_AMP
		CLC
		ADC	gameShakeSaveY
		STA	VAL_VIC_TEXTYPOS

;	X takes DIFFERENT bits of the same random byte, so the two axes
;	don't move in lockstep - together they'd read as a diagonal slide
;	rather than a shake.
		LDA	gameShakeTmp
		LSR
		LSR
		LSR
		AND	#GAME_SHAKE_AMP
		CLC
		ADC	gameShakeSaveX
		STA	VAL_VIC_TEXTXPOS

		RTS


;-------------------------------------------------------------------------------
;	gameShakeRestore - put the scroll bits back and stop shaking. Safe
;	to call when no shake is running.
;	USED	.A
;-------------------------------------------------------------------------------
gameShakeRestore:
		LDA	#$00
		STA	gameShakeFrames
		STA	gameShakeActive

		LDA	gameShakeSaveY
		STA	VAL_VIC_TEXTYPOS

		LDA	gameShakeSaveX
		STA	VAL_VIC_TEXTXPOS

		RTS


;-------------------------------------------------------------------------------
;	gameProcTileDeltaMsg - mcPlay/$09 (TileDelta). Payload is [count,
;	(row, col, tile) * count] (see TSnakeGame.SendTileDeltas/Tick,
;	SnakeServer.pas) - the general "these cells changed" broadcast; the
;	attract-mode bounce is its first real use, not a bespoke message of
;	its own (dengland's own correction, 2026-08-24: "why is this in the
;	client, shouldn't it just be getting tile deltas from the
;	server?"). Updates boardTiles and redraws each named cell directly
;	- single-cell STCELL16/STCOLR16 writes via the same gameTileChars/
;	gameTileColrs lookup gameDrawBoardRows uses, not a DMA row burst
;	(there's normally only 1-2 cells per message, not a whole row).
;-------------------------------------------------------------------------------
gameProcTileDeltaMsg:
		LDA	readmsg0 + 2			;delta count
		STA	gameDeltaCount
		LBEQ	@done				;plain BEQ is out of 8-bit branch range here

		LDX	#$00				;byte offset into the (row,col,tile) triples

@loop:
		LDA	readmsg0 + 3, X
		STA	gameDeltaRow
		LDA	readmsg0 + 4, X
		STA	gameDeltaCol
		LDA	readmsg0 + 5, X
		STA	gameDeltaTile

;	Ignore a delta naming a cell that isn't on the board at all. Both
;	tables below are exactly BOARD_ROWS/BOARD_COLS entries long, so an
;	out-of-range row would index straight past them into whatever
;	follows and hand the writes below a junk address - the same class
;	of wild write the missing boardTiles base caused (see the comment
;	on the boardptr1 setup). A malformed message shouldn't be able to
;	scribble on memory, so range-check here rather than trusting the
;	wire.
		LDA	gameDeltaRow
		CMP	#BOARD_ROWS
		BCS	@next
		LDA	gameDeltaCol
		CMP	#BOARD_COLS
		BCS	@next

;	Update boardTiles[row][col]. boardRowOffsetLo/Hi hold an offset
;	INTO boardTiles, not an address - the boardTiles base has to be
;	added, exactly as gameProcBoardRowsMsg and gameDrawBoardRows both
;	do with boardPairOffsetLo/Hi. Leaving it out (as this did until
;	2026-08-24) made every delta write its tile value to $0000 +
;	row * BOARD_COLS + col: raw zero page, the stack and $0200-$020F.
;	That trashed pageptr0 ($10/$11), the keyboard queue ($46-$4B),
;	boardptr0/boardptr1 themselves ($51-$56 - which then sent the
;	STCELL16/STCOLR16 writes below into random far memory) and return
;	addresses on the stack, depending only on which cell the attract
;	animation happened to touch. The column goes in .Y rather than
;	into the pointer, so there's just the one base add to get right.
		LDY	gameDeltaRow
		LDA	boardRowOffsetLo, Y
		CLC
		ADC	#<boardTiles
		STA	boardptr1
		LDA	boardRowOffsetHi, Y
		ADC	#>boardTiles
		STA	boardptr1 + 1

		LDA	gameDeltaTile
		LDY	gameDeltaCol
		STA	(boardptr1), Y

;	Draw the cell - screen row = board row + 5.
		LDA	gameDeltaRow
		CLC
		ADC	#$05
		STA	gameDeltaScreenRow

		LDY	gameDeltaScreenRow
		LDA	screenRowsLo, Y
		STA	boardptr0
		LDA	screenRowsHi, Y
		STA	boardptr0 + 1
		LDA	#$01
		STA	boardptr0 + 2
		LDA	#$00
		STA	boardptr0 + 3

		LDY	gameDeltaTile
		LDA	gameTileChars, Y
		STCELL16 boardptr0, gameDeltaCol

;	Re-point at the COLOUR row before the colour write - same low byte
;	as the screen row, but colour RAM's real physical high byte
;	(colourRowsHiPhys), not screenRowsHi. Missing this re-point is what
;	froze the client live (2026-08-24) - STCOLR16 was writing through
;	the screen row's own pointer, into the wrong memory entirely.
		LDY	gameDeltaScreenRow
		LDA	screenRowsLo, Y
		STA	boardptr0
		LDA	colourRowsHiPhys, Y
		STA	boardptr0 + 1

		LDY	gameDeltaTile
		LDA	gameTileColrs, Y
		STCOLR16 boardptr0, gameDeltaCol

;	Advance to the next delta triple and loop.
@next:
		TXA
		CLC
		ADC	#$03
		TAX

		DEC	gameDeltaCount
		LBNE	@loop				;plain BNE is out of 8-bit branch range here

@done:
		RTS


;-------------------------------------------------------------------------------
;	gameProcBoardRowsMsg - mcPlay/$0B (BoardRowsData), the reply to
;	gameSendBoardRowsReq. Payload is [startRow, 30 bytes of row
;	startRow, 30 bytes of row startRow+1] (see SendBoardRows,
;	SnakeServer.pas) - readmsg0+2 is startRow, readmsg0+3 onward is the
;	60 bytes of tile data, read directly out of readmsg0 the same way
;	chess's own clientProcPlayBoardSyncMsg read its (differently
;	shaped) board payload. Marks the pair fetched, hand-draws the 2 rows
;	just received (gameDrawBoardRows - immediate visual feedback per
;	pair, not just once the whole sync finishes), and immediately
;	chains to the next request - the normal way a sync advances, with
;	gamePollTick's timeout only needed if a reply never shows up at all.
;-------------------------------------------------------------------------------
gameProcBoardRowsMsg:
;-------------------------------------------------------------------------------
		LDA	readmsg0 + 2			;starting row of this pair
		LSR	A				;pairIndex = startRow / 2
		TAX

;	Ignore a pair index that isn't on the board. boardPairOffsetLo/Hi
;	are exactly BOARD_ROW_PAIRS entries long, so an out-of-range index
;	reads past them and hands the 60-byte copy below a junk
;	destination - the same class of wild write the missing boardTiles
;	base caused. gameProcTileDeltaMsg has always range checked its
;	row/col; this path never did.
;
;	It matters more than it used to: the server will no longer only
;	send these in answer to a request. A level or screen transition
;	pushes whole-board chunks unprompted (cheaper than sending the
;	change as deltas), so this side must not assume the row named is
;	one it asked for.
		CPX	#BOARD_ROW_PAIRS
		BCC	@inrange

		RTS

@inrange:
		LDA	boardPairOffsetLo, X
		CLC
		ADC	#<boardTiles
		STA	tempptr3
		LDA	boardPairOffsetHi, X
		ADC	#>boardTiles
		STA	tempptr3 + 1

		LDY	#$00
@copy:
		LDA	readmsg0 + 3, Y
		STA	(tempptr3), Y

		INY
		CPY	#BOARD_COLS * 2
		BCC	@copy

		LDA	#$01
		STA	boardFetched, X

		LDA	#$00
		STA	boardSyncWaiting

		LDA	readmsg0 + 2
		JSR	gameDrawBoardRows

		JMP	gameBoardSyncRequestNext
;		RTS


;===============================================================================
; BOARD RENDER - hand-drawn straight to screen RAM, not through the ctrls
; widget engine at all ("we don't need a proper control for the board,
; we'll just write there" - user, 2026-08-24). Board occupies screen cols
; 0-29, rows 5-24 (30x20, starting at row 5 per dengland's own layout
; call, and grown from the original's 18 rows to fill the screen down to
; page_detail's last row) - deliberately outside panel_detail_hud's
; own rect (cols 30-39), so the two never fight over the same screen cells
; (see panel_detail_hud's own comment).
;
; Both routines are DMA-driven (dmaFillRow/dmaCopyRow16, fw_ctrls_net.s) -
; a whole 30-column row goes in as one DMA burst per row per plane
; (screen chars, then colours), not a 30-cell STCELL16/STCOLR16 CPU loop.
; User's own question (2026-08-24): yes, a board row is exactly the kind
; of "string" those DMA jobs already move around elsewhere in this
; codebase (see dmaFillRow's use in ctrlsEraseBkg) - screen RAM just
; wasn't being written that way here yet when the board first went up.
;
; Tile values (the TILE_* constants, SnakeServer.pas) map
; to screen char/colour via gameTileChars/gameTileColrs, a small lookup
; table shared by gameDrawBoardRows (a whole row at a time) and
; gameProcTileDeltaMsg (single cells, mcPlay/$09 - see its own comment)
; - real tile types (food, snake segments, etc) just extend the table,
; not a growing pile of branches. Colours are CLR_LOG_C64_* (fw_core.s -
; raw system palette colours, added after a mid-air mix-up over which
; raw hex value was actually light green, 2026-08-24).
;===============================================================================

;-------------------------------------------------------------------------------
;	gameClearBoardArea - fills the whole board area with the floor tile
;	($0020) and colour (black, $00), straight to screen/colour RAM, one
;	dmaFillRow burst per row per plane (40 DMA jobs total, not 600
;	individual cell writes). Called once at the start of a fresh sync
;	(gameBoardSyncStart) so stale tiles from whatever was there before
;	(a previous sync, or just whatever screen RAM happened to hold)
;	don't linger visibly while the new board streams in row-pair by
;	row-pair.
;-------------------------------------------------------------------------------
gameClearBoardArea:
		LDA	#$01				;bank - screen/colour RAM is at $01xxxx
		STA	dmaDstBank

		LDA	#BOARD_COLS
		STA	dmaCnt

		LDX	#$00				;board-relative row, 0..19

@rowloop:
		TXA
		CLC
		ADC	#$05				;board row -> absolute screen row
		TAY

		LDA	screenRowsLo, Y
		STA	dmaDst
		LDA	screenRowsHi, Y
		STA	dmaDst + 1

		LDA	#$20				;TILE_FLOOR's screen char
		JSR	dmaFillRow

;	Colour row - same low byte as the screen row (screenRowsLo), a
;	different high-byte table (colourRowsHiPhys - colour RAM's real
;	physical address, not the $D800 CPU alias), offset +1 into each
;	cell to land in the high byte (STCOLR16's own layout note).
		LDA	screenRowsLo, Y
		CLC
		ADC	#$01
		STA	dmaDst
		LDA	colourRowsHiPhys, Y
		ADC	#$00
		STA	dmaDst + 1

		LDA	#CLR_LOG_C64_BLACK		;TILE_FLOOR's colour
		JSR	dmaFillRow

		INX
		CPX	#BOARD_ROWS
		BCC	@rowloop

		RTS


;-------------------------------------------------------------------------------
;	gameDrawBoardRows - hand-draws the 2 rows of a just-received
;	row-pair (see gameProcBoardRowsMsg) by reading back out of
;	boardTiles. Builds one row's chars into gameRowCharBuf and colours
;	into gameRowColrBuf (unavoidable per-cell CPU work - the tile data
;	varies cell to cell), then DMA-copies each buffer into place in one
;	burst (dmaCopyRow16) rather than 30 individual STCELL16/STCOLR16
;	writes per row. Reuses the exact same pairIndex -> boardTiles offset
;	lookup gameProcBoardRowsMsg just used to copy the data in
;	(boardPairOffsetLo/Hi), rather than threading tempptr3 through from
;	the caller, so this stays callable on its own later if a full
;	redraw is ever needed without a fresh network reply driving it.
;	IN	.A		starting row of the pair (even, 0..18)
;-------------------------------------------------------------------------------
gameDrawBoardRows:
		STA	gameDrawRowTmp

		LSR	A				;pairIndex = startRow / 2
		TAX

		LDA	boardPairOffsetLo, X
		CLC
		ADC	#<boardTiles
		STA	tempptr3
		LDA	boardPairOffsetHi, X
		ADC	#>boardTiles
		STA	tempptr3 + 1

		LDA	gameDrawRowTmp
		CLC
		ADC	#$05				;board row -> absolute screen row
		STA	gameDrawRowTmp2

		LDA	#$01				;bank - screen/colour RAM is at $01xxxx
		STA	dmaDstBank

		LDA	#$00				;0 = pair's first row, 1 = second - a
		STA	gameDrawRowInPair		;	plain byte, not X, so X stays free
							;	below for the tile-value lookup
@rowloop:
		LDY	#$00
@buildloop:
		LDA	(tempptr3), Y
		TAX
		LDA	gameTileChars, X
		STA	gameRowCharBuf, Y
		LDA	gameTileColrs, X
		STA	gameRowColrBuf, Y

		INY
		CPY	#BOARD_COLS
		BCC	@buildloop

		LDA	gameDrawRowInPair
		CLC
		ADC	gameDrawRowTmp2
		TAY

		LDA	#BOARD_COLS
		STA	dmaCnt

		LDA	#<gameRowCharBuf
		STA	dmaSrc
		LDA	#>gameRowCharBuf
		STA	dmaSrc + 1
		LDA	screenRowsLo, Y
		STA	dmaDst
		LDA	screenRowsHi, Y
		STA	dmaDst + 1

		JSR	dmaCopyRow16

		LDA	#<gameRowColrBuf
		STA	dmaSrc
		LDA	#>gameRowColrBuf
		STA	dmaSrc + 1
		LDA	screenRowsLo, Y
		CLC
		ADC	#$01
		STA	dmaDst
		LDA	colourRowsHiPhys, Y
		ADC	#$00
		STA	dmaDst + 1

		JSR	dmaCopyRow16

;	Advance the source pointer to the pair's second row (30 bytes on).
		LDA	tempptr3
		CLC
		ADC	#BOARD_COLS
		STA	tempptr3
		LDA	tempptr3 + 1
		ADC	#$00
		STA	tempptr3 + 1

		INC	gameDrawRowInPair
		LDA	gameDrawRowInPair
		CMP	#$02
		BCC	@rowloop

		RTS


;===============================================================================
; PAGE: page_ovrvw - reached from page_play. Placeholder spectator/corner-
; select overview - real 4-corner slot-claim UI and live status are
; follow-up work; this is just enough to be a valid, navigable page.
;===============================================================================
page_ovrvw:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00		;options	.byte
			.byte	CLR_TEXT	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_detail	;nxtpage
			.word	page_play	;bakpage
			.word	text_page_ovrvw	;textptr	.word
			.byte	$10		;textoffx .byte
			.word	page_ovrvw_pnls	;panels	.word
			.byte	$02

page_ovrvw_pnls:
			.word	tab_main
			.word	panel_ovrvw_main
			.word	$0000

;	Highscore table - display-only, deliberately no interactive
;	controls (exercises the ctrlsMoveActiveControl guard fix above -
;	this was the page that first hung before that fix existed). Row
;	content is static placeholder text for now; real scores are
;	follow-up work.
panel_ovrvw_main:
;			.word	$0000			;prepare
			.word	ctrlsPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00
			.byte	CLR_INSET		;colour	.byte
			.byte	$00			;posx	.byte
			.byte	$03			;posy	.byte
			.byte	$28			;width	.byte
			.byte	$16			;height	.byte
			.byte	$00			;tag	.byte
			.word	page_ovrvw
			.word	panel_ovrvw_main_ctrls	;controls
			.byte	$06

panel_ovrvw_main_ctrls:
			.word	label_ovrvw_title
			.word	label_ovrvw_score0
			.word	label_ovrvw_score1
			.word	label_ovrvw_score2
			.word	label_ovrvw_score3
			.word	label_ovrvw_score4
			.word	$0000

label_ovrvw_title:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_TEXT	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$04		;posy	.byte
			.byte	$26		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_ovrvw_main	;panel	.word
			.word	text_ovrvw_title	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_ovrvw_score0:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$06		;posy	.byte
			.byte	$26		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_ovrvw_main	;panel	.word
			.word	text_ovrvw_score0	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_ovrvw_score1:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$07		;posy	.byte
			.byte	$26		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_ovrvw_main	;panel	.word
			.word	text_ovrvw_score1	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_ovrvw_score2:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$08		;posy	.byte
			.byte	$26		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_ovrvw_main	;panel	.word
			.word	text_ovrvw_score2	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_ovrvw_score3:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$09		;posy	.byte
			.byte	$26		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_ovrvw_main	;panel	.word
			.word	text_ovrvw_score3	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_ovrvw_score4:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$0A		;posy	.byte
			.byte	$26		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_ovrvw_main	;panel	.word
			.word	text_ovrvw_score4	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word


;===============================================================================
; PAGE: page_detail - reached from page_ovrvw. Placeholder for the actual
; board - real tile-grid rendering is follow-up work (30x18 board, delta
; broadcast - see the project's design notes); this is just enough to be
; a valid, navigable page. Also where the 4 corner "start" buttons live
; (moved here from page_ovrvw per correction - the overview page is just
; the highscore table above, no interactive controls at all).
;===============================================================================
page_detail:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00		;options	.byte
			.byte	CLR_TEXT	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	$0000		;nxtpage
			.word	page_ovrvw	;bakpage
			.word	text_page_detail	;textptr	.word
			.byte	$10		;textoffx .byte
			.word	page_detail_pnls	;panels	.word
			.byte	$03

;	tab_main must be listed here (as chess's original page_detail_pnls
;	did) or the main BEGIN/CHAT/PLAY/PREFS tab navigation becomes
;	unreachable from this page - caught live (2026-08-24): could
;	navigate the start buttons but not the tabs, since tab_main's own
;	controls simply weren't part of this page's panel chain at all.
;
;	panel_detail_bkg listed next, mirroring chess's own original
;	page_detail_pnls order (tab_main, panel_detail_bkg, panel_detail_
;	board, lpanel_detail_log) - a plain full-page background panel,
;	needed for the same reason chess had one: nothing else clears
;	page_detail's screen area on entry. panel_detail_hud only covers
;	its own right-hand column and the board is hand-drawn (neither
;	clears anything outside their own rects), so without this, leaving
;	one page for another left stale tiles from the PREVIOUS page
;	visible underneath - caught live (2026-08-24). Listed BEFORE
;	panel_detail_hud so hud's own background+controls draw on top of,
;	not under, this fill.
page_detail_pnls:
			.word	tab_main
			.word	panel_detail_bkg
			.word	panel_detail_hud
			.word	$0000

panel_detail_bkg:
;			.word	$0000			;prepare
			.word	gameDetailBkgPresent	;present
			.word	ctrlsPanelDefChanged	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00
			.byte	CLR_INSET		;colour	.byte
			.byte	$00			;posx	.byte
			.byte	$03			;posy	.byte
			.byte	$28			;width	.byte
			.byte	$16			;height	.byte
			.byte	$00			;tag	.byte
			.word	page_detail
			.word	panel_detail_bkg_ctrls	;controls
			.byte	$01

panel_detail_bkg_ctrls:
			.word	label_detail_status
			.word	$0000

;	panel_detail_hud - the right-hand HUD column only (cols 30-39,
;	rows 5-24), NOT the whole page. Deliberately does not overlap the
;	board area (cols 0-29, rows 5-22) - the board is hand-drawn
;	straight to screen RAM (see the BOARD RENDER section below), not a
;	control, and this panel's own background redraws on every
;	STATE_DIRTY present pass (ctrlsPanelDefPresent -> ctrlsEraseBkg)
;	would blow away hand-drawn tiles if its rect ever covered them.
;	Was "panel_detail_placeholder" (just a "coming soon" label) before
;	real content existed here (2026-08-24).
panel_detail_hud:
;			.word	$0000			;prepare
			.word	ctrlsPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00
			.byte	CLR_INSET		;colour	.byte
			.byte	$1E			;posx	.byte	(30 - right of the board)
			.byte	$05			;posy	.byte	(5 - level with the board's top)
			.byte	$0A			;width	.byte	(10 - cols 30-39)
			.byte	$14			;height	.byte	(20 - four 5-row corner blocks)
			.byte	$00			;tag	.byte
			.word	page_detail
			.word	panel_detail_hud_ctrls	;controls
			.byte	$10

;	Four 5-row blocks (start button, score, 2 power-up slots, blank
;	separator), one per corner, filling the column top to bottom - the
;	blank row is just unused panel background, no control needed for it.
panel_detail_hud_ctrls:
			.word	button_detail_start0
			.word	label_detail_score0
			.word	label_detail_pwr1_0
			.word	label_detail_pwr2_0
			.word	button_detail_start1
			.word	label_detail_score1
			.word	label_detail_pwr1_1
			.word	label_detail_pwr2_1
			.word	button_detail_start2
			.word	label_detail_score2
			.word	label_detail_pwr1_2
			.word	label_detail_pwr2_2
			.word	button_detail_start3
			.word	label_detail_score3
			.word	label_detail_pwr1_3
			.word	label_detail_pwr2_3
			.word	$0000

;	Four independent corners - a spectator picks which one to enter by
;	pressing its own start control, per the confirmed design (no
;	auto-assigned/ready-gated slot like chess's 2-seat model). Stub
;	handlers for now - claiming a slot needs the wire protocol
;	(gameProcPlayMsg) designed first. Moved here from page_ovrvw per
;	correction - the overview page is the highscore table only.
button_detail_start0:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientDetailStart0Chng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options
			.byte	CLR_FACE		;colour
			.byte	$1E			;posx
			.byte	$05			;posy
			.byte	$0A			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_hud	;panel
			.word	text_detail_start0	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_1		;accelchar

button_detail_start1:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientDetailStart1Chng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options
			.byte	CLR_FACE		;colour
			.byte	$1E			;posx
			.byte	$0A			;posy
			.byte	$0A			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_hud	;panel
			.word	text_detail_start1	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_2		;accelchar

button_detail_start2:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientDetailStart2Chng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options
			.byte	CLR_FACE		;colour
			.byte	$1E			;posx
			.byte	$0F			;posy
			.byte	$0A			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_hud	;panel
			.word	text_detail_start2	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_3		;accelchar

button_detail_start3:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientDetailStart3Chng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options
			.byte	CLR_FACE		;colour
			.byte	$1E			;posx
			.byte	$14			;posy
			.byte	$0A			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_hud	;panel
			.word	text_detail_start3	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_4		;accelchar

;	Score/power-up slots, 3 per corner, display-only (OPT_NONAVIGATE,
;	same as page_ovrvw's highscore rows) - static placeholder text for
;	now, all four corners of each kind sharing one RODATA string since
;	there's no real per-player score/power-up state to show yet.
label_detail_score0:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$06		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	slotScoreText + (0 * SCORE_TEXT_SIZE)	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_score1:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$0B		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	slotScoreText + (1 * SCORE_TEXT_SIZE)	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_score2:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$10		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	slotScoreText + (2 * SCORE_TEXT_SIZE)	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_score3:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$15		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	slotScoreText + (3 * SCORE_TEXT_SIZE)	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

;	The level/clock line, on screen row 4 - the row directly above the
;	board, which starts at row 5 (board row + 5, see gameDrawBoardRows).
;	Its text is statusText, which gameProcGameStatusMsg writes the
;	server's own formatted line into once a second.
;
;	Colour is set at runtime, not here: it goes red for the last
;	STATUS_WARN_SECS. The value below is only what it looks like before
;	the first GameStatus arrives.
label_detail_status:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_LOG_C64_WHITE | CLR_SPEC_TEXT	;colour	.byte
			.byte	$05		;posx	.byte
			.byte	$04		;posy	.byte
			.byte	$14		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_bkg	;panel	.word
			.word	statusText	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_0:
;			.word	$0000		;prepare
			.word	gameLivesPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$07		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_1:
;			.word	$0000		;prepare
			.word	gameLivesPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$0C		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$01		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_2:
;			.word	$0000		;prepare
			.word	gameLivesPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$11		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$02		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_3:
;			.word	$0000		;prepare
			.word	gameLivesPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$16		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$03		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_0:
;			.word	$0000		;prepare
			.word	gameSpeedPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$08		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_1:
;			.word	$0000		;prepare
			.word	gameSpeedPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$0D		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$01		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_2:
;			.word	$0000		;prepare
			.word	gameSpeedPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$12		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$02		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_3:
;			.word	$0000		;prepare
			.word	gameSpeedPresent	;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$17		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$03		;tag	.byte	(corner)
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_bar	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

;-------------------------------------------------------------------------------
;	clientDetailStart0Chng/1/2/3 - one handler per corner (explicit,
;	not a tag-driven shared dispatch - matches this codebase's
;	established style of simple per-control handlers). Each does the
;	standard changed-handler redraw, then hands its own corner number
;	to gameSlotPress below.
;-------------------------------------------------------------------------------
clientDetailStart0Chng:
;-------------------------------------------------------------------------------
		LDA	#$00
		STA	gameSlotPressed

		JMP	gameSlotChanged
;		RTS

clientDetailStart1Chng:
;-------------------------------------------------------------------------------
		LDA	#$01
		STA	gameSlotPressed

		JMP	gameSlotChanged
;		RTS

clientDetailStart2Chng:
;-------------------------------------------------------------------------------
		LDA	#$02
		STA	gameSlotPressed

		JMP	gameSlotChanged
;		RTS

clientDetailStart3Chng:
;-------------------------------------------------------------------------------
		LDA	#$03
		STA	gameSlotPressed

		JMP	gameSlotChanged
;		RTS


;-------------------------------------------------------------------------------
;	gameSlotChanged - shared tail for the four corner START handlers,
;	which have already parked their own corner number in
;	gameSlotPressed.
;
;	A control's "changed" hook fires on the way UP as well as the way
;	down, so acting unconditionally would run the press twice. Gate on
;	STATE_DOWN exactly as the framework's own clientPlayJoinChng does
;	(fw_ctrls_net.s), including reading the state BEFORE
;	ctrlsControlDefChanged - it updates the element, so a read after it
;	is a read of the wrong thing.
;-------------------------------------------------------------------------------
gameSlotChanged:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	gameSlotPressed
		JMP	gameSlotPress
;		RTS

@exit:
		RTS


;-------------------------------------------------------------------------------
;	gameSlotPress - a corner's START control was pressed. START only
;	ever CLAIMS; it is not a toggle.
;
;	It was a toggle until 2026-08-25, and that was wrong twice over
;	(dengland: "you shouldn't be able to claim an active player"). An
;	occupied corner is not something to press - pressing your own
;	dropped you out of a running game, and with the joystick's fire
;	button still counting as a mouse click at the time, a shot at the
;	fire button did exactly that by itself. Leaving a corner is what
;	the PART control is for, which already releases the slot via the
;	server's own Remove.
;
;	Nothing is assumed about the outcome - gameMySlot only ever moves
;	when the server's own SlotStatus says so (see
;	gameProcSlotStatusMsg). A refused claim just produces a server
;	error in the log and leaves everything as it was.
;	IN	.A		corner 0..3
;-------------------------------------------------------------------------------
gameSlotPress:
;-------------------------------------------------------------------------------
;	Already holding a corner - any START press is a no-op, including
;	this corner's own. Checked client-side as well as server-side so a
;	stray press never even reaches the wire as an error.
		LDX	gameMySlot
		CPX	#SLOT_CLAIM_NONE
		BNE	@busy

;	Don't stack claims. Without this, holding the accelerator down (or
;	an impatient double-press while the first is still in flight) sends
;	several claims for the same corner; the server refuses the extras
;	harmlessly, but each one comes back as an error in the player's log
;	for something they did once.
		LDX	gameSlotWanted
		CPX	#SLOT_CLAIM_NONE
		BNE	@busy

		STA	gameSlotWanted

		JMP	gameSendSlotClaim
;		RTS

@busy:
		RTS


;===============================================================================
; RODATA - game-specific text
;===============================================================================
text_page_ovrvw:
			.asciiz	"OVERVIEW"
text_page_detail:
			.asciiz	"BOARD"

text_ovrvw_title:
			.asciiz	"HIGH SCORES"
text_ovrvw_score0:
			.asciiz	" 1.  ---------------------  000000"
text_ovrvw_score1:
			.asciiz	" 2.  ---------------------  000000"
text_ovrvw_score2:
			.asciiz	" 3.  ---------------------  000000"
text_ovrvw_score3:
			.asciiz	" 4.  ---------------------  000000"
text_ovrvw_score4:
			.asciiz	" 5.  ---------------------  000000"

;	No text_detail_score here any more - the four score labels point at
;	slotScoreText instead, which is RAM the SlotStatus handler writes the
;	server's own digits straight into. One shared RODATA string could
;	never have shown four different scores.
;	The lives and speed rows have no text of their own - their present
;	hooks (gameLivesPresent/gameSpeedPresent) fill the row by DMA and
;	never read textptr. This blank exists only so the field is not left
;	pointing at nothing, in case the default present is ever restored.
text_detail_bar:
			.asciiz	"          "
text_detail_start0:
			.asciiz	"[1 START]"
text_detail_start1:
			.asciiz	"[2 START]"
text_detail_start2:
			.asciiz	"[3 START]"
text_detail_start3:
			.asciiz	"[4 START]"
