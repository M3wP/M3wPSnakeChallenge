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
		DEX
		BPL	@clrslots

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

		JMP	clientProcUnknownMsg
;		RTS

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
;	by the compass directions the pipe OPENS TOWARD, after the user's
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
;	head block. The order here must match that numbering exactly:
;	these are indexed by raw tile value with no bounds check on this
;	side (gameProcTileDeltaMsg's range check on row/col is what
;	guarantees only real board cells ever reach a lookup). All 48 are
;	reachable - heads take corner shapes too, one step before turning.
;
;	Colours are the user's own pick (2026-08-24), light body / dark
;	head per player: P1 $0E/$06, P2 $0A/$02, P3 $0D/$05, P4 $07/$08.
gameTileChars:
;		floor  wall   attract
		.byte	$20,   $66,   $66
;	The same six shapes for every one of the 8 player/role blocks.
		.repeat	8
		.byte	$C0, $DD, $C9, $CA, $CB, $D5
		.endrepeat

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

		JMP	clientPlayJoinedSelf
;		RTS


;-------------------------------------------------------------------------------
;	gameProcSlotStatusMsg - mcPlay/$07 (SlotStatus). Payload is [slot,
;	state] (see TSnakeGame.SendSlotStatus) - just stored for now, see
;	slotStates' own comment above.
;-------------------------------------------------------------------------------
gameProcSlotStatusMsg:
;-------------------------------------------------------------------------------
		LDA	readmsg0 + 2			;slot (0..3)
		TAX
		CPX	#$04
		BCS	@bad				;defensive - shouldn't happen

		LDA	readmsg0 + 3			;state
		STA	slotStates, X

@bad:
		RTS


;-------------------------------------------------------------------------------
;	gameProcTileDeltaMsg - mcPlay/$09 (TileDelta). Payload is [count,
;	(row, col, tile) * count] (see TSnakeGame.SendTileDeltas/Tick,
;	SnakeServer.pas) - the general "these cells changed" broadcast; the
;	attract-mode bounce is its first real use, not a bespoke message of
;	its own (user's own correction, 2026-08-24: "why is this in the
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
; 0-29, rows 5-24 (30x20, starting at row 5 per the user's own layout
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
			.byte	$00

panel_detail_bkg_ctrls:
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
			.word	text_detail_score	;textptr	.word
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
			.word	text_detail_score	;textptr	.word
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
			.word	text_detail_score	;textptr	.word
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
			.word	text_detail_score	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_0:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$07		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr1	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_1:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$0C		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr1	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_2:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$11		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr1	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr1_3:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$16		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr1	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_0:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$08		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr2	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_1:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$0D		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr2	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_2:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$12		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr2	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_detail_pwr2_3:
;			.word	$0000		;prepare
			.word	$0000		;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$17		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_detail_hud	;panel	.word
			.word	text_detail_pwr2	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

;-------------------------------------------------------------------------------
;	clientDetailStart0Chng/1/2/3 - one handler per corner (explicit,
;	not a tag-driven shared dispatch - matches this codebase's
;	established style of simple per-control handlers). Standard
;	changed-handler boilerplate (redraw on state change) for now; each
;	is a placeholder for what will become a slot-claim send once
;	gameProcPlayMsg exists.
;-------------------------------------------------------------------------------
clientDetailStart0Chng:
;-------------------------------------------------------------------------------
		JSR	ctrlsControlDefChanged

;	TODO: claim corner 0 - send a slot-claim message once the wire
;	protocol for it is designed (see gameProcPlayMsg above).

		RTS

clientDetailStart1Chng:
;-------------------------------------------------------------------------------
		JSR	ctrlsControlDefChanged

;	TODO: claim corner 1 - see clientDetailStart0Chng.

		RTS

clientDetailStart2Chng:
;-------------------------------------------------------------------------------
		JSR	ctrlsControlDefChanged

;	TODO: claim corner 2 - see clientDetailStart0Chng.

		RTS

clientDetailStart3Chng:
;-------------------------------------------------------------------------------
		JSR	ctrlsControlDefChanged

;	TODO: claim corner 3 - see clientDetailStart0Chng.

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

text_detail_score:
			.asciiz	"000000"
text_detail_pwr1:
			.asciiz	"PWR1:--"
text_detail_pwr2:
			.asciiz	"PWR2:--"
text_detail_start0:
			.asciiz	"[1 START]"
text_detail_start1:
			.asciiz	"[2 START]"
text_detail_start2:
			.asciiz	"[3 START]"
text_detail_start3:
			.asciiz	"[4 START]"
