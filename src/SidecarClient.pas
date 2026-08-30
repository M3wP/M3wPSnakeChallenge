{==============================================================================|
| Project : M3wP Snake Challenge QUADRO                                        |
|==============================================================================|
| Content: RetroGameGate sidecar link - the local line protocol on             |
|          127.0.0.1:19764                                                     |
|==============================================================================|
| See doc/portal/sidecar-local.md, which is FROZEN at wire version 1. Any      |
| change to the line format needs the portal author's agreement first.         |
|==============================================================================}

unit SidecarClient;

{$MODE DELPHI}
{$H+}

interface

uses
	Classes, SysUtils, SyncObjs, Generics.Collections, synsock, blcksock,
	SnakeClasses;

const
//	sidecar-local.md S2: a longer line is a protocol error and the receiver
//	closes the socket.
	SIDECAR_LINE_MAX = 512;

//	S2 "Answer deadline": 5 s from sending VERIFY/NAME, then treat as NO.
//	Enforced by the caller (SnakeServer's parked-request list), not here -
//	this unit has no idea what a request means.
	SIDECAR_DEADLINE_MS = 5000;

//	S3 PING: send every 30 s when idle, no PONG within 5 s means a dead
//	socket.
	SIDECAR_PING_IDLE_MS = 30000;
	SIDECAR_PONG_WAIT_MS = 5000;

//	S2 Reconnect: 1 s -> 2 s -> 5 s -> 10 s (cap).
	SIDECAR_BACKOFF_MS: array[0..3] of Integer = (1000, 2000, 5000, 10000);

//	How long one pass of the thread loop parks in CanRead. Also the
//	resolution of every timer above, and of Terminated.
	SIDECAR_POLL_MS = 20;

	SIDECAR_DEF_HOST = '127.0.0.1';
	SIDECAR_DEF_PORT = '19764';

type
	TSidecarReplyKind = (srkOK, srkNo, srkKick);

	{ TSidecarReply }
//	One parsed inbound line worth acting on. PING/PONG never reach here -
//	they are answered inside the thread.
	TSidecarReply = class(TObject)
		Kind: TSidecarReplyKind;
		ReqId: Cardinal;
		Name: AnsiString;		//srkOK: the portal's canonical spelling.
								//	srkKick: who to throw out.
		Reason: AnsiString;		//srkNo/srkKick: the one-word reason, for
								//	the log only - it never goes to a client.

		constructor Create;
	end;

	TSidecarReplies = TThreadList<TSidecarReply>;

	{ TSidecarLine }
//	A queued outbound line. A tiny class rather than a raw string so the
//	queue is a TThreadList like every other cross-thread queue here
//	(LogMessages, ExpirePlayers, ListMessages).
	TSidecarLine = class(TObject)
		Text: AnsiString;

		constructor Create(const AText: AnsiString);
	end;

	TSidecarLines = TThreadList<TSidecarLine>;

	{ TSidecarClient }
//	Owns the one outbound TCP connection to the sidecar and nothing else.
//	It knows the LINE protocol; it does not know what a request means,
//	which player it belongs to or what to do about the answer. That all
//	lives in SnakeServer/the main loop, so this thread never touches
//	player state and needs no lock beyond its two queues.
	TSidecarClient = class(TThread)
	protected
		FHost: string;
		FPort: string;

		FSocket: TTCPBlockSocket;
		FLive: Boolean;

		FBackoffIdx: Integer;
		FInBuf: AnsiString;

		FIdleMs: Integer;
		FPongWaitMs: Integer;	//-1 when no PING is outstanding

		procedure Execute; override;

		function  TryConnect: Boolean;
		procedure Drop(const AWhy: string);

		procedure PumpOut;
		procedure PumpIn;
		procedure PumpPing;

		procedure HandleLine(const ALine: AnsiString);

	public
		Outbound: TSidecarLines;
		Replies: TSidecarReplies;

		constructor Create(const AHost, APort: string);
		destructor  Destroy; override;

		procedure Send(const ALine: AnsiString);

//	A hint, not a guarantee - the socket can die between the test and the
//	send. That is exactly what the 5 s deadline is for, so a plain read is
//	honest here.
		property Live: Boolean read FLive;
	end;

var
//	nil unless --sidecar was given. Every call site tests SidecarEnabled
//	first, so without the option not one socket is opened and none of this
//	runs.
	Sidecar: TSidecarClient = nil;
	SidecarEnabled: Boolean = False;

//	sidecar-local.md S6. fail_closed is the default whenever --sidecar is
//	given: with the check unavailable, nobody gets to impersonate a portal
//	user. --fail-open selects the lenient mode for servers that also want
//	walk-ins when the portal is down.
	SidecarFailOpen: Boolean = False;

function  SidecarNextReqId: Cardinal;
procedure SidecarSend(const ALine: AnsiString);

implementation

var
	FReqIdLock: TCriticalSection;
	FReqIdNext: Cardinal = 1;

//	S2: "a per-process counter is fine; it only has to be unique among
//	outstanding requests on this connection". Wraps back to 1 rather than
//	to 0 purely so a zero in a log always means "no request".
function  SidecarNextReqId: Cardinal;
	begin
	FReqIdLock.Acquire;
	try
		Result:= FReqIdNext;

		if  FReqIdNext = High(Cardinal) then
			FReqIdNext:= 1
		else
			Inc(FReqIdNext);

	finally
		FReqIdLock.Release;
		end;
	end;

//	Queue a line if there is a sidecar at all. Everything fire-and-forget
//	(EVENT JOIN/PART) goes through here so call sites do not each have to
//	repeat the Assigned test.
procedure SidecarSend(const ALine: AnsiString);
	begin
	if  SidecarEnabled
	and Assigned(Sidecar) then
		Sidecar.Send(ALine);
	end;

{ TSidecarReply }

constructor TSidecarReply.Create;
	begin
	inherited;

	Kind:= srkNo;
	ReqId:= 0;
	end;

{ TSidecarLine }

constructor TSidecarLine.Create(const AText: AnsiString);
	begin
	inherited Create;

	Text:= AText;
	end;

{ TSidecarClient }

constructor TSidecarClient.Create(const AHost, APort: string);
	begin
	FHost:= AHost;
	FPort:= APort;

	Outbound:= TSidecarLines.Create;
	Replies:= TSidecarReplies.Create;

	FSocket:= TTCPBlockSocket.Create;
	FSocket.Family:= SF_IP4;

	FLive:= False;
	FBackoffIdx:= 0;
	FPongWaitMs:= -1;

	FreeOnTerminate:= False;

	inherited Create(False);
	end;

destructor TSidecarClient.Destroy;
	var
	i: Integer;

	begin
	try
		if  Assigned(FSocket) then
			FSocket.CloseSocket;

		except
		end;

	with Outbound.LockList do
		try
		for i:= Count - 1 downto 0 do
			begin
			Items[i].Free;
			Delete(i);
			end;

		finally
		Outbound.UnlockList;
		end;

	with Replies.LockList do
		try
		for i:= Count - 1 downto 0 do
			begin
			Items[i].Free;
			Delete(i);
			end;

		finally
		Replies.UnlockList;
		end;

	Outbound.Free;
	Replies.Free;

	try
		if  Assigned(FSocket) then
			FSocket.Free;

		except
		end;

	inherited;
	end;

procedure TSidecarClient.Send(const ALine: AnsiString);
	begin
	Outbound.Add(TSidecarLine.Create(ALine));
	end;

function  TSidecarClient.TryConnect: Boolean;
	begin
	Result:= False;

	FSocket.CloseSocket;
	FSocket.CreateSocket;

	if  FSocket.LastError <> 0 then
		Exit;

	FSocket.Connect(FHost, FPort);

	if  FSocket.LastError <> 0 then
		Exit;

	FLive:= True;
	FBackoffIdx:= 0;
	FInBuf:= '';
	FIdleMs:= 0;
	FPongWaitMs:= -1;

	AddLogMessage(slkInfo, 'Sidecar connected (' + FHost + ':' + FPort + ')');

	Result:= True;
	end;

procedure TSidecarClient.Drop(const AWhy: string);
	begin
	if  FLive then
		AddLogMessage(slkWarning, 'Sidecar link lost: ' + AWhy);

	FLive:= False;
	FInBuf:= '';
	FPongWaitMs:= -1;

	try
		FSocket.CloseSocket;

		except
		end;
	end;

//	Drains the whole outbound queue each pass. A queued line is DISCARDED
//	if the socket is down rather than held: everything that goes out is
//	either fire-and-forget (EVENT) or has a 5 s deadline running against
//	it, so a line delivered after a reconnect would be answering a
//	question nobody is still asking.
procedure TSidecarClient.PumpOut;
	var
	l: TSidecarLine;

	begin
	while True do
		begin
		l:= nil;

		with Outbound.LockList do
			try
			if  Count > 0 then
				begin
				l:= Items[0];
				Delete(0);
				end;

			finally
			Outbound.UnlockList;
			end;

		if  not Assigned(l) then
			Break;

		try
			if  FLive then
				begin
				FSocket.SendString(l.Text + #10);

				if  FSocket.LastError <> 0 then
					Drop('send failed (' + FSocket.GetErrorDescEx + ')')
				else
					begin
					FIdleMs:= 0;
					AddLogMessage(slkDebug, 'Sidecar >> ' + string(l.Text));
					end;
				end;

			finally
			l.Free;
			end;
		end;
	end;

procedure TSidecarClient.PumpIn;
	var
	s: AnsiString;
	p: Integer;
	line: AnsiString;

	begin
	if  not FSocket.CanRead(SIDECAR_POLL_MS) then
		Exit;

	s:= FSocket.RecvPacket(0);

	if  FSocket.LastError <> 0 then
		begin
		Drop('recv failed (' + FSocket.GetErrorDescEx + ')');
		Exit;
		end;

//	CanRead said yes and nothing came back: the peer closed.
	if  Length(s) = 0 then
		begin
		Drop('closed by peer');
		Exit;
		end;

	FInBuf:= FInBuf + s;
	FIdleMs:= 0;

	while True do
		begin
		p:= Pos(#10, FInBuf);

		if  p = 0 then
			begin
//	S5: close on an over-long line rather than let the buffer grow.
			if  Length(FInBuf) > SIDECAR_LINE_MAX then
				Drop('line over ' + IntToStr(SIDECAR_LINE_MAX) + ' bytes');

			Break;
			end;

		line:= Copy(FInBuf, 1, p - 1);
		FInBuf:= Copy(FInBuf, p + 1, MaxInt);

//	CR is tolerated on input and never emitted (S2).
		if  (Length(line) > 0)
		and (line[Length(line)] = #13) then
			SetLength(line, Length(line) - 1);

		if  Length(line) > 0 then
			HandleLine(line);
		end;
	end;

procedure TSidecarClient.PumpPing;
	begin
	if  FPongWaitMs >= 0 then
		begin
		Inc(FPongWaitMs, SIDECAR_POLL_MS);

		if  FPongWaitMs > SIDECAR_PONG_WAIT_MS then
			Drop('no PONG within ' + IntToStr(SIDECAR_PONG_WAIT_MS) + 'ms');

		Exit;
		end;

	Inc(FIdleMs, SIDECAR_POLL_MS);

	if  FIdleMs >= SIDECAR_PING_IDLE_MS then
		begin
		FIdleMs:= 0;
		FPongWaitMs:= 0;

		Send('PING');
		end;
	end;

//	S4: "Any other line from the sidecar is ignored by the game server
//	(forward compatibility)" - so an unparseable line is logged and
//	dropped, never fatal.
procedure TSidecarClient.HandleLine(const ALine: AnsiString);
	var
	parts: TStringList;
	r: TSidecarReply;
	v: Int64;

	begin
	AddLogMessage(slkDebug, 'Sidecar << ' + string(ALine));

	if  CompareText(string(ALine), 'PING') = 0 then
		begin
		Send('PONG');
		Exit;
		end;

	if  CompareText(string(ALine), 'PONG') = 0 then
		begin
		FPongWaitMs:= -1;
		Exit;
		end;

	parts:= TStringList.Create;
	try
		parts.Delimiter:= ' ';
		parts.StrictDelimiter:= True;
		parts.DelimitedText:= string(ALine);

		if  parts.Count < 2 then
			Exit;

//	KICK <name> <reason> - S4. Optional inbound capability.
		if  CompareText(parts[0], 'KICK') = 0 then
			begin
			r:= TSidecarReply.Create;
			r.Kind:= srkKick;
			r.Name:= AnsiString(parts[1]);

			if  parts.Count > 2 then
				r.Reason:= AnsiString(parts[2])
			else
				r.Reason:= 'admin';

			Replies.Add(r);
			Exit;
			end;

		if  parts.Count < 3 then
			Exit;

		if  not TryStrToInt64(parts[1], v) then
			Exit;

		if  (v < 0)
		or  (v > High(Cardinal)) then
			Exit;

		if  CompareText(parts[0], 'OK') = 0 then
			begin
			r:= TSidecarReply.Create;
			r.Kind:= srkOK;
			r.ReqId:= Cardinal(v);
			r.Name:= AnsiString(parts[2]);

			Replies.Add(r);
			end
		else if  CompareText(parts[0], 'NO') = 0 then
			begin
			r:= TSidecarReply.Create;
			r.Kind:= srkNo;
			r.ReqId:= Cardinal(v);
			r.Reason:= AnsiString(parts[2]);

			Replies.Add(r);
			end;

	finally
		parts.Free;
		end;
	end;

procedure TSidecarClient.Execute;
	var
	waited: Integer;

	begin
	while not Terminated do
		begin
		if  not FLive then
			begin
			if  not TryConnect then
				begin
//	Sleep the backoff in poll-sized slices so Terminate still lands
//	promptly during a 10 s wait.
				waited:= 0;

				while (not Terminated)
				and   (waited < SIDECAR_BACKOFF_MS[FBackoffIdx]) do
					begin
					Sleep(SIDECAR_POLL_MS);
					Inc(waited, SIDECAR_POLL_MS);
					end;

				if  FBackoffIdx < High(SIDECAR_BACKOFF_MS) then
					Inc(FBackoffIdx);

//	Outbound queued while down is discarded, not left to pile up.
				PumpOut;

				Continue;
				end;
			end;

		PumpOut;

		if  FLive then
			PumpIn
		else
			Continue;

		if  FLive then
			PumpPing;
		end;

	Drop('shutting down');
	end;

initialization
	FReqIdLock:= TCriticalSection.Create;

finalization
	FReqIdLock.Free;

end.
