program SnakeQuadroCLIServer;

{$MODE DELPHI}
{$H+}

{.DEFINE DEBUG}

{$IFDEF UNIX}
	{$DEFINE UseCThreads}
{$ENDIF}

uses
{$IFDEF UNIX}
    {$IFNDEF DEBUG}
    cmem,
    {$ENDIF}
	{$IFDEF UseCThreads}
	cthreads,
    {$ENDIF}
{$ENDIF}
	Classes, SysUtils, CustApp, SnakeClasses, SnakeServer, TCPServer, blcksock,
    synsock, SidecarClient;

type

{ TSnakeServer }

	TSnakeServer = class(TCustomApplication)
	protected
		procedure DoRun; override;

		procedure DoConnect(const AConnection: TTCPConnection);
		procedure DoDisconnect(const AConnection: TTCPConnection);
		procedure DoReject(const AConnection: TTCPConnection);
		procedure DoReadData(const AIdent: TGUID; const AData: TMsgData);

	public
		constructor Create(TheOwner: TComponent); override;
		destructor  Destroy; override;

		procedure WriteHelp; virtual;
	end;

{ TSnakeServer }

procedure TSnakeServer.DoRun;
	var
	ErrorMsg: String;
    p: TPlayer;
	z: TZone;
	i: Integer;
	lm: TLogMessage;
	silent: Boolean;
    s: string;
	sidehost,
	sideport: string;

	begin
	// quick check parameters
//	--sidecar and --fail-open are LONG options only. The obvious short
//	form for the first, -s, is already taken (it is "silent", just below),
//	and the portal's own document suggests -s purely because it was written
//	without sight of this file - see doc/portal/implementation.md, which
//	tells Savrok the flag differs.
	ErrorMsg:= CheckOptions('hm:sdl:', 'help sidecar: fail-open');
	if  ErrorMsg <> '' then
		begin
		ShowException(Exception.Create(ErrorMsg));
		Terminate;
		Exit;
		end;

	// parse parameters
	if  HasOption('h', 'help') then
		begin
		WriteHelp;
		Terminate;
		Exit;
		end;

	if  HasOption('d', '') then
		Include(FilterLogKinds, slkDebug);

	// -l <n> - DEBUG: start every board on level n instead of 1, so a
	// lava or boss stage can be looked at without playing eight
	// two-minute levels to reach it. See StartPlay.
	if  HasOption('l', '') then
		begin
		s:= GetOptionValue('l', '');

		if  TryStrToInt(s, i) and (i >= 1) then
			DebugStartLevel:= i
		else
			begin
			ShowException(Exception.Create('Invalid start level!'));
			Terminate;
			Exit;
			end;
		end;

	// --sidecar <host:port> - talk to a RetroGameGate sidecar, which is
	// what turns on OTP-verified usernames and join/part events. Absent,
	// none of that code runs and not one socket is opened: the server
	// behaves exactly as it did before the portal work.
	if  HasOption('sidecar') then
		begin
		s:= GetOptionValue('sidecar');

		i:= Pos(':', s);

		if  i > 0 then
			begin
			sidehost:= Copy(s, 1, i - 1);
			sideport:= Copy(s, i + 1, MaxInt);
			end
		else
			begin
			sidehost:= s;
			sideport:= SIDECAR_DEF_PORT;
			end;

		if  Length(sidehost) = 0 then
			sidehost:= SIDECAR_DEF_HOST;

		if  (Length(sideport) = 0)
		or  (not TryStrToInt(sideport, i)) then
			begin
			ShowException(Exception.Create('Invalid sidecar address!'));
			Terminate;
			Exit;
			end;

		SidecarEnabled:= True;

		// fail_closed is the default whenever --sidecar is given: with the
		// check unavailable nobody should be able to take a portal user's
		// name (sidecar-local.md S6).
		SidecarFailOpen:= HasOption('fail-open');
		end
	else if HasOption('fail-open') then
		begin
		ShowException(Exception.Create('--fail-open needs --sidecar!'));
		Terminate;
		Exit;
		end;

    TCPServer.TCPServer:= TTCPServer.Create;
	TCPServer.TCPServer.OnConnect:= DoConnect;
	TCPServer.TCPServer.OnDisconnect:= DoDisconnect;
	TCPServer.TCPServer.OnReject:= DoReject;
	TCPServer.TCPServer.OnReadData:= DoReadData;

    if  HasOption('m', '') then
		begin
		s:= GetOptionValue('m', '');
		if  TryStrToInt(s, i) then
			TCPServer.TCPServer.MaxConnections:= i
		else
			begin
    		ShowException(Exception.Create('Invalid max connections value!'));
    		Terminate;
    		Exit;
			end;
		end;

    TCPListener:= TTCPListener.Create('19763');

	ServerDisp:= TServerDispatcher.Create;

	if  SidecarEnabled then
		Sidecar:= TSidecarClient.Create(sidehost, sideport);

	silent:= HasOption('s', '');

	// Otherwise the only sign of life is the first client connecting - a
	// server sitting there with no output looks indistinguishable from one
	// that silently failed to start.
	AddLogMessage(slkInfo, '----------------------------');
	AddLogMessage(slkInfo, 'M3wP Snake Challenge QUADRO Server ' + LIT_SYS_VERSION +
			' (' + LIT_SYS_PLATFRM + ')');
	AddLogMessage(slkInfo, 'Listening on port 19763');
	if  TCPServer.TCPServer.MaxConnections > 0 then
		AddLogMessage(slkInfo, 'Max connections: ' +
				IntToStr(TCPServer.TCPServer.MaxConnections))
	else
		AddLogMessage(slkInfo, 'Max connections: unlimited');

	if  SidecarEnabled then
		begin
		AddLogMessage(slkInfo, 'Sidecar: ' + sidehost + ':' + sideport);

		if  SidecarFailOpen then
			AddLogMessage(slkInfo, 'Sidecar mode: fail-open')
		else
			AddLogMessage(slkInfo, 'Sidecar mode: fail-closed');
		end
	else
		AddLogMessage(slkInfo, 'Sidecar: none (legacy usernames)');

	AddLogMessage(slkInfo, '----------------------------');

	while not Terminated do
    	begin
		Sleep(100);

        with LogMessages.LockList do
			try
			while Count > 0 do
				begin
				lm:= Items[0];
				Delete(0);
				if  not silent then
					begin
					Writeln(lm.Message);
					Flush(Output);
					end;
                lm.Free;
				end;
			finally
			LogMessages.UnlockList;
			end;

        with ExpirePlayers.LockList do
        	try
            while Count > 0 do
        		begin
        		p:= Items[0];
        		Delete(0);

                AddLogMessage(slkInfo, '"' + p.Ticket + '" releasing...');

                TCPServer.TCPServer.DisconnectByIdent(p.Ident);
                p.Free;

{$IFDEF DEBUG}
                Terminate;
                Break;
{$ENDIF}
        		end;
        	finally
            ExpirePlayers.UnlockList;
        	end;

		with ExpireZones.LockList do
			try
            while Count > 0 do
				begin
				z:= Items[0];
				Delete(0);
				if  z.PlayerCount = 0 then
					z.Free;
				end;
			finally
            ExpireZones.UnlockList;
			end;

    	with ListMessages.LockList do
    		try
    		for i:= Count - 1 downto 0 do
    			begin
    			if  Items[i].Process then
    				Items[i].ProcessList
    			else
    				Items[i].Elapsed;

    			if  Items[i].Complete then
    				begin
    				Items[i].Free;
    				Delete(i);
    				end;
    			end;

    		finally
    		ListMessages.UnlockList;
    		end;

		SystemZone.PlayersKeepAliveDecrement(100);
		SystemZone.PlayersKeepAliveExpire;

		// Before the limbo sweep on purpose: a username the sidecar just
		// approved is set by this call, and ExpirePlayers below is what
		// then promotes the player - so an approval lands in the very
		// same pass rather than waiting another 100 ms.
		SystemZone.SidecarPump;

    	LimboZone.BumpCounter;
    	LimboZone.ExpirePlayers;

		// TODO: the board-tick simulation (6 ticks/sec per the confirmed
		// design) drives from here once the movement model exists -
		// PlayZone's static boards (see ARR_SNAKE_BOARDS) are the fixed
		// set to iterate.
		end;

	if  Assigned(Sidecar) then
		begin
		Sidecar.Terminate;
		Sidecar.WaitFor;
		Sidecar.Free;
		Sidecar:= nil;
		end;

	TCPListener.Terminate;
    TCPListener.WaitFor;

{$IFNDEF DEBUG}
//	stop program loop
	Terminate;
{$ENDIF}
    end;

procedure TSnakeServer.DoConnect(const AConnection: TTCPConnection);
	var
	p: TPlayer;
	m: TBaseMessage;
	s: string;

	begin
	AddLogMessage(slkInfo, '"' + AConnection.Ticket +
			'" connected from IP: ' + AConnection.RemoteAddress);

	p:= TPlayer.Create(AConnection.Ident);

	p.Ident:= AConnection.Ident;
	p.Ticket:= AConnection.Ticket;

	// TTCPConnection is not reachable from TPlayer, and every sidecar
	// message carries <remote_ip>, so it is copied across here - the one
	// place both objects are in scope.
	p.RemoteAddress:= AConnection.RemoteAddress;

	SystemZone.Add(p);

	m:= TBaseMessage.Create;
	m.Category:= mcServer;
	m.Method:= $01;
	m.Params.Add(LIT_SYS_VERNAME);
	m.Params.Add(LIT_SYS_PLATFRM);
	m.Params.Add(LIT_SYS_VERSION);

	m.DataFromParams;

    p.AddSendMessage(m);
	end;

procedure TSnakeServer.DoDisconnect(const AConnection: TTCPConnection);
	var
	p: TPlayer;

	begin
	p:= SystemZone.PlayerByIdent(AConnection.Ident);

    if  Assigned(p) then
        SystemZone.Remove(p);

    AddLogMessage(slkInfo, '"' + AConnection.Ticket + '" disconnecting gracefully...');
	end;

procedure TSnakeServer.DoReject(const AConnection: TTCPConnection);
	begin
//TODO:  Send a nice server error message, "Can't - full"
	end;

procedure TSnakeServer.DoReadData(const AIdent: TGUID; const AData: TMsgData);
	var
	p: TPlayer;
	i,
	j: Integer;
	im: TBaseMessage;
	s: string;
    buf: TMsgData;

	begin
	p:= SystemZone.PlayerByIdent(AIdent);

    if  Assigned(p) then
		begin
		i:= Length(p.InputBuffer);
    	SetLength(p.InputBuffer, i + Length(AData));

		Move(AData[0], p.InputBuffer[i], Length(AData));

        while Length(p.InputBuffer) > 0 do
			begin
            if  p.InputBuffer[0] > (Length(p.InputBuffer) - 1) then
				Break;

			im:= TBaseMessage.Create;
			im.Ident:= AIdent;

        	SetLength(buf, p.InputBuffer[0] + 1);
            Move(p.InputBuffer[0], buf[0], Length(buf));

            im.Decode(buf);

            if  Length(p.InputBuffer) > Length(buf) then
				p.InputBuffer:= Copy(p.InputBuffer, Length(buf), MaxInt)
			else
				SetLength(p.InputBuffer, 0);

			s:= '>>' + IntToStr(buf[0]) + ' $' +
					IntToHex(buf[1], 2)+ ': ';

			for i:= 2 to High(buf) do
            	s:= s + Char(buf[i]);

			AddLogMessage(slkDebug, '"' + p.Ticket + '" ' + s);

			ServerDisp.ReadMessages.Add(im);
            end;
        end;
	end;

constructor TSnakeServer.Create(TheOwner: TComponent);
	begin
	inherited Create(TheOwner);
	StopOnException:= True;
	end;

destructor TSnakeServer.Destroy;
	begin
	inherited Destroy;
	end;

procedure TSnakeServer.WriteHelp;
	begin
	writeln('Usage: ', ExeName,
			' [-h|--help]|[[-s] [-d] [-m <connections>] [-l <level>]');
	writeln('                  [--sidecar=<host:port>] [--fail-open]]');
	writeln('  -s              silent');
	writeln('  -d              debug logging');
	writeln('  -m <n>          max connections');
	writeln('  -l <n>          DEBUG: start boards on level n (see the');
	writeln('                  stage cycle - 4 and 7 are lava, 8 is boss)');
	writeln('  --sidecar=<a>   RetroGameGate sidecar address, host:port.');
	writeln('                  (the = is required - FPC long options do');
	writeln('                  not take a space. Default port ',
			SIDECAR_DEF_PORT, '.) Enables OTP usernames');
	writeln('                  and join/part events. Without it the server');
	writeln('                  behaves exactly as it always has.');
	writeln('  --fail-open     while the sidecar is unreachable, accept');
	writeln('                  usernames the old way instead of refusing');
	writeln('                  them. Needs --sidecar.');
	end;

var
	Application: TSnakeServer;

begin
{$IFDEF DEBUG}
    if  FileExists('heap.trc') then
        DeleteFile('heap.trc');

    SetHeapTraceOutput('heap.trc');
{$ENDIF}

	Application:= TSnakeServer.Create(nil);

{$IFDEF DEBUG}
    CustomApplication:= Application;
{$ENDIF}

	Application.Title:='M3wP Snake Challenge QUADRO Server';
	Application.Run;
	Application.Free;
end.
