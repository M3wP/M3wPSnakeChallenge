unit SnakeServer;

{$IFDEF FPC}
	{$MODE DELPHI}
{$ENDIF}

interface

uses
	SyncObjs, Generics.Collections, Classes, TCPServer, SnakeClasses;

const
	// 30x20 - the original Lua game's 30x18 grown vertically to fill the
	// screen (user, 2026-08-24); the 70x21 expansion is still deferred.
	// The board draws at screen rows 5..5+BOARD_ROWS-1, so 20 rows runs
	// to screen row 24 - the last row of page_detail (posy 3, height 22)
	// and exactly the span the right-hand HUD column beside it already
	// uses. 20 rather than 19 deliberately: the row-fetch protocol below
	// moves TWO rows per message, so an even row count divides into
	// whole pairs and needs no short final message or half-pair special
	// case anywhere. Rows/cols are small enough that 2 rows (60 bytes)
	// comfortably fits one message under the 254-byte payload cap - see
	// TSnakeGame.SendBoardRows. Declared up here, ahead of the type
	// block, since TSnakeGame.Board's own field declaration needs them
	// in scope.
	BOARD_COLS = 30;
	BOARD_ROWS = 20;

	// Upper bound on a snake body, so the body array can be a fixed
	// record field rather than a dynamic array reallocated per growth.
	// Demo snakes never grow; this is headroom for real play. Up here
	// for the same reason as the board size - TDemoSnake needs it.
	MAX_SNAKE_LEN = 64;

type

	{ TServerDispatcher }
	TServerDispatcher = class(TThread)
	protected
		procedure Execute; override;

	public
		ReadMessages: TIdentMessages;

		constructor Create;
		destructor  Destroy; override;
	end;

	TPlayer = class;
	TPlayersList = TThreadList<TPlayer>;

	TMessageTemplate = record
		Category: TMsgCategory;
		Method: Byte;
	end;

	TMessageList = class(TObject)
		Player: TPlayer;
		Name: AnsiString;
		Template: TMessageTemplate;
		Data: TQueue<AnsiString>;
		Process: Boolean;
		Complete: Boolean;
		Counter: Cardinal;

		constructor Create(APlayer: TPlayer);
		destructor  Destroy; override;

		procedure ProcessList;
		procedure Elapsed;
	end;

	TMessageLists = TThreadList<TMessageList>;

	TZone = class(TObject)
	protected
		FPlayers: TPlayersList;

		function  GetCount: Integer;
		function  GetPlayers(AIndex: Integer): TPlayer;

	public
		Desc: AnsiString;

		constructor Create; virtual;
		destructor  Destroy; override;

		class function  Name: AnsiString; virtual; abstract;

		procedure Remove(APlayer: TPlayer); virtual;
		procedure Add(APlayer: TPlayer); virtual;

		function  PlayerByIdent(const AIdent: TGUID): TPlayer;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); virtual; abstract;

		property PlayerCount: Integer read GetCount;
		property Players[AIndex: Integer]: TPlayer read GetPlayers; default;
	end;

	TSystemZone = class(TZone)
	public
		destructor  Destroy; override;

		class function  Name: AnsiString; override;

		procedure Remove(APlayer: TPlayer); override;
		procedure Add(APlayer: TPlayer); override;

		function  PlayerByName(AName: AnsiString): TPlayer;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); override;

		procedure PlayersKeepAliveDecrement(Ams: Integer);
		procedure PlayersKeepAliveExpire;
	end;

	TLimboZone = class(TZone)
	public
		class function  Name: AnsiString; override;

		procedure Remove(APlayer: TPlayer); override;
		procedure Add(APlayer: TPlayer); override;

		procedure BumpCounter;
		procedure ExpirePlayers;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); override;
	end;

	TLobbyZone = class;

	TLobbyRoom = class(TZone)
	public
		Lobby: TLobbyZone;
		Password: AnsiString;

		destructor  Destroy; override;

		class function  Name: AnsiString; override;

		procedure Remove(APlayer: TPlayer); override;
		procedure Add(APlayer: TPlayer); override;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); override;
	end;

	TLobbyRooms = TThreadList<TLobbyRoom>;

	TLobbyZone = class(TZone)
	private
		FRooms: TLobbyRooms;

	public
		constructor Create; override;
		destructor  Destroy; override;

		class function  Name: AnsiString; override;

		function  RoomByName(ADesc: AnsiString): TLobbyRoom;

		procedure RemoveRoom(ADesc: AnsiString);
		function  AddRoom(ADesc, APassword: AnsiString): TLobbyRoom;

		procedure Remove(APlayer: TPlayer); override;
		procedure Add(APlayer: TPlayer); override;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); override;
	end;

	TPlayZone = class;

	// Snake QUADRO is spectator-first with 4 independently-claimed corners
	// (unlike chess's synchronised 2-seat ready-gate, and unlike Yahtzee's
	// 6-player Slots array too) - joining the zone is always spectating;
	// claiming a corner via its own "start" control is a separate action.
	// Only the join/part scaffolding survives the port here - there is no
	// tile-grid/movement state yet, see the TODO on TSnakeGame.
	TSnakeSlot = record
		Player: TPlayer;
		Name: AnsiString;
		State: TPlayerState;
		// TODO: score/lives/body-position fields land here once the
		// tile-grid/movement model is designed (see SnakeClasses.pas).
	end;

	// One cell of a TileDelta broadcast (mcPlay/$09 - see
	// TSnakeGame.SendTileDeltas) - the general "these cells changed"
	// wire shape any future per-tick board update rides on, not just
	// the attract-mode bounce that's exercising it first. Row/Col are
	// board-relative (0..BOARD_ROWS-1/0..BOARD_COLS-1), Tile is one of
	// the TILE_* constants (see the board-size const block).
	TTileDelta = record
		Row, Col, Tile: Byte;
	end;

	// Which way a snake is looking/moving. Values match the original's
	// tSNAKEDIR (server.lua) in meaning, not in numbering - nothing puts
	// these on the wire, so a plain enum is clearer than the original's
	// 1/2/4/8 bit flags.
	TSnakeDir = (sdUp, sdDown, sdLeft, sdRight);

	// One body segment's board position. Body[0] is the head, matching
	// the original's body[1]-is-head convention (1-based there).
	TSnakeSeg = record
		Row, Col: Byte;
	end;

	// A demo-mode snake. The demo AI is the original's snakeMenu()
	// (server.lua) exactly: no pathfinding, no look-ahead - the snake
	// runs laps of the interior rectangle, turning only when its head
	// lands on one of the four corners. Both snakes run the SAME circuit
	// in the same rotational direction, started half a lap apart, which
	// is why they never catch each other and no collision handling is
	// needed here at all.
	TDemoSnake = record
		Body: array[0..MAX_SNAKE_LEN - 1] of TSnakeSeg;
		Len: Integer;
		Dir: TSnakeDir;

		// Ticks left before this snake's next step - the original's
		// per-snake moveTick countdown (objectsTick), which is what
		// lets snakes move at different speeds off one shared tick.
		MoveTick: Integer;

		// Tile values this snake's head and body render as.
		HeadTile, BodyTile: Byte;
	end;

	TSnakeGame = class(TZone)
	public
		Play: TPlayZone;
		Lock: TCriticalSection;
		State: TGameState;

		// The 4 corners a spectator can claim by pressing that corner's
		// own "start" control - up to 64 total spectators are supported
		// separately, via bare zone membership (FPlayers), not this array
		// - see TPlayZone.ProcessPlayerMessage's join handling.
		Slots: array[0..3] of TSnakeSlot;

		// Subset of FPlayers who've told us their client is actually on
		// the board page right now (WatchStart/WatchStop, mcPlay/$0C and
		// /$0D - see ProcessPlayerMessage and AddWatcher/RemoveWatcher).
		// Being a zone member (spectating, i.e. in FPlayers) and actually
		// watching the board are different things - a spectator sitting
		// on the highscore overview or a chat tab shouldn't be sent board
		// updates just because they're in the room. The row-fetch sync
		// itself doesn't need this (it's pull-only, the client only asks
		// when it wants rows), but the future per-tick dirty-cell delta
		// broadcast (TODO) absolutely does - it should iterate Watchers,
		// not FPlayers, or every spectator gets flooded every tick
		// whether they're looking at the board or not.
		//
		// Plain TList<TPlayer>, not FPlayers' TThreadList - this class
		// already has its own Lock guarding Slots/Board, so Watchers
		// just joins that same critical section (see AddWatcher/
		// RemoveWatcher) rather than adding a second, independent lock
		// for one more piece of the same object's state.
		Watchers: TList<TPlayer>;

		// The one true copy of the board's tile grid - [row, col], row 0
		// at the top. Currently just a static placeholder pattern (see
		// Create) since the tick/movement simulation doesn't exist yet;
		// this is where that simulation will write once it does. Full-
		// grid sync is row-paginated (SendBoardRows) rather than one big
		// message, to stay under the 254-byte payload cap; live per-cell
		// updates (the attract-mode bounce below, and eventually real
		// gameplay) go out as TileDelta broadcasts (mcPlay/$09 - see
		// SendTileDeltas) instead - Board itself is kept in sync with
		// every delta sent, so the two paths can never disagree, and a
		// client that (re)syncs mid-tick sees exactly what a delta
		// would have told it anyway.
		Board: array[0..BOARD_ROWS - 1, 0..BOARD_COLS - 1] of Byte;

		// The two demo-mode snakes, ticked forward by TPlayZone's tick
		// thread and broadcast to Watchers as TileDeltas whenever no
		// corner is claimed. These replaced the "Cylon/KITT" single-cell
		// bounce that first proved the TileDelta pipeline out
		// (2026-08-24) - the bounce was scaffolding for the wire format,
		// this is the original's actual attract mode (server.lua's
		// iGameMode = tGAMEMODE.attract, driven by snakeMenu).
		DemoSnakes: array[0..1] of TDemoSnake;

		constructor Create; override;
		destructor  Destroy; override;

		class function  Name: AnsiString; override;

		procedure Remove(APlayer: TPlayer); override;
		procedure Add(APlayer: TPlayer); override;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); override;

		procedure SendGameStatus(APlayer: TPlayer);
		procedure SendSlotStatus(APlayer: TPlayer; ASlot: Integer);
		procedure SendBoardRows(APlayer: TPlayer; AStartRow: Integer);

		// TileDelta (mcPlay/$09) - the general "these cells changed"
		// broadcast; ADeltas is whatever cells changed this tick (see
		// Tick). Not gated on Watchers itself - Tick already only calls
		// this per-Watcher, same anti-flood reasoning as the board-row
		// sync (see Watchers' own comment).
		procedure SendTileDeltas(APlayer: TPlayer; const ADeltas: array of TTileDelta);

		// Demo/attract mode - see DemoSnakes. InitDemoSnakes lays both
		// snakes out on the board (and writes them into Board);
		// TickDemoSnakes advances them one tick, appending whatever
		// cells changed to ADeltas.
		procedure InitDemoSnakes;
		procedure TickDemoSnakes(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);

		procedure AddWatcher(APlayer: TPlayer);
		procedure RemoveWatcher(APlayer: TPlayer);

		// Tick - called once per server tick (see TPlayZone's tick
		// thread) for every board, regardless of whether anyone's
		// watching. Advances the attract-mode bounce above when idle
		// (no corner claimed), writes it into Board, and broadcasts it
		// as a TileDelta to Watchers; a no-op otherwise. This is also
		// where the real tile/movement simulation will eventually hook
		// in once it's designed.
		procedure Tick;

		// TODO: tile-grid/tick-driven simulation state (writing into
		// Board above) and the dirty-cell board-delta broadcast land
		// here once the movement model is designed - see
		// SnakeClasses.pas' TODO and the project's own design-decision
		// notes (6 ticks/sec, delta broadcast, 30x18 board for now,
		// demo/attract mode = 0 corners claimed).
	end;

	TSnakeGames = TThreadList<TSnakeGame>;

	TPlayZone = class(TZone)
	private
		FGames: TSnakeGames;

		// Drives every board's Tick at TICK_MS (6/sec - see the
		// project's own design-decision notes) via GetTickCount64, the
		// FPC-portable monotonic ms source (works identically on
		// Windows/Linux, unlike Now/DateUtils - see the earlier server-
		// timing discussion). Declared as the base TThread here so
		// TSnakeTickThread itself can stay entirely inside the
		// implementation section - nothing in the interface needs the
		// concrete type.
		FTickThread: TThread;

	public
		constructor Create; override;
		destructor  Destroy; override;

		class function  Name: AnsiString; override;

		function  GameByName(ADesc: AnsiString): TSnakeGame;

		procedure Remove(APlayer: TPlayer); override;
		procedure Add(APlayer: TPlayer); override;

		procedure ProcessPlayerMessage(APlayer: TPlayer; AMessage: TBaseMessage;
				var AHandled: Boolean); override;

		// Tick - called by FTickThread once per TICK_MS; calls every
		// board's own Tick in turn.
		procedure Tick;
	end;

	TZoneClass = class of TZone;

	TZones = TThreadList<TZone>;

	TExpireZones = TThreadList<TZone>;
    TExpirePlayers = TThreadList<TPlayer>;

	{ TPlayer }

    TPlayer = class(TObject)
	public
		Ident: TGUID;
		Ticket: string;
//		Connection: TTCPConnection;

		Zones: TZones;

        Lock: TCriticalSection;
		Name: AnsiString;
		Client: TNamedHost;

		Counter: Integer;
		KeepAliveCntr: Integer;
		KeepAliveMisses: Integer;

//		Messages: TMessages;

		InputBuffer: TMsgData;

		constructor Create(AIdent: TGUID);
		destructor  Destroy; override;

		procedure AddZone(AZone: TZone);
		procedure RemoveZone(AZone: TZone);
		procedure RemoveZoneByClass(AZoneClass: TZoneClass);
		procedure ClearZones;

		function  FindZoneByClass(AZoneClass: TZoneClass): TZone;
		function  FindZoneByNameDesc(AName, ADesc: AnsiString): TZone;

		procedure SendServerError(AMessage: AnsiString);

		procedure AddSendMessage(var AMessage: TBaseMessage);

		procedure KeepAliveReset;
		procedure KeepAliveDecrement(Ams: Integer);
	end;

var
	SystemZone: TSystemZone;
	LimboZone: TLimboZone;
	LobbyZone: TLobbyZone;
	PlayZone: TPlayZone;

	ServerDisp: TServerDispatcher;

	ListMessages: TMessageLists;

	ExpireZones: TExpireZones;
    ExpirePlayers: TExpirePlayers;


const
	LIT_SYS_VERNAME: AnsiString = 'alpha';
{$IFDEF ANDROID}
	LIT_SYS_PLATFRM: AnsiString = 'android';
{$ELSE}
	{$IFDEF UNIX}
		{$IFDEF LINUX}
   	LIT_SYS_PLATFRM: AnsiString = 'linux';
		{$ELSE}
   	LIT_SYS_PLATFRM: AnsiString = 'unix';
		{$ENDIF}
	{$ELSE}
	LIT_SYS_PLATFRM: AnsiString = 'mswindows';
	{$ENDIF}
{$ENDIF}
	LIT_SYS_VERSION: AnsiString = '0.00.01A';


implementation

uses
	SysUtils, IniFiles;

{$IFDEF WINDOWS}
// Windows' default timer resolution is ~15.6ms, and BOTH GetTickCount64
// and Sleep quantise to it - so TSnakeTickThread's pacing can only land
// on ~15.6ms boundaries no matter what TICK_MS says. At TICK_MS=166 that
// meant real periods of 172-187ms (measured client-side at 5.72 steps/sec
// against a theoretical 6.02), and, worse, an UNEVEN period tick to tick,
// which is exactly the "it does lurch every now and then" the user saw
// on hardware (2026-08-24).
//
// timeBeginPeriod(1) drops the system timer to 1ms for the lifetime of
// the process that asks. Without it TICK_MS=83 (12/sec) can't work at
// all - Sleep(83) would round up to ~93.75ms, i.e. 10.7/sec, with the
// relative jitter twice as bad as at 6/sec.
function timeBeginPeriod(uPeriod: LongWord): LongWord; stdcall;
		external 'winmm.dll' name 'timeBeginPeriod';
function timeEndPeriod(uPeriod: LongWord): LongWord; stdcall;
		external 'winmm.dll' name 'timeEndPeriod';
{$ENDIF}

const
	MOTD_DIR = 'motd';

	ARR_LIT_SYS_INFO: array[0..6] of AnsiString = (
			'----------------------------',
			'~{_/*\_/*\_/*\_/*\_/*\_/*\}~',
			'Snake Challenge QUADRO development system',
			'----------------------------',
			'M3wP /Ecclestial Solutions',
			'~{_/*\_/*\_/*\_/*\_/*\_/*\}~',
			'----------------------------');

	LIT_ERR_CLIENTID: AnsiString = 'Invalid client ident';
	LIT_ERR_CONNCTID: AnsiString = 'Invalid connect ident';
	LIT_ERR_SERVERUN: AnsiString = 'Unrecognised command';
	LIT_ERR_LBBYJINV: AnsiString = 'Invalid lobby join';
	LIT_ERR_LBBYPINV: AnsiString = 'Invalid lobby part';
	LIT_ERR_LBBYLINV: AnsiString = 'Invalid lobby list';
	LIT_ERR_TEXTPINV: AnsiString = 'Invalid text peer';
	LIT_ERR_PLAYJINV: AnsiString = 'Invalid play join';
	LIT_ERR_PLAYPINV: AnsiString = 'Invalid play part';
	LIT_ERR_PLAYLINV: AnsiString = 'Invalid play list';
	LIT_ERR_PLAYGMST: AnsiString = 'Play in progress or full';

	// Static list of boards, per the confirmed design ("at least for the
	// development passes") - unlike chess's freeform type-a-name-to-join-
	// or-create games, QUADRO's boards are a fixed set seeded once at
	// TPlayZone.Create (see below), never created/destroyed at runtime.
	// Trivially extended - just add more names here.
	ARR_SNAKE_BOARDS: array[0..1] of AnsiString = ('board1', 'board2');

	// Placeholder tile values only - no real tile set exists yet (see
	// TSnakeGame.Board's TODO). Just enough to hand the client something
	// real and stable to sync against while the row-fetch protocol is
	// being built.
	TILE_FLOOR = 0;
	TILE_WALL = 1;

	// Was the attract-mode bounce's lit cell, which the demo snakes below
	// have now replaced (2026-08-24). The value is deliberately left in
	// place rather than renumbered - the client's own gameTileChars/
	// gameTileColrs tables are indexed by these values, so keeping the
	// numbering stable means the snake tiles could be added without
	// disturbing anything already on the wire.
	TILE_ATTRACT = 2;

	// Demo-mode snake segments. Head and body are separate values even
	// though both currently render as the same character ($A0) - the
	// user's own call (2026-08-24): "use $00A0 for the snake tiles
	// including the head tile for now, we'll need to find out what the
	// look direction tiles are". When those are known only the CLIENT's
	// lookup table changes; the wire protocol and this numbering don't.
	// The original does the same split - server.lua's realiseSnake draws
	// body[1] from tSnakeLook[look] and every other segment from a fixed
	// index.
	TILE_SNAKE1 = 3;
	TILE_SNAKE1_HEAD = 4;
	TILE_SNAKE2 = 5;
	TILE_SNAKE2_HEAD = 6;

	// 12 ticks/sec (1000 div 12 = 83ms) as of 2026-08-24 - raised from
	// the original 6/sec once measurement showed the client keeping up
	// with the delta stream with room to spare. The point of the higher
	// rate is NOT faster snakes: it's RESOLUTION. Snake speed is a
	// per-snake tick COUNTDOWN (SNAKE_MOVE_TICKS), so the tick rate sets
	// how many distinct speeds exist between "normal" and "flat out".
	// At 6/sec with demo snakes already at 1 tick/step there was no
	// faster gear left at all, which would have made the original's
	// food speed-ups impossible to express.
	//
	// Note this does NOT double the network load: Tick only broadcasts
	// on ticks where something actually moved (see TSnakeGame.Tick's
	// deltaCount = 0 early out), so the message rate follows the snakes'
	// step rate, not the tick rate.
	//
	// Requires the 1ms timer resolution timeBeginPeriod(1) buys - at
	// Windows' default ~15.6ms granularity an 83ms period would round to
	// ~93.75ms (10.7/sec) and jitter visibly.
	TICK_MS = 83;

	// Ticks between one demo snake step. The user's own reading of the
	// original (2026-08-24): normal play is 3, flat out is 1, and the
	// DEMO snakes ran at 2 - deliberately a bit quicker than normal
	// play, which is what makes an attract screen look lively. At
	// TICK_MS=83 that's ~6 steps/sec for the demo, ~4 for normal play
	// and ~12 flat out.
	//
	// This is the demo/attract value only. Real play will carry a
	// per-snake period (the original's moveTick reset value) rather
	// than sharing this constant.
	//
	// The original also modulates this per snake via moveFast (food
	// speed-ups and slow-downs, +30..-12, decaying 1/tick back toward
	// 0) - deliberately NOT implemented here, since demo snakes never
	// eat. When food lands, that becomes a per-snake offset applied to
	// this base, exactly as objectsTick does it.
	SNAKE_MOVE_TICKS = 2;

	// Starting length of each demo snake, matching the original's
	// non-battle initSnakes (5 segments).
	DEMO_SNAKE_LEN = 5;



procedure DoDestroyListMessages;
	var
	i: Integer;

	begin
	with ListMessages.LockList do
		try
		for i:= Count - 1 downto 0 do
			Items[i].Free;

        Clear;

		finally
		ListMessages.UnlockList;
		end;

	ListMessages.Free;
	end;


{ TZone }

procedure TZone.Add(APlayer: TPlayer);
	begin
	FPlayers.Add(APlayer);
	APlayer.Zones.Add(Self);

	AddLogMessage(slkInfo, '"' + APlayer.Ticket + '" added to zone ' +
            Name + ' (' + Desc + ').');
	end;

constructor TZone.Create;
	begin
	inherited Create;

	FPlayers:= TPlayersList.Create;
	end;

destructor TZone.Destroy;
	var
	i: Integer;

	begin
	AddLogMessage(slkInfo, 'Destroying zone ' + Name + ' (' + Desc + ')');

	with FPlayers.LockList do
		try
		for i:= Count - 1 downto 0 do
			Remove(Items[i]);

		finally
		FPlayers.UnlockList;
		end;

	FPlayers.Free;

	inherited;
	end;

function TZone.GetCount: Integer;
	begin
	with FPlayers.LockList do
		try
		Result:= Count;

		finally
		FPlayers.UnlockList;
		end;
	end;

function TZone.GetPlayers(AIndex: Integer): TPlayer;
	begin
	with FPlayers.LockList do
		try
		Result:= Items[AIndex];

		finally
		FPlayers.UnlockList;
		end;
	end;

function TZone.PlayerByIdent(const AIdent: TGUID): TPlayer;
	var
	i: Integer;

	begin
	Result:= nil;

	with FPlayers.LockList do
		try
		for i:= 0 to Count - 1 do
			if  CompareMem(@Items[i].Ident, @AIdent, SizeOf(TGUID)) then
				begin
				Result:= Items[i];
				Exit;
				end;

		finally
		FPlayers.UnlockList;
		end;

	end;

procedure TZone.Remove(APlayer: TPlayer);
	begin
	FPlayers.Remove(APlayer);
	APlayer.Zones.Remove(Self);

	AddLogMessage(slkInfo, '"' + APlayer.Ticket + '" removed from zone ' +
            Name + '(' + Desc + ').');
	end;

{ TSystemZone }

procedure TSystemZone.Add(APlayer: TPlayer);
	begin
	inherited;

	LimboZone.Add(APlayer);
	end;

destructor TSystemZone.Destroy;
	begin

	inherited;
	end;

class function TSystemZone.Name: AnsiString;
	begin
	Result:= 'system';
	end;

function TSystemZone.PlayerByName(AName: AnsiString): TPlayer;
	var
	i: Integer;

	begin
	Result:= nil;

	with FPlayers.LockList do
		try
		for i:= 0 to Count - 1 do
			if  CompareText(string(Items[i].Name), string(AName)) = 0 then
				begin
				Result:= Items[i];
				Exit;
				end;

		finally
		FPlayers.UnlockList;
		end;
	end;

procedure TSystemZone.PlayersKeepAliveDecrement(Ams: Integer);
	var
	i: Integer;

	begin
	with FPlayers.LockList do
		try
		for i:= 0 to Count - 1 do
			if  not Assigned(LimboZone.PlayerByIdent(Items[i].Ident)) then
				Items[i].KeepAliveDecrement(Ams);

		finally
		FPlayers.UnlockList;
		end;
	end;

procedure TSystemZone.PlayersKeepAliveExpire;
	var
	i: Integer;

	begin
	with FPlayers.LockList do
		try
		for i:= Count - 1 downto 0 do
			if  Items[i].KeepAliveMisses >= 5 then
				Self.Remove(Items[i]);

		finally
		FPlayers.UnlockList;
		end;
	end;

// Appends a short (up to 8 line) public-domain poem verse after the sys-info
// banner - picked at random from motd/1.txt, motd/2.txt etc, with the count
// to pick from read from motd/index.ini. Missing/misconfigured motd files
// are a real deployment possibility (directory not copied, index.ini typo),
// so this fails quietly (just logs) rather than breaking the connect
// handshake over a missing poem.
procedure AppendMOTDPoem(AQueue: TQueue<AnsiString>);
	var
	dir: string;
	fname: string;
	ini: TIniFile;
	count: Integer;
	lines: TStringList;
	i: Integer;

	begin
	dir:= IncludeTrailingPathDelimiter(
			IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + MOTD_DIR);

	try
		if  not DirectoryExists(dir) then
			Exit;

		ini:= TIniFile.Create(dir + 'index.ini');
		try
			count:= ini.ReadInteger('motd', 'count', 0);

			finally
			ini.Free;
			end;

		if  count < 1 then
			Exit;

		fname:= dir + IntToStr(Random(count) + 1) + '.txt';

		if  not FileExists(fname) then
			Exit;

		lines:= TStringList.Create;
		try
			lines.LoadFromFile(fname);

			for i:= 0 to lines.Count - 1 do
				AQueue.Enqueue(AnsiString(lines[i]));

			finally
			lines.Free;
			end;

		except
		on E: Exception do
			AddLogMessage(slkError, 'Failed to load MOTD poem: ' + E.Message);
		end;
	end;

procedure TSystemZone.ProcessPlayerMessage(APlayer: TPlayer;
        AMessage: TBaseMessage; var AHandled: Boolean);
	var
	i: Integer;
	a: TPlayer;
	m: TBaseMessage;
	n: AnsiString;
	ml: TMessageList;

	begin
	if  (AMessage.Category = mcText)
	and (AMessage.Method = 0) then
		begin
		ml:= TMessageList.Create(APlayer);

		for i:= 0 to High(ARR_LIT_SYS_INFO) do
			ml.Data.Enqueue(ARR_LIT_SYS_INFO[i]);

		AppendMOTDPoem(ml.Data);

		m:= TBaseMessage.Create;
		m.Category:= mcText;
		m.Method:= $01;
		m.Params.Add(ml.Name);
		m.Params.Add(AnsiString(ARR_LIT_NAM_CATEGORY[mcSystem]));
		m.DataFromParams;

		APlayer.AddSendMessage(m);

		ListMessages.Add(ml);

		AHandled:= True;
		end
	else if (AMessage.Category = mcSystem) then
		begin
		TCPServer.TCPServer.DisconnectByIdent(APlayer.Ident);

		AHandled:= True;
		end
	else if  (AMessage.Category = mcText)
	and (AMessage.Method = $02) then
		begin
		AHandled:= True;
		AMessage.ExtractParams;

		if  AMessage.Params.Count > 0 then
			begin
			n:= Copy(AMessage.Params[0], 1, 8);

			with ListMessages.LockList do
				try
				for i:= 0 to Count - 1 do
					begin
					ml:= Items[i];

					if  CompareText(string(ml.Name), string(n)) = 0 then
						begin
						if  not ml.Complete then
							ml.Process:= True;

						Break;
						end;
					end;

				finally
				ListMessages.UnlockList;
				end;
			end;
		end
	else if  (AMessage.Category = mcText)
	and (AMessage.Method = $04) then
		begin
		AMessage.ExtractParams;

		if  AMessage.Params.Count > 0 then
			begin
			n:= Copy(AMessage.Params[0], 1, 8);
			a:= PlayerByName(n);

			if  Assigned(a) then
				begin
				m:= TBaseMessage.Create;
				m.Assign(AMessage);
				m.Params[0]:= APlayer.Name;
				m.DataFromParams;

				a.AddSendMessage(m);
				end;
			end
		else
			APlayer.SendServerError(LIT_ERR_TEXTPINV);

		AHandled:= True;
		end
	else if (AMessage.Category = mcConnect)
	and (AMessage.Method = 1) then
		begin
		AMessage.ExtractParams;
		if  (AMessage.Params.Count = 1)
		and (Length(AMessage.Params[0]) > 1) then
			begin
			n:= Copy(AMessage.Params[0], 1, 8);

			with FPlayers.LockList do
				try
					if  Length(APlayer.Name) > 0 then
						APlayer.SendServerError(LIT_ERR_CONNCTID)
					else
						begin
						a:= PlayerByName(n);

						if  not Assigned(a) then
							begin
							m:= TBaseMessage.Create;
							m.Assign(AMessage);
							m.Params.Add(APlayer.Name);
							m.DataFromParams;

							APlayer.AddSendMessage(m);

							APlayer.Name:= n;

							AddLogMessage(slkInfo, '"' + APlayer.Ticket +
									'" set username to "' + string(n) + '".');
							end
						else
							APlayer.SendServerError(LIT_ERR_CONNCTID);
						end;
				finally
                FPlayers.UnlockList;
				end;
			end
		else
			APlayer.SendServerError(LIT_ERR_CONNCTID);

		AHandled:= True;
		end
	else if (AMessage.Category = mcClient)
	and (AMessage.Method = 2) then
		begin
		APlayer.KeepAliveReset;

		// Client's keepalive otherwise gets no application-level reply,
		// so its TCP ACK has nothing to piggyback on and can sit behind
		// the peer's delayed-ACK timer for hundreds of ms. The client's
		// dispatch for mcClient is a no-op regardless of method, so this
		// is purely to give the ACK something to ride along with.
		m:= TBaseMessage.Create;
		m.Category:= mcClient;
		m.Method:= 2;
		APlayer.AddSendMessage(m);

		AHandled:= True;
		end;
	end;

procedure TSystemZone.Remove(APlayer: TPlayer);
	begin
	inherited;

	APlayer.ClearZones;

	ExpirePlayers.Add(APlayer);
	end;

{ TLimboZone }

procedure TLimboZone.Add(APlayer: TPlayer);
	begin
	inherited;

	APlayer.Counter:= 0;
	end;

procedure TLimboZone.BumpCounter;
	var
	i: Integer;
	p: TPlayer;

	begin
	with FPlayers.LockList do
		try
		for i:= 0 to Count - 1 do
			begin
			p:= Items[i];
            p.Lock.Acquire;
            try
			    p.Counter:= p.Counter + 1;

                if  p.Counter mod 100 = 0 then
				    AddLogMessage(slkInfo, '"' + p.Ticket +
							'" bumping auth wait count: ' + IntToStr(p.Counter));

                finally
                p.Lock.Release;
                end;
            end;

		finally
		FPlayers.UnlockList;
		end;
	end;

procedure TLimboZone.ExpirePlayers;
	var
	i: Integer;
	p: TPlayer;

	begin
	with FPlayers.LockList do
		try
		for i:= Count - 1 downto 0 do
			begin
			p:= Items[i];

            p.Lock.Acquire;
            try
			    if  Assigned(p.Client)
			    and (Length(p.Name) > 0) then
				    begin
				    AddLogMessage(slkInfo, '"' + p.Ticket +
							'" authenticated, move to lobby/play.');

                    LimboZone.Remove(p);

				    LobbyZone.Add(p);
				    PlayZone.Add(p);
				    end
			    else if p.Counter >= 600 then
				    begin
                    AddLogMessage(slkInfo, '"' + p.Ticket + '" auth failure.');

                    SystemZone.Remove(p);
				    end;

                finally
                p.Lock.Release;
                end;
            end;

		finally
		FPlayers.UnlockList;
		end;
	end;

class function TLimboZone.Name: AnsiString;
	begin
	Result:= 'limbo';
	end;

procedure TLimboZone.ProcessPlayerMessage(APlayer: TPlayer;
        AMessage: TBaseMessage; var AHandled: Boolean);
	var
	c: TNamedHost;

	begin
	if  (AMessage.Category = mcClient)
	and (AMessage.Method = 1) then
		begin
        APlayer.Lock.Acquire;
        try
		if not Assigned(APlayer.Client) then
			begin
			AMessage.ExtractParams;

			if  AMessage.Params.Count = 3 then
				begin
				c:= TNamedHost.Create;

				c.Name:= AMessage.Params[0];
				c.Host:= AMessage.Params[1];
				c.Version:= AMessage.Params[2];

				APlayer.Client:= c;
				end
			else
				APlayer.SendServerError(LIT_ERR_CLIENTID);
			end
		else
			APlayer.SendServerError(LIT_ERR_CLIENTID);


        finally
        APlayer.Lock.Release;
        end;

        AHandled:= True;
		end;
	end;

procedure TLimboZone.Remove(APlayer: TPlayer);
	begin
	inherited;

	end;

{ TLobbyRoom }

procedure TLobbyRoom.Add(APlayer: TPlayer);
	var
	i: Integer;

	procedure JoinMessageFromPeer(APeer: TPlayer; AName: AnsiString);
		var
		m: TBaseMessage;

		begin
		m:= TBaseMessage.Create;

		m.Category:= mcLobby;
		m.Method:= $01;

		m.Params.Add(Desc);
		m.Params.Add(AName);

		m.DataFromParams;

        APeer.AddSendMessage(m);
		end;

	begin
	inherited;

	with FPlayers.LockList do
		try
		for i:= 0 to Count - 1 do
			JoinMessageFromPeer(Items[i], APlayer.Name);

		finally
		FPlayers.UnlockList;
		end;
	end;

destructor TLobbyRoom.Destroy;
	begin
//	FDisposing:= True;

	if  Assigned(Lobby) then
		Lobby.RemoveRoom(Desc);

	inherited;
	end;

class function TLobbyRoom.Name: AnsiString;
	begin
	Result:= 'room';
	end;

procedure TLobbyRoom.ProcessPlayerMessage(APlayer: TPlayer;
        AMessage: TBaseMessage; var AHandled: Boolean);
	var
	i: Integer;

	procedure PeerMessageFromPlayer(APeer: TPlayer; AMessage: TBaseMessage);
		var
		m: TBaseMessage;

		begin
		m:= TBaseMessage.Create;

		m.Assign(AMessage);

		m.Category:= mcLobby;
		m.Method:= $04;

        APeer.AddSendMessage(m);
		end;

	begin
	if  AMessage.Category = mcLobby then
		if  AMessage.Method = 4 then
			begin
			AMessage.ExtractParams;
			if  (AMessage.Params.Count > 2)
			and (CompareText(string(Desc), string(AMessage.Params[0])) = 0) then
				begin
				AMessage.Params[1]:= Copy(APlayer.Name, Low(AnsiString), 8);

				AMessage.DataFromParams;

				with FPlayers.LockList do
					try
					for i:= 0 to Count - 1 do
						PeerMessageFromPlayer(Items[i], AMessage);

					finally
					FPlayers.UnlockList;
					end;

				AHandled:= True;
				end;
		end;
	end;

procedure TLobbyRoom.Remove(APlayer: TPlayer);
	var
	i: Integer;

	procedure PartMessageFromPeer(APeer: TPlayer; AName: AnsiString);
		var
		m: TBaseMessage;

		begin
		m:= TBaseMessage.Create;
		m.Category:= mcLobby;
		m.Method:= $02;

		m.Params.Add(Desc);
		m.Params.Add(AName);

		m.DataFromParams;

        APeer.AddSendMessage(m);
		end;

	begin
	with FPlayers.LockList do
		try
		for i:= 0 to Count - 1 do
			PartMessageFromPeer(Items[i], APlayer.Name);

		finally
		FPlayers.UnlockList;
		end;

	inherited;

	if  PlayerCount = 0 then
		ExpireZones.Add(Self);
	end;

{ TPlayer }

procedure TPlayer.AddZone(AZone: TZone);
	begin
	Zones.Add(AZone);
	end;

procedure TPlayer.ClearZones;
	var
	i: Integer;
	z: TZone;

	begin
	with Zones.LockList do
		try
		for i:= Count - 1 downto 0 do
			begin
			z:= Items[i];
			z.Remove(Self);
			end;
		finally
		Zones.UnlockList;
		end;
	end;

constructor TPlayer.Create(AIdent: TGUID);
	begin
	inherited Create;

    Lock:= TCriticalSection.Create;

	Zones:= TZones.Create;
	Zones.Duplicates:= dupError;

	Ident:= AIdent;

	Name:= '';
	Client:= nil;

	KeepAliveReset;
	end;

destructor TPlayer.Destroy;
	begin
    Lock.Acquire;
    try
        if  Assigned(Client) then
            Client.Free;

        finally
        Lock.Release;
        end;

    Zones.Free;

    Lock.Free;

	inherited;
	end;

function TPlayer.FindZoneByClass(AZoneClass: TZoneClass): TZone;
	var
	i: Integer;

	begin
	Result:= nil;

	with Zones.LockList do
		try
		for i:= 0 to Count - 1 do
			if  Items[i] is AZoneClass then
				begin
				Result:= Items[i];
				Exit;
				end;
		finally
		Zones.UnlockList;
		end;
	end;

function TPlayer.FindZoneByNameDesc(AName, ADesc: AnsiString): TZone;
	var
	i: Integer;

	begin
	Result:= nil;

	with Zones.LockList do
		try
		for i:= 0 to Count - 1 do
			if  (CompareText(string(Items[i].Name), string(AName)) = 0)
			and (CompareText(string(Items[i].Desc), string(ADesc)) = 0) then
				begin
				Result:= Items[i];
				Exit;
				end;
		finally
		Zones.UnlockList;
		end;
	end;

procedure TPlayer.KeepAliveDecrement(Ams: Integer);
	var
	m: TBaseMessage;

	begin
	if  KeepAliveCntr > 0 then
		Dec(KeepAliveCntr, Ams)
	else
		begin
		// A steady 30s heartbeat rather than a single challenge/short
		// grace window - each unanswered challenge just increments
		// KeepAliveMisses and another one goes out 30s later.
		// PlayersKeepAliveExpire only drops the player once 5 land in a
		// row unanswered (~2.5 minutes of total silence), which gives
		// real tolerance for the packet loss/latency a stop-and-wait
		// client stack sees on a real internet path.
		Inc(KeepAliveMisses);

		m:= TBaseMessage.Create;

		m.Category:= mcServer;
		m.Method:= 2;

		AddSendMessage(m);

		KeepAliveCntr:= 30000;
		end;
	end;

procedure TPlayer.KeepAliveReset;
	begin
	KeepAliveCntr:= 30000;
	KeepAliveMisses:= 0;
	end;

procedure TPlayer.RemoveZone(AZone: TZone);
	begin
	AZone.Remove(Self);
	end;

procedure TPlayer.RemoveZoneByClass(AZoneClass: TZoneClass);
	var
	z: TZone;

	begin
	repeat
		z:= FindZoneByClass(AZoneClass);
		if  Assigned(z) then
			z.Remove(Self);

		until not Assigned(z);
	end;

procedure TPlayer.SendServerError(AMessage: AnsiString);
	var
	m: TBaseMessage;

	begin
	m:= TBaseMessage.Create;

	m.Category:= mcServer;
	m.Method:= 0;
	m.Params.Add(AMessage);
	m.DataFromParams;

	AddSendMessage(m);
	end;

procedure TPlayer.AddSendMessage(var AMessage: TBaseMessage);
	begin
    AMessage.Ident:= Ident;
	TCPServer.TCPServer.AddSendMessage(Ident, AMessage);
	end;

{ TLobbyZone }

procedure TLobbyZone.Add(APlayer: TPlayer);
	begin
	inherited;

	end;

function TLobbyZone.AddRoom(ADesc, APassword: AnsiString): TLobbyRoom;
	begin
	with  FRooms.LockList do
		try
			Result:= RoomByName(ADesc);
			if  not Assigned(Result) then
				begin
				Result:= TLobbyRoom.Create;

				Result.Desc:= ADesc;
				Result.Lobby:= Self;
				Result.Password:= APassword;

				FRooms.Add(Result);
				end;

			finally
            FRooms.UnlockList;
			end;
	end;

constructor TLobbyZone.Create;
	begin
	inherited;

	FRooms:= TLobbyRooms.Create;
	end;

destructor TLobbyZone.Destroy;
	var
	i: Integer;

	begin
	with FRooms.LockList do
		try
		for i:= Count - 1 downto 0 do
			begin
			Items[i].Lobby:= nil;
			Items[i].Free;
			end;

		finally
		FRooms.UnlockList;
		end;

	FRooms.Free;

	inherited;
	end;

class function TLobbyZone.Name: AnsiString;
	begin
	Result:= 'lobby';
	end;

procedure TLobbyZone.ProcessPlayerMessage(APlayer: TPlayer;
        AMessage: TBaseMessage; var AHandled: Boolean);
	var
	r: TLobbyRoom;
	s: AnsiString;
	m: TBaseMessage;
	ml: TMessageList;
	i: Integer;
	p: AnsiString;

	begin
	if  AMessage.Category = mcLobby then
		if  AMessage.Method = 1 then
			begin
			AMessage.ExtractParams;

			if  (AMessage.Params.Count > 0)
			and (AMessage.Params.Count < 3) then
				begin
				s:= Copy(AMessage.Params[0], Low(AnsiString), 8);
				r:= RoomByName(AMessage.Params[0]);

				if  AMessage.Params.Count = 2 then
					p:= AMessage.Params[1]
				else
					p:= '';

				if  not Assigned(r) then
					r:= AddRoom(s, p);

				if  CompareText(string(p), string(r.Password)) = 0 then
					with APlayer.Zones.LockList do
						try
						if  not Contains(r) then
							r.Add(APlayer);

						finally
						APlayer.Zones.UnlockList;
						end
				else
					begin
					m:= TBaseMessage.Create;
					m.Category:= mcLobby;
					m.Method:= $00;

					APlayer.AddSendMessage(m);
					end;
				end
			else
				APlayer.SendServerError(LIT_ERR_LBBYJINV);

			AHandled:= True;
			end
		else if AMessage.Method = 2 then
			begin
			AMessage.ExtractParams;

			r:= RoomByName(AMessage.Params[0]);

			if  Assigned(r) then
				r.Remove(APlayer)
			else
				APlayer.SendServerError(LIT_ERR_LBBYPINV);

			AHandled:= True;
			end
		else if AMessage.Method = $03 then
			begin
			AHandled:= True;

			AMessage.ExtractParams;

			r:= nil;

			if  AMessage.Params.Count > 0 then
				begin
				r:= RoomByName(AMessage.Params[0]);
				if  not Assigned(r) then
					begin
					APlayer.SendServerError(LIT_ERR_LBBYLINV);
					Exit;
					end;
				end;

			ml:= TMessageList.Create(APlayer);

			if  AMessage.Params.Count > 0 then
				with r.FPlayers.LockList do
					try
					if  (Length(r.Password) = 0)
					or  Contains(APlayer) then
						for i:= 0 to Count - 1 do
							ml.Data.Enqueue(Items[i].Name);

					finally
					r.FPlayers.UnlockList;
					end
			else
				with FRooms.LockList do
					try
					for i:= 0 to Count - 1 do
						if  Length(Items[i].Password) = 0 then
							ml.Data.Enqueue(Items[i].Desc);

					finally
					FRooms.UnlockList;
					end;

			m:= TBaseMessage.Create;
			m.Category:= mcText;
			m.Method:= $01;
			m.Params.Add(ml.Name);
			m.Params.Add(AnsiString(ARR_LIT_NAM_CATEGORY[mcLobby]));

			if  AMessage.Params.Count > 0 then
				m.Params.Add(r.Desc);

			m.DataFromParams;

			APlayer.AddSendMessage(m);

			ListMessages.Add(ml);
			end
	end;

procedure TLobbyZone.Remove(APlayer: TPlayer);
	begin
	inherited;

	APlayer.RemoveZoneByClass(TLobbyRoom);
	end;

procedure TLobbyZone.RemoveRoom(ADesc: AnsiString);
	var
	r: TLobbyRoom;

	begin
	r:= RoomByName(ADesc);
	if  Assigned(r) then
		FRooms.Remove(r);
	end;

function TLobbyZone.RoomByName(ADesc: AnsiString): TLobbyRoom;
	var
	i: Integer;

	begin
	Result:= nil;
	with FRooms.LockList do
		try
		for i:= 0 to Count - 1 do
			if  CompareText(string(Items[i].Desc), string(ADesc)) = 0 then
				begin
				Result:= Items[i];
				Exit;
				end;
		finally
		FRooms.UnlockList;
		end;
	end;


{ TServerDispatcher }

procedure TServerDispatcher.Execute;
	var
//	cm: TConnectMessage;
	im: TBaseIdentMessage;
	p: TPlayer;
	handled: Boolean;
	z: TZone;
	i,
	batchcount: Integer;

	begin
	while not Terminated do
		try
		Sleep(20);

		// Drain a bounded batch of queued messages per tick rather than
		// exactly one - one-per-tick would cap the whole server's message
		// throughput regardless of player count. The cap keeps this loop
		// responsive to Terminated under a sustained flood.
		batchcount:= 0;

		while batchcount < 200 do
			begin
			Inc(batchcount);

			im:= nil;
			try
				with ReadMessages.LockList do
					try
					if  Count > 0 then
						begin
						im:= Items[0];
						Delete(0);
						end;
					finally
					ReadMessages.UnlockList;
					end;

				except
				AddLogMessage(slkError, 'Dispatcher cannot read messages!');
				end;

			if  not Assigned(im) then
				Break;

			try
				p:= SystemZone.PlayerByIdent(im.Ident);

                if  not Assigned(p) then
					Continue;

				try
					handled:= False;
					z:= nil;

					with p.Zones.LockList do
						try
						for i:= 0 to Count - 1 do
							begin
							z:= Items[i];

							z.ProcessPlayerMessage(p, TBaseMessage(im), handled);
							if  handled then
								Break;

							z:= nil;
							end;

						finally
						p.Zones.UnlockList;
						end;

					if  handled then
						begin
						p.KeepAliveReset;
						AddLogMessage(slkDebug, '"' + p.Ticket +
								'" handled in ' + z.Name + ' zone.');
						end
					else
						begin
						p.SendServerError(LIT_ERR_SERVERUN);

						AddLogMessage(slkDebug, '"' + p.Ticket +
								'" unhandled message.');
						end;

					except
					AddLogMessage(slkError, '"' + p.Ticket +
								'" error processing player message!');
					end;

				finally
				im.Free;
				end;
			end;

        except
		AddLogMessage(slkError, 'Unknown dispatcher error!');
		end;
	end;

constructor TServerDispatcher.Create;
	begin
	ReadMessages:= TIdentMessages.Create;

	inherited Create(False);
	end;

destructor TServerDispatcher.Destroy;
	begin
    with ReadMessages.LockList do
		try
        	while Count > 0 do
				begin
				Items[Count - 1].Free;
				Delete(Count - 1);
				end;

			finally
            ReadMessages.UnlockList;
			end;

    ReadMessages.Free;

	inherited Destroy;
	end;

{ TMessageList }

constructor TMessageList.Create(APlayer: TPlayer);
	var
	s: AnsiString;
	i,
	u,
	p: Integer;
	f: Boolean;

	begin
	inherited Create;

	Player:= APlayer;

	s:= APlayer.Name;
	p:= Length(s) + 1;
	if  p > 8 then
		p:= 8;

	if  Length(s) < p then
		SetLength(s, p);

	Dec(p);

	u:= 0;
	repeat
		s[p + Low(AnsiString)]:= AnsiChar(u + Ord(AnsiChar('0')));

		f:= False;
		with ListMessages.LockList do
			try
			for i:= 0 to Count - 1 do
				if  CompareText(string(Items[i].Name), string(s)) = 0 then
					begin
					f:= True;
					Break;
					end;
			finally
			ListMessages.UnlockList;
			end;

		if  not f then
			begin
			Name:= s;
			end
		else
			Inc(u);

		until (not f) or (u > 9);

	if  u > 9 then
        begin
		AddLogMessage(slkInfo, '"' + APlayer.Ticket +
				'" out of room for new Message List!');
        Exit;
        end;

	Data:= TQueue<AnsiString>.Create;

	Template.Category:= mcText;
	Template.Method:= $03;

	Process:= True;
	Complete:= False;
	end;

destructor TMessageList.Destroy;
	begin
	Data.Free;

	inherited;
	end;

procedure TMessageList.Elapsed;
	begin
	Inc(Counter);

	if  Counter >= 6000 then
		Complete:= True;
	end;

procedure TMessageList.ProcessList;
	var
	c: Integer;
	m: TBaseMessage;

	begin
	c:= 0;
	while (Data.Count > 0) and (c < 15) do
		begin
		m:= TBaseMessage.Create;

		m.Category:= Template.Category;
		m.Method:= Template.Method;

		m.Params.Add(Name);
		m.Params.Add(Data.Dequeue);

		m.DataFromParams;

        Player.AddSendMessage(m);

		Inc(c);
		end;

	m:= TBaseMessage.Create;

	m.Category:= mcText;
	m.Method:= $02;

	m.Params.Add(Name);
	m.Params.Add(AnsiString(IntToStr(Data.Count)));

	m.DataFromParams;

	Player.AddSendMessage(m);

	Process:= False;
	Complete:= Data.Count = 0;
    Counter:= 0;
	end;

{ TSnakeGame }

procedure TSnakeGame.Add(APlayer: TPlayer);
	var
	i: Integer;

	begin
	Lock.Acquire;
		try
		inherited;

		// Joining the game zone is always spectating - claiming one of the
		// 4 corners is a separate action (TODO: slot-claim message, see
		// SnakeClasses.pas), unlike chess's Add, which auto-seated the
		// joining player into slot 0/1. Tell the newcomer the board's
		// current state and whichever corners are already claimed, so
		// their client can render the live board immediately rather than
		// waiting for the next thing to change.
		SendGameStatus(APlayer);

		for i:= 0 to 3 do
			if  Assigned(Slots[i].Player) then
				SendSlotStatus(APlayer, i);

		finally
		Lock.Release;
		end;
	end;

constructor TSnakeGame.Create;
	var
	r, c: Integer;

	begin
	inherited;

	Lock:= TCriticalSection.Create;
	Watchers:= TList<TPlayer>.Create;

	// Placeholder board - a plain bordered room (wall around the edge,
	// empty floor inside). No real level/tile simulation exists yet
	// (see the TODO below) - this just gives the row-fetch protocol
	// something real and stable to sync against. The eventual tick
	// simulation replaces this wholesale, it doesn't build on it.
	for r:= 0 to BOARD_ROWS - 1 do
		for c:= 0 to BOARD_COLS - 1 do
			if  (r = 0) or (r = BOARD_ROWS - 1)
			or  (c = 0) or (c = BOARD_COLS - 1) then
				Board[r][c]:= TILE_WALL
			else
				Board[r][c]:= TILE_FLOOR;

	// Lay the demo snakes onto that board. State starts at gsWaiting (the
	// TGameState default, Ord 0) - attract/demo mode is "gsWaiting with 0
	// corners claimed", not a separate TGameState value, per the
	// confirmed design (0-4 active corners on one continuously-running
	// board, not a synchronised 2-seat ready-gate).
	InitDemoSnakes;
	end;

destructor TSnakeGame.Destroy;
	begin
	// Unlike chess's per-room dynamic games, static boards (see
	// TPlayZone.Create) are never destroyed at runtime - this only runs
	// at server shutdown (TPlayZone.Destroy), so there's no
	// Play.RemoveGame(Desc) call here to mirror chess's Destroy.
	Watchers.Free;
	Lock.Free;

	inherited;
	end;

// AddWatcher/RemoveWatcher - see Watchers' own comment above for why
// this is a plain TList guarded by Lock rather than a TThreadList.
procedure TSnakeGame.AddWatcher(APlayer: TPlayer);
	begin
	Lock.Acquire;
		try
		if  Watchers.IndexOf(APlayer) < 0 then
			Watchers.Add(APlayer);

		finally
		Lock.Release;
		end;
	end;

procedure TSnakeGame.RemoveWatcher(APlayer: TPlayer);
	begin
	Lock.Acquire;
		try
		Watchers.Remove(APlayer);

		finally
		Lock.Release;
		end;
	end;

// TileDelta (mcPlay/$09) - payload is [count, (row, col, tile) * count].
// General wire shape for "these cells changed" - Tick (below) is its
// first caller (the attract-mode bounce), but any future per-tick
// gameplay update rides the same message. Not gated on Watchers itself;
// callers are expected to only call this per-Watcher (see Tick).
procedure TSnakeGame.SendTileDeltas(APlayer: TPlayer; const ADeltas: array of TTileDelta);
	var
	m: TBaseMessage;
	i: Integer;

	begin
	m:= TBaseMessage.Create;
	m.Category:= mcPlay;
	m.Method:= $09;

	SetLength(m.Data, 1 + Length(ADeltas) * 3);
	m.Data[0]:= Length(ADeltas);

	for i:= 0 to High(ADeltas) do
		begin
		m.Data[1 + i * 3]:= ADeltas[i].Row;
		m.Data[1 + i * 3 + 1]:= ADeltas[i].Col;
		m.Data[1 + i * 3 + 2]:= ADeltas[i].Tile;
		end;

	APlayer.AddSendMessage(m);
	end;

// The demo circuit - the interior rectangle, one cell inside the wall
// border. The original's snakeMenu() hard-codes the equivalent numbers
// for its own 28x16 playfield (1/26 horizontally, 1/14 vertically);
// deriving them from the board size instead means the vertical growth
// to 20 rows needed no change here at all.
const
	DEMO_LEFT   = 1;
	DEMO_RIGHT  = BOARD_COLS - 2;
	DEMO_TOP    = 1;
	DEMO_BOTTOM = BOARD_ROWS - 2;

procedure TSnakeGame.InitDemoSnakes;
	var
	i, s: Integer;

	begin
	// Snake 1 runs along the bottom edge heading right, snake 2 along the
	// top edge heading left - both on the SAME circuit in the same
	// rotational direction, started half a lap apart, exactly as the
	// original's initSnakes lays them out. That's why they can chase each
	// other forever without ever meeting.
	DemoSnakes[0].Len:= DEMO_SNAKE_LEN;
	DemoSnakes[0].Dir:= sdRight;
	DemoSnakes[0].MoveTick:= 0;
	DemoSnakes[0].HeadTile:= TILE_SNAKE1_HEAD;
	DemoSnakes[0].BodyTile:= TILE_SNAKE1;

	for i:= 0 to DEMO_SNAKE_LEN - 1 do
		begin
		DemoSnakes[0].Body[i].Row:= DEMO_BOTTOM;
		DemoSnakes[0].Body[i].Col:= DEMO_LEFT + DEMO_SNAKE_LEN - 1 - i;
		end;

	DemoSnakes[1].Len:= DEMO_SNAKE_LEN;
	DemoSnakes[1].Dir:= sdLeft;
	DemoSnakes[1].MoveTick:= 0;
	DemoSnakes[1].HeadTile:= TILE_SNAKE2_HEAD;
	DemoSnakes[1].BodyTile:= TILE_SNAKE2;

	for i:= 0 to DEMO_SNAKE_LEN - 1 do
		begin
		DemoSnakes[1].Body[i].Row:= DEMO_TOP;
		DemoSnakes[1].Body[i].Col:= DEMO_RIGHT - DEMO_SNAKE_LEN + 1 + i;
		end;

	// Paint both onto Board itself, not just into the snake state - a
	// client syncing via SendBoardRows has to see the same thing a
	// TileDelta would have told it (see Board's own comment).
	for s:= 0 to High(DemoSnakes) do
		for i:= 0 to DemoSnakes[s].Len - 1 do
			with DemoSnakes[s].Body[i] do
				if  i = 0 then
					Board[Row][Col]:= DemoSnakes[s].HeadTile
				else
					Board[Row][Col]:= DemoSnakes[s].BodyTile;
	end;

procedure TSnakeGame.TickDemoSnakes(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i, s: Integer;
	head: TSnakeSeg;

	// Record one changed cell into both Board and the outgoing delta
	// list. Silently drops the delta if the caller's array is full -
	// Board stays authoritative either way, so the worst case is a cell
	// that looks stale until the next full sync, not a desync.
	procedure Emit(ARow, ACol, ATile: Byte);
		begin
		Board[ARow][ACol]:= ATile;

		if  ADeltaCount <= High(ADeltas) then
			begin
			ADeltas[ADeltaCount].Row:= ARow;
			ADeltas[ADeltaCount].Col:= ACol;
			ADeltas[ADeltaCount].Tile:= ATile;
			Inc(ADeltaCount);
			end;
		end;

	begin
	for s:= 0 to High(DemoSnakes) do
		begin
		// Per-snake countdown, not one shared timer - the original does
		// the same (objectsTick), which is what will let food speed-ups
		// give one snake a different pace from the other later.
		if  DemoSnakes[s].MoveTick > 0 then
			begin
			Dec(DemoSnakes[s].MoveTick);
			Continue;
			end;

		DemoSnakes[s].MoveTick:= SNAKE_MOVE_TICKS - 1;

		// The whole demo AI, straight out of the original's snakeMenu():
		// turn only when the head is sitting exactly on a circuit corner.
		head:= DemoSnakes[s].Body[0];

		if  (head.Row = DEMO_BOTTOM) and (head.Col = DEMO_LEFT) then
			DemoSnakes[s].Dir:= sdRight
		else if (head.Row = DEMO_BOTTOM) and (head.Col = DEMO_RIGHT) then
			DemoSnakes[s].Dir:= sdUp
		else if (head.Row = DEMO_TOP) and (head.Col = DEMO_RIGHT) then
			DemoSnakes[s].Dir:= sdLeft
		else if (head.Row = DEMO_TOP) and (head.Col = DEMO_LEFT) then
			DemoSnakes[s].Dir:= sdDown;

		case DemoSnakes[s].Dir of
			sdUp:    Dec(head.Row);
			sdDown:  Inc(head.Row);
			sdLeft:  Dec(head.Col);
			sdRight: Inc(head.Col);
			end;

		// Tail vacates first, so a snake exactly as long as the circuit
		// still can't collide with the cell it's about to leave.
		with DemoSnakes[s].Body[DemoSnakes[s].Len - 1] do
			Emit(Row, Col, TILE_FLOOR);

		for i:= DemoSnakes[s].Len - 1 downto 1 do
			DemoSnakes[s].Body[i]:= DemoSnakes[s].Body[i - 1];

		// Body[1] is the old head - it stops being the head this step, so
		// it has to be repainted as a body segment. Cheap now (both
		// render as $A0) but essential once the head has its own
		// direction tiles.
		with DemoSnakes[s].Body[1] do
			Emit(Row, Col, DemoSnakes[s].BodyTile);

		DemoSnakes[s].Body[0]:= head;
		Emit(head.Row, head.Col, DemoSnakes[s].HeadTile);
		end;
	end;

procedure TSnakeGame.Tick;
	var
	claimed: Boolean;
	i,
	deltaCount: Integer;
	deltas: array of TTileDelta;

	begin
	// 3 cells per moving snake (tail vacated, old head demoted to body,
	// new head), so 6 with both moving on the same tick - rounded up for
	// headroom. TickDemoSnakes drops anything past the end rather than
	// overrunning, so this is a ceiling, not an assumption.
	SetLength(deltas, 8);
	Lock.Acquire;
		try
		claimed:= False;
		for i:= 0 to 3 do
			if Assigned(Slots[i].Player) then
				claimed:= True;

		// Attract/demo mode is "0 corners claimed", not a separate
		// TGameState value (see the project's own design-decision
		// notes) - once a slot-claim protocol exists, a corner being
		// claimed mid-lap will just stop new deltas going out; nothing
		// currently resets whatever a client last drew, since there's
		// no way to claim a slot yet to actually exercise that case
		// (button_detail_start0-3 are still TODO stubs).
		if not claimed then
			begin
			deltaCount:= 0;

			TickDemoSnakes(deltas, deltaCount);

			// Nothing moved this tick (both snakes still counting down
			// to their next step) - don't send an empty broadcast.
			if deltaCount = 0 then
				Exit;

			// Each watcher sent individually inside its own try/except - a
			// stale watcher whose connection died without a clean WatchStop
			// (e.g. a client that crashed mid-test) must not be able to
			// throw here and kill TSnakeTickThread.Execute permanently,
			// which has no exception handling of its own and would
			// otherwise silently stop ticking for every watcher, forever,
			// with no crash visible anywhere (root-caused 2026-08-24 after
			// exactly one TileDelta message got through, then nothing -
			// see the client-side gameDeltaMsgCount diagnostic).
			for i:= 0 to Watchers.Count - 1 do
				try
				SendTileDeltas(Watchers[i], Copy(deltas, 0, deltaCount));

				except
				on E: Exception do
					AddLogMessage(slkError, 'Tick: SendTileDeltas failed for watcher - ' +
							E.Message);
				end;
			end;

		finally
		Lock.Release;
		end;
	end;

class function TSnakeGame.Name: AnsiString;
	begin
	Result:= 'game';
	end;

procedure TSnakeGame.ProcessPlayerMessage(APlayer: TPlayer;
        AMessage: TBaseMessage; var AHandled: Boolean);
	var
	i: Integer;

	procedure PeerMessageFromPlayer(APeer: TPlayer; AMessage: TBaseMessage);
		var
		m: TBaseMessage;

		begin
		m:= TBaseMessage.Create;

		m.Assign(AMessage);

		m.Category:= mcPlay;
		m.Method:= $04;

		APeer.AddSendMessage(m);
		end;

	begin
	if  AMessage.Category = mcPlay then
		begin
		// FIXME: this still expects chess's old RoomPeer-shaped payload
		// ([room, sender, message], method 4) and matches it against
		// Desc, but the client (clientSendGameChat, fw_ctrls_net.s) was
		// since corrected to send plain text only on method $0E with no
		// room-name field, since ProcessPlayerMessage is only ever
		// reached for players already in this game - see the comment on
		// clientSendGameChat. The two ends currently don't agree, so
		// chat doesn't actually work end-to-end yet - flagged for a
		// follow-up pass, deliberately not fixed as a drive-by here
		// since it's a separate concern from the board-row protocol.
		if  AMessage.Method = 4 then
			begin
			// Game chat - broadcast to everyone in the zone (spectators
			// included), not just the 4 claimed corners. Carried over
			// near-verbatim from chess's TChessGame.ProcessPlayerMessage,
			// which already worked this way (FPlayers is the zone's full
			// membership, not just Slots).
			AHandled:= True;

			AMessage.ExtractParams;
			if  (AMessage.Params.Count > 2)
			and (CompareText(string(Desc), string(AMessage.Params[0])) = 0) then
				begin
				AMessage.Params[1]:= Copy(APlayer.Name, Low(AnsiString), 8);

				AMessage.DataFromParams;

				with FPlayers.LockList do
					try
					for i:= 0 to Count - 1 do
						PeerMessageFromPlayer(Items[i], AMessage);

					finally
					FPlayers.UnlockList;
					end;
				end;
			end
		else if  AMessage.Method = $0A then
			begin
			// BoardRowsReq - client asks for 2 rows of the board, starting
			// at AMessage.Data[0]. Row-paginated full-board sync (see
			// SendBoardRows) rather than one big snapshot message, to
			// stay under the 254-byte payload cap. Silently ignores a
			// malformed/out-of-range request rather than erroring back -
			// this is an internal protocol driven entirely by our own
			// client code, not user-typed input, so there's nothing
			// meaningful to report if it's ever wrong.
			AHandled:= True;

			if  (Length(AMessage.Data) >= 1)
			and (AMessage.Data[0] <= BOARD_ROWS - 2)
			and (AMessage.Data[0] mod 2 = 0) then
				begin
				Lock.Acquire;
					try
					SendBoardRows(APlayer, AMessage.Data[0]);

					finally
					Lock.Release;
					end;
				end;
			end
		else if  AMessage.Method = $0C then
			begin
			// WatchStart - client is telling us its UI just switched to
			// the board page (page_detail). Doesn't push anything itself
			// - the client independently (re)starts its own row-fetch
			// sync the moment it starts watching (see gamePollTick,
			// snake_game.s) - this just adds APlayer to Watchers so the
			// future per-tick delta broadcast knows to include them.
			AHandled:= True;

			AddWatcher(APlayer);
			end
		else if  AMessage.Method = $0D then
			begin
			// WatchStop - client's UI just left the board page. See
			// WatchStart above.
			AHandled:= True;

			RemoveWatcher(APlayer);
			end;
		end;

	// TODO: slot-claim (press-start-on-one-of-4-corners), direction input,
	// and the dirty-cell board-delta broadcast all go here once the
	// tile/movement model is designed - see SnakeClasses.pas' TODO and
	// the project's own design-decision notes (spectator/slot model,
	// 6 ticks/sec, delta broadcast, 30x18 board for now).
	end;

procedure TSnakeGame.Remove(APlayer: TPlayer);
	var
	i,
	s: Integer;

	procedure SlotStatusToEveryone;
		var
		j: Integer;

		begin
		with FPlayers.LockList do
			try
			for j:= 0 to Count - 1 do
				SendSlotStatus(Items[j], s);

			finally
			FPlayers.UnlockList;
			end;
		end;

	begin
	Lock.Acquire;
		try
		s:= -1;
		for i:= 0 to 3 do
			if  Slots[i].Player = APlayer then
				begin
				s:= i;
				Break;
				end;

		if  s > -1 then
			begin
			// Dying/leaving just releases the corner back to spectator -
			// no forfeit/winner logic like chess's Remove, since there's
			// no synchronised 2-seat "game" to end here. The board just
			// keeps running with however many corners are still claimed,
			// down to 0 (demo/attract mode). Broadcast to everyone still
			// in the zone (not just the other corner-holders like chess
			// did), since spectators watching the board want to see this
			// too.
			Slots[s].Player:= nil;
			Slots[s].Name:= '';
			Slots[s].State:= psNone;

			SlotStatusToEveryone;
			end;

		// Leaving the zone entirely also means no longer watching -
		// unconditional (not just when s > -1), since a bare spectator
		// who never claimed a corner can still have been watching.
		// Already under Lock here, so this reaches into Watchers
		// directly rather than via RemoveWatcher (which would just
		// re-acquire the same Lock).
		Watchers.Remove(APlayer);

		finally
		Lock.Release;
		end;

	inherited;

	// Static board (from TPlayZone's fixed list, not created per-room) -
	// deliberately no ExpireZones.Add(Self)/self-destroy-on-empty here
	// like chess's dynamic per-room games. TODO: once the tick simulation
	// exists, PlayerCount = 0 is exactly the "nobody's even spectating"
	// case - decide then whether that should pause the sim or just keep
	// running as an empty demo board.
	end;

procedure TSnakeGame.SendGameStatus(APlayer: TPlayer);
	var
	m: TBaseMessage;

	begin
	m:= TBaseMessage.Create;
	m.Category:= mcPlay;
	m.Method:= $06;

	SetLength(m.Data, 1);
	m.Data[0]:= Ord(State);

    APlayer.AddSendMessage(m);
	end;

procedure TSnakeGame.SendSlotStatus(APlayer: TPlayer; ASlot: Integer);
	var
	m: TBaseMessage;

	begin
	m:= TBaseMessage.Create;
	m.Category:= mcPlay;
	m.Method:= $07;

	SetLength(m.Data, 2);
	m.Data[0]:= ASlot;
	m.Data[1]:= Ord(Slots[ASlot].State);

    APlayer.AddSendMessage(m);
	end;

// BoardRowsData (mcPlay/$0B) - reply to a client's BoardRowsReq
// (mcPlay/$0A, see ProcessPlayerMessage). AStartRow must be even and in
// range 0..BOARD_ROWS-2 - the caller (ProcessPlayerMessage) is
// responsible for validating/clamping, this just trusts it. Payload is
// [AStartRow, 30 bytes of row AStartRow, 30 bytes of row AStartRow+1] -
// 61 bytes total, comfortably under the 254-byte cap even with room to
// grow. Two rows/message was the user's own call (2026-08-24), over
// 1 row (simpler but slower to fully sync) or more than 2 (marginal
// speed gain, not worth the complexity).
procedure TSnakeGame.SendBoardRows(APlayer: TPlayer; AStartRow: Integer);
	var
	m: TBaseMessage;
	c: Integer;

	begin
	m:= TBaseMessage.Create;
	m.Category:= mcPlay;
	m.Method:= $0B;

	SetLength(m.Data, 1 + BOARD_COLS * 2);
	m.Data[0]:= AStartRow;

	for c:= 0 to BOARD_COLS - 1 do
		begin
		m.Data[1 + c]:= Board[AStartRow][c];
		m.Data[1 + BOARD_COLS + c]:= Board[AStartRow + 1][c];
		end;

	APlayer.AddSendMessage(m);
	end;

procedure TPlayZone.Add(APlayer: TPlayer);
	begin
	inherited;

	end;

type
	// TSnakeTickThread - paces TPlayZone.Tick at TICK_MS via
	// GetTickCount64 (SysUtils - FPC's portable monotonic ms source,
	// implemented per-platform under the hood, unlike Now/DateUtils -
	// see the project's own earlier design-decision notes on server
	// timing). Entirely implementation-local: nothing outside this unit
	// needs the concrete type, TPlayZone only stores it as a plain
	// TThread (see FTickThread's own comment).
	TSnakeTickThread = class(TThread)
	protected
		procedure Execute; override;

	public
		Zone: TPlayZone;
	end;

procedure TSnakeTickThread.Execute;
	var
	nextTick,
	now: QWord;

	begin
	{$IFDEF WINDOWS}
	// 1ms timer resolution for as long as we're ticking - see the
	// timeBeginPeriod comment at the top of the implementation section.
	timeBeginPeriod(1);
	try
	{$ENDIF}

	nextTick:= GetTickCount64 + TICK_MS;

	while not Terminated do
		begin
		now:= GetTickCount64;

		if now >= nextTick then
			begin
			// Advance the deadline by exactly one period rather than
			// re-basing it on 'now'. Re-basing (which this did until
			// 2026-08-24) silently absorbs every overshoot, so the real
			// rate is always slower than TICK_MS asks for and the error
			// never gets corrected - that was the other half of the 5%
			// shortfall measured on hardware.
			nextTick:= nextTick + TICK_MS;

			// ...but don't let a long stall turn into a burst of
			// catch-up ticks. If we're more than a few periods behind
			// (debugger break, machine sleep), give up on the lost time
			// and re-base.
			if now > (nextTick + TICK_MS * 4) then
				nextTick:= now + TICK_MS;

			Zone.Tick;
			end
		else
			Sleep(nextTick - now);
		end;

	{$IFDEF WINDOWS}
	finally
	timeEndPeriod(1);
	end;
	{$ENDIF}
	end;

constructor TPlayZone.Create;
	var
	i: Integer;
	g: TSnakeGame;
	t: TSnakeTickThread;

	begin
	inherited;

	FGames:= TSnakeGames.Create;

	// Static list (see ARR_SNAKE_BOARDS) - boards are seeded once here and
	// never created/destroyed at runtime, unlike chess's freeform
	// AddGame-on-any-typed-name behaviour.
	for i:= 0 to High(ARR_SNAKE_BOARDS) do
		begin
		g:= TSnakeGame.Create;

		g.Desc:= ARR_SNAKE_BOARDS[i];
		g.Play:= Self;

		FGames.Add(g);
		end;

	t:= TSnakeTickThread.Create(True);
	t.FreeOnTerminate:= False;
	t.Zone:= Self;
	FTickThread:= t;
	t.Start;
	end;

procedure TPlayZone.Tick;
	var
	i: Integer;

	begin
	with FGames.LockList do
		try
		for i:= 0 to Count - 1 do
			Items[i].Tick;

		finally
		FGames.UnlockList;
		end;
	end;

destructor TPlayZone.Destroy;
	var
	i: Integer;

	begin
	FTickThread.Terminate;
	FTickThread.WaitFor;
	FTickThread.Free;

	with FGames.LockList do
		try
		for i:= Count - 1 downto 0 do
			begin
			Items[i].Play:= nil;
			Items[i].Free;
			end;

		finally
		FGames.UnlockList;
		end;

	FGames.Free;

    inherited;
	end;

function TPlayZone.GameByName(ADesc: AnsiString): TSnakeGame;
	var
	i: Integer;

	begin
	Result:= nil;
	with FGames.LockList do
		try
		for i:= 0 to Count - 1 do
			if  CompareText(string(Items[i].Desc), string(ADesc)) = 0 then
				begin
				Result:= Items[i];
				Exit;
				end;
		finally
		FGames.UnlockList;
		end;
	end;

class function TPlayZone.Name: AnsiString;
	begin
	result:= 'play';
	end;

procedure TPlayZone.ProcessPlayerMessage(APlayer: TPlayer;
        AMessage: TBaseMessage; var AHandled: Boolean);
	var
	g: TSnakeGame;
	m: TBaseMessage;
	ml: TMessageList;
	i: Integer;

	begin
	if  AMessage.Category = mcPlay then
		if  AMessage.Method = 1 then
			begin
			AHandled:= True;
			AMessage.ExtractParams;

			if  AMessage.Params.Count = 1 then
				begin
				g:= GameByName(AMessage.Params[0]);

				if  Assigned(g) then
					begin
					g.Lock.Acquire;
						try
						// Joining is always spectating (see TSnakeGame.Add)
						// - there's no seat/slot contention to reject on
						// like chess's SlotCount<2 check, just the overall
						// spectator cap.
						if  g.PlayerCount < 64 then
							g.Add(APlayer)
						else
							begin
							m:= TBaseMessage.Create;
							m.Category:= mcPlay;
							m.Method:= $00;

							m.Params.Add(LIT_ERR_PLAYGMST);
							m.DataFromParams;

							APlayer.AddSendMessage(m);
							end;
						finally
						g.Lock.Release;
						end;
					end
				else
					APlayer.SendServerError(LIT_ERR_PLAYJINV);
				end
			else
				APlayer.SendServerError(LIT_ERR_PLAYJINV);
			end
		else if AMessage.Method = 2 then
			begin
			AMessage.ExtractParams;

			g:= GameByName(AMessage.Params[0]);

			if  Assigned(g) then
				begin
				g.Remove(APlayer);
				end
			else
				APlayer.SendServerError(LIT_ERR_PLAYPINV);

			AHandled:= True;
			end
		else if AMessage.Method = $03 then
			begin
			AHandled:= True;

			AMessage.ExtractParams;

			g:= nil;

			if  AMessage.Params.Count > 0 then
				begin
				g:= GameByName(AMessage.Params[0]);
				if  not Assigned(g) then
					begin
					APlayer.SendServerError(LIT_ERR_PLAYLINV);
					Exit;
					end;
				end;

			ml:= TMessageList.Create(APlayer);

			if  AMessage.Params.Count > 0 then
				begin
				// List everyone currently in this board's zone -
				// spectators and claimed corners alike, via the zone's
				// own public membership (PlayerCount/Players), not a
				// slot-only roster like chess used - there's no
				// password/membership gate to check here either.
				for i:= 0 to g.PlayerCount - 1 do
					ml.Data.Enqueue(g.Players[i].Name);
				end
			else
				with FGames.LockList do
					try
					for i:= 0 to Count - 1 do
						ml.Data.Enqueue(Items[i].Desc);

					finally
					FGames.UnlockList;
					end;

			m:= TBaseMessage.Create;
			m.Category:= mcText;
			m.Method:= $01;
			m.Params.Add(ml.Name);
			m.Params.Add(AnsiString(ARR_LIT_NAM_CATEGORY[mcPlay]));

			if  AMessage.Params.Count > 0 then
				m.Params.Add(g.Desc);

			m.DataFromParams;

            APlayer.AddSendMessage(m);

            ListMessages.Add(ml);
			end
	end;

procedure TPlayZone.Remove(APlayer: TPlayer);
	begin
	APlayer.RemoveZoneByClass(TSnakeGame);
	end;


initialization
    Randomize;

	ExpireZones:= TExpireZones.Create;
	ExpirePlayers:= TExpirePlayers.Create;

	ListMessages:= TMessageLists.Create;

	SystemZone:= TSystemZone.Create;
	LimboZone:= TLimboZone.Create;
	LobbyZone:= TLobbyZone.Create;
	PlayZone:= TPlayZone.Create;

finalization
	with ExpirePlayers.LockList do
		try
		while Count > 0 do
			begin
			Items[0].Free;
			Delete(0);
			end;
		finally
		ExpirePlayers.UnlockList;
		end;

	with ExpireZones.LockList do
		try
		while Count > 0 do
			begin
			Items[0].Free;
			Delete(0);
			end;
		finally
		ExpireZones.UnlockList;
		end;

	ServerDisp.Terminate;
	ServerDisp.WaitFor;
	ServerDisp.Free;

	DoDestroyListMessages;

	ExpireZones.Free;
    ExpirePlayers.Free;

	PlayZone.Free;
	LobbyZone.Free;
	LimboZone.Free;
	SystemZone.Free;

end.
