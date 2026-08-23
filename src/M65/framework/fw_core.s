;===============================================================================
; fw_core.s - FRAMEWORK (reusable across games)
;
; 45GS02/CHR16 macros, hardware register equates, key/protocol/UI-state
; constants, and the ELEMENT/PAGE/PANEL/TABPANEL/LOGPANEL/CONTROL/
; LABELCTRL/EDITCTRL widget struct definitions, plus the zero-page
; scratch-variable layout the rest of the framework (and app code) uses.
;
; Extracted verbatim from M3wPChess's chess.s during the Snake Challenge
; QUADRO port (2026-08-24) - confirmed 100% game-agnostic by diffing
; against M3wPYahtzee's independent copy of the same code (byte-identical
; over this range). Next port: copy this whole framework/ directory
; unchanged and start from a fresh game-specific file - no re-extraction
; needed.
;===============================================================================

;	TODO:
;   - Add a pointer state for text entry mode?
;   - clientDetailBoardPresent's screenHiBytesUsed check (see
;     screenClearHiBytes) sweeps all 1000 screen cells' high bytes on
;     every chess board redraw, even though a move only ever touches
;     a couple of squares. Since MakeMove/MoveMade already know
;     exactly which cells changed (chessMoveFromX/Y, the delta list),
;     a targeted clear of just those squares' high bytes would avoid
;     the whole-screen sweep - noted after seeing a brief flicker on
;     real hardware from the full sweep.
;
;
;	LIMITATIONS:
;		- Making controls invisible requires some effort to redisplay 
;		  properly
;		- Beware overlapping controls
;
;	BUGS:
;		- Edit controls with a captured (down) blinking cursor get
;		  "picked" and change presentation if the mouse moves over
;		  them while typing - probably the mouse hover/pick logic
;		  not checking downCtrl before restyling. Minor, not fixed
;		  yet.
;

	.setcpu		"4510"

;	LDAX/STAX (16-bit load/store via A/X) and the three IP65_ERROR_*
;	codes below were pulled in from ip65's common.inc/error.inc -
;	copied in directly since that was all that was actually used out
;	of them (net.inc was entirely dead and dropped outright). Original
;	source: ip65 (https://github.com/cc65/ip65), MPL 1.1.
;	common.inc - Per Olofsson, MagerValp@gmail.com, Copyright (C) 2009.
;	error.inc  - Jonno Downes, jonno@jamtronix.com, Copyright (C) 2009.
.macro ldax arg
.if (.match (.left (1, arg), #))      ; immediate mode
    lda #<(.right (.tcount (arg)-1, arg))
    ldx #>(.right (.tcount (arg)-1, arg))
.else                                 ; assume absolute or zero page
    lda arg
    ldx 1+(arg)
.endif
.endmacro

.define LDAX ldax

.macro stax arg
  sta arg
  stx 1+(arg)
.endmacro

.define STAX stax

;	45GS02 32-bit indirect addressing: a NOP immediately before
;	LDA/STA (zp),Z reads zp as a 4-byte far pointer (lo/hi/bank/top)
;	instead of the usual 2-byte one. The NOP stays visible here in the
;	macro body rather than being buried at every call site.
.macro ldq arg
	NOP
	LDA	(arg), Z
.endmacro

.define LDQ ldq

.macro stq arg
	NOP
	STA	(arg), Z
.endmacro

.define STQ stq

;	CHR16/FCLRHI cells are 2 bytes (value low, $00 high), so a screen
;	column now sits at byte offset column*2 within a row instead of
;	column. These two build on LDQ/STQ to keep that doubling out of
;	every call site. When col is immediate, the *2 is done here at
;	assemble time instead of costing a runtime ASL.

;	Sets .Z to the byte offset of column col (col*2, low byte only -
;	for toggling/reading a cell that's already been written, where the
;	high byte doesn't need touching).
;	IN	col		column (immediate #n or a byte variable)
;	USED	.A, .Z
.macro ldz16 col
.if (.match (.left (1, col), #))
	LDA	#((.right (.tcount (col)-1, col)) * 2)
	TAZ
.else
	LDA	col
	ASL
	TAZ
.endif
.endmacro

.define LDZ16 ldz16

;	Writes .A as the low byte of the 16-bit character cell at column
;	col within the row pointed to by far pointer ptr, and zeroes the
;	high byte. For screen RAM only - see STCOLR16 for colour RAM,
;	which is laid out the other way around.
;	IN	.A		character value to store
;	IN	ptr		far pointer (already row-selected)
;	IN	col		column (immediate #n or a byte variable)
;	USED	.A, .Z
.macro stcell16 ptr, col
	PHA
.if (.match (.left (1, col), #))
	LDA	#((.right (.tcount (col)-1, col)) * 2)
	TAZ
.else
	LDA	col
	ASL
	TAZ
.endif
	PLA
	STQ	ptr
	INZ
	LDA	#$00
	STQ	ptr
.endmacro

.define STCELL16 stcell16

;	Writes .A (masked to bits 0-3) into the HIGH byte of the 16-bit
;	colour cell at column col within the row pointed to by far pointer
;	ptr. Under FCLRHI, colour RAM's system colour value lives in the
;	high byte's low nybble, not the low byte - the opposite arrangement
;	from a screen/character cell. The low byte is left untouched (it
;	stays the $00 initMem's boot-time zero-fill put there - nothing
;	ever writes a colour cell's low byte). .A must already be a real
;	system/palette colour (screenCtrlToLogClr's output, or a literal
;	value like healthclrs) - not a raw logical/control colour constant
;	(CLR_TEXT etc).
;	IN	.A		system colour value (0-15)
;	IN	ptr		far pointer (already row-selected)
;	IN	col		column (immediate #n or a byte variable)
;	USED	.A, .Z
.macro stcolr16 ptr, col
	AND	#$0F
	PHA
.if (.match (.left (1, col), #))
	LDA	#((.right (.tcount (col)-1, col)) * 2 + 1)
	TAZ
.else
	LDA	col
	ASL
	TAZ
	INZ
.endif
	PLA
	STQ	ptr
.endmacro

.define STCOLR16 stcolr16

;	Writes a full 16-bit character cell (both bytes explicit) at
;	column col within the row pointed to by far pointer ptr - for
;	tile indices above 255 (the chess piece graphics), where
;	STCELL16's "always zero the high byte" behaviour doesn't apply.
;	Screen RAM only, same as STCELL16 - use STCOLR16 for colour RAM.
;	IN	.A		low byte of the tile index
;	IN	.X		high byte of the tile index
;	IN	ptr		far pointer (already row-selected)
;	IN	col		column (immediate #n or a byte variable)
;	USED	.A, .X, .Z
.macro sttile16 ptr, col
	PHA
.if (.match (.left (1, col), #))
	LDA	#((.right (.tcount (col)-1, col)) * 2)
	TAZ
.else
	LDA	col
	ASL
	TAZ
.endif
	PLA
	STQ	ptr
	INZ
	TXA
	STQ	ptr
.endmacro

.define STTILE16 sttile16

IP65_ERROR_TIMEOUT_ON_RECEIVE = $81
IP65_ERROR_ABORTED_BY_USER    = $86
IP65_ERROR_CONNECTION_CLOSED  = $8A


;	Debugging - show raster time usage on border
	.define	DEBUG_RASTERTIME	0
	
;	Debugging - check message limits and panic if borked
	.define	DEBUG_MSGSPUSHSZ	1

;	Debugging - log each RECV_DATA poll's byte count to the connect log
	.define	DEBUG_RXSIZE	0

;	Debugging - log every keypress's raw ASCIIKEY ($D610) and MODKEY
;	($D60A[0:6]) byte to the connect log, to nail down real MEGA65
;	keyboard-manual values by hand
	.define	DEBUG_KEYSCAN	0

;	Debugging - sleep when internet is idle
	.define DEBUG_INETDOSLEEP	0

;	Loads the custom font via bigglesLoadFontHack at boot. Off for Snake
;	QUADRO - PETSCII/ROM font stays active until the custom Xirod font
;	is adapted for this game's tile needs (explicit user call, 2026-08-24).
	.define	DEBUG_LOADFONT	0


cpuIRQ		=	$FFFE
cpuRESET	=	$FFFC
cpuNMI		=	$FFFA

krnlOutChr	= 	$E716

CIA1_PRA        = 	$DC00        		; Port A
CIA1_PRB	=	$DC01
CIA1_DDRA	=	$DC02
CIA1_DDRB	=	$DC03
cia1IRQCtl	=	$DC0D

VIC     	= 	$D000         		; VIC REGISTERS
VICXPOS0    	= 	VIC + $00      		; LOW ORDER X POSITION
VICYPOS0    	= 	VIC + $01      		; Y POSITION
VICXPOS1    	= 	VIC + $02      		; LOW ORDER X POSITION
VICYPOS1    	= 	VIC + $03      		; Y POSITION
VICXPOS2    	= 	VIC + $04      		; LOW ORDER X POSITION
VICYPOS2    	= 	VIC + $05      		; Y POSITION
VICXPOS3    	= 	VIC + $06      		; LOW ORDER X POSITION
VICYPOS3    	= 	VIC + $07      		; Y POSITION
VICXPOSMSB 	=	VIC + $10      		; BIT 0 IS HIGH ORDER X POS
vicCtrlReg	=	$D011
vicRstrVal	=	$D012
vicSprEnab	= 	$D015
vicSprExpY	=	$D017
vicMemCtrl	=	$D018
vicIRQFlgs	=	$D019
vicIRQMask	=	$D01A
vicSprCMod	= 	$D01C
vicSprExpX	= 	$D01D
vicBrdrClr	=	$D020
vicBkgdClr	= 	$D021
vicSprMCl0	= 	$D025
vicSprMCl1	= 	$D026
vicSprClr0	= 	$D027
vicSprClr1	= 	$D028
vicSprClr2	= 	$D029
vicSprClr3	= 	$D02A

SID     	= 	$D400         		; SID REGISTERS
SID_ADConv1    	= 	SID + $19
SID_ADConv2    	= 	SID + $1A

;	Matches $D60A[0:6] (MODKEY) exactly, so the byte read there can be
;	used as-is - bit 7 (KEYQUEUE, queue-non-empty) is masked off
;	before storage, see userKeyScanKey.
keyModNone	=	$00
keyModShiftL	=	$01
keyModShiftR	=	$02
keyModControl	=	$04
keyModSystem	=	$08		;MEGA key
keyModAlt	=	$10
keyModNoScroll	=	$20
keyModCapsLock	=	$40

buttonLeft	=	$10
buttonRight	=	$01

spriteMem20	= 	$0800

spritePtr0	=	$07F8
spritePtr1	=	$07F9
spritePtr2	=	$07FA
spritePtr3	=	$07FB



FRAMECOUNT          = $d7fa




offsX		=	24
offsY		=	50



	.define MSG_CATG_SYST	$00
	.define MSG_CATG_TEXT	$10
	.define MSG_CATG_LOBY	$20
	.define MSG_CATG_CNCT	$30
	.define MSG_CATG_CLNT	$40
	.define MSG_CATG_SRVR	$50
	.define MSG_CATG_PLAY	$60


	.define	INET_PROC_IDLE	$00
	.define INET_PROC_HALT	$01
	.define INET_PROC_INIT	$02
	.define INET_PROC_CNCT	$03
	.define INET_PROC_EXEC	$04
	.define INET_PROC_DISC	$05
	.define INET_PROC_PCNT	$06
	.define INET_PROC_DSCD	$07

	.define	INET_STATE_NORM	$00
	.define INET_STATE_ERR	$01
	.define INET_STATE_TICK $02
	
	.define INET_ERR_NONE	$00
	.define INET_ERR_INTRF	$01
	.define INET_ERR_INTRN	$02

	.define INET_ERROR_NONE $00
	.define INET_ERROR_INIT $01
	.define	INET_ERROR_CNCT	$02
	.define INET_ERROR_DISC	$03



; C65/MEGA65 JSRFAR workspace
FAR_BANK            = $02
FAR_ADDR_HI         = $03
FAR_ADDR_LO         = $04
FAR_STATUS          = $05
FAR_ARG_A           = $06
FAR_ARG_X           = $07
FAR_ARG_Y           = $08

; 28-bit indirect pointer for staging calls into bank 4.
PTR_LO              = $fb
PTR_HI              = $fc
PTR_BANK            = $fd
PTR_TOP             = $fe

; Mega-IP public jump table, as seen inside bank 4.
MIP_INIT            = $2000
MIP_SET_GATEWAY     = $2003
MIP_SET_LOCAL_IP    = $2006
MIP_SET_LOCAL_PORT  = $2009
MIP_SET_REMOTE_IP   = $200c
MIP_SET_REMOTE_PORT = $200f
MIP_SET_SUBNET      = $2012
MIP_SET_XLATE       = $2015
MIP_DISCONNECT      = $2021
MIP_STATUS_POLL     = $2024
MIP_CONNECT_START   = $2027
MIP_CONNECT_POLL    = $202a
MIP_GET_DNS_RESULT  = $2033
MIP_GET_DNS_STATE   = $2036
MIP_DHCP_START      = $2042
MIP_DHCP_POLL       = $2045
MIP_SET_DNS         = $204b
MIP_GET_LOCAL_IP    = $204e
MIP_GET_GATEWAY     = $2051
MIP_GET_SUBNET      = $2054
MIP_GET_DNS         = $2057
MIP_GET_REMOTE_IP   = $205a
MIP_FORCE_CLOSE     = $205d
MIP_TCP_TX_IDLE     = $2066

; Mega-IP ML extension table.
MIP_ML_SEND_BYTE    = $7600
MIP_DNS_START_BUF   = $760f
MIP_DNS_START_BUF_Y = $7618
MIP_ML_CALL_STAGED  = $761b
MIP_ML_RECV_BYTE    = $761e
MIP_ML_RECV_BLOCK   = $7621

; Staging block at physical bank-4 $77c0.
ML_STAGE_LO         = $77c0
ML_STAGE_HI         = $77
ML_STAGE_BANK       = $04
ML_STAGE_TARGET_LO  = 0
ML_STAGE_TARGET_HI  = 1
ML_STAGE_ARG_A      = 2
ML_STAGE_ARG_X      = 3
ML_STAGE_ARG_Y      = 4
ML_STAGE_ARG_Z      = 5



	.define	KEY_ASC_BKSPC	$14
	.define KEY_ASC_CR	$0D

	.define KEY_ASC_SPACE	$20
	.define KEY_ASC_EXMRK	$21
	.define KEY_ASC_DQUOTE	$22
	.define KEY_ASC_POUND	$23
	.define KEY_ASC_HASH	$23		;Alternate
	.define KEY_ASC_DOLLAR	$24
	.define KEY_ASC_PERCENT	$25
	.define KEY_ASC_AMP 	$26
	.define KEY_ASC_QUOTE	$27
	.define KEY_ASC_OBRCKT 	$28
	.define KEY_ASC_LBRCKT 	$28		;Alternate
	.define	KEY_ASC_CBRCKT	$29
	.define	KEY_ASC_RBRCKT	$29		;Alternate
	.define KEY_ASC_MULT	$2A
	.define KEY_ASC_PLUS	$2B
	.define KEY_ASC_COMMA	$2C
	.define KEY_ASC_MINUS	$2D
	.define KEY_ASC_STOP	$2E
	.define KEY_ASC_DIV	$2F
	.define KEY_ASC_FSLASH	$2F		;Alternate
	.define KEY_ASC_0	$30
	.define KEY_ASC_1	$31
	.define KEY_ASC_2	$32
	.define KEY_ASC_3	$33
	.define KEY_ASC_4	$34
	.define KEY_ASC_5	$35
	.define KEY_ASC_6	$36
	.define KEY_ASC_7	$37
	.define KEY_ASC_8	$38
	.define KEY_ASC_9	$39
	.define KEY_ASC_COLON	$3A
	.define KEY_ASC_SCOLON	$3B
	.define KEY_ASC_LESSTH	$3C
	.define KEY_ASC_EQUALS	$3D
	.define	KEY_ASC_GRTRTH	$3E
	.define KEY_ASC_QMARK	$3F
	.define KEY_ASC_AT	$40
	.define KEY_ASC_A	$41
	.define KEY_ASC_B	$42
	.define KEY_ASC_C	$43
	.define KEY_ASC_D	$44
	.define KEY_ASC_E	$45
	.define KEY_ASC_F	$46
	.define KEY_ASC_G	$47
	.define KEY_ASC_H	$48
	.define KEY_ASC_I	$49
	.define KEY_ASC_J	$4A
	.define KEY_ASC_K	$4B
	.define KEY_ASC_L	$4C
	.define KEY_ASC_M	$4D
	.define KEY_ASC_N	$4E
	.define KEY_ASC_O	$4F
	.define KEY_ASC_P	$50
	.define KEY_ASC_Q	$51
	.define KEY_ASC_R	$52
	.define KEY_ASC_S	$53
	.define KEY_ASC_T	$54
	.define KEY_ASC_U	$55
	.define KEY_ASC_V	$56
	.define KEY_ASC_W	$57
	.define	KEY_ASC_X	$58
	.define KEY_ASC_Y	$59
	.define	KEY_ASC_Z	$5A
	.define	KEY_ASC_OSQRBR	$5B
	.define	KEY_ASC_LSQRBR	$5B		;Alternate
	.define KEY_ASC_BSLASH	$5C		;!!Needs screen code xlat
	.define KEY_ASC_CSQRBR	$5D
	.define KEY_ASC_RSQRBR	$5D		;Alternate
;	HARDWARE LIMITATION - confirmed on real hardware, not just here in
;	software: '^' is doubly unsupported on the MEGA65.
;	  1. No physical key, alone or with MEGA held, reports ASCIIKEY
;	     $5E - unlike the other 7 "needs screen code xlat" characters
;	     around here, which all trace to a real key (BSLASH=MEGA+/,
;	     BQUOTE=MEGA+left-arrow, OCRLYB=MEGA+:, PIPE=MEGA+., CCRLYB=
;	     MEGA+;, TILDE=MEGA+,, USCORE=left-arrow alone). There is no
;	     way to type '^' on this keyboard via $D610, at least via any
;	     modifier combo tried so far (alone, MEGA - Shift/Ctrl untested).
;	  2. Even if $5E is produced some other way (pasted in, injected
;	     programmatically, etc.), the active charset's glyph at that
;	     screen-code position renders as '~' (tilde), not a caret -
;	     screenASCIIXLAT has no entry for $5E, so it falls through
;	     screenASCIIToScreen's generic conversion into whatever the
;	     ROM font actually has there, which isn't a caret glyph.
;	Matters because Pascal source (^ for pointer types) is exactly
;	the kind of text this client might need to display correctly one
;	day - flagging clearly rather than leaving it as a vague "needs
;	xlat" note, since unlike its neighbours this one may not be fixable
;	by adding a screenASCIIXLAT entry alone (there's no key to type it
;	with in the first place, and no glyph to draw even if there were).
	.define KEY_ASC_CARET	$5E		;!!See HARDWARE LIMITATION note above - unreachable via keyboard, no glyph either
	.define KEY_ASC_USCORE	$5F		;!!Needs screen code xlat
	.define KEY_ASC_BQUOTE	$60		;!!Needs screen code xlat. !!Not C64
	.define KEY_ASC_L_A	$61
	.define KEY_ASC_L_B	$62
	.define KEY_ASC_L_C	$63
	.define KEY_ASC_L_D	$64
	.define KEY_ASC_L_E	$65
	.define KEY_ASC_L_F	$66
	.define KEY_ASC_L_G	$67
	.define KEY_ASC_L_H	$68
	.define KEY_ASC_L_I	$69
	.define KEY_ASC_L_J	$6A
	.define KEY_ASC_L_K	$6B
	.define KEY_ASC_L_L	$6C
	.define KEY_ASC_L_M	$6D
	.define KEY_ASC_L_N	$6E
	.define KEY_ASC_L_O	$6F
	.define KEY_ASC_L_P	$70
	.define KEY_ASC_L_Q	$71
	.define KEY_ASC_L_R	$72
	.define KEY_ASC_L_S	$73
	.define KEY_ASC_L_T	$74
	.define KEY_ASC_L_U	$75
	.define KEY_ASC_L_V	$76
	.define KEY_ASC_L_W	$77
	.define	KEY_ASC_L_X	$78
	.define KEY_ASC_L_Y	$79
	.define	KEY_ASC_L_Z	$7A
	.define KEY_ASC_OCRLYB	$7B		;!!Needs screen code xlat. !!Not C64
	.define KEY_ASC_LCRLYB	$7B		;Alternate
	.define KEY_ASC_PIPE	$7C		;!!Needs screen code xlat
	.define KEY_ASC_CCRLYB	$7D		;!!Needs screen code xlat. !!Not C64
	.define KEY_ASC_RCRLYB	$7D		;Alternate
	.define KEY_ASC_TILDE	$7E		;!!Needs screen code xlat

	.define KEY_C64_SHIFT	$01		;Used twice.  Be nice to id l/r
	.define KEY_C64_SYS	$02
	.define KEY_C64_STOP	$03	
	.define KEY_C64_CTRL	$04
	.define	KEY_C64_CRIGHT 	$1D
	.define	KEY_C64_CDOWN 	$11		;Could be ascii line feed? $0A
	.define KEY_C64_HOME	$13
	.define KEY_C64_TAB	$09		;Confirmed on hardware - MEGA65 has no C64 equivalent
	.define KEY_C64_STAB	$0F		;TAB + SHIFT (either) - confirmed on hardware
	.define KEY_C64_POUND	$5C
	.define KEY_C64_ARRUP	$5E
	.define KEY_C64_ARRLEFT	$5F
	.define KEY_C64_SHSTOP	$83
	.define	KEY_C64_F1 	$F1
	.define	KEY_C64_F3 	$F3
	.define	KEY_C64_F5 	$F5
	.define	KEY_C64_F7 	$F7
	.define KEY_C64_F2	$F2
	.define KEY_C64_F4	$F4
	.define KEY_C64_F6	$F6
	.define KEY_C64_F8	$F8
	.define	KEY_C64_F9 	$F9
;	F10/F12/F14 aren't separate physical keys - they're MEGA65's own
;	continuation of the C64 odd/even F-key convention (odd = key
;	pressed alone, even = same key + shift or MEGA - confirmed on
;	real hardware that MEGA and shift report the same code here,
;	e.g. F7 alone $F7, F7+shift or F7+MEGA both $F8).
	.define	KEY_C64_F10	$FA
	.define	KEY_C64_F11	$FB
	.define	KEY_C64_F12	$FC
	.define	KEY_C64_F13	$FD
	.define	KEY_C64_F14	$FE
	.define	KEY_C64_HELP	$1F
	.define	KEY_C64_ESC	$1B		;Per the MEGA65 manual
	.define KEY_C64_SHRET	$8D		;Not mapped
	.define KEY_C64_CUP	$91
	.define KEY_C64_CLEAR	$93
	.define KEY_C64_INS	$94		;Could be ascii shift in? $0F
	.define KEY_C64_CLEFT	$9D		

	.define KEY_C64_INVALID	$FF




;	Controls definitions

	.define	CLR_BACK	$FD		;System - always black
	.define	CLR_EMPTY	$FE		;Border on C64
	.define	CLR_CURSOR	$FF		
	.define	CLR_TEXT	$00
	.define	CLR_FOCUS	$01
	.define	CLR_INSET	$02
	.define	CLR_FACE	$03
	.define CLR_SHADOW	$04
	.define CLR_PAPER	$05
	.define CLR_MONEY	$06
	.define CLR_DIE		$07
	.define CLR_SPEC_TEXT	$10		;Specific system text colour
	.define CLR_SPEC_CTRL	$20		;Specific system control colour 
						;(reversed on C64)

;	.define TYPE_ELEMENT	$00
;	.define TYPE_PAGE	$10
;	.define TYPE_PANEL	$20
;	.define TYPE_TABPANEL	TYPE_PANEL | $01
;	.define TYPE_CONTROL	$30
;	.define TYPE_LABEL	TYPE_CONTROL | $01

	.define STATE_CHANGED	$80		;System - don't use directly
	.define STATE_DIRTY	$40		;System - don't use directly
	.define STATE_PREPARED	$20		;System - for optimisations
	.define STATE_VISIBLE	$01
	.define STATE_ENABLED	$02
	.define STATE_PICK	$04
	.define STATE_ACTIVE	$08
	.define STATE_DOWN	$10

	.define	OPT_NOAUTOINVL	$01
	.define	OPT_NONAVIGATE	$02
	.define OPT_NODOWNACTV	$04
	.define OPT_CAPTURECRSR $08
	.define OPT_DOWNCAPTURE $10
	.define	OPT_AUTOCHECK	$20
	.define OPT_TEXTACCEL2X	$40
	.define OPT_TEXTCONTMRK $80

;	Loop-iteration cap for ctrlsMoveActiveControl's panel/control
;	wraparound search - see its own comment (2026-08-24 fix). Generous
;	relative to any real page's panel*control count, so it only ever
;	matters as a safety net, never a real limit.
	.define CTRLS_NAV_GUARD_MAX 200


;	Controls structures

	.struct	ELEMENT
;		prepare	.word
		present	.word
		changed .word
		keypress .word
;		type	.byte
		state	.byte
		options	.byte
		colour	.byte
		posx	.byte
		posy	.byte
		width	.byte
		height	.byte
		tag	.byte
	.endstruct
	
	.struct PAGE
		_element .tag ELEMENT
		nxtpage	.word
		bakpage	.word
		textptr	.word
		textoffx .byte
		panels	.word
		panlcnt	.byte
	.endstruct

	.struct	PANEL
		_element .tag ELEMENT
		page	.word
		controls .word
		ctrlcnt	.byte
	.endstruct
	
	.struct	TABPANEL
		_panel	.tag PANEL
		page	.word
	.endstruct

	.struct	LOGPANEL
		_panel	.tag	PANEL
		lines	.word
		linecnt .byte
		currln	.byte
		offsy	.byte
	.endstruct

	.struct	CONTROL
		_element .tag ELEMENT
		panel	.word
		textptr	.word
		textoffx .byte
		textaccel .byte
		accelchar .byte
	.endstruct

	.struct LABELCTRL
		_control .tag CONTROL
		actvctrl .word
	.endstruct

	.struct	EDITCTRL
		_control .tag	CONTROL
		textsiz  .byte
		textmaxsz .byte
	.endstruct
	



;===============================================================================
;	.segment  "ZEROPAGE": zeropage
;===============================================================================
;	.exportzp inetproc
	
;pageptr0:
;			.res	2
pageptr0 = $10

;panlptr0:
;			.res	2
panlptr0 = $12

;elemptr0:
;			.res	2
elemptr0 = $14

;ctrlptr0:
;			.res	2
ctrlptr0 = $16

;ctrlptr1:
;			.res	2
ctrlptr1 = $18


;	tempptr0-3 are 32-bit far pointers (lo/hi/bank/mb, NOP-prefix
;	indirect - see PTR_LO/PTR_HI/PTR_BANK/PTR_TOP) so they can reach
;	screen/colour RAM now that both live past $FFFF ($010000/$01F800).
;	Plain 2-byte (elemptr0-style) indirect still works through the low
;	two bytes for callers that don't need the far form.
;tempptr0:
;			.res 	4
tempptr0 = $1A

;tempptr1:
;			.res 	4
tempptr1 = $1E


;tempptr2:
;			.res 	4
tempptr2 = $22


;tempptr3:
;			.res 	4
tempptr3 = $26

;tempdat0:
;			.res	1
tempdat0  = $2A

;tempdat1:
;			.res	1
tempdat1 = $2B

;tempdat2:
;			.res 	1
tempdat2 = $2C

;tempdat3:
;			.res	1
tempdat3 = $2D

;imsgdat1:
;			.res	1
imsgdat1 = $2E

;imsgdat2:
;			.res	1
imsgdat2 = $2F

;tempbit0:
;			.res	1
tempbit0 = $30

;msgsptr0:
;			.res	2
msgsptr0 = $31

;msgsdat0:
;			.res	1
msgsdat0 = $33

;msgsdat1:
;			.res	1
msgsdat1 = $34

;senddat0:
;			.res	1
senddat0 = $35

;sendptr0:
;			.res	2
sendptr0 = $36

;pickCtrl:
;			.res	2
pickCtrl = $38

;downCtrl:
;			.res	2
downCtrl = $3A

;actvCtrl:
;			.res	2
actvCtrl = $3C

;inetproc:
;			.res	1
inetproc = $3E

;inetstat:
;			.res	1
inetstat = $3F

;ineterrk:
;			.res	1
ineterrk = $40

;ineterrc:
;			.res	1
ineterrc = $41

;inetread:
;			.res	2
inetread = $42

;inetcalc:
;			.res	2
inetcalc = $44


;keyZPKeyDown:
;			.res	1
keyZPKeyDown = $46

;keyZPKeyCount:
;			.res	1
keyZPKeyCount = $47

;keyZPKeyScan:
;			.res	1
keyZPKeyScan = $48

;keyZPDecodePtr:
;			.res	2
keyZPDecodePtr = $49

;keyZPAbort:
;			.res	1
keyZPAbort = $4B

;	Dedicated far pointer for the IRQ's cursor-blink screen/colour
;	writes - NOT shared with tempptr0-3, since those can be mid-use by
;	whatever foreground code this IRQ preempts.
;irqptr0:
;			.res	4
irqptr0 = $4C

