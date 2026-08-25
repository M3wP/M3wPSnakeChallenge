;===============================================================================
; fw_font_input.s - FRAMEWORK (reusable across games)
;
; Mouse pointer/button driver variables and routines, the keyboard IRQ
; handler (userIRQHandler, key repeat/scan/decode), and Xirod custom-font
; loading (fontLoadXirod). All game-agnostic - confirmed by diffing
; against Yahtzee's independent copy (byte-identical over this range).
;
; Deliberately excludes chess's piecesLoadHack, which used to sit right
; after fontLoadXirod - a game's own tile-graphics loader is the
; gameTilesLoadHack hook (see fw_startup.s), defined in the game's own
; file instead.
;
; Extracted from M3wPChess's chess.s during the Snake Challenge QUADRO
; port (2026-08-24). See fw_core.s for the wider extraction note.
;===============================================================================

;===============================================================================
;	.segment	"CODE"
;===============================================================================
flag_custom_font:
    .byte  $00

;-------------------------------------------------------------------------------
;Input driver variables
;-------------------------------------------------------------------------------
OldPotX:        
	.byte    	0               	;Old hw counter values
OldPotY:        
	.byte    	0

XPos:           
	.word    	0               	;Current mouse position, X
YPos:           
	.word    	0               	;Current mouse position, Y
XMin:           
	.word    	0               	;X1 value of bounding box
YMin:           
	.word    	0               	;Y1 value of bounding box
XMax:           
	.word    	319               	;X2 value of bounding box
YMax:           
	.word    	199           		;Y2 value of bounding box
	
Buttons:
	.byte    	0               	;button status bits
ButtonsOld:
	.byte		0
;	Control port 2's direction bits, sampled by userProcessMouse
;	(mouse.inc) at the one moment per frame the ports are set up for it.
;	Set bit = pushed: bit0 up, bit1 down, bit2 left, bit3 right.
joyDirs:
	.byte		0
;	Whether control port 2's FIRE button also counts as a left mouse
;	click. It normally does - that is how the joystick drives the UI on
;	a machine with no mouse. A game clears this while the stick is
;	steering something, or every shot at the fire button also re-presses
;	whatever control currently has focus (caught live 2026-08-25: fire
;	re-pressed the corner's own START, which released the corner and
;	ended the game).
joyAsMouse:
	.byte		1
ButtonLClick:
	.byte		0
ButtonRClick:
	.byte		0
MouseUsed:
	.byte		$00

OldValue:       
	.byte    	0               	;Temp for MoveCheck routine
NewValue:       
	.byte    	0               	;Temp for MoveCheck routine

tempValue:	
	.word		0

mouseCheck:
	.byte		$00
mouseTemp0:
	.word		$0000
mouseXCol:
	.byte		$00
mouseYRow:
	.byte		$00
;mouseLastY:
;	.word           $0000

mouseCapture:
			.byte	0
mouseCapCtrl:
			.word	$0000
mouseCapMove:
			.word	$0000
mouseCapClick:
			.word	$0000


mousePanl:
		.byte	$00

mouseExtX:
		.byte	$00
mouseExtY:
		.byte	$00
	
keyBuffer0:
	.repeat	20, I
		.byte	$00
	.endrep
keyBufferSize:
		.byte	$00
keyRepeatFlag:
		.byte	$00
keyRepeatSpeed:
		.byte	$00
keyRepeatDelay:
		.byte	$00
keyModifierFlag:
		.byte	$00
keyModifierLast:
		.byte	$00

pickBlinkDelay:
		.byte	$00
pickBlinkState:
		.byte	$00


	.export	userIRQInstall
;-------------------------------------------------------------------------------
userIRQInstall:
;-------------------------------------------------------------------------------
		LDA	#<userIRQ		;install our handler
		STA	cpuIRQ
		LDA	#>userIRQ
		STA	cpuIRQ + 1

		LDA	#<userNOP		;install our handler
		STA	cpuRESET
		LDA	#>userNOP
		STA	cpuRESET + 1

		LDA	#<userNOP		;install our handler
		STA	cpuNMI
		LDA	#>userNOP
		STA	cpuNMI + 1


		LDA	#%01111111		;We'll always want rasters
		AND	VAL_VIC_CTRLREG		;    less than $0100
		STA	VAL_VIC_CTRLREG
		
		LDA	#$19
		STA	VAL_VIC_RSTRVAL
		
		LDA	#$01			;Enable raster irqs
		STA	VAL_VIC_IRQMASK
		
		RTS

;-------------------------------------------------------------------------------
userNOP:
;-------------------------------------------------------------------------------
		RTI


;===============================================================================
; PANIC REPORT
;
; Built 2026-08-25 to chase an unhandled-interrupt lockup, and KEPT
; (dengland: "leave the debug out routine and the panic diagnostic in
; there"). It costs one byte of state and a handful of code on a path
; that, in a healthy client, never executes at all.
;
; VERIFIED on hardware the day it was written, by poking a $00 over the
; first byte of gamePollTick and checking the reported PC was exactly
; that address + 2. Do the same after any change to userIRQ's prologue -
; a reporter that prints a plausible WRONG address is worse than none,
; because it will be believed.
;===============================================================================

;	Set once userIRQ has taken an unhandled-interrupt fault and reported
;	it. Never cleared: the report is deliberately one-shot, see the call
;	site.
dbgPanicSeen:
		.byte	$00

;	THE FAULT, KEPT IN RAM as well as printed (dengland, 2026-08-25:
;	"if we're not watching the serial we'll miss it").
;
;	The serial report is only seen by whoever happens to have the port
;	open at that instant, and the port is exclusive - so most of the time
;	nobody is listening. These four bytes survive until the next reload
;	and can be read back over the monitor at any point afterwards, which
;	makes an unattended crash just as diagnosable as a watched one.
;
;	CAPTURED BEFORE ANYTHING IS PRINTED, deliberately: VAL_HYPR_DBGOUT is
;	a hypervisor trap per character and this is being called from inside
;	an interrupt handler, which is not a combination anyone has tested.
;	If that turns out to hang or misbehave, the evidence is already
;	safely in RAM rather than lost with it.
;
;	Addresses shift on every build - pull them from the .dbg file rather
;	than remembering them.
dbgPanicPC:
		.res	2
dbgPanicP:
		.byte	$00
dbgPanicIRQ:
		.byte	$00

;-------------------------------------------------------------------------------
;	dbgPanicReport - print what caused an unhandled interrupt, once, on
;	the hypervisor serial debug port. Called from userIRQ's non-raster
;	branch with the full IRQ frame still on the stack.
;
;	Output is one line:
;
;		!PANIC PC=xxxx P=xx IRQ=xx
;
;	PC   - where the fault came FROM. If it was a BRK this points just
;	       PAST the offending byte (BRK is 2 bytes and pushes PC+2), so
;	       a field of $00s reads as an address a little way into it.
;	P    - the status pushed by the BRK/IRQ. BIT 4 SET MEANS BRK; clear
;	       means a genuine interrupt from some source we never enabled.
;	       This is the single byte that settles which it is.
;	IRQ  - VAL_VIC_IRQFLGS, so if it is NOT a BRK we can still see
;	       whether the VIC raised something (sprite collision, lightpen)
;	       or whether it came from outside the VIC entirely.
;
;	THE STACK FRAME. userIRQ has pushed 6 bytes on top of the 3 the
;	BRK/IRQ itself pushed. PLUS THE 2 THIS JSR PUSHED - so every offset
;	below is shifted up by 2 from what it is at the call site. Getting
;	that wrong reads Y and X and calls them a program counter, which
;	looks entirely plausible and is entirely wrong.
;
;		$0103,X  elemptr0 + 1      $0108,X  P (from PHP)
;		$0104,X  elemptr0          $0109,X  P (from BRK/IRQ)
;		$0105,X  Y                 $010A,X  PCL
;		$0106,X  X                 $010B,X  PCH
;		$0107,X  A
;
;	If userIRQ's prologue ever changes, these offsets change with it.
;-------------------------------------------------------------------------------
dbgPanicReport:
;-------------------------------------------------------------------------------
;	CAPTURE FIRST. Nothing slow, nothing that can fail, and no JSR - so
;	the stack offsets here are the ones documented above and the evidence
;	is banked before the hypervisor traps below are ever attempted.
		TSX

		LDA	$010B, X			;PCH
		STA	dbgPanicPC + 1
		LDA	$010A, X			;PCL
		STA	dbgPanicPC
		LDA	$0109, X			;P as pushed - bit 4 = BRK
		STA	dbgPanicP
		LDA	VAL_VIC_IRQFLGS
		STA	dbgPanicIRQ

;	Then print, from the CAPTURED copy rather than from the stack again -
;	so what goes out of the port and what stays in RAM cannot disagree.
		LDX	#$00
@banner:
		LDA	dbgPanicText, X
		BEQ	@frame

		JSR	dbgPutChar

		INX
		BNE	@banner

@frame:
		LDA	dbgPanicPC + 1
		JSR	dbgPutHex
		LDA	dbgPanicPC
		JSR	dbgPutHex

		LDA	#' '
		JSR	dbgPutChar
		LDA	#'P'
		JSR	dbgPutChar
		LDA	#'='
		JSR	dbgPutChar

		LDA	dbgPanicP
		JSR	dbgPutHex

		LDA	#' '
		JSR	dbgPutChar
		LDA	#'I'
		JSR	dbgPutChar
		LDA	#'='
		JSR	dbgPutChar

		LDA	dbgPanicIRQ
		JSR	dbgPutHex

		LDA	#$0D
		JSR	dbgPutChar
		LDA	#$0A
;		JMP	dbgPutChar
;		RTS

;-------------------------------------------------------------------------------
;	dbgPutChar - one character out of the hypervisor serial debug port.
;	The CLV is not optional - it is how the trap returns (dengland,
;	2026-08-25). Slow: a hypervisor round trip per character.
;	IN	.A		character
;-------------------------------------------------------------------------------
dbgPutChar:
;-------------------------------------------------------------------------------
		STA	VAL_HYPR_DBGOUT
		CLV

		RTS

;-------------------------------------------------------------------------------
;	dbgPutHex - one byte as two hex digits.
;
;	Table lookup rather than the usual compare-and-add-7 carry trick -
;	there is no reason to be clever on a path that runs once, and this
;	one cannot be got subtly wrong.
;	IN	.A		byte
;	USED	.A, .Y
;-------------------------------------------------------------------------------
dbgPutHex:
;-------------------------------------------------------------------------------
		PHA

		LSR	A
		LSR	A
		LSR	A
		LSR	A
		TAY
		LDA	dbgHexDigits, Y
		JSR	dbgPutChar

		PLA
		AND	#$0F
		TAY
		LDA	dbgHexDigits, Y

		JMP	dbgPutChar
;		RTS

dbgHexDigits:
		.byte	"0123456789ABCDEF"

dbgPanicText:
		.byte	$0D, $0A, "!PANIC PC=", $00


	.export	userIRQ
;-------------------------------------------------------------------------------
userIRQ:
;-------------------------------------------------------------------------------
		PHP				;save the initial state
		PHA
		TXA
		PHA
		TYA
		PHA

;	Save/restore elemptr0 around the whole IRQ body - userHandleMouse
;	(called below via userIRQHandler) reuses elemptr0 as its own
;	per-cell mouse-hit-testing scratch, same as foreground code
;	(ctrlsPageSelect, clientMainNextChng, ctrlsPageKeyPress's
;	accelerator search, ...) does. Unlike irqptr0 (added specifically
;	so the cursor-blink code never has to touch elemptr0 at all), mouse
;	handling was never given its own pointer - root-caused (2026-08-24)
;	as pageptr0 landing on a torn, bogus address after a rapid F7
;	double-press: this raster IRQ fires ~50-60x/sec unconditionally,
;	so it could preempt foreground code's own elemptr0 use at any
;	instruction boundary and clobber it mid-sequence. Saving/restoring
;	here makes the IRQ's use of elemptr0 fully transparent to whatever
;	the foreground was doing with it, without having to hunt down and
;	individually protect every foreground call site that touches it.
		LDA	elemptr0
		PHA
		LDA	elemptr0 + 1
		PHA

		CLD
		
;	Is the VIC-II needing service?
		LDA	VAL_VIC_IRQFLGS
		AND	#$01
		BNE	@proc
		
;	Some other interrupt source??  Peculiar...  And a real problem!  How
;	do I acknowledge it if its not a BRK when I don't know what it would be?
;
;	DIAGNOSTIC (2026-08-25): report the fault once over the hypervisor
;	serial debug port, then carry on painting red exactly as before.
;
;	Because it is NOT acknowledged, whatever raised this fires again the
;	instant we RTI - so this branch runs thousands of times a second and
;	the red screen is really a livelock, not a single event. That is why
;	the report is LATCHED: VAL_HYPR_DBGOUT is a hypervisor trap per
;	character and would otherwise bury the one line that matters under
;	thousands of identical ones. What gets printed is the FIRST fault,
;	which is the only one that says anything.
;
;	A/X/Y are all saved above and restored below, so this is free to
;	use them.
		LDA	dbgPanicSeen
		BNE	@red

		LDA	#$01
		STA	dbgPanicSeen

		JSR	dbgPanicReport

@red:
		LDA	#$02
		STA	VAL_VIC_BRDRCLR
		STA	VAL_VIC_BKGDCLR

		JMP 	@done
		
@proc:
		ASL	VAL_VIC_IRQFLGS
		
		JSR	userIRQHandler

@done:
		PLA
		STA	elemptr0 + 1
		PLA
		STA	elemptr0

		PLA
		TAY
		PLA
		TAX
		PLA
		PLP

		RTI


;-------------------------------------------------------------------------------
;	Cursor blink delay, in frames - 10 on NTSC, 8 on PAL, so the
;	blink period comes out close to the same wall-clock time on both
;	(NTSC's ~16.7ms/frame vs PAL's ~20ms/frame).
;	OUT	.A		frame delay
;-------------------------------------------------------------------------------
crsrBlinkDelay:
;-------------------------------------------------------------------------------
		LDA	sys_ntsc_flag
		BEQ	@pal

		LDA	#10
		RTS

@pal:
		LDA	#8
		RTS


;-------------------------------------------------------------------------------
userIRQHandler:
;-------------------------------------------------------------------------------
	.if	DEBUG_RASTERTIME
		LDA	#$00
		STA	VAL_VIC_BRDRCLR
	.endif


;	UI notify with flash?
		LDA	uiflshcnt
		BEQ	@flshfin
		
		LDA	uiflshdly
		BEQ	@flash
		
		DEC	uiflshdly
		JMP	@flshfin
		
@flash:
		LDA	uiflshcnt
		
		AND	#$01
		BNE	@flshoff
		
		LDA	#$01
		STA	VAL_VIC_BRDRCLR
		
		JMP	@flshdone
		
@flshoff:
		LDA	current_clrs
		STA	VAL_VIC_BRDRCLR
		
		
@flshdone:
		LDA	#$08
		STA	uiflshdly
		
		DEC	uiflshcnt

@flshfin:
;	Blinking text-entry cursor - every crsrBlinkDelay frames (10 on
;	NTSC, 8 on PAL), XOR $80 (reverse video) into whatever character
;	is currently at crsr_col/crsr_row, and swap its colour between
;	CLR_FOCUS and the down control's own colour. crsr_on tracks which
;	phase we're in so ctrlsUnDownCtrl knows whether a matching XOR/
;	colour restore is needed on release.
;	NB: reads downCtrl directly rather than via elemptr0 - elemptr0 is
;	in heavy use by foreground control-drawing code this IRQ can
;	preempt, so it's not safe to touch here.
		LDA	crsr_active
		BEQ	@crsrfin

		LDA	crsr_dly
		BEQ	@crsrflash

		DEC	crsr_dly
		JMP	@crsrfin

@crsrflash:
		LDA	crsr_on
		EOR	#$01
		STA	crsr_on

		LDY	crsr_row
		LDA	screenRowsLo, Y
		STA	irqptr0
		LDA	screenRowsHi, Y
		STA	irqptr0 + 1
		LDA	#$01			;bank - screen RAM is at $010000
		STA	irqptr0 + 2
		LDA	#$00			;top
		STA	irqptr0 + 3

		LDZ16	crsr_col
		LDQ	irqptr0
		EOR	#$80
		STQ	irqptr0

		LDX	crsr_row
		LDA	screenRowsLo, X
		STA	irqptr0
		LDA	colourRowsHiPhys, X
		STA	irqptr0 + 1
		LDA	#$01			;bank - colour RAM's real physical
		STA	irqptr0 + 2		;	address is $01F800, not $D800
		LDA	#$00			;top
		STA	irqptr0 + 3

		LDA	crsr_on
		BEQ	@crsrclrctrl

		LDA	#CLR_FOCUS
		JMP	@crsrclrgo

@crsrclrctrl:
		LDY	#ELEMENT::colour
		LDA	(downCtrl), Y

@crsrclrgo:
;	screenCtrlToLogClr clobbers tempbit0, which foreground code may be
;	mid-use of - back it up around the call rather than assume it's
;	ours to trash from inside an IRQ.
		TAX
		LDA	tempbit0
		PHA
		TXA

		JSR	screenCtrlToLogClr

		TAX
		PLA
		STA	tempbit0
		TXA

		STCOLR16 irqptr0, crsr_col

		JSR	crsrBlinkDelay
		STA	crsr_dly

@crsrfin:
		JSR	userProcessMouse	;Do mouse first so we can skip
						;	expensive all lines
						;	keyboard scan when mouse
						;	used.

	.if	DEBUG_RASTERTIME
		LDA	#$05
		STA	VAL_VIC_BRDRCLR
	.endif

		JSR	userKeyScanKey
		
		LDA	ctrlsLock
		BNE	@skipUpdate

		LDA	ctrlsPrep
		BNE	@skipUpdate

	.if	DEBUG_RASTERTIME
		LDA	#$01
		STA	VAL_VIC_BRDRCLR
	.endif

		JSR	userHandleMouse
		
		LDA	ButtonLClick
		BEQ	@finish
		
		JSR	userHandleMouseClick
		JMP	@finish
	
@skipUpdate:
		LDY	pickBlinkDelay
		BEQ	@finish

		DEY
		STY	pickBlinkDelay


@finish:
	.if	DEBUG_RASTERTIME
		LDA	#$0E
		STA	VAL_VIC_BRDRCLR
	.endif

		LDA	#$19
		STA	VAL_VIC_RSTRVAL
		
		RTS


;-------------------------------------------------------------------------------
userDiscardKey:
;-------------------------------------------------------------------------------
		LDY	keyBuffer0		;copy kernal code for input key
		LDX	#$00
@loop:
		LDA	keyBuffer0 + 2, X
		STA	keyBuffer0, X
		INX
		
		LDA	keyBuffer0 + 3, X
		STA	keyBuffer0 + 1, X
		INX

		CPX	keyZPKeyCount
		BNE	@loop
		
		DEC	keyZPKeyCount
		DEC	keyZPKeyCount

		TYA
;		CLI				;NO!  Causes problem for IRQ
		CLC
		RTS


;-------------------------------------------------------------------------------
userReadKey:
;-------------------------------------------------------------------------------
		LDX	#$00

		STX	keyZPAbort

		LDA	keyZPKeyCount
		BEQ	@exit

		LDA	keyBuffer0, X
		PHA
		INX
		LDA	keyBuffer0, X
		PHA

		JSR	userDiscardKey

		PLA
		TAX
		PLA

@exit:
		RTS
	

;-------------------------------------------------------------------------------
userKeyScanKey:
;-------------------------------------------------------------------------------
		LDA	Buttons			;When button down, just leave 
		BEQ	@begin			;	already

		RTS

@begin:
;	MODKEY ($D60A[0:6]) for the event currently at the head of the
;	queue - read before popping ASCIIKEY below, so it can't end up
;	describing a different (later) keypress. Bit 7 (KEYQUEUE) is
;	masked off; the remaining 7 bits match the keyMod* defines above
;	exactly, so no translation is needed.
    LDA $D60A
    AND #$7F
    TAY

    LDA $D610
    BEQ @done

    STA $D610

    LDX keyZPKeyCount
    CPX keyBufferSize
    BCS @done

    STA keyBuffer0, X
    INX
    TYA
    STA keyBuffer0, X
    INX

    STX keyZPKeyCount

@done:
    RTS

;-------------------------------------------------------------------------------
check_for_abort_key:
;-------------------------------------------------------------------------------
		LDA	keyZPAbort
		BEQ	@nokey

		SEC
		RTS

@nokey:
		CLC
		RTS


	.export	userHandleMouse
;-------------------------------------------------------------------------------
userHandleMouse:
;-------------------------------------------------------------------------------
		LDA	mouseCheck
		CMP	#$10
		BCS	@proc
			
		LDA	ButtonLClick
		BNE	@proc

		LDA	mouseCapture
		BEQ	@tstpick

		RTS

@tstpick:
		LDA	pickCtrl + 1
		BNE	@tstblink

		RTS

@tstblink:
		CMP	downCtrl + 1
		BNE	@blink

		LDA	pickCtrl
		CMP	downCtrl
		BNE	@blink

		RTS

@blink:
		JSR	userMousePickBlink
		RTS

@proc:
		LDA	#$00
		STA	mouseCheck

		LDA	XPos
		STA	mouseTemp0
		LDA	XPos + 1
		STA	mouseTemp0 + 1
		
		LDX	#$02
@xDiv8Loop:
		LSR
		STA	mouseTemp0 + 1
		LDA	mouseTemp0
		ROR
		STA	mouseTemp0
		LDA	mouseTemp0 + 1
		
		DEX
		BPL	@xDiv8Loop
		
		LDA	mouseTemp0
		STA	mouseXCol
		
		LDA	YPos
		STA	mouseTemp0
		LDA	YPos + 1
		STA	mouseTemp0 + 1
		
		LDX	#$02
@yDiv8Loop:
		LSR
		STA	mouseTemp0 + 1
		LDA	mouseTemp0
		ROR
		STA	mouseTemp0
		LDA	mouseTemp0 + 1
		
		DEX
		BPL	@yDiv8Loop
		
		LDA	mouseTemp0
		STA	mouseYRow

		LDA	mouseCapture
		BEQ	@findctrl
		
		JMP	(mouseCapMove)

;	Find last panel on page
@findctrl:		
		LDY	#PAGE::panels
		LDA	(pageptr0), Y
		STA	ctrlptr0
		INY
		LDA	(pageptr0), Y
		STA	ctrlptr0 + 1

		LDY	#PAGE::panlcnt
		LDA	(pageptr0), Y
		ASL
		STA	ctrlvar_a
		DEC	ctrlvar_a

@panel0:
;	for each panel on page rev
		LDY	ctrlvar_a

		LDA	(ctrlptr0), Y
		STA	panlptr0 + 1
		DEY
		LDA	(ctrlptr0), Y
		STA	panlptr0
		DEY
		
		STY	ctrlvar_a

		LDY	#ELEMENT::state
		LDA	(panlptr0), Y
		AND	#STATE_VISIBLE
		BEQ	@panelnext

		LDA	(panlptr0), Y
		AND	#STATE_ENABLED
		BEQ	@panelnext

		LDY	#ELEMENT::options
		LDA	(panlptr0), Y
		AND	#OPT_NONAVIGATE
		BNE	@panelnext

;	find coord in panel

		LDA	panlptr0
		STA	elemptr0
		LDA	panlptr0 + 1
		STA	elemptr0 + 1

		JSR	userMouseInCtrl
		BCC	@panelnext

;	for each elem in panel 

		LDY	#PANEL::controls
		LDA	(panlptr0), Y
		STA	ctrlptr1
		INY
		LDA	(panlptr0), Y
		STA	ctrlptr1 + 1

		LDY	#$00
		
@elem0:
		LDA	(ctrlptr1), Y
		STA	elemptr0
		INY
		LDA	(ctrlptr1), Y
		BEQ	@panelnext
		
		STA	elemptr0 + 1
		INY
		
		STY	ctrlvar_b

;	find coord in elem on panel
		
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		BEQ	@elemnext

		LDA	(elemptr0), Y
		AND	#STATE_ENABLED
		BEQ	@elemnext

		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_NONAVIGATE
		BNE	@elemnext

;	find coord in elem

		JSR	userMouseInCtrl
		BCC	@elemnext

		LDA	elemptr0
		CMP	pickCtrl
		BNE	@newpick

		LDA	elemptr0 + 1
		CMP	pickCtrl + 1
		BNE	@newpick

		JSR	userMousePickBlink
		RTS

@newpick:
		LDA	#$29
		STA	pickBlinkDelay
		LDA	#$01
		STA	pickBlinkState

		JSR	userMousePickCtrl
		RTS
		
@elemnext:
		LDY	ctrlvar_b
		JMP	@elem0

@panelnext:
		LDY	ctrlvar_a
		BMI	@unpick
		
		JMP	@panel0

@unpick:
		JSR	userMouseUnPickCtrl

		RTS


;-------------------------------------------------------------------------------
userHandleMouseClick:
;-------------------------------------------------------------------------------
		LDA	#$00			
		STA	ButtonLClick

		LDA	mouseCapture
		BEQ	@norm
		
		JMP	(mouseCapClick)

@norm:
		LDA	pickCtrl + 1
		BNE	@down

		RTS

@down:
		STA	elemptr0 + 1
		LDA	pickCtrl
		STA	elemptr0 

		JSR	ctrlsDownCtrl

		RTS


	.export	userMousePickBlink
;-------------------------------------------------------------------------------
userMousePickBlink:
;-------------------------------------------------------------------------------
		LDY	pickBlinkDelay
		BEQ	@blink

		DEY
		STY	pickBlinkDelay
		
		RTS

@blink:
		LDY	#$29
		STY	pickBlinkDelay

		LDA	pickCtrl
		STA	elemptr0
		LDA	pickCtrl + 1
		STA	elemptr0 + 1
		
		LDA	pickBlinkState
		EOR	#$01
		STA	pickBlinkState

;		JSR 	ctrlsControlInvalidate

		BEQ	@exclude
	
		LDA	#STATE_PICK
		JSR	ctrlsIncludeState
		RTS

@exclude:
		LDA	#STATE_PICK
		JSR	ctrlsExcludeState

		RTS


;-------------------------------------------------------------------------------
userMouseUnPickCtrl:
;-------------------------------------------------------------------------------
		LDA	pickCtrl + 1
		BEQ	@exit

		LDY	#ELEMENT::state
		LDA	(pickCtrl), Y

		AND	#STATE_PICK
		BEQ	@clear

		LDA	pickCtrl
		STA	elemptr0
		LDA	pickCtrl + 1
		STA	elemptr0 + 1

		LDA	#STATE_PICK
		JSR	ctrlsExcludeState
		
@clear:
		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1

@exit:
		RTS


	.export	userMousePickCtrl
;-------------------------------------------------------------------------------
userMousePickCtrl:
;-------------------------------------------------------------------------------
		LDA	elemptr0
		CMP	pickCtrl
		BNE	@update

		LDA	elemptr0 + 1
		CMP	pickCtrl + 1
		BNE	@update

		RTS

@update:
		LDA	elemptr0
		STA	tempptr0
		LDA	elemptr0 + 1
		STA	tempptr0 + 1

		JSR	userMouseUnPickCtrl

		LDA	tempptr0
		STA	pickCtrl
		STA	elemptr0
		LDA	tempptr0 + 1
		STA	pickCtrl + 1
		STA	elemptr0 + 1

		LDA	#STATE_PICK
		JSR	ctrlsIncludeState
		
		RTS


	.export userMouseInCtrl
;-------------------------------------------------------------------------------
userMouseInCtrl:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::posy
		LDA	(elemptr0), Y
		STA	ctrlvar_c

		LDA	mouseYRow
		CMP	ctrlvar_c
		BPL	@testh

		JMP	@nomatch

@testh:
		LDY	#ELEMENT::height
		LDA	(elemptr0), Y

		CLC
		ADC	ctrlvar_c
		STA	ctrlvar_c

		LDA	mouseYRow
		CMP	ctrlvar_c
		BPL	@nomatch

		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		STA	ctrlvar_c

		LDA	mouseXCol
		CMP	ctrlvar_c
		BPL	@testw

@nomatch:
		CLC
		RTS

@testw:
		LDY	#ELEMENT::width
		LDA	(elemptr0), Y

		CLC
		ADC	ctrlvar_c
		STA	ctrlvar_c

		LDA	mouseXCol
		CMP	ctrlvar_c
		BPL	@nomatch

		SEC
		
		RTS


;-------------------------------------------------------------------------------
userCaptureMouse:
;-------------------------------------------------------------------------------
		SEI
		
		LDA	mouseCapture
		BNE	@exit
		
		LDA	#$01
		STA	mouseCapture
		
@exit:
		CLI
		
		RTS


;-------------------------------------------------------------------------------
userReleaseMouse:
;-------------------------------------------------------------------------------
		SEI
		
		LDA	mouseCapture
		BEQ	@exit
		
		LDA	#$00
		STA	mouseCapture
		
@exit:
		CLI
		
		RTS


;-------------------------------------------------------------------------------
;	userProcessMouse/MoveCheck moved to mouse.inc (proportional mouse
;	with acceleration + joystick fire button). Original kept at
;	src/backup/userProcessMouse_old.s.
;-------------------------------------------------------------------------------
	.include "mouse.inc"


;-------------------------------------------------------------------------------
ButtonCheck:
;-------------------------------------------------------------------------------
		LDA	Buttons			;Buttons still the same as last
		CMP	ButtonsOld		;time?
		BEQ	@done			;Yes - don't do anything here
		
;		PHA
;		LDA	#$01
;		STA	MouseUsed
;		PLA
		
		AND	#buttonLeft		;No - Is left button down?
		BNE	@testRight		;Yes - test right
		
		LDA	ButtonsOld		;No, but was it last time?
		AND	#buttonLeft
		BEQ	@testRight		;No - test right
		
		LDA	#$01			;Yes - flag have left click
		STA	ButtonLClick
		
@testRight:
		AND	#buttonRight		;Is right button down?
		BNE	@done			;Yes - don't do anything here
		
		LDA	ButtonsOld		;No, but was it last time?
		AND	#buttonRight
		BEQ	@done			;No - don't do anything here
		
		LDA	#$01			;Yes - flag have right click
		STA	ButtonRClick

@done:
		LDA	Buttons			;Store the current state
		STA	ButtonsOld
		RTS


;-------------------------------------------------------------------------------
CMOVEX:
;-------------------------------------------------------------------------------
		CLC
		LDA	XPos
		ADC	#offsX
		STA	tempValue
		LDA	XPos + 1
		ADC	#$00
		STA	tempValue + 1
	
		LDA	tempValue
		STA	VICXPOS0
		STA	VICXPOS1
		STA	VICXPOS2
		STA	VICXPOS3
		
		LDA	tempValue + 1
		CMP	#$00
		BEQ	@unset
	
		LDA	VICXPOSMSB
		ORA	#$0F
		STA	VICXPOSMSB
		RTS
	
@unset:
		LDA	VICXPOSMSB
		AND	#$F0
		STA	VICXPOSMSB
		RTS
	
;-------------------------------------------------------------------------------
CMOVEY:
;-------------------------------------------------------------------------------
		CLC
		LDA	YPos
		ADC	#offsY
		STA	tempValue
		LDA	YPos + 1
		ADC	#$00
		STA	tempValue + 1
	
		LDA	tempValue
		STA	VICYPOS0
		STA	VICYPOS1
		STA	VICYPOS2
		STA	VICYPOS3
	
		RTS




;===============================================================================
;	YhtzeXro.tcr (see text_font_file below) is derived from Xirod, a
;	discontinued but freely-usable font by Ray Larabie of Typodermic
;	Fonts (https://typodermicfonts.com/) - year unknown.
;===============================================================================

;===============================================================================
;	UsebigglesLoadFontHack (see bigglesworth.s) rather than a proper
;	block-transfer API, which is still to be designed. No missing-file
;	handling yet either - assumes YhtzeXro.tcr is on the SD root, and
;	just leaves screenCharXlatVec on the PETSCII routine if the load
;	fails, rather than disabling anything. See DEBUG_LOADFONT near the
;	top of the file for the flag that gates the boot-time call to this.
;
;	Bit 4 of $D07A isn't a "custom font on/off" switch - it tells the
;	VIC to read character data as 8x16 (upscaled) instead of 8x8, which
;	is the format this font is actually stored in. Screen translation
;	gets switched over in the same breath as that bit, since both only
;	make sense once the load has actually succeeded - and unlike the
;	bit, which just changes how the (now-overwritten) character data at
;	$FF7E000 gets read, there's no clean way back afterwards: loading
;	replaces the actual VIC character data, and undoing that needs a
;	ROM hack we're not doing for now.
;===============================================================================

;	BASIC/KERNAL are banked out (see initROM), so the classic C64
;	input-buffer page is free - reused here as bigglesworth's
;	page-aligned filename transfer buffer (must be in conventional low
;	memory, not the HIVARS/high-RAM segment).
fontXfrPage = $02

text_font_file:
			.asciiz	"YhtzeXro.tcr"

;-------------------------------------------------------------------------------
fontLoadXirod:
;	.C		OUT	Set if error
;-------------------------------------------------------------------------------
		LDA	#fontXfrPage
		STA	ptrBigglesXfrHi

		LDX	#<text_font_file
		LDY	#>text_font_file
		JSR	bigglesSetFileName
		BCS	@fail

		JSR	bigglesOpenFile
		BCS	@fail

;	Far destination $FF7E000 - see bigglesLoadFarHack.
		LDA	#$FF
		STA	bigglesFarDstMB + 1
		LDA	#$07
		STA	bigglesFarDstBank
		LDA	#$00
		STA	bigglesFarDst
		LDA	#$E0
		STA	bigglesFarDst + 1

		LDA	#$08			;4096 bytes / 512 per sector
		JSR	bigglesLoadFarHack
		PHP

		JSR	bigglesCloseFile

		PLP
		BCS	@fail

		LDA	$D07A
		ORA	#$10			;8x16 character data, not "font enable"
		STA	$D07A

		LDA	#<screenASCIIToScreenXirod
		STA	screenCharXlatVec
		LDA	#>screenASCIIToScreenXirod
		STA	screenCharXlatVec + 1

    LDA #$01
    STA flag_custom_font

		CLC
		RTS

@fail:
		SEC
		RTS


