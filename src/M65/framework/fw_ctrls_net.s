;===============================================================================
; fw_ctrls_net.s - FRAMEWORK (reusable across games)
;
; The ctrls widget engine implementation (ctrlsLockAcquire through
; ctrlsControlDefPresent), the generic networking/protocol layer
; (inet*/tcp/dns/dhcp glue, clientSend*/clientProc* for Sys/Text/Room/
; Connect/Client/Server messages and the generic mcPlay join/part/list/
; chat envelope), and shared screen/string utilities (screen*/strs*/
; dma*/msgsPush*). This is the single largest and most interleaved
; section of the original chess.s - see split_framework.py (scratchpad,
; not checked in) for the full per-label classification this was built
; from, in case a symbol needs re-auditing later.
;
; Extracted from M3wPChess's chess.s during the Snake Challenge QUADRO
; port (2026-08-24). See fw_core.s for the wider extraction note.
;===============================================================================

main:
;-------------------------------------------------------------------------------
		LDA	#$00
		JSR	colourSchemeSelect
		
		LDA	#<page_splsh
		STA	elemptr0
		LDA	#>page_splsh
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect

	
@loop:						
		CLI
						;This is where we do our timer
	.if	DEBUG_RASTERTIME		;	check for TCP keep alives
		LDA	#$06			;	and any message data sends
		STA	vicBrdrClr
	.endif

		LDA	inetproc
		CMP	#INET_PROC_INIT
		BEQ	@inetinit

		CMP	#INET_PROC_IDLE
		BNE	@tstnxt0

@idle:
		JSR	inetIdle
		JMP	@lock

@tstnxt0:
		CMP	#INET_PROC_HALT
		BEQ	@idle

		CMP	#INET_PROC_CNCT
		BEQ	@connect

		CMP	#INET_PROC_PCNT
		BNE	@tstnxt1

		LDA	#INET_PROC_CNCT
		STA	inetproc
		JMP	@lock
		
@tstnxt1:
		CMP	#INET_PROC_EXEC
		BNE	@tstnxt2

		JSR	inetExecute
		JMP	@lock

@tstnxt2:
		CMP	#INET_PROC_DISC
		BNE	@tstnxt3

		JSR	inetDisconnect
		JMP	@lock

@tstnxt3:
		CMP	#INET_PROC_DSCD
		BNE	@tstnxt4

		JSR	inetDisconnected
		JMP	@lock

@tstnxt4:
		JMP	@lock

@connect:
		JSR	userCursorPushBusy
		JSR	inetConnect
		JSR	userCursorPopBusy
		JMP	@lock

@inetinit:
		JSR	inetInitialise
		JSR	userCursorPopBusy


@lock:						;We need to lock here for reads...
		SEI
		LDA	ctrlsLock		;If already locked (eeii!) then skip
		BNE	@loop
		
		CLI
		JSR	ctrlsLockAcquire


	.if	DEBUG_RASTERTIME
		LDA	#$02
		STA	vicBrdrClr
	.endif

@prepare:					;Normal control life cycle starts
		LDA	ctrlsPrep
		BEQ	@changed

		JSR	ctrlsDisposeMsgs	;I don't think that the total time
						;	for reads and control life
		JSR	ctrlsPagePrepare	;	will cause problems for TCP
						;	keep alives.  If it does, 
		LDA	#$00			;	need to do one or other, 
		STA	ctrlsPrep		;	reads or ctrl updates.
		STA	ctrlsLChg

		JMP	@next

@changed:
		LDA	msgs_change_idx
		BEQ	@present

		LDA	ctrlsLChg
		BNE	@present

		JSR	ctrlsPageChanged

		LDA	#$01
		STA	ctrlsLChg

		JMP	@next

@present:
		LDA	#$00
		STA	ctrlsLChg

		LDA	msgs_dirty_idx
		BEQ	@keys

		JSR	ctrlsPagePresent

;		JMP	@next

@keys:
		JSR	userReadKey
		BEQ	@next

		JSR	ctrlsPageKeyPress

@next:
	.if	DEBUG_RASTERTIME
		LDA	#$0E
		STA	vicBrdrClr
	.endif

@unlock:					;Unlock here...
		JSR	ctrlsLockRelease

		JMP	@loop

		RTS


;-------------------------------------------------------------------------------
mainPanic:
;-------------------------------------------------------------------------------
		JMP	mainPanic


eth_init_value:
			.byte eth_init_default


;-------------------------------------------------------------------------------
inetInitialise:
;-------------------------------------------------------------------------------
		LDA	#INET_PROC_HALT
		STA	inetproc

		LDA	#INET_STATE_ERR
		STA	inetstat

		LDA	#INET_ERR_INTRF
		STA	ineterrk
		LDA	#INET_ERROR_INIT
		STA	ineterrc

;		LDA 	#$00
;		JSR 	drv_init

		LDA	eth_init_value
		JSR 	ip65_init
		BCC	:+

		JSR	clientOutputInetError
		RTS

:
		JSR 	dhcp_init
		BCC 	:+

		LDA	#INET_ERR_INTRN
		STA	ineterrk
		LDA	ip65_error
		STA	ineterrc
		
		JSR	clientOutputInetError
		RTS

:
		LDA	#INET_PROC_IDLE
		STA	inetproc

		LDA	#INET_STATE_NORM
		STA	inetstat

		LDA	#INET_ERR_NONE
		STA	ineterrk
		LDA	#INET_ERROR_NONE
		STA	ineterrc


		JSR	clientOutputInetConfig

		RTS


;-------------------------------------------------------------------------------
inetIdle:
;-------------------------------------------------------------------------------
;	This is a whole lot of nothing to do - sleep
;	Can probably be stubbed out once things are settled
	.if	DEBUG_INETDOSLEEP
		LDX	$7F
@sleep0:
		LDY	#$FF
@sleep1:
		DEY
		BNE	@sleep1
		DEX
		BPL	@sleep0
	.endif

		RTS

	
	.export	inetConnect
;-------------------------------------------------------------------------------
inetConnect:
;-------------------------------------------------------------------------------
		LDA	#INET_PROC_HALT
		STA	inetproc

		LDA	#INET_STATE_ERR
		STA	inetstat

		LDA	#INET_ERR_INTRF
		STA	ineterrk
		LDA	#INET_ERROR_CNCT
		STA	ineterrc

		LDAX 	#edit_cnct_host_buf
		JSR 	dns_set_hostname

		BCC 	:+

;	ip65_error is dead (never written anywhere), so it was always $00
;	here regardless of which of the 3 stages below actually failed -
;	every connect failure looked identical. Each stage now sets
;	ineterrc to its own code before jumping here instead.
		LDA	#$01
		STA	ineterrc
		JMP	@haveerror

@haveerror:
		LDA	#INET_ERR_INTRN
		STA	ineterrk

		JSR	clientOutputInetError
		RTS

; 	resolve host name
:
		LDA 	dns_hostname_is_dotted_quad
		BNE 	:+

		JSR 	dns_resolve
		BCC 	:+

		LDA	#$02
		STA	ineterrc
		JMP	@haveerror

:
		LDAX 	#19763
		STAX 	inet_port

; 	connect
		LDAX 	#inet_callback
		STAX 	tcp_callback

		LDX 	#3
:
		LDA 	dns_ip, X
		STA 	tcp_connect_ip, X

		DEX
		BPL 	:-

		LDAX 	inet_port
		JSR 	tcp_connect
		BCC 	:+

		LDA	#$03
		LDX	TCP_CONNECT_FAIL_WAS_RST
		BEQ 	@tcpfail_chk_synack
		LDA	#$05		;peer actively refused (RST) rather than a plain timeout
		JMP	@tcpfail_have_code
@tcpfail_chk_synack:
		LDX	TCP_CONNECT_FAIL_BAD_SYNACK
		BEQ 	@tcpfail_have_code
		LDA	#$06		;a SYN+ACK arrived but got dropped (ACK mismatch)
@tcpfail_have_code:
		STA	ineterrc
		JMP	@haveerror

; 	connected
: 
		LDA 	#0
		STA 	connection_close_requested
		STA 	connection_closed
		STA 	data_received

		STA	readmsglen
  
;		LDA 	#abort_key_disable
;		STA 	abort_key

		LDA	#INET_PROC_EXEC
		STA	inetproc

		LDA	#INET_STATE_NORM
		STA	inetstat

		LDA	#INET_ERR_NONE
		STA	ineterrk
		LDA	#INET_ERROR_NONE
		STA	ineterrc
		
		JSR	clientOutputInetError

		JSR	ctrlsLockAcquire

		LDA	#<button_cnct_cnct
		STA	elemptr0
		LDA	#>button_cnct_cnct
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		LDA	#<button_cnct_dcnt
		STA	elemptr0
		LDA	#>button_cnct_dcnt
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

		LDA	#<button_cnct_cnct
		CMP	actvCtrl
		BNE	@pick

		LDA	#>button_cnct_cnct
		CMP	actvCtrl + 1
		BNE	@pick

		JSR	ctrlsActivateCtrl

@pick:
		LDA	#<button_cnct_cnct
		CMP	pickCtrl
		BNE	@exit

		LDA	#>button_cnct_cnct
		CMP	pickCtrl + 1
		BNE	@exit

		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1

@exit:
		LDA	#$00
		STA	userNameAccepted

		LDA	#<button_cnct_upd
		STA	elemptr0
		LDA	#>button_cnct_upd
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

		JSR	ctrlsLockRelease

		RTS


;-------------------------------------------------------------------------------
inetDisconnect:
;-------------------------------------------------------------------------------
;	tcp_close only sends the FIN; the retry/ack handshake behind it is
;	driven entirely by continued ETH_STATUS_POLL calls, which we stop
;	making the instant inetproc leaves INET_PROC_EXEC. Wait here (with
;	the busy cursor up) until the close actually completes or a
;	generous timeout elapses, instead of abandoning it mid-handshake.
		JSR	userCursorPushBusy

		JSR 	tcp_close

		LDA	#<DISCONNECT_TIMEOUT_FRAMES
		STA	TIMEOUT_LO
		LDA	#>DISCONNECT_TIMEOUT_FRAMES
		STA	TIMEOUT_HI
		JSR	RESET_TIMEOUT_FRAME

@wait:
		LDA	#$00
		STA	TERMINAL_EVENT

		JSR	TERMINAL_POLL_STATUS

		LDA	TERMINAL_EVENT
		BNE	@waitdone		;server acked the close (or reset)

		JSR	DEC_TIMEOUT_FRAME
		BCC	@wait			;still within budget, keep polling

@waitdone:
		JSR	userCursorPopBusy

		LDA	#INET_PROC_DSCD
		STA	inetproc

		LDA	#INET_STATE_NORM
		STA	inetstat

		LDA	#INET_ERR_NONE
		STA	ineterrk

		LDA	#INET_ERROR_NONE
		STA	ineterrc

		RTS


;-------------------------------------------------------------------------------
inetDisconnected:
;-------------------------------------------------------------------------------
		LDA	#INET_PROC_IDLE
		STA	inetproc

		LDA	#INET_STATE_NORM
		STA	inetstat

		LDA	#INET_ERR_INTRF
		STA	ineterrk

		LDA	#INET_ERROR_DISC
		STA	ineterrc

		JSR	clientOutputInetError

		JSR	ctrlsLockAcquire

		LDA	#<button_cnct_dcnt
		STA	elemptr0
		LDA	#>button_cnct_dcnt
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		LDA	#<button_cnct_cnct
		STA	elemptr0
		LDA	#>button_cnct_cnct
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

		LDA	#<button_cnct_dcnt
		CMP	actvCtrl
		BNE	@pick

		LDA	#>button_cnct_dcnt
		CMP	actvCtrl + 1
		BNE	@pick

		JSR	ctrlsActivateCtrl

@pick:
		LDA	#<button_cnct_dcnt
		CMP	pickCtrl
		BNE	@done

		LDA	#>button_cnct_dcnt
		CMP	pickCtrl + 1
		BNE	@done

		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1

@done:
		LDA	#<button_cnct_upd
		STA	elemptr0
		LDA	#>button_cnct_upd
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

;	GAME HOOK: gameResetPlayGame - also drop back out of any game we
;	were sitting in on disconnect (button states and any per-game
;	"which slot am I" tracking would otherwise be left stale on the
;	next connect). Entirely game-defined, including resetting its own
;	slot-tracking var(s) - chess's original reset ourSlot to $FF here
;	before calling its own equivalent (clientResetPlayGame), since that
;	used ourSlot (via clientOvrvwClrSetAuthority) to decide whether the
;	colour-pick checkboxes should stay enabled.
		JSR	gameResetPlayGame

@exit:
		LDA	#$00
		STA	sendmsgscnt
		STA	readbufidx
		STA	readmsglen

		JSR	ctrlsLockRelease

		RTS


;-------------------------------------------------------------------------------
inetExecute:
;-------------------------------------------------------------------------------
;		LDA	inetstat
;		CMP	#INET_STATE_TICK
;		BEQ	@check_timeout
;
;		JSR 	timer_read
;		
;		TXA                           ; 1/1000 * 256 = ~ 1/4 seconds
;		ADC 	#$20                  ; 32 x 1/4 = ~ 8 seconds
;		
;		STA 	inet_timeout
;
;		LDA	#INET_STATE_TICK
;		STA	inetstat
;		
;@check_timeout:
;		LDA 	data_received
;		BNE 	:+
; 
;		JSR 	timer_read
;		CPX 	inet_timeout		
;		BNE 	:+			;	should sleep?
; 
;		JSR 	tcp_send_keep_alive
;		
;		LDA	#INET_STATE_NORM
;		STA	inetstat
;		RTS
;		
;: 
		LDA 	#0
		STA 	data_received
		JSR 	ip65_process
		
		LDA 	connection_close_requested
		BEQ 	@tstclosed
		
		LDA	#INET_PROC_DISC
		STA	inetproc


		LDA	#INET_STATE_NORM
		STA	inetstat

		LDA	#INET_ERR_NONE
		STA	ineterrk

		LDA	#INET_ERROR_NONE
		STA	ineterrc

		JMP 	@done
		
@tstclosed: 
		LDA 	connection_closed
		BNE 	@closed
		
		LDA	sendmsgscnt
		BNE	@send

		JMP	@done

		
@send:
		JSR	inetSendData
		JMP	@done

@closed:
;		LDA 	#abort_key_default
;		STA 	abort_key
		
		LDA	#INET_PROC_DSCD
		STA	inetproc

		LDA	#INET_STATE_NORM
		STA	inetstat

		LDA	#INET_ERR_NONE
		STA	ineterrk
		LDA	#INET_ERROR_NONE
		STA	ineterrc
	
@done:	
		
		RTS


;-------------------------------------------------------------------------------
sendmsgtable:
		.word	sendmsg0
		.word	sendmsg1
		.word	sendmsg2
		.word	sendmsg3
		.word	sendmsg4
		.word	sendmsg5


;-------------------------------------------------------------------------------
inetGetNextSend:
;-------------------------------------------------------------------------------
		LDA	inetproc
		CMP	#INET_PROC_EXEC
		BNE	@fail
				
		LDY	sendmsgscnt

;	.if	DEBUG_MSGSPUSHSZ
		CPY	#$0C
		BNE	@cont
		
@fail:
;		LDA	#$02
;		STA	vicBrdrClr
;		LDA	#$05
;		STA	vicBkgdClr
;		
;		JMP	mainPanic

		CLC
		RTS

@cont:
;	.endif

		LDA	sendmsgtable, Y
		STA	tempptr0
		INY
		LDA	sendmsgtable, Y
		STA	tempptr0 + 1
		INY

		STY	sendmsgscnt

		LDA	#$01
		STA	tempdat0

		SEC
		RTS


	.export	inetSendData
;-------------------------------------------------------------------------------
inetSendData:
;-------------------------------------------------------------------------------
		LDY	#$00
		STY	senddat0

@loop:
		LDA	sendmsgtable, Y
		STA	sendptr0
		INY
		LDA	sendmsgtable, Y
		STA	sendptr0 + 1
		INY
		
		STY	senddat0

		LDY	#$00
		LDA	(sendptr0), Y

		STA	tcp_send_data_len
		INC	tcp_send_data_len

		LDA	#$00
		STA	tcp_send_data_len + 1

		LDA	sendptr0
		LDX	sendptr0 + 1
		JSR tcp_send
		BCS @error

		JSR	inetWaitTxIdle

		JSR	clientDispInetHealth

		LDY	senddat0
		CPY	sendmsgscnt
		BNE	@loop

		JMP	@exit


@error:
		LDA 	ip65_error
		CMP 	#IP65_ERROR_CONNECTION_CLOSED
		BNE 	@errother

		JSR	inetRecordDiscEvent

		LDA 	#1
		STA 	connection_closed

		JMP	@exit

@errother:
		LDA	#INET_PROC_HALT
		STA	inetproc

		LDA	#INET_STATE_ERR
		STA	inetstat

		LDA	#INET_ERR_INTRN
		STA	ineterrk

		LDA	ip65_error
		STA	ineterrc
		
		JSR	clientOutputInetError

@exit:
		LDA	#$00
		STA	sendmsgscnt

		RTS


;-------------------------------------------------------------------------------
; The mega-ip TCP stack is stop-and-wait (one unacked segment in flight at a
; time); anything enqueued while a segment is outstanding just sits in the TX
; queue until a later poll notices the ACK. Block here until that queue has
; actually drained before letting the caller enqueue the next message, so
; back-to-back sends don't pile up unsent (or get silently coalesced together
; whenever the queue finally does flush).
;-------------------------------------------------------------------------------
;	Stashes TERMINAL_EVENT (TCP_EVENT_FLAG's sticky-OR'd EV_* bits, see
;	the mirrored defines near tcp_connect) into discEventFlags, so
;	clientOutputInetError can show *why* a connection ended instead of
;	just that it did. Call right before setting connection_closed - not
;	after, since some callers (tcp_send, tcp_send_keep_alive,
;	ETH_PROCESS_DEFERRED) reset TERMINAL_EVENT again on their own next
;	poll.
;-------------------------------------------------------------------------------
inetRecordDiscEvent:
;-------------------------------------------------------------------------------
		LDA	TERMINAL_EVENT
		STA	discEventFlags

		RTS


;-------------------------------------------------------------------------------
inetWaitTxIdle:
;-------------------------------------------------------------------------------
		LDA	#$00
		STA	TERMINAL_EVENT

		JSR	TERMINAL_POLL_STATUS

		LDA	TERMINAL_EVENT
		BNE	@closed

		JSR	MIP_TCP_TX_IDLE
		CMP	#$01
		BNE	inetWaitTxIdle

		RTS

@closed:
		JSR	inetRecordDiscEvent

		LDA	#$01
		STA	connection_close_requested
		STA	connection_closed

		RTS




	.export	inet_callback
;-------------------------------------------------------------------------------
inet_callback:
;-------------------------------------------------------------------------------
	.if	DEBUG_RASTERTIME
		LDA	vicBrdrClr
		PHA

		LDA	#$07
		STA	vicBrdrClr
	.endif

		LDA 	#1
		LDX 	tcp_inbound_data_length + 1
		CPX 	#$FF
		BNE 	@begin

;	Not a TCP_EVENT_FLAG signal - this is MIP_ML_RECV_BYTE's own
;	inbound-EOF sentinel, so there's nothing meaningful to show beyond
;	"unknown" ($00 - see discEventFlags).
		LDX	#$00
		STX	discEventFlags

		STA 	connection_closed
		JMP	@exit
		
@begin:
		STA 	data_received

		LDA 	tcp_inbound_data_length
		STAX	readmsgbuflen

		LDAX 	tcp_inbound_data_ptr
		STAX 	inetread

		LDY	#$00
		STY	readbufidx

		LDA	readmsglen
		BNE	@readmsg

@newmsg:
		LDY	#$00
		LDA	(inetread), Y
		STA	readmsg0, Y
		INY

		STY	readbufidx
		STY	readmsgidx

		TAY
		INY
		STY	readmsglen

		SEC	
		LDA	readmsgbuflen
		SBC	#$01
		STA	readmsgbuflen
		LDA	readmsgbuflen + 1
		SBC	#$00
		STA	readmsgbuflen + 1

		LDA	readmsgbuflen
		BNE	@readmsg
		LDA	readmsgbuflen + 1
		BEQ	@exit

@readmsg:
		LDY	readbufidx
		LDA	(inetread), Y
		INY
		STY	readbufidx

		LDY	readmsgidx
		STA	readmsg0, Y
		INY
		STY	readmsgidx

		SEC	
		LDA	readmsgbuflen
		SBC	#$01
		STA	readmsgbuflen
		LDA	readmsgbuflen + 1
		SBC	#$00
		STA	readmsgbuflen + 1

		LDY	readmsgidx
		CPY	readmsglen
		BNE	@tstbreak

		JSR	clientHandleReadMsg

;	Advance by readbufidx (bytes of THIS batch actually consumed),
;	not readmsglen (the message's full size) - they're only the same
;	when a message is entirely contained in one batch. For a message
;	that started in a PREVIOUS batch and only finishes here, inetread
;	was reset to this batch's own base (not the message's true start),
;	so advancing by the full message size overshoots by however many
;	bytes came from the earlier batch, landing partway into the next
;	message and desyncing everything after it in this batch.
		CLC
		LDA	inetread
		ADC	readbufidx
		STA	inetread
		LDA	inetread + 1
		ADC	#$00
		STA	inetread + 1

		LDA	#$00
		STA	readbufidx
		STA	readmsglen

@tstbreak:
		LDA	readmsgbuflen
		BNE	@tstnext
		LDA	readmsgbuflen + 1
		BEQ	@exit

@tstnext:
		LDA	readbufidx
		BNE	@cont
		
		JMP	@newmsg
		
@cont:
		JMP	@readmsg

@exit:
	.if	DEBUG_RASTERTIME
		PLA
		STA	vicBrdrClr
	.endif

		RTS


;-------------------------------------------------------------------------------
inetScanReadParams:
;-------------------------------------------------------------------------------
		LDX	#$00
		STX	readparmcnt
		
		LDA	readmsg0
		TAY
		INY
		STY	tempvar_z
		
		CPY	#$02
		BNE	@proc
		
		RTS
		
@proc:
		LDY	#$02

@mark:
		TYA
		STA	readparm0, X
		INX
		
		STX	readparmcnt
		
		CPX	#$03
		BNE	@loop
		
		RTS

@loop:
		CPY	tempvar_z
		BNE	@cont
		
		RTS
		
@cont:
		LDA	readmsg0, Y
		
		INY
		
		CMP	#KEY_ASC_SPACE
		BNE	@loop
		
		JMP	@mark
	

	.export	clientNotifyFail
;-------------------------------------------------------------------------------
clientNotifyFail:
;-------------------------------------------------------------------------------
		SEI
		LDA	#$06
		STA	uiflshcnt
		
		LDA	#$08
		STA	uiflshdly
		
		LDA	current_clrs
		STA	vicBrdrClr

		CLI

		RTS


	.export	roomLogNotifyUpdate
;-------------------------------------------------------------------------------
;	Drop-in replacement for ctrlsLogPanelUpdate - identical for any
;	other panel, but if tempptr2 is the room/chat log and the Room
;	page isn't the active one (pageptr0), counts the update and
;	flashes the border every 5th one so an idle player notices new
;	chat. Counter resets whenever an update lands while the page IS
;	active, so counting restarts fresh after the player's caught up.
roomLogNotifyUpdate:
;-------------------------------------------------------------------------------
		JSR	ctrlsLogPanelUpdate

		LDA	tempptr2
		CMP	#<lpanel_room_log
		BNE	@exit
		LDA	tempptr2 + 1
		CMP	#>lpanel_room_log
		BNE	@exit

		LDA	checkbx_config_flashchat + ELEMENT::tag
		BEQ	@exit

		LDA	pageptr0
		CMP	#<page_room
		BNE	@away
		LDA	pageptr0 + 1
		CMP	#>page_room
		BNE	@away

;	Pinned at 4 (not 0) while visible, so the first message after
;	leaving the room page hits 5 and flashes right away, rather than
;	needing 5 to accumulate first - @away's own reset-to-0 after a
;	flash still makes it every 5 after that.
		LDA	#$04
		STA	room_log_notify_cnt

@exit:
		RTS

@away:
		INC	room_log_notify_cnt
		LDA	room_log_notify_cnt
		CMP	#$05
		BCC	@exit

		LDA	#$00
		STA	room_log_notify_cnt

		SEI
		LDA	#$06
		STA	uiflshcnt
		LDA	#$08
		STA	uiflshdly
		LDA	current_clrs
		STA	vicBrdrClr
		CLI

		RTS

;-------------------------------------------------------------------------------
clientDispInetHealth:
;-------------------------------------------------------------------------------
		LDA	inetproc
		CMP	#INET_PROC_EXEC
		LBNE	@exit

;	Temporary diagnostic: log inet_last_rtt/inet_last_retries to the
;	connect log panel whenever either one actually changes, so we can
;	see the raw numbers behind the bar instead of guessing.
;	Disabled for now - remove this BRA to bring it back.
		BRA	@dbgdone

		LDA	inet_last_rtt
		CMP	dbg_last_rtt_logged
		BNE	@dbglog
		LDA	inet_last_retries
		CMP	dbg_last_retries_logged
		BEQ	@dbgdone

@dbglog:
		LDA	inet_last_rtt
		STA	dbg_last_rtt_logged
		LDA	inet_last_retries
		STA	dbg_last_retries_logged

		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_debug_rtt
		JSR	strsAppendString

		LDA	inet_last_rtt
		LDX	#$00
		JSR	strsAppendHex

		LDAX	#text_debug_retry
		JSR	strsAppendString

		LDA	inet_last_retries
		LDX	#$00
		JSR	strsAppendHex

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate

@dbgdone:
;	healthbars/healthclrs run best(0) to worst(8); inet_last_rtt is in
;	~20ms frame-ticks. With the keepalive-reply/Nagle fixes, steady-state
;	is now ~18 ticks (~360ms), so >>3 spreads a ~0-1.3s range across the
;	bar (18 ticks lands around index 2, still green) instead of pinning
;	every normal reading at worst.
		LDA	inet_last_rtt
		LSR
		LSR
		;LSR

		CMP	#$12
		BCC	:+
		LDA	#$12
:
    PHA
		ASL
    TAX

;	Fixed at row 0 (both screen and colour tables below are read
;	unindexed) - the two health-bar cells are columns 39/79, the
;	latter deliberately overflowing into row 1's column 39 (see
;	screenRowsLo/screenRowsHi: rows are laid out back to back, so row
;	0's pointer plus one row's worth of offset lands in row 1).
		LDA	screenRowsLo
		STA	tempptr1
		LDA	screenRowsHi
		STA	tempptr1 + 1
		LDA	#$01			;bank - screen RAM is at $010000
		STA	tempptr1 + 2
		LDA	#$00			;top
		STA	tempptr1 + 3

    LDA flag_custom_font
    BEQ @petscii

		LDA	healthbars_xirod, X
		STCELL16 tempptr1, #$27
    INX
		LDA	healthbars_xirod, X
		STCELL16 tempptr1, #$4F

    BRA @colour

@petscii:
		LDA	healthbars_c64, X
		STCELL16 tempptr1, #$27
    INX
		LDA	healthbars_c64, X
		STCELL16 tempptr1, #$4F

@colour:
		LDA	colourRowsHiPhys	;bank/top unchanged - same bank $01
		STA	tempptr1 + 1		;	as the screen write above

    PLX
		LDA	healthclrs, X
		STCOLR16 tempptr1, #$27
		LDA	healthclrs, X
		STCOLR16 tempptr1, #$4F

@exit:
		RTS


;-------------------------------------------------------------------------------
clientMsgProcs:
			.word	clientProcSysMsg
			.word	clientProcTextMsg
			.word	clientProcLobbyMsg
			.word	clientProcConctMsg
			.word	clientProcClientMsg
			.word	clientProcServerMsg
			.word	clientProcPlayMsg

;-------------------------------------------------------------------------------
clientProcUnknownMsg:
;-------------------------------------------------------------------------------
		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_trace_unkmsg
		JSR	strsAppendString
		
		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar
		
		LDA	readmsg0 + 1
		LDX	#$00
		JSR	strsAppendHex

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate

		RTS


;-------------------------------------------------------------------------------
clientSendIdent:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_CLNT
		ORA	#$01

		JSR	strsAppendChar

		LDAX	#text_ident_vernam
		JSR	strsAppendString

		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar

		LDAX	#text_ident_pltfrm
		JSR	strsAppendString

		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar

		LDAX	#text_ident_verlbl
		JSR	strsAppendString
		
		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS
		
@failed:
		JSR	clientNotifyFail

		LDA	#INET_PROC_DISC
		STA	inetproc
		
		RTS


;-------------------------------------------------------------------------------
clientSendUser:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_CNCT
		ORA	#$01

		JSR	strsAppendChar

		LDAX	#edit_cnct_user_buf
		JSR	strsAppendString

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS
		
@failed:
		JSR	clientNotifyFail
		
		RTS



;-------------------------------------------------------------------------------
clientSendGetSysInfo:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		
		BCC	@failed

		LDA	#MSG_CATG_TEXT
		ORA	#$00

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
clientSendKeepAlive:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_CLNT
		ORA	#$02

		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
;		JSR	clientNotifyFail
		
		RTS


;-------------------------------------------------------------------------------
clientSendRoomJoin:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		
		BCC	@failed
		
		LDA	#MSG_CATG_LOBY
		ORA	#$01
		
		JSR	strsAppendChar
		
		LDAX	#edit_room_room_buf
		JSR	strsAppendString
		
		LDA	edit_room_pwd_buf
		BEQ	@complete
		
		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar
		
		LDAX	#edit_room_pwd_buf
		JSR	strsAppendString

@complete:
		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS


;-------------------------------------------------------------------------------
;	clientSendRoomList - sends mcLobby/$03 (list room occupants) with
;	the room name as its one param - the same request the lobby's own
;	"list" command uses (see TLobbyZone.ProcessPlayerMessage's
;	Method=$03 case), just triggered automatically rather than by a
;	client-side UI command. The reply arrives as a paced mcText list,
;	already redirected to lpanel_room_log with a "* " prefix per line
;	(see clientProcTextMsgData/text_list_pref) - same mechanism the
;	MOTD poem uses, so nothing else needs building client-side.
;	Called from clientProcRoomJoinMsg once our own join is confirmed.
;-------------------------------------------------------------------------------
clientSendRoomList:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_LOBY
		ORA	#$03
		JSR	strsAppendChar

		LDAX	#edit_room_room_buf
		JSR	strsAppendString

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS

;-------------------------------------------------------------------------------
clientSendRoomPart:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		
		BCC	@failed
		
		LDA	#MSG_CATG_LOBY
		ORA	#$02
		
		JSR	strsAppendChar
		
		LDAX	#edit_room_room_buf
		JSR	strsAppendString
		
		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail
		
		RTS


;-------------------------------------------------------------------------------
clientSendRoomPeer:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		
		BCC	@failed
		
		LDA	#MSG_CATG_LOBY
		ORA	#$04
		
		JSR	strsAppendChar
		
		LDAX	#edit_room_room_buf
		JSR	strsAppendString
		
		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar

		LDAX	#edit_cnct_user_buf
		JSR	strsAppendString

		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar
		
		LDAX	#edit_room_text_buf
		JSR	strsAppendString

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail
		
		RTS


;-------------------------------------------------------------------------------
clientSendPlayJoin:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		
		BCC	@failed
		
		LDA	#MSG_CATG_PLAY
		ORA	#$01
		
		JSR	strsAppendChar
		
		LDAX	#edit_play_game_buf
		JSR	strsAppendString
		
		LDA	edit_play_pwd_buf
		BEQ	@complete
		
		LDA	#KEY_ASC_SPACE
		JSR	strsAppendChar
		
		LDAX	#edit_play_pwd_buf
		JSR	strsAppendString
		
@complete:
		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail
		
		RTS


;-------------------------------------------------------------------------------
;	Sends mcPlay/2 (Part) then tail-calls the GAME HOOK gameResetPlayGame
;	to reset local UI state, same hook as inetDisconnected uses above.
;-------------------------------------------------------------------------------
clientSendPlayPart:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$02

		JSR	strsAppendChar

		LDAX	#edit_play_game_buf
		JSR	strsAppendString

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		JMP	gameResetPlayGame
;		RTS

@failed:
		JSR	clientNotifyFail
		
		RTS


;-------------------------------------------------------------------------------
;-------------------------------------------------------------------------------
clientRoomListChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		JSR	clientSendRoomListNames

@exit:
		RTS


;-------------------------------------------------------------------------------
clientPlayListChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		JSR	clientSendPlayListGames

@exit:
		RTS


;-------------------------------------------------------------------------------
clientSendRoomListNames:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_LOBY
		ORA	#$03

		JSR	strsAppendChar

;	Only ask for a specific room's player list if we're actually in one
;	(Part button visible) - otherwise send no room name, which asks the
;	server for the list of all public rooms instead.
		LDA	button_room_part + ELEMENT::state
		AND	#STATE_VISIBLE
		BEQ	@send

		LDAX	#edit_room_room_buf
		JSR	strsAppendString

@send:
		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		LDA	#INET_PROC_DISC
		STA	inetproc

		JSR	clientNotifyFail

		RTS


;	Unlike the room list, the play list is only ever "list all games" -
;	players in a game are already visible on the overview page, so this
;	never asks for a specific game's player list. clientSendPlayListNames
;	below is separate and still does that, for the join-confirmation flow.
clientSendPlayListGames:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$03

		JSR	strsAppendChar

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		LDA	#INET_PROC_DISC
		STA	inetproc

		JSR	clientNotifyFail

		RTS


clientSendPlayListNames:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend

		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$03

		JSR	strsAppendChar

		LDAX	#edit_play_game_buf
		JSR	strsAppendString

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y
		
		RTS

@failed:
		LDA	#INET_PROC_DISC
		STA	inetproc

		JSR	clientNotifyFail
		
		RTS
		

;-------------------------------------------------------------------------------
clientProcSysMsg:
;-------------------------------------------------------------------------------
		RTS


;-------------------------------------------------------------------------------
clientProcTextMsgWhich:
;-------------------------------------------------------------------------------
		LDY	readparm1
		LDA	readmsg0, Y
		
		CMP	#'l'
		BNE	@tstplay
		
		LDA	#$0A
		JMP	@exit
		
@tstplay:
		CMP	#'p'
		BNE	@other
		
		LDA	#$14
		JMP	@exit
		
@other:
		LDA	#$00
		
@exit:
		STA	tempvar_z
		RTS


;-------------------------------------------------------------------------------
clientProcTextMsgClear:
;-------------------------------------------------------------------------------
		LDA	#$00
		TAX
@loop:
		STA	msglstsysid, Y
		STA	msglstsysloc, Y
		
		INY
		INX
		
		CPX	#$0A
		BNE	@loop

		RTS
		
		
;-------------------------------------------------------------------------------
clientProcTextMsgCopyID:
;-------------------------------------------------------------------------------
		LDY	readparm0
		LDX	#$00
@loop0:
		LDA	readmsg0, Y
		CMP	#KEY_ASC_SPACE
		BEQ	@store0
		
		STA	msglstid, X
		INX
		INY
		JMP	@loop0
		
@store0:
		INX
		STX	tempvar_y

		LDA	#$00
	
@loop1:
		CPX	#$0A
		BEQ	@exit

		STA	msglstid, X
		INX
		JMP	@loop1

@exit:
		RTS
		
	
;-------------------------------------------------------------------------------
clientProcTextMsgFind:
;-------------------------------------------------------------------------------
		LDX	#$09
		LDY	#$09
		
@loop0:
		LDA	msglstid, X
		STA	tempvar_z
		LDA	msglstsysid, Y
		
		DEY
		DEX
		BMI	@found0
		
		CMP	tempvar_z
		BEQ	@loop0

@tst1:
		LDX	#$09
		LDY	#$13
		
@loop1:
		LDA	msglstid, X
		STA	tempvar_z
		LDA	msglstsysid, Y
		
		DEY
		DEX
		BMI	@found1
		
		CMP	tempvar_z
		BEQ	@loop1
		
@tst2:
		LDX	#$09
		LDY	#$1D
		
@loop2:
		LDA	msglstid, X
		STA	tempvar_z
		LDA	msglstsysid, Y
		
		DEY
		DEX
		BMI	@found2
		
		CMP	tempvar_z
		BEQ	@loop2

		LDA	#$FF
		JMP	@exit
		
@found0:
		LDA	#$00
		JMP	@exit

@found1:
		LDA	#$0A
		JMP	@exit
		
@found2:
		LDA	#$14
		
@exit:
		STA	tempvar_z
		RTS
		

;-------------------------------------------------------------------------------
clientProcTextMsgBegin:
;-------------------------------------------------------------------------------
		JSR	clientProcTextMsgWhich
		TAY
		JSR	clientProcTextMsgClear
		
		JSR	clientProcTextMsgCopyID

		LDY	tempvar_z
		LDX	#$00
		
@loop1:
		LDA	msglstid, X
		STA	msglstsysid, Y
		
		INY
		INX
		CPX	tempvar_y
		BNE	@loop1

		LDA	readparmcnt
		CMP	#$03
		BNE	@finish
		
		LDA	readmsg0
		TAY
		INY
		STY	tempvar_x

		LDY	readparm2
		LDX	#$00
@loop2:
		LDA	readmsg0, Y
		CMP	#KEY_ASC_SPACE
		BEQ	@store1
		
		STA	msglstid, X
		INX
		INY
		
		CPY	tempvar_x
		BEQ	@store1
		
		JMP	@loop2
		
@store1:
		INX
		STX	tempvar_y
		
		LDY	tempvar_z
		LDX	#$00
		
@loop3:
		LDA	msglstid, X
		STA	msglstsysloc, Y
		
		INY
		INX
		CPX	tempvar_y
		BNE	@loop3

@finish:
		LDA	tempvar_z

		CMP	#$FF
		BEQ	@exit

;	A real list is starting (matching pop is in clientProcTextMsgMore,
;	once the "0 remaining" completion notice comes in for it). Reload
;	tempvar_z after the call since it clobbers A.
		JSR	userCursorPushBusy
		LDA	tempvar_z

		CMP	#$14
		BEQ	@play
		
		CMP	#$0A
		BEQ	@lobby
		
@system:
		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JMP	@output

@play:
		LDA	#<lpanel_play_log
		STA	tempptr2
		LDA	#>lpanel_play_log
		STA	tempptr2 + 1

		JMP	@output

@lobby:
		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1

		JMP	@output

@output:
		JSR	ctrlsLogPanelGetNextLine

		LDA	#$00
		JSR	strsAppendChar

		JSR	roomLogNotifyUpdate

@exit:
		RTS


;-------------------------------------------------------------------------------
clientProcTextMsgMore:
;-------------------------------------------------------------------------------
		LDY	readparm1
		LDA	readmsg0, Y
		CMP	#KEY_ASC_0
		BNE	@more

		JSR	clientProcTextMsgFind
		TAY
		JSR	clientProcTextMsgClear

		JSR	userCursorPopBusy

		RTS

@more:
;	List isn't finished - echo the list name back as our own method 2
;	so the server's ProcessPlayerMessage sets ml.Process:=True and
;	sends the next batch (TMessageList.ProcessList caps each batch at
;	15 entries; without this request, anything past the first batch
;	was silently dropped).
		JSR	inetGetNextSend

		BCC	@sendfail

		LDA	#MSG_CATG_TEXT
		ORA	#$02

		JSR	strsAppendChar

		LDA	readparm0
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@sendfail:
		JSR	clientNotifyFail

		RTS


	.export	clientProcTextMsgData
;-------------------------------------------------------------------------------
clientProcTextMsgData:
;-------------------------------------------------------------------------------
		JSR	clientProcTextMsgCopyID
		JSR	clientProcTextMsgFind
		
		CMP	#$FF
		BEQ	@exit
	
		CMP	#$14
		BEQ	@play
		
		CMP	#$0A
		BEQ	@lobby
		
@system:
		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JMP	@output

@play:
		JSR	inetScanReadParams

;	TODO: readparmcnt != 2 case used to update a per-slot name label
;	on the (dropped) Yahtzee overview page via clientProcTextMsgPlaySlts
;	- for now both cases just log to the play log; revisit once chess
;	has its own per-seat display to update.

@playlst:
		LDA	#<lpanel_play_log
		STA	tempptr2
		LDA	#>lpanel_play_log
		STA	tempptr2 + 1

		JMP	@output

@lobby:
		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1

		JMP	@output

@output:
		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_list_pref
		JSR	strsAppendString

		LDA	readparm1
		STA	tempdat1

		JSR	strsAppendMessage

		LDA	#$00
		JSR	strsAppendChar

		JSR	roomLogNotifyUpdate

@exit:
		RTS


;-------------------------------------------------------------------------------
clientProcTextMsg:
;-------------------------------------------------------------------------------
		LDA	imsgdat2
		CMP	#$04
		BEQ	@whisper

		JSR	inetScanReadParams
		
		LDA	readparmcnt
		CMP	#$02
		BCC	@unknown
		
		LDA	imsgdat2
		CMP	#$01
		BEQ	@begin
		
		CMP	#$02
		BEQ	@more
		
		CMP	#$03
		BEQ	@data
		
@unknown:
		JMP	clientProcUnknownMsg
		
@begin:
		JMP	clientProcTextMsgBegin

@more:
		JMP	clientProcTextMsgMore
		
@data:
		JMP	clientProcTextMsgData

@whisper:
;	Private "whisper" text from another player - wire format is
;	"user text" (mcText method 4, no room field), unlike the room-wide
;	peer chat's "room user text" (mcLobby method 4, clientProcRoomPeerMsg).
;	Dispatched here before inetScanReadParams runs, so scan params
;	ourselves. Always shows the sender header (no continuation-folding
;	against room_lastuser) and clears room_lastuser afterward so the
;	next ordinary room message reprints its own header too.
		JSR	inetScanReadParams
		LDA	readparmcnt
		CMP	#$02
		BCS	@dowhisper

		RTS

@dowhisper:
		JSR	ctrlsLockAcquire

		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1

		LDA	room_haveblank
		BNE	@wskip0

		JSR	ctrlsLogPanelGetNextLine

		LDA	#$00
		JSR	strsAppendChar

@wskip0:
		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_msg_pref
		JSR	strsAppendString

		LDA	readparm0
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam

		LDAX	#text_room_uwhisp
		JSR	strsAppendString

		LDA	#$00
		JSR	strsAppendChar

		LDY	readmsg0
		INY

		LDA	#$00
		STA	readmsg0, Y

		JSR	ctrlsLogPanelGetNextLine

		CLC
		LDA	#<readmsg0
		ADC	readparm1
		STA	tempptr3
		LDA	#>readmsg0
		ADC	#$00
		STA	tempptr3 + 1

		LDAX	tempptr3
		JSR	strsAppendWrapped

		LDA	#$00
		JSR	strsAppendChar

		LDA	#$00
		STA	room_haveblank
		STA	room_lastuser

		JSR	roomLogNotifyUpdate

		JSR	ctrlsLockRelease

		RTS


;-------------------------------------------------------------------------------
clientProcRoomJoinMsg:
;-------------------------------------------------------------------------------
		JSR	inetScanReadParams
		
		LDA	readparmcnt
		CMP	#$02
		BEQ	@join
		
		JMP	@unknown

@join:
		LDY	readmsg0
		INY
		LDA	#KEY_ASC_SPACE
		STA	readmsg0, Y

;	Update edit_room_room_buf with the room actually joined - may
;	differ slightly from what was typed/requested (server-side
;	normalisation, or joining by clicking a room in the list rather
;	than typing one in).
		LDY	readparm0
		LDX	#$00

@roombufloop:
		LDA	readmsg0, Y
		CMP	#KEY_ASC_SPACE
		BEQ	@roombufdone

		CPX	#$08
		BCS	@roombufdone

		STA	edit_room_room_buf, X
		INX
		INY
		JMP	@roombufloop

@roombufdone:
		LDA	#$00
		STA	edit_room_room_buf, X

		LDA	#<edit_room_room
		STA	elemptr0
		LDA	#>edit_room_room
		STA	elemptr0 + 1

		LDY	#EDITCTRL::textsiz
		TXA
		STA	(elemptr0), Y

		JSR	ctrlsControlInvalidate

		JSR	ctrlsLockAcquire
		
		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1 
		
		LDA	room_haveblank
		BNE	@skip0
		
		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar
		
@skip0:		
		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_indent_pref
		JSR	strsAppendString

		LDA	readparm1
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam
		
		LDAX	#text_room_ujoins
		JSR	strsAppendString

		LDA	readparm0
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam

		LDA	#$00
		JSR	strsAppendChar
		
		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar

		LDA	#$01
		STA	room_haveblank

		LDA	#$00
		STA	room_lastuser

		JSR	roomLogNotifyUpdate

;	Auto-request the room's occupant list (see clientSendRoomList) if
;	this join was our own - not for every other peer who joins after
;	us too, which would spam a redundant re-list each time. Mirrors
;	clientProcRoomPartMsg's own "was this us" name-compare exactly.
		LDX	readparm1
		LDY	#$00

@selfloop0:
		LDA	readmsg0, X
		CMP	#KEY_ASC_SPACE
		BEQ	@selffound0

		CMP	edit_cnct_user_buf, Y
		BEQ	@selfnext0

		JMP	@selfdone0

@selfnext0:
		INX
		INY
		JMP	@selfloop0

@selffound0:
		JSR	clientSendRoomList

@selfdone0:
;	Change Game Join button to Part
		LDA	#<button_room_join
		STA	elemptr0
		LDA	#>button_room_join
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		LDA	#<button_room_part
		STA	elemptr0
		LDA	#>button_room_part
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

		LDA	#<button_room_join
		CMP	actvCtrl
		BNE	@tstpick

		LDA	#>button_room_join
		CMP	actvCtrl + 1
		BNE	@tstpick

		JSR	ctrlsActivateCtrl

@tstpick:
		LDA	#<button_room_join
		CMP	pickCtrl
		BNE	@cont

		LDA	#>button_room_join
		CMP	pickCtrl + 1
		BNE	@cont

		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1


;	Disable Game Name and Password edits
@cont:
		LDA	#<edit_room_room
		STA	elemptr0
		LDA	#>edit_room_room
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		LDA	#<edit_room_pwd
		STA	elemptr0
		LDA	#>edit_room_pwd
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		JSR	ctrlsLockRelease

		RTS
		
@unknown:
		JMP	clientProcUnknownMsg
;		RTS



;-------------------------------------------------------------------------------
clientProcRoomPartMsg:
;-------------------------------------------------------------------------------
		JSR	inetScanReadParams
		
		LDA	readparmcnt
		CMP	#$02
		BEQ	@part
		
		JMP	@unknown

@part:
		LDY	readmsg0
		INY
		LDA	#KEY_ASC_SPACE
		STA	readmsg0, Y
		
		JSR	ctrlsLockAcquire
		
		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1 
		
		LDA	room_haveblank
		BNE	@skip0
		
		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar
		
@skip0:		
		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_outdent_pref
		JSR	strsAppendString
		
		LDA	readparm1
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam
		
		LDAX	#text_room_uparts
		JSR	strsAppendString

		LDA	readparm0
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam

		LDA	#$00
		JSR	strsAppendChar
		
		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar

		LDA	#$01
		STA	room_haveblank
		LDA	#$00
		STA	room_lastuser

		JSR	roomLogNotifyUpdate

;	Check that the user was us before updating the ui
		LDX	readparm1
		LDY	#$00
		
@loop0:
		LDA	readmsg0, X
		CMP	#KEY_ASC_SPACE
		BEQ	@found0
		
		CMP	edit_cnct_user_buf, Y
		BEQ	@next0
		
		JMP	@done

@next0:
		INX
		INY
		JMP	@loop0
		
@found0:
;	Change Game Part button to Join
		LDA	#<button_room_part
		STA	elemptr0
		LDA	#>button_room_part
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		LDA	#<button_room_join
		STA	elemptr0
		LDA	#>button_room_join
		STA	elemptr0 + 1

		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

;	Check the room more panel is visible before changing the active control

		LDA	#<panel_room_more
		STA	tempptr0
		LDA	#>panel_room_more
		STA	tempptr0 + 1
		
		LDY	#ELEMENT::state
		LDA	(tempptr0), Y
		AND	#STATE_VISIBLE
		BEQ	@cont
		
;	Update the active control

		LDA	#<button_room_part
		CMP	actvCtrl
		BNE	@tstpick

		LDA	#>button_room_part
		CMP	actvCtrl + 1
		BNE	@tstpick

		JSR	ctrlsActivateCtrl

@tstpick:
		LDA	#<button_room_part
		CMP	pickCtrl
		BNE	@cont

		LDA	#>button_room_part
		CMP	pickCtrl + 1
		BNE	@cont

		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1


;	Enable Game Name and Password edits
@cont:
		LDA	#<edit_room_room
		STA	elemptr0
		LDA	#>edit_room_room
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

		LDA	#<edit_room_pwd
		STA	elemptr0
		LDA	#>edit_room_pwd
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState

@done:
		JSR	ctrlsLockRelease

		RTS
		
@unknown:
		JMP	clientProcUnknownMsg
;		RTS


	.export	clientProcRoomPeerMsg
;-------------------------------------------------------------------------------
clientProcRoomPeerMsg:
;-------------------------------------------------------------------------------
		JSR	inetScanReadParams
		LDA	readparmcnt
		CMP	#$02
		BCS	@peer
		
		JMP	@unknown

@peer:
		JSR	ctrlsLockAcquire
		
		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1 

;	Compare user in message with the last one

		LDA	#$00
;		STA	tempvar_a		;Found?
		STA	tempvar_b		;lastuser idx
		
		LDAX	#readmsg0
		STAX	tempptr0
		
		LDAX	#room_lastuser
		STAX	tempptr1
		
		LDA	readparm1
		STA	tempvar_c		;message idx
		
@loop0:
		LDY	tempvar_c
		LDA	(tempptr0), Y
		CMP	#KEY_ASC_SPACE
		BEQ	@found0
		
		LDY	tempvar_b
		CMP	(tempptr1), Y
		BEQ	@next0
		
		LDA	#$00
		JMP	@done0
	
@next0:
		INC	tempvar_c
		INC	tempvar_b
		
		JMP	@loop0
		
@found0:
		LDA	#$01
;		STA	tempvar_a
		
@done0:
		BNE	@havelast

		LDA	room_haveblank
		BNE	@skip0
		
		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar
		
@skip0:		
		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_msg_pref
		JSR	strsAppendString

		LDA	readparm1
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam

		LDAX	#text_room_usays
		JSR	strsAppendString

		LDA	#$00
		JSR	strsAppendChar
		
@havelast:
		LDY	readmsg0
		INY

		LDA	#$00
		STA	readmsg0, Y

		JSR	ctrlsLogPanelGetNextLine

		CLC
		LDA	#<readmsg0
		ADC	readparm2
		STA	tempptr3
		LDA	#>readmsg0
		ADC	#$00
		STA	tempptr3 + 1

		LDAX	tempptr3
		JSR	strsAppendWrapped
		
		LDA	#$00
		JSR	strsAppendChar
		
		LDA	#$00
		STA	room_haveblank

		LDY	readparm1
		LDX	#$00
		
@loop1:
		LDA	readmsg0, Y
		CMP	#KEY_ASC_SPACE
		BEQ	@done1
		
		STA	room_lastuser, X
		
		INY
		INX
		
		JMP	@loop1
		
@done1:
		LDA	#$00
		STA	room_lastuser, X

		JSR	roomLogNotifyUpdate

		JSR	ctrlsLockRelease

		RTS
		
@unknown:
		JMP	clientProcUnknownMsg
;		RTS


;-------------------------------------------------------------------------------
clientProcLobbyMsg:
;-------------------------------------------------------------------------------
		LDA	imsgdat2
		BNE	@tstfirst
		
;	Error message
		LDA	#<lpanel_room_log
		STA	tempptr2
		LDA	#>lpanel_room_log
		STA	tempptr2 + 1 

		LDA	room_haveblank
		BNE	@skip0

		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar

@skip0:
		JSR	ctrlsLogPanelGetNextLine

		LDAX 	#text_err_pref
		JSR	strsAppendString

		LDA	#$02
		STA	tempdat1

		JSR	strsAppendMessage

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelGetNextLine
		
		LDA	#$00
		JSR	strsAppendChar
		
		LDA	#$01
		STA	room_haveblank

		JSR	roomLogNotifyUpdate

		RTS

@tstfirst:
		CMP	#$01
		BNE	@tstnxt0
		
		JMP	clientProcRoomJoinMsg
;		RTS
		
@tstnxt0:
		CMP	#$02
		BNE	@tstnxt1
		
		JMP	clientProcRoomPartMsg
;		RTS


@tstnxt1:
		CMP	#$04
		BNE	@tstnxt2
		
		JMP	clientProcRoomPeerMsg
;		RTS

@tstnxt2:
		JMP	clientProcUnknownMsg
;		RTS


;-------------------------------------------------------------------------------
clientProcConctMsg:
;-------------------------------------------------------------------------------
		LDA	imsgdat2
		BNE	@tstnxt0

		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JSR	ctrlsLogPanelGetNextLine

		LDAX 	#text_err_pref
		JSR	strsAppendString

		LDA	#$02
		STA	tempdat1

		JSR	strsAppendMessage

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate

		RTS

@tstnxt0:
		CMP	#$01
		BEQ	@ident

		JMP	clientProcUnknownMsg
;		RTS

@ident:
;	Server echoes mcConnect/1 back once it accepts our clientSendUser -
;	it only accepts one per connection, so disable the Update button
;	(button_cnct_upd) rather than let further clicks just collect
;	"Invalid connect ident" errors.
		LDA	#$01
		STA	userNameAccepted

		JSR	ctrlsLockAcquire

		LDA	#<button_cnct_upd
		STA	elemptr0
		LDA	#>button_cnct_upd
		STA	elemptr0 + 1

		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		JSR	ctrlsLockRelease

		RTS


;-------------------------------------------------------------------------------
clientProcClientMsg:
;-------------------------------------------------------------------------------
		RTS


	.export	clientProcServerMsg
;-------------------------------------------------------------------------------
clientProcServerMsg:
;-------------------------------------------------------------------------------
		LDA	imsgdat2
		BNE	@tstnxt0

		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_syserr_pref
		JSR	strsAppendString

		LDA	#$02
		STA	tempdat1
		
		JSR	strsAppendMessage

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate

		RTS

@tstnxt0:
		CMP	#$01
		BEQ	@ident

@tstnxt1:
		CMP	#$02
		BEQ	@chlng

		JMP	clientProcUnknownMsg
;		RTS

@ident:
;	Copy up to 42 characters of the message string into edit_cnct_info_buf
;	and mark the control dirty so it gets redrawn.

		LDA	readmsglen
		SEC
		SBC	#$02

		CMP	#43
		BCC	:+
		LDA	#42
:
		STA	tempdat0

		LDY	#$00
@infoloop:
		CPY	tempdat0
		BEQ	@infodone

		LDA	readmsg0 + 2, Y
		STA	edit_cnct_info_buf, Y

		INY
		BNE	@infoloop

@infodone:
		LDA	#$00
		STA	edit_cnct_info_buf, Y

		LDA	#<edit_cnct_info
		STA	elemptr0
		LDA	#>edit_cnct_info
		STA	elemptr0 + 1

		LDY	#EDITCTRL::textsiz
		LDA	tempdat0
		STA	(elemptr0), Y

		JSR	ctrlsControlInvalidate

		JSR	clientSendIdent
		JSR	clientSendUser
		JSR	clientSendGetSysInfo

		RTS

@chlng:
		JMP	clientSendKeepAlive
;		RTS


;-------------------------------------------------------------------------------
;	clientProcPlayMsg - clientMsgProcs' mcPlay category entry (see the
;	table above). Method $0E (GameChat) is handled generically right
;	here, same as room/lobby chat - see clientProcPlayGameChatMsg.
;	Everything else is game-specific wire shape (chess's original also
;	dispatched join/part/game status/slot status/starting-colours/
;	board sync/available moves/move made here) - GAME HOOK
;	gameProcPlayMsg, defined in the game's own file (see snake_game.s),
;	handles the rest.
;-------------------------------------------------------------------------------
clientProcPlayMsg:
;-------------------------------------------------------------------------------
		LDA	imsgdat2
		CMP	#$0E
		BEQ	@gamechat

		JMP	gameProcPlayMsg
;		RTS

@gamechat:
		JMP	clientProcPlayGameChatMsg


;-------------------------------------------------------------------------------
;	clientProcPlayGameChatMsg - mcPlay/$0E (GameChat broadcast). Same
;	dedup-against-last-sender shape as clientProcRoomPeerMsg above,
;	just routed to lpanel_play_log/play_haveblank/play_lastuser instead
;	of the room log, and with no leading room-name field to skip past
;	(readparm0 is the sender here, not readparm1 - GameChat's payload
;	is just [sender, message], unlike RoomPeer's [room, sender,
;	message]).
;-------------------------------------------------------------------------------
clientProcPlayGameChatMsg:
;-------------------------------------------------------------------------------
		JSR	inetScanReadParams
		LDA	readparmcnt
		CMP	#$02
		BCS	@peer

		JMP	clientProcUnknownMsg
;		RTS

@peer:
		JSR	ctrlsLockAcquire

		LDA	#<lpanel_play_log
		STA	tempptr2
		LDA	#>lpanel_play_log
		STA	tempptr2 + 1

;	Compare sender in message with the last one

		LDA	#$00
		STA	tempvar_b		;lastuser idx

		LDAX	#readmsg0
		STAX	tempptr0

		LDAX	#play_lastuser
		STAX	tempptr1

		LDA	readparm0
		STA	tempvar_c		;message idx

@loop0:
		LDY	tempvar_c
		LDA	(tempptr0), Y
		CMP	#KEY_ASC_SPACE
		BEQ	@found0

		LDY	tempvar_b
		CMP	(tempptr1), Y
		BEQ	@next0

		LDA	#$00
		JMP	@done0

@next0:
		INC	tempvar_c
		INC	tempvar_b

		JMP	@loop0

@found0:
		LDA	#$01

@done0:
		BNE	@havelast

		LDA	play_haveblank
		BNE	@skip0

		JSR	ctrlsLogPanelGetNextLine

		LDA	#$00
		JSR	strsAppendChar

@skip0:
		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_msg_pref
		JSR	strsAppendString

		LDA	readparm0
		STA	tempdat3

		LDAX	#readmsg0
		JSR	strsAppendParam

		LDAX	#text_room_usays
		JSR	strsAppendString

		LDA	#$00
		JSR	strsAppendChar

@havelast:
		LDY	readmsg0
		INY

		LDA	#$00
		STA	readmsg0, Y

		JSR	ctrlsLogPanelGetNextLine

		CLC
		LDA	#<readmsg0
		ADC	readparm1
		STA	tempptr3
		LDA	#>readmsg0
		ADC	#$00
		STA	tempptr3 + 1

		LDAX	tempptr3
		JSR	strsAppendWrapped

		LDA	#$00
		JSR	strsAppendChar

		LDA	#$00
		STA	play_haveblank

		LDY	readparm0
		LDX	#$00

@loop1:
		LDA	readmsg0, Y
		CMP	#KEY_ASC_SPACE
		BEQ	@done1

		STA	play_lastuser, X

		INY
		INX

		JMP	@loop1

@done1:
		LDA	#$00
		STA	play_lastuser, X

		JSR	ctrlsLogPanelUpdate

		JSR	ctrlsLockRelease

		RTS


;-------------------------------------------------------------------------------
;	strsSetEmptyName - resets an 8-byte name buffer (elemptr0) back to
;	the framework's generic "(EMPTY)" placeholder text (text_name_empty
;	below) - for a game's own player-name labels, same idea as chess's
;	original page_ovrvw name buffers.
;-------------------------------------------------------------------------------
strsSetEmptyName:
;-------------------------------------------------------------------------------
		LDY	#$00

@loop:
		LDA	text_name_empty, Y
		STA	(elemptr0), Y

		INY
		CPY	#$08
		BCC	@loop

		RTS


;-------------------------------------------------------------------------------
clientHandleReadMsg:
;-------------------------------------------------------------------------------
		JSR	ctrlsLockAcquire

		LDY	#$01
		LDA	readmsg0, Y

		AND	#$0F
		STA	imsgdat2

		LDA	readmsg0, Y
		AND	#$F0
		LSR
		LSR
		LSR

		TAY

		LDA	clientMsgProcs, Y
		STA	@branch + 1
		LDA	clientMsgProcs + 1, Y
		STA	@branch + 2

		LDY	#$02
		STY	imsgdat1	
		
@branch:
		JSR	clientHandleReadMsg

@exit:
		JSR	ctrlsLockRelease

		RTS


;-------------------------------------------------------------------------------
clientOutputInetConfig:
;-------------------------------------------------------------------------------
		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JSR	ctrlsLogPanelGetNextLine
		LDAX	#text_trace_init
		JSR	strsAppendString

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_driver_pref
		JSR	strsAppendString

		LDAX 	#eth_driver_name
		JSR	strsAppendString

		LDAX 	#eth_name
		JSR	strsAppendString

		LDA	#$00
		JSR	strsAppendChar
;
;		JSR	ctrlsLogPanelGetNextLine
;		
;		LDAX 	#text_iobase_pref
;		JSR	strsAppendString
;		
;		LDA 	eth_driver_io_base + 1
;		JSR 	strsAppendHex
;		
;		LDA 	eth_driver_io_base
;		JSR 	strsAppendHex
;
;		LDA	#$00
;		JSR	strsAppendChar
		
		JSR	ctrlsLogPanelGetNextLine

		LDAX 	#text_ipcfg_pref
		JSR	strsAppendString

		LDAX 	#cfg_ip
		JSR 	strsAppendDottedQuad

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate

		RTS


;-------------------------------------------------------------------------------
clientOutputInetError:
;-------------------------------------------------------------------------------
		LDA	#<lpanel_cnct_log
		STA	tempptr2 
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JSR	ctrlsLogPanelGetNextLine

		LDA	ineterrk
		CMP	#INET_ERR_NONE
		BEQ	@none

		CMP	#INET_ERR_INTRF
		BNE	@internal

		LDA	ineterrc
		CMP	#INET_ERROR_INIT
		BNE	@tstnxt0

		LDAX	#text_err_init
		JSR	strsAppendString
		JMP	@exit

@tstnxt0:
		CMP	#INET_ERROR_CNCT
		BNE	@tstnxt1

		LDAX	#text_err_cnct
		JSR	strsAppendString
		JMP	@exit

@tstnxt1:
		LDAX	#text_err_disc
		JSR	strsAppendString

;	discEventFlags - TCP_EVENT_FLAG's EV_* bits at the moment the
;	disconnect was noticed (see inetRecordDiscEvent): bit0 RST,
;	bit1 peer FIN, bit2 our FIN completed, bit3 TIME_WAIT done,
;	bit4 connect failed, bit5 TX retries exhausted, bit6 bad SYN+ACK.
;	$00 means it was detected via the inbound-EOF sentinel instead,
;	with no TCP_EVENT_FLAG bits available.
		LDAX	#text_err_disc_evt
		JSR	strsAppendString

		LDA	discEventFlags
		JSR	strsAppendHex

		JMP	@exit

@none:
		LDAX	#text_err_okay
		JSR	strsAppendString
		JMP	@exit

@internal:
		LDA 	ineterrc
		CMP 	#IP65_ERROR_ABORTED_BY_USER
		BNE 	:+
		
		LDAX 	#text_err_abort
		JSR	strsAppendString
		JMP	@exit

: 
		CMP 	#IP65_ERROR_TIMEOUT_ON_RECEIVE
		BNE 	:+
  
		LDAX 	#text_err_timeout
		JSR 	strsAppendString
		JMP	@exit

: 
		LDAX 	#text_err_other
		JSR 	strsAppendString
		
		LDA 	ineterrc
		JSR 	strsAppendHex

@exit:
		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate
		RTS


;-------------------------------------------------------------------------------
clientInitLblPres:
;-------------------------------------------------------------------------------
		JSR	ctrlsControlDefPresent

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		BNE	@init

		LDA	#<panel_splsh_foot
		STA	elemptr0
		LDA	#>panel_splsh_foot
		STA	elemptr0 + 1

		JSR	ctrlsControlInvalidate

		RTS

@init:
		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState

		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState

		LDA	#<button_splsh_cont
		STA	elemptr0
		LDA	#>button_splsh_cont
		STA	elemptr0 + 1
		
		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState

		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState
		
		JSR	ctrlsActivateCtrl
		
		LDA	#INET_PROC_INIT
		STA	inetproc
		
@exit:
		RTS
		

;-------------------------------------------------------------------------------
clientSplshContChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	#<page_connect
		STA	elemptr0
		LDA	#>page_connect
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect

@exit:
		RTS


	.export	clientSplshContKeyPress
;-------------------------------------------------------------------------------
clientSplshContKeyPress:
;-------------------------------------------------------------------------------
		JSR	ctrlsDownCtrl

		RTS
	

	.export	clientPlayJoinChng
;-------------------------------------------------------------------------------
clientPlayJoinChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	inetstat
		CMP	#INET_STATE_ERR
		BEQ	@exit

		LDA	edit_play_game_buf
		BEQ	@exit

		JSR	clientSendPlayJoin

		
@exit:
		RTS


	.export	clientPlayPartChng
;-------------------------------------------------------------------------------
clientPlayPartChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	inetstat
		CMP	#INET_STATE_ERR
		BEQ	@exit

		LDA	edit_play_game_buf
		BEQ	@exit

		JSR	clientSendPlayPart

		
@exit:
		RTS


	.export	clientRoomJoinChng
;-------------------------------------------------------------------------------
clientRoomJoinChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	inetstat
		CMP	#INET_STATE_ERR
		BEQ	@exit

		LDA	edit_room_room_buf
		BEQ	@exit

		JSR	clientSendRoomJoin

@exit:
		RTS


	.export	clientRoomPartChng
;-------------------------------------------------------------------------------
clientRoomPartChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	inetstat
		CMP	#INET_STATE_ERR
		BEQ	@exit

		LDA	edit_room_room_buf
		BEQ	@exit

		JSR	clientSendRoomPart
		
@exit:
		RTS


;-------------------------------------------------------------------------------
clientCnctUpdChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	userNameAccepted
		BNE	@exit			;already accepted - button should be disabled, but don't re-send if clicked anyway

		JSR	clientSendUser

@exit:
		RTS


	.export	clientCnctCnctChng
;-------------------------------------------------------------------------------
clientCnctCnctChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	inetproc
		CMP	#INET_PROC_EXEC
		BCS	@exit

		LDA	#<lpanel_cnct_log
		STA	tempptr2 
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1 

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_trace_cnct
		JSR	strsAppendString
		
		LDA	#$00
		LDY	tempdat0
		STA	(tempptr0), Y
		
		JSR	ctrlsLogPanelUpdate

		LDA	#INET_PROC_PCNT
		STA	inetproc

@exit:
		RTS


;-------------------------------------------------------------------------------
clientCnctDCntChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	inetproc
		CMP	#INET_PROC_EXEC
		BNE	@exit

		LDA	#INET_PROC_DISC
		STA	inetproc

@exit:
		RTS


;-------------------------------------------------------------------------------
clientMainUnsetTabs:
;-------------------------------------------------------------------------------
		LDX	#$07
@loop:
		LDA	tab_main_ctrls, X
		STA	tempptr0 + 1
		DEX
		LDA	tab_main_ctrls, X
		STA	tempptr0

		LDY	#ELEMENT::colour
		LDA	#CLR_FACE
		STA	(tempptr0), Y
		
		LDY	#ELEMENT::options
		LDA	(tempptr0), Y
		AND	#($FF ^ (OPT_NONAVIGATE))
		STA	(tempptr0), Y

		DEX
		BPL	@loop

		RTS

	
;-------------------------------------------------------------------------------
clientMainBeginChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDY	#ELEMENT::options
		LDA	tlabel_main_begin, Y
		AND	#OPT_NONAVIGATE
		BNE	@exit

		JSR	clientMainUnsetTabs

		LDY	#ELEMENT::colour
		LDA	#CLR_FOCUS
		STA	tlabel_main_begin, Y

		LDY	#ELEMENT::options
		LDA	#(OPT_NODOWNACTV | OPT_NONAVIGATE | OPT_TEXTACCEL2X)
		STA	tlabel_main_begin, Y

		SEI

		LDA	#<page_connect
		STA	elemptr0
		LDA	#>page_connect
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect

@exit:
		RTS


;-------------------------------------------------------------------------------
clientMainChatChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDY	#ELEMENT::options
		LDA	tlabel_main_chat, Y
		AND	#OPT_NONAVIGATE
		BNE	@exit

		JSR	clientMainUnsetTabs

		LDY	#ELEMENT::colour
		LDA	#CLR_FOCUS
		STA	tlabel_main_chat, Y

		LDY	#ELEMENT::options
		LDA	#(OPT_NODOWNACTV | OPT_NONAVIGATE | OPT_TEXTACCEL2X)
		STA	tlabel_main_chat, Y

		SEI
		LDA	#<page_room
		STA	elemptr0
		LDA	#>page_room
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect
@exit:

		RTS


;-------------------------------------------------------------------------------
clientMainNextChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		SEI

		LDA	pageNext
		STA	elemptr0
		LDA	pageNext + 1
		STA	elemptr0 + 1

		JSR	ctrlsPageSelect

@exit:
		RTS


;-------------------------------------------------------------------------------
clientMainBackChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		SEI

		LDA	pageBack
		STA	elemptr0
		LDA	pageBack + 1
		STA	elemptr0 + 1

		JSR	ctrlsPageSelect

@exit:
		RTS


;-------------------------------------------------------------------------------
clientRoomMoreChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BNE	@down

		JSR	ctrlsControlInvalidate
		JMP	@exit
		
@down:
		LDA	(elemptr0), Y
		AND	#($FF ^ (STATE_DOWN | STATE_PICK | STATE_ACTIVE))
		STA	(elemptr0), Y

		LDA	#$00
		STA	downCtrl
		STA	downCtrl + 1

;		JSR	ctrlsControlInvalidate

		LDA	#<panel_room_more
		STA	elemptr0
		LDA	#>panel_room_more
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		
		LDA	#<panel_room_less
		STA	elemptr0
		LDA	#>panel_room_less
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState

;		JSR	userMouseUnPickCtrl
;		JSR	ctrlsDeactivateCtrl
		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1
;		STA	actvCtrl
;		STA	actvCtrl + 1

;	Activate the button that just became visible (button_room_less),
;	not a control buried inside the newly-shown panel - activating
;	edit_room_room here was losing track of the active control.
		LDA	#<button_room_less
		STA	elemptr0
		LDA	#>button_room_less
		STA	elemptr0 + 1

		JSR	ctrlsActivateCtrl

		LDA	#<lpanel_room_log
		STA	elemptr0
		LDA	#>lpanel_room_log
		STA	elemptr0 + 1
		
		LDY	#ELEMENT::posy
		LDA	#$0A
		STA	(elemptr0), Y
		INY
		INY
		LDA	#$0D
		STA	(elemptr0), Y
		
		LDY	#LOGPANEL::offsy
		LDA	#$04
		STA	(elemptr0), Y
		
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		
		AND	#STATE_CHANGED
		BNE	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_CHANGED
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat1

		JSR	msgsPushChanging		
		
@exit:
		RTS
		
		
;-------------------------------------------------------------------------------
clientRoomLessChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BNE	@down

		JSR	ctrlsControlInvalidate
		JMP	@exit
		
@down:
		LDA	(elemptr0), Y
		AND	#($FF ^ (STATE_DOWN | STATE_PICK | STATE_ACTIVE))
		STA	(elemptr0), Y

		LDA	#$00
		STA	downCtrl
		STA	downCtrl + 1
		
;		JSR	ctrlsControlInvalidate

		LDA	#<panel_room_less
		STA	elemptr0
		LDA	#>panel_room_less
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		
		LDA	#<panel_room_more
		STA	elemptr0
		LDA	#>panel_room_more
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState

;		JSR	userMouseUnPickCtrl
;		JSR	ctrlsDeactivateCtrl
		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1
;		STA	actvCtrl
;		STA	actvCtrl + 1

		LDA	#<edit_room_text
		STA	elemptr0
		LDA	#>edit_room_text
		STA	elemptr0 + 1
		
		JSR	ctrlsActivateCtrl

		LDA	#<lpanel_room_log
		STA	elemptr0
		LDA	#>lpanel_room_log
		STA	elemptr0 + 1
		
		LDY	#ELEMENT::posy
		LDA	#$06
		STA	(elemptr0), Y
		INY
		INY
		LDA	#$11
		STA	(elemptr0), Y
		
		LDY	#LOGPANEL::offsy
		LDA	#$00
		STA	(elemptr0), Y
		
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		
		AND	#STATE_CHANGED
		BNE	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_CHANGED
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat1

		JSR	msgsPushChanging		
		
@exit:
		RTS


;-------------------------------------------------------------------------------
ctrlsRoomTextChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsPanelDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BNE	@exit

		LDA	edit_room_text_buf
		BEQ	@exit
		
		JSR	clientSendRoomPeer
		
		LDA	#$00
		STA	edit_room_text_buf
		LDY	#EDITCTRL::textsiz
		STA	(elemptr0), Y		
		
		JSR	ctrlsControlInvalidate

@exit:
		RTS

;-------------------------------------------------------------------------------
clientMainPlayChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDY	#ELEMENT::options
		LDA	tlabel_main_play, Y
		AND	#OPT_NONAVIGATE
		BNE	@exit

		JSR	clientMainUnsetTabs

		LDY	#ELEMENT::colour
		LDA	#CLR_FOCUS
		STA	tlabel_main_play, Y

		LDY	#ELEMENT::options
		LDA	#(OPT_NODOWNACTV | OPT_NONAVIGATE | OPT_TEXTACCEL2X)
		STA	tlabel_main_play, Y

		SEI
		LDA	#<page_play
		STA	elemptr0
		LDA	#>page_play
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect
@exit:

		RTS


;-------------------------------------------------------------------------------
clientMainPrefsChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDY	#ELEMENT::options
		LDA	tlabel_main_prefs, Y
		AND	#OPT_NONAVIGATE
		BNE	@exit

		JSR	clientMainUnsetTabs

		LDY	#ELEMENT::colour
		LDA	#CLR_FOCUS
		STA	tlabel_main_prefs, Y

		LDY	#ELEMENT::options
		LDA	#(OPT_NODOWNACTV | OPT_NONAVIGATE | OPT_TEXTACCEL2X)
		STA	tlabel_main_prefs, Y

		SEI
		LDA	#<page_config
		STA	elemptr0
		LDA	#>page_config
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect
@exit:

		RTS


;-------------------------------------------------------------------------------
clientConfigThemeNxtChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	clrschme_idx
		CMP	#(clrschme_cnt - 1)
		BCS	@exit			;already at the last scheme

		INC	clrschme_idx

		JSR	clientConfigThemeApply

@exit:
		RTS


;-------------------------------------------------------------------------------
clientConfigThemePrvChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

		LDA	clrschme_idx
		BEQ	@exit			;already at the first scheme

		DEC	clrschme_idx

		JSR	clientConfigThemeApply

@exit:
		RTS


;-------------------------------------------------------------------------------
;	clientConfigThemeApply - point label_config_theme_name at the name
;	for clrschme_idx, apply that scheme's colours, then re-select
;	page_config (via the same pageptr0 short-circuit as before) so the
;	panels redraw with the new colours and label text.
;-------------------------------------------------------------------------------
clientConfigThemeApply:
		LDA	#<clrschme_lst
		STA	tempptr0
		LDA	#>clrschme_lst
		STA	tempptr0 + 1

		LDA	clrschme_idx
		ASL
		ASL
		CLC
		ADC	#$02			;skip the scheme-data word, land
		TAY				;	on the name-pointer word

		LDA	(tempptr0), Y
		STA	label_config_theme_name + CONTROL::textptr
		INY
		LDA	(tempptr0), Y
		STA	label_config_theme_name + CONTROL::textptr + 1

		LDA	clrschme_idx
		JSR	colourSchemeSelect

		LDA	#$00
		STA	pageptr0 + 1

		LDA	#<page_config
		STA	elemptr0
		LDA	#>page_config
		STA	elemptr0 + 1
		JSR	ctrlsPageSelect

		RTS


;-------------------------------------------------------------------------------
;	The three speed checkboxes below are coerced into acting like a
;	real radio group: each one is a normal OPT_AUTOCHECK checkbox (so
;	ctrlsControlDefChanged still handles the redraw), but its changed
;	handler forces its own tag back to checked (undoing a toggle-off
;	click on the already-checked box) and forces the other two to
;	unchecked. No toggle-off limitation - clicking the checked box is
;	a no-op, clicking either other box switches selection.
;-------------------------------------------------------------------------------
clientConfigSpeedSlowChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

    LDA #$01
    STA checkbx_config_mouse_slow + ELEMENT::tag

		LDA	#<checkbx_config_mouse_medium
		STA	elemptr0
		LDA	#>checkbx_config_mouse_medium
		STA	elemptr0 + 1
		JSR	clientConfigSpeedUncheck

		LDA	#<checkbx_config_mouse_fast
		STA	elemptr0
		LDA	#>checkbx_config_mouse_fast
		STA	elemptr0 + 1
		JSR	clientConfigSpeedUncheck

		LDA	#MOUSE_SPEED_SLOW
		STA	mouseAccelSpeed

@exit:
		RTS


;-------------------------------------------------------------------------------
clientConfigSpeedMediumChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

    LDA #$01
    STA checkbx_config_mouse_medium + ELEMENT::tag

		LDA	#<checkbx_config_mouse_slow
		STA	elemptr0
		LDA	#>checkbx_config_mouse_slow
		STA	elemptr0 + 1
		JSR	clientConfigSpeedUncheck

		LDA	#<checkbx_config_mouse_fast
		STA	elemptr0
		LDA	#>checkbx_config_mouse_fast
		STA	elemptr0 + 1
		JSR	clientConfigSpeedUncheck

		LDA	#MOUSE_SPEED_MEDIUM
		STA	mouseAccelSpeed

@exit:
		RTS


;-------------------------------------------------------------------------------
clientConfigSpeedFastChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit

    LDA #$01
    STA checkbx_config_mouse_fast + ELEMENT::tag

		LDA	#<checkbx_config_mouse_slow
		STA	elemptr0
		LDA	#>checkbx_config_mouse_slow
		STA	elemptr0 + 1
		JSR	clientConfigSpeedUncheck

		LDA	#<checkbx_config_mouse_medium
		STA	elemptr0
		LDA	#>checkbx_config_mouse_medium
		STA	elemptr0 + 1
		JSR	clientConfigSpeedUncheck

		LDA	#MOUSE_SPEED_FAST
		STA	mouseAccelSpeed

@exit:
		RTS


;-------------------------------------------------------------------------------
;	clientConfigSpeedUncheck - force the checkbox pointed to by elemptr0
;	back to unchecked (tag = 0) and redraw it.
;-------------------------------------------------------------------------------
clientConfigSpeedUncheck:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::tag
		LDA	#$00
		STA	(elemptr0), Y

		JSR	ctrlsControlInvalidate

		RTS


;-------------------------------------------------------------------------------
clientPlayMoreChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BNE	@down

		JSR	ctrlsControlInvalidate
		JMP	@exit
		
@down:
		LDA	(elemptr0), Y
		AND	#($FF ^ (STATE_DOWN | STATE_PICK | STATE_ACTIVE))
		STA	(elemptr0), Y

		LDA	#$00
		STA	downCtrl
		STA	downCtrl + 1

;		JSR	ctrlsControlInvalidate

		LDA	#<panel_play_more
		STA	elemptr0
		LDA	#>panel_play_more
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		
		LDA	#<panel_play_less
		STA	elemptr0
		LDA	#>panel_play_less
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState

;		JSR	userMouseUnPickCtrl
;		JSR	ctrlsDeactivateCtrl
		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1
;		STA	actvCtrl
;		STA	actvCtrl + 1

;	Activate the button that just became visible (button_play_less),
;	not a control buried inside the newly-shown panel - activating
;	edit_play_game here was losing track of the active control (same
;	fix as clientRoomMoreChng).
		LDA	#<button_play_less
		STA	elemptr0
		LDA	#>button_play_less
		STA	elemptr0 + 1

		JSR	ctrlsActivateCtrl

		LDA	#<lpanel_play_log
		STA	elemptr0
		LDA	#>lpanel_play_log
		STA	elemptr0 + 1

;!!TODO: Change an offset parameter to hide/show top lines

		LDY	#ELEMENT::posy
		LDA	#$0A
		STA	(elemptr0), Y
		INY
		INY
		LDA	#$0D
		STA	(elemptr0), Y
		
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		
		AND	#STATE_CHANGED
		BNE	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_CHANGED
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat1

		JSR	msgsPushChanging		
		
@exit:
		RTS
		
		
;-------------------------------------------------------------------------------
clientPlayLessChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BNE	@down

		JSR	ctrlsControlInvalidate
		JMP	@exit
		
@down:
		LDA	(elemptr0), Y
		AND	#($FF ^ (STATE_DOWN | STATE_PICK | STATE_ACTIVE))
		STA	(elemptr0), Y

		LDA	#$00
		STA	downCtrl
		STA	downCtrl + 1
		
;		JSR	ctrlsControlInvalidate

		LDA	#<panel_play_less
		STA	elemptr0
		LDA	#>panel_play_less
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsIncludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsIncludeState
		
		LDA	#<panel_play_more
		STA	elemptr0
		LDA	#>panel_play_more
		STA	elemptr0 + 1
		
		LDA	#STATE_ENABLED
		JSR	ctrlsExcludeState
		LDA	#STATE_VISIBLE
		JSR	ctrlsExcludeState

;		JSR	userMouseUnPickCtrl
;		JSR	ctrlsDeactivateCtrl
		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1
;		STA	actvCtrl
;		STA	actvCtrl + 1

		LDA	#<edit_play_text
		STA	elemptr0
		LDA	#>edit_play_text
		STA	elemptr0 + 1
		
		JSR	ctrlsActivateCtrl

		LDA	#<lpanel_play_log
		STA	elemptr0
		LDA	#>lpanel_play_log
		STA	elemptr0 + 1

;!!TODO: Change an offset parameter to hide/show top lines

		LDY	#ELEMENT::posy
		LDA	#$06
		STA	(elemptr0), Y
		INY
		INY
		LDA	#$11
		STA	(elemptr0), Y
		
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		
		AND	#STATE_CHANGED
		BNE	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_CHANGED
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat1

		JSR	msgsPushChanging		
		
@exit:
		RTS


;-------------------------------------------------------------------------------
dmaFillRow:
;-------------------------------------------------------------------------------
		STA	@val

		LDA	dmaCnt
		STA	@cnt
		LDA	dmaDst
		STA	@dst
		LDA	dmaDst + 1
		STA	@dst + 1
		LDA	dmaDstBank
		STA	@dstbank

		STA	$D707
;	Dest skip = 2 - only the low byte of each 16-bit screen/colour cell
;	gets written, so the $00 high byte initMem already put there is
;	left alone. EXPERIMENTAL - verify on hardware.
		.byte	$85, $02
		.byte	$00		;end of job options
		.byte	$03		;fill
@cnt:
    .byte	$00
		.byte	$00		;count hi (row fills are always < 256 bytes)
@val:
    .byte	$00
		.byte	$00		;value hi (unused - fill byte is the low byte)
		.byte	$00		;src bank
@dst:
    .word	$0000
@dstbank:
    .byte	$00		;dst bank
		.byte	$00		;cmd hi
		.word	$0000		;modulo/ignored

		RTS


;-------------------------------------------------------------------------------
;	Copies dmaCnt bytes from dmaSrc to dmaDst via an inline enhanced
;	DMA job - same layout as dmaFillRow, but cmd $00 (copy) instead of
;	$03 (fill), so the word field after the command bytes is read as
;	a source address instead of a fill value.
;	IN	dmaSrc		source address
;	IN	dmaDst		destination address
;	IN	dmaCnt		byte count (1-255)
;	USED	.A
;-------------------------------------------------------------------------------
dmaCopyRow:
;-------------------------------------------------------------------------------
		LDA	dmaCnt
		STA	@cnt
		LDA	dmaSrc
		STA	@src
		LDA	dmaSrc + 1
		STA	@src + 1
		LDA	dmaDst
		STA	@dst
		LDA	dmaDst + 1
		STA	@dst + 1

		STA	$D707
		.byte	$00		;end of job options
		.byte	$00		;copy
@cnt:		
    .byte	$00
		.byte	$00		;count hi (row copies are always < 256 bytes)
@src:		
    .word	$0000
		.byte	$00		;src bank
@dst:		
    .word	$0000
		.byte	$00		;dst bank
		.byte	$00		;cmd hi
		.word	$0000		;modulo/ignored

		RTS


;-------------------------------------------------------------------------------
screenRectSetColour:
;	IN	.A		Colour ident
;	IN	tempvar_a	x pos
;	IN	tempvar_b	y pos
;	IN	tempvar_c	width
;	IN	tempvar_d	height
;	USED	.A
;	USED	.X
;	USED	.Y
;	USED	tempvar_e
;	USED	tempptr1
;-------------------------------------------------------------------------------
		JSR	screenCtrlToLogClr	
		STA	tempvar_e		;logical colour

@looph:
;	Column -> byte offset is column*2 now (CHR16/FCLRHI cells are 2
;	bytes). dest-skip=2 already advances the destination by 2 bytes
;	per write, so dmaCnt is the cell count (width) unscaled, not
;	width*2 - confirmed on hardware (see the second comment below).
;	+1 because under FCLRHI the system colour value lives in the HIGH
;	byte of a colour cell (see STCOLR16) - the low byte stays whatever
;	initMem's boot-time zero-fill left it as.
		LDA	tempvar_a
		ASL
		CLC
		ADC	#$01
		STA	tempvar_g

		LDX	tempvar_b
		LDA	screenRowsLo, X
		CLC
		ADC	tempvar_g
		STA	dmaDst
		LDA	colourRowsHiPhys, X
		ADC	#$00
		STA	dmaDst + 1

		LDA	#$01			;colour RAM's real physical
		STA	dmaDstBank		;address is $01F800, not $D800

;	dest-skip=2 already advances the destination by 2 bytes per write,
;	so dmaCnt is the cell count (width) unscaled, not width*2 -
;	doubling it too made fills span twice the intended column range.
		LDA	tempvar_c
		STA	dmaCnt
;	CRITICAL: a DMA job count of 0 is a real hardware hazard on this
;	platform (not a harmless no-op) - never let a zero-width call
;	reach dmaFillRow.
		BEQ	@skipclr

		LDA	tempvar_e		;colour to colour ram
		AND	#$0F
		JSR	dmaFillRow

@skipclr:
		INC	tempvar_b
		DEC	tempvar_d
		LDA	tempvar_d
		BNE	@looph

		RTS


;-------------------------------------------------------------------------------
;	clientPlayTextChng - page_play's in-game chat edit control (see
;	edit_play_text). Mirrors ctrlsRoomTextChng exactly, just sends via
;	clientSendGameChat/mcPlay instead of clientSendRoomPeer/mcLoby.
;-------------------------------------------------------------------------------
clientPlayTextChng:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsPanelDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BNE	@exit

		LDA	edit_play_text_buf
		BEQ	@exit

		JSR	clientSendGameChat

		LDA	#$00
		STA	edit_play_text_buf
		LDY	#EDITCTRL::textsiz
		STA	(elemptr0), Y

		JSR	ctrlsControlInvalidate

@exit:
		RTS

;-------------------------------------------------------------------------------
;	clientSendGameChat - sends mcPlay/$0E (GameChat), payload is
;	edit_play_text_buf verbatim (page_play's in-game chat box - see
;	clientPlayTextChng above) - no room name or username needed
;	(unlike clientSendRoomPeer/mcLoby/$04), since ProcessPlayerMessage
;	is only ever reached for players already in this game, and the
;	server stamps the sender name itself (see SendGameChat).
;-------------------------------------------------------------------------------
clientSendGameChat:
;-------------------------------------------------------------------------------
		JSR	inetGetNextSend
		BCC	@failed

		LDA	#MSG_CATG_PLAY
		ORA	#$0E
		JSR	strsAppendChar

		LDAX	#edit_play_text_buf
		JSR	strsAppendString

		DEC	tempdat0
		LDA	tempdat0
		LDY	#$00
		STA	(tempptr0), Y

		RTS

@failed:
		JSR	clientNotifyFail

		RTS
;-------------------------------------------------------------------------------
screenIsRevColour:
;-------------------------------------------------------------------------------
		PHA
		LDA	#$20
		STA	tempbit0
		PLA

		CMP	#$01
		BMI	@text
	
		CMP	#$10
		BMI	@ctrl

		BIT	tempbit0
		BEQ	@text

@ctrl:
		SEC
		RTS
		
@text:
		CLC
		RTS


;-------------------------------------------------------------------------------
screenCtrlToLogClr:
;-------------------------------------------------------------------------------
		PHA
		LDA	#$30
		STA	tempbit0
		PLA

		BIT	tempbit0
		BEQ	@ctrl
		
		AND	#$0F
		RTS
		
@ctrl:
		CMP	#CLR_BACK
		BNE	@other
		
		LDA	#$00
		RTS
		
@other:
		TAX
		INX
		INX
		LDA	current_clrs, X
		RTS
		
		
	.export	screenASCIIToScreen
;-------------------------------------------------------------------------------
screenASCIIToScreen:
;-------------------------------------------------------------------------------
		STA	tempvar_z
		LDY	#$07
@loop:
		LDA	screenASCIIXLAT, Y
		CMP	tempvar_z
		BEQ	@subst
		DEY
		BPL	@loop

		LDA	tempvar_z
		
		CMP	#$20
		BCS	@regular

@irregular:
		LDA	#$66
		RTS

@regular:
		CMP	#$7F
		BCS	@irregular

		CMP	#$40
		BCC	@exit
	
		CMP	#$60
		BCC	@upper
	
		SEC
		SBC	#$60
		
		RTS

@upper:
		SEC
		SBC	#$40
		
@exit:
		RTS

@subst:
		LDA	screenASCIIXLATSub, Y
		RTS


;-------------------------------------------------------------------------------
;	Every ASCII->screen-code translation goes through this indirect
;	call instead of JSR'ing screenASCIIToScreen straight, so switching
;	fonts is just a case of pointing screenCharXlatVec at a different
;	routine (see screenASCIIToScreenXirod below) rather than checking a
;	flag on every character drawn.
;-------------------------------------------------------------------------------
screenCharXlatVec:
		.word	screenASCIIToScreen

	.export	screenCharXlat
screenCharXlat:
		JMP	(screenCharXlatVec)


;-------------------------------------------------------------------------------
;	Character->screen-code translation for the Xirod font (see
;	fontLoadXirod) - turns out the font maps ASCII values onto PETSCII
;	_screen codes_, same as screenASCIIToScreen above, not raw ASCII
;	identity - so the letter/digit arithmetic here is identical to it.
;	The only difference is the 8 "special" characters PETSCII has no
;	real glyph for (see screenASCIIXLAT below screenASCIIToScreen, used
;	as the shared search/key table here too) - Xirod draws real glyphs
;	for those, but NOT at their raw ASCII value like the letters/digits
;	- confirmed on hardware: \ is $1C, ^ is $1E, _ is $1F, ` is $40,
;	{ is $5B, | is $5C, } is $5D, ~ is $5E (see screenASCIIXLATSubXirod).
;	Uppercase 'Q' lands on screen code $11 via the same arithmetic as
;	every other letter - that's the slot getting repurposed as the dot.
;-------------------------------------------------------------------------------
screenASCIIToScreenXirod:
		STA	tempvar_z
		LDY	#$07
@loop:
		LDA	screenASCIIXLAT, Y
		CMP	tempvar_z
		BEQ	@subst
		DEY
		BPL	@loop

		LDA	tempvar_z

		CMP	#$20
		BCS	@regular

@irregular:
		LDA	#$66
		RTS

@regular:
		CMP	#$7F
		BCS	@irregular

		CMP	#$40
		BCC	@exit

		CMP	#$60
		BCC	@upper

		SEC
		SBC	#$60

		RTS

@upper:
		SEC
		SBC	#$40

@exit:
		RTS

@subst:
		LDA	screenASCIIXLATSubXirod, Y
		RTS


;-------------------------------------------------------------------------------
colourSchemeSelect:
;-------------------------------------------------------------------------------
		TAY
		
		LDA	#<clrschme_lst
		STA	tempptr0
		LDA	#>clrschme_lst
		STA	tempptr0 + 1
		
		TYA
		ASL
		ASL
		TAY
		
		LDA	(tempptr0), Y
		STA	tempptr1
		INY
		LDA	(tempptr0), Y
		STA	tempptr1 + 1 
	
		LDY	#$09
@loop:
		LDA	(tempptr1), Y
		STA	current_clrs, Y
		
		DEY
		BPL	@loop
		
		LDA	#$00
		STA	vicBkgdClr
		STA	vicSprClr0
		
		LDY	#$00
		LDA	current_clrs, Y
		STA	vicBrdrClr
		
		INY
		LDA	current_clrs, Y
		STA	vicSprClr3		
		
		LDY	#$03
		LDA	current_clrs, Y
		STA	vicSprClr1

		LDY	#$06
		LDA	current_clrs, Y
		STA	vicSprClr2
		
		RTS


;-------------------------------------------------------------------------------
strsAppendChar:
;-------------------------------------------------------------------------------
		LDY	tempdat0
		STA	(tempptr0), Y

		INC	tempdat0

		RTS


;-------------------------------------------------------------------------------
strsAppendString:
;-------------------------------------------------------------------------------
		STA	tempptr1
		STX	tempptr1 + 1

		LDY	#$00

@loop:
		LDA	(tempptr1), Y
		BEQ	@exit

		INY
		STY	tempdat3

		LDY	tempdat0
		STA	(tempptr0), Y
		INY
		STY	tempdat0

		LDY	tempdat3

		JMP	@loop

@exit:
		RTS


;-------------------------------------------------------------------------------
strsAppendParam:
;-------------------------------------------------------------------------------
		STA	tempptr1
		STX	tempptr1 + 1

		LDY	tempdat3

@loop:
		LDA	(tempptr1), Y
		CMP	#KEY_ASC_SPACE
		BEQ	@exit

		INY
		STY	tempdat3

		LDY	tempdat0
		STA	(tempptr0), Y
		INY
		STY	tempdat0

		LDY	tempdat3

		JMP	@loop

@exit:
		RTS


;-------------------------------------------------------------------------------
;	Every caller of strsAppendMessage fills a fixed-size log-panel line
;	buffer (.res 41 - 40 visible columns + 1 null terminator, e.g.
;	cnct_log_line0). Stopping the copy once tempdat0 reaches this
;	leaves exactly the 1 byte callers need for their own trailing
;	strsAppendChar #$00 - without it, a line too long (a long poem
;	verse, chat message, etc) silently overruns into the NEXT line's
;	buffer with no warning at all.
LOGLINE_MAX = 40

;	Same idea as LOGLINE_MAX above, but for lpanel_detail_log's
;	narrower 21-column width - see clientProcPlayGameChatMsg, which
;	can't use strsAppendMessage/strsAppendWrapped for its text since
;	both are hardcoded to LOGLINE_MAX's 40.
DETAIL_LOGLINE_MAX = 21

strsAppendMessage:
;-------------------------------------------------------------------------------
;	Bound checked BEFORE each copy (not just via an exact-match exit)
;	so an empty tail - tempdat1 already at or past readmsglen, e.g. a
;	Data message whose text param is empty - can't make Y overshoot
;	readmsglen and run away copying garbage for up to 256 bytes before
;	accidentally landing back on an exact match. Also capped against
;	LOGLINE_MAX so an over-length message can't overrun the
;	destination buffer either.
		LDY	tempdat1
		CPY	readmsglen
		BCS	@done

		LDY	tempdat0
		CPY	#LOGLINE_MAX
		BCS	@done

;	count = min(bytes of room left in the destination line,
;	bytes remaining unread in readmsg0) - both are >= 1 here, so the
;	DMA job below never runs with a zero count.
		LDA	readmsglen
		SEC
		SBC	tempdat1
		STA	dmaCnt

		LDA	#LOGLINE_MAX
		SEC
		SBC	tempdat0
		CMP	dmaCnt
		BCS	@havecnt

		STA	dmaCnt

@havecnt:
		LDA	tempptr0
		CLC
		ADC	tempdat0
		STA	dmaDst
		LDA	tempptr0 + 1
		ADC	#$00
		STA	dmaDst + 1

		LDA	#<readmsg0
		CLC
		ADC	tempdat1
		STA	dmaSrc
		LDA	#>readmsg0
		ADC	#$00
		STA	dmaSrc + 1

		JSR	dmaCopyRow

		LDA	dmaCnt
		CLC
		ADC	tempdat0
		STA	tempdat0
		LDA	dmaCnt
		CLC
		ADC	tempdat1
		STA	tempdat1

@done:
		RTS


;-------------------------------------------------------------------------------
;	Wraps an arbitrary-length null-terminated string (AX) across the
;	current log line and, if it doesn't fit, additional lines obtained
;	via ctrlsLogPanelGetNextLine - each continuation line is prefixed
;	"/ " to match the motd/README.txt convention. Unlike the poem text
;	(pre-wrapped by hand at file-authoring time), chat text arrives at
;	whatever length another client sent (up to readmsg0's 100 bytes),
;	so the client has to wrap it itself. Caller must still close out
;	the final line with its own trailing strsAppendChar #$00, same as
;	after strsAppendString/strsAppendMessage.
strsAppendWrapped:
;-------------------------------------------------------------------------------
		STA	tempptr3
		STX	tempptr3 + 1

@loop:
		LDY	#$00
		LDA	(tempptr3), Y
		BEQ	@done

		LDA	tempdat0
		CMP	#LOGLINE_MAX
		BCC	@haveroom

;	Current line full - close it out and continue on a new one
		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_wrap_pref
		JSR	strsAppendString

@haveroom:
		LDY	#$00
		LDA	(tempptr3), Y

		LDY	tempdat0
		STA	(tempptr0), Y
		INY
		STY	tempdat0

		INW	tempptr3
		JMP	@loop

@done:
		RTS


;-------------------------------------------------------------------------------
strsAppendInteger:
;-------------------------------------------------------------------------------
                ; print 16 bit number in AX as a decimal number
;hex to bcd routine taken from Andrew Jacob's code at http://www.6502.org/source/integers/hex2dec-more.htm
		STAX 	temp_bin
		SED                           ; Switch to decimal mode
		LDA 	#0                        ; Ensure the result is clear		
		STA 	temp_bcd
		STA 	temp_bcd+1
		STA 	temp_bcd+2
		LDX 	#16                       ; The number of source bits
: 
		ASL 	temp_bin+0                ; Shift out one bit
		ROL 	temp_bin+1
		LDA 	temp_bcd+0                ; And add into result
		ADC 	temp_bcd+0
		STA 	temp_bcd+0
		LDA 	temp_bcd+1                ; propagating any carry
		ADC 	temp_bcd+1
		STA 	temp_bcd+1
		LDA 	temp_bcd+2                ; ... thru whole result
		ADC 	temp_bcd+2
		STA 	temp_bcd+2

		DEX                           ; And repeat for next bit
		BNE 	:-

		STX 	temp_bin+1                ; x is now zero - reuse temp_bin as a count of non-zero digits
		CLD                           ; back to binary
		LDX 	#2
		STX 	temp_bin+1                ; reuse temp_bin+1 as loop counter
@print_one_byte:
		LDX 	temp_bin+1
		LDA 	temp_bcd,x
		PHA
		LSR
		LSR
		LSR
		LSR
		JSR 	@print_one_digit
		PLA
		AND 	#$0F
		JSR 	@print_one_digit
		DEC 	temp_bin+1
		BPL 	@print_one_byte
		RTS

@print_one_digit:
		CMP 	#0
		BEQ 	@this_digit_is_zero
		INC 	temp_bin                  ; increment count of non-zero digits
@ok_to_print:
		CLC
		ADC 	#'0'
		JSR 	strsAppendChar
		RTS
@this_digit_is_zero:
		LDX 	temp_bin                  ; how many non-zero digits have we printed?
		BNE 	@ok_to_print
		LDX 	temp_bin+1                ; how many digits are left to print?
		BNE 	@this_is_not_last_digit
		INC 	temp_bin                  ; to get to this point, this must be the high nibble of the last byte.
                                ; by making 'count of non-zero digits' to be >0, we force printing of the last digit
@this_is_not_last_digit:
		RTS


;-------------------------------------------------------------------------------
strsAppendHex:
;-------------------------------------------------------------------------------
		PHA
		PHA
		LSR
		LSR
		LSR
		LSR
		TAX
		LDA 	hexdigits, X
		JSR 	strsAppendChar
		PLA
		AND 	#$0F
		TAX
		LDA 	hexdigits, X
		JSR 	strsAppendChar
		PLA
		RTS


;-------------------------------------------------------------------------------
strsAppendDottedQuad:
;-------------------------------------------------------------------------------
		STA 	tempptr1
		STX 	tempptr1 + 1
		LDA 	#0
@print_one_byte:
		PHA
		TAY
		LDA 	(tempptr1), Y
		LDX 	#0
		JSR 	strsAppendInteger
		PLA
		CMP 	#3
		BEQ 	@done
		CLC
		ADC 	#1
		PHA
		LDA 	#'.'
		JSR 	strsAppendChar
		PLA
		BNE 	@print_one_byte
@done:
		RTS


	.export	msgsPushChanging
;-------------------------------------------------------------------------------
msgsPushChanging:
;-------------------------------------------------------------------------------
		LDY	msgs_change_idx	

		LDA	elemptr0
		STA	msgs_change, Y
		INY
		LDA	elemptr0 + 1
		STA	msgs_change, Y
		INY
		LDA	msgsdat0
		STA	msgs_change, Y
		INY
		LDA	msgsdat1
		STA	msgs_change, Y
		INY
		
		STY	msgs_change_idx	

	.if	DEBUG_MSGSPUSHSZ
		BNE	@exit
		
		LDA	#$02
		STA	vicBrdrClr
		LDA	#$03
		STA	vicBkgdClr
		
		JMP	mainPanic

@exit:
	.endif

		RTS


	.export	msgsPushInvalid
;-------------------------------------------------------------------------------
msgsPushInvalid:
;-------------------------------------------------------------------------------
		LDY	msgs_dirty_idx	

		LDA	elemptr0
		STA	msgs_dirty, Y
		INY
		LDA	elemptr0 + 1
		STA	msgs_dirty, Y
		INY
		LDA	msgsdat0
		STA	msgs_dirty, Y
		INY
		LDA	msgsdat1
		STA	msgs_dirty, Y
		INY
		
		STY	msgs_dirty_idx	

	.if	DEBUG_MSGSPUSHSZ
		BNE	@exit
		
		LDA	#$02
		STA	vicBrdrClr
		LDA	#$04
		STA	vicBkgdClr

		JMP	mainPanic

@exit:
	.endif
		RTS


;-------------------------------------------------------------------------------
ctrlsLockAcquire:
;-------------------------------------------------------------------------------
		SEI
		LDA	#$01
		STA	ctrlsLock

		INC	ctrlsLCnt

		CLI

		RTS


;-------------------------------------------------------------------------------
ctrlsLockRelease:
;-------------------------------------------------------------------------------
		SEI

		DEC	ctrlsLCnt
		LDA	ctrlsLCnt
		BNE	@exit
		
		LDA	#$00
		STA	ctrlsLock

@exit:
		CLI

		RTS


;-------------------------------------------------------------------------------
ctrlsUnDownCtrl:
;-------------------------------------------------------------------------------
		LDA	downCtrl + 1
		BEQ	@exit

		LDA	downCtrl
		STA	elemptr0
		LDA	downCtrl + 1
		STA	elemptr0 + 1

		LDA	#STATE_DOWN
		JSR	ctrlsExcludeState

		LDA	#$00
		STA	downCtrl
		STA	downCtrl + 1

;	Stop the blinking cursor. If it's currently sitting reversed
;	(crsr_on), one more XOR $80 undoes the last one and leaves the
;	cell normal, and the colour needs putting back to the control's
;	own (it's currently CLR_FOCUS from the blink) - elemptr0 still
;	points at the control that was downCtrl, above.
		LDA	crsr_active
		BEQ	@exit

		LDA	#$00
		STA	crsr_active

		LDA	crsr_on
		BEQ	@exit

		LDY	crsr_row
		LDA	screenRowsLo, Y
		STA	tempptr1
		LDA	screenRowsHi, Y
		STA	tempptr1 + 1
		LDA	#$01			;bank - screen RAM is at $010000
		STA	tempptr1 + 2
		LDA	#$00			;top
		STA	tempptr1 + 3

		LDZ16	crsr_col
		LDQ	tempptr1
		EOR	#$80
		STQ	tempptr1

		LDX	crsr_row
		LDA	screenRowsLo, X
		STA	tempptr1
		LDA	colourRowsHiPhys, X
		STA	tempptr1 + 1
		LDA	#$01			;bank - colour RAM's real physical
		STA	tempptr1 + 2		;	address is $01F800, not $D800
		LDA	#$00			;top
		STA	tempptr1 + 3

		LDY	#ELEMENT::colour
		LDA	(elemptr0), Y
		JSR	screenCtrlToLogClr

		STCOLR16 tempptr1, crsr_col

@exit:
		RTS


;-------------------------------------------------------------------------------
ctrlsDownCtrl:
;-------------------------------------------------------------------------------
		LDA	elemptr0
		STA	tempptr0
		LDA	elemptr0 + 1
		STA	tempptr0 + 1

		JSR	ctrlsUnDownCtrl

;	If this control is already the active one, skip cycling it through
;	deactivate/reactivate below - besides being unnecessary, doing so
;	is what caused infinite recursion with ctrlsActivateCtrlSimple's
;	"auto-down on activate" hook calling straight back into here.
		LDA	tempptr0
		CMP	actvCtrl
		BNE	@notactv0
		LDA	tempptr0 + 1
		CMP	actvCtrl + 1
		BEQ	@nodeact

@notactv0:
		LDY	#ELEMENT::options
		LDA	(tempptr0), Y
		AND	#OPT_NONAVIGATE
		BNE	@nodeact

		JSR	ctrlsDeactivateCtrl

@nodeact:
		LDA	tempptr0
		STA	elemptr0
		LDA	tempptr0 + 1
		STA	elemptr0 + 1

		LDA	#STATE_DOWN
		JSR	ctrlsIncludeState

		LDA	elemptr0
		STA	downCtrl
		LDA	elemptr0 + 1
		STA	downCtrl + 1

		LDA	elemptr0
		CMP	actvCtrl
		BNE	@notactv1
		LDA	elemptr0 + 1
		CMP	actvCtrl + 1
		BEQ	@noact

@notactv1:
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_NONAVIGATE
		BNE	@noact

		JSR	ctrlsActivateCtrl

@noact:
		RTS


;-------------------------------------------------------------------------------
ctrlsDeactivateCtrl:
;-------------------------------------------------------------------------------
		LDA	actvCtrl + 1
		BEQ	@exit

		STA	elemptr0 + 1
		LDA	actvCtrl
		STA	elemptr0

		LDA	#STATE_ACTIVE
		JSR	ctrlsExcludeState

		LDA	#$00
		STA	actvCtrl
		STA	actvCtrl + 1

@exit:
		RTS


;-------------------------------------------------------------------------------
ctrlsActivateCtrlSimple:
;-------------------------------------------------------------------------------
		LDA	elemptr0
		STA	tempptr0
		LDA	elemptr0 + 1
		STA	tempptr0 + 1

		JSR	ctrlsDeactivateCtrl
		
		LDA	tempptr0
		STA	elemptr0
		LDA	tempptr0 + 1
		STA	elemptr0 + 1

		LDA	#STATE_ACTIVE
		JSR	ctrlsIncludeState

		LDA	elemptr0
		STA	actvCtrl
		LDA	elemptr0 + 1
		STA	actvCtrl + 1

;	Text-entry controls go straight into edit mode when activated
;	(so e.g. TAB'ing onto one can be typed into immediately), unless
;	they opt out with OPT_NODOWNACTV.
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#(OPT_CAPTURECRSR | OPT_NODOWNACTV)
		CMP	#OPT_CAPTURECRSR
		BNE	@exit

		JSR	ctrlsDownCtrl

@exit:
		RTS


;-------------------------------------------------------------------------------
ctrlsActivateCtrl:
;-------------------------------------------------------------------------------
		JSR	ctrlsActivateCtrlSimple
		
		LDY	#CONTROL::panel
		LDA	(elemptr0), Y
		STA	tempptr0
		INY
		LDA	(elemptr0), Y
		STA	tempptr0 + 1
		
		LDY	#PANEL::controls
		LDA	(tempptr0), Y
		STA	tempptr1
		INY
		LDA	(tempptr0), Y
		STA	tempptr1 + 1
		
		LDY	#$00
@loopc:
		STY	actvctrlc
		
		LDA	(tempptr1), Y
		INY
		
		CMP	elemptr0
		BNE	@nextc
		
		LDA	(tempptr1), Y
		BEQ	@donec
		
		CMP	elemptr0 + 1
		BEQ	@donec
		
@nextc:
		INY
		JMP	@loopc
		
@donec:
		LDY	#PANEL::page
		LDA	(tempptr0), Y
		STA	tempptr1
		INY
		LDA	(tempptr0), Y
		STA	tempptr1 + 1
		
		LDY	#PAGE::panels
		LDA	(tempptr1), Y
		STA	tempptr2
		INY
		LDA	(tempptr1), Y
		STA	tempptr2 + 1
		
		LDY	#$00
@loopp:
		STY	actvctrlp
		
		LDA	(tempptr2), Y
		INY
		
		CMP	tempptr0
		BNE	@nextp
		
		LDA	(tempptr2), Y
		BEQ	@donep
		
		CMP	tempptr0 + 1
		BEQ	@donep
		
@nextp:
		INY
		JMP	@loopp
		
@donep:
		RTS


	.export	ctrlsControlInvalidate
;-------------------------------------------------------------------------------
ctrlsControlInvalidate:
;-------------------------------------------------------------------------------
;	Only invalidate elements NOT already STATE_DIRTY

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DIRTY
		BNE	@exit

;	Only invalidate elements with STATE_PREPARED

		LDA	(elemptr0), Y
		AND	#STATE_PREPARED
		BEQ	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_DIRTY
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat0
		STA	msgsdat1

		JSR	msgsPushInvalid
		
@exit:
		RTS


;-------------------------------------------------------------------------------
ctrlsExcludeState:
;-------------------------------------------------------------------------------
;	Builds/sends a state-change message internally (msgsPushChanging),
;	which reuses msgsdat0/msgsdat1 as scratch for it - push/pop them so
;	a message the caller is still in the middle of processing survives
;	a call to this.
		STA	tempdat0
		EOR	#$FF
		STA	tempdat1

		LDA	msgsdat0
		PHA
		LDA	msgsdat1
		PHA

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	tempdat0
		BEQ	@exit

		LDA	(elemptr0), Y
		STA	msgsdat0
		AND	tempdat1
		STA	(elemptr0), Y

		AND	#STATE_CHANGED
		BNE	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_CHANGED
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat1

		JSR	msgsPushChanging

@exit:
		PLA
		STA	msgsdat1
		PLA
		STA	msgsdat0

		RTS


;-------------------------------------------------------------------------------
ctrlsIncludeState:
;-------------------------------------------------------------------------------
;	Builds/sends a state-change message internally (msgsPushChanging),
;	which reuses msgsdat0/msgsdat1 as scratch for it - push/pop them so
;	a message the caller is still in the middle of processing survives
;	a call to this.
		STA	tempdat0

		LDA	msgsdat0
		PHA
		LDA	msgsdat1
		PHA

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	tempdat0
		BNE	@exit

		LDA	(elemptr0), Y
		STA	msgsdat0
		ORA	tempdat0
		STA	(elemptr0), Y

		AND	#STATE_CHANGED
		BNE	@exit

		LDA	(elemptr0), Y
		ORA	#STATE_CHANGED
		STA	(elemptr0), Y

		LDA	#$00
		STA	msgsdat1

		JSR	msgsPushChanging

@exit:
		PLA
		STA	msgsdat1
		PLA
		STA	msgsdat0

		RTS


	.export	ctrlsDrawAccel
;-------------------------------------------------------------------------------
ctrlsDrawAccel:
;-------------------------------------------------------------------------------
		LDY	#CONTROL::textaccel
		LDA	(elemptr0), Y
		CMP	#$FF
		BEQ	@exit

		STA	tempvar_c

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_ENABLED
		BEQ	@exit

		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		
		CLC
		ADC	tempvar_c
		STA	tempvar_a		;x + textaccel
		
		INY
		LDA	(elemptr0), Y
		STA	tempvar_b		;y
		
		LDA	#CLR_FOCUS
		JSR	screenCtrlToLogClr	
		STA	tempvar_e		;logical colour

		LDX	tempvar_b
		LDA	screenRowsLo, X
		STA	tempptr1		;colour ptr
		LDA	colourRowsHiPhys, X
		STA	tempptr1 + 1
		LDA	#$01			;bank - colour RAM's real physical
		STA	tempptr1 + 2		;	address is $01F800, not $D800
		LDA	#$00			;top
		STA	tempptr1 + 3

		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_TEXTACCEL2X
		STA	tempvar_d

		LDA	tempvar_e
		STCOLR16 tempptr1, tempvar_a

		LDX	tempvar_d
		BEQ	@exit

		INC	tempvar_a
		LDA	tempvar_e
		STCOLR16 tempptr1, tempvar_a

@exit:
		RTS


	.export	ctrlsEraseBkg
;-------------------------------------------------------------------------------
ctrlsEraseBkg:
;-------------------------------------------------------------------------------
		STA	tempvar_e		;colour

		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		STA	tempvar_a		;x
		INY
		LDA	(elemptr0), Y
		STA	tempvar_b		;y
		INY
		LDA	(elemptr0), Y
		STA	tempvar_c		;w
		INY
		LDA	(elemptr0), Y
		STA	tempvar_d		;h
		
		LDA	tempvar_e
		
		JSR	screenIsRevColour
		BCC	@text
		
		LDA	#$A0
		JMP	@cont
		
@text:
		LDA	#$20
		
@cont:
		STA	tempvar_f		;background char

		LDA	tempvar_e
		JSR	screenCtrlToLogClr	
		STA	tempvar_e		;logical colour

@looph:
;	Column -> byte offset is column*2 now (CHR16/FCLRHI cells are 2
;	bytes). dest-skip=2 already advances the destination by 2 bytes
;	per write, so dmaCnt is the cell count (width) unscaled.
		LDA	tempvar_a
		ASL
		STA	tempvar_h		;doubled column, shared below

		LDA	tempvar_c
		STA	tempvar_i		;width (dmaCnt), shared below
;	CRITICAL: a DMA job count of 0 is a real hardware hazard on this
;	platform (not a harmless no-op) - never let a zero-width call
;	reach dmaFillRow.
		BEQ	@skipclr

		LDX	tempvar_b
		LDA	screenRowsLo, X
		STA	tempvar_g		;low byte shared by screen & colour rows
		CLC
		ADC	tempvar_h
		STA	dmaDst
		LDA	screenRowsHi, X
		ADC	#$00
		STA	dmaDst + 1

		LDA	#$01			;bank - screen RAM is at $010000
		STA	dmaDstBank

		LDA	tempvar_i
		STA	dmaCnt

		LDA	tempvar_f		;char to screen ram
		JSR	dmaFillRow

;	+1 because under FCLRHI the system colour value lives in the HIGH
;	byte of a colour cell (see STCOLR16) - the low byte stays whatever
;	initMem's boot-time zero-fill left it as.
		INC	tempvar_h

		LDA	tempvar_g
		CLC
		ADC	tempvar_h
		STA	dmaDst
		LDA	colourRowsHiPhys, X
		ADC	#$00
		STA	dmaDst + 1

		LDA	#$01			;colour RAM's real physical
		STA	dmaDstBank		;address is $01F800, not $D800

		LDA	tempvar_i
		STA	dmaCnt

		LDA	tempvar_e		;colour to colour ram
		AND	#$0F
		JSR	dmaFillRow

@skipclr:
		INC	tempvar_b
		DEC	tempvar_d
		LDA	tempvar_d
		BNE	@looph

		RTS


;-------------------------------------------------------------------------------
ctrlsDrawText:
;	IN	tempdat0	Colour
;	IN	tempdat1	Indent
;	IN	tempdat2	Max width
;	IN	tempdat3	Do cont char if opt
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		STA	tempvar_a		;x
		INY
		LDA	(elemptr0), Y
		STA	tempvar_b		;y
		INY
		
		LDY	#CONTROL::textptr
		LDA	(elemptr0), Y
		STA	tempptr1		;text lo
		INY
		LDA	(elemptr0), Y
		
		BNE	@calc0
		
;		JMP	@exit
		RTS
		
@calc0:
		STA	tempptr1 + 1		;text hi
		INY
		LDA	(elemptr0), Y		;
		STA	tempvar_d		;text off x


;---	Not doing accelerators here anymore
;		INY
;		LDA	(elemptr0), Y		;text accel
;		
;		CMP	#$FF
;		BEQ	@cont0
;		
;@wantaccel:
;		CLC
;		ADC	tempvar_a
;
;@cont0:
;		STA	tempvar_c		;text accel x/off
;---

;-------------------------------------------------------------------------------
ctrlsDrawTextDirect:
;	IN	tempdat0	Colour
;	IN	tempdat1	Indent
;	IN	tempdat2	Max width
;	IN	tempdat3	Do cont char if opt
;	IN	tempvar_a	x pos
;	IN	tempvar_b	y pos
;	IN	tempvar_d	text off x
;	IN	tempptr1	text pointer
;-------------------------------------------------------------------------------

		CLC
		LDA	tempvar_d
		ADC	tempvar_a
		STA	tempvar_a		;x

		LDA	tempdat0
		JSR	screenIsRevColour
		BCC	@text
		
		LDA	#$80
		JMP	@cont1
		
@text:
		LDA	#$00
		
@cont1:
		STA	tempvar_f		;char or

		LDX	tempvar_b
		LDA	screenRowsLo, X
		STA	tempptr0		;screen ptr
		LDA	screenRowsHi, X
		STA	tempptr0 + 1
		LDA	#$01			;bank - screen RAM is at $010000
		STA	tempptr0 + 2
		LDA	#$00			;top
		STA	tempptr0 + 3

		LDA	tempdat3
		BEQ	@cont2
	
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_TEXTCONTMRK
		BEQ	@cont2

		DEC	tempdat2

@cont2:
		LDA	tempdat1		;text indent
		STA	tempvar_e

		LDX	#$00
	
@loopw:
		LDY	tempvar_e
		LDA	(tempptr1), Y		;char 
		
		BEQ	@exit
		
		JSR	screenCharXlat
		ORA	tempvar_f

		STCELL16 tempptr0, tempvar_a

		INC	tempvar_a
		INC	tempvar_e

		INX
		CPX	tempdat2
		BCS	@contchk

		JMP	@loopw

@contchk:
		LDA	tempdat3
		BEQ	@exit

		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_TEXTCONTMRK
		BEQ	@exit

		LDA	#'>'
		JSR	screenCharXlat
		ORA	tempvar_f

		STCELL16 tempptr0, tempvar_a

@exit:
		RTS
		
		
;-------------------------------------------------------------------------------
;	screenClearHiBytes - zeroes the high byte of all 1000 screen cells
;	in a single DMA job, undoing whatever 16-bit tile indices (the
;	chess piece graphics) might have been drawn. Screen RAM's 2000
;	bytes are contiguous (see screenRowsLo/Hi's stride), so dest-
;	skip=2 starting at cell 0's high byte, running the full width in
;	one shot, covers the entire screen - see screenHiBytesUsed, which
;	gates the call to this in ctrlsPageSelect below.
;-------------------------------------------------------------------------------
screenClearHiBytes:
;-------------------------------------------------------------------------------
		STA	$D707
		.byte	$85, $02	;dest skip = 2 - high bytes only
		.byte	$00		;end of job options
		.byte	$03		;fill
		.word	1000		;count - one per screen cell (40x25)
		.word	$0000		;value (fill byte in low byte)
		.byte	$00		;src bank
		.word	$0001		;dst - offset 1, cell 0's high byte
		.byte	$01		;dst bank - screen RAM is at $010000
		.byte	$00		;cmd hi
		.word	$0000		;modulo/ignored

		LDA	#$00
		STA	screenHiBytesUsed

		RTS


	.export	ctrlsPageSelect
;-------------------------------------------------------------------------------
ctrlsPageSelect:
;-------------------------------------------------------------------------------
;	Page/tab change - if anything's drawn a 16-bit tile since the last
;	one, sweep the whole screen's high bytes clean first so the page
;	we're switching to can't inherit a stale tile index.
		LDA	screenHiBytesUsed
		BEQ	@nohi

		JSR	screenClearHiBytes

@nohi:
		SEI
		LDA	#$01
		STA	ctrlsPrep
		CLI

;	Got a current page?

		LDA	pageptr0 + 1
		BEQ	@cont0

;	Hide the current page

		LDY	#ELEMENT::state
		LDA	(pageptr0), Y
		AND	#($FF ^ (STATE_VISIBLE | STATE_PREPARED))
		STA	(pageptr0), Y

;	Remove STATE_PREPARED from all page elements

;	Find last panel on page
		LDY	#PAGE::panels
		LDA	(pageptr0), Y
		STA	tempptr0
		INY
		LDA	(pageptr0), Y
		STA	tempptr0 + 1

		LDY	#PAGE::panlcnt
		LDA	(pageptr0), Y
		ASL
		STA	tempvar_a
		DEC	tempvar_a

@panel0:
;	for each panel on page rev
		LDY	tempvar_a

		LDA	(tempptr0), Y
		STA	tempptr1 + 1
		DEY
		LDA	(tempptr0), Y
		STA	tempptr1
		DEY
		
		STY	tempvar_a

		LDY	#ELEMENT::state
		LDA	(tempptr1), Y
		AND	#$FF ^ STATE_PREPARED
		STA	(tempptr1), Y
		
;	for each elem in panel 

		LDY	#PANEL::controls
		LDA	(tempptr1), Y
		STA	tempptr2
		INY
		LDA	(tempptr1), Y
		STA	tempptr2 + 1

		LDY	#$00
		
@elem0:
		LDA	(tempptr2), Y
		STA	tempptr3
		INY
		LDA	(tempptr2), Y
		BEQ	@panelnext
		
		STA	tempptr3 + 1
		INY
		
		STY	tempvar_b

		LDY	#ELEMENT::state
		LDA	(tempptr3), Y
		AND	#$FF ^ STATE_PREPARED
		STA	(tempptr3), Y

@elemnext:
		LDY	tempvar_b
		JMP	@elem0

@panelnext:
		LDY	tempvar_a
		BMI	@cont0
		
		JMP	@panel0

@cont0:
;	Set the current page

		LDA	elemptr0
		STA	pageptr0
		LDA	elemptr0 + 1
		STA	pageptr0 + 1

		LDY	#ELEMENT::state
		LDA	(pageptr0), Y
		ORA	#STATE_VISIBLE | STATE_PREPARED
		STA	(pageptr0), Y

		LDY	#ELEMENT::tag
		LDA	(pageptr0), Y
		STA	currpgtag

;	Clear picked, down and active controls

		LDA	#$00
		STA	pickCtrl
		STA	pickCtrl + 1
		STA	downCtrl 
		STA	downCtrl + 1
		STA	actvCtrl
		STA	actvCtrl + 1

;	Copy header text

		LDY	#PAGE::textptr
		LDA	(pageptr0), Y
		STA	tempvar_a		;textptr lo
		INY
		LDA	(pageptr0), Y
		STA	tempvar_b		;textptr hi
		INY
		LDA	(pageptr0), Y
		STA	tempvar_c		;textoffx
		
		LDY	#CONTROL::textptr
		LDA	tempvar_a
		STA	hlabel_main_page, Y
		INY
		LDA	tempvar_b
		STA	hlabel_main_page, Y
		INY
		LDA	tempvar_c
		STA	hlabel_main_page, Y
		
;	Set-up the back and next buttons

		LDA	#$00
		STA	button_main_next + ELEMENT::state
		STA	button_main_back + ELEMENT::state

		LDY	#PAGE::nxtpage + 1
		LDA	(pageptr0), Y
		BEQ	@chkback
		
		STA	pageNext + 1
		DEY
		LDA	(pageptr0), Y
		STA	pageNext
		
		LDA	#STATE_VISIBLE | STATE_ENABLED
		STA	button_main_next + ELEMENT::state

@chkback:
		LDY	#PAGE::bakpage + 1
		LDA	(pageptr0), Y
		BEQ	@tabhdr
		
		STA	pageBack + 1
		DEY
		LDA	(pageptr0), Y
		STA	pageBack
		
		LDA	#STATE_VISIBLE | STATE_ENABLED
		STA	button_main_back + ELEMENT::state

@tabhdr:
		
;	Put tab header on page
		
		LDY	#PANEL::page
		LDA	pageptr0
		STA	tab_main, Y
		INY
		LDA	pageptr0 + 1
		STA	tab_main, Y

		RTS
	

;-------------------------------------------------------------------------------
ctrlsDisposeMsgs:
;-------------------------------------------------------------------------------
		LDA	msgs_change_idx
		BEQ	@dirty

		LDY	#$00

@loop0:
		LDA	msgs_change, Y
		STA	elemptr0
		INY
		LDA	msgs_change, Y
		STA	elemptr0 + 1
		INY
		INY
		INY
	
		STY	ctrlvar_a

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#($FF ^ STATE_CHANGED)
		STA	(elemptr0), Y

		LDY	ctrlvar_a
		CPY	msgs_change_idx
		BNE	@loop0
		
		LDA	#$00
		STA	msgs_change_idx

@dirty:
		LDA	msgs_dirty_idx
		BEQ	@exit

		LDY	#$00

@loop1:
		LDA	msgs_dirty, Y
		STA	elemptr0
		INY
		LDA	msgs_dirty, Y
		STA	elemptr0 + 1
		INY
		INY
		INY
	
		STY	ctrlvar_a

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#($FF ^ STATE_DIRTY)
		STA	(elemptr0), Y

		LDY	ctrlvar_a
		CPY	msgs_dirty_idx
		BNE	@loop1

		LDA	#$00
		STA	msgs_dirty_idx

@exit:
		RTS


	.export	ctrlsLogPanelInit
;-------------------------------------------------------------------------------
ctrlsLogPanelInit:
;-------------------------------------------------------------------------------
		LDY	#LOGPANEL::lines
		LDA	(tempptr2), Y
		STA	tempptr1
		INY
		LDA	(tempptr2), Y
		STA	tempptr1 + 1

		INY
		LDA	(tempptr2), Y		;linecnt
		ASL
		
		TAY
		DEY
@loop:
		LDA	(tempptr1), Y
		STA	tempptr0 + 1
		DEY
		LDA	(tempptr1), Y
		STA	tempptr0
		DEY

		TYA
		TAX

		LDA	#$00
		LDY	#$00
		STA	(tempptr0), Y
		
		TXA
		TAY

		BPL	@loop
		
		RTS


	.export	ctrlsLogPanelGetNextLine
;-------------------------------------------------------------------------------
ctrlsLogPanelGetNextLine:
;-------------------------------------------------------------------------------
		LDY	#LOGPANEL::currln
		LDA	(tempptr2), Y
		STA	tempvar_a

		INC	tempvar_a

		LDY	#LOGPANEL::lines
		LDA	(tempptr2), Y
		STA	tempptr1
		INY
		LDA	(tempptr2), Y
		STA	tempptr1 + 1

		INY
		LDA	(tempptr2), Y		;linecnt

		CMP	tempvar_a
		BCS	@havenext

		ASL	
		STA	tempvar_b
		DEC	tempvar_a

		LDY	#$00
		LDA	(tempptr1), Y
		STA	tempptr0
		INY
		LDA	(tempptr1), Y
		STA	tempptr0 + 1

		LDY	#$02
@loop:
		LDA	(tempptr1), Y
		STA	tempvar_c
		INY
		LDA	(tempptr1), Y
		STA	tempvar_d
		
		DEY
		DEY
		DEY
		
		LDA	tempvar_c
		STA	(tempptr1), Y
		INY
		LDA	tempvar_d
		STA	(tempptr1), Y
		
		INY
		INY
		INY

		CPY	tempvar_b
		BNE	@loop
	
		DEY
		DEY

		LDA	tempptr0
		STA	(tempptr1), Y
		INY
		LDA	tempptr0 + 1
		STA	(tempptr1), Y

@havenext:
		DEC	tempvar_a
		LDA	tempvar_a
		ASL	
		TAY

		LDA	(tempptr1), Y
		STA	tempptr0
		INY
 		LDA	(tempptr1), Y
		STA	tempptr0 + 1
		INY

		STY	tempvar_a
		
		LDA	#$00
		STA	tempdat0

		LDY	#LOGPANEL::currln
		LDA	tempvar_a
		LSR
		STA	(tempptr2), Y
		
		RTS

	
	.export	ctrlsLogPanelUpdate
;-------------------------------------------------------------------------------
ctrlsLogPanelUpdate:
;-------------------------------------------------------------------------------
		LDY	#PANEL::page
		LDA	(tempptr2), Y
		STA	tempptr1
		INY
		LDA	(tempptr2), Y
		STA	tempptr1 + 1

;		LDY	#ELEMENT::state
;		LDA	(tempptr1), Y
;		AND	#STATE_VISIBLE
;		BNE	@update

		CMP	pageptr0 + 1
		BNE	@hidden
		
		LDA	tempptr1
		CMP	pageptr0
		BNE	@hidden
		
		JMP	@update

@hidden:
		RTS

@update:
		JSR	ctrlsLockAcquire

		LDA	tempptr2
		STA	elemptr0
		LDA	tempptr2 + 1
		STA	elemptr0 + 1

		JSR	ctrlsControlInvalidate

		JSR	ctrlsLockRelease

		RTS

;-------------------------------------------------------------------------------
ctrlsPageChanged:
;-------------------------------------------------------------------------------
		LDY	#$00

@loop:
		LDA	msgs_change, Y
		STA	msgsptr0
		STA	elemptr0
		INY
		LDA	msgs_change, Y
		STA	msgsptr0 + 1
		STA	elemptr0 + 1
		INY
		LDA	msgs_change, Y
		STA	msgsdat0
		INY
		LDA	msgs_change, Y
		STA	msgsdat1
		INY
	
		STY	ctrlvar_a
		
		LDY	#ELEMENT::changed
		LDA	(elemptr0), Y
		STA	ctrlptr_a
		INY
		LDA	(elemptr0), Y
		STA	ctrlptr_a + 1
		
		BEQ	@def
		
		JSR	ctrlsProxyA
		JMP	@next
		
@def:
		JSR	ctrlsControlDefChanged
	
@next:	
		LDY	#ELEMENT::state
		LDA	(msgsptr0), Y
		AND	#($FF ^ STATE_CHANGED)
		STA	(msgsptr0), Y

		LDY	ctrlvar_a
		CPY	msgs_change_idx
		BNE	@loop
		
@exit:
		LDA	#$00
		STA	msgs_change_idx

		RTS


;-------------------------------------------------------------------------------
ctrlsLabelDefChanged:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		STA	tempdat0

		JSR	ctrlsControlDefChanged

		LDA	tempdat0
		AND	#STATE_DOWN
		BEQ	@exit
		
		LDY	#LABELCTRL::actvctrl
		LDA	(elemptr0), Y
		STA	tempptr0
		INY
		LDA	(elemptr0), Y
		STA	tempptr0 + 1
		
		LDA	tempptr0
		STA	elemptr0
		LDA	tempptr0 + 1
		STA	elemptr0 + 1
		
;		JSR	ctrlsActivateCtrl
		JSR	ctrlsDownCtrl

@exit:
		RTS
		

	.export	ctrlsPanelDefChanged
;-------------------------------------------------------------------------------
ctrlsPanelDefChanged:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_CHANGED
		BEQ	@exit
		
		LDA	(elemptr0), Y
		AND	#($FF ^ STATE_CHANGED)
		STA	(elemptr0), Y

		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		BEQ	@exit

		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_NOAUTOINVL
		BNE	@cont0

		JSR	ctrlsControlInvalidate

@cont0:
		LDY	#PANEL::ctrlcnt
		LDA	(elemptr0), Y
		BEQ	@exit
		
		ASL	
		TAX
		DEX
		
		LDY	#PANEL::controls
		LDA	(elemptr0) , Y
		STA	tempptr0
		INY
		LDA	(elemptr0) , Y
		STA	tempptr0 + 1
		
		TXA
		TAY

@loop:
		LDA	(tempptr0), Y
		STA	elemptr0 + 1
		DEY
		LDA	(tempptr0), Y
		STA	elemptr0
		
		TYA
		PHA
		
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		BEQ	@next

		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_NOAUTOINVL
		BNE	@next

		JSR	ctrlsControlInvalidate

@next:
		PLA
		TAY
		DEY
		BPL	@loop

@exit:
		RTS


	.export	ctrlsControlDefChanged
;-------------------------------------------------------------------------------
ctrlsControlDefChanged:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_CHANGED
		BEQ	@exit

		LDA	#$00
		STA	tempvar_a

		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BEQ	@dirty

		LDA	#$01
		STA	tempvar_a
		
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_DOWNCAPTURE
		BNE	@dirty

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#($FF ^ STATE_DOWN)
		STA	(elemptr0), Y

		LDA	#$00
		STA	downCtrl
		STA	downCtrl + 1

@dirty:
		LDY	#ELEMENT::options
		
		LDA	tempvar_a
		BEQ	@cont1

		LDA	(elemptr0), Y
		AND	#OPT_AUTOCHECK
		BEQ	@cont1
		
		LDY	#ELEMENT::tag
		LDA	(elemptr0), Y
		BEQ	@check
		
		LDA	#$00
		JMP	@cont0

@check:
		LDA	#$01
		
@cont0:
		STA	(elemptr0), Y
		
		LDY	#ELEMENT::options
@cont1:
		LDA	(elemptr0), Y
		AND	#OPT_NOAUTOINVL
		BNE	@exit

		JSR	ctrlsControlInvalidate
		
@exit:
		RTS


	.export	ctrlsMoveIsTarget
;-------------------------------------------------------------------------------
ctrlsMoveIsTarget:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_NONAVIGATE
		BNE	ctrlsMoveIsTargetNot

ctrlsMoveIsTargetPanel:
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		BEQ	ctrlsMoveIsTargetNot

		LDA	(elemptr0), Y
		AND	#STATE_ENABLED
		BEQ	ctrlsMoveIsTargetNot

		SEC
		RTS

ctrlsMoveIsTargetNot:
		CLC
		RTS


	.export	ctrlsMoveActiveControl
;-------------------------------------------------------------------------------
;	Wraps around every panel*control combination on the current page
;	looking for the next/previous ctrlsMoveIsTarget-eligible control -
;	see @moveup/@nextpnlup/@movedown/@nextpnldn below. Originally had no
;	termination condition for "searched everywhere, found nothing" -
;	harmless in chess (every page had at least one real button/
;	checkbox) but a genuine infinite loop (hang on TAB/cursor-up/down)
;	on any page with none, e.g. Snake QUADRO's board page or an
;	overview page that's just a highscore table with no interactive
;	controls (found live, 2026-08-24). Fixed with a flat iteration
;	cap (ctrlvar_e/CTRLS_NAV_GUARD_MAX) rather than exact starting-
;	position tracking - simpler to verify correct in this already
;	heavily register-optimised code, and the cost of a few hundred
;	wasted cycles in the genuinely-empty case is negligible.
;-------------------------------------------------------------------------------
ctrlsMoveActiveControl:
;-------------------------------------------------------------------------------
		LDA	#$00
		STA	ctrlvar_e

		LDY	#PAGE::panels
		LDA	(pageptr0), Y
		STA	ctrlptr0
		INY
		LDA	(pageptr0), Y
		STA	ctrlptr0 + 1

		LDY	actvctrlp
		STY	ctrlvar_a

		LDA	(ctrlptr0), Y
		STA	panlptr0
		INY
		LDA	(ctrlptr0), Y
		STA	panlptr0 + 1

		LDY	#PANEL::controls
		LDA	(panlptr0), Y
		STA	ctrlptr1
		INY
		LDA	(panlptr0), Y
		STA	ctrlptr1 + 1

		LDY	actvctrlc
		STY	ctrlvar_b

		LDA	msgsdat0
		CMP	#KEY_C64_CDOWN
		BNE	@moveup

		JMP	@movedown

@moveup:
		INC	ctrlvar_e
		LDA	ctrlvar_e
		CMP	#CTRLS_NAV_GUARD_MAX
		BCC	@moveupok
		RTS

@moveupok:
		LDY	ctrlvar_b
		BEQ	@nextpnlup

		DEY
		LDA	(ctrlptr1), Y
		STA	elemptr0 + 1
		DEY
		LDA	(ctrlptr1), Y
		STA	elemptr0

		STY	ctrlvar_b

		JSR	ctrlsMoveIsTarget
		BCC	@moveup

		JSR	ctrlsActivateCtrlSimple

		LDY	ctrlvar_b
;		INY
;		INY
		STY	actvctrlc

		LDY	ctrlvar_a
;		INY
;		INY
		STY	actvctrlp

		RTS

@nextpnlup:
		INC	ctrlvar_e
		LDA	ctrlvar_e
		CMP	#CTRLS_NAV_GUARD_MAX
		BCC	@nextpnlupok
		RTS

@nextpnlupok:
		LDY	ctrlvar_a
		BEQ	@uploop

		DEY
		LDA	(ctrlptr0), Y
		STA	panlptr0 + 1
		DEY
		LDA	(ctrlptr0), Y
		STA	panlptr0

		STY	ctrlvar_a
		
		LDA	panlptr0 + 1
		STA	elemptr0 + 1
		LDA	panlptr0
		STA	elemptr0

		JSR	ctrlsMoveIsTargetPanel
		BCC	@nextpnlup		
		
		JMP	@uplast

@uploop:
		LDY	#PAGE::panlcnt
		LDA	(pageptr0), Y
		ASL
;		STA	ctrlvar_a

		TAY
		
		DEY
		LDA	(ctrlptr0), Y
		STA	panlptr0 + 1
		STA	elemptr0 + 1
		DEY
		LDA	(ctrlptr0), Y
		STA	panlptr0
		STA	elemptr0

		STY	ctrlvar_a

		JSR	ctrlsMoveIsTargetPanel
		BCC	@nextpnlup		

@uplast:
		LDY	#PANEL::controls
		LDA	(panlptr0), Y
		STA	ctrlptr1
		INY
		LDA	(panlptr0), Y
		STA	ctrlptr1 + 1

		LDY	#PANEL::ctrlcnt
		LDA	(panlptr0), Y
		BEQ	@nextpnlup
		ASL
		STA	ctrlvar_b

		JMP	@moveup
			
@movedown:
		INC	ctrlvar_e
		LDA	ctrlvar_e
		CMP	#CTRLS_NAV_GUARD_MAX
		BCC	@movedownok
		RTS

@movedownok:
		LDY	#PANEL::ctrlcnt
		LDA	(panlptr0), Y
		TAY
		DEY
		TYA
		ASL
		CMP	ctrlvar_b
		BEQ	@nextpnldn

		LDY	ctrlvar_b
		INY
		INY

		STY	ctrlvar_b

@downtest:
		LDA	(ctrlptr1), Y
		STA	elemptr0
		INY
		LDA	(ctrlptr1), Y
		STA	elemptr0 + 1
		
		JSR	ctrlsMoveIsTarget
		BCC	@movedown

		JSR	ctrlsActivateCtrlSimple

		LDY	ctrlvar_b
		STY	actvctrlc

		LDY	ctrlvar_a
		STY	actvctrlp

		RTS

@nextpnldn:
		INC	ctrlvar_e
		LDA	ctrlvar_e
		CMP	#CTRLS_NAV_GUARD_MAX
		BCC	@nextpnldnok
		RTS

@nextpnldnok:
		LDY	#PAGE::panlcnt
		LDA	(pageptr0), Y
		TAY
		DEY
		TYA
		ASL
		CMP	ctrlvar_a
		BEQ	@dnloop

		LDY	ctrlvar_a
		INY
		INY

		STY	ctrlvar_a

		LDA	(ctrlptr0), Y
		STA	panlptr0
		STA	elemptr0
		INY
		LDA	(ctrlptr0), Y
		STA	panlptr0 + 1
		STA	elemptr0 + 1
		
		JSR	ctrlsMoveIsTargetPanel
		BCC	@nextpnldn
		
		JMP	@dnfirst

@dnloop:
		LDA	#$00
		STA	ctrlvar_a

		TAY
		
		LDA	(ctrlptr0), Y
		STA	panlptr0
		STA	elemptr0
		INY
		LDA	(ctrlptr0), Y
		STA	panlptr0 + 1
		STA	elemptr0 + 1

		JSR	ctrlsMoveIsTargetPanel
		BCC	@nextpnldn		
		
@dnfirst:
		LDY	#PANEL::controls
		LDA	(panlptr0), Y
		STA	ctrlptr1
		INY
		LDA	(panlptr0), Y
		STA	ctrlptr1 + 1

		LDA	#$00
		STA	ctrlvar_b

		LDY	#PANEL::ctrlcnt
		LDA	(panlptr0), Y
		BEQ	@nextpnldn

		LDY	ctrlvar_b

		JMP	@downtest


;-------------------------------------------------------------------------------
;	Hand-catalogued from the MEGA65 keyboard manual plus live
;	DEBUG_KEYSCAN testing on real hardware (several manual entries
;	turned out wrong, e.g. MEGA+up-arrow is $FF not the manual's $00,
;	and MEGA+0/MEGA+1 both genuinely report $81, not distinct codes).
;	Paired tables covering only the letters/digits controls actually
;	use as accelerators: keyMegaAccelTbl[i] is the raw ASCIIKEY byte
;	reported with MEGA held; keyMegaAccelBase[i] is that same key's
;	plain (no-modifier) character - what's stored in accelchar. Uses
;	the KEY_ASC_* defines rather than quoted char literals, since
;	ca65's own charmap (not necessarily plain ASCII) applies to those.
;-------------------------------------------------------------------------------
keyMegaAccelTbl:
		.byte	$C1, $C2, $C3, $C4, $C5, $C6, $C7, $C8, $C9, $CA	;a-j
		.byte	$CB, $CC, $CD, $CE, $CF, $D0, $D1, $D2, $D3, $D4	;k-t
		.byte	$D5, $D6, $D7, $D8, $D9, $DA				;u-z
		.byte	$81, $95, $96, $97, $98, $99, $9A, $9B, $92		;1-9 (0 shares 1's $81 - no control uses '0')
keyMegaAccelTblEnd:

keyMegaAccelBase:
		.byte	KEY_ASC_L_A, KEY_ASC_L_B, KEY_ASC_L_C, KEY_ASC_L_D, KEY_ASC_L_E
		.byte	KEY_ASC_L_F, KEY_ASC_L_G, KEY_ASC_L_H, KEY_ASC_L_I, KEY_ASC_L_J
		.byte	KEY_ASC_L_K, KEY_ASC_L_L, KEY_ASC_L_M, KEY_ASC_L_N, KEY_ASC_L_O
		.byte	KEY_ASC_L_P, KEY_ASC_L_Q, KEY_ASC_L_R, KEY_ASC_L_S, KEY_ASC_L_T
		.byte	KEY_ASC_L_U, KEY_ASC_L_V, KEY_ASC_L_W, KEY_ASC_L_X, KEY_ASC_L_Y
		.byte	KEY_ASC_L_Z
		.byte	KEY_ASC_1, KEY_ASC_2, KEY_ASC_3, KEY_ASC_4, KEY_ASC_5
		.byte	KEY_ASC_6, KEY_ASC_7, KEY_ASC_8, KEY_ASC_9


;-------------------------------------------------------------------------------
;	Translates a MEGA-modified ASCIIKEY byte back to the plain
;	character the same key reports alone, via keyMegaAccelTbl/
;	keyMegaAccelBase above, so it can be matched against accelchar.
;	IN	.A		raw ASCIIKEY byte (MEGA held)
;	OUT	.A		base character, or $00 if no accelerator uses that key
;	USED	.X
;-------------------------------------------------------------------------------
keyMegaToBase:
;-------------------------------------------------------------------------------
		LDX	#$00
@loop:
		CPX	#(keyMegaAccelTblEnd - keyMegaAccelTbl)
		BCS	@notfound

		CMP	keyMegaAccelTbl, X
		BEQ	@found

		INX
		JMP	@loop

@found:
		LDA	keyMegaAccelBase, X
		RTS

@notfound:
		LDA	#$00
		RTS


	.export	ctrlsPageKeyPress
;-------------------------------------------------------------------------------
ctrlsPageKeyPress:
;-------------------------------------------------------------------------------
		STA	msgsdat0
		STX	msgsdat1

;	A mouse-captured control (see userCaptureMouse) takes priority
;	over everything below - TAB/cursor-key page navigation, accelerator
;	lookup, all of it - since a panel like panel_detail_board can only
;	ever receive keys this way (it can't be down-captured like a real
;	widget/control - see boardEnterSelectMode), and while something's
;	captured, cursor keys need to reach it directly rather than being
;	treated as control-navigation input by the block just below.
		LDA	mouseCapture
		BEQ	@nomousecap

		LDA	mouseCapCtrl
		STA	elemptr0
		LDA	mouseCapCtrl + 1
		STA	elemptr0 + 1
		JMP	@send

@nomousecap:
	.if	DEBUG_KEYSCAN
		LDA	#<lpanel_cnct_log
		STA	tempptr2
		LDA	#>lpanel_cnct_log
		STA	tempptr2 + 1

		JSR	ctrlsLogPanelGetNextLine

		LDAX	#text_dbg_key_pref
		JSR	strsAppendString

		LDA	msgsdat0
		JSR	strsAppendHex

		LDAX	#text_dbg_key_mid
		JSR	strsAppendString

		LDA	msgsdat1
		JSR	strsAppendHex

		LDA	#$00
		JSR	strsAppendChar

		JSR	ctrlsLogPanelUpdate
	.endif

;	TAB/SHIFT+TAB and cursor up/down all navigate controls, even while
;	one is down (e.g. typing in an edit box) - un-capture it first
;	(same as Enter would) before moving on. Cursor left/right stay out
;	of this for now - reserved for mid-text cursor movement someday.
		LDA	msgsdat0
		CMP	#KEY_C64_TAB
		BNE	@nottab

		LDA	#KEY_C64_CDOWN
		STA	msgsdat0
		JMP	@navtab

@nottab:
		CMP	#KEY_C64_STAB
		BNE	@notstab

		LDA	#KEY_C64_CUP
		STA	msgsdat0
		JMP	@navtab

@notstab:
		CMP	#KEY_C64_CDOWN
		BEQ	@navtab

		CMP	#KEY_C64_CUP
		BNE	@notnavtab

@navtab:
		LDA	actvCtrl + 1
		BEQ	@navtabdiscard		;nothing to navigate to

		LDA	downCtrl + 1
		BEQ	@moveactv

		LDA	downCtrl
		STA	elemptr0
		LDA	downCtrl + 1
		STA	elemptr0 + 1
		JSR	ctrlsUnDownCtrl

		JMP	@moveactv

@navtabdiscard:
		RTS

;	msgsdat1 rather than TXA - X may not have survived the DEBUG_KEYSCAN
;	block above (strsAppendString/ctrlsLogPanelUpdate use X/Y freely)
@notnavtab:
		LDA	msgsdat1
		AND	#keyModSystem
		BNE	@findaccel

		LDA	msgsdat0

		CMP	#KEY_C64_HELP
		BEQ	@findaccel

		CMP	#KEY_C64_F1
		BCS	@fkey0

		JMP	@isdownctrl

@fkey0:
		CMP	#(KEY_C64_F14 + 1)
		BCC	@findaccel

@isdownctrl:
;	mouseCapture is already handled at the very top of this routine -
;	reaching here means it was clear.
		LDA	downCtrl + 1
		BNE	@downctrl

		LDA	actvCtrl + 1
		BNE	@actvctrl

		RTS				;discard key press

@actvctrl:
		LDA	actvCtrl
		STA	elemptr0
		LDA	actvCtrl + 1
		STA	elemptr0 + 1

		LDA	msgsdat0
		CMP	#KEY_ASC_CR
		BNE	@send

		JMP	ctrlsDownCtrl
;		RTS


@moveactv:
		JMP	ctrlsMoveActiveControl
;		RTS

@downctrl:
		STA	elemptr0 + 1
		LDA	downCtrl
		STA	elemptr0

@send:
		LDY	#ELEMENT::keypress
		LDA	(elemptr0), Y
		STA	ctrlptr_a
		INY
		LDA	(elemptr0), Y
		STA	ctrlptr_a + 1
		
		BEQ	@def
		
		JSR	ctrlsProxyA
		RTS
		
@def:
		JSR	ctrlsControlDefKeyPress
		RTS

@findaccel:
;	Reached two ways: MEGA held (any key - msgsdat0 is a MEGA-modified
;	code and needs translating back to what accelchar stores), or an
;	F1-F9 key regardless of modifier (msgsdat0 already matches
;	accelchar's KEY_C64_F* values directly - leave it alone).
		LDA	msgsdat1
		AND	#keyModSystem
		BEQ	@noxlat

		LDA	msgsdat0
		JSR	keyMegaToBase
		STA	msgsdat0

@noxlat:
		LDY	#PAGE::panels
		LDA	(pageptr0), Y
		STA	ctrlptr0
		INY
		LDA	(pageptr0), Y
		STA	ctrlptr0 + 1

		LDY	#$00

@looppanl:
		LDA	(ctrlptr0), Y
		STA	panlptr0
		INY
		LDA	(ctrlptr0), Y
		BEQ	@exit
		
		STA	panlptr0 + 1
		INY
		
		STY	ctrlvar_a
		
		LDY	#ELEMENT::state
		LDA	(panlptr0), Y
		AND	#(STATE_VISIBLE | STATE_ENABLED)
		CMP	#(STATE_VISIBLE | STATE_ENABLED)
		BNE	@nextpanl
		
		LDY	#PANEL::controls
		LDA	(panlptr0), Y
		STA	ctrlptr1
		INY
		LDA	(panlptr0), Y
		STA	ctrlptr1 + 1

		LDY	#$00
		
@loopctrl:
		LDA	(ctrlptr1), Y
		STA	elemptr0
		INY
		LDA	(ctrlptr1), Y
		BEQ	@nextpanl
		
		STA	elemptr0 + 1
		INY
		
		STY	ctrlvar_b

;	Check that the control is both enabled and visible!

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE | STATE_ENABLED
		CMP	#STATE_VISIBLE | STATE_ENABLED
		BNE	@nextctrl
		
;	Check the control's accelerator
		
		LDY	#CONTROL::accelchar
		LDA	(elemptr0), Y
		CMP	msgsdat0

		BNE	@nextctrl

		JSR	ctrlsDownCtrl
		RTS

@nextctrl:	
		LDY	ctrlvar_b
		JMP	@loopctrl

@nextpanl:	
		LDY	ctrlvar_a
		JMP	@looppanl

@exit:
		RTS


	.export	ctrlsEditDefKeyPress
;-------------------------------------------------------------------------------
ctrlsEditDefKeyPress:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BNE	@downkeys

		RTS

@downkeys:
		LDA	msgsdat0
		CMP	#KEY_ASC_CR
		BNE	@input

		JSR	ctrlsUnDownCtrl
		RTS

@input:
		LDY	#CONTROL::textptr
		LDA	(elemptr0), Y
		STA	tempptr0
		INY
		LDA	(elemptr0), Y
		STA	tempptr0 + 1

		LDY	#EDITCTRL::textsiz
		LDA	(elemptr0), Y
		STA	tempdat0

		LDA	msgsdat0
		CMP	#KEY_ASC_BKSPC
		BEQ	@delete

		LDY	#EDITCTRL::textmaxsz
		LDA	(elemptr0), Y
		CMP	tempdat0
		BEQ	@exit

		LDY	tempdat0

		LDA	msgsdat0
		STA	(tempptr0), Y
		
		INY
		LDA	#$00
		STA	(tempptr0), Y
		TYA

@invalidate:
		LDY	#EDITCTRL::textsiz
		STA	(elemptr0), Y

		JSR	ctrlsControlInvalidate
		
@exit:
		JMP	ctrlsControlDefKeyPress

@delete:
		LDY	tempdat0
		BEQ	@exit

		DEY

		LDA	#$00
		STA	(tempptr0), Y
		
		TYA
		
		JMP	@invalidate


;-------------------------------------------------------------------------------
ctrlsControlDefKeyPress:
;-------------------------------------------------------------------------------
		RTS


	.export	ctrlsPagePrepare
;-------------------------------------------------------------------------------
ctrlsPagePrepare:
;-------------------------------------------------------------------------------
		LDY	#PAGE::panels
		LDA	(pageptr0), Y
		STA	ctrlptr0
		INY
		LDA	(pageptr0), Y
		STA	ctrlptr0 + 1

		LDY	#$00
		
@loop:
		LDA	(ctrlptr0), Y
		STA	panlptr0
		INY
		LDA	(ctrlptr0), Y
		BEQ	@exit
		
		STA	panlptr0 + 1
		INY
		
		STY	ctrlvar_a
		
;	Include STATE_PREPARED on panel

		LDY	#ELEMENT::state
		LDA	(panlptr0), Y
		ORA	#STATE_PREPARED
		STA	(panlptr0), Y

;	Stub out prepare override functionality

;		LDY	#ELEMENT::prepare
;		LDA	(panlptr0), Y
;		STA	ctrlptr_a
;		INY
;		LDA	(panlptr0), Y
;		STA	ctrlptr_a + 1
;		
;		BEQ	@def
;		
;		JSR	ctrlsProxyA
;		JMP	@next
;		
;@def:
		JSR	ctrlsPanelDefPrepare
	
@next:	
		LDY	ctrlvar_a
		
		JMP	@loop

@exit:
		RTS


	.export	ctrlsProxyA
;-------------------------------------------------------------------------------
ctrlsProxyA:
;-------------------------------------------------------------------------------
		JMP	(ctrlptr_a)


	.export	ctrlsPanelDefPrepare
;-------------------------------------------------------------------------------
ctrlsPanelDefPrepare:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(panlptr0), Y
		AND	#STATE_VISIBLE
;		BEQ	@exit
		STA	ctrlvar_d
	
		BEQ	@skip0

		LDA	panlptr0
		STA	elemptr0
		LDA	panlptr0 + 1
		STA	elemptr0 + 1

		JSR	ctrlsControlInvalidate
		
@skip0:
		LDY	#PANEL::controls
		LDA	(panlptr0), Y
		STA	ctrlptr1
		INY
		LDA	(panlptr0), Y
		STA	ctrlptr1 + 1

		LDY	#$00
		
@loop:
		LDA	(ctrlptr1), Y
		STA	elemptr0
		INY
		LDA	(ctrlptr1), Y
		BEQ	@exit
		
		STA	elemptr0 + 1
		INY
		
		STY	ctrlvar_b
		
;	Include STATE_PREPARED on element

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		ORA	#STATE_PREPARED
		STA	(elemptr0), Y

;	Stub out prepare override functionality

;		LDY	#ELEMENT::prepare
;		LDA	(elemptr0), Y
;		STA	ctrlptr_a
;		INY
;		LDA	(elemptr0), Y
;		STA	ctrlptr_a + 1
;		
;		BEQ	@def
;		
;		JSR	ctrlsProxyA
;		JMP	@next
;		
;@def:
		LDA	ctrlvar_d
		BEQ	@next

		JSR	ctrlsControlDefPrepare
	
@next:	
		LDY	ctrlvar_b
		
		JMP	@loop

@exit:
		RTS
		

;-------------------------------------------------------------------------------
ctrlsControlDefPrepare:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		
		AND	#($FF ^ (STATE_ACTIVE | STATE_PICK | STATE_DOWN))
		STA	(elemptr0), Y

		LDA	actvCtrl + 1
		BNE	@cont

		LDA	panlptr0
		CMP	#<tab_main
		BNE	@begin

		LDA	panlptr0 + 1
		CMP	#>tab_main
		BNE	@begin

		JMP	@cont

@begin:
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_NONAVIGATE
		BNE	@cont

		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#(STATE_VISIBLE | STATE_ENABLED)
		CMP	#(STATE_VISIBLE | STATE_ENABLED)
		BNE	@cont

;	Activate the first visible control
		LDA	(elemptr0), Y
		ORA	#STATE_ACTIVE
		STA	(elemptr0), Y
		
		LDA	elemptr0
		STA	actvCtrl 
		LDA	elemptr0 + 1
		STA	actvCtrl + 1

		LDA	ctrlvar_a
		STA	actvctrlp
		DEC	actvctrlp
		DEC	actvctrlp

		LDA	ctrlvar_b
		STA	actvctrlc
		DEC	actvctrlc
		DEC	actvctrlc
		
@cont:
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_VISIBLE
		BEQ	@exit

		JSR	ctrlsControlInvalidate
		
@exit:
		RTS


	.export ctrlsPagePresent
;-------------------------------------------------------------------------------
ctrlsPagePresent:
;-------------------------------------------------------------------------------
		LDY	#$00

@loop:
		LDA	msgs_dirty, Y
		STA	elemptr0
		STA	msgsptr0
		INY
		LDA	msgs_dirty, Y
		STA	elemptr0 + 1
		STA	msgsptr0 + 1
		INY
		LDA	msgs_dirty, Y
		STA	msgsdat0
		INY
		LDA	msgs_dirty, Y
		STA	msgsdat1
		INY
	
		STY	ctrlvar_a
		
		LDY	#ELEMENT::present
		LDA	(elemptr0), Y
		STA	ctrlptr_a
		INY
		LDA	(elemptr0), Y
		STA	ctrlptr_a + 1
		
		BEQ	@def
		
		JSR	ctrlsProxyA
		JMP	@next
		
@def:
		JSR	ctrlsControlDefPresent
	
@next:	
		LDY	#ELEMENT::state
		LDA	(msgsptr0), Y
		AND	#($FF ^ STATE_DIRTY)
		STA	(msgsptr0), Y

		LDY	ctrlvar_a
		CPY	msgs_dirty_idx
		BNE	@loop
		
@exit:
		LDA	#$00
		STA	msgs_dirty_idx
		
		JSR	clientDispInetHealth

		RTS


	.export	ctrlsLPanelDefPresent
;-------------------------------------------------------------------------------
ctrlsLPanelDefPresent:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y

		AND	#STATE_VISIBLE
		BEQ	@exit

		JSR	ctrlsPanelDefPresent

		LDY	#LOGPANEL::lines
		LDA	(elemptr0), Y
		STA	ctrlptr0
		INY
		LDA	(elemptr0), Y
		STA	ctrlptr0 + 1

		INY
		LDA	(elemptr0), Y
		ASL
		STA	tempvar_c		;Total count to loop	

;	Fetch offsy for indexing ctrlptr0
		LDY	#LOGPANEL::offsy
		LDA	(elemptr0), Y		
		ASL
		PHA

		LDY	#ELEMENT::posy
		LDA	(elemptr0), Y
		STA	tempvar_x

		PLA
		TAY
		STY	tempvar_y
		
@loop:
		LDA	(ctrlptr0), Y
		STA	tempptr1 
		INY
		LDA	(ctrlptr0), Y
		STA	tempptr1 + 1
		INY

		STY	tempvar_y

		LDA	#CLR_TEXT
		STA	tempdat0

		LDA	#$00
		STA	tempdat1
		STA	tempvar_d

;	ctrlsDrawTextDirect's own x pos - unlike ctrlsDrawText (used by
;	every other control type), this never read ELEMENT::posx, always
;	drawing at column 0. Never mattered before since every LOGPANEL
;	that existed (lpanel_cnct_log/lpanel_room_log/lpanel_play_log) was
;	always posx 0 anyway - lpanel_detail_log is the first one that
;	isn't.
		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		STA	tempvar_a

		LDY	#ELEMENT::width
		LDA	(elemptr0), Y
		STA	tempdat2

		LDA	#$01
		STA	tempdat3
		
		LDA	tempvar_x
		STA	tempvar_b

		INC	tempvar_x

		JSR	ctrlsDrawTextDirect
		
		LDY	tempvar_y
		CPY	tempvar_c
		BNE	@loop

@exit:
		RTS


;-------------------------------------------------------------------------------
ctrlsPanelDefPresent:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y

		AND	#STATE_VISIBLE
		BEQ	@exit

		LDA	(elemptr0), Y
		AND	#STATE_DIRTY
		BEQ	@exit

		LDY	#ELEMENT::colour
		LDA	(elemptr0), Y
	
		JSR	ctrlsEraseBkg

@exit:
		RTS


	.export	ctrlsEditDefPresent
;-------------------------------------------------------------------------------
ctrlsEditDefPresent:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y
		AND	#STATE_DOWN
		BEQ	@normal

		LDA	#CLR_TEXT
		STA	tempdat0

		JSR	ctrlsEraseBkg

		LDY	#CONTROL::textoffx
		LDA	(elemptr0), Y
		STA	tempdat2

		LDY	#ELEMENT::width
		LDA	(elemptr0), Y
		
		SEC
		SBC	tempdat2
		STA	tempdat2

		DEC	tempdat2

		LDY	#EDITCTRL::textsiz
		LDA	(elemptr0), Y
		STA	tempdat1

		LDA	tempdat2
		CMP	tempdat1
		BCS	@noindent

		SEC
		LDA	tempdat1
		SBC	tempdat2
		STA	tempdat1
	
		JMP	@text

@noindent:
		LDA	#$00
		STA	tempdat1

@text:
		LDA	#$00
		STA	tempdat3

		JSR	ctrlsDrawText

;	Stash where the text draw left off (tempvar_a/b are left as the
;	screen column/row right after the last drawn character) for
;	userIRQHandler's blinking cursor - only when this is actually the
;	current down-captured control (downCtrl), since STATE_DOWN alone
;	shouldn't change here - only ctrlsControlDefChanged/ctrlsDownCtrl/
;	ctrlsUnDownCtrl touch that. Cell's just been redrawn plain, so
;	start untouched (crsr_on=0) and let the IRQ handler flip it after
;	its own 6-frame delay, same as it would mid-blink.
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_CAPTURECRSR
		BEQ	@exit

		LDA	elemptr0
		CMP	downCtrl
		BNE	@exit
		LDA	elemptr0 + 1
		CMP	downCtrl + 1
		BNE	@exit

		LDA	tempvar_a
		STA	crsr_col
		LDA	tempvar_b
		STA	crsr_row

		LDA	#$01
		STA	crsr_active

		LDA	#$00
		STA	crsr_on

		JSR	crsrBlinkDelay
		STA	crsr_dly

@exit:
		RTS

@normal:
		JMP 	ctrlsControlDefPresent


;-------------------------------------------------------------------------------
ctrlsControlDefPresent:
;-------------------------------------------------------------------------------
		LDY	#ELEMENT::state
		LDA	(elemptr0), Y

		AND	#STATE_VISIBLE
		BNE	@present
		
;		JMP	@exit
		RTS

@present:
		LDA	(elemptr0), Y
		AND	#STATE_DIRTY
		BNE	@tstenable

;		JMP	@exit
		RTS

@tstenable:
		LDA	(elemptr0), Y
		AND	#STATE_ENABLED
		BNE	@checkpick
		
		LDA	#CLR_SHADOW
		JMP	@draw
		
@checkpick:
		LDA	(elemptr0), Y
		AND	#STATE_PICK
		BEQ	@checkactv

		LDA	(elemptr0), Y		;Check that its not active
		AND	#STATE_ACTIVE
		BNE	@normal

@picked:
		LDY	#ELEMENT::colour	;Check its not already FOCUS
		LDA	(elemptr0), Y
		CMP	#CLR_FOCUS
		BNE	@pickednrm
		
		LDA	#CLR_FACE
		JMP	@draw

@pickednrm:
		LDA	#CLR_FOCUS
		JMP	@draw

@checkactv:
		LDA	(elemptr0), Y
		AND	#STATE_ACTIVE
		BNE	@picked			;Make it the same as picked
		
@normal:
		LDY	#ELEMENT::colour
		LDA	(elemptr0), Y
		
@draw:
		STA	tempdat0

		JSR	ctrlsEraseBkg

		LDA	#$00
		STA	tempdat1

		LDY	#CONTROL::textoffx
		LDA	(elemptr0), Y
		STA	tempdat2

		LDY	#ELEMENT::width
		LDA	(elemptr0), Y
		
		SEC
		SBC	tempdat2
		STA	tempdat2

		LDA	#$01
		STA	tempdat3

		JSR	ctrlsDrawText

		JSR	ctrlsDrawAccel
		
		LDY	#ELEMENT::options
		LDA	(elemptr0), Y
		AND	#OPT_AUTOCHECK
		BEQ	@exit
		
		LDY	#ELEMENT::tag
		LDA	(elemptr0), Y
		BEQ	@exit
		
		LDY	#ELEMENT::posx
		LDA	(elemptr0), Y
		STA	tempvar_a
		INY
		LDA	(elemptr0), Y
		STA	tempvar_b
		INY
		LDA	(elemptr0), Y
		TAX
		DEX
		DEX
		TXA
		STA	tempvar_c
		
		LDA	tempvar_a
		CLC
		ADC	tempvar_c
		STA	tempvar_c
		
		LDY	tempvar_b
		LDA	screenRowsLo, Y
		STA	tempptr0
		STA	tempptr1
		LDA	screenRowsHi, Y
		STA	tempptr0 + 1
		LDA	#$01			;bank - screen RAM is at $010000
		STA	tempptr0 + 2
		LDA	#$00			;top
		STA	tempptr0 + 3
		LDA	colourRowsHiPhys, Y
		STA	tempptr1 + 1
		LDA	#$01			;bank - colour RAM's real physical
		STA	tempptr1 + 2		;	address is $01F800, not $D800
		LDA	#$00			;top
		STA	tempptr1 + 3

		LDA	#CLR_TEXT
		JSR	screenCtrlToLogClr

		STCOLR16 tempptr1, tempvar_c

		LDA	#$51
		STCELL16 tempptr0, tempvar_c

@exit:
		RTS


;===============================================================================


;===============================================================================
;	.segment 	"INIT"
;===============================================================================


;===============================================================================
;	.segment 	"ONCE"
;===============================================================================
sprPointer0:
		.byte	%00000000, %00000000, %00000000
		.byte	%01111111, %10000000, %00000000
		.byte	%01000001, %00000000, %00000000
		.byte	%01000010, %00000000, %00000000
		.byte	%01000001, %00000000, %00000000
		.byte	%01000000
;===============================================================================


	.export	connection_closed
	.export	readmsg0
	.export tempdat2
	.export	ctrlsLock
	
;===============================================================================
;	.segment	"BSS"
;===============================================================================



;	.import ip65_error
ip65_error:
    .byte $00

;;	.import eth_driver_name
eth_driver_name:
    .asciiz "MEGA65_XLAR54"

;;	.import eth_driver_io_base



;	.import eth_name
eth_name:
    .word $0000

;	.import cfg_ip
cfg_ip:
    .dword $00000000

;;	.import abort_key			;Don't include these from ip65
;;	.importzp abort_key_default		;These will be handled here
;;	.importzp abort_key_disable

;	.importzp eth_init_default
eth_init_default = $50
	
;;	.import drv_init


;	.import dns_hostname_is_dotted_quad
dns_hostname_is_dotted_quad:
    .byte $00

;	.import dns_ip
dns_ip:
    .dword $00000000

;	.import dns_resolve
dns_resolve:
    LDA LINEBUF
    STA STAGE_ARG_A_VAR
    STA count_len_loop + 1
    
    LDA LINEBUF + 1
    STA STAGE_ARG_X_VAR
    STA count_len_loop + 2

    lda #$00
    sta STAGE_ARG_Y_VAR

    LDX #$00
    STX LINE_LEN

count_len_loop:
    LDA LINEBUF, X
    BEQ @count_done

    INC LINE_LEN
    BRA count_len_loop

@count_done:
    LDA LINE_LEN
    STA STAGE_ARG_Z_VAR

    LDA STAGE_ARG_A_VAR
    LDX STAGE_ARG_X_VAR
    LDY STAGE_ARG_Y_VAR
    LDZ STAGE_ARG_Z_VAR

    JSR MIP_DNS_START_BUF

    CMP #1
    BNE @resolve_fail

    JMP DNS_WAIT_START_OK

@resolve_fail:
    SEC
    RTS


DNS_WAIT_START_OK:
    JSR RESET_DNS_TIMEOUT

@DNS_WAIT_LOOP:
    JSR MIP_STATUS_POLL

    JSR MIP_GET_DNS_STATE

    CMP #DNS_STATE_DONE
    BEQ @DNS_DONE

    CMP #DNS_STATE_FAIL
    BEQ @DNS_FAILED

    JSR DEC_TIMEOUT_FRAME
    BCC @DNS_WAIT_LOOP

@DNS_FAILED:
    SEC
    RTS

@DNS_DONE:
    JSR MIP_GET_DNS_RESULT

    STA dns_ip
    STX dns_ip + 1
    STY dns_ip + 2
    STZ dns_ip + 3

    CLC
    RTS


LINEBUF:
    .word $0000
LINE_LEN:
    .byte $00
OCTET_INDEX:
    .byte $00
CUR_VALUE:
    .byte $00
DIGIT_VALUE:            
    .byte 0
DIGIT_SEEN:
    .byte $00




;	.import dns_set_hostname
dns_set_hostname:
    STA PARSE_IP_LOOP + 1
    STA LINEBUF
    STX PARSE_IP_LOOP + 2
    STX LINEBUF + 1

    JSR PARSE_IP
    BCS @_resolve_as_host
    
    JSR SET_REMOTE_FROM_IPBUF

    LDA #$01
    STA dns_hostname_is_dotted_quad

    CLC
    RTS

@_resolve_as_host:
    LDA #$00
    STA dns_hostname_is_dotted_quad

    CLC


    RTS


SET_REMOTE_FROM_IPBUF:
    LDA dns_ip
    LDX dns_ip + 1
    LDY dns_ip + 2
    LDZ dns_ip + 3

    JSR MIP_SET_REMOTE_IP
    
    CLC
    RTS


PARSE_IP:
    LDA #0
    STA dns_ip + 0
    STA dns_ip + 1
    STA dns_ip + 2
    STA dns_ip + 3
    STA OCTET_INDEX
    STA CUR_VALUE
    STA DIGIT_SEEN
    LDX #0    

PARSE_IP_LOOP:
    LDA LINEBUF, X
    BEQ @PARSE_IP_END
 
    CMP #'.'
    BEQ @PARSE_IP_DOT
 
    CMP #'0'
    BCC @PARSE_IP_FAIL
 
    CMP #'9'+1
    BCS @PARSE_IP_FAIL
 
    SEC
    SBC #'0'
    STA DIGIT_VALUE
 
    JSR CUR_MUL10_ADD_DIGIT
    BCS @PARSE_IP_FAIL
 
    LDA #1
    STA DIGIT_SEEN
    INX
 
    BRA PARSE_IP_LOOP

@PARSE_IP_DOT:
    LDA DIGIT_SEEN
    BEQ @PARSE_IP_FAIL

    LDY OCTET_INDEX
    CPY #3
    BCS @PARSE_IP_FAIL

    LDA CUR_VALUE
    STA dns_ip, Y
    INC OCTET_INDEX
    LDA #0
    STA CUR_VALUE
    STA DIGIT_SEEN
    INX
    BRA PARSE_IP_LOOP

@PARSE_IP_END:
    LDA DIGIT_SEEN
    BEQ @PARSE_IP_FAIL

    LDA OCTET_INDEX
    CMP #3
    BNE @PARSE_IP_FAIL

    LDY OCTET_INDEX
    LDA CUR_VALUE
    STA dns_ip,y
    CLC
    RTS

@PARSE_IP_FAIL:
    SEC
    RTS


CUR_MUL10_ADD_DIGIT:
    LDA CUR_VALUE
    ASL
    BCS @_cur_fail
    STA ETH_TEMP_A
    ASL
    BCS @_cur_fail
    ASL
    BCS @_cur_fail
    CLC
    ADC ETH_TEMP_A
    BCS @_cur_fail
    CLC
    ADC DIGIT_VALUE
    BCS @_cur_fail
    STA CUR_VALUE
    CLC
    RTS

@_cur_fail:
    SEC
    RTS



;	.import ip65_init
ip65_init:

    LDA #0
    STA ARG_A_VAR
    STA ARG_X_VAR
    STA ARG_Y_VAR

    JSR MIP_INIT
    CLC

    RTS


;	.import ip65_process
ip65_process:
    LDA #$00
    STA TERMINAL_EVENT

    JSR TERMINAL_POLL_STATUS

    LDA TERMINAL_EVENT
    BNE @TERMINAL_HANDLE_EVENT

    LDA #$00
    STA tcp_inbound_data_length
    STA tcp_inbound_data_length + 1

    ;JSR RECV_BLOCK

    JSR  RECV_DATA

;	Diagnostic: log how many bytes THIS poll's RECV_DATA actually
;	received, whenever it received anything.
    .if	DEBUG_RXSIZE
    LDA tcp_inbound_data_length
    ORA tcp_inbound_data_length + 1
    BEQ @norx

    LDA #<lpanel_cnct_log
    STA tempptr2
    LDA #>lpanel_cnct_log
    STA tempptr2 + 1

    JSR ctrlsLogPanelGetNextLine

    LDAX #text_dbg_rx_pref
    JSR strsAppendString

    LDA tcp_inbound_data_length + 1
    JSR strsAppendHex
    LDA tcp_inbound_data_length
    JSR strsAppendHex

    LDA #$00
    JSR strsAppendChar

    JSR ctrlsLogPanelUpdate

@norx:
    .endif
;	Was checking the low byte alone, which was harmless while
;	tcp_inbound_data_length could never actually exceed 255 (the old,
;	buggy RECV_DATA wrapped there anyway). Now that bursts can
;	genuinely exceed that, a burst landing on an exact multiple of
;	256 would read as "nothing received" here and inet_callback would
;	never run - silently losing data already drained from the ring
;	buffer. ORA both bytes together so either one being nonzero counts.
    LDA tcp_inbound_data_length
    ORA tcp_inbound_data_length + 1

    BNE @TERMINAL_HANDLE_RX

    RTS

@TERMINAL_HANDLE_RX:
    JSR inet_callback
    RTS

@TERMINAL_HANDLE_EVENT:
    JSR inetRecordDiscEvent

    LDA #$01
    STA connection_close_requested
    STA connection_closed

    RTS

TERMINAL_POLL_STATUS:
    JSR MIP_STATUS_POLL
    STX inet_last_rtt
    STY inet_last_retries
    CMP #0
    BEQ @_terminal_poll_done
    ORA TERMINAL_EVENT
    STA TERMINAL_EVENT
    SEC
    RTS
@_terminal_poll_done:
    CLC
    RTS


RECV_DATA:
;	tcp_inbound_data_length is a 16-bit counter, but the old version
;	reloaded Y straight from its low byte each time and INC'd only
;	that byte - past 255 bytes in one burst, Y silently wrapped back
;	to 0 and the loop started overwriting the start of the buffer
;	(including the first message's own length byte) with the tail of
;	the burst, corrupting everything already received. Y now stays 0
;	for the whole loop; inetread itself is walked forward one byte at
;	a time with INW instead, so there's no 255-byte addressing limit.
		LDAX 	tcp_inbound_data_ptr
		STAX 	inetread

    LDA #$00
    STA tcp_inbound_data_length
    STA tcp_inbound_data_length + 1

    LDY #$00
@loop:
;	tcp_inbound_data_ptr points at RX_BLOCK_BUF, a fixed 256-byte
;	buffer - stop once it's full rather than walking inetread past
;	its end into whatever memory follows. Anything not drained here
;	stays safely queued in the ring buffer (MIP_ML_RECV_BYTE only
;	consumes what it actually returns) for the next poll to pick up;
;	inet_callback already handles a message continuing across polls.
    LDA tcp_inbound_data_length + 1
    BNE @done

    JSR MIP_ML_RECV_BYTE
    CPX #$01
    BNE @done

    STA (inetread), Y

    INW inetread

;	tcp_inbound_data_length isn't zero-page, and INW only supports
;	zero-page operands on the 4510, so this stays a manual carry-
;	checked increment.
    INC tcp_inbound_data_length
    BNE @loop
    INC tcp_inbound_data_length + 1

    BRA @loop

@done:
    RTS


;RECV_BLOCK:
;    LDA #<RX_BLOCK_BUF
;    STA STAGE_ARG_A_VAR
;    LDA #>RX_BLOCK_BUF
;    STA STAGE_ARG_X_VAR
;    LDA #0
;    STA STAGE_ARG_Y_VAR
;    LDA #235
;    STA STAGE_ARG_Z_VAR
;    
;    LDA STAGE_ARG_A_VAR
;    LDX STAGE_ARG_X_VAR
;    LDY STAGE_ARG_Y_VAR
;    LDZ STAGE_ARG_Z_VAR
;    
;    JSR MIP_ML_RECV_BLOCK
;    
;    STA tcp_inbound_data_length
;    RTS

TERMINAL_EVENT:
    .byte $00

; Last measured send-to-ack round trip, in frame-ticks (~20ms PAL each),
; returned via X from MIP_STATUS_POLL. Drives clientDispInetHealth.
inet_last_rtt:
    .byte $00

; Retries the most recently completed segment actually needed (0 = acked
; clean), returned via Y from MIP_STATUS_POLL. Diagnostic only for now.
inet_last_retries:
    .byte $00

; Last values written to the connect log by clientDispInetHealth's
; temporary diagnostic - lets it only log on a real change.
dbg_last_rtt_logged:
    .byte $00
dbg_last_retries_logged:
    .byte $00

; Non-zero (bit 7 set) on an NTSC machine, 0 on PAL. Read once at startup
; from $D06F; ~16.7ms/tick on NTSC vs ~20ms/tick on PAL.
sys_ntsc_flag:
    .byte $00

DHCP_STATE_BOUND    = $04
DHCP_STATE_FAILED   = $7f
DNS_STATE_DONE      = $02
DNS_STATE_FAIL      = $03

DHCP_TIMEOUT_FRAMES = 3600
DNS_TIMEOUT_FRAMES  = 3600
;	mega-ip's own FIN retry budget (TCP_TX_MAX_RETRIES x TCP_TX_RETRY_TICKS)
;	force-closes locally within ~1.2s worst case even with zero replies,
;	so 300 frames (~6s) is a generous safety margin above that, not the
;	thing actually expected to fire in normal operation.
DISCONNECT_TIMEOUT_FRAMES = 300

;	Same budget as DHCP/DNS. tcp_connect's own wait loop needs this -
;	it never used to reset the shared timeout itself, just inherited
;	whatever DHCP/DNS (or, now, inetDisconnect) left behind. That was
;	fine by accident on a cold boot (DHCP/DNS leave a huge budget
;	behind) but after a disconnect burns most of its own 300-frame
;	budget, tcp_connect would inherit an already-exhausted countdown
;	and fail almost instantly on the very next connect attempt.
CONNECT_TIMEOUT_FRAMES = 3600

ARG_A_VAR:              
    .byte 0
ARG_X_VAR:              
    .byte 0
ARG_Y_VAR:              
    .byte 0
STAGE_ARG_A_VAR:        
    .byte 0
STAGE_ARG_X_VAR:        
    .byte 0
STAGE_ARG_Y_VAR:        
    .byte 0
STAGE_ARG_Z_VAR:        
    .byte 0

LAST_DHCP_STATE:
    .byte $00
TIMEOUT_LO:             
    .byte 0
TIMEOUT_HI:             
    .byte 0
TIMEOUT_FRAME_LAST:     
    .byte 0

PORT_LO:
    .byte 0
PORT_HI:
    .byte 0

ETH_TEMP_A:
    .byte $00


;	.import dhcp_init
dhcp_init:
    LDA #0
    STA ARG_A_VAR
    STA ARG_X_VAR
    STA ARG_Y_VAR

    JSR MIP_DHCP_START

    LDA #$FF
    STA LAST_DHCP_STATE
    JSR RESET_DHCP_TIMEOUT

@DHCP_LOOP:
    JSR MIP_STATUS_POLL

    JSR MIP_DHCP_POLL
    STA ETH_TEMP_A

    CMP LAST_DHCP_STATE
    BEQ @DHCP_STATE_DONE

    STA LAST_DHCP_STATE
    JSR RESET_DHCP_TIMEOUT

@DHCP_STATE_DONE:
    LDA ETH_TEMP_A
    CMP #DHCP_STATE_BOUND
    BEQ @DHCP_SUCCEED

    CMP #DHCP_STATE_FAILED
    BEQ @DHCP_FAILED

    JSR DEC_TIMEOUT_FRAME
    BCC @DHCP_LOOP

@DHCP_FAILED:
    SEC
    RTS

@DHCP_SUCCEED:
    JSR MIP_FORCE_CLOSE
    ;JSR CLEAR_NETWORK_STATUS_AREA

    LDA #0
    STA STAGE_ARG_A_VAR
    STA STAGE_ARG_X_VAR
    STA STAGE_ARG_Y_VAR
    STA STAGE_ARG_Z_VAR
    JSR MIP_GET_LOCAL_IP

    STA cfg_ip + 0
    STX cfg_ip + 1
    STY cfg_ip + 2
    TZA
    STA cfg_ip + 3

    CLC
    RTS


RESET_DHCP_TIMEOUT:
    LDA #<DHCP_TIMEOUT_FRAMES
    STA TIMEOUT_LO
    LDA #>DHCP_TIMEOUT_FRAMES
    STA TIMEOUT_HI
    BRA RESET_TIMEOUT_FRAME

RESET_DNS_TIMEOUT:
    LDA #<DNS_TIMEOUT_FRAMES
    STA TIMEOUT_LO
    LDA #>DNS_TIMEOUT_FRAMES
    STA TIMEOUT_HI
    BRA RESET_TIMEOUT_FRAME

RESET_TIMEOUT_FRAME:
    LDA FRAMECOUNT
    STA TIMEOUT_FRAME_LAST
    RTS

DEC_TIMEOUT_FRAME:
    LDA FRAMECOUNT
    CMP TIMEOUT_FRAME_LAST
    BEQ @_timeout_frame_same
    
    STA TIMEOUT_FRAME_LAST
    BRA @DEC_TIMEOUT

@_timeout_frame_same:
    CLC
    RTS

@DEC_TIMEOUT:
    LDA TIMEOUT_LO
    BNE @_dec_lo
    
    LDA TIMEOUT_HI
    BEQ @_timeout_done
    
    DEC TIMEOUT_HI

@_dec_lo:
    DEC TIMEOUT_LO
    CLC
    RTS

@_timeout_done:
    SEC
    RTS



;	.import tcp_callback
tcp_callback:
    .word $0000


;	.import tcp_close
tcp_close:
;	Was a no-op - clicking Disconnect only reset local client state,
;	never told the server anything, so the connection sat fully
;	ESTABLISHED on the wire until the server's own (very slow) TCP
;	timeout eventually noticed and released it. Send a real FIN so the
;	server sees the close immediately.
    JSR MIP_DISCONNECT
    RTS


CONN_CONNECTED      = %00000001
CONN_FAILED         = %00000010

;	mirror eth.asm's EV_* bits in TCP_EVENT_FLAG - not otherwise exposed
;	to test.s, so re-declared here. Also used by inetRecordDiscEvent
;	below to decode discEventFlags for clientOutputInetError.
EV_RST              = %00000001	;hard reset seen (peer RST)
EV_PEER_FIN         = %00000010	;peer initiated close (we saw FIN)
EV_LOCAL_CLOSE       = %00000100	;our FIN exchange completed
EV_TIMEWAIT_DONE    = %00001000	;TIME_WAIT expired - CLOSED
EV_CONNECT_FAIL     = %00010000	;SYN handshake failed/timeout
EV_TX_TIMEOUT       = %00100000	;data retransmit retries exhausted
EV_BAD_SYNACK       = %01000000	;SYN-SENT: SYN+ACK arrived but its
					;ACK didn't match - dropped, not a
					;true no-reply

;	non-zero after a failed tcp_connect if the failure was an active
;	peer RST (connection refused) rather than a plain SYN timeout.
TCP_CONNECT_FAIL_WAS_RST:
    .byte $00

;	non-zero after a failed tcp_connect if a SYN+ACK actually arrived
;	but was silently dropped because its ACK didn't match what we
;	expected - a real reply that got rejected, not true silence.
TCP_CONNECT_FAIL_BAD_SYNACK:
    .byte $00


;	.import tcp_connect
tcp_connect:

;  huh?

    STA STAGE_ARG_X_VAR
    STA PORT_HI
    STX STAGE_ARG_A_VAR
    STX PORT_LO

    LDA STAGE_ARG_A_VAR
    LDX STAGE_ARG_X_VAR

    JSR MIP_SET_REMOTE_PORT
    
    LDA PORT_HI
    LDX PORT_LO

    LDY #$00
    LDZ #$00

    JSR MIP_SET_LOCAL_PORT

    LDA #<CONNECT_TIMEOUT_FRAMES
    STA TIMEOUT_LO
    LDA #>CONNECT_TIMEOUT_FRAMES
    STA TIMEOUT_HI
    JSR RESET_TIMEOUT_FRAME

;	Accumulate TCP_EVENT_FLAG bits (via TERMINAL_POLL_STATUS, same
;	sticky-OR pattern inetDisconnect uses) across the whole attempt, so
;	that if it fails we can tell an active refusal (peer RST, EV_RST)
;	apart from nobody answering the SYN at all (plain timeout) - the
;	two have different causes and previously looked identical.
    LDA #$00
    STA TERMINAL_EVENT

    JSR MIP_CONNECT_START

@CONNECT_LOOP:
    JSR TERMINAL_POLL_STATUS

    JSR MIP_CONNECT_POLL

    STA ETH_TEMP_A
    LDA ETH_TEMP_A

    AND #CONN_CONNECTED
    BNE @CONNECTED

    LDA ETH_TEMP_A
    AND #CONN_FAILED
    BNE @CONNECT_FAILED

    JSR DEC_TIMEOUT_FRAME
    BCC @CONNECT_LOOP

@CONNECT_FAILED:
    LDA TERMINAL_EVENT
    AND #EV_RST
    STA TCP_CONNECT_FAIL_WAS_RST
    LDA TERMINAL_EVENT
    AND #EV_BAD_SYNACK
    STA TCP_CONNECT_FAIL_BAD_SYNACK
    SEC
    RTS

@CONNECTED:
    CLC
    RTS

;	.import tcp_connect_ip
tcp_connect_ip:
    .dword  $00000000
    
;	.import tcp_inbound_data_ptr
tcp_inbound_data_ptr:
    .word RX_BLOCK_BUF

;RX_BLOCK_COUNT:
;    .byte 0

;	.import tcp_inbound_data_length
tcp_inbound_data_length:
    .word $0000

;	.import tcp_send
tcp_send:
    ;RTS

    LDY tcp_send_data_len
    LDZ #0

    JSR MIP_ML_SEND_BYTE

    LDA #$00
    STA TERMINAL_EVENT

    JSR TERMINAL_POLL_STATUS

    LDA TERMINAL_EVENT
    BNE @TERMINAL_HANDLE_EVENT

    RTS

@TERMINAL_HANDLE_EVENT:
    JSR inetRecordDiscEvent

    LDA #$01
    STA connection_close_requested
    STA connection_closed

    RTS

;	.import tcp_send_data_len
tcp_send_data_len:
    .word $0000

;	.import tcp_send_keep_alive
tcp_send_keep_alive:
    LDA #$00
    STA TERMINAL_EVENT

    JSR TERMINAL_POLL_STATUS

    LDA TERMINAL_EVENT
    BNE @TERMINAL_HANDLE_EVENT

    RTS

@TERMINAL_HANDLE_EVENT:
    JSR inetRecordDiscEvent

    LDA #$01
    STA connection_close_requested
    STA connection_closed

    RTS

;	.import timer_read
timer_read:
    RTS

;	.export	check_for_abort_key		;Required for ip65 callback
	
;	.import	tcp_loop_count
tcp_loop_count:
    .byte $00

;	.import	tcp_packet_sent_count
tcp_packet_sent_count:
    .byte $00





tempvar_a:
			.res 	1
tempvar_b:
			.res	1
tempvar_c:
			.res	1
tempvar_d:
			.res	1
tempvar_e:
			.res	1
tempvar_f:
			.res	1
tempvar_g:
			.res 	1
tempvar_h:
			.res 	1
tempvar_i:
			.res 	1
			
tempvar_q:
			.res	1
tempvar_r:
			.res	1
tempvar_s:
			.res 	1
tempvar_t:
			.res	1

tempvar_x:
			.res	1
tempvar_y:
			.res	1
tempvar_z:
			.res	1

;	dmaFillRow/dmaCopyRow's parameters (see below) - a dedicated set
;	rather than reusing tempptr/tempvar since these are called from
;	inside other routines' own tempvar-heavy loops (ctrlsEraseBkg,
;	screenRectSetColour, strsAppendMessage).
dmaSrc:
			.res	2
dmaDst:
			.res	2
dmaDstBank:
			.res	1
dmaCnt:
			.res	1

uiflshcnt:
			.res 	1
uiflshdly:
			.res	1

room_log_notify_cnt:
			.res	1

;	Blinking text-entry cursor (OPT_CAPTURECRSR) - crsr_col/crsr_row
;	are the screen position userIRQHandler XORs $80 (reverse video)
;	into every crsrBlinkDelay frames (see there); crsr_on is the
;	toggle (0=normal, 1=reversed) so ctrlsUnDownCtrl knows whether
;	one more XOR is needed to restore the cell on release;
;	crsr_active gates all of it off when no captured control wants a
;	cursor.
crsr_col:
			.res	1
crsr_row:
			.res	1
crsr_active:
			.res	1
crsr_on:
			.res	1
crsr_dly:
			.res	1

ctrlvar_a:
			.res	1
ctrlvar_b:
			.res	1
ctrlvar_c:
			.res	1
ctrlvar_d:
			.res	1

;	Loop guard for ctrlsMoveActiveControl's wraparound search (2026-08-24
;	fix - see its own comment). Not part of the original chess.s.
ctrlvar_e:
			.res	1

ctrlptr_a:
			.res	2

ctrlsLock:
			.res	1
ctrlsLCnt:
			.res	1
ctrlsPrep:
			.res	1
ctrlsLChg:
			.res	1

currpgtag:
			.res	1

actvctrlp:
			.res	1
actvctrlc:
			.res	1

pageNext:
			.res	2
pageBack:
			.res 	2
			
temp_num:
			.res 	6
			
temp_bin: 
			.res 	2
temp_bcd: 
			.res 	3

inet_port:
			.res	2
inet_timeout:
			.res	1
connection_close_requested:     
			.res 	1
connection_closed:
			.res 	1
data_received:
			.res 	1

;	Snapshot of TERMINAL_EVENT (TCP_EVENT_FLAG's sticky-OR'd EV_* bits,
;	see above) taken by inetRecordDiscEvent right before connection_closed
;	is set, so clientOutputInetError can show *why* the connection
;	ended instead of just that it did. $00 means connection_closed was
;	set via inet_callback's inbound-EOF sentinel instead (no
;	TCP_EVENT_FLAG bits involved there).
discEventFlags:
			.res	1

sendmsgscnt:
			.res 	1

readmsgbuflen:
			.res	2
readmsgidx:
			.res	1
readbufidx:
			.res	1
readmsglen:
			.res	1

readparmcnt:
			.res	1
readparm0:
			.res	1
readparm1:
			.res	1
readparm2:
			.res	1

msglstid:
			.res	10
msglstsysid:
			.res	10
msglstlobid:
			.res	10
msglstplyid:
			.res	10
msglstsysloc:
			.res	10
msglstlobloc:
			.res	10
msglstplyloc:
			.res	10

			
current_clrs:	
			.res	10


room_haveblank:
			.res 	1
room_lastuser:
			.res	11

;	Same dedup-state shape as room_haveblank/room_lastuser above, for
;	page_play's in-game chat log (lpanel_play_log) - see
;	clientProcPlayGameChatMsg.
play_haveblank:
			.res	1
play_lastuser:
			.res	11


msgs_change_idx:
			.res	1

msgs_dirty_idx:
			.res	1


;	Set whenever anything draws a 16-bit tile index (> 255 - the chess
;	piece graphics) into a screen cell. dest-skip=2 background fills
;	never touch a cell's high byte (see dmaFillRow), so once a cell's
;	held a tile, only an explicit clear gets it back to a plain
;	low-byte-only character - screenClearHiBytes does that for the
;	whole screen, and ctrlsPageSelect calls it on every page change
;	whenever this flag says it's actually needed.
screenHiBytesUsed:
			.res	1


;===============================================================================


;===============================================================================
;	.segment	"RODATA"
;===============================================================================
;	Screen RAM now lives at $010000 (bank byte handled separately by
;	each far-pointer call site, see irqptr0/tempptr0-3), 25 rows at an
;	80-byte stride (CHR16 - two bytes per character, still 40 columns).
screenRowsLo:
			.byte	<$0000, <$0050, <$00A0, <$00F0, <$0140
			.byte	<$0190, <$01E0, <$0230, <$0280, <$02D0
			.byte	<$0320, <$0370, <$03C0, <$0410, <$0460
			.byte	<$04B0, <$0500, <$0550, <$05A0, <$05F0
			.byte	<$0640, <$0690, <$06E0, <$0730, <$0780

screenRowsHi:
			.byte	>$0000, >$0050, >$00A0, >$00F0, >$0140
			.byte	>$0190, >$01E0, >$0230, >$0280, >$02D0
			.byte	>$0320, >$0370, >$03C0, >$0410, >$0460
			.byte	>$04B0, >$0500, >$0550, >$05A0, >$05F0
			.byte	>$0640, >$0690, >$06E0, >$0730, >$0780

;	The $D800 CPU-alias window (colourRowsHi/colourRowsLo in the
;	original Yahtzee source) is gone - a 2000-byte colour RAM span at
;	80 bytes/row no longer fits through it, so every site now goes
;	through the real physical address below via a far pointer instead.
;	Low byte still matches screenRowsLo row for row, since $F800's low
;	byte is $00 just like $010000's.
colourRowsHiPhys:
			.byte	>$F800, >$F850, >$F8A0, >$F8F0, >$F940
			.byte	>$F990, >$F9E0, >$FA30, >$FA80, >$FAD0
			.byte	>$FB20, >$FB70, >$FBC0, >$FC10, >$FC60
			.byte	>$FCB0, >$FD00, >$FD50, >$FDA0, >$FDF0
			.byte	>$FE40, >$FE90, >$FEE0, >$FF30, >$FF80

screenASCIIXLAT:
	.byte	KEY_ASC_BSLASH, KEY_ASC_CARET, KEY_ASC_USCORE, KEY_ASC_BQUOTE
	.byte	KEY_ASC_OCRLYB, KEY_ASC_PIPE, KEY_ASC_CCRLYB, KEY_ASC_TILDE, $00
screenASCIIXLATSub:
	.byte	$4D, $71, $64, $4A ,$55, $5D, $49, $45, $00

;	Same key order as screenASCIIXLAT above (BSLASH, CARET, USCORE,
;	BQUOTE, OCRLYB, PIPE, CCRLYB, TILDE) - used by screenASCIIToScreenXirod
;	instead of screenASCIIXLATSub. All 8 confirmed on hardware - none
;	of these sit at their raw ASCII value in this font.
screenASCIIXLATSubXirod:
	.byte	$1C, $1E, $1F, $40
	.byte	$5B, $5C, $5D, $5E, $00


text_token_null:
			.asciiz	""

text_ident_vernam:
			.asciiz	"alpha"
text_ident_pltfrm:
			.asciiz	"M65"
text_ident_verlbl:
			.asciiz	"0.00.01A"

text_init_text0:
			.asciiz	"INITIALISING..."

text_splsh_title:
			.asciiz	"SNAKE CHALLENGE QUADRO!"
text_splsh_text0:
			.asciiz	"WRITTEN BY:  DANIEL ENGLAND"
text_splsh_text1:
			.asciiz	"OF ECCLESTIAL SOLUTIONS"
text_splsh_text2:
			.asciiz	"VERSION:  0.00.01A"
text_splsh_text3:
			.asciiz	"FOR THE COMMUNITY!"
text_splsh_text4:
			.asciiz	"ALL RIGHTS RESERVED"
text_splsh_cont:
			.asciiz	"[CONTINUE]"

text_main_begin:
			.asciiz	"F1-BEGIN"
text_main_chat:
			.asciiz	"F3-CHAT"
text_main_play:
			.asciiz	"F5-PLAY"
text_main_prefs:
			.asciiz	"F9-PREFS"
			
text_main_back:
			.asciiz	"[F8 <-BAK]"
text_main_next:
			.asciiz	"[F7 NXT->]"
			
			
text_page_connect:
			.asciiz	"CONNECT"
text_page_config:
			.asciiz	"CONFIGURE"
text_config_mouse:
			.asciiz	"MOUSE SETTINGS"
text_config_mouse_slow:
			.asciiz	"[SLOW          ]"
text_config_mouse_medium:
			.asciiz	"[MEDIUM        ]"
text_config_mouse_fast:
			.asciiz	"[FAST          ]"
text_config_theme:
			.asciiz	"THEME SETTINGS"
text_config_theme_prv:
			.asciiz	"[< PRV]"
text_config_theme_nxt:
			.asciiz	"[NXT >]"
text_config_interface:
			.asciiz	"INTERFACE"
text_config_flashchat:
			.asciiz	"[FLASH HIDDN CHAT ]"
text_cnct_host:
			.asciiz "HOST NAME:"
text_cnct_user:
			.asciiz	"USER NAME:"
text_cnct_upd:
			.asciiz	"[UPDATE  ]"
text_cnct_cnct:
			.asciiz "[CONNECT ]"
text_cnct_dcnct:
			.asciiz "[DISCNNCT]"
text_cnct_info:
			.asciiz	"HOST INFO:"
text_page_room:
			.asciiz	"ROOM"
			
text_room_room:
			.asciiz	"ROOM:"
text_room_pwd:
			.asciiz	"PASSWORD:"
text_room_more:	
			.asciiz	"[MORE   >]"
text_room_less:	
			.asciiz	"[LESS   <]"
text_room_list:	
			.asciiz	"[LIST    ]"
text_room_join:	
			.asciiz	"[JOIN    ]"
text_room_part:	
			.asciiz	"[PART    ]"
			
text_room_ujoins:
text_play_ujoins:
			.asciiz	" JOINS "
;text_play_ujoins:
;			.asciiz	" JOINS"
text_room_uparts:
text_play_uparts:
			.asciiz	" PARTS "
;text_play_uparts:
;			.asciiz	" PARTS"
text_room_usays:
			.asciiz	" SAYS"
text_room_uwhisp:
			.asciiz	" WHISPERS"

text_page_play:
			.asciiz	"GAME"

text_play_game:
			.asciiz	"GAME:"


text_driver_pref:
			.asciiz "= USING DRIVER: "
;text_iobase_pref:
;			.asciiz	"= DEVICE I/O  : $"
text_ipcfg_pref:
			.asciiz	"= WITH IP ADDR: "

text_trace_init:
			.asciiz	"# INITIALISED!"
text_trace_cnct:
			.asciiz	"# CONNECTING..."
text_trace_unkmsg:
			.asciiz "- UNKNOWN MESSAGE IDENT"

text_debug_rtt:
			.asciiz "RTT $"
text_debug_retry:
			.asciiz " RETRY $"

text_syserr_pref:
			.asciiz	"!!"
text_err_pref:
			.asciiz	"! "
text_list_pref:
			.asciiz "* "
text_indent_pref:
			.asciiz "> "
text_outdent_pref:
			.asciiz "< "
text_msg_pref:
			.asciiz ": "
text_wrap_pref:
			.asciiz "/ "
text_dbg_rx_pref:
			.asciiz "RX $"
text_dbg_key_pref:
			.asciiz "KEY $"
text_dbg_key_mid:
			.asciiz " MOD $"


text_err_init:
			.asciiz	"!!INITIALISATION ERROR (NO DEVICE?)"
text_err_cnct:
			.asciiz "!!UNSPECIFIED CONNECTION ERROR"
text_err_abort:
			.asciiz	"! ERROR - USER ABORTED"
text_err_timeout:
			.asciiz	"! ERROR - OPERATION TIMEOUT"
text_err_other:
			.asciiz	"! ERROR - SYSTEM ERROR $"
text_err_disc:
			.asciiz "! DISCONNECTED"
text_err_disc_evt:
			.asciiz " $"
text_err_okay:
			.asciiz	"= OKAY"

;	Generic placeholder text for an unset 8-byte name buffer - see
;	strsSetEmptyName above.
text_name_empty:
			.asciiz	"(EMPTY)"


hexdigits:
			.byte "0123456789ABCDEF"
			
healthbars_c64:
			.byte	$A0, $A0
      .byte $E3, $A0
      .byte $F7, $A0
      .byte $F8, $A0
      .byte $62, $A0
      .byte $79, $A0
      .byte $6F, $A0
      .byte $64, $A0
      .byte $20, $A0
			.byte	$20, $A0
      .byte $20, $E3
      .byte $20, $F7
      .byte $20, $F8
      .byte $20, $62
      .byte $20, $79
      .byte $20, $6F
      .byte $20, $64
      .byte $20, $20

healthbars_xirod:
			.byte	$A0, $A0
      .byte $4A, $A0
      .byte $4B, $A0
      .byte $4C, $A0
      .byte $4D, $A0
      .byte $4E, $A0
      .byte $4F, $A0
      .byte $50, $A0
      .byte $50, $A0
			.byte	$20, $A0
      .byte $20, $4A
      .byte $20, $4A
      .byte $20, $4B
      .byte $20, $4C
      .byte $20, $4D
      .byte $20, $4E
      .byte $20, $4F
      .byte $20, $50

healthclrs:
			.byte	$0D, $0D, $05, $05, $05, $05, $07, $07, $07
      .byte $07, $0A, $0A, $0A, $08, $08, $02, $02, $02

			
clrschme_idx:
			.byte	$00
clrschme_cnt	=	$06
clrschme_lst:
			.word	clrschme0
			.word	name_clrschme0
			.word	clrschme1
			.word	name_clrschme1
			.word	clrschme2
			.word	name_clrschme2
			.word	clrschme3
			.word	name_clrschme3
			.word	clrschme4
			.word	name_clrschme4
			.word	clrschme5
			.word	name_clrschme5
			.word	$0000
			
name_clrschme0:
			.asciiz	"CORPORATE"
clrschme0:
			.byte	$06, $02, $0E, $01, $06, $04, $0C, $0F, $03, $01
name_clrschme1:
			.asciiz	"FAMILIAR"
clrschme1:
			.byte	$0E, $0A, $01, $01, $0E, $04, $0C, $0F, $03, $01
name_clrschme2:
      .asciiz "POSTCARD"
clrschme2:
			.byte	$08, $09, $07, $01, $08, $0A, $0C, $0F, $03, $01
name_clrschme3:
      .asciiz "DESTINY"
clrschme3:
			.byte	$05, $0D, $0D, $01, $05, $07, $0C, $0F, $03, $01
name_clrschme4:
      .asciiz "BERRY"
clrschme4:
			.byte	$02, $0A, $0A, $01, $02, $04, $0C, $0F, $03, $01
name_clrschme5:
      .asciiz "PROWL'N"
clrschme5:
			.byte	$0B, $0F, $0F, $01, $0B, $0D, $0C, $0F, $03, $01
;===============================================================================


;CLR_BACK	$FD		;System - always black
;CLR_EMPTY	$FE		;Border on C64
;CLR_CURSOR	$FF		
;CLR_TEXT	$00
;CLR_FOCUS	$01
;CLR_INSET	$02
;CLR_FACE	$03
;CLR_SHADOW	$04
;CLR_PAPER	$05
;CLR_MONEY	$06
;CLR_DIE		$07


;===============================================================================
;	Framework CODE ends here. A game's own tile/sprite graphics binary
;	(chess's chessPiecesBinData was the original example, loaded via its
;	own gameTilesLoadHack - see fw_startup.s) typically gets embedded
;	right after this point, at the tail end of CODE (which runs through
;	$DFFF - see __HIMEM__ in m65.cfg). $D000-$DFFF is the IO shadow once
;	initROM/initM65IOFast bank IO in, so the CPU can't address this range
;	again after boot - but it rides along in the .prg's ordinary load
;	image regardless, and DMA (unlike the CPU) doesn't care what's
;	banked in at $D000-$DFFF, so a boot-time DMA copy can still reach it
;	there before anything else needs that space.
;
;	The actual size check has moved to fw_hivars.s, which .include's
;	last (after the game's own file) - checking here would only cover
;	framework CODE, undercounting the game's own CODE-segment content
;	(state vars, asset blobs, etc.) that's meant to sit between this
;	file and fw_hivars.s in the assembled output.
;===============================================================================
.out .sprintf("Framework CODE ends at $%04X (%u bytes free before $D000)", *, $D000 - *)
