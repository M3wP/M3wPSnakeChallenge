;===============================================================================
; fw_ui_shell.s - FRAMEWORK (reusable across games)
;
; The generic "lobby shell" page definitions: splash/version screen
; (page_splsh), the main tab navigation (tab_main), preferences
; (page_config), server connect (page_connect), lobby/chat room
; (page_room), and the game join list (page_play). None of this is
; game-specific - confirmed by diffing against Yahtzee's independent
; copy (byte-identical over this range).
;
; A game's own overview/board pages (chess's page_ovrvw/page_detail;
; Snake QUADRO's equivalent) are NOT here - they live in the game's own
; file, since that's where the actual gameplay UI differs per game.
;
; Extracted from M3wPChess's chess.s during the Snake Challenge QUADRO
; port (2026-08-24). See fw_core.s for the wider extraction note.
;===============================================================================

;===============================================================================
;USER INTERFACE DEFINITIONS
;===============================================================================

.out .sprintf("UI control definitions start: * = $%04X", *)

	.export	page_splsh
;-------------------------------------------------------------------------------
page_splsh:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00 		;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	$0000		;nxtpage
			.word	$0000		;bakpage
			.word	$0000		;textptr	.word
			.byte	$00		;textoffx .byte
			.word	page_splsh_pnls ;panels	.word
			.byte	$05

page_splsh_pnls:
			.word	panel_splsh_hdr
			.word	panel_splsh_body
			.word	panel_splsh_bkgd
			.word	panel_splsh_frgd
			.word	panel_splsh_foot
			.word	$0000
			
panel_splsh_hdr:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$00		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$03		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_splsh
			.word	panel_splsh_hdr_ctrls	;controls .word
			.byte	$01

panel_splsh_hdr_ctrls:
			.word	hlabel_splsh_title
			.word	$0000

hlabel_splsh_title:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FOCUS	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$02		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_hdr	;panel	.word
			.word	text_splsh_title	;textptr	.word
			.byte	$0E		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

panel_splsh_body:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$15		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_splsh
			.word	panel_splsh_body_ctrls	;controls .word
			.byte	$01

panel_splsh_body_ctrls:
			.word	button_splsh_cont
			.word	$0000

button_splsh_cont:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientSplshContChng
			.word	clientSplshContKeyPress
			.byte	$00
			.byte	$00		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$0F		;posx	.byte
			.byte	$16		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_body	;panel	.word
			.word	text_splsh_cont	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	'c'		;accelchar .byte

panel_splsh_bkgd:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_SHADOW	;colour	.byte
			.byte	$04		;posx	.byte
			.byte	$07		;posy	.byte
			.byte	$23		;width	.byte
			.byte	$0E		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_splsh
			.word	panel_splsh_bkgd_ctrls	;controls .word
			.byte	$00

panel_splsh_bkgd_ctrls:
			.word	$0000

panel_splsh_frgd:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_PAPER	;colour	.byte
			.byte	$02		;posx	.byte
			.byte	$05		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$0F		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_splsh
			.word	panel_splsh_frgd_ctrls	;controls .word
			.byte	$05

panel_splsh_frgd_ctrls:
			.word	static_splsh_text0
			.word	static_splsh_text1
			.word	static_splsh_text2
			.word	static_splsh_text3
			.word	static_splsh_text4
			.word	$0000

static_splsh_text0:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$02		;posx	.byte
			.byte	$07		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_frgd	;panel	.word
			.word	text_splsh_text0	;textptr	.word
			.byte	$04		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte

static_splsh_text1:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$02		;posx	.byte
			.byte	$09		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_frgd	;panel	.word
			.word	text_splsh_text1	;textptr	.word
			.byte	$06		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte

static_splsh_text2:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$02		;posx	.byte
			.byte	$0C		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_frgd	;panel	.word
			.word	text_splsh_text2	;textptr	.word
			.byte	$09		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte

static_splsh_text3:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$02		;posx	.byte
			.byte	$0F		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_frgd	;panel	.word
			.word	text_splsh_text3	;textptr	.word
			.byte	$06		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte

static_splsh_text4:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$02		;posx	.byte
			.byte	$11		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_frgd	;panel	.word
			.word	text_splsh_text4	;textptr	.word
			.byte	$09		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte

panel_splsh_foot:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$18		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_splsh
			.word	panel_splsh_foot_ctrls	;controls .word
			.byte	$01
			
panel_splsh_foot_ctrls:
			.word	static_init_text0
			.word	$0000

static_init_text0:
;			.word	$0000		;prepare
			.word	clientInitLblPres	;present	.word
			.word	$0000			;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$18		;posy	.byte
			.byte	$24		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_splsh_foot	;panel	.word
			.word	text_init_text0	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte


tab_main:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_TAB
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00 		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$00		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$03		;height	.byte
			.byte	$00		;tag	.byte
			.word	$0000
			.word	tab_main_ctrls	;controls .word
			.byte	$07
			.word	$0000		;page	.word
			
tab_main_ctrls:
			.word	tlabel_main_begin
			.word	tlabel_main_chat
			.word	tlabel_main_play
			.word	tlabel_main_prefs
			.word	hlabel_main_page
			.word 	button_main_back
			.word 	button_main_next
			.word	$0000

tlabel_main_begin:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientMainBeginChng	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE | OPT_NODOWNACTV | OPT_TEXTACCEL2X	
			.byte	CLR_FOCUS	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$00		;posy	.byte
			.byte	$09		;width	.byte
			.byte	$02		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	text_main_begin ;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$00		;textaccel .byte
			.byte	KEY_C64_F1	;accelchar .byte
			.word	$0000		;actvctrl .word
			
tlabel_main_chat:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientMainChatChng ;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NODOWNACTV | OPT_TEXTACCEL2X 
			.byte	CLR_FACE	;colour	.byte
			.byte	$09		;posx	.byte
			.byte	$00		;posy	.byte
			.byte	$09		;width	.byte
			.byte	$02		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	text_main_chat  ;textptr	.word
			.byte	$01		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	KEY_C64_F3		;accelchar .byte
			.word	$0000		;actvctrl .word
		
tlabel_main_play:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientMainPlayChng	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NODOWNACTV | OPT_TEXTACCEL2X	
			.byte	CLR_FACE	;colour	.byte
			.byte	$12		;posx	.byte
			.byte	$00		;posy	.byte
			.byte	$09		;width	.byte
			.byte	$02		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	text_main_play  ;textptr	.word
			.byte	$01		;textoffx .byte
			.byte	$01		;teXtaccel .byte
			.byte	KEY_C64_F5		;accelchar .byte
			.word	$0000		;actvctrl .word

tlabel_main_prefs:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientMainPrefsChng	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NODOWNACTV | OPT_TEXTACCEL2X
			.byte	CLR_FACE	;colour	.byte
			.byte	$1B		;posx	.byte
			.byte	$00		;posy	.byte
			.byte	$09		;width	.byte
			.byte	$02		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	text_main_prefs ;textptr	.word
			.byte	$01		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	KEY_C64_F9		;accelchar .byte
			.word	$0000		;actvctrl .word

hlabel_main_page:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FOCUS	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$02		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	$0000 		;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

button_main_back:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientMainBackChng
			.word	$0000		;keypress .word
			.byte	$00 
			.byte	OPT_TEXTACCEL2X	;options	.byte
			.byte	CLR_FOCUS	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$02		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	text_main_back	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	KEY_C64_F8	;accelchar .byte
			
button_main_next:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientMainNextChng
			.word	$0000		;keypress .word
			.byte	$00
			.byte	OPT_TEXTACCEL2X	;options	.byte
			.byte	CLR_FOCUS	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$02		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	tab_main	;panel	.word
			.word	text_main_next	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	KEY_C64_F7	;accelchar .byte


page_config:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00 		;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	$0000		;nxtpage
			.word	$0000		;bakpage
			.word	text_page_config;textptr	.word
			.byte	$10		;textoffx .byte
			.word	page_config_pnls;panels	.word
			.byte	$03

page_config_pnls:
			.word	tab_main
			.word	panel_config_mouse
			.word	panel_config_theme
			.word	$0000

panel_config_mouse:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_PANEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$14		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_config
			.word	panel_config_mouse_ctrls;controls .word
			.byte	$04

panel_config_mouse_ctrls:
			.word	label_config_mouse
			.word	checkbx_config_mouse_slow
			.word	checkbx_config_mouse_medium
			.word	checkbx_config_mouse_fast
			.word	$0000

label_config_mouse:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$01		;posx	.byte
			.byte	$04		;posy	.byte
			.byte	$12		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_config_mouse	;panel	.word
			.word	text_config_mouse;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

checkbx_config_mouse_slow:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientConfigSpeedSlowChng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_AUTOCHECK		;options
			.byte	CLR_FACE		;colour
			.byte	$02			;posx
			.byte	$06			;posy
			.byte	$10			;width
			.byte	$01			;height
			.byte	$00			;tag	- unchecked
			.word	panel_config_mouse	;panel
			.word	text_config_mouse_slow	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_L_S	;accelchar

checkbx_config_mouse_medium:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientConfigSpeedMediumChng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_AUTOCHECK		;options
			.byte	CLR_FACE		;colour
			.byte	$02			;posx
			.byte	$08			;posy
			.byte	$10			;width
			.byte	$01			;height
			.byte	$01			;tag	- checked (default speed)
			.word	panel_config_mouse	;panel
			.word	text_config_mouse_medium	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_L_M			;accelchar

checkbx_config_mouse_fast:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientConfigSpeedFastChng	;changed
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_AUTOCHECK		;options
			.byte	CLR_FACE		;colour
			.byte	$02			;posx
			.byte	$0A			;posy
			.byte	$10			;width
			.byte	$01			;height
			.byte	$00			;tag	- unchecked
			.word	panel_config_mouse	;panel
			.word	text_config_mouse_fast	;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	KEY_ASC_L_F		;accelchar


panel_config_theme:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_PANEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$14		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$14		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_config
			.word	panel_config_theme_ctrls;controls .word
			.byte	$06

panel_config_theme_ctrls:
			.word	label_config_theme
			.word	button_config_theme_prv
			.word	button_config_theme_nxt
			.word	label_config_theme_name
			.word	label_config_interface
			.word	checkbx_config_flashchat
			.word	$0000

label_config_theme:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$15		;posx	.byte
			.byte	$04		;posy	.byte
			.byte	$12		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_config_theme	;panel	.word
			.word	text_config_theme;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

button_config_theme_prv:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientConfigThemePrvChng	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$16		;posx	.byte
			.byte	$06		;posy	.byte
			.byte	$07		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_config_theme	;panel	.word
			.word	text_config_theme_prv	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$03		;textaccel .byte
			.byte	KEY_ASC_L_P		;accelchar .byte

button_config_theme_nxt:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientConfigThemeNxtChng	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$1F		;posx	.byte
			.byte	$06		;posy	.byte
			.byte	$07		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_config_theme	;panel	.word
			.word	text_config_theme_nxt	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	KEY_ASC_L_N		;accelchar .byte

label_config_theme_name:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_TEXT	;colour	.byte
			.byte	$16		;posx	.byte
			.byte	$08		;posy	.byte
			.byte	$10		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_config_theme	;panel	.word
			.word	name_clrschme0	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

label_config_interface:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$15		;posx	.byte
			.byte	$0B		;posy	.byte
			.byte	$12		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_config_theme	;panel	.word
			.word	text_config_interface;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	$0000		;actvctrl .word

checkbx_config_flashchat:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	ctrlsControlDefChanged	;changed - plain toggle, roomLogNotifyUpdate reads the tag directly
			.word	$0000			;keypress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_AUTOCHECK		;options
			.byte	CLR_FACE		;colour
			.byte	$15			;posx
			.byte	$0D			;posy
			.byte	$13			;width
			.byte	$01			;height
			.byte	$01			;tag	- checked (default on)
			.word	panel_config_theme	;panel
			.word	text_config_flashchat	;textptr
			.byte	$00			;textoffx
			.byte	$07			;textaccel
			.byte	KEY_ASC_L_H			;accelchar

;	checkbx_config_flashckplyr ("FLASH CHCK PLYR") removed here
;	(2026-08-24) - it was chess-specific, not generic: its only reader
;	was clientCheckFlashIfOurs (flash the border when a check-state
;	broadcast is about ourselves), which is chess-specific and doesn't
;	exist in the framework. Left in during the original extraction
;	because it lived in the same page_config range as the genuinely
;	generic checkbx_config_flashchat, with no "chess" text anywhere in
;	its own name/label to flag it - caught live (2026-08-24) as a
;	config option that didn't do anything. A game wanting an equivalent
;	per-game notification toggle should add its own checkbox (in its
;	own file) rather than reusing this slot.


page_connect:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00 		;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	$0000		;nxtpage
			.word	$0000		;bakpage
			.word	text_page_connect;textptr	.word
			.byte	$10		;textoffx .byte
			.word	page_connect_pnls;panels	.word
			.byte	$03

page_connect_pnls:
			.word	tab_main
			.word	panel_cnct_data
			.word	lpanel_cnct_log
			.word	$0000
			
panel_cnct_data:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_PANEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$09		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_connect
			.word	panel_cnct_data_ctrls	;controls .word
			.byte	$09
			
panel_cnct_data_ctrls:
			.word	label_cnct_host
			.word	edit_cnct_host
			.word	label_cnct_user
			.word	edit_cnct_user
			.word	button_cnct_upd
			.word	button_cnct_cnct
			.word	button_cnct_dcnt
			.word	label_cnct_info
			.word	edit_cnct_info
			.word	$0000

label_cnct_host:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FACE	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$04		;posy	.byte
			.byte	$0B		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	text_cnct_host  ;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$00		;textaccel .byte
			.byte	'h'		;accelchar .byte
			.word	edit_cnct_host	;actvctrl .word
			
edit_cnct_host:
;			.word	$0000		;prepare
			.word	ctrlsEditDefPresent
			.word	$0000		;changed .word
			.word	ctrlsEditDefKeyPress
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_TEXTCONTMRK | OPT_CAPTURECRSR
			.byte	CLR_PAPER	;colour	.byte
			.byte	$0B		;posx	.byte
			.byte	$04		;posy	.byte
			.byte	$1D		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	edit_cnct_host_buf ;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.byte	$0D		;textsiz
			.byte	$3C		;textmaxsz
			

edit_cnct_host_buf:
			.asciiz "192.168.137.1"
	.repeat	48	
			.byte	$00
	.endrep

label_cnct_user:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FACE	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$06		;posy	.byte
			.byte	$0B		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	text_cnct_user  ;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$00		;textaccel .byte
			.byte	'u'		;accelchar .byte
			.word	edit_cnct_user	;actvctrl .word
			
edit_cnct_user:
;			.word	$0000			;prepare
			.word	ctrlsEditDefPresent
			.word	$0000			;changed
			.word	ctrlsEditDefKeyPress
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER		;colour	
			.byte	$0B			;posx	
			.byte	$06			;posy	
			.byte	$09			;width	
			.byte	$01			;height	
			.byte	$00			;tag	
			.word	panel_cnct_data		;panel	
			.word	edit_cnct_user_buf
			.byte	$00			;textoffx 
			.byte	$FF			;textaccel 
			.byte	$00			;accelchar 
			.byte	$00			;textsiz
			.byte	$08			;textmaxsz

edit_cnct_user_buf:
	.repeat	9
			.byte	$00
	.endrep

;	Set once the server has echoed our username back as accepted
;	(clientProcConctMsg's @ident case) - the server only accepts one
;	clientSendUser per connection, so button_cnct_upd gets disabled
;	once this is set.
userNameAccepted:
			.byte	$00


button_cnct_upd:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientCnctUpdChng	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_CONTROL
;	Always visible (looked wrong toggling with the connect state) -
;	enabled once connected, disabled again once the server accepts
;	our username (it only accepts one clientSendUser per connection).
			.byte	STATE_VISIBLE
			.byte	$00		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$06		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	text_cnct_upd	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$02		;textaccel .byte
			.byte	'p'		;accelchar .byte

button_cnct_cnct:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientCnctCnctChng
			.word	$0000		;keypress .word
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$08		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	text_cnct_cnct	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	'c'		;accelchar .byte
			
button_cnct_dcnt:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	clientCnctDCntChng
			.word	$0000		;keypress .word
;			.byte	TYPE_CONTROL
			.byte	$00
			.byte	$00		;options	.byte
			.byte	CLR_FACE	;colour	.byte
			.byte	$1E		;posx	.byte
			.byte	$08		;posy	.byte
			.byte	$0A		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	text_cnct_dcnct	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$01		;textaccel .byte
			.byte	'd'		;accelchar .byte

label_cnct_info:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000		;keypress .word
;			.byte	TYPE_LABEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_PAPER	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$0A		;posy	.byte
			.byte	$0B		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	text_cnct_info  ;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.word	edit_cnct_info	;actvctrl .word


edit_cnct_info:
;			.word	$0000		;prepare
			.word	ctrlsEditDefPresent		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE		;options	.byte
			.byte	CLR_TEXT	;colour	.byte
			.byte	$0B		;posx	.byte
			.byte	$0A		;posy	.byte
			.byte	$1D		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_cnct_data	;panel	.word
			.word	edit_cnct_info_buf ;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.byte	$00			;textsiz
			.byte	$2A			;textmaxsz

edit_cnct_info_buf:
	.repeat	43	
			.byte	$00
	.endrep


lpanel_cnct_log:
;			.word	$0000			;prepare
			.word	ctrlsLPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed 
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_TEXT		;colour	
			.byte	$00			;posx	
			.byte	$0C			;posy	
			.byte	$28			;width	
			.byte	$0D			;height	
			.byte	$00			;tag	
			.word	page_connect
			.word	lpanel_cnct_log_ctrls	;controls
			.byte	$00
			.word	lpanel_cnct_log_lines
			.byte	$0D
			.byte	$00
			.byte	$00			;offsy

lpanel_cnct_log_lines:
			.word	cnct_log_line0
			.word	cnct_log_line1
			.word	cnct_log_line2
			.word	cnct_log_line3
			.word	cnct_log_line4
			.word	cnct_log_line5
			.word	cnct_log_line6
			.word	cnct_log_line7
			.word	cnct_log_line8
			.word	cnct_log_line9
			.word	cnct_log_lineA
			.word	cnct_log_lineB
			.word	cnct_log_lineC

lpanel_cnct_log_ctrls:
			.word	$0000

page_room:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_PAGE
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00 		;options	.byte
			.byte	CLR_TEXT	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	$0000		;nxtpage
			.word	$0000		;bakpage
			.word	text_page_room	;textptr	.word
			.byte	$12		;textoffx .byte
			.word	page_room_pnls	;panels	.word
			.byte	$05

page_room_pnls:
			.word	tab_main
			.word	panel_room_more
			.word	lpanel_room_log
			.word	panel_room_data
			.word 	panel_room_less
			.word	$0000
			
panel_room_less:
;			.word	$0000			;prepare
			.word	ctrlsPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed 
			.word	$0000			;keypress 
;			.byte	TYPE_PANEL
			.byte	$00
			.byte	$00
			.byte	CLR_INSET		;colour	.byte
			.byte	$00			;posx	.byte
			.byte	$03			;posy	.byte
			.byte	$28			;width	.byte
			.byte	$02			;height	.byte
			.byte	$00			;tag	.byte
			.word	page_room
			.word	panel_room_less_ctrls	;controls 
			.byte	$01
			
panel_room_less_ctrls:
			.word	button_room_more
			.word	$0000
			
button_room_more:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientRoomMoreChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_room_less		;panel	.word
			.word	text_room_more		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$08			;textaccel .byte
			.byte	'>'			;accelchar .byte			

panel_room_more:
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
			.byte	$07			;height	.byte
			.byte	$00			;tag	.byte
			.word	page_room
			.word	panel_room_more_ctrls	;controls 
			.byte	$08
			
panel_room_more_ctrls:
			.word	label_room_room
			.word	edit_room_room
			.word	button_room_list
			.word	label_room_pwd
			.word	edit_room_pwd
			.word	button_room_join
			.word	button_room_part
			.word	button_room_less
			.word	$0000

label_room_room:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FACE		;colour	.byte
			.byte	$00			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$0C			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_room_more		;panel	.word
			.word	text_room_room  	;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$00			;textaccel .byte
			.byte	'r'			;accelchar .byte
			.word	edit_room_room		;actvctrl .word

edit_room_room:
;			.word	$0000			;prepare
			.word	ctrlsEditDefPresent
			.word	$0000			;changed .word
			.word	ctrlsEditDefKeyPress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER		;colour	.byte
			.byte	$0C			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$09			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_room_more		;panel	.word
			.word	edit_room_room_buf
			.byte	$00			;textoffx .byte
			.byte	$FF			;textaccel .byte
			.byte	$00			;accelchar .byte
			.byte	$00			;textsiz
			.byte	$08			;textmaxsz

edit_room_room_buf:
	.repeat	9	
			.byte	$00
	.endrep

button_room_list:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientRoomListChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_room_more		;panel	.word
			.word	text_room_list		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$01			;textaccel .byte
			.byte	'l'			;accelchar .byte			

label_room_pwd:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FACE		;colour	
			.byte	$00			;posx	
			.byte	$06			;posy	
			.byte	$0C			;width	
			.byte	$01			;height	
			.byte	$00			;tag	
			.word	panel_room_more		;panel	
			.word	text_room_pwd	  	;textptr
			.byte	$00			;textoffx 
			.byte	$02			;textaccel
			.byte	's'			;accelchar
			.word	edit_room_pwd		;actvctrl 

edit_room_pwd:
;			.word	$0000			;prepare
			.word	ctrlsEditDefPresent
			.word	$0000			;changed .word
			.word	ctrlsEditDefKeyPress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER		;colour	.byte
			.byte	$0C			;posx	.byte
			.byte	$06			;posy	.byte
			.byte	$09			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_room_more		;panel	.word
			.word	edit_room_pwd_buf
			.byte	$00			;textoffx .byte
			.byte	$FF			;textaccel .byte
			.byte	$00			;accelchar .byte
			.byte	$00			;textsiz
			.byte	$08			;textmaxsz

edit_room_pwd_buf:
	.repeat	9	
			.byte	$00
	.endrep

button_room_join:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientRoomJoinChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options
			.byte	CLR_FACE		;colour	
			.byte	$1E			;posx	
			.byte	$06			;posy	
			.byte	$0A			;width	
			.byte	$01			;height	
			.byte	$00			;tag	
			.word	panel_room_more		;panel	
			.word	text_room_join		;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	'j'			;accelchar

button_room_part:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientRoomPartChng
			.word	$0000			;keypress 
			.byte	$00
			.byte	$00			;options
			.byte	CLR_FACE		;colour	
			.byte	$1E			;posx	
			.byte	$06			;posy	
			.byte	$0A			;width	
			.byte	$01			;height	
			.byte	$00			;tag	
			.word	panel_room_more		;panel	
			.word	text_room_part		;textptr
			.byte	$00			;textoffx
			.byte	$01			;textaccel
			.byte	'p'			;accelchar

button_room_less:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientRoomLessChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$08			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_room_more		;panel	.word
			.word	text_room_less		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$08			;textaccel .byte
			.byte	'<'			;accelchar .byte			

lpanel_room_log:
;			.word	$0000			;prepare
			.word	ctrlsLPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed 
			.word	$0000			;keypress 
;			.byte	TYPE_PANEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_TEXT		;colour	
			.byte	$00			;posx	
			.byte	$0A			;posy	
			.byte	$28			;width	
			.byte	$0D			;height	
			.byte	$00			;tag	
			.word	page_room
			.word	panel_room_log_ctrls	;controls 
			.byte	$00
			.word	lpanel_room_log_lines
			.byte	$11
			.byte	$10
			.byte	$04			;offsy

lpanel_room_log_lines:
			.word	room_log_line0
			.word	room_log_line1
			.word	room_log_line2
			.word	room_log_line3
			.word	room_log_line4
			.word	room_log_line5
			.word	room_log_line6
			.word	room_log_line7
			.word	room_log_line8
			.word	room_log_line9
			.word	room_log_lineA
			.word	room_log_lineB
			.word	room_log_lineC
			.word	room_log_lineD
			.word	room_log_lineE
			.word	room_log_lineF
			.word	room_log_line10

panel_room_log_ctrls:
			.word	$0000

panel_room_data:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
;			.byte	TYPE_PANEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$17		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$02		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_room
			.word	panel_room_data_ctrls	;controls .word
			.byte	$01

panel_room_data_ctrls:
			.word	edit_room_text
			.word	$0000

edit_room_text:
;			.word	$0000			;prepare
			.word	ctrlsEditDefPresent
			.word	ctrlsRoomTextChng	;changed
			.word	ctrlsEditDefKeyPress
;			.byte	TYPE_CONTROL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER		;colour	
			.byte	$00			;posx	
			.byte	$18			;posy	
			.byte	$28			;width	
			.byte	$01			;height	
			.byte	$00			;tag	
			.word	panel_room_data		;panel	
			.word	edit_room_text_buf	;textptr	
			.byte	$00			;textoffx 
			.byte	$FF			;textaccel
			.byte	$00			;accelchar
			.byte	$00			;textsiz
			.byte	$28			;textmaxsz
			
edit_room_text_buf:
	.repeat	41
			.byte	$00
	.endrep


page_play:
;			.word	$0000		;prepare
			.word	$0000		;present	.word
			.word	$0000		;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00 		;options	.byte
			.byte	CLR_TEXT	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$03		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$16		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_ovrvw	;nxtpage
			.word	$0000		;bakpage
			.word	text_page_play	;textptr	.word
			.byte	$12		;textoffx .byte
			.word	page_play_pnls	;panels	.word
			.byte	$05

page_play_pnls:
			.word	tab_main
			.word	panel_play_more
			.word	lpanel_play_log
			.word	panel_play_data
			.word 	panel_play_less
			.word	$0000
			
panel_play_less:
;			.word	$0000			;prepare
			.word	ctrlsPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed 
			.word	$0000			;keypress 
			.byte	$00
			.byte	$00
			.byte	CLR_INSET		;colour	.byte
			.byte	$00			;posx	.byte
			.byte	$03			;posy	.byte
			.byte	$28			;width	.byte
			.byte	$02			;height	.byte
			.byte	$00			;tag	.byte
			.word	page_play
			.word	panel_play_less_ctrls	;controls 
			.byte	$01
			
panel_play_less_ctrls:
			.word	button_play_more
			.word	$0000
			
button_play_more:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientPlayMoreChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_less		;panel	.word
			.word	text_room_more		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$08			;textaccel .byte
			.byte	'>'			;accelchar .byte			

panel_play_more:
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
			.byte	$07			;height	.byte
			.byte	$00			;tag	.byte
			.word	page_play
			.word	panel_play_more_ctrls	;controls 
			.byte	$08
			
panel_play_more_ctrls:
			.word	label_play_game
			.word	edit_play_game
			.word	button_play_list
			.word	label_play_pwd
			.word	edit_play_pwd
			.word	button_play_join
			.word	button_play_part
			.word	button_play_less
			.word	$0000

label_play_game:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FACE		;colour	.byte
			.byte	$00			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$0C			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	text_play_game  	;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$00			;textaccel .byte
			.byte	'g'			;accelchar .byte
			.word	edit_play_game		;actvctrl .word

edit_play_game:
;			.word	$0000			;prepare
			.word	ctrlsEditDefPresent
			.word	$0000			;changed .word
			.word	ctrlsEditDefKeyPress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER		;colour	.byte
			.byte	$0C			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$09			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	edit_play_game_buf
			.byte	$00			;textoffx .byte
			.byte	$FF			;textaccel .byte
			.byte	$00			;accelchar .byte
			.byte	$00			;textsiz
			.byte	$08			;textmaxsz

edit_play_game_buf:
	.repeat	9	
			.byte	$00
	.endrep

button_play_list:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	clientPlayListChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$04			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	text_room_list		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$01			;textaccel .byte
			.byte	'l'			;accelchar .byte			

label_play_pwd:
;			.word	$0000			;prepare
			.word	$0000			;present
			.word	ctrlsLabelDefChanged	;changed
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_FACE		;colour	
			.byte	$00			;posx	
			.byte	$06			;posy	
			.byte	$0C			;width	
			.byte	$01			;height	
			.byte	$00			;tag	
			.word	panel_play_more		;panel	
			.word	text_room_pwd	  	;textptr
			.byte	$00			;textoffx 
			.byte	$02			;textaccel
			.byte	's'			;accelchar
			.word	edit_play_pwd		;actvctrl 

edit_play_pwd:
;			.word	$0000			;prepare
			.word	ctrlsEditDefPresent
			.word	$0000			;changed .word
			.word	ctrlsEditDefKeyPress
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER		;colour	.byte
			.byte	$0C			;posx	.byte
			.byte	$06			;posy	.byte
			.byte	$09			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	edit_play_pwd_buf
			.byte	$00			;textoffx .byte
			.byte	$FF			;textaccel .byte
			.byte	$00			;accelchar .byte
			.byte	$00			;textsiz
			.byte	$08			;textmaxsz

edit_play_pwd_buf:
	.repeat	9	
			.byte	$00
	.endrep

button_play_join:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientPlayJoinChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$06			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	text_room_join		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$01			;textaccel .byte
			.byte	'j'			;accelchar .byte			

button_play_part:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientPlayPartChng
			.word	$0000			;keypress 
			.byte	$00
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$06			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	text_room_part		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$01			;textaccel .byte
			.byte	'p'			;accelchar .byte

button_play_less:
;			.word	$0000			;prepare
			.word	$0000			;present	
			.word	clientPlayLessChng
			.word	$0000			;keypress 
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00			;options	.byte
			.byte	CLR_FACE		;colour	.byte
			.byte	$1E			;posx	.byte
			.byte	$08			;posy	.byte
			.byte	$0A			;width	.byte
			.byte	$01			;height	.byte
			.byte	$00			;tag	.byte
			.word	panel_play_more		;panel	.word
			.word	text_room_less		;textptr	.word
			.byte	$00			;textoffx .byte
			.byte	$08			;textaccel .byte
			.byte	'<'			;accelchar .byte			

lpanel_play_log:
;			.word	$0000			;prepare
			.word	ctrlsLPanelDefPresent	;present
			.word	ctrlsPanelDefChanged	;changed
			.word	$0000			;keypress
;			.byte	TYPE_PANEL
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_NONAVIGATE
			.byte	CLR_TEXT	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$0A		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$0D		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_play
			.word	panel_play_log_ctrls	;controls .word
			.byte	$00
			.word	lpanel_play_log_lines
			.byte	$11
			.byte	$10
			.byte	$04			;offsy

lpanel_play_log_lines:
			.word	play_log_line0
			.word	play_log_line1
			.word	play_log_line2
			.word	play_log_line3
			.word	play_log_line4
			.word	play_log_line5
			.word	play_log_line6
			.word	play_log_line7
			.word	play_log_line8
			.word	play_log_line9
			.word	play_log_lineA
			.word	play_log_lineB
			.word	play_log_lineC
			.word	play_log_lineD
			.word	play_log_lineE
			.word	play_log_lineF
			.word	play_log_line10

panel_play_log_ctrls:
			.word	$0000

panel_play_data:
;			.word	$0000		;prepare
			.word	ctrlsPanelDefPresent	;present	.word
			.word	ctrlsPanelDefChanged	;changed .word
			.word	$0000		;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	$00	 	;options	.byte
			.byte	CLR_INSET	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$17		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$02		;height	.byte
			.byte	$00		;tag	.byte
			.word	page_play
			.word	panel_play_data_ctrls	;controls .word
			.byte	$01

panel_play_data_ctrls:
			.word	edit_play_text
			.word	$0000

;	Wired up as the default in-game chat control (2026-08-24) - chess's
;	original left this unwired (empty textptr, no present/changed/
;	keypress handlers) since it built its own page_detail-specific chat
;	box instead, which only made sense for a 2-player game. Games with
;	spectators should route chat through here instead (see
;	clientPlayTextChng/clientSendGameChat below), matching how room
;	chat already works via edit_room_text/ctrlsRoomTextChng.
edit_play_text:
;			.word	$0000		;prepare
			.word	ctrlsEditDefPresent	;present	.word
			.word	clientPlayTextChng	;changed .word
			.word	ctrlsEditDefKeyPress	;keypress .word
			.byte	STATE_VISIBLE | STATE_ENABLED
			.byte	OPT_DOWNCAPTURE | OPT_CAPTURECRSR
			.byte	CLR_PAPER	;colour	.byte
			.byte	$00		;posx	.byte
			.byte	$18		;posy	.byte
			.byte	$28		;width	.byte
			.byte	$01		;height	.byte
			.byte	$00		;tag	.byte
			.word	panel_play_data	;panel	.word
			.word	edit_play_text_buf	;textptr	.word
			.byte	$00		;textoffx .byte
			.byte	$FF		;textaccel .byte
			.byte	$00		;accelchar .byte
			.byte	$00		;textsiz
			.byte	$28		;textmaxsz

edit_play_text_buf:
	.repeat	41
			.byte	$00
	.endrep


