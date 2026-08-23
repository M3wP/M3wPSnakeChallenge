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
		AND	vicCtrlReg		;    less than $0100
		STA	vicCtrlReg
		
		LDA	#$19
		STA	vicRstrVal
		
		LDA	#$01			;Enable raster irqs
		STA	vicIRQMask
		
		RTS

;-------------------------------------------------------------------------------
userNOP:
;-------------------------------------------------------------------------------
		RTI


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

		CLD
		
;	Is the VIC-II needing service?
		LDA	vicIRQFlgs
		AND	#$01
		BNE	@proc
		
;	Some other interrupt source??  Peculiar...  And a real problem!  How
;	do I acknowledge it if its not a BRK when I don't know what it would be?
		LDA	#$02
		STA	vicBrdrClr
		STA	vicBkgdClr

		JMP 	@done
		
@proc:
		ASL	vicIRQFlgs
		
		JSR	userIRQHandler

@done:
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
		STA	vicBrdrClr
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
		STA	vicBrdrClr
		
		JMP	@flshdone
		
@flshoff:
		LDA	current_clrs
		STA	vicBrdrClr
		
		
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
		STA	vicBrdrClr
	.endif

		JSR	userKeyScanKey
		
		LDA	ctrlsLock
		BNE	@skipUpdate

		LDA	ctrlsPrep
		BNE	@skipUpdate

	.if	DEBUG_RASTERTIME
		LDA	#$01
		STA	vicBrdrClr
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
		STA	vicBrdrClr
	.endif

		LDA	#$19
		STA	vicRstrVal
		
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


