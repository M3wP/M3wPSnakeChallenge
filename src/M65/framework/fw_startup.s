;===============================================================================
; fw_startup.s - FRAMEWORK (reusable across games)
;
; BASIC loader stub, mouse-pointer sprite data, and hardware/VIC/CHR16
; boot init (initROM/initHiVars/initMem/initM65IOFast/initCore/initScreen/
; initSprites/initUser + the busy/pointer cursor-sprite push/pop pair).
;
; Three extension-point hooks a game's own file must define (see the
; matching "GAME HOOK" comments below for exactly where/why each is
; called) - chess's originals (piecesLoadHack, the ChessPiecesArray.pal
; unpack loop, and the ourReady/boardPickMode/etc reset block) are NOT
; carried over, since they're entirely game-specific:
;   gameTilesLoadHack  - load tile/sprite graphics into VRAM at boot
;   gameLoadPalette    - unpack this game's palette data into $D100-$D3FF
;   gameStateInit      - zero this game's own BSS state vars at boot
;
; Extracted from M3wPChess's chess.s during the Snake Challenge QUADRO
; port (2026-08-24). See fw_core.s for the wider extraction note.
;===============================================================================

;===============================================================================
;	.segment 	"STARTUP"
;===============================================================================
;	Ends up at $080D
;-----------------------------------------------------------
;BASIC interface
;-----------------------------------------------------------
.segment "CODE"
;start 2 before load address so
;we can inject it into the binary
	.org		$07FF			
						
	.byte		$01, $08		;load address
	
;BASIC next addr and this line #
	.word		_basNext, $000A		
	.byte		$9E			;SYS command
	.asciiz		"2061"			;2061 and line end
_basNext:
	.word		$0000			;BASIC prog terminator
	.assert		* = $080D, error, "BASIC Loader incorrect!"
;-----------------------------------------------------------
  JMP init

;	* = $0810
.res  $0810 - *, 0

;	.assert * = $0810, error, "Mouse pointer data location incorrect!"
	
		.byte	           %10000000, %00000000
		.byte	%01010000, %01000000, %00000000
		.byte	%01101000, %00100000, %00000000
		.byte	%01000100, %01000000, %00000000
		.byte	%00000010, %10000000, %00000000
		.byte	%00000001, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00
		
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00111110, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000010, %00000000, %00000000
		.byte	%00000001, %00000000, %00000000
		.byte	%00000000, %10000000, %00000000
		.byte	%00000000, %01000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00
		
		.byte	%11111111, %11000000, %00000000
		.byte	%10000000, %01000000, %00000000
		.byte	%10000000, %10000000, %00000000
		.byte	%10100001, %00000000, %00000000
		.byte	%10100000, %10000000, %00000000
		.byte	%10100000, %01000000, %00000000
		.byte	%10101000, %00100000, %00000000
		.byte	%10010100, %01010000, %00000000
		.byte	%10101010, %10100000, %00000000
		.byte	%11000101, %01000000, %00000000
		.byte	%00000010, %10000000, %00000000
		.byte	%00000001, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00

		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00011100, %00000000, %00000000
		.byte	%00011100, %00000000, %00000000
		.byte	%00011110, %00000000, %00000000
		.byte	%00000111, %00000000, %00000000
		.byte	%00000011, %10000000, %00000000
		.byte	%00000001, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00


  ; 16-colour sprite pointer data for busy
  ; 1 = FG
  ; 2 = black
  ; 3 = grey
  ; 4 = white
		;.byte		$00, $03, $33, $33, $33, $33, $00, $00
		;.byte		$00, $32, $22, $22, $22, $23, $30, $00
		;.byte		$03, $24, $44, $44, $44, $42, $23, $00
		;.byte		$32, $33, $11, $11, $11, $14, $23, $00
		;.byte		$32, $31, $11, $11, $11, $14, $23, $00
		;.byte		$32, $31, $11, $11, $11, $14, $23, $00
		;.byte		$32, $31, $11, $11, $11, $14, $23, $00
		;.byte		$32, $33, $11, $11, $11, $42, $33, $00
		;.byte		$03, $23, $32, $34, $44, $22, $30, $00
		;.byte		$00, $32, $23, $31, $11, $42, $30, $00
		;.byte		$03, $24, $43, $11, $14, $23, $00, $00
		;.byte		$32, $31, $14, $23, $32, $30, $00, $00
		;.byte		$32, $33, $32, $32, $23, $00, $00, $00
		;.byte		$03, $22, $23, $33, $30, $00, $00, $00
		;.byte		$00, $33, $30, $00, $00, $00, $00, $00
		;.byte		$00, $00, $00, $00, $00, $00, $00, $00
		;.byte		$00, $00, $00, $00, $00, $00, $00, $00
		;.byte		$00, $00, $00, $00, $00, $00, $00, $00
		;.byte		$00, $00, $00, $00, $00, $00, $00, $00
		;.byte		$00, $00, $00, $00, $00, $00, $00, $00
		;.byte		$00, $00, $00, $00, $00, $00, $00, $00

  ; Mono colour black (2)
		.byte	%00000000, %00000000, %00000000
		.byte	%00011111, %11100000, %00000000
		.byte	%00100000, %00011000, %00000000
		.byte	%01000000, %00001000, %00000000
		.byte	%01000000, %00001000, %00000000
		.byte	%01000000, %00001000, %00000000
		.byte	%01000000, %00001000, %00000000
		.byte	%01000000, %00010000, %00000000
		.byte	%00100100, %00110000, %00000000
		.byte	%00011000, %00010000, %00000000
		.byte	%00100000, %00100000, %00000000
		.byte	%01000010, %01000000, %00000000
		.byte	%01000101, %10000000, %00000000
		.byte	%00111000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00

  ; White (4)
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00011111, %11100000, %00000000
		.byte	%00000000, %00010000, %00000000
		.byte	%00000000, %00010000, %00000000
		.byte	%00000000, %00010000, %00000000
		.byte	%00000000, %00010000, %00000000
		.byte	%00000000, %00100000, %00000000
		.byte	%00000001, %11000000, %00000000
		.byte	%00000000, %00100000, %00000000
		.byte	%00011000, %01000000, %00000000
		.byte	%00000100, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00

  ; Grey (3)
		.byte	%00011111, %11110000, %00000000
		.byte	%00100000, %00011000, %00000000
		.byte	%01000000, %00000100, %00000000
		.byte	%10110000, %00000100, %00000000
		.byte	%10100000, %00000100, %00000000
		.byte	%10100000, %00000100, %00000000
		.byte	%10100000, %00000100, %00000000
		.byte	%10110000, %00001100, %00000000
		.byte	%01011010, %00001000, %00000000
		.byte	%00100110, %00001000, %00000000
		.byte	%01000100, %00010000, %00000000
		.byte	%10100001, %10100000, %00000000
		.byte	%10111010, %01000000, %00000000
		.byte	%01000111, %10000000, %00000000
		.byte	%00111000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00

  ; FG (1)
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00001111, %11100000, %00000000
		.byte	%00011111, %11100000, %00000000
		.byte	%00011111, %11100000, %00000000
		.byte	%00011111, %11100000, %00000000
		.byte	%00001111, %11000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000001, %11000000, %00000000
		.byte	%00000011, %10000000, %00000000
		.byte	%00011000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	%00000000, %00000000, %00000000
		.byte	$00

init:
		;LDA	#$8E			;go to uppercase characters
		;JSR	krnlOutChr
		;LDA	#$08			;disable change character case
		;JSR	krnlOutChr
	
		SEI
		CLD

		LDA	#$00
		STA	$00
		LDA	#$37
		STA	$01

		LDA	#$00
		LDX	#$0F
		LDY	#$00
		LDZ	#$0F
		MAP

		LDA	#0
		TAX
		TAY
		TAZ
		MAP
		EOM

		LDA	#$00
		STA	$D02F

		LDA	#$7F			;disable standard CIA irqs
		STA	cia1IRQCtl

    JSR initROM
    JSR initM65IOFast

	.if	DEBUG_LOADFONT
		JSR	fontLoadXirod
	.endif

;	GAME HOOK: gameTilesLoadHack - load this game's tile/sprite graphics
;	into VRAM. Must exist even if it's currently just RTS (see snake_game.s).
		JSR	gameTilesLoadHack

    JSR initHiVars
    JSR initMem
		JSR	initCore

;	Reset the stack pointer

		LDX	#$FF
		TXS

		JMP 	main

;	GAME HOOK data: a game's own palette asset (16 RGB triples, indices
;	$10-$1F) is .incbin'd in the game's own file, not here - see
;	gameLoadPalette below, which unpacks it into $D100-$D3FF.

;-------------------------------------------------------------------------------
initROM:
;-------------------------------------------------------------------------------
;	Bank out BASIC + Kernal (keep IO).  First, make sure that the IO port
;	is set to output on those lines.
		LDA	$00
		ORA	#$07
		STA	$00
		
;	Now, exclude BASIC + KERNAL from the memory map (include only IO)
;		LDA	$01
;		AND	#$FC
;		ORA	#$01
		LDA	#$1D
		STA	$01

    RTS


;-------------------------------------------------------------------------------
;	High memory ($E000-$FFF9, see m65.cfg's HIMEM/HIVARS) is bss - it
;	costs nothing in the .prg, but that also means it's genuine
;	garbage until cleared here, once, at startup (initROM must run
;	first so it's actually RAM under the banked-out KERNAL). Inline
;	enhanced DMA fill job rather than a CPU loop.
	.import	__HIMEM_START__
	.import	__HIMEM_SIZE__
initHiVars:
;-------------------------------------------------------------------------------
		STA	$D707
		.byte	$00			;end of job options
		.byte	$03			;fill
		.word	__HIMEM_SIZE__		;count
		.word	$0000			;value (fill byte in low byte)
		.byte	$00			;src bank
		.word	__HIMEM_START__		;dst
		.byte	$00			;dst bank
		.byte	$00			;cmd hi
		.word	$0000			;modulo/ignored

		RTS


;-------------------------------------------------------------------------------
initMem:
;-------------------------------------------------------------------------------

;	Screen (2000 bytes, $010000) and colour RAM (2000 bytes, physical
;	$01F800) are genuine garbage at boot. CHR16/FCLRHI cells are 2
;	bytes (value low, $00 high), and from here on nothing ever writes
;	the high byte again - dmaFillRow uses a stride-2 DMA fill that only
;	touches the low byte, and the CPU paths (LDQ/STQ/STCELL16) always
;	zero it themselves on a fresh write. So the high bytes only need
;	clearing once, here, up front.
		STA	$D707
		.byte	$00		;end of job options
		.byte	$03		;fill
		.word	2000		;count - 25 rows * 80 bytes/row
		.word	$0000		;value (fill byte in low byte)
		.byte	$00		;src bank
		.word	$0000		;dst
		.byte	$01		;dst bank - screen RAM is at $010000
		.byte	$00		;cmd hi
		.word	$0000		;modulo/ignored

		STA	$D707
		.byte	$00		;end of job options
		.byte	$03		;fill
		.word	2000		;count
		.word	$0000		;value
		.byte	$00		;src bank
		.word	$F800		;dst
		.byte	$01		;dst bank - colour RAM's real physical
					;	address is $01F800, not $D800
		.byte	$00		;cmd hi
		.word	$0000		;modulo/ignored

;	Init mouse pointer RAM from ONCE segment

		LDA	#<sprPointer0
		STA	tempptr0
		LDA	#>sprPointer0
		STA	tempptr0 + 1
		
		LDA	#<spriteMem20		
		STA	tempptr1
		LDA	#>spriteMem20
		STA	tempptr1 + 1
		
		LDY	#$0F
@loop5:						
		LDA	(tempptr0), Y
		STA	(tempptr1), Y
		
		DEY
		BPL	@loop5

;	Initialise state

		LDA	#$00

		STA	ctrlsLock
		STA	ctrlsLCnt

		STA	pageptr0
		STA	pageptr0 + 1

		STA	downCtrl
		STA	downCtrl + 1
		STA	pickCtrl
		STA	pickCtrl + 1

		STA	msgs_change_idx
		STA	msgs_dirty_idx

		STA	sendmsgscnt
		STA	readmsglen
		STA	readmsgidx

		STA	keyZPKeyDown
		STA	keyZPKeyCount
		STA	keyZPKeyScan
		STA	keyZPDecodePtr
		STA	keyZPDecodePtr + 1
		
		STA	uiflshcnt
		STA	room_log_notify_cnt
		STA	crsr_active
		STA	crsr_on

;	Initialise logs

		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1

		JSR	ctrlsLogPanelInit

		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1

		JSR	ctrlsLogPanelInit

		LDA	#<lpanel_play_log
		STA	tempptr2
		LDA	#>lpanel_play_log
		STA	tempptr2 + 1

		JSR	ctrlsLogPanelInit

;	GAME HOOK note: chess's original also ctrlsLogPanelInit'd its own
;	board-page chat log panel (lpanel_detail_log) here, plus reset its
;	dedup-state vars (detailChatHaveBlank/detailChatLastUser) - both
;	entirely game-specific (the panel's own name/existence, and
;	whether it even has this kind of dedup state). In-game chat itself
;	is generic now though (see clientProcPlayGameChatMsg, routed
;	through lpanel_play_log/play_haveblank/play_lastuser below,
;	initialised here like room chat is) - a game only needs
;	gameStateInit for a SEPARATE board-page log panel, if it wants one.

		LDA	#$01
		STA	room_haveblank
		LDA	#$00
		STA	room_lastuser

		LDA	#$01
		STA	play_haveblank
		LDA	#$00
		STA	play_lastuser
		
		
;	Intialise keyboard handler

		LDA	#$00
		STA	keyRepeatFlag
;		LDA	#$80
;		STA	keyModifierLock
		LDA	#$14
		STA	keyBufferSize

		RTS


;-----------------------------------------------------------
initM65IOFast:
;-----------------------------------------------------------
;	Go fast, first attempt
		LDA	#65
		STA	$00

;	Enable M65 enhanced registers
		LDA	#$47
		STA	$D02F
		LDA	#$53
		STA	$D02F
;	Switch to fast mode, be sure
; 	1. C65 fast-mode enable
		LDA	$D031
		ORA	#$40
		STA	$D031
; 	2. MEGA65 40.5MHz enable (requires C65 or C128 fast mode to truly enable, 
;	hence the above)
;		LDA	#$40
		LDA	#$C0
		TSB	$D054
		
		RTS


;-------------------------------------------------------------------------------
initCore:
;-------------------------------------------------------------------------------
		;JSR	initMem

    JSR initScreen
    JSR	initSprites

;	screenHiBytesUsed is framework-owned (see screenClearHiBytes) so it
;	resets here, not in the GAME HOOK below.
		LDA	#$00
		STA	screenHiBytesUsed

;	GAME HOOK: gameStateInit - zero this game's own BSS state vars
;	(chess's original reset ourReady/whiteAssign/boardSelX/boardSelY/
;	chessGameState/checkStateSlot0/checkStateSlot1/ourTurn/boardPickMode/
;	ourSlot and called clientDetailInitDefaultPieces here - none of
;	that carries over, it's entirely game-specific).
		JSR	gameStateInit

		JSR	initUser

		LDA	#INET_PROC_HALT
		STA	inetproc
		LDA	#INET_STATE_NORM
		STA	inetstat
		LDA	#INET_ERR_NONE
		STA	ineterrk
		LDA	#INET_ERROR_NONE
		STA	ineterrc

		RTS
		

;-------------------------------------------------------------------------------
initScreen:
;-------------------------------------------------------------------------------
;	Bit 7 of $D06F is set on an NTSC machine, clear on PAL. It can change
;	dynamically, but we only care about it once at startup for now.
		LDA	$D06F
		AND	#$80
		STA	sys_ntsc_flag

;	D018 charset nibble = 2 ($1000) - lowercase/symbol charset
		LDA	#$24
		STA	$D018

;	Clears D05D bit 7 - exact documented meaning not confirmed, verify
;	before trusting the old "prevent VIC-II compatibility changes" claim
		LDA	#$80
		TRB	$D05D

		LDA	#$00
		STA	$D020		;border colour
		LDA	#$00
		STA	$D021		;background colour

;	32-bit screen RAM address (D060-D063) = $00010000
		LDA	#$00
		STA	$D060
		STA	$D061
		LDA	#$01
		STA	$D062

; address is only in bits 0 to 3.  Bit 6 is "256 colour tiles"
		LDA	#$40
		STA	$D063

;	D030 bit 2 set - use palette RAM entries for colours 0-15
		LDA	$D030
		ORA	#$04
		STA	$D030

;	D031 = $40 (FAST bit only - H640/V400/BPM/ATTR all clear, so this is
;	still classic 40-column addressing, not 80-column)
		LDA	#$40
		STA	$D031

;	D058/D059 = 80 - text row stride in bytes (two bytes per character
;	now that CHR16 is on, still 40 columns)
		LDA #<$50
		STA $D058
		LDA #>$50
		STA $D059

;	D05E = 40 - characters per row (again 40, not 80)
		LDA	#$28
		STA	$D05E

; D07B = rows per screen (25)
    LDA #$18
    STA $D07B

;	D054 = $45 - bit 0 CHR16 (16-bit characters), bit 2 FCLRHI (full
;	colour RAM, used for the piece graphics), bit 6 VFAST. Bit 7
;	(ALPHAEN, alpha blending) deliberately left clear - not wanted here.
		LDA	#$45
		STA	$D054

;	D064/D065 - Colour RAM base address offset
		LDA	#$00
		STA	$D064
		LDA	#$00
		STA	$D065

;	Clears D051 bit 7 - exact documented meaning not confirmed, verify
;	before trusting the old "FCM double-buffering" claim
		LDA #$00
		TRB $D051

;	D04C (text X position) = $50
		LDA	#$50
		STA	$D04C

;	Clears the low nibble of D04D, leaves the high nibble untouched
		LDA	$D04D
		AND	#$F0
		STA	$D04D

;	GAME HOOK: gameLoadPalette - unpack this game's 16 RGB triples
;	(indices $10-$1F) into palette registers $10-$1F. The registers are
;	laid out as three separate 256-byte blocks (one per channel: red
;	$D100-$D1FF, green $D200-$D2FF, blue $D300-$D3FF), not interleaved
;	like a typical source asset, so a game's own version of this can't
;	just be a single copy - see chess's original palloop (removed here)
;	for the unpack shape to follow. Colours 16-31 aren't classic VIC-II
;	colours (D030 bit 2 above only speaks to 0-15), so they're expected
;	to just be RAM-backed regardless - no separate enable needed here
;	unless hardware testing says otherwise.
		JSR	gameLoadPalette

    RTS



;-------------------------------------------------------------------------------
initSprites:
;-------------------------------------------------------------------------------
;	Init location of sprite pointers
    LDA #<spritePtr0
    STA $D06C
    LDA #>spritePtr0
    STA $D06D

; Init y position offset
    LDA sys_ntsc_flag
    BEQ @ispal

    LDA #$18
    STA $D072

@ispal:
;	Init sprite RAM locations - busy sprite by default, via the push/pop
;	mechanism below so it plays nicely with anything else that pushes.
		JSR	userCursorPushBusy

;	Turn off MCM and expansion

		LDA	#$00			;MCM none
		STA	vicSprCMod
		STA	vicSprExpX
		STA	vicSprExpY

;	Enable all of the sprites required

		LDA	#$0F			;sprites
		STA	vicSprEnab

		RTS


;-------------------------------------------------------------------------------
;	Cursor busy/pointer sprite switching, nested via cursorBusyCnt so
;	several overlapping "this will take a while" operations don't let
;	one finishing early flip back to the pointer while another is still
;	in flight - only the pop that brings the counter back to 0 actually
;	restores the pointer sprite.
;-------------------------------------------------------------------------------

	.export	userCursorSetBusy
;-------------------------------------------------------------------------------
userCursorSetBusy:
;-------------------------------------------------------------------------------
		LDA	#$24
		STA	spritePtr0
		LDA	#$25
		STA	spritePtr1
		LDA	#$26
		STA	spritePtr2
		LDA	#$27
		STA	spritePtr3

		RTS


	.export	userCursorSetPointer
;-------------------------------------------------------------------------------
userCursorSetPointer:
;-------------------------------------------------------------------------------
		LDA	#$20
		STA	spritePtr0
		LDA	#$21
		STA	spritePtr1
		LDA	#$22
		STA	spritePtr2
		LDA	#$23
		STA	spritePtr3

		RTS


	.export	userCursorPushBusy
;-------------------------------------------------------------------------------
userCursorPushBusy:
;-------------------------------------------------------------------------------
		LDA	cursorBusyCnt
		BNE	@nested

		JSR	userCursorSetBusy

@nested:
		INC	cursorBusyCnt

		RTS


	.export	userCursorPopBusy
;-------------------------------------------------------------------------------
userCursorPopBusy:
;-------------------------------------------------------------------------------
		LDA	cursorBusyCnt
		BEQ	@exit			;already at rest - underflow guard

		DEC	cursorBusyCnt
		BNE	@exit

		JSR	userCursorSetPointer

@exit:
		RTS


cursorBusyCnt:
		.byte	$00


;-------------------------------------------------------------------------------
initUser:
;-------------------------------------------------------------------------------
;	Update the mouse pointer position

		JSR	CMOVEX
		JSR	CMOVEY

;	Install the UI IRQ handler

		JSR	userIRQInstall

		RTS



