;===============================================================================
; snake.s - Snake Challenge QUADRO, MEGA65 client top-level file
;
; Ties together the generic framework (framework/*.s, extracted from
; M3wPChess's chess.s during this port - see framework/fw_core.s for the
; extraction note) with this game's own content (snake_game.s). Segment
; order matters here (see framework/fw_hivars.s) - this is the one file
; that has to get the .include order right, everything else just slots
; into whichever segment is already open when it's reached.
;===============================================================================

;===============================================================================
;	GAME IDENTITY - the only two things left in framework/ that differ
;	per game, so they're defined here (before the includes) rather than
;	edited into the framework on every port. If a third ever appears,
;	it belongs here too, not in a framework file.
;
;	The framework's own contract with the game is otherwise just seven
;	hooks (gameStateInit, gamePollTick, gameKeyPress, gameProcPlayMsg,
;	gameResetPlayGame, gameLoadPalette, gameTilesLoadHack) plus
;	page_ovrvw, all supplied by snake_game.s.
;===============================================================================

GAME_INET_PORT	= 19763				;Chess is 19762, Yahtzee 7632

	.define	GAME_TITLE_TEXT	"SNAKE CHALLENGE QUADRO!"

;	Not debug-only despite the name: gates the JSR fontLoadXirod in
;	fw_startup.s. Snake loads its charset another way; Chess sets this 1.
	.define	DEBUG_LOADFONT	0

;	Snake adds no control of its own to the generic preferences panel.
GAME_CONFIG_THEME_EXTRA	= 0


.include "framework/fw_core.s"
.include "framework/fw_startup.s"
.include "framework/fw_ui_shell.s"

;===============================================================================
;	$2000 is a fixed load address (eth.bin/mega-ip's jump table is
;	hardcoded to it). bigglesworth.s/eth.bin are path-relative to this
;	file's own directory, so this block stays here rather than moving
;	into framework/ - see fw_font_input.s's own note.
;===============================================================================
.include "bigglesworth.s"

.out .sprintf("Before eth.bin pad: * = $%04X, room until $2000 = %d bytes", *, $2000 - *)

.res    $2000 - *, 0

.assert * = $2000, error, "eth.bin must load at $2000 - mega-ip's own jump table (MIP_INIT etc.) is hardcoded to that address, layout above no longer adds up"

.incbin "eth.bin"


.include "framework/fw_font_input.s"
.include "framework/fw_ctrls_net.s"

.include "snake_game.s"

.include "framework/fw_hivars.s"
