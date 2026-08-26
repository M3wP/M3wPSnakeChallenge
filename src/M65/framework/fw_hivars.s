;===============================================================================
; fw_hivars.s - FRAMEWORK (reusable across games)
;
; This is a REAL segment boundary, not just an organizational comment
; like most of the "BSS"/"RODATA"/"INIT"/"ONCE" section markers
; elsewhere in this port (chess.s had only two actual .segment
; directives in its ~18,000 lines: CODE at the very top, and this
; HIVARS one right here). High memory ($E000-$FFF9, KERNAL banked out
; by initROM) costs nothing in the .prg image, unlike everything above
; this point which - despite plenty of "BSS"-labeled comments - is
; really still all one CODE segment and DOES consume file bytes.
;
; Must be .include'd LAST, after a game's own file, so that any
; game-specific state the game wants to declare lands back in CODE
; (matching where chess's own chessGameState/boardPickMode/etc sat -
; before this boundary) rather than silently inheriting HIVARS just
; because it happened to be assembled after this file.
;
; Extracted from M3wPChess's chess.s during the Snake Challenge QUADRO
; port (2026-08-24). See fw_core.s for the wider extraction note.
;===============================================================================

;	Real end-of-CODE size check (see fw_ctrls_net.s's note on why it's
;	here and not there) - covers framework CODE plus whatever
;	game-specific CODE-segment content sits between that file and this
;	one in the assembled output.
.if * > $CFFF
.error .sprintf("CODE now ends at $%04X, past $D000 - program borken!!", *)
.endif

.segment "HIVARS"

;	THE .reloc IS LOAD-BEARING - DO NOT REMOVE IT.
;
;	The BASIC stub at the top of the program does .org $07FF, and until
;	this line nothing anywhere calls .reloc. Per the ca65 manual (11.77):
;	"By default, absolute/relocatable mode is global (valid even when
;	switching segments)" - so the assembler is STILL in absolute mode
;	when it reaches the .segment directive above, and the program counter
;	simply carries on from wherever CODE ended.
;
;	Without this line every label below is baked by ca65, as a constant,
;	at CODE_end+1 - and ld65 cannot correct it, because an absolute value
;	leaves no relocation for the linker to fix up. The map file still
;	reports the segment at $E000, which is what makes this look fine when
;	it is not: only the emitted bytes disagree.
;
;	That is harmless while CODE is small - the vars just land in unused
;	RAM above the program - and catastrophic once CODE grows enough to
;	push them past $D000, where every write lands on an IO register
;	instead. Snake was 833 bytes from that when this was found
;	(2026-08-26). chess.s, being bigger, was already over the line, which
;	is why it always carried an .org $E000 here and dengland remembered
;	it as necessary - it was.
;
;	.reloc rather than that .org because the address then comes from
;	HIMEM in m65.cfg alone, instead of being repeated here where the two
;	could drift apart. Verified byte-identical to the .org version.
	.reloc

RX_BLOCK_BUF:
			.res	256

sendmsg0:
			.res	100
sendmsg1:
			.res	100
sendmsg2:
			.res	100
sendmsg3:
			.res	100
sendmsg4:
			.res	100
sendmsg5:
			.res	100

readmsg0:
			.res	100

msgs_change:
			.res	256
msgs_dirty:
			.res	256

cnct_log_line0:
			.res	41
cnct_log_line1:
			.res	41
cnct_log_line2:
			.res	41
cnct_log_line3:
			.res	41
cnct_log_line4:
			.res	41
cnct_log_line5:
			.res	41
cnct_log_line6:
			.res	41
cnct_log_line7:
			.res	41
cnct_log_line8:
			.res	41
cnct_log_line9:
			.res	41
cnct_log_lineA:
			.res	41
cnct_log_lineB:
			.res	41
cnct_log_lineC:
			.res	41


room_log_line0:
			.res	41
room_log_line1:
			.res	41
room_log_line2:
			.res	41
room_log_line3:
			.res	41
room_log_line4:
			.res	41
room_log_line5:
			.res	41
room_log_line6:
			.res	41
room_log_line7:
			.res	41
room_log_line8:
			.res	41
room_log_line9:
			.res	41
room_log_lineA:
			.res	41
room_log_lineB:
			.res	41
room_log_lineC:
			.res	41
room_log_lineD:
			.res	41
room_log_lineE:
			.res	41
room_log_lineF:
			.res	41
room_log_line10:
			.res	41

play_log_line0:
			.res	41
play_log_line1:
			.res	41
play_log_line2:
			.res	41
play_log_line3:
			.res	41
play_log_line4:
			.res	41
play_log_line5:
			.res	41
play_log_line6:
			.res	41
play_log_line7:
			.res	41
play_log_line8:
			.res	41
play_log_line9:
			.res	41
play_log_lineA:
			.res	41
play_log_lineB:
			.res	41
play_log_lineC:
			.res	41
play_log_lineD:
			.res	41
play_log_lineE:
			.res	41
play_log_lineF:
			.res	41
play_log_line10:
			.res	41
