;===============================================================================
;	mouse.inc - proportional-mouse driver + joystick/button port reads
;-------------------------------------------------------------------------------
;	This is a DROP-IN REPLACEMENT for userProcessMouse/MoveCheck in
;	test.s. It reuses the existing state (XPos/YPos/XMin/XMax/YMin/
;	YMax/Buttons/ButtonsOld/OldPotX/OldPotY/mouseCheck/OldValue/
;	NewValue) and calls the existing CMOVEX/CMOVEY/ButtonCheck
;	unchanged, so none of the downstream UI layer - capture
;	(mouseCapture/mouseCapMove/mouseCapClick), hit-testing
;	(userMouseInCtrl and friends), or click handling (userHandleMouse/
;	userHandleMouseClick) - needs to change at all.
;
;	THE PORT DISCIPLINE, and why it looks roundabout
;	------------------------------------------------
;	Restructured 2026-08-25 to follow MEGASPUTM's input.c (kept in
;	src/3rdparty/ for reference), which is a shipped MEGA65 engine and
;	therefore a working configuration on hardware this codebase cannot
;	test on. Three rules, all of them load-bearing:
;
;	1. DDRA/DDRB ARE SET ONCE, AT INIT, AND NEVER TOUCHED AGAIN.
;	   The previous version flipped both to input and back on every
;	   frame and read the ports on the very next instruction. On
;	   dengland's MEGA65 revision the CIA direction registers do
;	   nothing at all, so that worked; on later revisions they are
;	   really implemented and the lines have not settled by the time
;	   the read happens. Never changing them is correct on both - the
;	   writes are simply ignored on the older machines.
;
;	2. EVERY PRA CHANGE IS PAID FOR WITH USEFUL WORK BEFORE ITS READ.
;	   input.c says it twice - "prepare CIA1 already for sampling
;	   mouse, as this takes some time" - and arranges the frame so the
;	   multiplexer always has real work happening between being
;	   selected and being sampled. So does this: the pots are read at
;	   the top of a frame having been selected at the end of the LAST
;	   one, and the joystick is read only after the delta maths and the
;	   whole keyboard scan have run.
;
;	3. THE KEYBOARD MATRIX IS LEFT ALONE.
;	   The old code drove DDRB to output and wrote "all keys pushed"
;	   whenever a button was down. That is a KERNAL-era trick to stop
;	   mouse buttons reading as keys, and this framework does not read
;	   the keyboard through the matrix at all - it reads the MEGA65's
;	   own scanner at $D610 (userKeyScanKey). So the write bought
;	   nothing and actively disturbed the scanner, which is the
;	   suspected cause of "you can't use the keyboard when the mouse is
;	   plugged in" on newer revisions (dengland, 2026-08-25). PRB now
;	   stays driven high, exactly as input.c leaves it.
;
;	The frame is therefore SPLIT ACROSS TWO ENTRY POINTS, called either
;	side of the keyboard scan (see fw_font_input.s):
;
;		userProcessMouse	pots, then select the joystick
;		userKeyScanKey		<- the settling delay, doing real work
;		userProcessPorts	joystick + buttons, then select the pots
;
;	They are not independent - userProcessPorts must run after
;	userProcessMouse and before userHandleMouse, since it is what fills
;	in Buttons. Splitting them is the whole point: there is nowhere else
;	to put a delay that isn't wasted time.
;===============================================================================

;-------------------------------------------------------------------------------
;	userInitPorts - one-time CIA1 setup, called from the startup
;	sequence (fw_startup.s) before main.
;
;	input_init() in input.c, with the same values. Both ports are
;	OUTPUT and both are driven high: a joystick switch or mouse button
;	pulls its line down against that, which is what makes the per-frame
;	reads work without ever touching a direction register again.
;-------------------------------------------------------------------------------
userInitPorts:
;-------------------------------------------------------------------------------
		LDA	#$FF
		STA	VAL_CIA1_DDRA		;both ports output...
		STA	VAL_CIA1_DDRB
		STA	VAL_CIA1_PRB		;...and all port B pins high

;	Select port 1's pots for the SID now, so the very first frame's
;	read has had as long to settle as every later one.
		LDA	#VAL_CIA1_PRA_POTS
		STA	VAL_CIA1_PRA

;	Keyboard column C8 on the C65/MEGA65 hangs off UART_E, not the CIA,
;	and nothing in this framework was driving it. Straight out of
;	input_init().
		LDA	VAL_UART_E_DDR
		ORA	#$02
		STA	VAL_UART_E_DDR

		LDA	VAL_UART_E_PRA
		ORA	#$02
		STA	VAL_UART_E_PRA

		RTS


;-------------------------------------------------------------------------------
userProcessMouse:
;-------------------------------------------------------------------------------
		LDA	mouseCheck
		BEQ	@begin

		INC	mouseCheck

@begin:
;	SAMPLE BOTH POTS FIRST, before anything else touches VAL_CIA1_PRA. The
;	multiplexer was pointed at them at the end of the previous frame
;	(userProcessPorts), so this is the one read in the frame that has
;	had a full frame of settling behind it.
;
;	Both are latched into RAM here rather than being read one at a time
;	as the maths needs them, because the moment the multiplexer is
;	switched below, the OTHER pot is no longer available.
		LDA	VAL_SID_ADCONV1
		STA	potXRaw
		LDA	VAL_SID_ADCONV2
		STA	potYRaw

;	Multiplexer now switches to the joystick, and everything below -
;	plus the whole of userKeyScanKey - is the settling time before
;	userProcessPorts actually reads it.
		LDA	#VAL_CIA1_PRA_JOY
		STA	VAL_CIA1_PRA

		LDA	potXRaw			;Get mouse X movement
		LDY	OldPotX
		JSR	MouseReadDelta		;Calculate movement vector

; Skip processing if nothing has changed

		BCC	@SkipX
		STY	OldPotX

; Calculate the new X coordinate (--> a/y)

		CLC
		ADC	XPos

		TAY				;Remember low byte
		TXA
		ADC	XPos + 1
		TAX

; Limit the X coordinate to the bounding box

		CPY	XMin
		SBC	XMin + 1
		BPL	@L1
		LDY	XMin
		LDX	XMin + 1
		JMP	@L2
@L1:
		TXA

		CPY	XMax
		SBC	XMax + 1
		BMI	@L2
		LDY	XMax
		LDX	XMax + 1
@L2:
		STY	XPos
		STX	XPos + 1

; Move the mouse pointer to the new X pos

		TYA
		JSR	CMOVEX

		LDA	mouseCheck
		BNE	@SkipX

		LDA	#$01
		STA	mouseCheck

; Calculate the Y movement vector

@SkipX:
		LDA	potYRaw			;Get mouse Y movement
		LDY	OldPotY
		JSR	MouseReadDelta		;Calculate movement

; Skip processing if nothing has changed

		BCC	@SkipY
		STY	OldPotY

; Calculate the new Y coordinate (--> a/y)

		STA	OldValue
		LDA	YPos
		SEC
		SBC	OldValue

		TAY
		STX	OldValue
		LDA	YPos + 1
		SBC	OldValue
		TAX

; Limit the Y coordinate to the bounding box

		CPY	YMin
		SBC	YMin + 1
		BPL	@L3
		LDY	YMin
		LDX	YMin + 1
		JMP	@L4
@L3:
		TXA

		CPY	YMax
		SBC	YMax + 1
		BMI	@L4
		LDY	YMax
		LDX	YMax + 1
@L4:
		STY	YPos
		STX	YPos + 1

; Move the mouse pointer to the new Y pos

		TYA
		JSR	CMOVEY

		LDA	mouseCheck
		BNE	@SkipY

		LDA	#$01
		STA	mouseCheck

; Done

@SkipY:
		CLC				;Interrupt not "handled"

		RTS


;-------------------------------------------------------------------------------
;	userProcessPorts - read control port 2 (joystick) and control port 1
;	(mouse buttons), then re-select the pots for the next frame.
;
;	SECOND HALF of the frame's port work - see the discipline note at the
;	top of this file. Must be called AFTER userKeyScanKey (which is what
;	gives VAL_CIA1_PRA time to settle after userProcessMouse switched it) and
;	BEFORE userHandleMouse (which consumes Buttons/ButtonLClick).
;-------------------------------------------------------------------------------
userProcessPorts:
;-------------------------------------------------------------------------------
		LDX	VAL_CIA1_PRA		;Control-Port 2 (joystick)
		LDA	VAL_CIA1_PRB		;Control-Port 1 (mouse buttons)

		EOR	#%11111111		;Bit goes up when button goes down
		STA	Buttons

;	Port 2's direction bits, kept for the game (see gamePollJoystick,
;	snake_game.s). Active low on the wire, so the EOR leaves a set bit
;	meaning "pushed": bit0 up, bit1 down, bit2 left, bit3 right.
		TXA
		EOR	#%11111111
		AND	#%00001111
		STA	joyDirs

;	Fire doubles as a left click only while joyAsMouse says so - see its
;	own comment. A game that is steering with the stick clears it, so
;	fire can't also press whatever control has focus.
		LDA	joyAsMouse
		BEQ	@nojoybtn

		TXA
		EOR	#%11111111
		AND	#buttonLeft		;Only the joystick fire bit counts
		ORA	Buttons			;	- merge into mouse buttons
		STA	Buttons

@nojoybtn:
		JSR	ButtonCheck

;	Point the multiplexer back at the pots for NEXT frame's
;	userProcessMouse. Doing it here rather than there is the whole
;	trick - it buys a full frame of settling for free.
		LDA	#VAL_CIA1_PRA_POTS
		STA	VAL_CIA1_PRA

		RTS


;	Raw pot readings, latched by userProcessMouse before the multiplexer
;	is switched away from them - see its own comment.
potXRaw:
		.byte	$00
potYRaw:
		.byte	$00


;-------------------------------------------------------------------------------
;	MouseReadDelta - ported from input.c's check_mouse_movement(),
;	folding in apply_acceleration() for any non-zero result.
;
;	Entry:	A = current pot reading, Y = old pot reading
;	Exit:	carry set, Y = value to store as the new "old" reading,
;		X:A = signed 16-bit delta (X is A's sign, $00 or $FF),
;		ready to ADC straight into a position word - same
;		contract the old MoveCheck had.
;		carry clear means no movement (X/A/Y not meaningful).
;-------------------------------------------------------------------------------
MouseReadDelta:
		STA	NewValue
		STY	OldValue

		LDX	#$00

		SEC
		LDA	NewValue
		SBC	OldValue
		AND	#$7F			; a = mod128 (new - old)

		CMP	#$40
		BCS	@neg

;	Small (non-negative) delta

		LSR	A
		BEQ	@zero

		JSR	MouseAccelerate

		LDY	NewValue
		SEC
		RTS

@neg:
		ORA	#$C1			; "or" in high-order bits
		CMP	#$FF			; noise floor - treat as no move
		BEQ	@zero

		SEC
		ROR	A			; a /= 2, sign preserved
		DEX				; X = $FF, sign-extend the delta

		JSR	MouseAccelerate

		LDY	NewValue
		SEC
		RTS

@zero:
		LDA	#$00
		CLC
		RTS


MOUSE_SPEED_SLOW	= 0
MOUSE_SPEED_MEDIUM	= 1
MOUSE_SPEED_FAST	= 2

;-------------------------------------------------------------------------------
;	MouseAccelerate - ported from input.c's apply_acceleration(), with
;	the two thresholds pulled from mouseAccelParams (indexed by
;	mouseAccelSpeed) instead of hardcoded, so the PREFS page can change
;	feel at runtime.
;
;	Entry/exit: A = signed delta, scaled up for larger movements so a
;	fast physical mouse move doesn't feel like it's dragging.
;-------------------------------------------------------------------------------
MouseAccelerate:
		STA	mouseAccelTemp
		BPL	@pos

		EOR	#$FF
		CLC
		ADC	#$01

@pos:
		STA	mouseAccelAbs

		LDA	mouseAccelSpeed
		ASL	A
		TAY				;Y = speed * 2, indexes the pair

		LDA	mouseAccelAbs
		CMP	mouseAccelParams, Y		;high threshold
		BCC	@tst5

		LDA	mouseAccelTemp
		ASL	A
		ASL	A			; value << 2
		RTS

@tst5:
		LDA	mouseAccelAbs
		CMP	mouseAccelParams + 1, Y		;low threshold
		BCC	@none

		LDA	mouseAccelTemp
		ASL	A			; value << 1
		RTS

@none:
		LDA	mouseAccelTemp
		RTS


mouseAccelTemp:
		.byte	$00
mouseAccelAbs:
		.byte	$00

;	0=slow, 1=medium, 2=fast - default medium
mouseAccelSpeed:
		.byte	MOUSE_SPEED_MEDIUM

;	high, low threshold pair per speed - abs delta > high gets <<2,
;	> low gets <<1, otherwise unscaled. Order must match MOUSE_SPEED_*.
mouseAccelParams:
		.byte	21, 16			;slow
		.byte	16, 11			;medium
		.byte	11, 6			;fast
