;===============================================================================
; snake_game.s - Snake Challenge QUADRO, game-specific content
;
; Everything in framework/*.s is generic across games; everything here is
; specific to THIS game. Deliberately minimal for now (scaffolding pass,
; not the real tile/movement simulation - see the project's own design-
; decision notes: spectator/4-corner slot model, 6 ticks/sec, delta
; broadcast, 30x18 board). Defines the five things framework/*.s expects
; a game to provide:
;
;   gameTilesLoadHack  - load tile/sprite graphics into VRAM at boot
;                        (fw_startup.s) - stub, no tile art yet.
;   gameLoadPalette    - unpack this game's palette into $D100-$D3FF
;                        (fw_startup.s) - stub, no palette asset yet.
;   gameStateInit      - zero this game's own BSS state at boot
;                        (fw_startup.s, via initCore) - stub for now.
;   gameResetPlayGame  - reset local UI state on disconnect/leave
;                        (fw_ctrls_net.s) - stub for now.
;   gameProcPlayMsg    - mcPlay message dispatch for everything except
;                        chat, which framework already handles generically
;                        (fw_ctrls_net.s's clientProcPlayMsg) - stub for
;                        now, no game-specific wire messages exist yet.
;
; Also defines page_ovrvw and page_detail - framework's page_play always
; navigates to a page named page_ovrvw (see fw_ui_shell.s), and this
; game's own page_ovrvw navigates on to page_detail, mirroring chess's
; original page-name contract. Both are placeholder content only - the
; real 4-corner spectator overview and the actual board rendering are
; follow-up work, not part of this scaffolding pass.
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
;	gameStateInit - stub. No Snake QUADRO BSS state vars exist yet
;	(no board/slot/spectator tracking has been designed - see the
;	project's own design-decision notes). Called from initCore, after
;	initScreen/initSprites, before initUser.
;-------------------------------------------------------------------------------
gameStateInit:
;-------------------------------------------------------------------------------
		RTS


;-------------------------------------------------------------------------------
;	gameResetPlayGame - stub. Called on disconnect (inetDisconnected)
;	and after sending Part (clientSendPlayPart) to reset local UI state
;	- chess's original reset ready/colour checkboxes and player-name
;	labels here. Nothing to reset yet on page_ovrvw below.
;-------------------------------------------------------------------------------
gameResetPlayGame:
;-------------------------------------------------------------------------------
		RTS


;-------------------------------------------------------------------------------
;	gameProcPlayMsg - stub. clientProcPlayMsg (fw_ctrls_net.s) already
;	handles mcPlay/$0E (GameChat) generically and routes anything else
;	here. No game-specific wire messages exist yet (slot-claim,
;	direction input, tile deltas - see the project's design notes), so
;	everything just falls through to clientProcUnknownMsg for now.
;-------------------------------------------------------------------------------
gameProcPlayMsg:
;-------------------------------------------------------------------------------
		JMP	clientProcUnknownMsg
;		RTS


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
			.byte	$02

;	tab_main must be listed here (as chess's original page_detail_pnls
;	did) or the main BEGIN/CHAT/PLAY/PREFS tab navigation becomes
;	unreachable from this page - caught live (2026-08-24): could
;	navigate the start buttons but not the tabs, since tab_main's own
;	controls simply weren't part of this page's panel chain at all.
page_detail_pnls:
			.word	tab_main
			.word	panel_detail_placeholder
			.word	$0000

panel_detail_placeholder:
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
			.word	page_detail
			.word	panel_detail_placeholder_ctrls	;controls
			.byte	$05

panel_detail_placeholder_ctrls:
			.word	label_detail_placeholder
			.word	button_detail_start0
			.word	button_detail_start1
			.word	button_detail_start2
			.word	button_detail_start3
			.word	$0000

label_detail_placeholder:
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
			.word	panel_detail_placeholder	;panel	.word
			.word	text_detail_placeholder	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

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
			.byte	$01			;posx
			.byte	$06			;posy
			.byte	$0F			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_placeholder	;panel
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
			.byte	$01			;posx
			.byte	$08			;posy
			.byte	$0F			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_placeholder	;panel
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
			.byte	$01			;posx
			.byte	$0A			;posy
			.byte	$0F			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_placeholder	;panel
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
			.byte	$01			;posx
			.byte	$0C			;posy
			.byte	$0F			;width
			.byte	$01			;height
			.byte	$00			;tag
			.word	panel_detail_placeholder	;panel
			.word	text_detail_start3	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_4		;accelchar

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

text_detail_placeholder:
			.asciiz	"BOARD RENDERING - COMING SOON"
text_detail_start0:
			.asciiz	"[1 START]"
text_detail_start1:
			.asciiz	"[2 START]"
text_detail_start2:
			.asciiz	"[3 START]"
text_detail_start3:
			.asciiz	"[4 START]"
