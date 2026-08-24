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

	// The 4 corners/players. Up here for the same reason -
	// TSnakeGame.DemoSnakes is declared in the type block below.
	SNAKE_PLAYER_COUNT = 4;

	// How many lava pools a wave seeds, and the hard ceiling on cells in
	// one pool. Up here for the same reason again - TDemoLava's cell
	// array and TSnakeGame.DemoLava both need them in scope. The
	// reasoning behind the VALUES sits with the lava constants below.
	//
	// The CAP is only the array bound. What a pool actually grows to
	// scales with difficulty - see LavaMaxCells.
	DEMO_LAVA_SEEDS = 2;
	DEMO_LAVA_CELLS_CAP = 32;

	// Bees in the attract wave, one per corner. Up here too -
	// TSnakeGame.DemoBees needs it. Reasoning with the other bee
	// constants further down.
	DEMO_BEE_COUNT = 4;

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

	// One body segment's board position, plus which pipe shape that cell
	// renders as (a SHAPE_* value - see their comment). The shape is a
	// property of the PATH through the cell, so once set it never
	// changes as the segment moves down the body toward the tail; only
	// the newly-vacated tail, the newly-demoted old head and the new
	// head ever need repainting on a step.
	// Body[0] is the head, matching the original's body[1]-is-head
	// convention (1-based there).
	TSnakeSeg = record
		Row, Col: Byte;
		Shape: Integer;
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

		// Dir is the way the snake ACTUALLY last travelled; Look is the
		// way it intends to go next. Separate for exactly the reason the
		// original separates move from look (server.lua): the head is
		// drawn from LOOK, so it visibly turns the moment the turn is
		// decided, one or more ticks before the body follows. The
		// original repaints the head as soon as input arrives
		// (playersTick) and only assigns move = look when the snake
		// actually steps (snakeMove) - and snakeMenu, the attract AI,
		// sets look too, so demo snakes get the same tell.
		//
		// Keeping Dir is not just bookkeeping: the corner left behind on
		// a turn needs the direction actually travelled IN to that cell,
		// which Look has already moved on from.
		Dir: TSnakeDir;
		Look: TSnakeDir;

		// Ticks left before this snake's next step - the original's
		// per-snake moveTick countdown (objectsTick), which is what
		// lets snakes move at different speeds off one shared tick.
		MoveTick: Integer;

		// Which of the 4 players this snake renders as (0-3) - decides
		// its colours client-side, via SnakeTile.
		Player: Integer;

		// Ticks of invulnerability left, and whether the body is
		// CURRENTLY painted in the flash tile. FlashOn is the painted
		// state, not the wanted one: comparing the two is what decides
		// whether a repaint has to go out this tick, so the body is only
		// re-emitted when the phase actually flips (or the burst ends)
		// rather than every tick. The original's equivalent is
		// invun/invunTicks (initSnakes, snakeInvunExp).
		InvunTicks: Integer;
		FlashOn: Boolean;
	end;

	// Which mechanic the attract reel is currently showing off. See
	// DEMO_WAVE_FIRST/LAST - the reel runs the implemented span of this
	// in order and then wraps.
	TDemoWave = (dwLava, dwBees, dwFood, dwBoss);

	// A lava pool's life: creep outward, sit at full extent, drain back.
	// dlpIdle is the beat between waves.
	TDemoLavaPhase = (dlpIdle, dlpGrow, dlpHold, dlpRecede);

	// One spreading lava pool. Cells are kept in CREATION ORDER, which
	// is doing three jobs at once: it fixes each cell's colour tier, it
	// makes recession newest-first (just walk backwards), and it means
	// the whole pool is one flat array with no per-cell bookkeeping.
	TDemoCell = record
		Row, Col: Byte;
	end;

	TDemoLava = record
		Cells: array[0..DEMO_LAVA_CELLS_CAP - 1] of TDemoCell;
		Count: Integer;
	end;

	// One bee. Target is a SNAKE INDEX picked at spawn and then KEPT -
	// dengland's call, and it is what stops the bees clumping: if each
	// re-picked the nearest head every step, bees that drifted near one
	// another would converge on the same snake and merge into a single
	// wall instead of staying four separate threats.
	TDemoBee = record
		Row, Col: Byte;
		Target: Integer;
		MoveTick: Integer;
		Active: Boolean;
	end;

	// The original's tGAMEDIFFICULTY (server.lua), ordinals and all:
	// training = 0 .. expert = 4. Difficulty seeds the level
	// progression rather than being consulted directly - the original
	// does `iLevelProgress = iGameDifficulty` and then increments
	// iLevelProgress per level cleared, so starting on hard and
	// reaching level 2 on normal are the same difficulty of level.
	// Hazard scaling reads the PROGRESS, never this.
	TGameDifficulty = (gdTraining, gdEasy, gdNormal, gdHard, gdExpert);

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
		DemoSnakes: array[0..SNAKE_PLAYER_COUNT - 1] of TDemoSnake;

		// Ticks until the next invulnerability burst is handed to a
		// randomly chosen demo snake. One counter for the whole board,
		// not one per snake, because only ever ONE snake flashes at a
		// time - see DEMO_INVUN_TICKS.
		DemoInvunNext: Integer;

		// This board's difficulty, and the level progression it seeds -
		// the original's iGameDifficulty / iLevelProgress pair. Hazard
		// scaling reads LevelProgress (see LavaMaxCells), never
		// Difficulty directly, so clearing levels makes an easy board
		// converge on a hard one exactly as the original intends.
		//
		// The eventual plan (dengland, 2026-08-24) is that the separate
		// game boards ARE the difficulty tiers - each one created with
		// its own starting difficulty and speed, so joining "board3"
		// means choosing how hard you want it. Deliberately not wired up
		// yet ("we'll wire that up much later"); every board is normal
		// for now. Attract mode already renders from these, so once they
		// do differ, each board's demo advertises what that board plays
		// like without any further work.
		Difficulty: TGameDifficulty;
		LevelProgress: Integer;

		// The attract reel: which mechanic is on stage, where its
		// animation has got to, and the tick counters driving both.
		DemoWave: TDemoWave;
		DemoLava: array[0..DEMO_LAVA_SEEDS - 1] of TDemoLava;
		DemoLavaPhase: TDemoLavaPhase;
		DemoLavaStep: Integer;

		// Ticks left in the lava's HOLD phase. Its own counter, not
		// DemoWaveWait: that one means "a wave gap is running" to
		// TickDemoWave, which decrements it and skips the wave entirely
		// while it is non-zero. Borrowing it for the hold meant the
		// hold was actually being driven by the gap logic with DemoWave
		// still dwLava, so the shake cue fired a SECOND time as the
		// pool began to drain (dengland, 2026-08-25: "its shaking when
		// the lava goes away too which isn't right").
		DemoLavaHold: Integer;

		DemoWaveWait: Integer;

		DemoBees: array[0..DEMO_BEE_COUNT - 1] of TDemoBee;
		DemoBeeLeft: Integer;

		DemoFoodLeft: Integer;

		// The boss needs no body array: it runs a fixed loop, and
		// RectWalk is stateless, so its whole state is how far round it
		// has got. Every segment's position AND shape derive from
		// (DemoBossDist - segment index). See TickDemoBoss.
		DemoBossDist: Integer;
		DemoBossStep: Integer;
		DemoBossLeft: Integer;

		// Whether the boss's body is CURRENTLY painted flashing - the
		// same painted-vs-wanted trick the demo snakes use, so the body
		// is only re-emitted when the phase actually flips.
		DemoBossFlashOn: Boolean;

		// Frames of screen shake owed to every watcher, set by the wave
		// code and drained by Tick. A flag rather than a direct send so
		// the wave procedures stay pure board logic and all the
		// per-watcher error handling lives in one place (see Tick).
		DemoShakePending: Integer;

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

		// Tell a watcher to shake its screen for AFrames frames - see
		// the implementation for why duration, not per-frame offsets.
		procedure SendShake(APlayer: TPlayer; AFrames: Integer);

		// SLOT CLAIM/RELEASE - a spectator taking or giving up one of the
		// four corners. Both return the slot affected, or -1 if nothing
		// happened; both broadcast SlotStatus themselves. Callers must
		// NOT hold Lock - these acquire it.
		function  ClaimSlot(APlayer: TPlayer; ASlot: Integer): Integer;
		function  ReleaseSlot(APlayer: TPlayer): Integer;

		// Broadcast one slot's state to everyone in the zone. Caller
		// must hold Lock.
		procedure SlotStatusToAll(ASlot: Integer);

		// LEVEL GEOMETRY - see the implementations and the LEVEL_*
		// constants. BuildLevelBase lays down bare floor inside a solid
		// border ring; DrawWallLine is the original's levelDrawLine;
		// DrawWallQuad reflects one line into all four quadrants so
		// every corner gets the same geometry; BuildLevel assembles one
		// of the LEVEL_VARIANTS at a given difficulty progress.
		procedure BuildLevelBase;
		procedure DrawWallLine(AR1, AC1, AR2, AC2: Integer);
		procedure DrawWallQuad(AR1, AC1, AR2, AC2: Integer);
		procedure BuildLevel(AVariant, AProgress: Integer);

		// Demo/attract mode - see DemoSnakes. InitDemoSnakes lays both
		// snakes out on the board (and writes them into Board);
		// TickDemoSnakes advances them one tick, appending whatever
		// cells changed to ADeltas.
		procedure InitDemoSnakes;
		procedure TickDemoSnakes(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);

		// Record one changed cell into both Board and the outgoing delta
		// list. Shared by the snakes and the hazard waves so there is
		// exactly one place that knows Board is the authority.
		procedure EmitCell(ARow, ACol, ATile: Byte;
				var ADeltas: array of TTileDelta; var ADeltaCount: Integer);

		// The attract reel - advances whichever hazard wave is on stage.
		// See TDemoWave.
		procedure TickDemoWave(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure TickDemoLava(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure TickDemoBees(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure TickDemoFood(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure TickDemoBoss(var ADeltas: array of TTileDelta;
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
		//	FPC defines UNIX and DARWIN for macOS, but NOT LINUX, so
		//	without this macOS would fall through and report itself as
		//	the generic 'unix' (spotted by dengland, 2026-08-24 - "I
		//	might have forgotten it since I can't build for it at all").
		//	Untested: there's no Mac here to build on. It's a
		//	compile-time string choice only, so on every other target
		//	DARWIN simply isn't defined and nothing changes.
			{$IFDEF DARWIN}
   	LIT_SYS_PLATFRM: AnsiString = 'macos';
			{$ELSE}
   	LIT_SYS_PLATFRM: AnsiString = 'unix';
			{$ENDIF}
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
// which is exactly the "it does lurch every now and then" dengland saw
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
	LIT_ERR_PLAYCINV: AnsiString = 'Invalid corner claim';
	LIT_ERR_PLAYCTKN: AnsiString = 'Corner already taken';
	LIT_ERR_PLAYCHAV: AnsiString = 'Already holding a corner';

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

	// SlotClaim (mcPlay/$05) payload - a specific corner 0..3, or this
	// for "any free one". The four-corner controls send a specific
	// corner (that is the design: a spectator presses the START on the
	// corner they want); ANY exists for a plain "just put me in"
	// affordance and costs nothing to support.
	SLOT_CLAIM_ANY = $FF;

	// Was the attract-mode bounce's lit cell, which the demo snakes below
	// have now replaced (2026-08-24). The value is deliberately left in
	// place rather than renumbered - the client's own gameTileChars/
	// gameTileColrs tables are indexed by these values, so keeping the
	// numbering stable means the snake tiles could be added without
	// disturbing anything already on the wire.
	TILE_ATTRACT = 2;

	// Snake segments, drawn as a CONNECTED PIPE: each cell's character
	// depends on which way the snake entered it and which way it left,
	// so a turn leaves a corner piece behind. Shapes are named by the
	// compass directions the pipe OPENS TOWARD, which is unambiguous -
	// describing them as left/right turns depends on which way you were
	// already going and reads as gibberish (user, 2026-08-24: "this and
	// that way left and right is a bit odd").
	//
	// Characters (user-supplied, 2026-08-24): SHAPE_HORZ $C0,
	// SHAPE_VERT $DD, SHAPE_WS $C9, SHAPE_NE $CA, SHAPE_NW $CB,
	// SHAPE_ES $D5. The client owns the actual characters - see
	// gameTileChars, snake_game.s.
	SHAPE_HORZ = 0;			// opens E-W
	SHAPE_VERT = 1;			// opens N-S
	SHAPE_WS   = 2;			// opens W+S
	SHAPE_NE   = 3;			// opens N+E
	SHAPE_NW   = 4;			// opens N+W
	SHAPE_ES   = 5;			// opens E+S
	SHAPE_COUNT = 6;

	// Head and body use the SAME six shapes and differ only in COLOUR.
	// Every segment is shaped by where the snake entered that cell and
	// where it leaves it - for the head, "leaves" means the turn it has
	// already committed to but not yet made (see TDemoSnake.Look), so a
	// turning head shows the corner piece one step EARLY. When it then
	// moves on, that cell keeps the identical character and only
	// changes colour to the body's, making the hand-off invisible.
	//
	// This is why dengland's character list has one "looking left or
	// right" and one "looking up or down" rather than four facings: a
	// head running straight is just a straight pipe.
	SNAKE_ROLE_BODY = 0;
	SNAKE_ROLE_HEAD = 1;
	SNAKE_ROLE_COUNT = 2;

	// Tile value = TILE_SNAKE_BASE
	//              + ((player * SNAKE_ROLE_COUNT) + role) * SHAPE_COUNT
	//              + shape
	// 5 render slots (4 players + the boss) x 2 roles x 6 shapes = 60
	// values, 3..62 - comfortably inside the one byte a delta carries.
	// All are reachable: heads take corner shapes too, one step before
	// they turn. See SnakeTile.
	TILE_SNAKE_BASE = 3;

	// A fifth RENDER slot after the four players, for the boss - cyan
	// body, purple head (dengland, 2026-08-25). It is a snake, so it
	// gets a slot in the same encoding rather than a tile range and a
	// lookup of its own: SnakeTile(SNAKE_SLOT_BOSS, role, shape) just
	// works, and every shaping helper (SegShape, the turn telegraph,
	// the flash) applies to it unchanged.
	//
	// Deliberately NOT folded into SNAKE_PLAYER_COUNT - that is the
	// number of CORNERS a human can claim, and it sizes Slots and
	// DemoSnakes. The boss is not a player.
	SNAKE_SLOT_BOSS = SNAKE_PLAYER_COUNT;
	SNAKE_RENDER_SLOTS = SNAKE_PLAYER_COUNT + 1;

	// One MORE block of 6 shapes straight after those (63..68): the
	// invulnerability flash body, white, shared by every snake.
	//
	// The original does the same thing - realiseSnake swaps the body to
	// a different texture index (5) while invun, rather than recolouring
	// - but its body has no shapes at all, just one flat texture, so its
	// flash is a single tile. Ours keeps the connected-pipe shape and
	// changes only the colour, otherwise a flashing snake would come
	// apart into disconnected blocks for half of every cycle and undo
	// the whole point of the pipe rendering.
	//
	// One shared block, not one per player: white is white, and the
	// point of the flash is that it OVERRIDES the player colour.
	TILE_SNAKE_FLASH_BASE = TILE_SNAKE_BASE
			+ (SNAKE_RENDER_SLOTS * SNAKE_ROLE_COUNT * SHAPE_COUNT);

	// Spreading lava (57..59), by AGE tier: the cells laid down first are
	// the hot core, the newest are the cooling crust at the edge. Tier is
	// fixed when a cell is created and never repainted, so a blob paints
	// itself into a bullseye as it grows for free - and since it recedes
	// newest-first, it visibly drains back toward its own bright centre.
	//
	// Placeholder colours (yellow/orange/brown heat ramp) - these are
	// mine, not dengland's, unlike the snake pipe characters. Easy to
	// respecify: they are three entries in the client's table.
	TILE_LAVA_BASE = TILE_SNAKE_FLASH_BASE + SHAPE_COUNT;
	LAVA_TIER_COUNT = 3;

	// Total distinct tile values. The client indexes gameTileChars /
	// gameTileColrs by raw tile value with NO bounds check (snake_game.s
	// says so explicitly), so these tables must have exactly this many
	// entries - if this number changes, they change with it.
	// Bee (60). One tile - bees have no shapes and no age, they just
	// move. Character $DA in colour $04, both dengland's.
	TILE_BEE = TILE_LAVA_BASE + LAVA_TIER_COUNT;

	// Food (61..64), in the original's own type order - see
	// snakeCheckEat. Note 0 and 1 are OPPOSITES in both growth and
	// speed, and each cancels the other's pending effect; they are not
	// "grow big / grow small".
	//
	//   0  clubs $58         growNone 18, moveFast  +9   600 pts
	//   1  solid circle $51  growEx   12, moveFast  -6   200 pts
	//   2  open circle $57                moveFast +24   400 pts
	//   3  heart $53         invun +24,   moveFast +12   500 pts
	//
	// Characters are dengland's (2026-08-25), bit 7 clear - the plain
	// forms, not the reversed ones. Solid circle reads as heavy for the
	// grow-and-slow food, open circle as light for the fast one, which
	// was his reasoning.
	TILE_FOOD_BASE = TILE_BEE + 1;
	FOOD_TYPE_COUNT = 4;

	TILE_COUNT = TILE_FOOD_BASE + FOOD_TYPE_COUNT;


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

	// Ticks between one demo snake step. dengland's own reading of the
	// original (2026-08-24): normal play is 3, flat out is 1, and the
	// DEMO snakes ran at 2 - deliberately a bit quicker than normal
	// play, which is what makes an attract screen look lively. At
	// TICK_MS=83 that's ~6 steps/sec for the demo, ~4 for normal play
	// and ~12 flat out.
	//
	// The gear names, in ticks-per-step (SMALLER is faster). These are
	// the original's tGAMESPEED values exactly:
	//   {slow = 4, normal = 3, fast = 2, turbo1 = 1, turbo2 = 0}
	// turbo2 is deliberately absent - server.lua:46 says "DO NOT USE
	// turbo settings, especially turbo2!", so TOP is the floor here.
	SNAKE_SPEED_SLOW   = 4;
	SNAKE_SPEED_NORMAL = 3;
	SNAKE_SPEED_FAST   = 2;
	SNAKE_SPEED_TOP    = 1;
	//
	// The original also modulates this per snake via moveFast (food
	// speed-ups and slow-downs, +30..-12, decaying 1/tick back toward
	// 0) - deliberately NOT implemented here, since demo snakes never
	// eat. When food lands, that becomes a per-snake offset applied to
	// this base, exactly as objectsTick does it.
	//
	// Attract mode runs at FAST: quicker than normal play so the demo
	// looks lively, but never TOP. Both halves are dengland's own rules
	// (2026-08-24), guarded below rather than left to a comment.
	//
	// NORMAL and TOP were each run briefly to judge the turn telegraph,
	// which lasts exactly one step - so its duration IS the step
	// duration: 250ms at NORMAL, 166ms at FAST, 83ms at TOP. Top speed
	// measured 12.1 cells/sec with four snakes and the client tracking
	// it perfectly, so the limit there is human rather than technical:
	// 83ms is below visual reaction time, making the top gear something
	// played from anticipation. User's verdict: "that's deadly with 4p".
	SNAKE_MOVE_TICKS = SNAKE_SPEED_FAST;

	// Top speed is what a powered-up player earns; an attract screen
	// handing it out for free undercuts that.
{$IF SNAKE_MOVE_TICKS <= SNAKE_SPEED_TOP}
	{$ERROR demo snakes must not run at top speed}
{$ENDIF}
{$IF SNAKE_MOVE_TICKS >= SNAKE_SPEED_NORMAL}
	{$ERROR demo snakes must be faster than normal play}
{$ENDIF}

	// Hard ceiling on a DEMO snake, well under MAX_SNAKE_LEN (user,
	// 2026-08-24: "much less say 8 or 10 so they don't collide too
	// much").
	//
	// The real constraint is geometric: all the demo snakes share one
	// circuit, evenly spaced, so the gap between them is
	// DEMO_LAP div SNAKE_PLAYER_COUNT. On the current 30x20 board that
	// lap is 80 cells and 4 snakes sit 20 apart, so anything from 20
	// up would have a snake's tail reach the head behind it. 10 leaves
	// half the gap clear. If the board, the inset or the player count
	// change, re-check this against that division rather than assuming
	// 10 is still safe - the compile-time guard further down does
	// exactly that check.
	DEMO_SNAKE_MAX_LEN = 10;

	// Starting length of each demo snake. Matches the original: attract
	// mode runs initSnakes(), whose non-battle branch builds 5-segment
	// bodies (server.lua:588-589).
	//
	// This was briefly raised to the ceiling while tuning the turn
	// telegraph, because a longer body makes the direction of travel
	// easier to read at a glance and the turn stands out against that.
	// The telegraph itself is unchanged and correct at either length -
	// if it ever reads poorly again, the fix is NOT to lengthen the
	// snakes, and it is not the timing either (three separate attempts
	// at a longer preview all put the corner in the wrong cell). See
	// TickDemoSnakes.
	DEMO_SNAKE_LEN = 5;

	// --- Attract-mode invulnerability showcase ---
	//
	// In the ORIGINAL, invulnerability is earned: eating food type 3
	// sets invun and adds 24 to invunTicks, hard-capped at 30
	// (snakeCheckEat), and snakes also spawn with 18 ticks of it
	// (initSnakes). Demo snakes never eat, so none of that fires here.
	//
	// So this schedule is a DEMO-ONLY invention to show the effect off,
	// dengland's rule (2026-08-24): pick a snake at random and
	// give it a 10-second burst. Note 10s is far longer than anything
	// the original grants - its 30-tick cap is only 2.5s at TICK_MS=83.
	// That is fine for an attract screen, whose job is to show you the
	// mechanic exists; it is NOT the gameplay value, and real play
	// should use the original's earn-it-and-cap-it rule instead.
	DEMO_INVUN_TICKS = 10000 div TICK_MS;

	// Quiet gap between bursts, so the flash reads as an EVENT rather
	// than a permanent state of the attract screen. Nothing in the
	// original to copy here - it exists only because a demo that is
	// always flashing somewhere stops drawing the eye.
	DEMO_INVUN_GAP_TICKS = 6000 div TICK_MS;

	// Ticks per flash half-cycle. 1 = flip every tick, which is what the
	// original does (realiseSnake: invunTicks % 2) - at TICK_MS=83 that
	// is a 6Hz flash. Raise to 2 for a slower 3Hz throb if 6 reads as
	// shimmer rather than flash on real hardware. Only 4 cells flash, so
	// this is a legibility question, not a brightness one.
	DEMO_INVUN_FLASH_TICKS = 1;

	// The demo circuit - a rectangle inset TWO cells from the board edge,
	// i.e. one clear cell between the snakes and the wall (dengland's own
	// call, 2026-08-24: "can we move them one tile in from the edge
	// though?"). The original's snakeMenu() hard-codes the equivalent
	// numbers for its own 28x16 playfield; deriving them from the board
	// size instead means neither the growth to 20 rows nor this inset
	// needed anything else changed.
	//
	// Declared here rather than beside the rest of the demo geometry
	// because TSnakeGame.Create needs them for the wall below, and it
	// comes earlier in the unit.
	DEMO_INSET  = 2;
	DEMO_LEFT   = DEMO_INSET;
	DEMO_RIGHT  = BOARD_COLS - 1 - DEMO_INSET;
	DEMO_TOP    = DEMO_INSET;
	DEMO_BOTTOM = BOARD_ROWS - 1 - DEMO_INSET;

	// A short wall across the middle of the circuit's interior, on the
	// lava seed row and centred between the two pools - see
	// TSnakeGame.Create. Placed so BOTH pools can reach it by creeping
	// inward, without either seed landing on it.
	DEMO_WALL_ROW   = (DEMO_TOP + DEMO_BOTTOM) div 2;
	DEMO_WALL_HALF  = 3;
	DEMO_WALL_LEFT  = ((DEMO_LEFT + DEMO_RIGHT) div 2) - DEMO_WALL_HALF;
	DEMO_WALL_RIGHT = ((DEMO_LEFT + DEMO_RIGHT) div 2) + DEMO_WALL_HALF;

	// --- Attract-mode hazard WAVES ---
	//
	// The attract screen runs a demo REEL (dengland, 2026-08-24):
	// each mechanic gets the stage in turn, then the cycle repeats -
	// lava, then bees, then food. Nothing like this is in the original,
	// whose attract mode only ever shows two snakes driving around; it
	// exists because an attract screen's job is to advertise what the
	// game HAS, and a mechanic nobody sees might as well not be built.
	//
	// Waves are built one at a time. DEMO_WAVE_LAST is the only thing
	// that needs changing to bring the next one into the rotation - the
	// cycle runs DEMO_WAVE_FIRST..DEMO_WAVE_LAST, so an unimplemented
	// wave is simply not in the reel yet rather than dead air on screen.
	//
	// DEMO_LAVA_SEEDS (2) and DEMO_LAVA_CELLS_CAP have to be
	// declared ahead of the type block - see the top of the unit.
	// DEMO_LAVA_SEEDS = 2 puts one pool either side of centre, which is
	// dengland's layout for the ATTRACT screen; the seeding code spaces
	// any count evenly.
	//
	// Real play gets ONE pool at a time (dengland, 2026-08-24). Two here
	// is a showcase decision - it fills the idle board and shows the
	// spread reading from both sides - not the game rule. Whatever
	// drives lava in real play should seed a single pool.
	//
	// How far a pool spreads, scaled by level progress the same way the
	// original scales bees (`iLevelBeesMax = 5 + iLevelProgress * 3`).
	// On the original's 5-point difficulty scale that gives:
	//
	//     training 12   easy 14   normal 16   hard 18   expert 20
	//
	// which is dengland's own calibration (2026-08-24): expert/"insane"
	// at 20-21, hard/"bad" three below that, normal two below again.
	// Progress keeps climbing as levels are cleared, so late levels go
	// past expert until DEMO_LAVA_CELLS_CAP stops them.
	DEMO_LAVA_CELLS_BASE = 12;
	DEMO_LAVA_CELLS_PER_LEVEL = 2;

	// Lava is confined to the INSIDE of the demo circuit, one cell clear
	// of it, so it can never overwrite a snake. That matters because the
	// demo has no collision at all: a lava cell landing on a snake would
	// sit there looking like corruption until that snake's tail happened
	// to pass over and clear it. Confining it is simpler and more
	// honest than trying to arbitrate.

	// Ticks between growth (and recession) steps, and how many cells
	// move per step per blob. The cap is what makes it CREEP rather than
	// pop, and it also bounds the delta burst: 2 blobs x 2 cells = 4
	// cells a step, against the 12 the snakes can already produce.
	//
	// Was 3 cells every 3 ticks (9 cells/sec) - "spreads a little fast
	// maybe" (dengland, 2026-08-24). Now 2 every 5, so a pool takes
	// about 4.5s to reach full extent instead of 2.5s.
	DEMO_LAVA_STEP_TICKS = 5;
	DEMO_LAVA_PER_STEP = 2;

	// Spread only from the most recently added cells, not from anywhere
	// in the pool. Picking a source uniformly means the cells around the
	// seed keep getting chosen, so the pool fills itself in as a solid
	// disc - "too dense in the middle" (dengland, 2026-08-24).
	// Restricting the source to the advancing front makes it creep
	// outward in lobes and tendrils, which is what actually reads as
	// spreading rather than inflating.
	DEMO_LAVA_FRONTIER = 8;

	// Cells of clearance lava keeps from any live snake's HEAD, as a
	// box (+/- this on both axes) - the original's checkPlaceBee idea,
	// applied to spreading instead of spawning. 2 matches the original's
	// figure.
	//
	// This does not change anything in the attract demo, where lava is
	// already confined well inside the circuit and can never come near a
	// snake. It is here so the rule is correct and in force the moment
	// lava is let out into real play, rather than being remembered then.
	DEMO_LAVA_HEAD_CLEAR = 2;

	// --- Bees ---
	//
	// DEMO_BEE_COUNT (4, one per corner) is declared ahead of the type
	// block - see the top of the unit. In real play the count should
	// scale with progress the way the original does it
	// (`iLevelBeesMax = 5 + iLevelProgress * 3`); four is a showcase
	// number, matching dengland's "4 bees in the corners".

	// Cells of clearance a bee needs from every head when it SPAWNS
	// (Chebyshev - max of the two axis distances). dengland's rule,
	// 2026-08-24, superseding the original's checkPlaceBee: that one
	// ANDs its axis tests, so it actually blocks the whole 5-wide row
	// band and column band through the head rather than a box. A plain
	// distance is both clearer and less punishing.
	DEMO_BEE_SPAWN_CLEAR = 5;

	// A bee's move is chosen from three options, weighted. Toward-weight
	// rises and stall-weight falls with progress, so difficulty changes
	// how OFTEN a bee acts, never how fast it moves when it does -
	// dengland's call, and the important one:
	//
	//   a slow bee is a PREDICTABLE bee. Scaling the rate down for easy
	//   play would make easy bees both slow and deterministic, which is
	//   exactly the solvable-by-geometry problem the stall option
	//   exists to prevent. Do not "simplify" this back into a rate.
	//
	//   progress   toward:random:stall      toward / random / stall
	//   training      2:1:3                    33% / 17% / 50%
	//   easy          2:1:2                    40% / 20% / 40%
	//   normal        2:1:1                    50% / 25% / 25%  <- his figure
	//   hard          3:1:1                    60% / 20% / 20%
	//   expert        4:1:1                    67% / 17% / 17%
	//
	// Stall never reaches zero, so arrival stays uncertain even at
	// expert.
	DEMO_BEE_WEIGHT_RANDOM = 1;

	// How long the bee wave holds the stage.
	DEMO_BEE_WAVE_TICKS = 9000 div TICK_MS;

	// --- Food ---
	//
	// The attract food wave is a straight DISPLAY of all four types, not
	// a simulation: one row above the middle wall and one below, every
	// other cell, cycling through the types (dengland, 2026-08-25 -
	// "two rows of it above and below the wall alternating each type
	// with spaces between them"). Demo snakes never eat, so there is
	// nothing to simulate yet; this exists to show what the four foods
	// LOOK like.
	//
	// Real play spawns them one at a time at random free cells with a
	// TTL of 16..28 and a cap of 5 outstanding (levelTick) - nothing
	// like this layout.
	// --- Boss ---
	//
	// The attract boss circles the middle wall (dengland, 2026-08-25:
	// "we can have the boss circling the wall after the food is shown").
	// A fixed loop, NOT an AI - it is the demo snakes' circuit trick on
	// a smaller rectangle, so it costs nothing and can't misbehave. The
	// real boss AI is a separate and much larger job; see the design
	// notes on why a snake AI is harder than the bees' (a bee is a
	// point and can bump harmlessly, a snake that walks into itself is
	// dead).
	//
	// Margin 2 rather than 1: hugging the wall gives a loop only 3 rows
	// tall, where the boss spends most of its time cornering and reads
	// as frantic rather than deliberate.
	DEMO_BOSS_MARGIN = 2;
	DEMO_BOSS_TOP    = DEMO_WALL_ROW - DEMO_BOSS_MARGIN;
	DEMO_BOSS_BOTTOM = DEMO_WALL_ROW + DEMO_BOSS_MARGIN;
	DEMO_BOSS_LEFT   = DEMO_WALL_LEFT - DEMO_BOSS_MARGIN;
	DEMO_BOSS_RIGHT  = DEMO_WALL_RIGHT + DEMO_BOSS_MARGIN;

	DEMO_BOSS_LAP = 2 * (DEMO_BOSS_RIGHT - DEMO_BOSS_LEFT)
			+ 2 * (DEMO_BOSS_BOTTOM - DEMO_BOSS_TOP);

	// Longer than a demo snake - it should read as something bigger
	// than the players, and length is the only cue for that (a head
	// running straight is the same character as its body).
	DEMO_BOSS_LEN = 8;

	// Slower than the demo snakes' FAST, so it reads as heavy.
	DEMO_BOSS_STEP_TICKS = SNAKE_SPEED_NORMAL;

	// Longer than the other waves (dengland, 2026-08-25). It moves at
	// NORMAL speed round a 28-cell loop, so 9s was barely a lap and a
	// half - not enough to read as circling. 14s is about two and a
	// half laps.
	DEMO_BOSS_WAVE_TICKS = 14000 div TICK_MS;

	DEMO_FOOD_STRIDE = 2;

	// Rows between the food and the wall - 2 leaves ONE clear tile
	// between them (dengland, 2026-08-25). Sitting directly against the
	// wall made the two read as one thick band.
	DEMO_FOOD_WALL_GAP = 2;
	DEMO_FOOD_WAVE_TICKS = 7000 div TICK_MS;

	// How long the pool sits at full extent before draining.
	DEMO_LAVA_HOLD_TICKS = 3000 div TICK_MS;

	// Gap after a wave finishes, before the next one starts - the same
	// reasoning as DEMO_INVUN_GAP_TICKS: back-to-back effects read as
	// noise, a beat of nothing makes each one an event.
	DEMO_WAVE_GAP_TICKS = 2000 div TICK_MS;

	// --- Screen shake, cued for the lava eruption ---
	//
	// dengland, 2026-08-25: shake "just before and then during the first
	// parts of the lava eruption". So it is cued DEMO_SHAKE_LEAD_MS
	// before the wave's gap runs out, and runs on past the seeding into
	// the first growth steps - the ground moves, then the lava arrives.
	//
	// Duration goes over in FRAMES, not ticks: the client jitters the
	// scroll registers per frame, and a tick is 83ms - far too coarse
	// to pace a shake by. PAL 50Hz assumed for the conversion.
	FRAME_MS = 20;

	DEMO_SHAKE_LEAD_MS = 800;
	DEMO_SHAKE_MS = 2200;

	DEMO_SHAKE_LEAD_TICKS = DEMO_SHAKE_LEAD_MS div TICK_MS;
	DEMO_SHAKE_FRAMES = DEMO_SHAKE_MS div FRAME_MS;


	// --- REAL LEVEL GEOMETRY -------------------------------------------
	//
	// Ported from the original's levelGenA..D (LUA/server.lua:1370-1465)
	// and its Bresenham levelDrawLine (:1338). This is the interior wall
	// layout a REAL game plays on, as opposed to the demo's single
	// hand-placed bar (DEMO_WALL_ROW and friends above), which exists
	// only to give the attract reel's hazards something to flow around.
	//
	// Two differences from the original are deliberate:
	//
	// 1. THE ORIGINAL HAS NO BORDER. Its bounds test is commented out
	//    (snakeCheckMove, :1026-1031) and nothing ever draws a frame, so
	//    a snake leaving the field indexes tUpdTiles out of range.
	//    QUADRO has always drawn a solid ring (now BuildLevelBase), and
	//    that stays - it is the same rule the walls already give us
	//    rather than a special case, and it is what the client already
	//    renders.
	//
	// 2. FOUR-FOLD SYMMETRY INSTEAD OF THE ORIGINAL'S HAND-PLACED PAIRS.
	//    The original is a 2-player game and its four lines are two
	//    roughly-mirrored pairs, eyeballed rather than generated - e.g.
	//    levelGenA's {3,7} pairs with {24,8}, which is not an exact
	//    reflection of anything. With four corners that stops being good
	//    enough: whatever geometry sits near one corner has to sit near
	//    all four, or the corners are not the same game. So a variant
	//    declares ONE line in the top-left quadrant and DrawWallQuad
	//    reflects it into the other three.
	//
	// Line COUNT is unchanged at four per level - the original drew four
	// by hand, this draws one shape four times.
	LEVEL_VARIANTS = 4;

	// Generated walls stay one cell clear of the demo circuit's track
	// (DEMO_INSET), and that clearance is not cosmetic. The demo snakes
	// restore TILE_FLOOR behind themselves rather than whatever was
	// there before, so a generated wall underneath the track would be
	// silently EATEN by the first snake to pass over it.
	LEVEL_INSET = DEMO_INSET + 1;

	// The top-left quadrant a variant's base line is declared in. Walls
	// are mirrored out of here, so a line is capped to the QUADRANT
	// rather than to the board - the original's caps of 8 and 5 assume
	// its own 30x18 field with no border and no inset, and a vertical
	// run of 8 does not fit in the seven rows this leaves.
	LEVEL_QUAD_TOP    = LEVEL_INSET;
	LEVEL_QUAD_LEFT   = LEVEL_INSET;
	LEVEL_QUAD_BOTTOM = (BOARD_ROWS div 2) - 1;
	LEVEL_QUAD_RIGHT  = (BOARD_COLS div 2) - 1;

	LEVEL_QUAD_ROWS = LEVEL_QUAD_BOTTOM - LEVEL_QUAD_TOP + 1;
	LEVEL_QUAD_COLS = LEVEL_QUAD_RIGHT - LEVEL_QUAD_LEFT + 1;

	// The original's own length scaling, kept exactly: a "long" run is
	// min((progress+1)*2, 8) and a "short" one min(progress+1, 5), each
	// then less one because they count cells TRAVELLED, not cells drawn.
	// Walls therefore GROW with difficulty, which is the original's
	// level-difficulty model and the reason boards can eventually BE the
	// difficulty tiers.
	LEVEL_LONG_CAP  = 8;
	LEVEL_SHORT_CAP = 5;

	// The boss needs a fifth spawn point when all four corners are taken,
	// and dengland put it in the middle (2026-08-25) - "the area in the
	// middle might be free but we can make it so anyway". It IS free:
	// measured across every variant at progress 0..20, the smallest
	// clear box at dead centre is 8x8. This carve is therefore a no-op
	// today and exists as a GUARANTEE - a future variant reaching the
	// middle would otherwise break the boss spawn silently, and this is
	// far cheaper than remembering to re-measure.
	//
	// Half-width, so the box is 2x this on each axis - the centre of an
	// even-sided board falls between cells and has no single middle.
	LEVEL_CENTRE_CLEAR = 2;


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

// SlotStatusToAll - tell everyone in the zone about one corner. Caller
// holds Lock.
//
// Everyone, not just the other corner-holders as chess did: QUADRO is
// spectator-first, and a spectator watching the board wants to see a
// corner change hands as much as the players do. Mirrors the same
// broadcast already inside Remove.
procedure TSnakeGame.SlotStatusToAll(ASlot: Integer);
	var
	j: Integer;

	begin
	with FPlayers.LockList do
		try
		for j:= 0 to Count - 1 do
			SendSlotStatus(Items[j], ASlot);

		finally
		FPlayers.UnlockList;
		end;
	end;

// ClaimSlot - a spectator takes one of the four corners. ASlot is
// 0..3, or SLOT_CLAIM_ANY for the lowest free one. Returns the slot
// claimed, or -1 if the claim was refused.
//
// Refusals are distinguished by the caller (see ProcessPlayerMessage)
// rather than folded into one error, because they mean genuinely
// different things to a player: the corner you pressed is taken, versus
// you already have one.
//
// Claiming does NOT spawn a snake yet - there is no movement model to
// spawn into. This is the corner-ownership half only; the spawn (with
// its shield and cleared start area, per the join-in-progress design)
// lands with the tick simulation.
function TSnakeGame.ClaimSlot(APlayer: TPlayer; ASlot: Integer): Integer;
	var
	i: Integer;

	begin
	Result:= -1;

	Lock.Acquire;
		try
		// One corner per player. Without this a client that double-fires
		// its control would silently occupy two corners and only ever
		// be released from one (Remove stops at the first match).
		for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
			if  Slots[i].Player = APlayer then
				Exit;

		if  ASlot = SLOT_CLAIM_ANY then
			begin
			for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
				if  not Assigned(Slots[i].Player) then
					begin
					ASlot:= i;
					Break;
					end;

			if  ASlot = SLOT_CLAIM_ANY then
				Exit;			// all four taken
			end
		else
			begin
			if  (ASlot < 0) or (ASlot > SNAKE_PLAYER_COUNT - 1) then
				Exit;

			if  Assigned(Slots[ASlot].Player) then
				Exit;
			end;

		Slots[ASlot].Player:= APlayer;
		Slots[ASlot].Name:= APlayer.Name;
		Slots[ASlot].State:= psPlaying;

		Result:= ASlot;

		SlotStatusToAll(ASlot);

		finally
		Lock.Release;
		end;
	end;

// ReleaseSlot - give up whatever corner this player holds, back to
// spectator. Returns the slot released, or -1 if they held none.
//
// Deliberately the same three assignments Remove makes, for the same
// reason: there is no forfeit or winner logic to run, the board just
// carries on with one fewer corner claimed - down to zero, which is
// attract mode.
function TSnakeGame.ReleaseSlot(APlayer: TPlayer): Integer;
	var
	i: Integer;

	begin
	Result:= -1;

	Lock.Acquire;
		try
		for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
			if  Slots[i].Player = APlayer then
				begin
				Slots[i].Player:= nil;
				Slots[i].Name:= '';
				Slots[i].State:= psNone;

				Result:= i;

				SlotStatusToAll(i);

				Break;
				end;

		finally
		Lock.Release;
		end;
	end;

// BuildLevelBase - a bare room: solid wall around the outside, floor
// everywhere inside. Every board starts here, demo or real, so there is
// exactly one place that knows what the border looks like.
//
// The border is QUADRO's own addition; see the LEVEL_* constants for why
// the original manages without one (it doesn't, quite).
procedure TSnakeGame.BuildLevelBase;
	var
	r, c: Integer;

	begin
	for r:= 0 to BOARD_ROWS - 1 do
		for c:= 0 to BOARD_COLS - 1 do
			if  (r = 0) or (r = BOARD_ROWS - 1)
			or  (c = 0) or (c = BOARD_COLS - 1) then
				Board[r][c]:= TILE_WALL
			else
				Board[r][c]:= TILE_FLOOR;
	end;

// DrawWallLine - the original's levelDrawLine (LUA/server.lua:1338),
// which is Bresenham from rosettacode. Kept rather than replaced because
// variants C and D draw shallow DIAGONALS, and a diagonal's exact step
// pattern is the shape - reimplementing it with a different rounding
// rule would quietly redraw those levels.
//
// Two changes from the original. It takes plain row/col integers instead
// of mutating {x,y} tables in place (the original's caller can never
// reuse a tPos, since levelDrawLine walks tPos1 to its destination); and
// every write is range-checked. The check is defence, not policy - the
// callers below stay inside the quadrant by construction - but Board is
// a fixed array and a bad progress value writing outside it would be the
// same class of wild write as the board-row bug fixed in the client.
procedure TSnakeGame.DrawWallLine(AR1, AC1, AR2, AC2: Integer);
	var
	dr, dc, sr, sc, err: Integer;

	begin
	if  AC1 < AC2 then
		sc:= 1
	else
		sc:= -1;

	if  AR1 < AR2 then
		sr:= 1
	else
		sr:= -1;

	dc:= Abs(AC2 - AC1);
	dr:= Abs(AR2 - AR1);

	if  dc > dr then
		err:= dc div 2
	else
		err:= -dr div 2;

	while True do
		begin
		if  (AR1 >= 0) and (AR1 <= BOARD_ROWS - 1)
		and (AC1 >= 0) and (AC1 <= BOARD_COLS - 1) then
			Board[AR1][AC1]:= TILE_WALL;

		if  (AC1 = AC2) and (AR1 = AR2) then
			Break;

		if  err > -dc then
			begin
			err:= err - dr;
			AC1:= AC1 + sc;

			if  (AC1 = AC2) and (AR1 = AR2) then
				begin
				if  (AR1 >= 0) and (AR1 <= BOARD_ROWS - 1)
				and (AC1 >= 0) and (AC1 <= BOARD_COLS - 1) then
					Board[AR1][AC1]:= TILE_WALL;

				Break;
				end;
			end;

		if  err < dr then
			begin
			err:= err + dc;
			AR1:= AR1 + sr;
			end;
		end;
	end;

// DrawWallQuad - draw a line and its three reflections, so all four
// corners see identical geometry. This is the whole of QUADRO's
// departure from the original's level layout; see the LEVEL_* constants
// for why four players make hand-placed pairs untenable.
//
// Reflections are about the board's centre lines, which for even
// dimensions fall BETWEEN cells - so col c maps to BOARD_COLS-1-c with
// no fixed column, and every line has three distinct images. On an odd
// dimension a line sitting exactly on the centre would map to itself and
// get drawn twice; harmless (it writes the same TILE_WALL) but worth
// knowing before anyone revisits the 29x20 board idea.
procedure TSnakeGame.DrawWallQuad(AR1, AC1, AR2, AC2: Integer);
	var
	mr, mc: Integer;

	begin
	mr:= BOARD_ROWS - 1;
	mc:= BOARD_COLS - 1;

	DrawWallLine(AR1, AC1, AR2, AC2);
	DrawWallLine(AR1, mc - AC1, AR2, mc - AC2);
	DrawWallLine(mr - AR1, AC1, mr - AR2, AC2);
	DrawWallLine(mr - AR1, mc - AC1, mr - AR2, mc - AC2);
	end;

// BuildLevel - lay out one of the four level variants at a given
// difficulty progress. Ported from levelGenA..D; see the LEVEL_*
// constants for what was kept and what changed.
//
// Each variant declares ONE line inside the top-left quadrant and hands
// it to DrawWallQuad. A and B are the axis-aligned pair (A long
// horizontal, B long vertical - the original alternates the same way),
// C and D the shallow diagonals, mirrored so C rises to the right and D
// falls.
//
// NOT YET CALLED FROM ANYWHERE. Real games do not start yet, and the
// attract reel deliberately does not use this: the demo's boss circles
// rows 7..11 / cols 9..19 painting TILE_FLOOR behind itself, which would
// erase any generated wall it crossed - variant A's line at row 8 runs
// straight through it. The demo's own bar stays demo scaffolding.
procedure TSnakeGame.BuildLevel(AVariant, AProgress: Integer);
	var
	long, short, drop, r, c: Integer;

	begin
	BuildLevelBase;

	// The original's scaling, then clamped to the quadrant so a run
	// cannot cross the centre line and collide with its own reflection.
	long:= (AProgress + 1) * 2;
	if  long > LEVEL_LONG_CAP then
		long:= LEVEL_LONG_CAP;

	short:= AProgress + 1;
	if  short > LEVEL_SHORT_CAP then
		short:= LEVEL_SHORT_CAP;

	Dec(long);
	Dec(short);

	if  long > LEVEL_QUAD_COLS - 1 then
		long:= LEVEL_QUAD_COLS - 1;
	if  short > LEVEL_QUAD_ROWS - 1 then
		short:= LEVEL_QUAD_ROWS - 1;

	case AVariant mod LEVEL_VARIANTS of
		// A - long horizontal, sitting one row above the centre line and
		// reaching inward from the left edge of the quadrant.
		0:	DrawWallQuad(LEVEL_QUAD_BOTTOM - 1, LEVEL_QUAD_LEFT,
					LEVEL_QUAD_BOTTOM - 1, LEVEL_QUAD_LEFT + long);

		// B - long vertical. The vertical cap bites here: the quadrant
		// is only LEVEL_QUAD_ROWS tall, so B's run is shorter than A's
		// at the same progress. That asymmetry is the board's shape
		// (30x20), not a mistake, and it is why B pushes its line
		// further in from the side to compensate.
		1:	DrawWallQuad(LEVEL_QUAD_TOP, LEVEL_QUAD_LEFT + 2,
					LEVEL_QUAD_TOP + short, LEVEL_QUAD_LEFT + 2);

		// C/D - the diagonals. The original derives the rise from the
		// run (iLenY2 = ceil(iLenX / 3)), giving a shallow slope that
		// stays readable as a wall rather than a staircase; kept, with
		// the ceiling done by hand since Pascal's Ceil wants floats.
		2:	begin
			drop:= (long + 2) div 3;
			DrawWallQuad(LEVEL_QUAD_BOTTOM, LEVEL_QUAD_LEFT,
					LEVEL_QUAD_BOTTOM - drop, LEVEL_QUAD_LEFT + long);
			end;

		3:	begin
			drop:= (long + 2) div 3;
			DrawWallQuad(LEVEL_QUAD_TOP, LEVEL_QUAD_LEFT,
					LEVEL_QUAD_TOP + drop, LEVEL_QUAD_LEFT + long);
			end;
		end;

	// Guarantee the boss's centre spawn - see LEVEL_CENTRE_CLEAR. Runs
	// after the variant, so it wins over anything a variant draws.
	for r:= (BOARD_ROWS div 2) - LEVEL_CENTRE_CLEAR
			to (BOARD_ROWS div 2) - 1 + LEVEL_CENTRE_CLEAR do
		for c:= (BOARD_COLS div 2) - LEVEL_CENTRE_CLEAR
				to (BOARD_COLS div 2) - 1 + LEVEL_CENTRE_CLEAR do
			Board[r][c]:= TILE_FLOOR;
	end;

constructor TSnakeGame.Create;
	var
	c: Integer;

	begin
	inherited;

	Lock:= TCriticalSection.Create;
	Watchers:= TList<TPlayer>.Create;

	// Every board is normal until boards carry their own difficulty -
	// see the field declarations. The original seeds progress from
	// difficulty the same way (`iLevelProgress = iGameDifficulty`).
	Difficulty:= gdNormal;
	LevelProgress:= Ord(Difficulty);

	// A plain bordered room - wall around the edge, empty floor inside.
	// This is the ATTRACT board; a real game will call BuildLevel
	// instead, which starts from the same base and then adds the level's
	// own interior geometry. The demo scaffolding below is deliberately
	// not part of that - see BuildLevel's own comment.
	BuildLevelBase;

	// A short wall across the middle, on the lava seed row and between
	// the two pools. Demo scaffolding, not a real level: lava has always
	// refused to spread through anything that is not bare floor, but
	// with an empty interior there was nothing for it to refuse AT, so
	// the rule was invisible. dengland asked for something to show the
	// pattern against (2026-08-24) - a tendril creeping inward along
	// this row now visibly stops dead and flows around it instead.
	//
	// Real level geometry now exists - see BuildLevel, ported from the
	// original's levelGenA..D and reworked for 4 corners. It is not used
	// here: the boss circuit and the food rows are both positioned off
	// this bar, and the demo paints TILE_FLOOR behind everything it
	// moves, so generated walls and the attract reel cannot share a
	// board without the reel slowly eating the level.
	for c:= DEMO_WALL_LEFT to DEMO_WALL_RIGHT do
		Board[DEMO_WALL_ROW][c]:= TILE_WALL;

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

// Shake (mcPlay/$0C) - payload is [frames]. "We can just send a message
// 'shake now' and have it last that long on the client" (dengland,
// 2026-08-25).
//
// One message, one duration, and the client owns the whole effect after
// that: it jitters the scroll registers itself, per FRAME, and stops on
// its own. Sending per-frame offsets from here instead would put a
// 50Hz visual on a 12Hz tick and burn the delta budget on something the
// client can generate for free.
procedure TSnakeGame.SendShake(APlayer: TPlayer; AFrames: Integer);
	var
	m: TBaseMessage;

	begin
	if  AFrames > 255 then
		AFrames:= 255;

	m:= TBaseMessage.Create;
	m.Category:= mcPlay;
	m.Method:= $0C;

	SetLength(m.Data, 1);
	m.Data[0]:= AFrames;

	APlayer.AddSendMessage(m);
	end;

const
	// Lap length in cells, walking the rectangle's perimeter.
	DEMO_RUN_H  = DEMO_RIGHT - DEMO_LEFT;
	DEMO_RUN_V  = DEMO_BOTTOM - DEMO_TOP;
	DEMO_LAP    = 2 * DEMO_RUN_H + 2 * DEMO_RUN_V;

	// Gap between consecutive snakes on the shared circuit.
	DEMO_SPACING = DEMO_LAP div SNAKE_PLAYER_COUNT;

// Enforced rather than left as a comment to re-check: the demo snakes
// only stay clear of each other because they're evenly spaced on one
// circuit, so a snake must be shorter than the gap or its tail reaches
// the head behind it. Board size, DEMO_INSET and SNAKE_PLAYER_COUNT all
// feed DEMO_SPACING, so any of them changing can break this silently.
{$IF DEMO_SNAKE_MAX_LEN >= DEMO_SPACING}
	{$ERROR DEMO_SNAKE_MAX_LEN must be less than DEMO_SPACING - demo snakes would collide}
{$ENDIF}
{$IF DEMO_SNAKE_LEN > DEMO_SNAKE_MAX_LEN}
	{$ERROR DEMO_SNAKE_LEN exceeds DEMO_SNAKE_MAX_LEN}
{$ENDIF}

// A tile value has to fit the single byte a TTileDelta carries, and the
// client's lookup tables are indexed by it with no bounds check.
{$IF TILE_COUNT > 256}
	{$ERROR TILE_COUNT exceeds the one byte a TileDelta tile value has}
{$ENDIF}

// A burst that rounds to nothing would leave the flash permanently off
// with no other symptom - TICK_MS could grow enough to do that.
{$IF DEMO_INVUN_TICKS < 1}
	{$ERROR DEMO_INVUN_TICKS rounded to zero - check TICK_MS}
{$ENDIF}

// The boss must be shorter than its own loop, or its tail would still
// occupy the cell its head is arriving at and it would paint over
// itself. Same reasoning as DEMO_SNAKE_MAX_LEN vs DEMO_SPACING, and it
// matters here because the loop is derived from the WALL's size - move
// the wall and this can break silently.
{$IF DEMO_BOSS_LEN >= DEMO_BOSS_LAP}
	{$ERROR DEMO_BOSS_LEN must be less than DEMO_BOSS_LAP}
{$ENDIF}

// Tile value for one snake segment - see the SHAPE_*/SNAKE_ROLE_*
// constants for the encoding.
function SnakeTile(APlayer, ARole, AShape: Integer): Byte;
	begin
	Result:= TILE_SNAKE_BASE
			+ (((APlayer * SNAKE_ROLE_COUNT) + ARole) * SHAPE_COUNT)
			+ AShape;
	end;

// Tile value for one BODY segment, honouring the invulnerability flash.
// Only the body ever flashes - the head keeps its own look tile
// throughout, exactly as the original does it: realiseSnake draws
// body[1] (the head) from tSnakeLook BEFORE testing invun at all, and
// the flash loop starts at i = 2.
function SnakeBodyTile(APlayer, AShape: Integer; AFlashing: Boolean): Byte;
	begin
	if  AFlashing then
		Result:= TILE_SNAKE_FLASH_BASE + AShape
	else
		Result:= SnakeTile(APlayer, SNAKE_ROLE_BODY, AShape);
	end;

// The shape of a cell a snake entered travelling ADirIn and left
// travelling ADirOut. A corner opens toward the REVERSE of the way it
// came in, plus the way it went out - naming the shapes by the compass
// directions they open toward (rather than by "turning left/right")
// is what makes this table readable at all.
function SegShape(ADirIn, ADirOut: TSnakeDir): Integer;
	begin
	if  ADirIn = ADirOut then
		begin
		if  ADirIn in [sdLeft, sdRight] then
			Result:= SHAPE_HORZ
		else
			Result:= SHAPE_VERT;

		Exit;
		end;

	// Reversing into itself is impossible for a snake, so only the four
	// genuine corners can occur; SHAPE_HORZ is an inert default rather
	// than a meaningful case.
	Result:= SHAPE_HORZ;

	if  ((ADirIn = sdRight) and (ADirOut = sdDown))
	or  ((ADirIn = sdUp) and (ADirOut = sdLeft)) then
		Result:= SHAPE_WS
	else if ((ADirIn = sdDown) and (ADirOut = sdRight))
	or      ((ADirIn = sdLeft) and (ADirOut = sdUp)) then
		Result:= SHAPE_NE
	else if ((ADirIn = sdRight) and (ADirOut = sdUp))
	or      ((ADirIn = sdDown) and (ADirOut = sdLeft)) then
		Result:= SHAPE_NW
	else if ((ADirIn = sdLeft) and (ADirOut = sdDown))
	or      ((ADirIn = sdUp) and (ADirOut = sdRight)) then
		Result:= SHAPE_ES;
	end;

// Move one cell in ADir.
procedure StepCell(var ARow, ACol: Byte; ADir: TSnakeDir);
	begin
	case ADir of
		sdUp:    Dec(ARow);
		sdDown:  Inc(ARow);
		sdLeft:  Dec(ACol);
		sdRight: Inc(ACol);
		end;
	end;

// The whole demo AI, straight out of the original's snakeMenu(): turn
// only when the head is sitting exactly on a circuit corner, otherwise
// keep going. Returns the direction the snake should LOOK from the cell
// it currently occupies - called the moment the head arrives somewhere,
// not when it leaves, which is what produces the early head turn.
function DemoLookFrom(ARow, ACol: Byte; ADir: TSnakeDir): TSnakeDir;
	begin
	Result:= ADir;

	if  (ARow = DEMO_BOTTOM) and (ACol = DEMO_LEFT) then
		Result:= sdRight
	else if (ARow = DEMO_BOTTOM) and (ACol = DEMO_RIGHT) then
		Result:= sdUp
	else if (ARow = DEMO_TOP) and (ACol = DEMO_RIGHT) then
		Result:= sdLeft
	else if (ARow = DEMO_TOP) and (ACol = DEMO_LEFT) then
		Result:= sdDown;
	end;

// Where a snake is after ADist steps around the circuit from the
// bottom-left corner, and which way it leaves that cell. Making the
// circuit parametric is what lets any number of snakes be spaced evenly
// around it without hand-placing each one - including snakes whose
// bodies straddle a corner at spawn, which hand-placement got wrong.
// Walk ADist cells anticlockwise round the perimeter of an arbitrary
// rectangle. Generalised out of CircuitAt so the boss can run its own
// smaller loop around the middle wall on exactly the same code - see
// BossAt.
//
// Note this is STATELESS: a cell's position and the direction leaving
// it depend only on the distance. That is what lets a snake on a fixed
// loop be stored as nothing but a distance counter, with no body array
// and no per-segment bookkeeping at all.
procedure RectWalk(ADist, ATop, ALeft, ABottom, ARight: Integer;
		out ARow, ACol: Byte; out ADir: TSnakeDir);
	var
	d, runh, runv, lap: Integer;

	begin
	runh:= ARight - ALeft;
	runv:= ABottom - ATop;
	lap:= 2 * runh + 2 * runv;

	d:= ((ADist mod lap) + lap) mod lap;

	if  d < runh then
		begin					// along the bottom, heading right
		ARow:= ABottom;
		ACol:= ALeft + d;
		ADir:= sdRight;
		end
	else if d < (runh + runv) then
		begin					// up the right side
		ARow:= ABottom - (d - runh);
		ACol:= ARight;
		ADir:= sdUp;
		end
	else if d < (2 * runh + runv) then
		begin					// along the top, heading left
		ARow:= ATop;
		ACol:= ARight - (d - runh - runv);
		ADir:= sdLeft;
		end
	else
		begin					// down the left side
		ARow:= ATop + (d - 2 * runh - runv);
		ACol:= ALeft;
		ADir:= sdDown;
		end;
	end;

procedure CircuitAt(ADist: Integer; out ARow, ACol: Byte; out ADir: TSnakeDir);
	begin
	RectWalk(ADist, DEMO_TOP, DEMO_LEFT, DEMO_BOTTOM, DEMO_RIGHT,
			ARow, ACol, ADir);
	end;

procedure TSnakeGame.InitDemoSnakes;
	var
	b, i, s, d, spacing: Integer;
	dirIn, dirOut: TSnakeDir;
	r, c,
	rPrev, cPrev: Byte;

	begin
	// All four snakes run the SAME circuit in the same rotational
	// direction, spaced evenly around it - so they chase each other
	// forever and never meet, which is why the demo needs no collision
	// handling at all. The original runs two, half a lap apart
	// (initSnakes); four at quarter-lap spacing is the same idea, and
	// shows all four player colours on the attract screen.
	spacing:= DEMO_LAP div Length(DemoSnakes);

	// Open on a quiet gap rather than an immediate flash - the attract
	// screen should establish what a normal snake looks like before it
	// shows one behaving unusually, or the flash reads as the default.
	DemoInvunNext:= DEMO_INVUN_GAP_TICKS;

	// The reel starts on the first wave, after the same settling beat.
	DemoWave:= dwLava;
	DemoLavaPhase:= dlpIdle;
	DemoLavaStep:= 0;
	DemoLavaHold:= 0;
	DemoWaveWait:= DEMO_WAVE_GAP_TICKS;

	for b:= 0 to High(DemoLava) do
		DemoLava[b].Count:= 0;

	DemoBeeLeft:= 0;
	DemoFoodLeft:= 0;
	DemoBossLeft:= 0;
	DemoShakePending:= 0;

	for b:= 0 to High(DemoBees) do
		DemoBees[b].Active:= False;

	for s:= 0 to High(DemoSnakes) do
		begin
		DemoSnakes[s].Len:= DEMO_SNAKE_LEN;
		DemoSnakes[s].MoveTick:= 0;
		DemoSnakes[s].Player:= s;
		DemoSnakes[s].InvunTicks:= 0;
		DemoSnakes[s].FlashOn:= False;

		// Head at its own offset, body trailing back along the circuit.
		for i:= 0 to DEMO_SNAKE_LEN - 1 do
			begin
			d:= (s * spacing) - i;

			// dirOut is the way the snake leaves this cell; dirIn is the
			// way it arrived, which is the direction of the step from the
			// cell BEFORE it.
			CircuitAt(d, r, c, dirOut);
			CircuitAt(d - 1, rPrev, cPrev, dirIn);

			DemoSnakes[s].Body[i].Row:= r;
			DemoSnakes[s].Body[i].Col:= c;

			// Every segment, head included, is shaped the same way: by
			// where the snake came from and where it goes next. For the
			// head that means a snake spawned exactly on a corner starts
			// already showing the corner, the same tell it gets in play.
			DemoSnakes[s].Body[i].Shape:= SegShape(dirIn, dirOut);

			if  i = 0 then
				begin
				DemoSnakes[s].Dir:= dirIn;	// how it got here
				DemoSnakes[s].Look:= dirOut;	// where it's going
				end;
			end;
		end;

	// Paint them onto Board itself, not just into the snake state - a
	// client syncing via SendBoardRows has to see the same thing a
	// TileDelta would have told it (see Board's own comment).
	for s:= 0 to High(DemoSnakes) do
		for i:= 0 to DemoSnakes[s].Len - 1 do
			with DemoSnakes[s].Body[i] do
				if  i = 0 then
					Board[Row][Col]:= SnakeTile(DemoSnakes[s].Player,
							SNAKE_ROLE_HEAD, Shape)
				else
					Board[Row][Col]:= SnakeTile(DemoSnakes[s].Player,
							SNAKE_ROLE_BODY, Shape);
	end;

// Record one changed cell into both Board and the outgoing delta list.
// Silently drops the delta if the caller's array is full - Board stays
// authoritative either way, so the worst case is a cell that looks
// stale until the next full sync, not a desync.
procedure TSnakeGame.EmitCell(ARow, ACol, ATile: Byte;
		var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
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

procedure TSnakeGame.TickDemoSnakes(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i, s: Integer;
	head: TSnakeSeg;
	prevDir: TSnakeDir;
	wantFlash, repaint: Boolean;

	procedure Emit(ARow, ACol, ATile: Byte);
		begin
		EmitCell(ARow, ACol, ATile, ADeltas, ADeltaCount);
		end;

	// Re-emit every BODY segment of snake ASnake at its current flash
	// phase. Only called when the phase actually flipped (or a burst
	// started/ended), since the movement path alone never touches
	// segments behind Body[1] - they'd otherwise keep whatever colour
	// they were painted with when they were laid down.
	procedure RepaintBody(ASnake: Integer);
		var
		j: Integer;

		begin
		for j:= 1 to DemoSnakes[ASnake].Len - 1 do
			with DemoSnakes[ASnake].Body[j] do
				Emit(Row, Col, SnakeBodyTile(DemoSnakes[ASnake].Player,
						Shape, DemoSnakes[ASnake].FlashOn));
		end;

	begin
	// Hand a fresh burst to a randomly chosen snake when the last one
	// has run its course and the gap after it has elapsed. One at a
	// time by construction: the next countdown covers the whole burst
	// plus the gap, so it can't start a second while one is running.
	if  DemoInvunNext > 0 then
		Dec(DemoInvunNext)
	else
		begin
		DemoSnakes[Random(Length(DemoSnakes))].InvunTicks:= DEMO_INVUN_TICKS;
		DemoInvunNext:= DEMO_INVUN_TICKS + DEMO_INVUN_GAP_TICKS;
		end;

	for s:= 0 to High(DemoSnakes) do
		begin
		// Invulnerability runs on the TICK, not on the step - it has to
		// count down and flash even on ticks where this snake doesn't
		// move, so it sits above the MoveTick early-out below. The
		// original separates them the same way (snakeInvunExp is called
		// per tick, independently of the moveTick countdown).
		if  DemoSnakes[s].InvunTicks > 0 then
			Dec(DemoSnakes[s].InvunTicks);

		wantFlash:= (DemoSnakes[s].InvunTicks > 0)
				and (((DemoSnakes[s].InvunTicks div DEMO_INVUN_FLASH_TICKS)
					and 1) = 0);

		// Comparing wanted against painted catches the burst ENDING for
		// free: InvunTicks hits 0, wantFlash goes False, and the body
		// gets repainted back to the player's own colour by the same
		// path that flips it mid-burst.
		repaint:= wantFlash <> DemoSnakes[s].FlashOn;
		DemoSnakes[s].FlashOn:= wantFlash;

		// Per-snake countdown, not one shared timer - the original does
		// the same (objectsTick), which is what will let food speed-ups
		// give one snake a different pace from the other later.
		if  DemoSnakes[s].MoveTick > 0 then
			begin
			Dec(DemoSnakes[s].MoveTick);

			if  repaint then
				RepaintBody(s);

			Continue;
			end;

		DemoSnakes[s].MoveTick:= SNAKE_MOVE_TICKS - 1;

		// The direction the head ARRIVED at its current cell with - what
		// decides whether the cell it's about to leave becomes a
		// straight or a corner.
		prevDir:= DemoSnakes[s].Dir;

		// Commit the turn that was already decided when the head landed
		// here (see the end of this loop), the original's
		// "move = look" in snakeMove. Nothing is chosen at this point;
		// the head has been visibly looking this way for a tick or more
		// already, which is the whole point.
		DemoSnakes[s].Dir:= DemoSnakes[s].Look;

		head:= DemoSnakes[s].Body[0];
		StepCell(head.Row, head.Col, DemoSnakes[s].Dir);

		// Tail vacates first, so a snake exactly as long as the circuit
		// still can't collide with the cell it's about to leave.
		with DemoSnakes[s].Body[DemoSnakes[s].Len - 1] do
			Emit(Row, Col, TILE_FLOOR);

		for i:= DemoSnakes[s].Len - 1 downto 1 do
			DemoSnakes[s].Body[i]:= DemoSnakes[s].Body[i - 1];

		// Body[1] is the old head. It stops being the head this step, so
		// it repaints as a body segment - and THIS is the cell that
		// becomes a corner when the snake turned, since the head itself
		// has already moved out of the turn. Entered travelling prevDir,
		// left travelling the (possibly new) Dir.
		DemoSnakes[s].Body[1].Shape:= SegShape(prevDir, DemoSnakes[s].Dir);
		with DemoSnakes[s].Body[1] do
			Emit(Row, Col, SnakeBodyTile(DemoSnakes[s].Player, Shape,
					DemoSnakes[s].FlashOn));

		// Decide the NEXT turn immediately on arrival - the original's
		// early head turn (user, 2026-08-24: "I wanted the head to turn
		// before the actual moment", and later "like the ghosts in
		// pacman?" - yes, the same telegraph: the eyes commit to the
		// corner a beat before the body does). Costs nothing extra, the
		// head's tile is emitted this step regardless.
		//
		// The telegraph lasts EXACTLY ONE STEP, and only ever appears
		// on the turn cell itself. Two longer variants were tried and
		// both rejected: showing it a whole cell early (2 steps) and on
		// the last tick before the step (3 ticks) both put the corner
		// in the cell BEFORE the turn, which is simply the wrong cell -
		// "its happening in the wrong cell really" (user).
		//
		// One step is also right for gameplay, not just a limitation:
		// the preview is a fixed number of STEPS, so its duration
		// shrinks as the snake speeds up. "It should be harder to see
		// the faster you are. But still controllable at the fastest
		// speed" (user). Reaction time getting shorter with speed is
		// what makes the top gear demanding - so DON'T decouple this
		// from the step rate to make it more visible.
		DemoSnakes[s].Look:= DemoLookFrom(head.Row, head.Col,
				DemoSnakes[s].Dir);

		// Shape the head by where it came FROM and where it's turning
		// toward, so it shows the CORNER piece rather than a bare bar
		// on the new axis, which wouldn't join the body behind it
		// (dengland's own correction: "it shouldn't be the new direction so
		// much as the turning into it one... the same that would have
		// been there for going around the corner, just earlier").
		//
		// At the corner itself this also makes the hand-off seamless:
		// next step the head moves on and this cell becomes Body[1]
		// with SegShape(prevDir, Dir) - the SAME corner. The character
		// never changes, only the colour, head -> body.
		head.Shape:= SegShape(DemoSnakes[s].Dir, DemoSnakes[s].Look);
		DemoSnakes[s].Body[0]:= head;
		Emit(head.Row, head.Col, SnakeTile(DemoSnakes[s].Player,
				SNAKE_ROLE_HEAD, head.Shape));

		// After the move, so it paints the segments where they now ARE
		// rather than where they were - and so the tail cell that just
		// got cleared isn't painted white on its way out.
		if  repaint then
			RepaintBody(s);
		end;
	end;

// How far one pool spreads at this level progress - see
// DEMO_LAVA_CELLS_BASE. Clamped to the array bound so a long game can't
// walk off the end of TDemoLava.Cells.
function LavaMaxCells(AProgress: Integer): Integer;
	begin
	Result:= DEMO_LAVA_CELLS_BASE + AProgress * DEMO_LAVA_CELLS_PER_LEVEL;

	if  Result > DEMO_LAVA_CELLS_CAP then
		Result:= DEMO_LAVA_CELLS_CAP;
	end;

// The colour tier for the AGE-th cell of a lava pool. Fixed when the
// cell is laid down and never repainted: earliest third is the hot
// core, latest third the cooling crust, so the pool paints itself into
// a bullseye as it spreads without any repainting at all.
//
// Tiered against the pool's ACTUAL extent, not the array bound, or an
// easy level would come out all core and never show the ramp.
function LavaTile(AAge, AMax: Integer): Byte;
	var
	tier: Integer;

	begin
	if  AMax < 1 then
		AMax:= 1;

	tier:= (AAge * LAVA_TIER_COUNT) div AMax;

	if  tier >= LAVA_TIER_COUNT then
		tier:= LAVA_TIER_COUNT - 1;

	Result:= TILE_LAVA_BASE + tier;
	end;

procedure TSnakeGame.TickDemoLava(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	b, i, n, tries, grown: Integer;
	full: Boolean;
	r, c, maxcells: Integer;

	// True if (ARow, ACol) is too close to any live snake's head for
	// lava to be allowed to appear there - see the call site.
	function LavaBlockedNearHead(ARow, ACol: Integer): Boolean;
		var
		k: Integer;

		begin
		Result:= True;

		for k:= 0 to High(DemoSnakes) do
			with DemoSnakes[k].Body[0] do
				if  (Abs(ARow - Row) <= DEMO_LAVA_HEAD_CLEAR)
				and (Abs(ACol - Col) <= DEMO_LAVA_HEAD_CLEAR) then
					Exit;

		Result:= False;
		end;

	// Try once to grow pool b by one cell: pick a random cell already in
	// it and a random orthogonal neighbour. Deliberately NOT a true
	// Game-of-Life rule - a real one is unpredictable enough to either
	// die out or run away across the whole board, and neither is what an
	// attract screen wants. This gives the same organic creeping look
	// with a hard bound.
	function GrowOnce(APool: Integer): Boolean;
		var
		src: TDemoCell;
		have, nr, nc: Integer;

		begin
		Result:= False;

		have:= DemoLava[APool].Count;

		if  have >= maxcells then
			Exit;

		// Source from the advancing FRONT, not the whole pool - see
		// DEMO_LAVA_FRONTIER. Cells are in creation order, so the front
		// is simply the tail of the array.
		if  have > DEMO_LAVA_FRONTIER then
			src:= DemoLava[APool].Cells[have - 1 - Random(DEMO_LAVA_FRONTIER)]
		else
			src:= DemoLava[APool].Cells[Random(have)];
		nr:= src.Row;
		nc:= src.Col;

		case Random(4) of
			0: Dec(nr);
			1: Inc(nr);
			2: Dec(nc);
		else
			Inc(nc);
			end;

		// Stay one clear cell INSIDE the demo circuit - see
		// DEMO_LAVA_CELLS_BASE's comment for why lava must never be
		// able to reach a snake.
		if  (nr <= DEMO_TOP) or (nr >= DEMO_BOTTOM)
		or (nc <= DEMO_LEFT) or (nc >= DEMO_RIGHT) then
			Exit;

		// Only ever claim empty floor. This one test is what stops lava
		// spreading THROUGH walls, over snake bodies and tails, or onto
		// food - anything that is not bare floor simply refuses it, with
		// no per-hazard special cases. Cheaper and more robust than
		// searching our own cell list too.
		if  Board[nr][nc] <> TILE_FLOOR then
			Exit;

		// ...but a cell being empty right now is not enough on its own:
		// lava appearing directly in front of a snake would be an
		// unavoidable death nobody could have read. Keep clear of every
		// live head, the way the original keeps bee spawns clear
		// (checkPlaceBee).
		//
		// NOTE the original's rule is not the 5x5 box it looks like:
		// isOutsideRect ANDs the two axis tests, so it actually blocks
		// the whole 5-wide row band AND column band through the head, a
		// cross spanning the board. Fine for a bee, which spawns once -
		// far too much for lava, which would be locked out of most of
		// the board by four snakes at once. So this is the box the
		// original reads as intending.
		if  LavaBlockedNearHead(nr, nc) then
			Exit;

		with DemoLava[APool] do
			begin
			Cells[Count].Row:= nr;
			Cells[Count].Col:= nc;
			EmitCell(nr, nc, LavaTile(Count, maxcells), ADeltas, ADeltaCount);
			Inc(Count);
			end;

		Result:= True;
		end;

	begin
	// Everything below moves on a STEP, not on every tick - the pool
	// would otherwise reach full extent in well under a second.
	if  DemoLavaStep > 0 then
		begin
		Dec(DemoLavaStep);
		Exit;
		end;

	DemoLavaStep:= DEMO_LAVA_STEP_TICKS - 1;

	// How far the pools spread on THIS board, at its current progress.
	maxcells:= LavaMaxCells(LevelProgress);

	case DemoLavaPhase of
	dlpIdle:
		begin
		// Seed the pools: DEMO_LAVA_SEEDS of them, evenly spaced across
		// the middle of the circuit's interior. Two lands them left and
		// right of centre, which is dengland's layout; the
		// spacing generalises if that count ever changes.
		for b:= 0 to High(DemoLava) do
			begin
			DemoLava[b].Count:= 0;

			r:= (DEMO_TOP + DEMO_BOTTOM) div 2;
			c:= DEMO_LEFT
					+ ((DEMO_RIGHT - DEMO_LEFT) * (2 * b + 1))
						div (2 * DEMO_LAVA_SEEDS);

			if  Board[r][c] = TILE_FLOOR then
				begin
				DemoLava[b].Cells[0].Row:= r;
				DemoLava[b].Cells[0].Col:= c;
				DemoLava[b].Count:= 1;
				EmitCell(r, c, LavaTile(0, maxcells), ADeltas, ADeltaCount);
				end;
			end;

		DemoLavaPhase:= dlpGrow;
		end;

	dlpGrow:
		begin
		full:= True;

		for b:= 0 to High(DemoLava) do
			begin
			grown:= 0;
			tries:= 0;

			// Bounded retries, not "keep going until it fits": a pool
			// hemmed in on all sides would otherwise spin here forever.
			while (grown < DEMO_LAVA_PER_STEP)
			and (tries < DEMO_LAVA_PER_STEP * 8) do
				begin
				if  GrowOnce(b) then
					Inc(grown);

				Inc(tries);
				end;

			if  DemoLava[b].Count < maxcells then
				full:= False;
			end;

		if  full then
			begin
			DemoLavaPhase:= dlpHold;
			DemoLavaHold:= DEMO_LAVA_HOLD_TICKS;
			end;
		end;

	dlpHold:
		begin
		Dec(DemoLavaHold, DEMO_LAVA_STEP_TICKS);

		if  DemoLavaHold <= 0 then
			DemoLavaPhase:= dlpRecede;
		end;

	dlpRecede:
		begin
		n:= 0;

		// Newest-first, so the pool drains back toward its own bright
		// centre rather than hollowing out from the middle.
		for b:= 0 to High(DemoLava) do
			for i:= 1 to DEMO_LAVA_PER_STEP do
				if  DemoLava[b].Count > 0 then
					begin
					Dec(DemoLava[b].Count);

					// Only clear a cell that is still OURS. Lava writes
					// its own tiles, so anything else standing there now
					// means something took the cell over since (a snake
					// moving through it, once lava is allowed near the
					// path at all) - and blanking it would erase that
					// instead, which reads as corruption. Cheap
					// insurance: the pool just gives the cell up.
					with DemoLava[b].Cells[DemoLava[b].Count] do
						if  (Board[Row][Col] >= TILE_LAVA_BASE)
						and (Board[Row][Col] < TILE_LAVA_BASE + LAVA_TIER_COUNT) then
							EmitCell(Row, Col, TILE_FLOOR, ADeltas, ADeltaCount);

					Inc(n);
					end;

		if  n = 0 then
			begin
			DemoLavaPhase:= dlpIdle;
			DemoWave:= dwBees;			// next in the reel
			DemoWaveWait:= DEMO_WAVE_GAP_TICKS;
			end;
		end;
		end;
	end;

// Ticks between steps for anything moving at this board's own pace -
// snakes in real play, and bees, which get their move OPPORTUNITY on
// the same rhythm (see TickDemoBees).
//
// Derived from difficulty rather than being a separate setting: the
// original keeps iGameSpeed independent of iGameDifficulty, but QUADRO
// makes the boards themselves the difficulty tiers, so a harder board
// is a faster one. Anchored so normal progress gives SNAKE_SPEED_NORMAL.
//
// The clamp is NOT optional. A plain (4 - progress) lands expert on 0,
// which is the original's turbo2 - "DO NOT USE turbo settings,
// especially turbo2!" (server.lua:46) - and progress keeps climbing
// past expert as levels are cleared, so it would go negative after.
function SnakeStepTicks(AProgress: Integer): Integer;
	begin
	Result:= SNAKE_SPEED_NORMAL + 2 - AProgress;

	if  Result > SNAKE_SPEED_SLOW then
		Result:= SNAKE_SPEED_SLOW;

	if  Result < SNAKE_SPEED_TOP then
		Result:= SNAKE_SPEED_TOP;
	end;

procedure TSnakeGame.TickDemoBees(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	b, k, best, dist, bestdist: Integer;
	toward, stall, pick: Integer;
	dr, dc, nr, nc: Integer;
	r, c: Integer;

	// Chebyshev distance - the "at least 5 away" rule is a box, so the
	// larger of the two axis distances is the one that matters.
	function HeadDist(ARow, ACol, ASnake: Integer): Integer;
		var
		a, d: Integer;

		begin
		a:= Abs(ARow - DemoSnakes[ASnake].Body[0].Row);
		d:= Abs(ACol - DemoSnakes[ASnake].Body[0].Col);

		if  a > d then
			Result:= a
		else
			Result:= d;
		end;

	begin
	// --- spawn, on entering the wave ---
	if  DemoBeeLeft <= 0 then
		begin
		DemoBeeLeft:= DEMO_BEE_WAVE_TICKS;

		for b:= 0 to High(DemoBees) do
			begin
			DemoBees[b].Active:= False;

			// Clustered around the middle WALL - one off each end, above
			// and below (dengland, 2026-08-25: "closer to the wall so
			// as to not be blocked by the snakes").
			//
			// They used to spawn in the circuit's interior corners,
			// which put them right against the track: the snakes were
			// constantly in the way, and worse, the spawn clearance
			// test below would reject a corner outright whenever a head
			// happened to be near it, so bees went missing rather than
			// appearing somewhere else. Starting in the open middle
			// gives them room to actually be seen chasing.
			//
			// Bees are still PENNED inside the circuit for the same
			// reason lava is: the demo has no collision, so a bee on
			// the track would just be painted over by the next snake
			// through. Real play lets them anywhere, which is where the
			// clearance rule starts earning its keep.
			if  (b and 1) = 0 then
				c:= DEMO_WALL_LEFT - 1
			else
				c:= DEMO_WALL_RIGHT + 1;

			if  (b and 2) = 0 then
				r:= DEMO_WALL_ROW - 1
			else
				r:= DEMO_WALL_ROW + 1;

			if  Board[r][c] <> TILE_FLOOR then
				Continue;

			// Never spawn on top of a player - see
			// DEMO_BEE_SPAWN_CLEAR.
			bestdist:= BOARD_COLS + BOARD_ROWS;
			best:= 0;

			for k:= 0 to High(DemoSnakes) do
				begin
				dist:= HeadDist(r, c, k);

				if  dist < bestdist then
					begin
					bestdist:= dist;
					best:= k;			// nearest head, kept for life
					end;
				end;

			if  bestdist < DEMO_BEE_SPAWN_CLEAR then
				Continue;

			DemoBees[b].Row:= r;
			DemoBees[b].Col:= c;
			DemoBees[b].Target:= best;
			DemoBees[b].MoveTick:= 0;
			DemoBees[b].Active:= True;

			EmitCell(r, c, TILE_BEE, ADeltas, ADeltaCount);
			end;
		end;

	Dec(DemoBeeLeft);

	// --- move ---
	toward:= 2;

	if  LevelProgress > 2 then
		toward:= 2 + (LevelProgress - 2);

	stall:= 3 - LevelProgress;

	if  stall < 1 then
		stall:= 1;

	for b:= 0 to High(DemoBees) do
		begin
		if  not DemoBees[b].Active then
			Continue;

		// The move OPPORTUNITY comes at the board's own step rate, not
		// every tick. That is what makes the weighting above work at
		// every difficulty: a bee's actual speed is (chance of acting x
		// board rate), so it is always a little slower than a snake
		// simply running away, but the margin narrows from about 2x at
		// training to 1.2x at expert.
		if  DemoBees[b].MoveTick > 0 then
			begin
			Dec(DemoBees[b].MoveTick);
			Continue;
			end;

		DemoBees[b].MoveTick:= SnakeStepTicks(LevelProgress) - 1;

		pick:= Random(toward + DEMO_BEE_WEIGHT_RANDOM + stall);
		dr:= 0;
		dc:= 0;

		if  pick < toward then
			begin
			// Toward the target head, on whichever axis it is further
			// away - no pathfinding, dengland's call. A blocked move is
			// simply a lost one (below), which is what makes walls real
			// shelter rather than something bees route around.
			r:= DemoSnakes[DemoBees[b].Target].Body[0].Row;
			c:= DemoSnakes[DemoBees[b].Target].Body[0].Col;

			if  Abs(r - DemoBees[b].Row) > Abs(c - DemoBees[b].Col) then
				begin
				if  r < DemoBees[b].Row then
					dr:= -1
				else if r > DemoBees[b].Row then
					dr:= 1;
				end
			else
				begin
				if  c < DemoBees[b].Col then
					dc:= -1
				else if c > DemoBees[b].Col then
					dc:= 1;
				end;
			end
		else if pick < (toward + DEMO_BEE_WEIGHT_RANDOM) then
			begin
			case Random(4) of
				0: dr:= -1;
				1: dr:= 1;
				2: dc:= -1;
			else
				dc:= 1;
				end;
			end;

		if  (dr = 0) and (dc = 0) then
			Continue;					// stalled, or already level

		nr:= DemoBees[b].Row + dr;
		nc:= DemoBees[b].Col + dc;

		// Penned inside the circuit for the demo - see the spawn
		// comment above.
		if  (nr <= DEMO_TOP) or (nr >= DEMO_BOTTOM)
		or (nc <= DEMO_LEFT) or (nc >= DEMO_RIGHT) then
			Continue;

		// Floor only. The same single test lava uses, and it gives
		// "cannot pass through walls, snakes, tails, lava or food" with
		// no per-hazard cases.
		if  Board[nr][nc] <> TILE_FLOOR then
			Continue;

		EmitCell(DemoBees[b].Row, DemoBees[b].Col, TILE_FLOOR,
				ADeltas, ADeltaCount);

		DemoBees[b].Row:= nr;
		DemoBees[b].Col:= nc;

		EmitCell(nr, nc, TILE_BEE, ADeltas, ADeltaCount);
		end;

	// --- wave over: clear up and hand on ---
	if  DemoBeeLeft <= 0 then
		begin
		for b:= 0 to High(DemoBees) do
			if  DemoBees[b].Active then
				begin
				DemoBees[b].Active:= False;

				// Only blank a cell still holding OUR bee, for the same
				// reason lava checks before draining - once bees are
				// let out onto the track in real play, something else
				// may own that cell by now.
				with DemoBees[b] do
					if  Board[Row][Col] = TILE_BEE then
						EmitCell(Row, Col, TILE_FLOOR, ADeltas, ADeltaCount);
				end;

		DemoWave:= dwFood;				// next in the reel
		DemoWaveWait:= DEMO_WAVE_GAP_TICKS;
		end;
	end;

procedure TSnakeGame.TickDemoFood(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	pass, row, c, idx: Integer;

	begin
	// Lay the whole display out in one go, then just hold it. Both rows
	// together are ~24 cells, which would blow the delta budget as a
	// single burst - so this walks one PASS (one row) per tick, two
	// ticks to appear and two to clear. It also looks better: the rows
	// arrive one after the other rather than snapping into place.
	if  DemoFoodLeft <= 0 then
		DemoFoodLeft:= DEMO_FOOD_WAVE_TICKS + 2;

	Dec(DemoFoodLeft);

	pass:= DEMO_FOOD_WAVE_TICKS + 1 - DemoFoodLeft;

	// Laying out (passes 0 and 1), or clearing (the last two ticks).
	if  (pass < 2) or (DemoFoodLeft < 2) then
		begin
		if  pass < 2 then
			row:= DEMO_WALL_ROW - DEMO_FOOD_WALL_GAP
					+ (pass * DEMO_FOOD_WALL_GAP * 2)	// above, then below
		else
			row:= DEMO_WALL_ROW - DEMO_FOOD_WALL_GAP
					+ ((1 - DemoFoodLeft) * DEMO_FOOD_WALL_GAP * 2);

		// Type cycles along the row AND continues across both rows, so
		// the two rows are offset from each other rather than repeating
		// the same sequence twice.
		idx:= 0;

		if  row > DEMO_WALL_ROW then
			idx:= 1;

		c:= DEMO_LEFT + 1;

		while c <= DEMO_RIGHT - 1 do
			begin
			if  pass < 2 then
				begin
				if  Board[row][c] = TILE_FLOOR then
					EmitCell(row, c,
							TILE_FOOD_BASE + (idx mod FOOD_TYPE_COUNT),
							ADeltas, ADeltaCount);
				end
			else
				// Only clear what is still food - a snake or lava may
				// own the cell by the time the wave ends.
				if  (Board[row][c] >= TILE_FOOD_BASE)
				and (Board[row][c] < TILE_FOOD_BASE + FOOD_TYPE_COUNT) then
					EmitCell(row, c, TILE_FLOOR, ADeltas, ADeltaCount);

			Inc(idx);
			Inc(c, DEMO_FOOD_STRIDE);
			end;
		end;

	if  DemoFoodLeft <= 0 then
		begin
		DemoWave:= dwBoss;				// the boss closes the reel
		DemoWaveWait:= DEMO_WAVE_GAP_TICKS;
		end;
	end;

procedure TSnakeGame.TickDemoBoss(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i: Integer;
	r, c: Byte;
	dir: TSnakeDir;
	flash, repaint: Boolean;

	// Where the cell ADist round the boss loop is.
	procedure BossAt(ADist: Integer; out ARow, ACol: Byte;
			out ADir: TSnakeDir);
		begin
		RectWalk(ADist, DEMO_BOSS_TOP, DEMO_BOSS_LEFT,
				DEMO_BOSS_BOTTOM, DEMO_BOSS_RIGHT, ARow, ACol, ADir);
		end;

	// The shape of the cell ADist round the loop: entered travelling
	// the direction that LEFT ADist-1, left travelling the direction
	// that leaves ADist. Purely positional - no history needed, which
	// is the whole reason the boss needs no body array.
	//
	// This also gives the turn telegraph for free: the head sits on a
	// corner cell showing the corner piece the step before it turns,
	// exactly as a demo snake's head does.
	function BossShape(ADist: Integer): Integer;
		var
		rr, cc: Byte;
		din, dout: TSnakeDir;

		begin
		BossAt(ADist - 1, rr, cc, din);
		BossAt(ADist, rr, cc, dout);

		Result:= SegShape(din, dout);
		end;

	// Paint or clear the whole boss where it currently stands.
	procedure PaintBoss(AShow: Boolean);
		var
		j: Integer;
		rr, cc: Byte;
		dd: TSnakeDir;

		begin
		for j:= 0 to DEMO_BOSS_LEN - 1 do
			begin
			BossAt(DemoBossDist - j, rr, cc, dd);

			if  AShow then
				begin
				if  j = 0 then
					EmitCell(rr, cc, SnakeTile(SNAKE_SLOT_BOSS,
							SNAKE_ROLE_HEAD, BossShape(DemoBossDist - j)),
							ADeltas, ADeltaCount)
				else
					// Body honours the flash; the head never does, same
					// as any other snake (see SnakeBodyTile).
					EmitCell(rr, cc, SnakeBodyTile(SNAKE_SLOT_BOSS,
							BossShape(DemoBossDist - j), DemoBossFlashOn),
							ADeltas, ADeltaCount);
				end
			else
				// Only clear what is still ours - see the lava and bee
				// waves for why.
				if  (Board[rr][cc] >= TILE_SNAKE_BASE)
				and (Board[rr][cc] < TILE_SNAKE_FLASH_BASE) then
					EmitCell(rr, cc, TILE_FLOOR, ADeltas, ADeltaCount);
			end;
		end;

	begin
	// --- arrive ---
	if  DemoBossLeft <= 0 then
		begin
		DemoBossLeft:= DEMO_BOSS_WAVE_TICKS;
		DemoBossDist:= 0;
		DemoBossStep:= 0;
		DemoBossFlashOn:= False;

		PaintBoss(True);
		end;

	Dec(DemoBossLeft);

	// --- leave ---
	if  DemoBossLeft <= 0 then
		begin
		PaintBoss(False);

		DemoWave:= dwLava;			// round the reel again
		DemoWaveWait:= DEMO_WAVE_GAP_TICKS;

		Exit;
		end;

	// --- invulnerability, from halfway on ---
	//
	// It turns invulnerable partway through its own wave rather than
	// arriving that way (dengland, 2026-08-25), so the attract screen
	// shows the boss BECOMING dangerous - a state change reads as an
	// event, where a boss that flashed from the start would just look
	// like a differently-coloured snake.
	//
	// Runs on the TICK, not the step, so it flashes at the same rate a
	// player's does regardless of how slowly the boss is crawling.
	flash:= (DemoBossLeft <= (DEMO_BOSS_WAVE_TICKS div 2))
			and (((DemoBossLeft div DEMO_INVUN_FLASH_TICKS) and 1) = 0);

	repaint:= flash <> DemoBossFlashOn;
	DemoBossFlashOn:= flash;

	// --- crawl ---
	if  DemoBossStep > 0 then
		begin
		Dec(DemoBossStep);

		if  repaint then
			PaintBoss(True);

		Exit;
		end;

	DemoBossStep:= DEMO_BOSS_STEP_TICKS - 1;

	// Only three cells change per step, the same as a demo snake: the
	// tail vacates, the old head demotes to body, and the new head
	// arrives. Tail first, so a boss as long as its own loop still
	// can't collide with the cell it is leaving.
	BossAt(DemoBossDist - DEMO_BOSS_LEN + 1, r, c, dir);
	EmitCell(r, c, TILE_FLOOR, ADeltas, ADeltaCount);

	i:= DemoBossDist;
	BossAt(i, r, c, dir);
	EmitCell(r, c, SnakeBodyTile(SNAKE_SLOT_BOSS, BossShape(i),
			DemoBossFlashOn), ADeltas, ADeltaCount);

	Inc(DemoBossDist);

	BossAt(DemoBossDist, r, c, dir);
	EmitCell(r, c, SnakeTile(SNAKE_SLOT_BOSS, SNAKE_ROLE_HEAD,
			BossShape(DemoBossDist)), ADeltas, ADeltaCount);

	// After the move, so it paints where the segments now are.
	if  repaint then
		PaintBoss(True);
	end;

procedure TSnakeGame.TickDemoWave(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	begin
	// The beat between waves.
	if  DemoWaveWait > 0 then
		begin
		Dec(DemoWaveWait);

		// Cue the shake while the beat is still running, so the ground
		// is already moving before the first lava cell appears.
		if  (DemoWave = dwLava)
		and (DemoWaveWait = DEMO_SHAKE_LEAD_TICKS) then
			DemoShakePending:= DEMO_SHAKE_FRAMES;

		Exit;
		end;

	case DemoWave of
	dwLava:
		TickDemoLava(ADeltas, ADeltaCount);

	dwBees:
		TickDemoBees(ADeltas, ADeltaCount);

	dwFood:
		TickDemoFood(ADeltas, ADeltaCount);

	dwBoss:
		TickDemoBoss(ADeltas, ADeltaCount);
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
	// new head), so 12 with all four moving on the same tick. On a tick
	// where the invulnerability flash also flips phase, the ONE snake
	// that can be flashing repaints its whole body on top of that -
	// another DEMO_SNAKE_LEN - 1 cells. The hazard wave adds up to
	// DEMO_LAVA_SEEDS x DEMO_LAVA_PER_STEP on a step tick. 48 covers
	// the lot with room to spare, and stays well under the ~70 deltas
	// that would overflow one TCP payload (the count is a single byte,
	// but the stack caps a payload at 235 = 1 + 78 x 3).
	// TickDemoSnakes drops anything past the end rather than
	// overrunning, so this is a ceiling, not an assumption.
	SetLength(deltas, 48);
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
			TickDemoWave(deltas, deltaCount);

			// Drain a cued shake BEFORE the empty-broadcast check
			// below: the shake is cued during a wave's quiet beat, so
			// the very tick it lands on is quite likely to be one where
			// nothing moved at all, and the early Exit would swallow it.
			if  DemoShakePending > 0 then
				begin
				for i:= 0 to Watchers.Count - 1 do
					try
					SendShake(Watchers[i], DemoShakePending);

					except
					on E: Exception do
						AddLogMessage(slkError, 'Tick: SendShake failed for watcher - ' +
								E.Message);
					end;

				DemoShakePending:= 0;
				end;

			// Nothing changed this tick (snakes still counting down to
			// their next step, and no hazard cell moved) - don't send
			// an empty broadcast.
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
	i, s: Integer;
	h: Boolean;
	m: TBaseMessage;

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
		if  AMessage.Method = 4 then
			begin
			// Game chat - broadcast to everyone in the zone (spectators
			// included), not just the 4 claimed corners. FPlayers is the
			// zone's full membership, not just Slots.
			//
			// FIXED 2026-08-25. This used to expect chess's RoomPeer
			// payload ([room, sender, message]) and match the room name
			// against Desc, while the client had moved to sending plain
			// text on $0E - so the two ends agreed on neither the method
			// number nor the shape, and chat never worked end-to-end.
			// Both are now $04 (dengland wanted the standard methods low,
			// and it matches mcLobby/$04 room chat).
			//
			// Inbound is [message] and nothing else: ProcessPlayerMessage
			// is only reached for a player already in this game, so there
			// is no room to name, and the sender is stamped HERE from
			// APlayer rather than trusted from the wire - a client could
			// otherwise post as anyone.
			AHandled:= True;

			AMessage.ExtractParams;

			if  AMessage.Params.Count >= 1 then
				begin
				m:= TBaseMessage.Create;
					try
					m.Category:= mcPlay;
					m.Method:= $04;

					// Outbound is [sender, message] - what the client's
					// clientProcPlayGameChatMsg reads (readparm0 is the
					// sender there, not readparm1: unlike RoomPeer there
					// is no leading room-name field to skip).
					m.Params.Add(Copy(APlayer.Name, Low(AnsiString), 8));
					m.Params.Add(AMessage.Params[0]);
					m.DataFromParams;

					with FPlayers.LockList do
						try
						for i:= 0 to Count - 1 do
							PeerMessageFromPlayer(Items[i], m);

						finally
						FPlayers.UnlockList;
						end;

					finally
					// PeerMessageFromPlayer Assigns a fresh copy per
					// recipient, so this template is ours to free.
					m.Free;
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
		else if  AMessage.Method = $05 then
			begin
			// SlotClaim - a spectator presses START on one of the four
			// corners. Payload is [slot], 0..3 or SLOT_CLAIM_ANY.
			//
			// $05, not $04: method 4 is still bound to the dead chess-era
			// RoomPeer chat handler above. That handler is known-broken
			// (the client moved to $0E and the server never followed) but
			// it is live code and matches FIRST, so a claim on $04 would
			// simply never be reached.
			//
			// Unlike BoardRowsReq above this DOES error back on refusal:
			// a claim is a deliberate user action, not internal protocol
			// traffic, so a player who pressed a corner and got nothing
			// needs telling why.
			AHandled:= True;

			if  Length(AMessage.Data) < 1 then
				APlayer.SendServerError(LIT_ERR_PLAYCINV)
			else
				begin
				s:= ClaimSlot(APlayer, AMessage.Data[0]);

				if  s < 0 then
					begin
					// Distinguish the two refusals - see ClaimSlot. The
					// held-a-corner test is repeated here rather than
					// returned as a code, since ClaimSlot's contract is
					// "the slot, or nothing" and a second return value
					// would complicate every caller for one message.
					h:= False;

					Lock.Acquire;
						try
						for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
							if  Slots[i].Player = APlayer then
								h:= True;

						finally
						Lock.Release;
						end;

					if  h then
						APlayer.SendServerError(LIT_ERR_PLAYCHAV)
					else if (AMessage.Data[0] = SLOT_CLAIM_ANY)
					or  (AMessage.Data[0] <= SNAKE_PLAYER_COUNT - 1) then
						APlayer.SendServerError(LIT_ERR_PLAYCTKN)
					else
						APlayer.SendServerError(LIT_ERR_PLAYCINV);

					// A refusal must also report the corner's ACTUAL
					// state, not just an error string. The client marks
					// a claim outstanding when it sends one and clears
					// it when SlotStatus arrives for that corner - so a
					// refusal that carried no SlotStatus would leave
					// that marker set forever and block every later
					// claim. Only for a real corner number; a refused
					// SLOT_CLAIM_ANY names no particular slot, and the
					// client never leaves a marker outstanding for it.
					if  (AMessage.Data[0] <= SNAKE_PLAYER_COUNT - 1) then
						begin
						Lock.Acquire;
							try
							SendSlotStatus(APlayer, AMessage.Data[0]);

							finally
							Lock.Release;
							end;
						end;
					end;
				end;
			end
		else if  AMessage.Method = $08 then
			begin
			// SlotRelease - give up a corner, back to spectating.
			// Payload-less. Silent if they held none: the client can
			// reasonably fire this on leaving the board page without
			// knowing whether it ever claimed anything.
			AHandled:= True;

			ReleaseSlot(APlayer);
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

	// Slot-claim (press-start-on-one-of-4-corners) is done - $05/$08
	// above. TODO: direction input, and the spawn itself (shield +
	// cleared start area), once the tile/movement model is designed -
	// see SnakeClasses.pas' TODO and
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

	// [slot, state, isyou]. The third byte is new (2026-08-25) and is
	// what lets a client tell ITS corner from anyone else's - without it
	// slotStates records that corner 2 is occupied but not by whom, so
	// the client cannot decide whether pressing START on it means claim
	// or release.
	//
	// Free to add: this is already called once per recipient (see the
	// broadcast loops in Remove/SlotStatusToAll), so each player can be
	// told something different, and the payload had 252 spare bytes.
	// Appending also keeps it backward-compatible - the client reads
	// fixed offsets and ignores trailing data.
	SetLength(m.Data, 3);
	m.Data[0]:= ASlot;
	m.Data[1]:= Ord(Slots[ASlot].State);

	if  Slots[ASlot].Player = APlayer then
		m.Data[2]:= 1
	else
		m.Data[2]:= 0;

    APlayer.AddSendMessage(m);
	end;

// BoardRowsData (mcPlay/$0B) - reply to a client's BoardRowsReq
// (mcPlay/$0A, see ProcessPlayerMessage). AStartRow must be even and in
// range 0..BOARD_ROWS-2 - the caller (ProcessPlayerMessage) is
// responsible for validating/clamping, this just trusts it. Payload is
// [AStartRow, 30 bytes of row AStartRow, 30 bytes of row AStartRow+1] -
// 61 bytes total, comfortably under the 254-byte cap even with room to
// grow. Two rows/message was dengland's own call (2026-08-24), over
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
