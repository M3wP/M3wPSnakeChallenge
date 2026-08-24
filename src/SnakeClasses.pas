unit SnakeClasses;

{$IFDEF FPC}
	{$MODE DELPHI}
{$ENDIF}
{$H+}

interface

uses
	Generics.Collections, Classes;

type
 	TMsgData = array of Byte;

     { TBaseIdentMessage }

    TBaseIdentMessage = class
		Ident: TGUID;
        Data: TMsgData;

        constructor Create; virtual;

		function  Encode: TMsgData; virtual;
		procedure Decode(const AData: TMsgData); virtual;
	end;

    TIdentMessages = TThreadList<TBaseIdentMessage>;

    TMsgCategory = (mcSystem, mcText, mcLobby, mcConnect, mcClient, mcServer, mcPlay);

	TBaseMessage = class(TBaseIdentMessage)
	public
		Category: TMsgCategory;
		Method: Byte;
		Params: TList<AnsiString>;

		constructor Create; override;
		destructor  Destroy; override;

		procedure ExtractParams; virtual;
		procedure DataFromParams;

		function  DataToString: AnsiString;

		function  Encode: TMsgData; override;
		procedure Decode(const AData: TMsgData); override;

		procedure Assign(AMessage: TBaseMessage);
	end;

//	TMessages = TThreadList<TMessage>;

    TLogKind = (slkError, slkWarning, slkInfo, slkDebug);

    TLogMessage = class
        Kind: TLogKind;
        Message: string;
    end;

	TLogMessages = TThreadList<TLogMessage>;

	TNamedHost = class(TObject)
	public
		Name: AnsiString;
		Host: AnsiString;
		Version: AnsiString;
	end;

	TGameState = (gsWaiting, gsPreparing, gsPlaying, gsPaused, gsFinished);

	// psReady/psPreparing/psWaiting don't really apply to Snake QUADRO's
	// spectator/press-start-per-corner model the way they did to chess's
	// synchronised 2-seat ready-gate - kept as-is anyway (rather than
	// pruning) since SendSlotStatus's wire shape reuses this enum
	// unmodified; TSnakeSlot.State just won't exercise every value.
	// psPlaying = occupying one of the 4 corners, psFinished/psWinner or
	// back to psNone = released back to spectator (see TSnakeGame.Remove).
	TPlayerState = (psNone, psIdle, psReady, psPreparing, psWaiting, psPlaying,
			psFinished, psWinner);

	// TODO: Snake QUADRO wire-format enums/records go here once the board/
	// tile/movement model is designed - deliberately unimplemented for now
	// (mirrors the client's own TODO markers around clientMsgProcs' mcPlay
	// entry in chess.s, and this file's own former TChessPieceType/
	// TChessMoveCategory/TChessCheckState/TChessPiece/TChessMoveDelta,
	// removed during the port from chess since none of chess's move/board
	// wire shapes apply to a real-time tile grid). Expect at least: a
	// direction enum for client input, a tile/food-type enum for the
	// dirty-cell broadcast stream, and a slot-claim message shape
	// (spectator presses one of 4 corner "start" controls).

const
	ARR_LIT_NAM_CATEGORY: array[TMsgCategory] of string = (
			'system', 'text', 'lobby', 'connect', 'client', 'server', 'play');


//  I think that 2 should be 5 but this is using RFC messages as a template.

//		0	-	System
//		00	- 	Hang up
//		0E	-	Invalid category
//		0F	-	Invalid empty
//
//		1	-	Text
//		10	-	Information
//		11	-	Begin
//		12	-	More
//		13	-	Data
//		14	-	Peer
//
//		2	-	Lobby
//		20 	- 	Error
//		21	-	Join
//		22	-	Part
//		23	-	List
//		24	-	Peer
//
//		3	-	Connection
//		30	-	Error
//		31	-	Identify
//
//		4	-	Client
//		40	-	Error
//		41	-	Identify
//		52	-	KeepAlive
//
//		5	-	Server
//		50	-	Error
//		51	-	Identify
//		52	-	Challenge
//
//		6	-	Play
//		60 	- 	Error
//		61	-	Join
//		62	-	Part
//		63	-	List
//		64	-	TextPeer (unused by Snake QUADRO - see the FIXME on
//				TSnakeGame.ProcessPlayerMessage, SnakeServer.pas)
//		65	-	KickPeer (unused)
//		66	-	StatusGame
//		67	-	StatusPeer
//		69	-	TileDelta (Snake QUADRO) - [count, (row,col,tile)*count],
//				see TSnakeGame.SendTileDeltas/Tick
//		6A	-	BoardRowsReq (Snake QUADRO) - client->server, [startRow]
//		6B	-	BoardRowsData (Snake QUADRO) - server->client,
//				[startRow, 30 bytes row, 30 bytes row+1]
//		6C	-	WatchStart (Snake QUADRO) - client->server, no payload
//		6D	-	WatchStop (Snake QUADRO) - client->server, no payload
//		6E	-	GameChat - framework-generic (fw_ctrls_net.s's
//				clientProcPlayMsg), not dispatched here
//
//		TODO: snake direction-input and slot-claim opcodes go here once
//		the movement/slot-claim model is designed - deliberately
//		unimplemented for now (mirrors the client's own TODO markers
//		around clientMsgProcs' mcPlay entry).

procedure AddLogMessage(const AKind: TLogKind; const AMessage: string);

var
    FilterLogKinds: set of TLogKind = [slkError, slkWarning, slkInfo];

	LogMessages: TLogMessages;


implementation

uses
    SysUtils;


procedure AddLogMessage(const AKind: TLogKind; const AMessage: string);
    var
    lm: TLogMessage;

    begin
    if  AKind in FilterLogKinds then
        begin
        lm:= TLogMessage.Create;
        lm.Kind:= AKind;
        lm.Message:= FormatDateTime('hh:nn:ss.zzz ', Now) + AMessage;
        UniqueString(lm.Message);

        LogMessages.Add(lm);
        end;
    end;


{ TBaseIdentMessage }

constructor TBaseIdentMessage.Create;
    begin
    inherited;

    end;

function TBaseIdentMessage.Encode: TMsgData;
    begin
    Result:= Data;
    end;

procedure TBaseIdentMessage.Decode(const AData: TMsgData);
    begin
    Data:= AData;
    end;


{ TMessage }

procedure TBaseMessage.Assign(AMessage: TBaseMessage);
	var
	i: Integer;

	begin
	Category:= AMessage.Category;
	Method:= AMessage.Method;

	SetLength(Data, Length(AMessage.Data));
	Move(AMessage.Data[0], Data[0], Length(AMessage.Data));

	Params.Clear;
	for i:= 0 to AMessage.Params.Count - 1 do
		Params.Add(AMessage.Params[i]);
	end;

constructor TBaseMessage.Create;
	begin
	inherited Create;

	Params:= TList<AnsiString>.Create;
	end;

procedure TBaseMessage.DataFromParams;
	var
	s: AnsiString;
	i: Integer;

	begin
	s:= AnsiString('');
	for i:= 0 to Params.Count - 1 do
		begin
		s:= s + Params[i];
		if  i < (Params.Count - 1) then
			s:= s + AnsiString(' ');
		end;

	SetLength(Data, Length(s));
	for i:= Low(s) to High(s) do
		Data[i - Low(s)]:= Ord(s[i]);
	end;

function TBaseMessage.DataToString: AnsiString;
	var
	i: Integer;

	begin
	Result:= AnsiString('');
	for i:= 0 to High(Data) do
		Result:= Result + AnsiChar(Data[i]);
	end;

procedure TBaseMessage.Decode(const AData: TMsgData);
	var
	i: Integer;
	c: Byte;

	begin
	if  (Length(AData) > 1)
	and (Length(AData) = AData[0] + 1) then
		begin
		SetLength(Data, Length(AData) - 2);

		c:= AData[1] shr 4;
		if  c in [Ord(Low(TMsgCategory))..Ord(High(TMsgCategory))] then
			begin
			Category:= TMsgCategory(AData[1] shr 4);
			Method:= AData[1] and $0F;
			end
		else
			begin
			Category:= mcSystem;
			Method:= $0E;
			end;

		for i:= 2 to High(AData) do
			Data[i - 2]:= AData[i]
		end
	else
		begin
		SetLength(Data, 0);
		Category:= mcSystem;
		Method:= $0F;
		end;
	end;

destructor TBaseMessage.Destroy;
    var
    s: AnsiString;

    begin
    with Params do
        while Count > 0 do
            begin
            s:= Items[0];
            Delete(0);
            end;

	Params.Free;

	inherited;
	end;

function TBaseMessage.Encode: TMsgData;
	var
	i: Integer;
	c: Byte;

	begin
	SetLength(Result, 2 + Length(Data));

	Result[0]:= Length(Data) + 1;

	c:= (Ord(Category) shl 4) or (Method and $0F);
	Result[1]:= c;

	for i:= 0 to High(Data) do
		Result[2 + i]:= Data[i];
	end;

procedure TBaseMessage.ExtractParams;
	var
	i: Integer;
	s: AnsiString;

	begin
    with Params do
        while Count > 0 do
            begin
            s:= Items[0];
            Delete(0);
            s:= AnsiString('');
            end;

//	Params.Clear;

    s:= AnsiString('');
	for i:= 0 to High(Data) do
		if  Data[i] = $20 then
			begin
			Params.Add(s);
			s:= AnsiString('');
			end
		else
			s:= s + AnsiChar(Data[i]);

	if  Length(s) > 0 then
		Params.Add(s);
	end;


initialization
	LogMessages:= TLogMessages.Create;


finalization
    with LogMessages.LockList do
        while Count > 0 do
            begin
            Items[Count - 1].Free;
            Delete(Count - 1);
            end;

	LogMessages.Free;

end.
