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
	// for the same reason as the board size - TSnake needs it.
	MAX_SNAKE_LEN = 64;

	// The 4 corners/players. Up here for the same reason -
	// TSnakeGame.DemoSnakes is declared in the type block below.
	SNAKE_PLAYER_COUNT = 4;

	// The boss's render slot, and the resulting total. Their REASONING
	// lives with the tile encoding further down (see TILE_SNAKE_BASE) -
	// they are only hoisted up here because the boss became a real snake
	// (2026-08-26), so PlaySnakes, TLavaHeads and every Z-order helper
	// are now sized by the total rather than by the player count.
	//
	// Deliberately still NOT folded into SNAKE_PLAYER_COUNT: that is the
	// number of CORNERS a human can claim, and it sizes Slots and
	// DemoSnakes. The boss is not a player and must never be handed a
	// slot, a life count or a respawn.
	SNAKE_SLOT_BOSS = SNAKE_PLAYER_COUNT;
	SNAKE_RENDER_SLOTS = SNAKE_PLAYER_COUNT + 1;

	// How many lava pools a wave seeds, and the hard ceiling on cells in
	// one pool. Up here for the same reason again - TLavaPool's cell
	// array and TSnakeGame.DemoLava/PlayLava all need them in scope. The
	// reasoning behind the VALUES sits with the lava constants below.
	//
	// The CAP is only the array bound, and it is SHARED: real play's
	// pools are the same record as the reel's. What a pool actually
	// grows to scales with difficulty - see LavaMaxCells.
	//
	// RAISED 32 -> 48 (2026-08-26) when real play's lava was widened.
	// At 32 the hard and expert boards both asked for more than the
	// bound and got it clipped to the same number, which quietly undid
	// the whole point of PLAY_STAGE_LAVA_TIER on exactly the boards
	// where the second lava level should bite hardest - the two stages
	// came out identical in extent and differed only by a pool. Three
	// pools of 48 is around 29% of the interior molten at once, which is
	// the most the board can carry and still be playable.
	//
	// The reel is unaffected: its own ladder tops out around 20.
	DEMO_LAVA_SEEDS = 2;
	PLAY_LAVA_SEEDS = 3;
	LAVA_CELLS_CAP = 48;

	// Bees in the attract wave, one per corner. Up here too -
	// TSnakeGame.DemoBees needs it. Reasoning with the other bee
	// constants further down.
	DEMO_BEE_COUNT = 4;

	// Most food on the board at once, and up here for the same reason as
	// everything else in this block - TSnakeGame.PlayFood is sized by it.
	// The reasoning behind the VALUE sits with the other PLAY_FOOD_*
	// constants below.
	PLAY_FOOD_MAX = 5;

	// Hard ceiling on live bees, sizing TSnakeGame.PlayBees. NOT the
	// number actually on the board - that scales with difficulty, see
	// PlayBeeMax. This is only the array bound, and it exists because
	// LevelProgress keeps climbing as levels are cleared and would
	// otherwise ask for bees without limit.
	// Raised 10 -> 16 (dengland, 2026-08-26). At 10 the ladder saturated
	// exactly on the last stage - PLAY_BEE_BASE + 8 is 10 - so the swarm
	// was already at maximum before the boss arrived, and BOTH the
	// last-30-seconds ramp and the anger mechanic silently did nothing
	// there. A cap the difficulty curve reaches on its own final step is
	// not a safety limit, it is a flat spot in the worst possible place.
	PLAY_BEE_CAP = 16;

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

		// Lives left on this corner's current run. Set when the corner
		// is claimed, spent on death, and when it hits zero the corner
		// is released back to spectator - see KillPlayerSnake.
		//
		// On the SLOT and not on the snake: a snake is torn down and
		// rebuilt on every respawn, so anything that has to outlive a
		// death cannot live there.
		Lives: Integer;

		// Points scored on this corner's current run. On the SLOT for the
		// same reason Lives is - it has to survive a death - and reset by
		// ClaimSlot, not by release, so a finished run's final score stays
		// on the HUD until somebody else takes the corner.
		//
		// The original tracks a separate `bonus` counter to decide when a
		// bonus life is due; PLAY_BONUS_LIFE's own comment explains why
		// this needs none.
		Score: Integer;
	end;

	// One piece of food sitting on the board, with the timed expiry the
	// original gives it (tLevelTiles TTL / levelExpireTiles). The TILE is
	// on Board like everything else - this table exists only to hold what
	// Board cannot: how long the thing has left, and which of the five
	// slots it occupies against PLAY_FOOD_MAX.
	//
	// Kind is the food TYPE (0..3), the same index the original uses into
	// tSnakePts and its own effect branch. It is recoverable from the tile
	// value, but keeping it makes EatFood read as the original does.
	TPlayFood = record
		Row, Col: Byte;
		Kind: Integer;
		Ticks: Integer;
		Active: Boolean;
	end;

	// One bee in REAL PLAY. Deliberately its own record rather than
	// reusing TDemoBee: the two are live at mutually exclusive times, and
	// a play bee needs a TTL the attract-reel version has no use for
	// (that one lives and dies with its wave).
	//
	// Target is a SNAKE INDEX picked at spawn and then KEPT - dengland's
	// call, and it is what stops the bees clumping. If each re-picked the
	// nearest head every step, bees that drifted near one another would
	// converge on the same snake and merge into a single moving wall
	// instead of staying separate threats.
	TPlayBee = record
		Row, Col: Byte;
		Target: Integer;
		MoveTick: Integer;
		Ticks: Integer;
		Active: Boolean;
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
	TSnake = record
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

		// Real play only. The demo never sets this - its snakes run a
		// fixed circuit with no collision at all (see the comment above
		// this record), so there is nothing there that can die.
		Alive: Boolean;

		// FLOATING - this snake is currently overlapping another one and
		// is passing THROUGH it rather than colliding with it. Set when a
		// spawn lands on top of somebody (SpawnPlayerSnake), cleared the
		// moment its own head reaches a cell no other snake occupies
		// (dengland's rule, 2026-08-25).
		//
		// While floating:
		//   - it renders ON TOP, head included
		//   - snake tiles do not block it, so it can always move clear
		//   - it cannot kill anyone: a snake whose head lands on a
		//     floating snake passes through instead of dying
		//
		// THIS IS WHAT PUT A Z ORDER ON THE BOARD, and the consequence
		// reaches further than rendering. Board holds ONE tile per cell,
		// so while anything is floating the board can no longer answer
		// "what is in this cell" - only "what is on top of it". Every
		// collision and vacate decision therefore asks the SNAKE MODELS
		// (SolidSnakeAt/TopSnakeAt) and treats Board as the render layer
		// it has become.
		Floating: Boolean;

		// --- FOOD EFFECTS (real play only) ---
		//
		// The original's moveFast/grow/growNone/growEx, kept as four
		// separate things for the same reason it does: they decay
		// independently and two of them CANCEL each other rather than
		// stacking (see EatFood).
		//
		// MoveFast is a SIGNED tick counter that decays one per tick back
		// toward zero (snakeFastExp), positive for quicker and negative
		// for slower. It is not a speed - PlayStepTicks reads it and
		// shifts the gear by one or two, which is exactly what the
		// original's moveTick arithmetic does.
		MoveFast: Integer;

		// Grow is the one-shot "the next step lengthens me" flag set by
		// eating anything. GrowEx holds it TRUE for a while, so the snake
		// lengthens on every step for that long; GrowNone suppresses it
		// entirely for a while. Eating the food that sets one of the two
		// timers CANCELS the other rather than setting its own - so the
		// two foods are genuine opposites, and a player who has just
		// eaten one can undo it with the other.
		Grow: Boolean;
		GrowNone: Integer;
		GrowEx: Integer;
	end;

	// Which mechanic the attract reel is currently showing off. See
	// DEMO_WAVE_FIRST/LAST - the reel runs the implemented span of this
	// in order and then wraps.
	TDemoWave = (dwLava, dwBees, dwFood, dwBoss);

	// A lava pool's life: creep outward, sit at full extent, drain back.
	// lpIdle is the beat between cycles - the gap on the attract reel
	// before the next wave, and the breather in real play before the
	// pools re-seed somewhere else.
	//
	// SHARED BY THE ATTRACT REEL AND REAL PLAY since lava was given a
	// play stage (2026-08-26), which is why none of these three types
	// carry the Demo prefix any more. The same reasoning the bees are
	// held to: the attract screen has been teaching players how lava
	// behaves all along, so there had better be one definition of it
	// rather than two that drift.
	TLavaPhase = (lpIdle, lpGrow, lpHold, lpRecede);

	// One spreading lava pool. Cells are kept in CREATION ORDER, which
	// is doing three jobs at once: it fixes each cell's colour tier, it
	// makes recession newest-first (just walk backwards), and it means
	// the whole pool is one flat array with no per-cell bookkeeping.
	TLavaCell = record
		Row, Col: Byte;
	end;

	TLavaPool = record
		Cells: array[0..LAVA_CELLS_CAP - 1] of TLavaCell;
		Count: Integer;
	end;

	// The heads lava must keep clear of, gathered by the caller.
	//
	// Passed in rather than looked up, because the two callers read
	// different arrays - the reel's DemoSnakes, real play's live
	// PlaySnakes - and threading a "which mode am I" flag down into the
	// growth primitive to pick between them would put the one thing that
	// genuinely differs in the one place that should not care.
	TLavaHeads = record
		Count: Integer;
		Row, Col: array[0..SNAKE_RENDER_SLOTS - 1] of Integer;
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

	// One board as it is SET UP, before it exists - see ARR_SNAKE_BOARDS.
	// Deliberately a record from the start rather than parallel arrays,
	// so the eventual ini file has something to parse INTO and adding a
	// third per-board setting is one field rather than a third array to
	// keep in step.
	TSnakeBoardDef = record
		Name: AnsiString;
		Difficulty: TGameDifficulty;

		// THE CEILING THIS BOARD NEVER CLIMBS PAST.
		//
		// Difficulty says where a board STARTS; without this, every
		// board ended up in the same place - LevelProgress rises one
		// per level whatever it started at, and it drives the bee count
		// AND how hard the bees chase. A training board fifteen minutes
		// in had a bigger, more aggressive swarm than an expert board's
		// opening, which defeats the point of having a training board
		// at all (dengland's aim, 2026-08-26: scale "for the more
		// thrill seeking player as well as younger children").
		//
		// Applies to the SPEED ladder too - see SpeedProgress. One
		// ceiling for the board, not one per mechanic: "this board
		// never gets harder than X" is the thing being expressed.
		MaxProgress: Integer;
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
		DemoSnakes: array[0..SNAKE_PLAYER_COUNT - 1] of TSnake;

		// REAL PLAY. One snake per corner, indexed the same way Slots is
		// - PlaySnakes[i] belongs to Slots[i], always, so a corner and
		// its snake never need mapping between them.
		//
		// Separate from DemoSnakes rather than reusing it: the two are
		// live at mutually exclusive times, but keeping them apart means
		// the attract reel's state is still intact when play ends and
		// the board falls back to it, instead of having to be rebuilt.
		//
		// SIZED SNAKE_RENDER_SLOTS, NOT SNAKE_PLAYER_COUNT - the extra
		// entry is the BOSS (SNAKE_SLOT_BOSS), and putting it in this
		// array rather than beside it is the whole implementation
		// strategy for the boss. Every Z-order helper - SolidSnakeAt,
		// TopSnakeAt, SnakeSegAt, VacateCell - walks this array, so the
		// boss gets collision, overlap handling and correct repainting
		// underneath other snakes for free, and cannot be quietly missed
		// by a helper that was written before it existed. A boss living
		// outside the array would have been walked straight past by all
		// four of them.
		//
		// THE PRICE is that every loop over this array now has to mean
		// what it says. Loops that are about PLAYERS - input, respawn,
		// lives, scoring, slot status, the head-on pre-pass - still run
		// to SNAKE_PLAYER_COUNT - 1 and must stay that way; only the
		// board-geometry questions run the full range.
		PlaySnakes: array[0..SNAKE_RENDER_SLOTS - 1] of TSnake;

		// Ticks until a dead corner's snake respawns, 0 when it is
		// either alive or unclaimed.
		PlayRespawn: array[0..SNAKE_PLAYER_COUNT - 1] of Integer;

		// This corner's head needs repainting because the player has
		// TURNED, independently of whether it is about to step. Set by
		// SetPlayerLook on the message thread, drained at the top of
		// TickPlaySnakes - see there.
		PlayHeadDirty: array[0..SNAKE_PLAYER_COUNT - 1] of Boolean;

		// The gear last BROADCAST for each corner (see PlayGearFor).
		// Not the current gear - SendSlotStatus always recomputes that -
		// but the record of what the clients were last told, which is
		// what lets the tick loop notice a change and send only then.
		// A snake's gear only moves when its MoveFast crosses zero or
		// the two-gear threshold, so this is a handful of messages per
		// pickup rather than one per tick.
		PlayGear: array[0..SNAKE_PLAYER_COUNT - 1] of Integer;

		// Bees currently on the board. Fixed array with an Active flag,
		// same shape as PlayFood - but unlike food, the CAP here is not
		// the mechanic: how many bees the board wants scales with
		// difficulty (PlayBeeMax) and PLAY_BEE_CAP is only the ceiling
		// that stops unbounded LevelProgress asking for more.
		PlayBees: array[0..PLAY_BEE_CAP - 1] of TPlayBee;

		// Food currently on the board, at most PLAY_FOOD_MAX of it.
		// A fixed array with an Active flag rather than a list: the cap IS
		// the mechanic (the original's iLevelBonus counter), so making the
		// storage the cap means there is no separate count to keep in step
		// with it.
		PlayFood: array[0..PLAY_FOOD_MAX - 1] of TPlayFood;

		// True while at least one corner is claimed - i.e. the board is
		// playing rather than attracting. Held as state, not recomputed,
		// so Tick can spot the EDGE and do the changeover work (build a
		// real level, push the board out) exactly once.
		Playing: Boolean;

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

		// This board's difficulty ceiling - see TSnakeBoardDef's own
		// field. LevelProgress never passes it, and neither does
		// SpeedProgress.
		MaxProgress: Integer;

		// The running level: ticks left on its clock, which of the four
		// line-generator patterns it was built from, whether its
		// last-30-seconds ramp has fired yet, and how many bees have been
		// eaten on it (see PLAY_BEE_ANGER_PER).
		//
		// LevelSecsSent is the last whole second broadcast to watchers -
		// the clock only goes on the wire when the DISPLAYED value
		// changes, not every tick.
		LevelTicks: Integer;
		LevelVariant: Integer;
		LevelNumber: Integer;
		LevelRamped: Boolean;
		LevelBeesEaten: Integer;
		LevelSecsSent: Integer;

		// THE KEY's schedule for this level: how many chances are left
		// (from PLAY_STAGE_KEYS), how long until the next one, and the
		// size of the window each chance is drawn from.
		//
		// KeyWindow is the level divided by the number of chances, so
		// they spread across the level instead of all landing in the
		// first minute. Held rather than recomputed because the divisor
		// is the count the level STARTED with, not what is left.
		LevelKeysLeft: Integer;
		LevelKeyTimer: Integer;
		LevelKeyWindow: Integer;

		// --- REAL PLAY'S LAVA (stages 4 and 7) ---
		//
		// The same pools, phases and pacing counters the attract reel
		// runs, kept separately for exactly the reason PlaySnakes is
		// kept apart from DemoSnakes: the two are live at mutually
		// exclusive times, and not sharing means the reel's state
		// survives a game intact.
		//
		// dengland chose "grow, hold, recede, repeat" over a board that
		// steadily closes in (2026-08-26): the dangerous ground MOVES
		// rather than accumulating, so a bad seed near a player is
		// survivable and the board keeps breathing all level. lpIdle is
		// therefore the gap between cycles, and each new cycle re-seeds
		// somewhere else - see TickPlayLava.
		PlayLava: array[0..PLAY_LAVA_SEEDS - 1] of TLavaPool;
		PlayLavaPhase: TLavaPhase;
		PlayLavaStep: Integer;
		PlayLavaHold: Integer;

		// Whether THIS burst's warning shake has been cued yet. A latch
		// rather than an equality test on PlayLavaHold - which is how
		// the attract reel does it - because that only fires reliably
		// while the gap divides exactly by the step interval, and both
		// are constants somebody will reasonably want to tune.
		PlayLavaShook: Boolean;

		// --- THE BOSS (stage 8) ---
		//
		// The boss SNAKE itself is PlaySnakes[SNAKE_SLOT_BOSS] - see
		// there. These are the only things about it a player snake has
		// no equivalent of.
		//
		// BossLives is dengland's rule (2026-08-26): the boss starts
		// with the same PLAY_START_LIVES a player does, and a hit spends
		// one. It does NOT respawn on losing one, it just goes
		// invulnerable and keeps coming - which is why this is a plain
		// counter here and not a Slots entry.
		//
		// BossWake is the dormant spell at the start of the level, also
		// his: the boss is laid down with the level rather than arriving
		// later, "so we don't have spawn in issues and floating to
		// account for", but it sits still and unkillable until this runs
		// out. Unkillability is not a separate flag - the wake timer is
		// spent as invulnerability, so the boss visibly flashes while
		// dormant and the tell costs nothing.
		BossLives: Integer;
		BossWake: Integer;

		// Segments the boss is still owed, from things it has destroyed
		// - see PLAY_BOSS_GROW_FOOD. A plain pending COUNT rather than
		// TSnake's own Grow/GrowEx pair, because those are tick timers
		// serving foods that cancel one another, and none of that
		// applies to something which simply gets bigger as it eats.
		BossGrow: Integer;

		// The attract reel: which mechanic is on stage, where its
		// animation has got to, and the tick counters driving both.
		DemoWave: TDemoWave;
		DemoLava: array[0..DEMO_LAVA_SEEDS - 1] of TLavaPool;
		DemoLavaPhase: TLavaPhase;
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

		// REAL PLAY. StartPlay/StopPlay handle the changeover between
		// attract and play (see Tick's edge detect); SpawnPlayerSnake
		// puts one corner's snake on the board; TickPlaySnakes advances
		// them; KillPlayerSnake wipes one off it. PushBoardToWatchers
		// resends the whole board, for when a level changes wholesale
		// and deltas would be the wrong tool.
		procedure StartPlay;
		procedure StopPlay;
		procedure SpawnPlayerSnake(ASlot: Integer;
				var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
		procedure KillPlayerSnake(ASlot: Integer;
				var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
		procedure TickPlaySnakes(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure PushBoardToWatchers;

		// FOOD. TickPlayFood ages what is out there and rolls for a new
		// piece; FoodAt finds the table entry for a board cell (-1 if
		// none); ClearFoodAt forgets one that something else has removed
		// from the board; EatFood applies one type's effects to one snake.
		// Which food kind to put down - a flat roll everywhere except
		// the boss stage, which has its own table. See RandomFoodKind.
		function  RandomFoodKind: Integer;

		procedure TickPlayFood(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		function  FoodAt(ARow, ACol: Byte): Integer;
		procedure ClearFoodAt(ARow, ACol: Byte);
		procedure EatFood(ASlot, AFood: Integer);

		// BEES. TickPlayBees ages, moves and spawns them; BeeAt finds the
		// table entry for a board cell (-1 if none); ClearBeeAt forgets
		// one something else has taken off the board; PlayBeeMax is how
		// many this board wants right now.
		procedure TickPlayBees(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure TrySpawnBee(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);

		// THE KEY. ResetLevelKeys arms this level's schedule;
		// TickLevelKey runs it down and spends a chance when one is due.
		procedure ResetLevelKeys;
		procedure TickLevelKey(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		function  BeeAt(ARow, ACol: Byte): Integer;
		procedure ClearBeeAt(ARow, ACol: Byte);
		function  PlayBeeMax: Integer;

		// LAVA - THE SHARED PRIMITIVES, used by both the attract reel and
		// real play. These three hold everything subtle about lava: the
		// frontier-weighted growth, the floor-only legality test, the
		// head clearance, the age-tiered colouring, and the "only clear
		// a cell that is still OURS" care on the way back out.
		//
		// The two tick procedures keep their own phase machines, because
		// what genuinely differs is only the pacing and where a cycle
		// SEEDS - the reel drops its pools at fixed points inside its
		// circuit, real play scatters them anywhere legal.
		procedure LavaSeedPool(var APool: TLavaPool; ARow, ACol,
				AMaxCells: Integer; var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		function  LavaGrowOnce(var APool: TLavaPool; ATop, ALeft, ABottom,
				ARight, AMaxCells, AClear: Integer; const AHeads: TLavaHeads;
				var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer): Boolean;
		function  LavaRecedeOnce(var APool: TLavaPool;
				var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer): Boolean;

		// LAVA, REAL PLAY (stages 4 and 7). TickPlayLava runs the phase
		// machine; ClearLavaAt forgets a cell something else has taken
		// off the board, the same courtesy ClearFoodAt and ClearBeeAt
		// do.
		procedure TickPlayLava(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure ClearLavaAt(ARow, ACol: Byte);
		procedure ResetPlayLava;

		// How bad this stage's lava is - see PLAY_STAGE_LAVA_TIER. Both
		// levers the tier pulls, so the two lava stages in a cycle are
		// genuinely different levels rather than the same one twice.
		function  LavaTier: Integer;
		function  LavaPools: Integer;
		function  PlayLavaMaxCells: Integer;

		// Whose heads the lava must keep clear of, gathered for
		// LavaGrowOnce - the reel's snakes or the live ones.
		procedure DemoLavaHeads(out AHeads: TLavaHeads);
		procedure PlayLavaHeads(out AHeads: TLavaHeads);

		// THE BOSS (stage 8). SpawnBoss lays it down with the level;
		// TickBoss is its whole simulation; HitBoss is a shielded
		// player's head arriving on it; KillBoss is the last life going.
		procedure SpawnBoss(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure TickBoss(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure HitBoss(ASlot: Integer; var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure KillBoss(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);
		procedure ClearBoss(var ADeltas: array of TTileDelta;
				var ADeltaCount: Integer);

		// Is the boss on the board and simulating right now? Not the
		// same question as StageHasBoss, which only says what the LEVEL
		// is - the boss can be dead with the level still running out its
		// last tick.
		function  BossOnBoard: Boolean;

		// Which stage of the cycle this level is, and what it runs.
		// See PLAY_STAGE_*.
		function  SpeedProgress: Integer;
		function  LevelStage: Integer;
		function  StageHasBees: Boolean;
		function  StageHasLava: Boolean;
		function  StageHasBoss: Boolean;

		// Z ORDER (see TSnake.Floating). Board cannot answer these once
		// anything is floating, so they go to the models instead.
		// SolidSnakeAt is the collision question - who is really in the
		// way; TopSnakeAt is the render question - whose tile belongs in
		// this cell. VacateCell is what a leaving segment calls instead
		// of blindly emitting floor.
		function  SolidSnakeAt(ARow, ACol: Byte; AExclude: Integer): Integer;
		function  SnakeSegAt(ASnake: Integer; ARow, ACol: Byte): Integer;
		function  TopSnakeAt(ARow, ACol: Byte; AExclude: Integer): Integer;
		procedure VacateCell(ARow, ACol: Byte; AExclude: Integer;
				var ADeltas: array of TTileDelta; var ADeltaCount: Integer);

		// Ticks between steps for one PLAYING snake - the board's base
		// gear (SnakeStepTicks) shifted by that snake's own MoveFast.
		function  PlayStepTicks(ASlot: Integer): Integer;

		// The same thing as the HUD sees it: clamped onto the six named
		// gears, and 0 for a corner nobody is playing.
		function  PlayGearFor(ASlot: Integer): Integer;

		// This board's base step cadence right now - SnakeStepTicks for
		// the current progress, one gear quicker once the level has
		// ramped. Everything in real play paces off this rather than
		// calling SnakeStepTicks directly, so the ramp reaches snakes and
		// bees alike.
		function  BoardStepTicks: Integer;

		// Clock ran out: rebuild on the next pattern, harder, and put
		// everyone back on their corner.
		procedure NextLevel;

		// Seconds left on the level clock, for the wire and the HUD.
		function  LevelSecsLeft: Integer;

		// Add points to a corner, awarding a bonus life if the total
		// crosses a multiple of PLAY_BONUS_LIFE. Caller holds Lock.
		procedure AddScore(ASlot, APoints: Integer);

		// Apply a direction request from a player. Rejects the reverse
		// of the way the snake is actually travelling - see the
		// implementation.
		procedure SetPlayerLook(APlayer: TPlayer; ADir: TSnakeDir);

		// SLOT CLAIM/RELEASE - a spectator taking or giving up one of the
		// four corners. Both return the slot affected, or -1 if nothing
		// happened; both broadcast SlotStatus themselves. Callers must
		// NOT hold Lock - these acquire it.
		function  ClaimSlot(APlayer: TPlayer; ASlot: Integer): Integer;
		function  ReleaseSlot(APlayer: TPlayer): Integer;

		// Broadcast board-wide state to everyone in the zone.
		procedure GameStatusToAll;

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
	// DEBUG ONLY - the level a board starts on, set from -l on the
	// command line and read by StartPlay. 0 or 1 means normal.
	//
	// A plain global rather than a per-board property because it is a
	// development shortcut, not a game setting: every board takes it, it
	// is set once before anything runs, and giving it a proper home would
	// imply it belongs in the design.
	DebugStartLevel: Integer = 0;

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
	// A RECORD PER BOARD, not just a name (2026-08-26). dengland's own
	// long-standing call - "the differences between the game boards can
	// be the initial difficulty/speed" - and it matters more now than it
	// did: base speed steps only once per cycle
	// (PLAY_SPEED_LEVELS_PER_STEP), so DIFFICULTY has become the main
	// speed dial rather than an opening nudge. It seeds both
	// LevelProgress and SpeedProgress, so it sets the starting gear, the
	// starting bee count and how hard the bees chase.
	//
	// This is the shape the eventual INI wants ("a small ini file to
	// describe game names and difficulty settings", dengland) - a list of
	// board definitions, read from a file instead of compiled in, with
	// the client listing them for selection. Nothing else needs to
	// change when that lands: the seeding loop below already reads
	// whatever this holds.
	//
	// board1/board2 keep their names and board1 keeps easy, since every
	// tool and habit points at them. The ordering past that is by
	// difficulty rather than by number - rename freely, it is one table.
	// MaxProgress in terms of what a player actually meets - bees are
	// 2 + progress, and the chase weight is 2:1:1 up to progress 2 then
	// one point of "toward" per step after it:
	//
	//   2   4 bees, 2:1:1    the normal board's opening
	//   4   6 bees, 4:1:1    the expert board's opening
	//   6   8 bees, 6:1:1
	//   9  11 bees, 9:1:1
	//  14  16 bees (the array cap), 14:1:1
	//
	// So a training board tops out at what a normal board STARTS at,
	// and easy tops out at what expert starts at. Each difficulty keeps
	// a band of its own instead of every board ending up in the same
	// place an hour in.
	ARR_SNAKE_BOARDS: array[0..4] of TSnakeBoardDef = (
			(Name: 'board1'; Difficulty: gdEasy;     MaxProgress:  4),
			(Name: 'board2'; Difficulty: gdNormal;   MaxProgress:  6),
			(Name: 'board3'; Difficulty: gdHard;     MaxProgress:  9),
			(Name: 'board4'; Difficulty: gdExpert;   MaxProgress: 14),
			(Name: 'board5'; Difficulty: gdTraining; MaxProgress:  2));

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
	// already committed to but not yet made (see TSnake.Look), so a
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
	// SNAKE_SLOT_BOSS and SNAKE_RENDER_SLOTS are DECLARED AT THE TOP OF
	// THE FILE, not here, because the type block needs them in scope -
	// see there. This is still where their reasoning belongs, since the
	// tile encoding is what they are for.

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

	// --- THE TILE DELTA BUDGET ---
	//
	// PLAY_DELTAS_PER_MSG is arithmetic, not taste: the stack caps a
	// payload at 235 bytes, a delta is 3 bytes, and there is one count
	// byte, so 1 + 78 x 3 = 235 is exactly one full message. It is the
	// CHUNK SIZE, not a limit - see SendTileDeltas, which splits.
	//
	// PLAY_DELTAS_MAX is how many cells one tick may change before the
	// gather buffer starts dropping them. Sized for the real worst case
	// (four full-length flashing players, a flashing boss, a full swarm
	// on the move, food turning over) rather than for one message, which
	// is what it was pinned to until 2026-08-26.
	PLAY_DELTAS_PER_MSG = 78;
	PLAY_DELTAS_MAX = 320;

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
	//   4  KEY $00, yellow    clock cut to 30s         2000 pts
	//
	// The key's character is a SCREEN CODE like all the others - '@' is
	// $40 in PETSCII but $00 on screen, and $40 was what went in first
	// and drew the wrong glyph on hardware (2026-08-26).
	//
	// THE KEY IS NOT PART OF THE RANDOM FOOD ROLL. It is the one pickup
	// with a schedule of its own (see PLAY_STAGE_KEYS and TrySpawnKey) -
	// a fixed number of chances per level, each lasting only a few
	// seconds - so the ordinary spawner deliberately rolls
	// FOOD_TYPE_COUNT - 1 and can never produce it. It rides the food
	// TABLE because everything else about it is food (it is eaten,
	// expires, sweeps, and occupies a cell the same way), and reusing
	// that machinery is far cheaper than a parallel one.
	TILE_FOOD_BASE = TILE_BEE + 1;
	FOOD_TYPE_COUNT = 5;

	// The scheduled kind, and the count the RANDOM spawner may roll.
	// Named rather than written as 4 and 4 at their use sites, which
	// would be two different meanings wearing the same digit.
	FOOD_KIND_KEY = 4;
	FOOD_RANDOM_KINDS = FOOD_KIND_KEY;

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
	// The gear names, in ticks-per-step (SMALLER is faster).
	//
	// RESCALED 2026-08-25 (dengland: "we need slow (5), normal (4),
	// fast (3), fastest (2) and top (1)"). The original's tGAMESPEED
	// was {slow=4, normal=3, fast=2, turbo1=1, turbo2=0}; every gear
	// has moved one step slower, and a sixth has been added below.
	//
	// Why slower than the original: QUADRO puts FOUR snakes on one
	// board rather than two, so the same cell is contested far more
	// often and a player needs longer to read the board before
	// committing. The original's normal was simply too quick here -
	// play started at 4 steps/sec and felt hurried.
	//
	// VERY SLOW (6) exists because it makes the ladder line up exactly
	// one gear per difficulty, with no two tiers sharing a gear. The
	// old scale ran out at the bottom and clamped training and easy
	// both onto SLOW; now every tier is distinct - see SnakeStepTicks.
	//
	// turbo2 (0) is still deliberately absent - server.lua:46 says "DO
	// NOT USE turbo settings, especially turbo2!", so TOP is the floor.
	SNAKE_SPEED_VSLOW   = 6;		//  2.0 steps/sec
	SNAKE_SPEED_SLOW    = 5;		//  2.4
	SNAKE_SPEED_NORMAL  = 4;		//  3.0
	SNAKE_SPEED_FAST    = 3;		//  4.0
	SNAKE_SPEED_FASTEST = 2;		//  6.0
	SNAKE_SPEED_TOP     = 1;		// 12.0
	//
	// The original also modulates this per snake via moveFast (food
	// speed-ups and slow-downs, +30..-12, decaying 1/tick back toward
	// 0) - deliberately NOT implemented here, since demo snakes never
	// eat. When food lands, that becomes a per-snake offset applied to
	// this base, exactly as objectsTick does it.
	//
	// Attract mode runs quicker than normal play so the demo looks
	// lively, but never TOP. Both halves are dengland's own rules
	// (2026-08-24), guarded below rather than left to a comment.
	//
	// FASTEST, not FAST, since the 2026-08-25 rescale. The demo has
	// always run at 2 ticks / 6 steps per second, which is the speed
	// that was judged to look right on hardware - and 2 ticks is what
	// FASTEST names now that every gear has shifted one slower. Left
	// as FAST this would have quietly dropped the attract screen to 4
	// steps/sec, changing something already tuned by eye.
	//
	// The turn telegraph lasts exactly one step, so its duration IS the
	// step duration: 333ms at NORMAL now, 166ms at FASTEST, 83ms at
	// TOP. Top speed measured 12.1 cells/sec with four snakes and the
	// client tracking it perfectly, so the limit there is human rather
	// than technical: 83ms is below visual reaction time, making the
	// top gear something played from anticipation. dengland's verdict:
	// "that's deadly with 4p".
	SNAKE_MOVE_TICKS = SNAKE_SPEED_FASTEST;

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
	// DEMO_LAVA_SEEDS (2) and LAVA_CELLS_CAP have to be
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
	// past expert until LAVA_CELLS_CAP stops them.
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

	// Slower than the demo snakes, so it reads as heavy - one gear
	// down from them, which is 3 ticks.
	//
	// FAST, not NORMAL, since the 2026-08-25 rescale: 3 ticks is what
	// the boss has always run at and what was judged right on hardware,
	// and FAST is the name 3 carries now. Left as NORMAL it would have
	// silently dropped to 4 and changed a wave already tuned by eye.
	DEMO_BOSS_STEP_TICKS = SNAKE_SPEED_FAST;

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

	// --- THE STAGE CYCLE -----------------------------------------------
	//
	// Eight levels, then it repeats. dengland's own shape (2026-08-26):
	// "3 bees, 1 lava, 2 bees, 1 lava, 1 boss".
	//
	// EIGHT is not arbitrary - it is where the numbers already stop
	// moving. SnakeStepTicks is 6 - progress clamped to TOP, so speed
	// saturates at level 5; PlayBeeMax is 2 + progress, so the swarm used
	// to reach its old cap of 10 at level 8. It is also LEVEL_VARIANTS x
	// 2, so each of the four wall layouts is seen exactly twice per
	// cycle. A longer cycle would add levels that differ from each other
	// in nothing but which walls are drawn.
	//
	// LAVA AND BEES ARE NEVER BOTH ON ("we don't have bees and lava" -
	// dengland). The boss level DOES keep its bees, which is what the
	// raised PLAY_BEE_CAP is for.
	PLAY_LEVEL_STAGES = 8;

	// Which hazards each stage runs. Indexed by (LevelNumber - 1) mod
	// PLAY_LEVEL_STAGES, so it is a cycle rather than an ending - the
	// board runs continuously with players coming and going, so there is
	// nowhere for a "game over" to put anybody.
	//
	// Difficulty does NOT restart with the cycle: LevelProgress goes on
	// climbing and both the things it feeds clamp, so a second lap is the
	// same layouts at permanent top speed. That is the intended shape of
	// an arcade board, but it IS a decision - see NextLevel.
	PLAY_STAGE_BEES: array[0..PLAY_LEVEL_STAGES - 1] of Boolean =
			(True, True, True, False, True, True, False, True);
	PLAY_STAGE_LAVA: array[0..PLAY_LEVEL_STAGES - 1] of Boolean =
			(False, False, False, True, False, False, True, False);
	PLAY_STAGE_BOSS: array[0..PLAY_LEVEL_STAGES - 1] of Boolean =
			(False, False, False, False, False, False, False, True);

	// --- THE KEY -------------------------------------------------------
	//
	// How many chances at a key each stage gets. dengland (2026-08-26):
	// "2 spawn attempts instead of 1 in the first group of bee levels
	// (before lava) and 1 in the second".
	//
	// PER LEVEL, not per group - the key cuts THIS level's clock, so it
	// has to be available in the level it affects, and a group-wide
	// budget would leave some levels with no key at all.
	//
	// LAVA AND BOSS STAGES GET NONE. Lava never had a key mechanic; the
	// boss stage lost the one I had given it (dengland, 2026-08-26: "we
	// don't have keys on the boss level either"), and once the boss's
	// clock was frozen the key could not have worked there anyway - all
	// it does is cut LevelTicks, and on a boss level LevelTicks is not
	// what ends the level. It would have been a 2000-point pickup that
	// silently did nothing.
	PLAY_STAGE_KEYS: array[0..PLAY_LEVEL_STAGES - 1] of Integer =
			(2, 2, 2, 0, 1, 1, 0, 0);

	// HOW BAD EACH LAVA STAGE IS: 0 for a level with no lava, then 1 for
	// the cycle's first lava level and 2 for its second (dengland,
	// 2026-08-26: "can we make the first level of lava less terrifying
	// than the second?").
	//
	// It DID already scale with difficulty and progress, both of which
	// feed PlayLavaMaxCells - but LevelProgress rises by only three
	// between stages 4 and 7, and on a board sitting at its MaxProgress
	// ceiling it does not rise at all, so within one cycle the two lava
	// levels came out near enough identical. This is the explicit
	// difference, on top of whatever the progress scaling is doing.
	//
	// The tier pulls TWO levers - LavaPools and PlayLavaMaxCells - so
	// stage 7 gets both more pools and bigger ones.
	PLAY_STAGE_LAVA_TIER: array[0..PLAY_LEVEL_STAGES - 1] of Integer =
			(0, 0, 0, 1, 0, 0, 2, 0);

	// --- HOW OFTEN THE BASE SPEED STEPS UP -----------------------------
	//
	// Levels per gear. dengland, 2026-08-26, after playing stage 8:
	// "we need to not scale the speed up so much... maybe instead of
	// increasing the base speed every level just increase it every set
	// of 8?"
	//
	// It used to climb EVERY level, which put level 5 onward at TOP -
	// twelve steps a second - and made the whole back half of a cycle
	// one flat wall of maximum speed.
	//
	// SPEED IS NOW THE ONLY THING ON A SLOWER CLOCK. Bees, bee
	// aggression and the generated wall layouts all still scale per
	// level off LevelProgress, so levels inside a cycle still differ
	// from each other - they get busier rather than faster. And the
	// last-30-seconds ramp still takes a gear off whatever the base is,
	// so every level keeps its late kick.
	//
	// ONE CONSTANT TO TUNE. At 8 a gear lasts a full cycle (~16 min);
	// at 4 it is half a cycle. See SpeedProgress for the resulting
	// ladder.
	PLAY_SPEED_LEVELS_PER_STEP = PLAY_LEVEL_STAGES;

	// A key is SHORT-LIVED - that is the whole tension in it. Long enough
	// to cross a corner of the board for, not long enough to finish what
	// you were doing first.
	PLAY_KEY_TTL_MIN_MS = 4000;
	PLAY_KEY_TTL_MAX_MS = 6000;
	PLAY_KEY_TTL_MIN = PLAY_KEY_TTL_MIN_MS div TICK_MS;
	PLAY_KEY_TTL_MAX = PLAY_KEY_TTL_MAX_MS div TICK_MS;

	// What taking one does: the level clock drops to this.
	//
	// Deliberately the same 30 seconds as PLAY_LEVEL_RAMP_MS, so a key
	// does not just shorten the level - it drops you straight into the
	// last-30-seconds ramp, one gear quicker with an extra bee. The
	// reward and the punishment are the same act, which is what stops it
	// being a free skip.
	PLAY_KEY_CLOCK_MS = 30000;
	PLAY_KEY_CLOCK_TICKS = PLAY_KEY_CLOCK_MS div TICK_MS;

	// How many cells to try before giving a key attempt up. Enough that
	// a merely busy board never costs a level its key, few enough that a
	// genuinely full one still ends rather than looping.
	PLAY_KEY_PLACE_TRIES = 24;

	PLAY_FOOD_PTS_KEY = 2000;

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


	// --- REAL PLAY -----------------------------------------------------
	//
	// Where a claimed corner's snake starts: EXACTLY where the demo puts
	// that corner's snake. There is no separate spawn geometry - see
	// SpawnPlayerSnake, which walks the demo's own circuit.
	//
	// So the spawn inherits the demo circuit's properties rather than
	// restating them: DEMO_INSET keeps all four snakes in the lane that
	// LEVEL_INSET guarantees free of generated walls at every
	// difficulty, and they circulate the same way round it, so a
	// head-on between neighbours needs somebody to turn in first.
	//
	// Starting length is the demo's, for the same reason the position
	// is: one number, not two that can drift. Changing DEMO_SNAKE_LEN
	// now moves both, and its existing compile-time guard against
	// DEMO_SPACING keeps covering both as well.

	// Spawn shield. Long enough to get clear of the corner at the
	// slowest step rate; the flash is the same one the food effect uses,
	// so this costs no new tiles (see SnakeBodyTile).
	PLAY_SPAWN_INVUN_MS = 3000;
	PLAY_SPAWN_INVUN_TICKS = PLAY_SPAWN_INVUN_MS div TICK_MS;

	// How much room around a spawn is swept clear of hazards, as a
	// half-width box. A joiner must not arrive inside a lava pool that
	// spread over their corner while they were spectating.
	PLAY_SPAWN_CLEAR = 3;

	// Ticks a dead snake stays gone before it respawns. Long enough to
	// register as a death rather than a stutter.
	PLAY_RESPAWN_MS = 2000;
	PLAY_RESPAWN_TICKS = PLAY_RESPAWN_MS div TICK_MS;

	// Lives on a corner's run. The original gives 3 in single play and
	// 2 in battle (gameUpdateMode); QUADRO has no such modes - every
	// corner is its own independent run on a shared board, whether one
	// person is playing or four - so it takes the solo figure.
	//
	// Running out does NOT end anything for anyone else. The corner is
	// released back to spectator and the board carries on with whoever
	// is left, down to zero corners, which is attract mode. That is the
	// "0-4 corners on one continuously-running board" design doing its
	// job: there is no game-wide game-over to declare.
	PLAY_START_LIVES = 3;

	// --- FOOD ---------------------------------------------------------
	//
	// All of this is the original's (levelTick, snakeCheckEat, snakeMove,
	// snakeFastExp/snakeGrowExp), with two systematic translations:
	//
	// 1. EVERY DURATION IS DOUBLED, expressed in MS here rather than as
	//    the original's raw counts. The original's effect counters tick
	//    down once per game-loop pass at roughly 6/sec; QUADRO ticks at
	//    12/sec (TICK_MS), so a straight copy of "18" would have run for
	//    half as long as it does in the original. Written as MS so they
	//    stay honest the next time TICK_MS moves - which it already has
	//    once.
	//
	// 2. THE BATTLE-MODE VALUES ARE THE ONES USED. The original branches
	//    on iGameMode for three of these (points, growNone, growEx), and
	//    QUADRO is the battle case by construction: four corners, one
	//    board, everyone contesting the same food. There is no
	//    single-player mode here to take the other branch.

	// PLAY_FOOD_MAX (the original's `iLevelBonus < 5`) is declared with
	// the board size at the top of the unit, because it sizes an array
	// field. Not scaled up for four players deliberately: contesting a
	// scarce pickup is the point, and doubling it would make the board a
	// buffet.

	// Chance of a spawn ATTEMPT succeeding, as 1-in-N per tick, when
	// there is a free slot. The original rolls 1-in-8 per pass
	// ((iLevelMax + 1) * 2 with iLevelMax = 3); at twice the tick rate
	// that is 1-in-16 for the same food-per-second.
	//
	// An attempt also fails if the cell it picks is not bare floor, so
	// the real rate is lower than this and falls as the board fills -
	// which is the original's behaviour too, and a good one: a crowded
	// board stops handing out more.
	PLAY_FOOD_SPAWN_ODDS = 16;

	// How long a piece of food sits before it rots away. The original
	// gives each one a TTL of random(16,28) EXPIRY CYCLES, and a cycle is
	// iLevelMax + 1 = 4 passes (levelExpireTiles only runs when iLevelTick
	// runs out), so 64-112 of its passes - about 11-19 seconds.
	//
	// Held in ms and converted, so it is the SECONDS that are the
	// original's, not a tick count that would silently halve.
	PLAY_FOOD_TTL_MIN_MS = 11000;
	PLAY_FOOD_TTL_MAX_MS = 19000;
	PLAY_FOOD_TTL_MIN = PLAY_FOOD_TTL_MIN_MS div TICK_MS;
	PLAY_FOOD_TTL_MAX = PLAY_FOOD_TTL_MAX_MS div TICK_MS;

	// Points per food type, in the same order as TILE_FOOD_BASE and the
	// original's tSnakePts, already doubled for battle mode.
	//
	// Note what the ordering says: the food that GROWS you is the
	// cheapest of the four (200 doubled to 400) and the one that stops
	// you growing is the dearest (600 doubled to 1200). Length is a
	// liability in this game, not a reward, so the scoring pays you for
	// staying short.
	// THE BOSS STAGE'S FOOD WEIGHTING, indexed by food kind - clubs
	// (no-grow, faster), solid circle (extra-grow, slower), open circle
	// (pure speed), heart (shield). Out of ten. See RandomFoodKind for
	// why the boss stage wants a different table at all; every other
	// stage rolls flat.
	PLAY_FOOD_WEIGHT_BOSS: array[0..FOOD_RANDOM_KINDS - 1] of Integer =
			(2, 1, 3, 4);

	PLAY_FOOD_PTS_NOGROW = 1200;		// type 0, clubs
	PLAY_FOOD_PTS_XGROW  = 400;		// type 1, solid circle
	PLAY_FOOD_PTS_BURST  = 800;		// type 2, open circle
	PLAY_FOOD_PTS_SHIELD = 1000;		// type 3, heart

	// Type 0 suppresses growth for this long (battle-mode growNone = 9,
	// i.e. 1.5s - HALF what the original's single-player mode gets).
	PLAY_FOOD_NOGROW_MS = 1500;
	PLAY_FOOD_NOGROW_TICKS = PLAY_FOOD_NOGROW_MS div TICK_MS;

	// Type 1 grows you on EVERY step for this long (battle-mode
	// growEx = 24, i.e. 4s - TWICE the single-player value). The one that
	// can turn a 5-cell snake into a genuine obstacle in a few seconds,
	// and the reason battle mode makes it the longer of the two.
	PLAY_FOOD_XGROW_MS = 4000;
	PLAY_FOOD_XGROW_TICKS = PLAY_FOOD_XGROW_MS div TICK_MS;

	// Type 3's shield, and the cap on any shield earned by eating
	// (invunTicks + 24, clamped at 30). The cap is on the EARNED shield
	// only - the spawn shield and the head-on shield set their own value
	// outright, as the original's do.
	PLAY_FOOD_INVUN_MS = 4000;
	PLAY_FOOD_INVUN_TICKS = PLAY_FOOD_INVUN_MS div TICK_MS;

	// WHEN A SHIELD STARTS TO RUN OUT, and how the flash changes to say
	// so (dengland, 2026-08-26: "can we make the shield flash half the
	// speed once it is at a certain value, say half the normal
	// increment? This will alert the player its going to end").
	//
	// The threshold is half of what one heart food grants, so "about to
	// end" means the same length of time however the shield was
	// acquired - a spawn, a head-on, a heart, or two hearts stacked up
	// to the cap. Reading it off the food increment rather than off the
	// snake's own remaining time is what makes that true.
	//
	// The flash then runs at HALF SPEED. Slowing rather than quickening
	// is his call and it is the better one for this hardware: the flash
	// already toggles every tick (DEMO_INVUN_FLASH_TICKS is 1), so there
	// is no faster available - the only direction left with any contrast
	// in it is slower.
	PLAY_INVUN_WARN_TICKS = PLAY_FOOD_INVUN_TICKS div 2;
	PLAY_INVUN_WARN_SLOW = 2;
	PLAY_INVUN_CAP_MS = 5000;
	PLAY_INVUN_CAP_TICKS = PLAY_INVUN_CAP_MS div TICK_MS;

	// MoveFast adjustments, one per food type, and the clamps either side
	// (moveFast +30 / -12). All signed tick counts that decay to zero.
	PLAY_FAST_NOGROW_MS =  1500;		// type 0: +9
	PLAY_FAST_XGROW_MS  = -1000;		// type 1: -6
	PLAY_FAST_BURST_MS  =  4000;		// type 2: +24
	PLAY_FAST_SHIELD_MS =  2000;		// type 3: +12

	PLAY_FAST_NOGROW = PLAY_FAST_NOGROW_MS div TICK_MS;
	PLAY_FAST_XGROW  = -((-PLAY_FAST_XGROW_MS) div TICK_MS);
	PLAY_FAST_BURST  = PLAY_FAST_BURST_MS div TICK_MS;
	PLAY_FAST_SHIELD = PLAY_FAST_SHIELD_MS div TICK_MS;

	PLAY_FAST_CAP_MS = 5000;		// moveFast +30
	PLAY_FAST_FLOOR_MS = 2000;		// moveFast -12
	PLAY_FAST_CAP = PLAY_FAST_CAP_MS div TICK_MS;
	PLAY_FAST_FLOOR = PLAY_FAST_FLOOR_MS div TICK_MS;

	// Above this much MoveFast left, the gear shifts by TWO instead of
	// one (the original's `moveFast >= 18`). So a fresh speed burst is
	// genuinely fierce and then settles into merely quick as it decays,
	// rather than switching off all at once.
	PLAY_FAST_HARD_MS = 3000;
	PLAY_FAST_HARD = PLAY_FAST_HARD_MS div TICK_MS;

	// Every this many points, the corner earns a life (the original's
	// iGameBonusLife = 50000). Doubled with the points themselves, so it
	// falls at the same place in the run that it does there.
	//
	// No `bonus` counter is needed to go with it, unlike the original:
	// scores only ever go UP and only ever by one food at a time, so
	// crossing a multiple can be detected from the before-and-after
	// division at the point of scoring. See AddScore.
	PLAY_BONUS_LIFE = 100000;

	// Six digits is what the client's score label is (text_detail_score,
	// snake_game.s), and the server formats to it - see SendSlotStatus
	// for why the score goes on the wire as text.
	PLAY_SCORE_DIGITS = 6;
	PLAY_SCORE_MAX = 999999;

	// --- LEVELS --------------------------------------------------------
	//
	// How long a level runs. dengland's own figure (2026-08-24: "levels
	// run for 2 minutes"). The original's iLevelTimer is 600 at roughly
	// 6 passes/sec, which is about 100 seconds - close enough that this
	// is his number rather than a rescale of theirs.
	PLAY_LEVEL_MS = 120000;
	PLAY_LEVEL_TICKS = PLAY_LEVEL_MS div TICK_MS;

	// With this long left, the level RAMPS: one more bee and one gear
	// quicker. The original does the same thing at iLevelTimer = 150,
	// i.e. its last quarter (`iLevelBeesMax + 2`, `iSnakeMoveMax =
	// iGameSpeed - 1`).
	//
	// So the countdown is not only a clock - it is the difficulty curve
	// WITHIN a level, and the last 30 seconds are meant to be the part
	// you have to survive rather than play. Worth keeping in mind when
	// the display is built: the number going red is telling the truth.
	PLAY_LEVEL_RAMP_MS = 30000;
	PLAY_LEVEL_RAMP_TICKS = PLAY_LEVEL_RAMP_MS div TICK_MS;

	// ONE bee, not the original's two (dengland, 2026-08-25). Same
	// reasoning as the count itself: these ones move, so each is worth
	// more than a static one - and on easy this is 3 -> 4, where the
	// original's was 8 -> 10.
	PLAY_LEVEL_RAMP_BEES = 1;

	// The status line above the board, as the server formats it:
	//
	//     LEVEL  1   TIME 1:59
	//
	// FIXED WIDTH so the client can copy it into a fixed buffer with no
	// length byte and no terminator handling - same deal as the score,
	// and for the same reason: formatting mm:ss on a 6502 means dividing,
	// and the server is the machine here that division is free on.
	PLAY_STATUS_LEN = 20;

	// Below this many seconds the client colours the line red. Sent as a
	// raw count ALONGSIDE the text purely so the client can make that
	// comparison without parsing digits back out of its own display.
	PLAY_STATUS_WARN_SECS = 30;

	// --- BEES ----------------------------------------------------------
	//
	// The design was settled 2026-08-24 and is followed here rather than
	// re-derived; the reasoning is worth reading before changing any of
	// it, because several of these numbers are load-bearing in ways that
	// are not obvious from the value.
	//
	// How many bees the board wants. DELIBERATELY NOT the original's
	// scaling, which is `iLevelBeesMax = 5 + iLevelProgress * 3` and runs
	// to 17 by expert.
	//
	// dengland, 2026-08-25: "that's a lot and because they move now, they
	// occupy more space". The original's bees are STATIC - placed once and
	// left to expire (verified in the Lua: nothing repositions them) - so
	// each one denies exactly one cell. QUADRO's move, so each one denies
	// a moving region and threatens everything near its path. The
	// original's count simply does not transfer, and matching it would
	// have made a far denser board than his game ever has.
	//
	//   training 2   easy 3   normal 4   hard 5   expert 6
	//
	// still climbing past expert as levels clear, up to PLAY_BEE_CAP.
	PLAY_BEE_BASE = 2;
	PLAY_BEE_PER_PROGRESS = 1;

	// ...and the progress term is then DIVIDED by this, which is where
	// the swarm was thinned out once bees could actually strike rather
	// than merely be run into (2026-08-26). Kept as a divisor on the
	// slope rather than folded into PLAY_BEE_PER_PROGRESS because that
	// is an integer and 1/2 is not - see PlayBeeMax for the resulting
	// ladder.
	PLAY_BEE_PROGRESS_DIV = 2;

	// 1-in-N per tick to place one, when below the current maximum. Same
	// rate as food and for the same reason: the original rolls 1-in-8 per
	// pass at roughly half our tick rate.
	//
	// An attempt that picks an unsuitable cell is simply wasted rather
	// than retried, exactly as the original does - which is what makes a
	// crowded board quietly stop producing more.
	PLAY_BEE_SPAWN_ODDS = 16;

	// How long a bee sits before it expires. The original gives each one
	// random(8,16) EXPIRY CYCLES of 4 passes - 32-64 of its passes, call
	// it 5-11 seconds. Held in ms so it is the SECONDS that are the
	// original's, not a tick count that would silently halve.
	//
	// Deliberately shorter-lived than food: a hazard that accumulated
	// would eventually fill the board, and the cap alone would make the
	// oldest bees permanent furniture.
	PLAY_BEE_TTL_MIN_MS = 5000;
	PLAY_BEE_TTL_MAX_MS = 11000;
	PLAY_BEE_TTL_MIN = PLAY_BEE_TTL_MIN_MS div TICK_MS;
	PLAY_BEE_TTL_MAX = PLAY_BEE_TTL_MAX_MS div TICK_MS;

	// Nothing spawns within this CHEBYSHEV distance of any live head
	// (dengland: "spawn at least 5 cells from any head"). Supersedes the
	// original's checkPlaceBee, which blocks the whole 5-wide row band
	// AND column band through the head - a cross spanning the board,
	// which reads like a rectangle test that wanted OR.
	//
	// Measured against EVERY live head, not just the one being targeted:
	// a bee appearing on top of a bystander is exactly as unfair as one
	// appearing on top of its target.
	PLAY_BEE_SPAWN_CLEAR = 5;

	// Weight of the "move at random" option. The other two - toward the
	// target, and stall - scale with difficulty; see TickPlayBees, which
	// carries the table.
	PLAY_BEE_WEIGHT_RANDOM = 1;

	// EVERY N BEES EATEN, the board allows one more (dengland, 2026-08-25:
	// "what if every 4 eaten raises the level's limit by 1? Get angry the
	// bees?").
	//
	// Nothing like this is in the original - it is his own idea, and a
	// good one: bee-hunting is the single most lucrative thing on the
	// board (PLAY_BEE_PTS), and until now it was pure upside during an
	// invulnerability burst. This gives the reward a price paid in the
	// same currency, so a greedy run makes its own board harder.
	//
	// Counts SHIELDED KILLS ONLY. Dying to a bee should not anger the
	// swarm as well - you have already paid for that one.
	//
	// Reset each level, along with the rest of the level state.
	PLAY_BEE_ANGER_PER = 4;

	// Eating a bee while shielded. The original's tSnakePts[5] = 750,
	// doubled for battle mode like every other score here.
	//
	// This is the one thing on the board worth going OUT of your way for,
	// and it only exists during an invulnerability burst - so the heart
	// food turns into a timed hunting licence rather than just a safety
	// net. Worth keeping when the numbers get retuned.
	PLAY_BEE_PTS = 1500;

	// --- LAVA IN REAL PLAY (stages 4 and 7) ---
	//
	// Lava had existed only on the attract reel until 2026-08-26, where
	// its whole job was to look good inside a fenced circuit that
	// nothing could walk into. In play it is a hazard on the same board
	// as four snakes, so the numbers are NOT the reel's.
	//
	// THREE POOLS is the array bound and what the SECOND lava stage
	// uses; the first uses two. See PLAY_STAGE_LAVA_TIER.
	//
	// THE PACING IS THE WHOLE FEEL OF THE STAGE, and it matters more here
	// than anywhere else because a lava stage has NO BEES (PlayBeeMax
	// returns 0) - whatever the lava is not doing, nothing else is doing
	// either.
	//
	// RETUNED FASTER AND WIDER 2026-08-26, watching it live. dengland
	// could not choose between quicker, further-spreading lava and
	// putting half a swarm of bees on the level, which was really one
	// observation from two sides: a burst every fifty seconds left too
	// much empty board between them.
	//
	// Quicker lava was the better answer, and not only because it is a
	// constant rather than a feature. Bees and lava sharing a level was
	// his own rule to avoid, and keeping it is what makes the eight
	// stages read as changes of SUBJECT rather than as a difficulty
	// slider - three levels about the swarm, then one about the ground.
	//
	// There is a mechanical objection to the bees too: they have NO
	// PATHFINDING, and a blocked move is simply a lost move (see
	// TickPlayBees), so a board with real pools on it would leave the
	// swarm bunched and stalling against their edges. That is not what
	// half a swarm was meant to add.
	PLAY_LAVA_STEP_TICKS = 5;
	PLAY_LAVA_PER_STEP = 2;

	// How far ONE pool spreads, before the shared LAVA_CELLS_CAP array
	// bound. Widened with the pacing above - board1 (easy, progress 4)
	// now runs 2 pools of 30, about 60 cells of the 28x18 interior.
	PLAY_LAVA_CELLS_BASE = 14;
	PLAY_LAVA_CELLS_PER_PROGRESS = 4;

	// EACH POOL IS SMALLER when there are more of them - this many cells
	// off the per-pool extent per tier above the first (dengland,
	// 2026-08-26, watching stage 7: "maybe with the three of them they
	// needn't spread so much").
	//
	// A REDUCTION, where this was a BONUS an hour earlier, and his
	// instinct is the better one. What matters is the total budget, not
	// the size of any one pool - and three big pools mostly buy you one
	// big pool, because they run into each other and the whole point of
	// having three distinct hazards is lost. Three SMALLER pools scatter
	// the danger instead, which is harder to route around without simply
	// being more lava.
	//
	// The tiers still climb, and now climb more steeply the harder the
	// board (total cells at full extent, tier 1 -> tier 2):
	//
	//   training  44 ->  48     easy    60 ->  72
	//   normal    76 ->  96     hard    96 -> 132
	//   expert    96 -> 144
	//
	// It also un-flattens the top of the ladder as a side effect:
	// subtracting BEFORE the LAVA_CELLS_CAP clamp means hard and expert
	// no longer both clip to the same figure at tier 2, which they did
	// while this was a bonus.
	PLAY_LAVA_TIER_CELLS_LESS = 6;

	// ...but never below this, or a training board's second lava stage
	// would be three specks.
	PLAY_LAVA_CELLS_MIN = 12;

	// Time at full extent before draining, and the clear board a lava
	// level opens on - which is also the pause between bursts.
	//
	// The opening gap is not politeness: the corner spawns and the level
	// rebuild land on the same tick, and lava blooming while players are
	// still finding their bearings would be read as the level itself
	// killing them. It is short enough now to still be a beat rather
	// than a lull.
	PLAY_LAVA_HOLD_MS = 12000;
	PLAY_LAVA_HOLD_TICKS = PLAY_LAVA_HOLD_MS div TICK_MS;
	PLAY_LAVA_GAP_MS = 6000;
	PLAY_LAVA_GAP_TICKS = PLAY_LAVA_GAP_MS div TICK_MS;

	// Lava may not appear within this many cells of a live head, at
	// growth OR at seeding. THREE, not the reel's two: the reel's snakes
	// crawl on a fixed circuit, while a real snake at expert speed
	// covers 12 cells a second, and lava blooming two cells ahead of
	// that is an unavoidable death nobody could have read.
	PLAY_LAVA_HEAD_CLEAR = 3;

	// Attempts at finding somewhere legal to drop a seed. A seed needs
	// bare floor clear of every head, which most of the board is, so
	// this is generous - but a board with four snakes spread across it
	// during the last-30-seconds ramp is exactly when it could fail, and
	// a pool that fails to seed simply sits out the cycle.
	PLAY_LAVA_SEED_TRIES = 40;

	// Seeds keep this far in from the border wall, so a pool grows into
	// the board rather than immediately hemming itself against the edge
	// - which is also the lane the corner spawns run along.
	PLAY_LAVA_SEED_INSET = 3;

	// ...and this far from EACH OTHER, Chebyshev, so a cycle's pools
	// land in genuinely different parts of the board instead of merging
	// into one big blob that cost twice the budget.
	//
	// Seven on a 14x24 usable area comfortably fits three pools while
	// still leaving most placements legal. A preference rather than a
	// rule - see the seeding loop, which relaxes it rather than losing a
	// pool on a crowded board.
	PLAY_LAVA_SEED_APART = 7;

	// THE ERUPTION SHAKES THE SCREEN, cued just BEFORE the pools appear
	// so the ground moves and then the lava arrives - dengland's own
	// staging for the attract reel ("just before and then during the
	// first parts of the lava eruption", 2026-08-25), and he spotted its
	// absence in play the moment he spectated a lava level.
	//
	// The reel had it and real play did not, which is exactly backwards:
	// on the attract screen it is decoration, but in play it is the only
	// warning a burst is coming, and a burst arriving in silence is the
	// difference between a hazard you can read and one that simply
	// appears under you.
	//
	// Frames, not ticks, for the same reason the reel's are: the client
	// jitters the scroll registers per frame and owns the whole effect
	// after one message (see SendShake).
	PLAY_LAVA_SHAKE_LEAD_MS = 800;
	PLAY_LAVA_SHAKE_MS = 2200;

	PLAY_LAVA_SHAKE_LEAD_TICKS = PLAY_LAVA_SHAKE_LEAD_MS div TICK_MS;
	PLAY_LAVA_SHAKE_FRAMES = PLAY_LAVA_SHAKE_MS div FRAME_MS;

	// --- THE BOSS (stage 8) ---
	//
	// dengland's design, 2026-08-26, in his own words and order:
	//
	//   "the boss can die and has the same starting number of lives"
	//   "instead of respawning though, just go invunerable and lose a
	//    life"
	//   "there from the start for the time being but maybe idle for a
	//    while and unkillable - that way we don't have spawn in issues
	//    and floating to account for"
	//   contact with a player: NORMAL SNAKE RULES
	//   "the boss should not die if it runs into a player but the same
	//    both players run into each other logic for snakes should apply
	//    (becomming invunerable in that case)"
	//   "let's use the both collide to kill the boss"
	//   "instead of time going down normally on this level, you have to
	//    clear it with killing the boss"
	//
	// THE HEAD-ON IS THE WEAPON, and that last decision is what makes
	// this stage its own thing rather than a fast bee level with a
	// bigger snake in it. The only way to hurt the boss is to meet it
	// HEAD TO HEAD, which is the one thing every instinct says not to
	// do; touch any other part of it and the ordinary rules apply, which
	// is to say you die. Nothing else on the board works this way.
	//
	// It follows from the existing head-on rule rather than being bolted
	// on beside it: a mutual collision already costs neither party a
	// life and hands both a shield to get clear with
	// (snakeApplyCollide), so the boss taking damage there is the ONE
	// thing added, and the player's side of it is untouched. It also
	// means the weapon needs no pickup - no heart food, no shield, no
	// setup - so a stage-8 board that has gone badly is still winnable.
	//
	// TWELVE segments, laid out as a SERPENTINE so they fit the 4x4 patch
	// BuildLevel guarantees clear at the centre (LEVEL_CENTRE_CLEAR) - a
	// straight twelve would not, and widening that guarantee would
	// change every level's geometry to suit one stage in eight. The box
	// holds sixteen cells, so twelve is a comfortable fit with room to
	// lengthen this again.
	//
	// Was SIX, which dengland called correctly the moment he saw it in
	// play: "the boss is too small". Six is barely longer than a
	// player's own starting snake (DEMO_SNAKE_LEN is five), so the thing
	// meant to be the climax of the eight-stage cycle read as just
	// another snake in a different colour.
	PLAY_BOSS_LEN = 12;

	// IT GROWS AS IT FEEDS, and a lot ("also grow more from effects. A
	// lot more probably" - dengland). It eats nothing in the scoring
	// sense, but everything it walks over is destroyed, and now every
	// one of those makes it longer.
	//
	// Six per food and two per bee, so a boss level's own swarm feeds the
	// thing hunting you - a nice reversal of the bee levels, where the
	// swarm is the threat and the food is yours.
	//
	// THESE NUMBERS ARE LARGE ON PURPOSE. The first attempt used 3 and 1
	// and measured a boss growing from 12 segments to 13 in a hundred
	// seconds, because it chases HEADS and only ever eats what it
	// happens to cross. Rate alone could not fix that - see the
	// opportunistic grab in TickBoss, which is the other half.
	PLAY_BOSS_GROW_FOOD = 6;
	PLAY_BOSS_GROW_BEE = 2;

	// WHICH FOODS THE BOSS WILL TURN ASIDE FOR, by kind - clubs
	// (no-grow), solid circle (extra-grow), open circle (speed), heart
	// (shield). dengland: "it just wants the grow ones really maybe the
	// invincibility ones".
	//
	// It keeps the boss's appetite legible: it goes for what makes it
	// BIGGER, and ignores speed and the food whose entire purpose is to
	// STOP growth. Note this governs only what it detours for - it
	// destroys and grows from anything it crosses regardless.
	//
	// NOTE the heart does NOT make the boss invulnerable, only larger.
	// Invulnerability is what gates damage AND what makes it flee
	// (TickBoss), so a boss that could eat a shield would spend the
	// level running away un-hittable - which is neither the threat nor
	// the fight. Worth revisiting only if that changes.
	PLAY_BOSS_WANTS: array[0..FOOD_RANDOM_KINDS - 1] of Boolean =
			(False, True, False, True);

	// ...bounded, but by TASTE rather than by the wire.
	//
	// This was 28, chosen because the boss repaints its whole body every
	// tick while flashing and the tick delta budget was a hard 78 for
	// the entire board. That ceiling is gone - SendTileDeltas splits
	// across messages now (see PLAY_DELTAS_PER_MSG) - so the only
	// question left is how big a snake the board can carry and still be
	// playable. Forty of roughly 460 free cells is a wall you plan
	// around rather than dodge.
	PLAY_BOSS_LEN_MAX = 40;

	// The boss's opening dormancy, spent AS INVULNERABILITY (see
	// BossWake) - it sits still, flashing, and cannot be hurt. Long
	// enough to read the board and get moving; short enough that it is
	// not a dead quarter-minute.
	PLAY_BOSS_WAKE_MS = 6000;
	PLAY_BOSS_WAKE_TICKS = PLAY_BOSS_WAKE_MS div TICK_MS;

	// Reeling after a hit: it keeps coming, but cannot be hit again for
	// this long. NOT optional and not merely a fairness gesture - a
	// head-on leaves the two of them nose to nose with the PLAYER also
	// shielded, so without a gate the very next step is another head-on,
	// and all three of the boss's lives would go inside one exchange
	// nobody had to work for.
	//
	// It should also be read alongside PLAY_SPAWN_INVUN_TICKS, the
	// shield the draw hands the player: while both are up, neither can
	// touch the other, which is the disengage window the whole exchange
	// needs given the boss is the faster of the two.
	// It is ALSO how long the boss spends running away (see TickBoss), so
	// it has to be long enough to actually break contact - at a board's
	// base cadence this is a dozen or so steps, which puts real distance
	// between them. Shortening it makes the fight one long shove again.
	PLAY_BOSS_HIT_INVUN_MS = 4000;
	PLAY_BOSS_HIT_INVUN_TICKS = PLAY_BOSS_HIT_INVUN_MS div TICK_MS;

	// THE BOSS RUNS AT PLAYER SPEED - ticks FEWER between steps than the
	// board's base cadence, and now zero of them.
	//
	// It was 1, at dengland's own request ("the boss should have a 1
	// gear speed advantage though, increasing its base movement
	// speed"), and he took it back the same session after playing
	// against it: "I think we do dial down the gear of the boss to
	// normal for a snake again."
	//
	// What the advantage really cost was the FIGHT. A boss you cannot
	// outrun is not more frightening, it is less interactive: it decides
	// every meeting, arrives before you are ready, and the head-on -
	// the only weapon there is - becomes something that happens to you
	// rather than something you set up. At equal speed you can position,
	// turn inside it, and choose the moment.
	//
	// It also removed the last excuse for treating boss collisions
	// differently from any other snake's. Nobody is quicker, so nobody
	// "gets there first", and the mutual-collision rule applies on its
	// own terms - see the head-on in TickPlaySnakes.
	//
	// Kept as a constant rather than deleted: it is one number, the
	// arithmetic around it is already written and clamped, and this is
	// exactly the sort of thing that gets tried again.
	PLAY_BOSS_GEAR_BONUS = 0;

	// The boss's chase weighting, in the bees' own terms (toward :
	// random : stall) - see TickPlayBees, whose chooser this is. Heavier
	// on the chase than any bee, because there is only one of it and it
	// is the whole level.
	//
	// STALL IS STILL NOT ZERO, for the same reason it never reaches zero
	// for bees: a pure chaser moving at a fixed rate is solvable by
	// arithmetic, and a player could compute exactly where it will be.
	PLAY_BOSS_WEIGHT_TOWARD = 6;
	PLAY_BOSS_WEIGHT_RANDOM = 1;
	PLAY_BOSS_WEIGHT_STALL = 1;

	// Landing a hit on the boss - worth several bees, since it means
	// having deliberately driven head-first into the one thing on the
	// board that is faster than you.
	PLAY_BOSS_HIT_PTS = 5000;

	// Killing it outright, paid to whoever lands the last hit ON TOP of
	// that hit's own points. The level's whole objective, and the
	// biggest single award in the game.
	PLAY_BOSS_KILL_PTS = 20000;

	// The victory beat after the boss dies, before the next level is
	// built. Not decoration: killing the boss releases the frozen clock
	// (see KillBoss), and NextLevel then arrives on the ordinary path
	// with the shake and the final SlotStatus already sent rather than
	// being thrown away by the rebuild.
	PLAY_BOSS_CLEAR_MS = 2500;
	PLAY_BOSS_CLEAR_TICKS = PLAY_BOSS_CLEAR_MS div TICK_MS;

	// Frames of screen shake cued when the boss takes a hit and when it
	// finally dies. The client owns the effect (see SendShake); these
	// are the only two moments in real play that use it, and they are
	// the two that most need to be unmistakable.
	PLAY_BOSS_HIT_SHAKE = 8;
	PLAY_BOSS_KILL_SHAKE = 25;


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
// GameStatusToAll - broadcast board-wide state (currently the level
// clock) to everyone in the zone. Caller holds Lock.
//
// FPlayers rather than Watchers: the clock is cheap, and a spectator
// sitting on another page should still have a current picture the moment
// they navigate back to the board.
procedure TSnakeGame.GameStatusToAll;
	var
	j: Integer;

	begin
	with FPlayers.LockList do
		try
		for j:= 0 to Count - 1 do
			SendGameStatus(Items[j]);

		finally
		FPlayers.UnlockList;
		end;
	end;

procedure TSnakeGame.SlotStatusToAll(ASlot: Integer);
	var
	j: Integer;

	begin
	// Every broadcast carries the current gear (SendSlotStatus computes
	// it fresh), so this is where the record of what clients have been
	// told is kept up to date. TickPlaySnakes' change check reads it, and
	// updating it here means a status sent for some OTHER reason - a
	// death, a pickup - counts as having reported the gear too, instead
	// of being followed by a redundant second message.
	PlayGear[ASlot]:= PlayGearFor(ASlot);

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
// Claiming a corner on an ATTRACTING board just takes ownership: the
// tick loop sees the board go from nobody-claimed to somebody-claimed and
// runs StartPlay, which builds a real level and spawns everyone who holds
// a corner. Claiming one on a board that is ALREADY PLAYING has no such
// edge to ride, so it queues its own spawn - see the join-in-progress
// note at the bottom of this routine.
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
		Slots[ASlot].Lives:= PLAY_START_LIVES;

		// Cleared on CLAIM, not on release - so the last run's final score
		// stays on the corner's HUD row until somebody takes it on.
		Slots[ASlot].Score:= 0;

		Result:= ASlot;

		// JOINING IN PROGRESS. If the board is already playing, this claim
		// does not go through StartPlay - so without this the corner is
		// owned, scored and shown on the HUD while having no snake on the
		// board, forever. Only the FIRST claim (the one that flips
		// Playing) ever got a snake.
		//
		// Found 2026-08-25 by the dev ghost client's first four-bot run
		// (tools/ghost_client.py) - it needs a second player to happen at
		// all, which is exactly the class of bug one MEGA65 and one client
		// cannot reach.
		//
		// Queued as a RESPAWN rather than spawned here, deliberately:
		// SpawnPlayerSnake emits deltas, and the tick loop is what owns
		// the delta array and the broadcast. Calling it from this thread
		// would have to invent its own array and its own send. The respawn
		// path already does all of it, including the SlotStatus that tells
		// the client to forget the direction it last sent - and it is the
		// same path a death takes, so a joiner and a returning player
		// arrive by one route, not two that can drift.
		//
		// 1 tick, not PLAY_RESPAWN_TICKS: a player who just pressed START
		// should be on the board, per the join-in-progress design (spawn
		// immediately, shielded, into a cleared start area - no level
		// reset). The death delay exists to punctuate a death, and this
		// is not one.
		if  Playing then
			PlayRespawn[ASlot]:= 1;

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

	// Every board is EASY until boards carry their own difficulty - see
	// the field declarations. The original seeds progress from
	// difficulty the same way (`iLevelProgress = iGameDifficulty`).
	//
	// Was gdNormal, dropped 2026-08-25: dengland found play started too
	// quick. Easy is 5 ticks (2.4 steps/sec) against normal's 4 (3.0),
	// and progress still climbs from there as levels are cleared, so
	// this sets the OPENING pace rather than capping it.
	//
	// One value for all boards is the remaining shortcut here. The real
	// design is per-board difficulty - "the differences between the
	// game boards can be the initial difficulty/speed" - which wants a
	// difficulty alongside the name in ARR_SNAKE_BOARDS rather than a
	// constant in the constructor.
	Difficulty:= gdEasy;
	LevelProgress:= Ord(Difficulty);

	// Overwritten by the seeding loop from ARR_SNAKE_BOARDS, like
	// Difficulty above. High enough to be no ceiling at all if a board
	// is ever created without one - a missing limit should behave like
	// the old unbounded climb rather than silently pinning a board to
	// its opening difficulty, which would be much harder to notice.
	MaxProgress:= 99;

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
// SendTileDeltas - broadcast changed cells, SPLIT ACROSS AS MANY
// MESSAGES AS IT TAKES. Caller holds Lock.
//
// One message holds at most PLAY_DELTAS_PER_MSG cells, because the stack
// caps a payload at 235 bytes and a delta is three: 1 + 78 x 3 = 235
// exactly. Anything longer than that used to be DROPPED - Tick gathered
// into a 78-entry array and EmitCell silently discarded the overflow.
//
// THAT CEILING WAS NEVER A BOSS PROBLEM, though the boss is what
// exposed it (dengland, 2026-08-26: "isn't that going to apply to any
// snake?"). It applies to every snake on the board: MAX_SNAKE_LEN is 64,
// a snake repaints its WHOLE body whenever its invulnerability flash
// flips, and that flip happens every tick - so one well-fed player with
// a shield could exceed the budget on its own, quietly, with nothing to
// show for it but stale cells until the next full sync.
//
// Chunking costs the client a second message on the rare heavy tick.
// That is the right trade: the alternative is not "cheaper", it is
// "wrong", and the client's handler is address-driven and stateless
// per message, so two arriving together apply exactly as one would.
procedure TSnakeGame.SendTileDeltas(APlayer: TPlayer; const ADeltas: array of TTileDelta);
	var
	m: TBaseMessage;
	i, n, sent, chunk: Integer;

	begin
	sent:= 0;
	n:= Length(ADeltas);

	// A zero-length send is not worth a message - and the loop below
	// would not produce one anyway, so say it here rather than leave the
	// caller wondering.
	while sent < n do
		begin
		chunk:= n - sent;

		if  chunk > PLAY_DELTAS_PER_MSG then
			chunk:= PLAY_DELTAS_PER_MSG;

		m:= TBaseMessage.Create;
		m.Category:= mcPlay;
		m.Method:= $09;

		SetLength(m.Data, 1 + chunk * 3);
		m.Data[0]:= chunk;

		for i:= 0 to chunk - 1 do
			begin
			m.Data[1 + i * 3]:= ADeltas[sent + i].Row;
			m.Data[1 + i * 3 + 1]:= ADeltas[sent + i].Col;
			m.Data[1 + i * 3 + 2]:= ADeltas[sent + i].Tile;
			end;

		APlayer.AddSendMessage(m);

		Inc(sent, chunk);
		end;
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

// IsSnakeTile - is this cell occupied by SOME snake, anybody's?
//
// One contiguous run covers the lot: the four players and the boss, both
// roles, every shape, and the shared invulnerability-flash block that
// sits immediately after them. That is the whole point of laying the
// encoding out that way, and it means this needs no player argument and
// cannot miss a case when a shape or a render slot is added.
//
// Deliberately does NOT say WHOSE snake. Nothing that asks this question
// cares - the spawn sweep just needs "leave it alone" - and answering it
// would mean dividing by SHAPE_COUNT and special-casing the flash block,
// which is not shared by accident: a flashing body genuinely has no
// player in its tile value.
function IsSnakeTile(ATile: Byte): Boolean;
	begin
	Result:= (ATile >= TILE_SNAKE_BASE) and (ATile < TILE_LAVA_BASE);
	end;

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

// The reverse of ADir.
//
// Written out rather than done with arithmetic on the ordinals, even
// though TSnakeDir's pairs happen to sit next to each other: that is a
// coincidence of the declaration order, and a reordering would break
// this silently and in a way that only showed up as snakes turning
// inside out.
function OppositeDir(ADir: TSnakeDir): TSnakeDir;
	begin
	case ADir of
		sdUp:    Result:= sdDown;
		sdDown:  Result:= sdUp;
		sdLeft:  Result:= sdRight;
	else
		Result:= sdLeft;
		end;
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
	DemoLavaPhase:= lpIdle;
	DemoLavaStep:= 0;
	DemoLavaHold:= 0;
	DemoWaveWait:= DEMO_WAVE_GAP_TICKS;

	for b:= 0 to High(DemoLava) do
		DemoLava[b].Count:= 0;

	DemoBeeLeft:= 0;
	DemoFoodLeft:= 0;
	DemoBossLeft:= 0;
	DemoShakePending:= 0;

	// Real play's own hazards. StartPlay arms both properly, but a board
	// spends its whole life in attract mode until somebody claims a
	// corner and these must not be reading rubbish before then - the
	// boss slot in particular is walked by every Z-order helper.
	ResetPlayLava;

	PlaySnakes[SNAKE_SLOT_BOSS].Alive:= False;
	PlaySnakes[SNAKE_SLOT_BOSS].Floating:= False;
	BossLives:= 0;
	BossWake:= 0;

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

// --- LAVA, SHARED ----------------------------------------------------
//
// The three primitives below are the whole of what lava DOES; the two
// tick procedures that call them (TickDemoLava, TickPlayLava) are only
// phase machines and pacing. Split out 2026-08-26 when lava was given
// real play stages - see TLavaPhase's own note on why there is one
// definition of this rather than two.

// How far one ATTRACT-REEL pool spreads at this level progress - see
// DEMO_LAVA_CELLS_BASE. Real play has its own, PlayLavaMaxCells, on its
// own numbers. Both clamp to the shared array bound so a long game
// can't walk off the end of TLavaPool.Cells.
function LavaMaxCells(AProgress: Integer): Integer;
	begin
	Result:= DEMO_LAVA_CELLS_BASE + AProgress * DEMO_LAVA_CELLS_PER_LEVEL;

	if  Result > LAVA_CELLS_CAP then
		Result:= LAVA_CELLS_CAP;
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

// LavaSeedPool - start a pool at (ARow, ACol). Caller holds Lock.
//
// Refuses anything but bare floor and simply leaves the pool empty,
// which every caller then treats as "this pool sits this cycle out".
procedure TSnakeGame.LavaSeedPool(var APool: TLavaPool; ARow, ACol,
		AMaxCells: Integer; var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	begin
	APool.Count:= 0;

	if  (ARow <= 0) or (ARow >= BOARD_ROWS - 1)
	or  (ACol <= 0) or (ACol >= BOARD_COLS - 1) then
		Exit;

	if  Board[ARow][ACol] <> TILE_FLOOR then
		Exit;

	APool.Cells[0].Row:= ARow;
	APool.Cells[0].Col:= ACol;
	APool.Count:= 1;

	EmitCell(ARow, ACol, LavaTile(0, AMaxCells), ADeltas, ADeltaCount);
	end;

// LavaGrowOnce - try once to grow APool by a single cell. Caller holds
// Lock. Returns False if the attempt came to nothing, which is normal
// and not an error: the caller retries a bounded number of times.
//
// Deliberately NOT a true Game-of-Life rule - a real one is
// unpredictable enough to either die out or run away across the whole
// board, and neither is what this wants. This gives the same organic
// creeping look with a hard bound.
function TSnakeGame.LavaGrowOnce(var APool: TLavaPool; ATop, ALeft, ABottom,
		ARight, AMaxCells, AClear: Integer; const AHeads: TLavaHeads;
		var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer): Boolean;
	var
	src: TLavaCell;
	have, nr, nc, k: Integer;

	begin
	Result:= False;

	have:= APool.Count;

	if  (have < 1) or (have >= AMaxCells) then
		Exit;

	// Source from the advancing FRONT, not the whole pool - see
	// DEMO_LAVA_FRONTIER. Cells are in creation order, so the front is
	// simply the tail of the array.
	if  have > DEMO_LAVA_FRONTIER then
		src:= APool.Cells[have - 1 - Random(DEMO_LAVA_FRONTIER)]
	else
		src:= APool.Cells[Random(have)];

	nr:= src.Row;
	nc:= src.Col;

	case Random(4) of
		0: Dec(nr);
		1: Inc(nr);
		2: Dec(nc);
	else
		Inc(nc);
		end;

	// The caller's box. For the reel that is one clear cell inside its
	// circuit; for real play it is the board's own playable interior.
	if  (nr <= ATop) or (nr >= ABottom)
	or  (nc <= ALeft) or (nc >= ARight) then
		Exit;

	// Floor, or FOOD, which it burns up on the way through (dengland,
	// 2026-08-26). Everything else refuses it, and that one test is the
	// whole legality rule - it still means "cannot spread through walls,
	// over snake bodies and tails, onto a bee, or over the boss" with no
	// per-hazard special cases and nothing to forget when a tile type is
	// added.
	//
	// It is also why lava can never bury a snake and desynchronise the
	// board from the models, the failure the spawn sweep and the tail
	// vacate both had to be fixed for.
	//
	// Burning food matters more than it sounds on a lava stage: the
	// swarm is switched off there, so food is the only thing on the
	// board worth crossing it for, and lava that politely flowed around
	// the prize made the decision for the player. Now the pools take the
	// board AND what is on it, and a piece of food inside a spreading
	// pool is a closing window rather than a permanent invitation.
	if  Board[nr][nc] <> TILE_FLOOR then
		begin
		if  (Board[nr][nc] < TILE_FOOD_BASE)
		or  (Board[nr][nc] >= TILE_FOOD_BASE + FOOD_TYPE_COUNT) then
			Exit;

		// Struck off the table as well as painted over - the same
		// courtesy the spawn sweep pays, and for the same reason: a food
		// slot left spoken for means the board quietly supports less
		// food until the TTL runs out. Harmless in the attract reel,
		// whose food is written straight to tiles and is not in this
		// table at all.
		ClearFoodAt(nr, nc);
		end;

	// ...but a cell being empty right now is not enough on its own:
	// lava appearing directly in front of a snake would be an
	// unavoidable death nobody could have read. Keep clear of every
	// head the caller listed, the way the original keeps bee spawns
	// clear (checkPlaceBee).
	//
	// NOTE the original's rule is not the box it looks like:
	// isOutsideRect ANDs the two axis tests, so it actually blocks the
	// whole row band AND column band through the head, a cross spanning
	// the board. Fine for a bee, which spawns once - far too much for
	// lava, which would be locked out of most of the board by four
	// snakes at once. So this is the box the original reads as
	// intending.
	for k:= 0 to AHeads.Count - 1 do
		if  (Abs(nr - AHeads.Row[k]) <= AClear)
		and (Abs(nc - AHeads.Col[k]) <= AClear) then
			Exit;

	APool.Cells[APool.Count].Row:= nr;
	APool.Cells[APool.Count].Col:= nc;
	EmitCell(nr, nc, LavaTile(APool.Count, AMaxCells), ADeltas, ADeltaCount);
	Inc(APool.Count);

	Result:= True;
	end;

// LavaRecedeOnce - give up APool's NEWEST cell. Caller holds Lock.
// Returns False when the pool is already empty.
//
// Newest-first, so a pool drains back toward its own bright centre
// rather than hollowing out from the middle.
function TSnakeGame.LavaRecedeOnce(var APool: TLavaPool;
		var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer): Boolean;
	begin
	Result:= False;

	if  APool.Count <= 0 then
		Exit;

	Dec(APool.Count);

	// ONLY CLEAR A CELL THAT IS STILL OURS. Lava writes its own tiles,
	// so anything else standing there now means something took the cell
	// over since - a snake moving through where lava used to be, a spawn
	// sweep clearing a corner - and blanking it would erase that
	// instead, which reads as corruption. Cheap insurance: the pool just
	// gives the cell up.
	//
	// ClearLavaAt exploits this directly, parking a swept cell on (0, 0)
	// - the border wall, which can never be lava - so this test skips it
	// without needing to know it happened.
	with APool.Cells[APool.Count] do
		if  (Board[Row][Col] >= TILE_LAVA_BASE)
		and (Board[Row][Col] < TILE_LAVA_BASE + LAVA_TIER_COUNT) then
			EmitCell(Row, Col, TILE_FLOOR, ADeltas, ADeltaCount);

	Result:= True;
	end;

// DemoLavaHeads / PlayLavaHeads - the heads LavaGrowOnce must keep away
// from. Caller holds Lock.
procedure TSnakeGame.DemoLavaHeads(out AHeads: TLavaHeads);
	var
	k: Integer;

	begin
	AHeads.Count:= 0;

	for k:= 0 to High(DemoSnakes) do
		begin
		AHeads.Row[AHeads.Count]:= DemoSnakes[k].Body[0].Row;
		AHeads.Col[AHeads.Count]:= DemoSnakes[k].Body[0].Col;
		Inc(AHeads.Count);
		end;
	end;

// LIVE snakes only, and the boss counts. It has no lives to lose to a
// lava bloom, but lava spreading over the cell it is about to step into
// would block it silently, and a boss stuck in a lava pocket is a level
// that cannot be cleared. Bees are NOT listed: they are not on a lava
// stage at all (PlayBeeMax returns 0 there).
procedure TSnakeGame.PlayLavaHeads(out AHeads: TLavaHeads);
	var
	k: Integer;

	begin
	AHeads.Count:= 0;

	for k:= 0 to SNAKE_RENDER_SLOTS - 1 do
		if  PlaySnakes[k].Alive then
			begin
			AHeads.Row[AHeads.Count]:= PlaySnakes[k].Body[0].Row;
			AHeads.Col[AHeads.Count]:= PlaySnakes[k].Body[0].Col;
			Inc(AHeads.Count);
			end;
	end;

// TickDemoLava - the attract reel's lava wave. Caller holds Lock.
//
// PHASE MACHINE AND PACING ONLY since 2026-08-26; everything lava
// actually does now lives in LavaSeedPool/LavaGrowOnce/LavaRecedeOnce,
// shared with real play. The behaviour here is unchanged - the
// primitives were lifted from this routine, not written to replace it.
procedure TSnakeGame.TickDemoLava(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	b, i, n, tries, grown: Integer;
	full: Boolean;
	r, c, maxcells: Integer;
	heads: TLavaHeads;

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

	DemoLavaHeads(heads);

	case DemoLavaPhase of
	lpIdle:
		begin
		// Seed the pools: DEMO_LAVA_SEEDS of them, evenly spaced across
		// the middle of the circuit's interior. Two lands them left and
		// right of centre, which is dengland's layout; the
		// spacing generalises if that count ever changes.
		for b:= 0 to High(DemoLava) do
			begin
			r:= (DEMO_TOP + DEMO_BOTTOM) div 2;
			c:= DEMO_LEFT
					+ ((DEMO_RIGHT - DEMO_LEFT) * (2 * b + 1))
						div (2 * DEMO_LAVA_SEEDS);

			LavaSeedPool(DemoLava[b], r, c, maxcells, ADeltas, ADeltaCount);
			end;

		DemoLavaPhase:= lpGrow;
		end;

	lpGrow:
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
				// Stay one clear cell INSIDE the demo circuit - see
				// DEMO_LAVA_CELLS_BASE's comment for why reel lava must
				// never be able to reach a snake.
				if  LavaGrowOnce(DemoLava[b], DEMO_TOP, DEMO_LEFT,
						DEMO_BOTTOM, DEMO_RIGHT, maxcells,
						DEMO_LAVA_HEAD_CLEAR, heads,
						ADeltas, ADeltaCount) then
					Inc(grown);

				Inc(tries);
				end;

			if  DemoLava[b].Count < maxcells then
				full:= False;
			end;

		if  full then
			begin
			DemoLavaPhase:= lpHold;
			DemoLavaHold:= DEMO_LAVA_HOLD_TICKS;
			end;
		end;

	lpHold:
		begin
		Dec(DemoLavaHold, DEMO_LAVA_STEP_TICKS);

		if  DemoLavaHold <= 0 then
			DemoLavaPhase:= lpRecede;
		end;

	lpRecede:
		begin
		n:= 0;

		for b:= 0 to High(DemoLava) do
			for i:= 1 to DEMO_LAVA_PER_STEP do
				if  LavaRecedeOnce(DemoLava[b], ADeltas, ADeltaCount) then
					Inc(n);

		if  n = 0 then
			begin
			DemoLavaPhase:= lpIdle;
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
// Since the 2026-08-25 rescale this lands EXACTLY ONE GEAR PER TIER,
// with nothing shared and nothing clamped away in the middle:
//
//   training 0 -> 6 VSLOW     easy    1 -> 5 SLOW
//   normal   2 -> 4 NORMAL    hard    3 -> 3 FAST
//   expert   4 -> 2 FASTEST
//
// and progress climbing past expert as levels are cleared reaches TOP
// and stops there. That tidiness is the whole reason VSLOW (6) was
// worth adding: on the old scale the arithmetic ran off the bottom and
// the clamp put training and easy both on SLOW, so the gentlest tier
// wasn't actually gentler than the one above it.
//
// The clamp is NOT optional at either end. Without the floor, progress
// past expert reaches 0 - the original's turbo2, "DO NOT USE turbo
// settings, especially turbo2!" (server.lua:46) - and then goes
// negative, which would be a step every zero ticks.
// InvunFlashOn - is a snake with ATicks of invulnerability left showing
// its flash tile THIS tick?
//
// The phase is derived from the countdown itself rather than kept as
// state, so it needs no per-snake bookkeeping and cannot drift.
//
// IT SLOWS DOWN NEAR THE END, which is the whole reason this is a
// function and not an expression written out twice. Below
// PLAY_INVUN_WARN_TICKS the flash runs at PLAY_INVUN_WARN_SLOW times
// the period, so a shield about to expire looks visibly different from
// one that has just been picked up - see the constants for why slower
// rather than faster.
function InvunFlashOn(ATicks: Integer): Boolean;
	var
	period: Integer;

	begin
	Result:= False;

	if  ATicks <= 0 then
		Exit;

	period:= DEMO_INVUN_FLASH_TICKS;

	if  ATicks <= PLAY_INVUN_WARN_TICKS then
		period:= period * PLAY_INVUN_WARN_SLOW;

	Result:= ((ATicks div period) and 1) = 0;
	end;

function SnakeStepTicks(AProgress: Integer): Integer;
	begin
	Result:= SNAKE_SPEED_NORMAL + 2 - AProgress;

	if  Result > SNAKE_SPEED_VSLOW then
		Result:= SNAKE_SPEED_VSLOW;

	if  Result < SNAKE_SPEED_TOP then
		Result:= SNAKE_SPEED_TOP;

	end;
// --- REAL PLAY ---------------------------------------------------------

// SpawnPlayerSnake - lay corner ASlot's snake on the board, shielded,
// with the ground around it swept clear. Caller holds Lock.
//
// PLACEMENT IS THE DEMO'S, EXACTLY: same circuit, same inset, same
// quarter-lap spacing, walked out by the same CircuitAt pair that
// InitDemoSnakes uses. dengland's own answer when asked where the
// corners should be (2026-08-25): "they should just be the same as the
// demo".
//
// Right in a way none of the three layouts I offered were. The attract
// screen has been showing players exactly where they start all along,
// so the demo doubles as the explanation - and there is now only ONE
// definition of where a corner is. The invented second one had already
// drifted from it (inset 1, head five cells along the wall) and would
// have drifted again the moment either moved.
procedure TSnakeGame.SpawnPlayerSnake(ASlot: Integer;
		var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
	var
	i, d, r, c, spacing: Integer;
	hr, hc: Byte;
	cr, cc, rPrev, cPrev: Byte;
	dirIn, dirOut: TSnakeDir;

	// One cell of the spawn area made safe. Hoisted out because it is now
	// called from TWO places - the box around the head, and every cell the
	// body itself will occupy - and those must not be able to disagree
	// about what "cleared" means.
	procedure ClearSpawnCell(ARow, ACol: Integer);
		begin
		if  (ARow <= 0) or (ARow >= BOARD_ROWS - 1)
		or  (ACol <= 0) or (ACol >= BOARD_COLS - 1) then
			Exit;

		// Walls stay (punching holes in the level is worse than the
		// problem) and so do snakes - see the sweep's own comment.
		if  (Board[ARow][ACol] = TILE_FLOOR)
		or  (Board[ARow][ACol] = TILE_WALL)
		or  IsSnakeTile(Board[ARow][ACol]) then
			Exit;

		// Food, bees and lava swept up this way have to be struck off
		// their tables too, or the slot stays spoken for until the TTL
		// runs out and the board quietly supports less of them.
		//
		// Lava joined the list when it gained real play stages
		// (2026-08-26). Its pool would not have leaked a slot the way
		// food and bees do - LavaRecedeOnce declines to clear a cell
		// that is no longer lava, so nothing would have been corrupted -
		// but the pool would have gone on believing it was that much
		// bigger than it was, and grown that much less. See ClearLavaAt
		// for why it parks the cell rather than removing it.
		ClearFoodAt(ARow, ACol);
		ClearBeeAt(ARow, ACol);
		ClearLavaAt(ARow, ACol);

		EmitCell(ARow, ACol, TILE_FLOOR, ADeltas, ADeltaCount);
		end;

	begin
	spacing:= DEMO_LAP div SNAKE_PLAYER_COUNT;

	// The head's cell, needed up front for the hazard sweep below.
	CircuitAt(ASlot * spacing, hr, hc, dirOut);

	// Sweep the area clear first - a corner can easily have lava or a
	// bee sitting on it from the attract reel, or from another player's
	// hazard, and spawning into that would be an instant and
	// unattributable death. Only floor-and-hazard is cleared; WALLS
	// stay, since the spawn lane is guaranteed clear of them anyway and
	// punching holes in the level would be worse than the problem.
	//
	// AND SNAKES STAY TOO (dengland, 2026-08-25). The sweep used to take
	// them with everything else, which did not just look wrong - it
	// desynchronised the board from the model. The victim's Body[] still
	// held every one of those cells, so it went on living and moving
	// while its tiles read as bare floor, which made them PASSABLE: the
	// collision test reads Board, so anything could then drive straight
	// through the invisible half of another snake until its tail caught
	// up and the cells came back.
	//
	// Leaving them means the spawn can land ON another snake, which is
	// its own problem - see the overlap note where the body is painted
	// below. Deleting a live player to make room was never the answer to
	// it.
	//
	// THE BOX ROUND THE HEAD IS NOT THE WHOLE SNAKE - the body is swept
	// separately once its cells are known, below. PLAY_SPAWN_CLEAR is a
	// radius of 3 about the head while DEMO_SNAKE_LEN is 5, so on a
	// straight run the last segment lands 4 cells back, outside this box
	// entirely (dengland, 2026-08-26).
	for r:= Integer(hr) - PLAY_SPAWN_CLEAR to Integer(hr) + PLAY_SPAWN_CLEAR do
		for c:= Integer(hc) - PLAY_SPAWN_CLEAR to Integer(hc) + PLAY_SPAWN_CLEAR do
			ClearSpawnCell(r, c);

	with PlaySnakes[ASlot] do
		begin
		Len:= DEMO_SNAKE_LEN;
		Player:= ASlot;
		MoveTick:= BoardStepTicks;
		InvunTicks:= PLAY_SPAWN_INVUN_TICKS;
		FlashOn:= True;
		Alive:= True;

		// A death spends every power-up with it. The original does the
		// same on a respawn (snakeReset, server.lua:1083 - moveFast,
		// growEx, growNone and grow all back to nothing), and it is what
		// stops a speed burst outliving the snake that earned it.
		MoveFast:= 0;
		Grow:= False;
		GrowNone:= 0;
		GrowEx:= 0;

		// Head at its own offset, body trailing back along the circuit -
		// InitDemoSnakes' loop verbatim. Walking the circuit rather than
		// stepping back along one axis is what lets a snake spawn ON a
		// corner and bend round it correctly, instead of running off the
		// board or drawing a straight line through the wall.
		for i:= 0 to Len - 1 do
			begin
			d:= (ASlot * spacing) - i;

			// dirOut is the way the snake leaves this cell; dirIn the way
			// it arrived, i.e. the step from the cell before it.
			CircuitAt(d, cr, cc, dirOut);
			CircuitAt(d - 1, rPrev, cPrev, dirIn);

			Body[i].Row:= cr;
			Body[i].Col:= cc;
			Body[i].Shape:= SegShape(dirIn, dirOut);

			if  i = 0 then
				begin
				Dir:= dirIn;		// how it got here
				Look:= dirOut;		// where it is going
				end;
			end;

		// NOW SWEEP THE BODY'S OWN CELLS. The box above only reaches 3
		// from the head, so without this a tail segment can come down on
		// a live bee or a piece of food and hide it: the tile is
		// overwritten but the table entry survives, so the bee goes on
		// moving under the snake and the food goes on holding a slot.
		//
		// Done AFTER the body is placed, because that is the first moment
		// these cells are known - which is the whole reason it could not
		// simply be folded into the box above.
		for i:= 0 to Len - 1 do
			ClearSpawnCell(Body[i].Row, Body[i].Col);

		// OVERLAP. The sweep above deliberately left other snakes where
		// they were, so this body may have been laid straight through
		// one. Rather than refuse, move, or delete anybody, the arriving
		// snake FLOATS: it passes through until it is clear, renders on
		// top meanwhile, and cannot kill what it is standing in. See
		// TSnake.Floating.
		//
		// Tested over the whole body, not just the head, because any
		// overlapping segment is a cell two snakes are sharing - and the
		// vacate path has to know about all of them, not only the one the
		// head happens to be on.
		Floating:= False;

		for i:= 0 to Len - 1 do
			if  SolidSnakeAt(Body[i].Row, Body[i].Col, ASlot) >= 0 then
				begin
				Floating:= True;
				Break;
				end;

		// Logged because it is rare, interesting, and otherwise
		// invisible: a spawn overlap happens only when somebody is lying
		// across a corner as it respawns, which is exactly the case that
		// is awkward to reproduce on purpose and worth knowing really
		// happened when it does. One line per spawn at most.
		if  Floating then
			AddLogMessage(slkDebug, 'Snake ' + IntToStr(ASlot)
					+ ' spawned onto another snake - floating');

		EmitCell(Body[0].Row, Body[0].Col,
				SnakeTile(Player, SNAKE_ROLE_HEAD, Body[0].Shape),
				ADeltas, ADeltaCount);

		for i:= 1 to Len - 1 do
			EmitCell(Body[i].Row, Body[i].Col,
					SnakeBodyTile(Player, Body[i].Shape, FlashOn),
					ADeltas, ADeltaCount);
		end;

	PlayRespawn[ASlot]:= 0;
	end;

// KillPlayerSnake - wipe one snake off the board, spend a life, and
// either queue a respawn or give the corner up. Caller holds Lock.
procedure TSnakeGame.KillPlayerSnake(ASlot: Integer;
		var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
	var
	i: Integer;

	begin
	if  not PlaySnakes[ASlot].Alive then
		Exit;

	// Alive goes down FIRST, so the VacateCell calls below do not find
	// this snake still standing in its own cells and dutifully repaint
	// the corpse it is trying to clear.
	PlaySnakes[ASlot].Alive:= False;
	PlaySnakes[ASlot].Floating:= False;

	for i:= 0 to PlaySnakes[ASlot].Len - 1 do
		with PlaySnakes[ASlot].Body[i] do
			// Restores whoever was underneath rather than clearing - the
			// snake that dies inside another one must not take a bite out
			// of it on the way out. See VacateCell.
			VacateCell(Row, Col, ASlot, ADeltas, ADeltaCount);

	if  Slots[ASlot].Lives > 0 then
		Dec(Slots[ASlot].Lives);

	if  Slots[ASlot].Lives > 0 then
		begin
		PlayRespawn[ASlot]:= PLAY_RESPAWN_TICKS;
		SlotStatusToAll(ASlot);

		Exit;
		end;

	// Out of lives - the run is over and the corner goes back to the
	// pool. Deliberately NOT a call to ReleaseSlot: that acquires Lock,
	// and everything on this path is already holding it. The three
	// assignments are the same ones ReleaseSlot and Remove make.
	PlayRespawn[ASlot]:= 0;

	Slots[ASlot].Player:= nil;
	Slots[ASlot].Name:= '';
	Slots[ASlot].State:= psNone;

	SlotStatusToAll(ASlot);
	end;

// SetPlayerLook - a player asked to turn. Caller must NOT hold Lock.
//
// A reversal onto the snake's own neck is refused rather than obeyed.
// The original does the same thing implicitly by dying on it, but with
// four players and a shared board an accidental reverse is far more
// often a fumbled input than an intent, and eating yourself for it is a
// bad-feeling death. Refusing costs the player nothing they wanted.
//
// Note this tests Dir, the direction actually TRAVELLED, not Look. Two
// quick turns inside one step would otherwise let a player reverse via
// an intermediate direction that never happened on the board.
procedure TSnakeGame.SetPlayerLook(APlayer: TPlayer; ADir: TSnakeDir);
	var
	i: Integer;
	bad: TSnakeDir;

	begin
	Lock.Acquire;
		try
		for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
			if  (Slots[i].Player = APlayer) and PlaySnakes[i].Alive then
				begin
				case PlaySnakes[i].Dir of
					sdUp:    bad:= sdDown;
					sdDown:  bad:= sdUp;
					sdLeft:  bad:= sdRight;
					else     bad:= sdLeft;
					end;

				if  (ADir <> bad) and (ADir <> PlaySnakes[i].Look) then
					begin
					PlaySnakes[i].Look:= ADir;

					// SHOW IT NOW - before the step is attempted, and so
					// before anything has decided whether it can even be
					// made (dengland, 2026-08-26: "it should be showing
					// the turn before its made so before its determined
					// that it can't be done").
					//
					// That is what the telegraph is FOR. The head is
					// shaped from Dir toward Look precisely so a turn
					// shows the moment it is decided rather than when
					// the body follows it, and the original repaints the
					// head as soon as input arrives (playersTick) for
					// exactly this reason.
					//
					// A FLAG rather than a direct paint, because this
					// runs on the message thread and has no delta array
					// to write into - Tick owns that. It is picked up at
					// the top of the next TickPlaySnakes pass, which is
					// one tick at worst and always before the step it
					// belongs to.
					PlayHeadDirty[i]:= True;
					end;

				Break;
				end;

		finally
		Lock.Release;
		end;
	end;

// FoodAt - which PlayFood entry, if any, is sitting on this cell.
// Returns -1 for none. Caller holds Lock.
//
// A linear scan of five, run at most once per snake per step. A position
// index would be faster and would need keeping in step with the board;
// this cannot go stale.
function TSnakeGame.FoodAt(ARow, ACol: Byte): Integer;
	var
	i: Integer;

	begin
	Result:= -1;

	for i:= 0 to PLAY_FOOD_MAX - 1 do
		if  PlayFood[i].Active
		and (PlayFood[i].Row = ARow) and (PlayFood[i].Col = ACol) then
			begin
			Result:= i;
			Exit;
			end;
	end;

// ClearFoodAt - forget the food on this cell, for when something OTHER
// than a snake eating it has taken it off the board. Caller holds Lock.
//
// The spawn sweep is the case that needs this (SpawnPlayerSnake clears
// everything that is not floor or wall around an arriving player). Without
// it the table would still be holding a slot for a tile that no longer
// exists, and the board would quietly support fewer and fewer pieces of
// food as the game went on.
procedure TSnakeGame.ClearFoodAt(ARow, ACol: Byte);
	var
	i: Integer;

	begin
	i:= FoodAt(ARow, ACol);

	if  i >= 0 then
		PlayFood[i].Active:= False;
	end;

// EatFood - apply one food's effects to one snake, and pay for it.
// Caller holds Lock; the food's tile has NOT been cleared yet.
//
// snakeCheckEat (server.lua:957) more or less line for line, with the
// battle-mode branch taken throughout - see the PLAY_FOOD_* constants.
procedure TSnakeGame.EatFood(ASlot, AFood: Integer);
	var
	pts: Integer;

	begin
	with PlaySnakes[ASlot] do
		begin
		case PlayFood[AFood].Kind of
			// Type 0, clubs - points and speed, but no length. Or rather:
			// it CANCELS the extra-growth food if that is running, and
			// only sets its own suppression timer if it is not. Eating
			// this while already growing spends the food on stopping,
			// which is the trade.
			0:	begin
				pts:= PLAY_FOOD_PTS_NOGROW;

				if  GrowEx > 0 then
					GrowEx:= 0
				else
					GrowNone:= PLAY_FOOD_NOGROW_TICKS;

				Inc(MoveFast, PLAY_FAST_NOGROW);
				end;

			// Type 1, solid circle - the mirror image: cancels a running
			// suppression, or starts growing on every step. Cheapest food
			// on the board and the only one that slows you down.
			1:	begin
				pts:= PLAY_FOOD_PTS_XGROW;

				if  GrowNone > 0 then
					GrowNone:= 0
				else
					GrowEx:= PLAY_FOOD_XGROW_TICKS;

				Inc(MoveFast, PLAY_FAST_XGROW);
				end;

			// Type 2, open circle - pure speed, nothing else.
			2:	begin
				pts:= PLAY_FOOD_PTS_BURST;
				Inc(MoveFast, PLAY_FAST_BURST);
				end;

			// Type 3, heart - a shield, ADDED to whatever is left of the
			// one already running and capped, so eating two in a row is
			// worth less than eating them apart.
			3:	begin
				pts:= PLAY_FOOD_PTS_SHIELD;

				Inc(InvunTicks, PLAY_FOOD_INVUN_TICKS);

				if  InvunTicks > PLAY_INVUN_CAP_TICKS then
					InvunTicks:= PLAY_INVUN_CAP_TICKS;

				Inc(MoveFast, PLAY_FAST_SHIELD);
				end;

			// THE KEY - cuts the level clock to PLAY_KEY_CLOCK_TICKS.
			//
			// Only ever DOWN. Late in a level the clock is already below
			// 30 seconds, and a key that pushed it back up would turn the
			// one pickup meant to hurry a level along into a way of
			// prolonging it.
			//
			// The ramp is deliberately not forced here. Setting the clock
			// is enough: the tick loop's own `LevelTicks <=
			// PLAY_LEVEL_RAMP_TICKS` test fires on the very next tick, so
			// the ramp arrives through the one path that owns it rather
			// than being latched from two places that could disagree.
			else
				begin
				pts:= PLAY_FOOD_PTS_KEY;

				if  LevelTicks > PLAY_KEY_CLOCK_TICKS then
					LevelTicks:= PLAY_KEY_CLOCK_TICKS;

				// TAKING ONE ENDS THIS LEVEL'S KEYS. One escape hatch
				// per level: you either take it or you do not
				// (dengland, 2026-08-26 - "we definitely can't have it
				// that you take two of these keys").
				//
				// Explicit rather than left to the clock. Cutting the
				// level to 30 seconds usually outran the next scheduled
				// attempt, but only usually - whether a second key
				// appeared came down to whether its random gap happened
				// to fall inside the time left, which is an outcome
				// decided by a number the player cannot see.
				LevelKeysLeft:= 0;
				LevelKeyTimer:= 0;
				end;
			end;

		if  MoveFast > PLAY_FAST_CAP then
			MoveFast:= PLAY_FAST_CAP
		else if MoveFast < -PLAY_FAST_FLOOR then
			MoveFast:= -PLAY_FAST_FLOOR;

		// EVERY food grows you once, on top of whatever else it did -
		// including the one whose whole job is to stop growth, which sets
		// GrowNone in the same breath and so suppresses its own segment.
		Grow:= True;
		end;

	PlayFood[AFood].Active:= False;

	AddScore(ASlot, pts);
	end;

// AddScore - pay a corner, and hand out a life on every multiple of
// PLAY_BONUS_LIFE crossed. Caller holds Lock.
//
// The original keeps a `bonus` counter per player and compares
// floor(score / iGameBonusLife) against it. None is needed here: a score
// only ever rises, and only by one food at a time, so comparing the
// division before and against after catches the crossing directly.
//
// Does NOT broadcast - the caller does, because a step that scores has
// other reasons to send a SlotStatus anyway and one is enough.
procedure TSnakeGame.AddScore(ASlot, APoints: Integer);
	var
	was: Integer;

	begin
	was:= Slots[ASlot].Score div PLAY_BONUS_LIFE;

	Inc(Slots[ASlot].Score, APoints);

	if  Slots[ASlot].Score > PLAY_SCORE_MAX then
		Slots[ASlot].Score:= PLAY_SCORE_MAX;

	if  (Slots[ASlot].Score div PLAY_BONUS_LIFE) > was then
		Inc(Slots[ASlot].Lives);
	end;

// PlayStepTicks - how many ticks corner ASlot's snake waits between
// steps right now: the board's own gear, shifted by that snake's
// MoveFast. Caller holds Lock.
//
// The shift is the original's, thresholds and all (objectsTick,
// server.lua:1776): a big MoveFast is worth two gears, any positive one
// gear, a negative one gear the other way. Deliberately NOT proportional
// - the original quantises it hard, and that is what makes a speed food
// read as a distinct state rather than a slider.
function TSnakeGame.PlayStepTicks(ASlot: Integer): Integer;
	begin
	Result:= BoardStepTicks;

	if  PlaySnakes[ASlot].MoveFast >= PLAY_FAST_HARD then
		Dec(Result, 2)
	else if PlaySnakes[ASlot].MoveFast > 0 then
		Dec(Result)
	else if PlaySnakes[ASlot].MoveFast < 0 then
		Inc(Result);

	// Only the FAST end is clamped. The original clamps at 0, which is
	// its own turbo2 - "DO NOT USE turbo settings" (server.lua:46) - so
	// this stops at TOP instead. The slow end needs no clamp: the base is
	// already at most VSLOW, so a slowed snake can only reach VSLOW + 1,
	// which is a legitimate gear to be stuck in for a second.
	if  Result < SNAKE_SPEED_TOP then
		Result:= SNAKE_SPEED_TOP;
	end;

// PlayGearFor - corner ASlot's speed as the HUD shows it: one of the six
// named gears (SNAKE_SPEED_TOP..SNAKE_SPEED_VSLOW), or 0 for a corner
// nobody is playing. Caller holds Lock.
//
// Clamped onto the ladder, which PlayStepTicks is NOT: a slowed snake on
// an already-slow board sits at VSLOW + 1, a real seventh gear with no
// name and no bar segment of its own. It reads as VSLOW here, which is
// honest enough - it IS the bottom of the range - and keeps the display
// to the six gears that exist.
//
// A DEAD snake reports its board's base gear rather than 0. Its bar
// would otherwise empty and refill on every death, and the death is
// already being announced by the lives row right above it.
function TSnakeGame.PlayGearFor(ASlot: Integer): Integer;
	begin
	Result:= 0;

	if  not Assigned(Slots[ASlot].Player) then
		Exit;

	if  PlaySnakes[ASlot].Alive then
		Result:= PlayStepTicks(ASlot)
	else
		Result:= BoardStepTicks;

	if  Result > SNAKE_SPEED_VSLOW then
		Result:= SNAKE_SPEED_VSLOW;

	if  Result < SNAKE_SPEED_TOP then
		Result:= SNAKE_SPEED_TOP;
	end;

// RandomFoodKind - which food to put down. Caller holds Lock.
//
// NOT FOOD_TYPE_COUNT anywhere in here: the key is SCHEDULED, never
// rolled, so it can only ever arrive through TrySpawnKey. See
// FOOD_RANDOM_KINDS.
//
// THE BOSS STAGE RE-WEIGHTS THE TABLE (dengland, 2026-08-26: "do we
// change the food distribution so there are fewer slow and grows and
// more invincibles and fasts? I think perhaps yes"), and the reason it
// wants to is specific to that stage rather than general. On a boss
// level the thing chasing you is FASTER than you are, so the two foods
// that make you longer and slower are actively working against the
// player, while the shield is the only thing that makes the boss's body
// survivable to be near - and getting near it is the entire objective,
// since the head-on is the only weapon.
//
// So the weights follow the stage's own logic rather than being a
// difficulty knob: 4 shield, 3 pure speed, 2 no-grow, 1 extra-grow, out
// of ten. The slow, growing food is still THERE - it is the cheapest
// scoring food on the board and taking one is a real decision under
// pressure - it is simply no longer as likely as everything else.
//
// Every other stage keeps the flat roll it has always had.
function TSnakeGame.RandomFoodKind: Integer;
	var
	i, total, pick: Integer;

	begin
	if  not StageHasBoss then
		begin
		Result:= Random(FOOD_RANDOM_KINDS);

		Exit;
		end;

	total:= 0;

	for i:= 0 to FOOD_RANDOM_KINDS - 1 do
		Inc(total, PLAY_FOOD_WEIGHT_BOSS[i]);

	pick:= Random(total);

	for i:= 0 to FOOD_RANDOM_KINDS - 1 do
		begin
		Dec(pick, PLAY_FOOD_WEIGHT_BOSS[i]);

		if  pick < 0 then
			begin
			Result:= i;

			Exit;
			end;
		end;

	// Unreachable while the weights are positive, but a weight table
	// edited down to all zeroes would otherwise fall out of here with
	// Result undefined.
	Result:= 0;
	end;

// TickPlayFood - age the food on the board and roll for one more.
// Caller holds Lock.
//
// levelTick's bonus half (server.lua:1942) plus levelExpireTiles.
// Deliberately NOT modelled on the bee placement rule: checkPlaceBee
// keeps hazards out of a player's lane, and food is the opposite kind of
// thing - it is SUPPOSED to appear somewhere you have to go and get it.
procedure TSnakeGame.TickPlayFood(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i, free, r, c, kind: Integer;

	begin
	free:= -1;

	for i:= 0 to PLAY_FOOD_MAX - 1 do
		begin
		if  not PlayFood[i].Active then
			begin
			if  free < 0 then
				free:= i;

			Continue;
			end;

		Dec(PlayFood[i].Ticks);

		if  PlayFood[i].Ticks > 0 then
			Continue;

		// Rotted. Only wipe the cell if it is still OUR tile - a snake
		// head arriving on the same tick as the expiry would already have
		// eaten it and cleared the entry, but a level rebuild or a spawn
		// sweep can have painted over it without going through
		// ClearFoodAt, and clearing that to floor would punch a hole in
		// whatever replaced it.
		if  (Board[PlayFood[i].Row][PlayFood[i].Col]
				= TILE_FOOD_BASE + PlayFood[i].Kind) then
			EmitCell(PlayFood[i].Row, PlayFood[i].Col, TILE_FLOOR,
					ADeltas, ADeltaCount);

		PlayFood[i].Active:= False;

		if  free < 0 then
			free:= i;
		end;

	if  free < 0 then
		Exit;

	if  Random(PLAY_FOOD_SPAWN_ODDS) <> 0 then
		Exit;

	// One attempt at one cell, and if it is occupied the roll is simply
	// wasted - the original does the same rather than searching for
	// somewhere free. It is what makes a busy board hand out less food
	// without any explicit rule saying so.
	r:= 1 + Random(BOARD_ROWS - 2);
	c:= 1 + Random(BOARD_COLS - 2);

	if  Board[r][c] <> TILE_FLOOR then
		Exit;

	kind:= RandomFoodKind;

	PlayFood[free].Row:= r;
	PlayFood[free].Col:= c;
	PlayFood[free].Kind:= kind;
	PlayFood[free].Ticks:= PLAY_FOOD_TTL_MIN
			+ Random(PLAY_FOOD_TTL_MAX - PLAY_FOOD_TTL_MIN + 1);
	PlayFood[free].Active:= True;

	EmitCell(r, c, TILE_FOOD_BASE + kind, ADeltas, ADeltaCount);
	end;

// BoardStepTicks - this board's base step cadence right now. Caller
// holds Lock.
//
// SnakeStepTicks for the current progress, one gear quicker once the
// level has ramped. Real play paces EVERYTHING off this rather than
// calling SnakeStepTicks directly, which is what makes the ramp reach
// the bees as well as the snakes - if it only reached the snakes, the
// last 30 seconds would make the hazard RELATIVELY slower, which is
// backwards.
//
// The demo deliberately still calls SnakeStepTicks directly: the attract
// reel has no level clock to ramp.
function TSnakeGame.BoardStepTicks: Integer;
	begin
	// SpeedProgress, NOT LevelProgress - speed steps once per set of
	// levels while everything else scales per level. See SpeedProgress.
	Result:= SnakeStepTicks(SpeedProgress);

	if  LevelRamped then
		Dec(Result);

	if  Result < SNAKE_SPEED_TOP then
		Result:= SNAKE_SPEED_TOP;
	end;

// LevelSecsLeft - the level clock as whole seconds, rounded UP so it
// only shows zero when the level is genuinely over. Caller holds Lock.
function TSnakeGame.LevelSecsLeft: Integer;
	begin
	Result:= (LevelTicks * TICK_MS + 999) div 1000;

	if  Result < 0 then
		Result:= 0;
	end;

// NextLevel - the clock ran out. Rebuild on the next pattern, one step
// harder, and put everyone back on their corner. Caller holds Lock.
//
// THE FOUR LINE-GENERATOR PATTERNS ARE CYCLED HERE. They were ported and
// verified back when the level geometry was built (levelGenA..D, see
// BuildLevel and LEVEL_VARIANTS) and have been sitting unused since,
// because nothing ever asked for a second level. This is the thing that
// asks.
//
// Progress rises every level, exactly as the original does
// (iLevelProgress increments per level cleared), so an easy board
// converges on a hard one if you live long enough. Both the things it
// feeds - SnakeStepTicks and PlayBeeMax - clamp, so it saturates rather
// than running away.
//
// Lives and SCORE are untouched: they live on the slot precisely so they
// outlast things like this. A level change is not a new game.
procedure TSnakeGame.NextLevel;
	var
	i, deltaCount: Integer;
	deltas: array of TTileDelta;

	begin
	Inc(LevelProgress);

	// Stop at this board's ceiling - see TSnakeBoardDef.MaxProgress.
	// The board goes on cycling its layouts and its stages forever, it
	// just stops getting harder.
	if  LevelProgress > MaxProgress then
		LevelProgress:= MaxProgress;

	LevelVariant:= (LevelVariant + 1) mod LEVEL_VARIANTS;
	Inc(LevelNumber);

	LevelTicks:= PLAY_LEVEL_TICKS;
	LevelRamped:= False;
	LevelBeesEaten:= 0;
	LevelSecsSent:= -1;			// force the clock out again

	// AFTER LevelNumber has moved - both of these read LevelStage, which
	// is derived from it, so arming them before the increment would give
	// this level the PREVIOUS stage's key budget and lava tier.
	ResetLevelKeys;
	ResetPlayLava;

	BuildLevel(LevelVariant, LevelProgress);

	for i:= 0 to PLAY_FOOD_MAX - 1 do
		PlayFood[i].Active:= False;

	for i:= 0 to PLAY_BEE_CAP - 1 do
		PlayBees[i].Active:= False;

	// Everyone still holding a corner starts again on it. A snake that
	// was mid-board when the clock ran out would otherwise find itself
	// inside whatever the new pattern put there.
	//
	// SNAKE_RENDER_SLOTS for the same reason StartPlay uses it: the boss
	// goes down with everybody else and is re-laid below only if this
	// stage wants one. Note the boss is very often ALREADY dead here -
	// killing it is what ended the level - and clearing it again is
	// harmless.
	for i:= 0 to SNAKE_RENDER_SLOTS - 1 do
		PlaySnakes[i].Alive:= False;

	for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
		PlayRespawn[i]:= 0;

	// As in StartPlay: the spawns write straight into Board and go out
	// with the whole-board push below, so their deltas are thrown away.
	SetLength(deltas, 64);
	deltaCount:= 0;

	if  StageHasBoss then
		SpawnBoss(deltas, deltaCount);

	for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  Assigned(Slots[i].Player) then
			SpawnPlayerSnake(i, deltas, deltaCount);

	PushBoardToWatchers;
	end;

// BeeAt / ClearBeeAt - the same pair FoodAt/ClearFoodAt are, and for the
// same reasons. Caller holds Lock.
function TSnakeGame.BeeAt(ARow, ACol: Byte): Integer;
	var
	i: Integer;

	begin
	Result:= -1;

	for i:= 0 to PLAY_BEE_CAP - 1 do
		if  PlayBees[i].Active
		and (PlayBees[i].Row = ARow) and (PlayBees[i].Col = ACol) then
			begin
			Result:= i;
			Exit;
			end;
	end;

procedure TSnakeGame.ClearBeeAt(ARow, ACol: Byte);
	var
	i: Integer;

	begin
	i:= BeeAt(ARow, ACol);

	if  i >= 0 then
		PlayBees[i].Active:= False;
	end;

// SolidSnakeAt - which live, NON-FLOATING snake occupies this cell, or
// -1. Caller holds Lock.
//
// THE COLLISION QUESTION. A floating snake is deliberately invisible to
// it: that is the whole of "other snakes can't be killed by it while
// floating" (dengland, 2026-08-25), expressed once here rather than as a
// test repeated at every site that might run into one.
//
// AExclude is skipped; pass -1 to check everybody. The COLLISION caller
// passes -1 on purpose - your own body still stops you - while the SPAWN
// caller has to exclude itself, since by then it is already Alive with
// its new Body[] in place and would otherwise find nothing but itself
// and float every single time.
//
// The about-to-vacate tail exemption is NOT here; it belongs to the
// caller, which is the only place that knows whether the snake is
// growing this step and therefore whether the tail is really leaving.
function TSnakeGame.SolidSnakeAt(ARow, ACol: Byte; AExclude: Integer): Integer;
	var
	k, j: Integer;

	begin
	Result:= -1;

	// SNAKE_RENDER_SLOTS, so the BOSS is in the answer. This is what
	// gives the boss collision without a line of collision code being
	// written for it - see PlaySnakes' own note. It also means a caller
	// can get SNAKE_SLOT_BOSS back from here, and TickPlaySnakes reads
	// exactly that to tell a boss hit from an ordinary one.
	for k:= 0 to SNAKE_RENDER_SLOTS - 1 do
		if  (k <> AExclude) and PlaySnakes[k].Alive
		and not PlaySnakes[k].Floating then
			for j:= 0 to PlaySnakes[k].Len - 1 do
				if  (PlaySnakes[k].Body[j].Row = ARow)
				and (PlaySnakes[k].Body[j].Col = ACol) then
					begin
					Result:= k;
					Exit;
					end;
	end;

// SnakeSegAt - which of ASnake's segments is on this cell, or -1.
// Caller holds Lock.
function TSnakeGame.SnakeSegAt(ASnake: Integer; ARow, ACol: Byte): Integer;
	var
	j: Integer;

	begin
	Result:= -1;

	for j:= 0 to PlaySnakes[ASnake].Len - 1 do
		if  (PlaySnakes[ASnake].Body[j].Row = ARow)
		and (PlaySnakes[ASnake].Body[j].Col = ACol) then
			begin
			Result:= j;
			Exit;
			end;
	end;

// TopSnakeAt - which live snake's tile should be SHOWING in this cell,
// ignoring AExclude, or -1 if none. Caller holds Lock.
//
// THE RENDER QUESTION, and the counterpart to SolidSnakeAt. A floating
// snake wins, because that is what floating means; failing that, whoever
// is found. AExclude is the snake asking - normally the one leaving the
// cell, which must not count itself as a reason to stay painted.
//
// Two passes rather than one with a running preference: the first hit
// can be exited on, and "floating wins" then needs no comparison logic
// at all.
function TSnakeGame.TopSnakeAt(ARow, ACol: Byte; AExclude: Integer): Integer;
	var
	k, j: Integer;

	begin
	Result:= -1;

	for k:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  (k <> AExclude) and PlaySnakes[k].Alive
		and PlaySnakes[k].Floating then
			for j:= 0 to PlaySnakes[k].Len - 1 do
				if  (PlaySnakes[k].Body[j].Row = ARow)
				and (PlaySnakes[k].Body[j].Col = ACol) then
					begin
					Result:= k;
					Exit;
					end;

	for k:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  (k <> AExclude) and PlaySnakes[k].Alive then
			for j:= 0 to PlaySnakes[k].Len - 1 do
				if  (PlaySnakes[k].Body[j].Row = ARow)
				and (PlaySnakes[k].Body[j].Col = ACol) then
					begin
					Result:= k;
					Exit;
					end;
	end;

// VacateCell - AExclude's segment is leaving this cell. Put back
// whatever was underneath it, or floor if there was nothing. Caller
// holds Lock.
//
// EVERY SNAKE CELL THAT EMPTIES MUST GO THROUGH HERE, and that is the
// half of the overlap problem that has nothing to do with rendering.
// Emitting floor unconditionally - which is what the tail step and
// KillPlayerSnake both used to do - erases a cell somebody else is still
// standing in. Their Body[] still holds it, so they carry on living and
// moving while their tiles read as bare floor, and since the collision
// test reads Board those cells become PASSABLE. That is the same
// desynchronisation the spawn sweep used to cause by deleting snakes
// outright, arriving from the other end.
//
// The same "only clear it if it is still yours" care that TickPlayFood
// and TickPlayBees already take over their own expiring cells - this is
// simply the version that can also restore what it finds.
procedure TSnakeGame.VacateCell(ARow, ACol: Byte; AExclude: Integer;
		var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
	var
	k, j: Integer;

	begin
	k:= TopSnakeAt(ARow, ACol, AExclude);

	if  k < 0 then
		begin
		EmitCell(ARow, ACol, TILE_FLOOR, ADeltas, ADeltaCount);
		Exit;
		end;

	// Somebody is still here. Repaint THEIR tile rather than clearing -
	// and from their own segment, so the pipe shape is the one that
	// belongs to that cell rather than a guess. Head included: a
	// floating snake's head can perfectly well be the thing underneath.
	j:= SnakeSegAt(k, ARow, ACol);

	if  j < 0 then
		begin
		// TopSnakeAt just said it was here, so this cannot happen -
		// but clearing is the safe answer if it ever does, rather than
		// indexing Body with -1.
		EmitCell(ARow, ACol, TILE_FLOOR, ADeltas, ADeltaCount);
		Exit;
		end;

	if  j = 0 then
		EmitCell(ARow, ACol, SnakeTile(PlaySnakes[k].Player,
				SNAKE_ROLE_HEAD, PlaySnakes[k].Body[0].Shape),
				ADeltas, ADeltaCount)
	else
		EmitCell(ARow, ACol, SnakeBodyTile(PlaySnakes[k].Player,
				PlaySnakes[k].Body[j].Shape, PlaySnakes[k].FlashOn),
				ADeltas, ADeltaCount);
	end;

// SpeedProgress - the progress figure the SPEED ladder runs on, as
// distinct from LevelProgress which everything else uses. Caller holds
// Lock.
//
// Seeded from the board's difficulty exactly as LevelProgress is, then
// stepped once per PLAY_SPEED_LEVELS_PER_STEP levels instead of once per
// level. On an easy board (Ord(gdEasy) = 1) at the default 8:
//
//   levels  1-8    progress 1    5 ticks/step   2.4 steps/sec
//   levels  9-16   progress 2    4              3.0
//   levels 17-24   progress 3    3              4.0
//   levels 25-32   progress 4    2              6.0
//   levels 33+     progress 5    1             12.0  (TOP, clamped)
//
// SO TOP SPEED IS NOW A LONG WAY OUT - about an hour of play at two
// minutes a level, where it used to arrive at level 5. That is the point
// of the change, but it IS a big swing, and PLAY_SPEED_LEVELS_PER_STEP
// is the one number to turn if it wants to be less of one.
function TSnakeGame.SpeedProgress: Integer;
	begin
	Result:= Ord(Difficulty)
			+ ((LevelNumber - 1) div PLAY_SPEED_LEVELS_PER_STEP);

	// The board's ceiling applies here too - a training board that
	// eventually reached top speed would not be a training board, it
	// would just be a slow start.
	if  Result > MaxProgress then
		Result:= MaxProgress;
	end;

// LevelStage / StageHasBees / StageHasLava / StageHasBoss - where this
// level sits in the eight-stage cycle and what it therefore runs. Caller
// holds Lock.
//
// LevelNumber starts at 1, so it is offset before the modulo. Kept as
// four tiny functions rather than read straight off the arrays at each
// site: the offset is the sort of thing that gets written correctly once
// and then off-by-one everywhere else.
function TSnakeGame.LevelStage: Integer;
	begin
	Result:= (LevelNumber - 1) mod PLAY_LEVEL_STAGES;

	// LevelNumber should never be below 1, but a negative modulo in
	// Pascal stays negative and would index off the front of the tables.
	if  Result < 0 then
		Result:= 0;
	end;

function TSnakeGame.StageHasBees: Boolean;
	begin
	Result:= PLAY_STAGE_BEES[LevelStage];
	end;

function TSnakeGame.StageHasLava: Boolean;
	begin
	Result:= PLAY_STAGE_LAVA[LevelStage];
	end;

function TSnakeGame.StageHasBoss: Boolean;
	begin
	Result:= PLAY_STAGE_BOSS[LevelStage];
	end;

// ResetLevelKeys - arm this level's key schedule. Caller holds Lock.
procedure TSnakeGame.ResetLevelKeys;
	begin
	LevelKeysLeft:= PLAY_STAGE_KEYS[LevelStage];

	if  LevelKeysLeft < 1 then
		begin
		LevelKeyWindow:= 0;
		LevelKeyTimer:= 0;

		Exit;
		end;

	LevelKeyWindow:= PLAY_LEVEL_TICKS div LevelKeysLeft;

	// First chance lands somewhere in the first window rather than at a
	// fixed offset, so a level does not always hand its key over at the
	// same moment.
	LevelKeyTimer:= 1 + Random(LevelKeyWindow);
	end;

// TickLevelKey - run the key schedule down and spend a chance when one
// falls due. Caller holds Lock.
//
// A CHANCE CAN BE WASTED, exactly like a food or bee spawn roll: the
// cell is picked at random and if it is not free the attempt is simply
// gone. That is what makes a busy board hand out fewer keys without any
// rule saying so, and it is the same bargain every other spawner here
// makes.
procedure TSnakeGame.TickLevelKey(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i, free, r, c: Integer;

	begin
	if  LevelKeysLeft < 1 then
		Exit;

	if  LevelKeyTimer > 0 then
		begin
		Dec(LevelKeyTimer);

		Exit;
		end;

	// This chance is now spent whatever happens below.
	Dec(LevelKeysLeft);

	if  LevelKeysLeft > 0 then
		LevelKeyTimer:= 1 + Random(LevelKeyWindow);

	// Never two at once - a second key while one is still on the board
	// would make the clock cut stack, and the point of a short TTL is
	// that the chance is the one in front of you.
	free:= -1;

	for i:= 0 to PLAY_FOOD_MAX - 1 do
		if  PlayFood[i].Active then
			begin
			if  PlayFood[i].Kind = FOOD_KIND_KEY then
				begin
				AddLogMessage(slkDebug,
						'Key attempt wasted - one already out');

				Exit;
				end;
			end
		else if free < 0 then
			free:= i;

	// A KEY DOES NOT LOSE ITS TURN TO A FULL TABLE. Evict whichever
	// ordinary food is closest to expiring - never another key, and
	// there cannot be one anyway by the test above.
	//
	// Food and bees can afford to throw an attempt away because they
	// roll EVERY TICK; a key gets two chances in a whole level, so the
	// same "wasted roll" bargain is not the same bargain at all. Both
	// wastage paths were measured doing real damage: on a two-level run
	// the second level produced no key whatsoever, one attempt lost to a
	// full table and the other to an occupied cell (2026-08-26).
	if  free < 0 then
		begin
		free:= 0;

		for i:= 1 to PLAY_FOOD_MAX - 1 do
			if  PlayFood[i].Ticks < PlayFood[free].Ticks then
				free:= i;

		// Only clear the cell if it is still showing that food - the
		// same care every other vacate here takes.
		if  Board[PlayFood[free].Row][PlayFood[free].Col]
				= TILE_FOOD_BASE + PlayFood[free].Kind then
			EmitCell(PlayFood[free].Row, PlayFood[free].Col, TILE_FLOOR,
					ADeltas, ADeltaCount);

		PlayFood[free].Active:= False;
		end;

	// AND IT GETS MORE THAN ONE LOOK FOR SOMEWHERE TO LAND. One random
	// cell on a board this busy is a coin toss, and losing a whole
	// level's key to it is not a difficulty, it is an absence.
	i:= PLAY_KEY_PLACE_TRIES;

	repeat
		r:= 1 + Random(BOARD_ROWS - 2);
		c:= 1 + Random(BOARD_COLS - 2);

		Dec(i);
	until (Board[r][c] = TILE_FLOOR) or (i <= 0);

	if  Board[r][c] <> TILE_FLOOR then
		begin
		// Genuinely nowhere to put it - the board really is that full.
		AddLogMessage(slkDebug, 'Key attempt wasted - no free cell in '
				+ IntToStr(PLAY_KEY_PLACE_TRIES) + ' tries');

		Exit;
		end;

	PlayFood[free].Row:= r;
	PlayFood[free].Col:= c;
	PlayFood[free].Kind:= FOOD_KIND_KEY;
	PlayFood[free].Ticks:= PLAY_KEY_TTL_MIN
			+ Random(PLAY_KEY_TTL_MAX - PLAY_KEY_TTL_MIN + 1);
	PlayFood[free].Active:= True;

	EmitCell(r, c, TILE_FOOD_BASE + FOOD_KIND_KEY, ADeltas, ADeltaCount);

	AddLogMessage(slkDebug, 'KEY spawned at ' + IntToStr(r) + ','
			+ IntToStr(c) + ' for ' + IntToStr(PlayFood[free].Ticks)
			+ ' ticks (' + IntToStr(LevelKeysLeft) + ' left this level)');
	end;

// PlayBeeMax - how many bees this board wants on it right now. Caller
// holds Lock.
//
// Clamped to the array. Bees are the hazard that answers "what stops a
// good player circulating forever", so this is the one thing that should
// keep rising as levels are cleared - but far more gently than the
// original, because these ones MOVE. See the PLAY_BEE_BASE comment.
function TSnakeGame.PlayBeeMax: Integer;
	begin
	// A lava stage has no swarm at all - the two hazards do not share a
	// level. Zero rather than a flag test at every call site, so existing
	// bees expire and none replace them, and every bee path goes quiet on
	// its own without needing to know about stages.
	if  not StageHasBees then
		begin
		Result:= 0;
		Exit;
		end;

	// HALVED AGAINST PROGRESS (dengland, 2026-08-26: "can we halve the
	// progress bees effect somehow?"), the same session the swarm was
	// given the ability to attack at all. The two go together: bees that
	// could only be run into needed numbers to be a threat, and bees
	// that strike do not - the same board is far more dangerous with
	// fewer of them on it.
	//
	// Halving the SLOPE rather than the base, so a gentle board is
	// barely touched and a hard one is where the difference lands:
	//
	//   training  4 -> 3     easy  6 -> 4     normal  8 -> 5
	//   hard     11 -> 6     expert  16 -> 9
	//
	// Anger and the last-30-seconds ramp still add on top of this, so
	// the swarm can still build well past these figures within a level;
	// what has changed is where it STARTS.
	Result:= PLAY_BEE_BASE
			+ ((LevelProgress * PLAY_BEE_PER_PROGRESS)
				div PLAY_BEE_PROGRESS_DIV);

	// Angered: every PLAY_BEE_ANGER_PER eaten on this level buys the
	// swarm one more. dengland's own mechanic - see the constant.
	Inc(Result, LevelBeesEaten div PLAY_BEE_ANGER_PER);

	if  LevelRamped then
		Inc(Result, PLAY_LEVEL_RAMP_BEES);

	if  Result > PLAY_BEE_CAP then
		Result:= PLAY_BEE_CAP;
	end;

// TickPlayBees - age, move and spawn the bees. Caller holds Lock.
//
// The MOVEMENT is TickDemoBees' chooser exactly, and deliberately so:
// the attract screen has been showing players how bees behave all along,
// so there should be one definition of that, not two that drift. The
// differences are only the ones real play needs - a TTL, spawning
// anywhere rather than in the demo's four corners, and no pen.
//
// THE PEN IS GONE. Demo bees are fenced inside the circuit because the
// demo has no collision and a bee on the track would simply be painted
// over. Here the spawn-clearance rule does that job instead, and the
// board's own wall border is the only boundary a bee needs - it cannot
// leave without failing the floor test first.
procedure TSnakeGame.TickPlayBees(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	b, k, best, dist, bestdist: Integer;
	toward, stall, pick, attempts, a: Integer;
	dr, dc, nr, nc, r, c: Integer;
	chasing: Boolean;

	// Chebyshev, the same measure the spawn clearance uses - a diagonal
	// counts as one step, which is what "5 cells away" means to somebody
	// looking at the board.
	function HeadDist(ARow, ACol, ASnake: Integer): Integer;
		var
		a, d: Integer;

		begin
		a:= Abs(ARow - Integer(PlaySnakes[ASnake].Body[0].Row));
		d:= Abs(ACol - Integer(PlaySnakes[ASnake].Body[0].Col));

		if  a > d then
			Result:= a
		else
			Result:= d;
		end;

	begin
	// --- weights ---
	//
	// dengland's 2:1:1 (toward : random : stall) is NORMAL, and both ends
	// scale from it:
	//
	//   training 2:1:3   easy 2:1:2   normal 2:1:1
	//   hard     3:1:1   expert 4:1:1
	//
	// STALL NEVER REACHES ZERO, and that is the load-bearing part. A pure
	// chaser moving at a fixed rate is solvable by geometry - a player
	// can work out exactly when it arrives. Stalls make arrival time
	// uncertain, which is the whole reason this hazard is not just
	// arithmetic. Do not tidy the stall away at expert.
	toward:= 2;
	if  LevelProgress > 2 then
		toward:= 2 + (LevelProgress - 2);

	stall:= 3 - LevelProgress;
	if  stall < 1 then
		stall:= 1;

	for b:= 0 to PLAY_BEE_CAP - 1 do
		begin
		if  not PlayBees[b].Active then
			Continue;

		// --- expiry ---
		Dec(PlayBees[b].Ticks);

		if  PlayBees[b].Ticks <= 0 then
			begin
			// Only wipe the cell if it is still OUR tile - see
			// TickPlayFood's expiry for why that check is not optional.
			if  Board[PlayBees[b].Row][PlayBees[b].Col] = TILE_BEE then
				EmitCell(PlayBees[b].Row, PlayBees[b].Col, TILE_FLOOR,
						ADeltas, ADeltaCount);

			PlayBees[b].Active:= False;

			Continue;
			end;

		// --- move opportunity ---
		//
		// On the BOARD'S step cadence, not every tick. That is what makes
		// the difficulty table work: a bee's real speed is P(act) x the
		// snake rate, so the margin between snake and bee narrows from
		// about 2x at training to 1.2x at expert without either ever
		// being given a fixed cells/sec figure. Bees stepping every tick
		// was worked through and rejected - even training bees would
		// outrun a normal snake.
		if  PlayBees[b].MoveTick > 0 then
			begin
			Dec(PlayBees[b].MoveTick);
			Continue;
			end;

		PlayBees[b].MoveTick:= BoardStepTicks - 1;

		// The target is kept for life - EXCEPT that a dead target has no
		// head to aim at. Re-picking then is a necessary deviation from
		// "assigned at spawn", not a quiet softening of it: with nobody
		// to chase, the bee would otherwise stall forever and become
		// scenery.
		if  (PlayBees[b].Target < 0)
		or  (PlayBees[b].Target > SNAKE_PLAYER_COUNT - 1)
		or  (not PlaySnakes[PlayBees[b].Target].Alive) then
			begin
			bestdist:= BOARD_COLS + BOARD_ROWS;
			best:= -1;

			for k:= 0 to SNAKE_PLAYER_COUNT - 1 do
				if  PlaySnakes[k].Alive then
					begin
					dist:= HeadDist(PlayBees[b].Row, PlayBees[b].Col, k);

					if  dist < bestdist then
						begin
						bestdist:= dist;
						best:= k;
						end;
					end;

			PlayBees[b].Target:= best;
			end;

		pick:= Random(toward + PLAY_BEE_WEIGHT_RANDOM + stall);

		dr:= 0;
		dc:= 0;

		// ONLY A DELIBERATE CHASE STEP CAN KILL - see the strike below.
		// dengland, 2026-08-26: "it should only be on the 2:1:1 move
		// toward the snake chance that they kill you I think, its a
		// little too often".
		//
		// A bee that blunders into a head on its RANDOM step has not
		// hunted anybody down, and dying to one reads as arbitrary
		// rather than as having been caught. Gating on the chase also
		// makes the threat scale with the same weights everything else
		// about the swarm scales with - at training the chase is 2 in 6
		// and at expert 4 in 6, so bees get more lethal on hard boards
		// without a single new number.
		chasing:= (pick < toward) and (PlayBees[b].Target >= 0);

		if  chasing then
			begin
			// Close the LARGER axis first. No pathfinding, by design: a
			// blocked move is simply a lost move for this bee this step,
			// with no fallback and no routing - which is what makes walls
			// genuine shelter rather than a brief detour.
			r:= PlaySnakes[PlayBees[b].Target].Body[0].Row;
			c:= PlaySnakes[PlayBees[b].Target].Body[0].Col;

			if  Abs(r - Integer(PlayBees[b].Row))
					> Abs(c - Integer(PlayBees[b].Col)) then
				begin
				if  r < PlayBees[b].Row then
					dr:= -1
				else if r > PlayBees[b].Row then
					dr:= 1;
				end
			else
				begin
				if  c < PlayBees[b].Col then
					dc:= -1
				else if c > PlayBees[b].Col then
					dc:= 1;
				end;
			end
		else if pick < (toward + PLAY_BEE_WEIGHT_RANDOM) then
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
			Continue;				// stalled, or already level

		nr:= Integer(PlayBees[b].Row) + dr;
		nc:= Integer(PlayBees[b].Col) + dc;

		// Floor, or A PLAYER'S HEAD - which it strikes.
		//
		// THE BEES COULD NOT ATTACK AT ALL until 2026-08-26. This test
		// was floor-only, and a snake is not floor, so a bee adjacent to
		// a head simply could not enter it: the swarm drifted toward
		// players and then waited to be run into. Every death by bee up
		// to now was the PLAYER driving into a stationary one. dengland
		// spotted the behaviour without seeing the cause - "bees don't
		// attack you enough. If they have an opportunity to kill you
		// they don't really take it."
		//
		// THE HEAD ONLY, deliberately. Letting a bee land anywhere on a
		// body would make length itself lethal - a long snake would be
		// a wall of targets it cannot see or protect - and would punish
		// the player for the one thing the game rewards. The head is
		// also the part the player is steering and can defend, so a
		// strike is something to be read and dodged rather than
		// something that arrives from behind.
		//
		// Everything else still refuses the bee exactly as before:
		// walls, lava, food, another bee, a body, a tail, and the boss.
		if  Board[nr][nc] <> TILE_FLOOR then
			begin
			// Not hunting - so this is a bee bumping into scenery, and
			// the scenery might happen to be a player. Refuse the move
			// and leave them alone. See the note on `chasing`.
			if  not chasing then
				Continue;

			// The MODELS answer this, not Board - a floating snake is
			// not really there and cannot be hurt, which the tile alone
			// cannot tell us. See TSnake.Floating.
			k:= SolidSnakeAt(nr, nc, -1);

			// Nothing killable there - or it is the BOSS, which is
			// immune to the swarm and is not a bee's business at all
			// (agreed with dengland when the stage cycle was designed).
			if  (k < 0) or (k >= SNAKE_PLAYER_COUNT) then
				Continue;

			if  SnakeSegAt(k, nr, nc) <> 0 then
				Continue;

			// CONTACT DESTROYS THE BEE EITHER WAY, shield or no shield -
			// the same rule the player's own side of this collision
			// already follows (see TickPlaySnakes), and the original's
			// too: it clears the tile unconditionally and only the
			// SCORING depends on being invulnerable.
			if  Board[PlayBees[b].Row][PlayBees[b].Col] = TILE_BEE then
				EmitCell(PlayBees[b].Row, PlayBees[b].Col, TILE_FLOOR,
						ADeltas, ADeltaCount);

			PlayBees[b].Active:= False;

			if  PlaySnakes[k].InvunTicks > 0 then
				begin
				// Shielded, so the bee threw itself away on somebody it
				// could not hurt. Scored as a kill for the same reason
				// the player's own swat is - and it angers the swarm,
				// which is what makes a heart food a hunting licence.
				AddScore(k, PLAY_BEE_PTS);
				SlotStatusToAll(k);
				Inc(LevelBeesEaten);
				end
			else
				KillPlayerSnake(k, ADeltas, ADeltaCount);

			Continue;
			end;

		// Only clear the cell being LEFT if it is still ours - the same
		// check this routine's own expiry makes a few dozen lines up, and
		// not optional for the same reason.
		//
		// A bee can end up underneath something without knowing it: a
		// spawning snake lays its body over whatever it lands on, and the
		// spawn sweep only clears a box around the HEAD, so a tail
		// segment can come down on a live bee (dengland spotted the gap
		// 2026-08-26). Clearing unconditionally then punched a
		// floor-coloured hole straight through that snake the moment the
		// bee stepped away - the board and the snake's Body[] disagreeing
		// again, which is the same failure the spawn sweep and the tail
		// vacate both had.
		//
		// The spawn now sweeps its whole body too, so this should no
		// longer be reachable. Kept because it costs one compare and
		// because "something else is on my cell" is a condition every
		// other mover here already has to allow for.
		if  Board[PlayBees[b].Row][PlayBees[b].Col] = TILE_BEE then
			EmitCell(PlayBees[b].Row, PlayBees[b].Col, TILE_FLOOR,
					ADeltas, ADeltaCount);

		PlayBees[b].Row:= nr;
		PlayBees[b].Col:= nc;

		EmitCell(nr, nc, TILE_BEE, ADeltas, ADeltaCount);
		end;

	// --- spawn ---
	//
	// ANGER MAKES THE SWARM ARRIVE IN BURSTS, not just in greater
	// numbers. Until now exactly one bee could appear per tick, on a
	// 1-in-PLAY_BEE_SPAWN_ODDS roll, and since the roll also throws the
	// attempt away when the chosen cell is not floor, the real rate is
	// well under that. Raising only the CEILING therefore made an angry
	// swarm arrive no faster - it just kept trickling in for longer,
	// which is not what "angry" should feel like (dengland, 2026-08-26).
	//
	// One extra attempt per anger tier. The tier is the same
	// LevelBeesEaten div PLAY_BEE_ANGER_PER that PlayBeeMax uses, so the
	// two move together by construction: every four bees killed buys both
	// one more bee on the board AND one more chance per tick of it
	// showing up promptly.
	//
	// Each attempt still rolls independently and still has to find a
	// legal cell, so this raises the rate without ever guaranteeing a
	// spawn - the swarm gets more insistent, not deterministic.
	attempts:= 1 + (LevelBeesEaten div PLAY_BEE_ANGER_PER);

	for a:= 1 to attempts do
		TrySpawnBee(ADeltas, ADeltaCount);
	end;

// TrySpawnBee - one attempt at putting a bee on the board. Caller holds
// Lock. Split out of TickPlayBees when anger gained the ability to make
// several attempts in a tick (see there) - it was a single fall-through
// tail before, which cannot be repeated.
procedure TSnakeGame.TrySpawnBee(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	b, k, best, dist, bestdist, live, free, r, c: Integer;

	function HeadDist(ARow, ACol, ASnake: Integer): Integer;
		var
		a, d: Integer;

		begin
		a:= Abs(ARow - Integer(PlaySnakes[ASnake].Body[0].Row));
		d:= Abs(ACol - Integer(PlaySnakes[ASnake].Body[0].Col));

		if  a > d then
			Result:= a
		else
			Result:= d;
		end;

	begin
	free:= -1;
	live:= 0;

	for b:= 0 to PLAY_BEE_CAP - 1 do
		if  PlayBees[b].Active then
			Inc(live)
		else if free < 0 then
			free:= b;

	if  free < 0 then
		Exit;

	if  live >= PlayBeeMax then
		Exit;

	if  Random(PLAY_BEE_SPAWN_ODDS) <> 0 then
		Exit;

	r:= 1 + Random(BOARD_ROWS - 2);
	c:= 1 + Random(BOARD_COLS - 2);

	if  Board[r][c] <> TILE_FLOOR then
		Exit;

	// Clear of EVERY live head, and the nearest one becomes the target -
	// so one scan does both jobs.
	bestdist:= BOARD_COLS + BOARD_ROWS;
	best:= -1;

	for k:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  PlaySnakes[k].Alive then
			begin
			dist:= HeadDist(r, c, k);

			if  dist < bestdist then
				begin
				bestdist:= dist;
				best:= k;
				end;
			end;

	// Nobody alive to be unfair to - and nobody to chase either.
	if  best < 0 then
		Exit;

	if  bestdist < PLAY_BEE_SPAWN_CLEAR then
		Exit;

	PlayBees[free].Row:= r;
	PlayBees[free].Col:= c;
	PlayBees[free].Target:= best;
	PlayBees[free].MoveTick:= BoardStepTicks;
	PlayBees[free].Ticks:= PLAY_BEE_TTL_MIN
			+ Random(PLAY_BEE_TTL_MAX - PLAY_BEE_TTL_MIN + 1);
	PlayBees[free].Active:= True;

	EmitCell(r, c, TILE_BEE, ADeltas, ADeltaCount);
	end;


// --- LAVA IN REAL PLAY (stages 4 and 7) ---------------------------------

// LavaTier - how bad the lava is on THIS stage: 1 for the cycle's first
// lava level, 2 for its second, 0 for a level that has none. Caller
// holds Lock.
//
// dengland asked for the first one to be less terrifying than the second
// (2026-08-26). It already scaled with difficulty and progress - both
// feed PlayLavaMaxCells - but progress rises by only three between
// stages 4 and 7, and on a board that has reached its MaxProgress
// ceiling it does not rise at all, so within one cycle the two lava
// levels were near enough identical. The tier is the explicit
// difference, on top of whatever the progress scaling is doing.
function TSnakeGame.LavaTier: Integer;
	begin
	Result:= PLAY_STAGE_LAVA_TIER[LevelStage];
	end;

// LavaPools - how many pools this stage seeds. The FIRST lever on the
// tier difference, and the more visible of the two: two pools leave
// obvious safe ground, three start closing the routes between them.
function TSnakeGame.LavaPools: Integer;
	begin
	Result:= LavaTier + 1;

	if  Result > PLAY_LAVA_SEEDS then
		Result:= PLAY_LAVA_SEEDS;
	end;

// PlayLavaMaxCells - how far ONE pool spreads on this board right now.
// Caller holds Lock. The play-side counterpart to LavaMaxCells, on its
// own numbers - see PLAY_LAVA_CELLS_BASE.
//
// The SECOND lever on the tier difference, and it pulls the OPPOSITE way
// to the first: stage 7 gets more pools, and each of them is smaller for
// it. See PLAY_LAVA_TIER_CELLS_LESS - the total still climbs, but the
// danger is scattered rather than piled up.
function TSnakeGame.PlayLavaMaxCells: Integer;
	begin
	Result:= PLAY_LAVA_CELLS_BASE
			+ (LevelProgress * PLAY_LAVA_CELLS_PER_PROGRESS);

	// BEFORE the cap, not after, and that ordering is doing real work:
	// applied afterwards, every board that clips to LAVA_CELLS_CAP would
	// come out at the same reduced figure and hard and expert would be
	// indistinguishable at tier 2 again.
	if  LavaTier > 1 then
		Dec(Result, (LavaTier - 1) * PLAY_LAVA_TIER_CELLS_LESS);

	if  Result > LAVA_CELLS_CAP then
		Result:= LAVA_CELLS_CAP;

	if  Result < PLAY_LAVA_CELLS_MIN then
		Result:= PLAY_LAVA_CELLS_MIN;
	end;

// ClearLavaAt - something else has taken this cell off the board, so the
// pool that owns it should stop believing it is still theirs. Caller
// holds Lock.
//
// The lava counterpart to ClearFoodAt and ClearBeeAt, and it exists for
// the same reason they do: the spawn sweep clears a box around an
// arriving snake, and a hazard swept up that way has to be struck off
// its table too or the model and the board quietly disagree.
//
// PARKED ON (0, 0) RATHER THAN REMOVED. Cell order in a pool is not
// bookkeeping, it IS the colour tier and the recession order (see
// TLavaPool), so shifting the array to close a gap would repaint nothing
// but would change what recedes next and in what shade. (0, 0) is the
// board's top-left BORDER WALL and can therefore never hold lava, so
// LavaRecedeOnce's "is this cell still ours" test skips the parked entry
// without needing to know parking exists.
procedure TSnakeGame.ClearLavaAt(ARow, ACol: Byte);
	var
	b, i: Integer;

	begin
	for b:= 0 to PLAY_LAVA_SEEDS - 1 do
		for i:= 0 to PlayLava[b].Count - 1 do
			if  (PlayLava[b].Cells[i].Row = ARow)
			and (PlayLava[b].Cells[i].Col = ACol) then
				begin
				PlayLava[b].Cells[i].Row:= 0;
				PlayLava[b].Cells[i].Col:= 0;

				Exit;
				end;
	end;

// ResetPlayLava - forget every pool and arm the phase machine for a new
// level. Caller holds Lock.
//
// Emits nothing, and deliberately so: every caller
// (StartPlay/NextLevel/StopPlay) has just rebuilt the whole board and is
// about to push it, so there are no stale lava tiles left to clear -
// only stale MODEL state, which is all this touches.
//
// Armed into lpIdle with the opening gap already running, so a lava
// level starts on clear board and the pools arrive as an event rather
// than blooming under everyone at the whistle.
procedure TSnakeGame.ResetPlayLava;
	var
	b: Integer;

	begin
	for b:= 0 to PLAY_LAVA_SEEDS - 1 do
		PlayLava[b].Count:= 0;

	PlayLavaPhase:= lpIdle;
	PlayLavaStep:= 0;
	PlayLavaHold:= PLAY_LAVA_GAP_TICKS;
	PlayLavaShook:= False;
	end;

// TickPlayLava - grow, hold, recede. ONCE. Caller holds Lock, and only
// calls this on a stage that has lava.
//
// dengland chose growing-and-receding over a board that steadily closes
// in (2026-08-26). The difference matters more than it sounds: pools
// that never recede mean a bad seed can wall a player into a shrinking
// pocket with no counterplay at all, whereas a cycle makes the dangerous
// ground MOVE - you are never safe standing still, but you are never
// doomed by where the level happened to put you either.
//
// REPEATED BURSTS, ONE AT A TIME, WITH A PAUSE BETWEEN (dengland,
// 2026-08-26: "there should be repeated bursts of lava but only one at a
// time... there should be a pause between them"). The phase machine IS
// that rule rather than something that implements it - a single set of
// pools can only be in one phase at once, so "only one at a time" is
// structural and nothing has to arbitrate between bursts, and lpIdle is
// the pause. Each burst re-seeds somewhere new, so the safe ground moves
// from one to the next.
//
// THE PACING CONSTANTS ARE THEREFORE THE WHOLE FEEL OF THE STAGE, and
// they are set to make the burst an EVENT that occupies most of the
// middle of the level rather than a fifteen-second squall in a
// two-minute empty room - which is what a fast cycle would leave,
// because a lava stage has no bees either. Roughly: ten seconds of clear
// board, half a minute of creeping growth, twenty seconds at full
// extent, half a minute draining. Every one of those is a named
// constant and none of it is load-bearing on anything else.
//
// LAVA IS LETHAL WITHOUT A LINE OF CODE HERE SAYING SO. It is simply not
// floor, and TickPlaySnakes' collision test is "anything that is not
// bare floor or food stops the snake dead" - so an unshielded head that
// enters it dies, and a shielded one is stopped where it stands rather
// than passing through, exactly as with a wall. That is also why the
// shield question needed no decision: the answer was already written.
procedure TSnakeGame.TickPlayLava(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	b, i, n, tries, grown, seeded, pools: Integer;
	r, c, maxcells: Integer;
	full, ok: Boolean;
	heads: TLavaHeads;
	msg: AnsiString;

	begin
	// On a STEP, not on every tick - the pools would otherwise reach
	// full extent in well under a second.
	if  PlayLavaStep > 0 then
		begin
		Dec(PlayLavaStep);
		Exit;
		end;

	PlayLavaStep:= PLAY_LAVA_STEP_TICKS - 1;

	maxcells:= PlayLavaMaxCells;
	pools:= LavaPools;

	PlayLavaHeads(heads);

	case PlayLavaPhase of
	lpIdle:
		begin
		// The clear opening, and the pause between bursts. Counted down
		// in STEPS, so it is decremented by the step interval rather
		// than by one.
		if  PlayLavaHold > 0 then
			begin
			Dec(PlayLavaHold, PLAY_LAVA_STEP_TICKS);

			// THE WARNING SHAKE, cued just before the pools break
			// through so the ground moves and THEN the lava arrives -
			// see PLAY_LAVA_SHAKE_LEAD_MS. In play this is not
			// decoration: it is the only notice a burst is coming.
			if  (not PlayLavaShook)
			and (PlayLavaHold <= PLAY_LAVA_SHAKE_LEAD_TICKS) then
				begin
				DemoShakePending:= PLAY_LAVA_SHAKE_FRAMES;
				PlayLavaShook:= True;
				end;

			Exit;
			end;

		// SCATTERED, not placed. The reel puts its pools at fixed points
		// inside its circuit because it is a display; here they land
		// anywhere legal, so no two lava levels play the same and the
		// stage cannot be learned by rote.
		seeded:= 0;

		for b:= 0 to pools - 1 do
			begin
			PlayLava[b].Count:= 0;

			for tries:= 1 to PLAY_LAVA_SEED_TRIES do
				begin
				r:= PLAY_LAVA_SEED_INSET
						+ Random(BOARD_ROWS - 2 * PLAY_LAVA_SEED_INSET);
				c:= PLAY_LAVA_SEED_INSET
						+ Random(BOARD_COLS - 2 * PLAY_LAVA_SEED_INSET);

				// Clear of every live head, the same rule growth is held
				// to - a pool that SEEDS on top of somebody is worse
				// than one that grows into them, because there was no
				// warning at all.
				ok:= True;

				for i:= 0 to heads.Count - 1 do
					if  (Abs(r - heads.Row[i]) <= PLAY_LAVA_HEAD_CLEAR)
					and (Abs(c - heads.Col[i]) <= PLAY_LAVA_HEAD_CLEAR) then
						begin
						ok:= False;
						Break;
						end;

				if  not ok then
					Continue;

				// AND CLEAR OF THE POOLS ALREADY SEEDED THIS CYCLE.
				//
				// Purely random seeds land close together far more often
				// than intuition says - with three pools scattered over
				// a 14x24 usable area, two of them being neighbours is
				// the common case, not the unlucky one, and two pools
				// that merge are one big pool that happens to have cost
				// twice the budget. dengland spotted it from the
				// spectator seat inside a couple of minutes.
				//
				// THE SEPARATION IS RELAXED FOR THE LAST THIRD OF THE
				// ATTEMPTS. A hard requirement would mean a crowded
				// board simply loses pools, which is a worse failure
				// than a close pair - so this is a strong preference,
				// not a rule, and it degrades rather than failing.
				if  tries <= (PLAY_LAVA_SEED_TRIES * 2) div 3 then
					begin
					for i:= 0 to b - 1 do
						if  (PlayLava[i].Count > 0)
						and (Abs(r - Integer(PlayLava[i].Cells[0].Row))
								<= PLAY_LAVA_SEED_APART)
						and (Abs(c - Integer(PlayLava[i].Cells[0].Col))
								<= PLAY_LAVA_SEED_APART) then
							begin
							ok:= False;
							Break;
							end;

					if  not ok then
						Continue;
					end;

				LavaSeedPool(PlayLava[b], r, c, maxcells,
						ADeltas, ADeltaCount);

				// LavaSeedPool refuses anything but bare floor, so a
				// count of zero means that spot was taken and this
				// attempt simply did not land.
				if  PlayLava[b].Count > 0 then
					begin
					Inc(seeded);

					Break;
					end;
				end;
			end;

		// Not one pool found anywhere to start - a crowded board, and
		// nothing worth logging. Wait out another gap and try again
		// rather than spinning on it every step.
		if  seeded = 0 then
			begin
			PlayLavaHold:= PLAY_LAVA_GAP_TICKS;
			PlayLavaShook:= False;

			Exit;
			end;

		// The POSITIONS are in the log, not just the count - a cycle's
		// pools landing on top of one another is invisible in a count
		// and obvious in a list of coordinates.
		msg:= '';

		for b:= 0 to pools - 1 do
			if  PlayLava[b].Count > 0 then
				msg:= msg + ' (' + IntToStr(PlayLava[b].Cells[0].Row)
						+ ',' + IntToStr(PlayLava[b].Cells[0].Col) + ')';

		AddLogMessage(slkDebug, 'Lava: seeded ' + IntToStr(seeded) + '/'
				+ IntToStr(pools) + ' pools, tier ' + IntToStr(LavaTier)
				+ ', max ' + IntToStr(maxcells) + ' cells each, at' + msg);

		PlayLavaPhase:= lpGrow;
		end;

	lpGrow:
		begin
		full:= True;

		for b:= 0 to pools - 1 do
			begin
			// A pool that never seeded has nothing to grow and must not
			// hold the phase open waiting for it.
			if  PlayLava[b].Count < 1 then
				Continue;

			grown:= 0;
			tries:= 0;

			// Bounded retries, not "keep going until it fits": a pool
			// hemmed in on all sides would otherwise spin here forever.
			while (grown < PLAY_LAVA_PER_STEP)
			and (tries < PLAY_LAVA_PER_STEP * 8) do
				begin
				// The whole playable interior, not a fenced circuit -
				// the border wall is the only edge real play's lava
				// needs, and the head clearance is what keeps it fair
				// rather than a pen.
				if  LavaGrowOnce(PlayLava[b], 0, 0, BOARD_ROWS - 1,
						BOARD_COLS - 1, maxcells, PLAY_LAVA_HEAD_CLEAR,
						heads, ADeltas, ADeltaCount) then
					Inc(grown);

				Inc(tries);
				end;

			if  PlayLava[b].Count < maxcells then
				full:= False;
			end;

		// Note this can also finish because every pool is WEDGED rather
		// than full - the bounded retries above give up, nothing grows,
		// and the pools sit at whatever extent they reached. The hold
		// then runs normally and the cycle carries on, which is the
		// behaviour wanted: a small pool is not a stuck level.
		if  full then
			begin
			n:= 0;

			for b:= 0 to PLAY_LAVA_SEEDS - 1 do
				Inc(n, PlayLava[b].Count);

			AddLogMessage(slkDebug, 'Lava: at full extent, '
					+ IntToStr(n) + ' cells');

			PlayLavaPhase:= lpHold;
			PlayLavaHold:= PLAY_LAVA_HOLD_TICKS;
			end;
		end;

	lpHold:
		begin
		Dec(PlayLavaHold, PLAY_LAVA_STEP_TICKS);

		if  PlayLavaHold <= 0 then
			PlayLavaPhase:= lpRecede;
		end;

	lpRecede:
		begin
		n:= 0;

		// Every pool, not just the ones this stage seeded - the tier can
		// have changed since (a level ended mid-burst and the next one
		// seeds fewer), and a pool nobody drains would be left painted
		// on the board with no model owning it.
		for b:= 0 to PLAY_LAVA_SEEDS - 1 do
			for i:= 1 to PLAY_LAVA_PER_STEP do
				if  LavaRecedeOnce(PlayLava[b], ADeltas, ADeltaCount) then
					Inc(n);

		if  n = 0 then
			begin
			AddLogMessage(slkDebug, 'Lava: drained, pausing');

			// ROUND AGAIN, after a pause. One burst on the board at a
			// time, never two overlapping, and a clear gap between them
			// (dengland, 2026-08-26: "there should be repeated bursts of
			// lava but only one at a time... there should be a pause
			// between them").
			//
			// The phase machine gives this for nothing - a single pool
			// set that can only be in one phase at once IS "only one at
			// a time", and lpIdle IS the pause. Nothing here has to
			// arbitrate between bursts because there is only ever one.
			PlayLavaPhase:= lpIdle;
			PlayLavaHold:= PLAY_LAVA_GAP_TICKS;
			PlayLavaShook:= False;
			end;
		end;
		end;
	end;

// --- THE BOSS (stage 8) -------------------------------------------------

// BossOnBoard - is the boss up and simulating? Caller holds Lock.
//
// NOT the same question as StageHasBoss, which only describes the LEVEL.
// The gap between them is the whole victory beat: once the boss is dead
// the stage still has a boss, but the board no longer does, and that is
// precisely what releases the frozen clock. See KillBoss.
function TSnakeGame.BossOnBoard: Boolean;
	begin
	Result:= StageHasBoss and PlaySnakes[SNAKE_SLOT_BOSS].Alive;
	end;

// SpawnBoss - lay the boss down at the centre with the level. Caller
// holds Lock.
//
// dengland's own choice of timing (2026-08-26): "there from the start
// for the time being but maybe idle for a while and unkillable - that
// way we don't have spawn in issues and floating to account for". It is
// built WITH the level, onto a board that has just been rebuilt and has
// nothing on it yet, so there is no sweep to run, nothing to overlap and
// no Floating state to reason about. The corner spawns that follow are
// the length of the board away.
//
// THE DORMANCY IS SPENT AS INVULNERABILITY rather than as a separate
// "cannot be hurt" flag, which gets three things for one: it cannot be
// damaged, it visibly FLASHES while it sleeps so the tell costs nothing,
// and waking needs no code at all because the flash simply stops.
procedure TSnakeGame.SpawnBoss(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	const
	// The body from the HEAD BACKWARDS, each entry the direction to step
	// to reach the next segment back. A SERPENTINE rather than a line so
	// all twelve segments fit the 4x4 patch BuildLevel guarantees clear
	// at the centre - see PLAY_BOSS_LEN. Three rows of four, boustrophedon:
	//
	//     <- <- <- H      row r0
	//     -> -> -> v      row r0 + 1
	//     <- <- <- ^      row r0 + 2
	//
	// The fourth row of the box is left spare, so this can lengthen
	// again by four before the layout has to be rethought.
	BOSS_LAYOUT: array[0..PLAY_BOSS_LEN - 2] of TSnakeDir =
			(sdLeft, sdLeft, sdLeft,
			 sdDown,
			 sdRight, sdRight, sdRight,
			 sdDown,
			 sdLeft, sdLeft, sdLeft);

	var
	i, r0, c0: Integer;
	cr, cc: Byte;
	dirIn, dirOut: TSnakeDir;

	begin
	// The top-left of the guaranteed-clear centre patch, which is what
	// BuildLevel sweeps - see LEVEL_CENTRE_CLEAR. Derived rather than
	// written out, so moving the guarantee moves the boss with it.
	r0:= (BOARD_ROWS div 2) - LEVEL_CENTRE_CLEAR;
	c0:= (BOARD_COLS div 2) - LEVEL_CENTRE_CLEAR;

	with PlaySnakes[SNAKE_SLOT_BOSS] do
		begin
		Len:= PLAY_BOSS_LEN;
		Player:= SNAKE_SLOT_BOSS;
		Alive:= True;

		// NEVER FLOATING. It is laid on an empty board and nothing can
		// spawn under it afterwards - a player arriving on top of it
		// floats instead, which is the arriving snake's problem to solve
		// and is already handled (SpawnPlayerSnake).
		Floating:= False;

		// The boss eats nothing and grows never, so the food effects are
		// dead weight on it - zeroed anyway, because the growth test and
		// PlayStepTicks are shared code that must not read rubbish if
		// either is ever pointed at this slot.
		MoveFast:= 0;
		Grow:= False;
		GrowNone:= 0;
		GrowEx:= 0;

		// Dormant, unkillable, and flashing to say so.
		BossWake:= PLAY_BOSS_WAKE_TICKS;
		InvunTicks:= PLAY_BOSS_WAKE_TICKS;
		FlashOn:= True;

		MoveTick:= BoardStepTicks;

		// Head at the patch's top right, body hooking back and down.
		cr:= r0;
		cc:= c0 + (2 * LEVEL_CENTRE_CLEAR) - 1;

		for i:= 0 to Len - 1 do
			begin
			Body[i].Row:= cr;
			Body[i].Col:= cc;

			// dirIn is the way the snake ARRIVED at this cell, dirOut
			// the way it left. BOSS_LAYOUT[i] points from segment i back
			// to segment i+1, so both are its reverse - which is the
			// whole reason the layout is written head-first.
			if  i < Len - 1 then
				dirIn:= OppositeDir(BOSS_LAYOUT[i])
			else
				// The tail has nothing behind it; carry the direction it
				// leaves on, so it renders straight rather than bent.
				dirIn:= OppositeDir(BOSS_LAYOUT[i - 1]);

			if  i > 0 then
				dirOut:= OppositeDir(BOSS_LAYOUT[i - 1])
			else
				dirOut:= dirIn;			// the head goes straight on

			Body[i].Shape:= SegShape(dirIn, dirOut);

			if  i = 0 then
				begin
				Dir:= dirIn;
				Look:= dirOut;
				end;

			if  i < Len - 1 then
				StepCell(cr, cc, BOSS_LAYOUT[i]);
			end;

		EmitCell(Body[0].Row, Body[0].Col,
				SnakeTile(Player, SNAKE_ROLE_HEAD, Body[0].Shape),
				ADeltas, ADeltaCount);

		for i:= 1 to Len - 1 do
			EmitCell(Body[i].Row, Body[i].Col,
					SnakeBodyTile(Player, Body[i].Shape, FlashOn),
					ADeltas, ADeltaCount);
		end;

	BossLives:= PLAY_START_LIVES;
	BossGrow:= 0;

	AddLogMessage(slkInfo, 'Boss stage: level ' + IntToStr(LevelNumber)
			+ ', ' + IntToStr(BossLives) + ' lives, waking in '
			+ IntToStr((PLAY_BOSS_WAKE_TICKS * TICK_MS) div 1000) + 's');
	end;

// ClearBoss - take the boss off the board without any of the ceremony.
// Caller holds Lock.
//
// Deliberately NOT KillPlayerSnake: that spends a LIFE, queues a
// respawn and can release a SLOT, and the boss has none of those things
// - it is not a player and must never be handed one. The vacate loop is
// the only part the two share, and it is shared for the reason
// VacateCell exists at all: something may still be standing in these
// cells.
procedure TSnakeGame.ClearBoss(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i: Integer;

	begin
	if  not PlaySnakes[SNAKE_SLOT_BOSS].Alive then
		Exit;

	// Down FIRST, so the vacates below do not find the boss still
	// standing in its own cells and dutifully repaint the corpse they
	// are trying to clear - the same ordering KillPlayerSnake needs.
	PlaySnakes[SNAKE_SLOT_BOSS].Alive:= False;
	PlaySnakes[SNAKE_SLOT_BOSS].Floating:= False;

	for i:= 0 to PlaySnakes[SNAKE_SLOT_BOSS].Len - 1 do
		with PlaySnakes[SNAKE_SLOT_BOSS].Body[i] do
			VacateCell(Row, Col, SNAKE_SLOT_BOSS, ADeltas, ADeltaCount);
	end;

// KillBoss - the last life is gone. Caller holds Lock.
procedure TSnakeGame.KillBoss(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	begin
	ClearBoss(ADeltas, ADeltaCount);

	DemoShakePending:= PLAY_BOSS_KILL_SHAKE;

	// THE LEVEL IS CLEARED, and this one assignment is how it ends.
	//
	// A boss level's clock is FROZEN while the boss lives (see Tick), so
	// nothing has been counting down. Killing it releases the freeze -
	// BossOnBoard went false the moment Alive did - and starts a short
	// victory beat, after which the ordinary "LevelTicks <= 0 ->
	// NextLevel" path fires with no special case anywhere.
	//
	// Setting it to zero instead would work and would be worse: the
	// rebuild would land in the SAME tick as the kill, throwing away the
	// shake and the final score message along with every other delta
	// gathered this tick, and the boss would blink out in the very frame
	// the next level appeared.
	LevelTicks:= PLAY_BOSS_CLEAR_TICKS;

	AddLogMessage(slkInfo, 'Boss killed on level ' + IntToStr(LevelNumber));
	end;

// HitBoss - a player has met the boss HEAD ON. Caller holds Lock.
//
// The head-on itself - neither party moving, both coming away shielded -
// is applied by the CALLER, because either side of the exchange can be
// the one that detects it and each has its own idea of what "did not
// move" means. All this does is the damage, which is the one thing the
// ordinary head-on rule does not already cover.
//
// It is therefore correct, and important, that this can decline: a boss
// that is dormant or already reeling takes nothing, but the draw still
// happens and the player still comes away shielded. "Unkillable" during
// the opening spell is exactly this returning early.
procedure TSnakeGame.HitBoss(ASlot: Integer;
		var ADeltas: array of TTileDelta; var ADeltaCount: Integer);
	var
	i: Integer;

	begin
	if  not PlaySnakes[SNAKE_SLOT_BOSS].Alive then
		Exit;

	// Dormant (BossWake) or reeling from the last hit - both are held as
	// invulnerability, so one test covers them and there is no way for
	// the two to disagree.
	if  PlaySnakes[SNAKE_SLOT_BOSS].InvunTicks > 0 then
		Exit;

	if  BossLives > 0 then
		Dec(BossLives);

	AddScore(ASlot, PLAY_BOSS_HIT_PTS);

	if  BossLives <= 0 then
		begin
		// The kill bonus goes to whoever landed the last hit, on top of
		// that hit's own points.
		AddScore(ASlot, PLAY_BOSS_KILL_PTS);
		SlotStatusToAll(ASlot);

		KillBoss(ADeltas, ADeltaCount);

		// The status line reads its life pips off BossLives, and the
		// level clock has just been released - both have changed.
		GameStatusToAll;

		Exit;
		end;

	SlotStatusToAll(ASlot);

	PlaySnakes[SNAKE_SLOT_BOSS].InvunTicks:= PLAY_BOSS_HIT_INVUN_TICKS;

	if  not PlaySnakes[SNAKE_SLOT_BOSS].FlashOn then
		begin
		PlaySnakes[SNAKE_SLOT_BOSS].FlashOn:= True;

		for i:= 1 to PlaySnakes[SNAKE_SLOT_BOSS].Len - 1 do
			with PlaySnakes[SNAKE_SLOT_BOSS].Body[i] do
				EmitCell(Row, Col,
						SnakeBodyTile(PlaySnakes[SNAKE_SLOT_BOSS].Player,
							Shape, True),
						ADeltas, ADeltaCount);
		end;

	DemoShakePending:= PLAY_BOSS_HIT_SHAKE;

	// The boss's remaining lives ARE the status line on this stage -
	// there is no clock ticking to carry the change out on its own.
	GameStatusToAll;
	end;

// TickBoss - the boss's entire simulation. Caller holds Lock.
//
// Separate from TickPlaySnakes rather than folded into it, even though
// the boss lives in the same array. That routine's shape is a PRE-PASS
// that resolves head-ons between equals before anybody moves, and the
// boss is not an equal: it has no player, no lives on a slot, no
// respawn, no input and no food effects, and its collisions resolve
// differently in every single case. Running after the players also means
// it chases where they ARE rather than where they were.
//
// The chooser is TickPlayBees' weighted one - toward the nearest head,
// or a random step, or a stall - on the boss's own weights. That is not
// laziness: the behaviour is already play-tested, already tuned by
// numbers that exist, and already familiar to anyone who has watched the
// attract screen. What differs is that the boss has a BODY, so it must
// move as a snake and cannot walk into itself, and that a blocked boss
// takes the next legal direction where a blocked bee simply loses its
// move.
procedure TSnakeGame.TickBoss(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	type
	// What stepping onto a candidate cell would mean. There is no "and
	// the player dies" case: the boss bounces off players rather than
	// eating them, and you die by running into IT - see Verdict.
	TBossStep = (bsBlocked, bsMove, bsDraw);

	var
	i, j, k, f, pick, best, dist, bestdist, steps: Integer;
	dr, dc, nr, nc, r, c, pass: Integer;
	grabbed, fed: Boolean;
	head: TSnakeSeg;
	prevDir, want, cand: TSnakeDir;
	stepKind, chosen: TBossStep;
	victim, chosenVictim: Integer;
	wantFlash, repaint: Boolean;

	// Chebyshev, as everywhere else here - a diagonal counts as one
	// step, which is what "three cells away" means to somebody looking
	// at the board.
	function HeadDist(ARow, ACol, ASnake: Integer): Integer;
		var
		a, d: Integer;

		begin
		a:= Abs(ARow - Integer(PlaySnakes[ASnake].Body[0].Row));
		d:= Abs(ACol - Integer(PlaySnakes[ASnake].Body[0].Col));

		if  a > d then
			Result:= a
		else
			Result:= d;
		end;

	procedure RepaintBoss;
		var
		n: Integer;

		begin
		for n:= 1 to PlaySnakes[SNAKE_SLOT_BOSS].Len - 1 do
			with PlaySnakes[SNAKE_SLOT_BOSS].Body[n] do
				EmitCell(Row, Col,
						SnakeBodyTile(PlaySnakes[SNAKE_SLOT_BOSS].Player,
							Shape, PlaySnakes[SNAKE_SLOT_BOSS].FlashOn),
						ADeltas, ADeltaCount);
		end;

	// What would happen if the boss stepped to (ANr, ANc)? Sets AVictim
	// to the player involved for bsDraw and bsKill, -1 otherwise.
	//
	// PURE - it decides, it does not act. Candidates that lose must
	// leave no trace, so clearing the bee or the food that was in the
	// winning cell is the caller's job once the cell is definitely being
	// entered.
	function Verdict(ANr, ANc: Integer; out AVictim: Integer): TBossStep;
		var
		s, seg: Integer;
		tile: Byte;

		begin
		AVictim:= -1;
		Result:= bsBlocked;

		if  (ANr <= 0) or (ANr >= BOARD_ROWS - 1)
		or  (ANc <= 0) or (ANc >= BOARD_COLS - 1) then
			Exit;

		// ITSELF, and this has to be settled COMPLETELY here - deciding
		// it and then falling through to the board test below does not
		// work, because the board reads "snake tile" for every one of
		// these cells and would block them all over again.
		//
		// That was a real bug and dengland walked straight into it: the
		// boss could never follow its own tail, so a long one boxed
		// itself in with the tail it was chasing ("the boss is actually
		// stuck again but with only the front covered in by the tail").
		// The floating escape did not help either, for exactly the same
		// reason - the board still said snake.
		seg:= SnakeSegAt(SNAKE_SLOT_BOSS, ANr, ANc);

		if  seg >= 0 then
			begin
			// FLOATING - its own body is not in its way at all. That is
			// what floating means, and it is the escape from having
			// coiled itself into a knot. See the resolve pass below.
			if  PlaySnakes[SNAKE_SLOT_BOSS].Floating then
				begin
				Result:= bsMove;

				Exit;
				end;

			// THE TAIL IS EXEMPT WHEN IT IS ABOUT TO VACATE, exactly as
			// it is for a player: the cell is still painted but empties
			// in this same step, so following itself round a tight
			// corner is legal - and it takes more skill than a loose
			// turn, so blocking it punishes the wrong thing.
			//
			// NOT exempt when the boss is about to grow, because then
			// the tail stays where it is. Same rule the player step
			// applies, and the same honest price.
			//
			// The "about to grow" test is spelled the same way the move
			// code spells it, cap included - a boss owed segments it can
			// never be paid still vacates its tail, and would otherwise
			// refuse a turn that is perfectly legal.
			if  (seg = PlaySnakes[SNAKE_SLOT_BOSS].Len - 1)
			and not ((BossGrow > 0)
				and (PlaySnakes[SNAKE_SLOT_BOSS].Len < PLAY_BOSS_LEN_MAX)) then
				begin
				Result:= bsMove;

				Exit;
				end;

			Exit;					// blocked by its own body
			end;

		// ANOTHER SNAKE - and the MODELS answer this, not Board, for the
		// same Z-order reason everything else here asks them. A FLOATING
		// snake is not really there: it cannot be hurt and cannot block,
		// so the boss walks through it and neither is any the wiser.
		s:= SolidSnakeAt(ANr, ANc, SNAKE_SLOT_BOSS);

		if  s >= 0 then
			begin
			AVictim:= s;

			// THE BOSS RUNNING INTO A PLAYER IS ALWAYS A DRAW, and
			// crucially it NEVER damages the boss - dengland's rule in
			// as many words: "the boss should not die if it runs into a
			// player but the same both players run into each other logic
			// for snakes should apply (becomming invunerable in that
			// case)".
			//
			// THE FIRST BUILD GOT THIS WRONG and the first test run
			// caught it: counting "the boss stepped onto a head" as a
			// mutual collision made the boss SUICIDAL, because homing on
			// heads is the whole chase. It spent all three lives in
			// nineteen seconds against a bot that never once tried to
			// attack it. A hazard that kills itself by doing its job is
			// not a boss.
			//
			// The damage therefore lives ENTIRELY on the player's side
			// of the exchange (see TickPlaySnakes), and that division is
			// exact rather than approximate: PLAYERS MOVE FIRST each
			// tick, so a player driving into the boss is always resolved
			// on the player's own pass, and by the time the boss moves,
			// the only players it can still meet are ones that did not
			// move into it. Nothing is lost by refusing damage here.
			//
			// ANY SEGMENT, not just the head. A player's body is a wall
			// to the boss exactly as it is to another player, and
			// bouncing off it costs the boss its step - which is most of
			// what makes cutting the boss off with your own tail a real
			// tactic instead of a suicidal one.
			Result:= bsDraw;

			Exit;
			end;

		tile:= Board[ANr][ANc];

		if  tile = TILE_FLOOR then
			begin
			Result:= bsMove;

			Exit;
			end;

		// BEES AND FOOD ARE SIMPLY DESTROYED. The boss is immune to the
		// swarm and always kills it (agreed with dengland when the stage
		// cycle was designed), and food it walks over is gone - it eats
		// nothing, scores nothing and never grows.
		if  tile = TILE_BEE then
			begin
			Result:= bsMove;

			Exit;
			end;

		if  (tile >= TILE_FOOD_BASE)
		and (tile < TILE_FOOD_BASE + FOOD_TYPE_COUNT) then
			Result:= bsMove;

		// Anything else - wall, lava, a snake tile the models disowned -
		// stays bsBlocked. Lava should be unreachable here, since the
		// stage table never puts the two on one level, and it is left to
		// fall through rather than being named so that it stays blocked
		// if that ever changes.
		end;

	begin
	if  not PlaySnakes[SNAKE_SLOT_BOSS].Alive then
		Exit;

	// --- flash, dormancy and pacing ---
	//
	// All three run on the TICK, not the step, for the same reason a
	// player's invulnerability does: they have to keep running on ticks
	// where the boss is standing still between moves.
	if  PlaySnakes[SNAKE_SLOT_BOSS].InvunTicks > 0 then
		Dec(PlaySnakes[SNAKE_SLOT_BOSS].InvunTicks);

	if  BossWake > 0 then
		Dec(BossWake);

	wantFlash:= InvunFlashOn(PlaySnakes[SNAKE_SLOT_BOSS].InvunTicks);

	repaint:= wantFlash <> PlaySnakes[SNAKE_SLOT_BOSS].FlashOn;
	PlaySnakes[SNAKE_SLOT_BOSS].FlashOn:= wantFlash;

	// DORMANT. It sits still and flashes until BossWake runs out - which
	// is also exactly how long it cannot be hurt for, the two having
	// been set from the same constant.
	if  BossWake > 0 then
		begin
		if  repaint then
			RepaintBoss;

		Exit;
		end;

	if  PlaySnakes[SNAKE_SLOT_BOSS].MoveTick > 0 then
		begin
		Dec(PlaySnakes[SNAKE_SLOT_BOSS].MoveTick);

		if  repaint then
			RepaintBoss;

		Exit;
		end;

	// ONE GEAR QUICKER THAN THE BOARD - see PLAY_BOSS_GEAR_BONUS. The
	// clamp is the same floor SnakeStepTicks holds every other mover to:
	// a step every zero ticks is not a speed.
	steps:= BoardStepTicks - PLAY_BOSS_GEAR_BONUS;

	if  steps < SNAKE_SPEED_TOP then
		steps:= SNAKE_SPEED_TOP;

	PlaySnakes[SNAKE_SLOT_BOSS].MoveTick:= steps - 1;

	// --- pick a direction ---
	//
	// Nearest live PLAYER, never a bee. Re-picked every step rather than
	// kept for life the way a bee's target is: there is only one boss,
	// so the clumping that rule exists to prevent cannot happen, and a
	// boss still chasing a corner somebody had long since left would
	// simply look broken.
	bestdist:= BOARD_COLS + BOARD_ROWS;
	best:= -1;

	for k:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  PlaySnakes[k].Alive then
			begin
			dist:= HeadDist(PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row,
					PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col, k);

			if  dist < bestdist then
				begin
				bestdist:= dist;
				best:= k;
				end;
			end;

	// OPPORTUNISTIC FEEDING, resolved before the chase and overriding it.
	//
	// The rate at which the boss grows was never really about the rate:
	// with 3 per food it managed 12 segments to 13 in a hundred seconds,
	// because it homes on HEADS and so only ever meets food by accident.
	// Raising the numbers alone would have made those accidents bigger
	// without making them any less rare, which is a lottery, not a
	// mechanic.
	//
	// So it takes anything edible it is ALREADY STANDING NEXT TO. One
	// cell of greed, no searching and no pathfinding - it will never
	// cross the board for a meal, and a player is still what it wants -
	// but food it walks past now feeds it instead of being stepped
	// around. On a boss stage the swarm is on, which makes bees the
	// steadier of the two supplies.
	grabbed:= False;

	for i:= 0 to 3 do
		begin
		cand:= TSnakeDir(i);

		if  cand = OppositeDir(PlaySnakes[SNAKE_SLOT_BOSS].Dir) then
			Continue;

		nr:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row;
		nc:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col;

		case cand of
			sdUp:    Dec(nr);
			sdDown:  Inc(nr);
			sdLeft:  Dec(nc);
		else
			Inc(nc);
			end;

		if  (nr <= 0) or (nr >= BOARD_ROWS - 1)
		or  (nc <= 0) or (nc >= BOARD_COLS - 1) then
			Continue;

		// IT IS FUSSY ABOUT FOOD (dengland: "it just wants the grow ones
		// really maybe the invincibility ones"). Only the extra-growth
		// food and the heart are worth a step out of its way - see
		// PLAY_BOSS_WANTS - which keeps its appetite legible: the boss
		// goes for the things that make it BIGGER, not for speed or for
		// a food whose whole purpose is to stop growth.
		//
		// It still DESTROYS anything it happens to cross, and still
		// grows from that; this is only about what it will turn aside
		// for. Bees always qualify - they are the steadier supply on a
		// stage that keeps its swarm.
		if  Board[nr][nc] <> TILE_BEE then
			begin
			if  (Board[nr][nc] < TILE_FOOD_BASE)
			or  (Board[nr][nc] >= TILE_FOOD_BASE + FOOD_RANDOM_KINDS) then
				Continue;

			if  not PLAY_BOSS_WANTS[Board[nr][nc] - TILE_FOOD_BASE] then
				Continue;
			end;

		// Legality is still Verdict's to decide - a bee sitting on a
		// cell the boss cannot enter for some other reason is not a
		// meal.
		if  Verdict(nr, nc, victim) <> bsMove then
			Continue;

		want:= cand;
		grabbed:= True;

		Break;
		end;

	// When something was grabbed, `want` is already decided and the
	// whole chase below is skipped - straight to the resolve pass, which
	// still runs its full search from that direction, so if anything has
	// changed its mind about the cell the boss simply picks another.
	if  not grabbed then
		begin
	pick:= Random(PLAY_BOSS_WEIGHT_TOWARD + PLAY_BOSS_WEIGHT_RANDOM
			+ PLAY_BOSS_WEIGHT_STALL);

	dr:= 0;
	dc:= 0;

	if  (pick < PLAY_BOSS_WEIGHT_TOWARD) and (best >= 0) then
		begin
		// Close the LARGER axis first - TickPlayBees' rule exactly. No
		// pathfinding, deliberately: it is what makes walls genuine
		// shelter rather than a brief detour, and it is the difference
		// between a hazard and an opponent.
		r:= PlaySnakes[best].Body[0].Row;
		c:= PlaySnakes[best].Body[0].Col;

		if  Abs(r - Integer(PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row))
				> Abs(c - Integer(PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col)) then
			begin
			if  r < PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row then
				dr:= -1
			else if r > PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row then
				dr:= 1;
			end
		else
			begin
			if  c < PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col then
				dc:= -1
			else if c > PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col then
				dc:= 1;
			end;

		// REELING - RUN AWAY. The same vector, turned round.
		//
		// THIS IS WHAT MAKES THE FIGHT A FIGHT, and it was the second
		// thing the test run forced. With the boss's own move no longer
		// able to hurt it, the damage all came from the player's side -
		// and a player jammed nose to nose with the boss simply RE-RAMS
		// it every single step, so all three lives went in three
		// consecutive gate-openings, 2.5 seconds apart, seventeen
		// seconds into the level. The hit gate alone cannot fix that: it
		// only sets the metronome the lives are spent on.
		//
		// Breaking contact is what fixes it, and having the boss recoil
		// is the version of that which reads as something rather than as
		// a rule. Land a hit and it flinches away across the board; you
		// have to hunt it down and set the next one up, which is three
		// separate encounters instead of one long shove. It also means
		// the reeling spell is doing visible work rather than being an
		// invisible cooldown.
		//
		// Not while DORMANT, though - the opening spell is invulnerable
		// too, and a boss that fled before it had even woken up would
		// never be where the level put it.
		if  (PlaySnakes[SNAKE_SLOT_BOSS].InvunTicks > 0)
		and (BossWake = 0) then
			begin
			dr:= -dr;
			dc:= -dc;
			end;
		end
	else if pick < (PLAY_BOSS_WEIGHT_TOWARD + PLAY_BOSS_WEIGHT_RANDOM) then
		begin
		case Random(4) of
			0: dr:= -1;
			1: dr:= 1;
			2: dc:= -1;
		else
			dc:= 1;
			end;
		end
	else
		begin
		// STALLED. Not a lost move to be recovered from by trying
		// elsewhere - it IS the deliberate uncertainty in the boss's
		// arrival time, and rerouting round it would quietly delete the
		// one thing keeping the chase from being solvable by arithmetic.
		if  repaint then
			RepaintBoss;

		Exit;
		end;

	if  dr < 0 then
		want:= sdUp
	else if dr > 0 then
		want:= sdDown
	else if dc < 0 then
		want:= sdLeft
	else if dc > 0 then
		want:= sdRight
	else
		begin
		// Already level with the target on the axis it chose, which is
		// only reachable when it is standing on it. Nothing to do.
		if  repaint then
			RepaintBoss;

		Exit;
		end;

		end;			// not grabbed - the whole chase above is skipped

	// --- resolve the step ---
	//
	// The preferred direction first, then the others in order. A player
	// whose move is blocked DIES; the boss instead takes the next legal
	// thing it can find, because a boss that killed itself on a wall
	// would end the level by accident and a boss that simply stopped
	// would wedge in a dead end for the rest of it.
	// Run TWICE if the first pass finds nothing, with the boss FLOATING
	// on the second - see below.
	for pass:= 0 to 1 do
		begin
		chosen:= bsBlocked;
		chosenVictim:= -1;

		for i:= 0 to 4 do
			begin
			if  i = 0 then
				cand:= want
			else
				begin
				cand:= TSnakeDir(i - 1);

				if  cand = want then
					Continue;			// already tried
				end;

			// Never reverse onto its own neck. Verdict's tail exemption
			// would otherwise make this legal on a short body and the
			// boss would turn itself inside out.
			if  cand = OppositeDir(PlaySnakes[SNAKE_SLOT_BOSS].Dir) then
				Continue;

			nr:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row;
			nc:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col;

			case cand of
				sdUp:    Dec(nr);
				sdDown:  Inc(nr);
				sdLeft:  Dec(nc);
			else
				Inc(nc);
				end;

			stepKind:= Verdict(nr, nc, victim);

			if  stepKind = bsBlocked then
				Continue;

			chosen:= stepKind;
			chosenVictim:= victim;
			PlaySnakes[SNAKE_SLOT_BOSS].Look:= cand;

			Break;
			end;

		if  chosen <> bsBlocked then
			Break;

		// BOXED IN - AND FOR THE BOSS THAT IS A DEADLOCK, not a bad
		// moment. dengland hit it in play: "the boss is stuck. I think
		// if that happens it has to go floating somehow over its own
		// tail".
		//
		// It is worse than it would be for anybody else, and the reason
		// is the clock. A stuck PLAYER is only stuck until the level
		// runs out; a stuck BOSS stops the level running out at all,
		// because a boss stage's clock is frozen until the boss dies
		// (see Tick). A boss coiled into its own body would therefore
		// hold the board open indefinitely.
		//
		// It became reachable the moment the boss was allowed to grow -
		// at twelve segments it can barely trap itself, at forty it
		// coils easily.
		//
		// FLOATING IS ALREADY THE ANSWER TO THIS EXACT PROBLEM. It was
		// built so a snake spawning on top of another could always move
		// clear rather than being stuck inside it (see TSnake.Floating),
		// and "cannot move because a snake is in the way" is the same
		// predicament arriving from the other direction. So the boss
		// takes the same escape: it passes through its own body until
		// its head is somewhere clear, then goes solid again.
		//
		// Walls are NOT included in that - floating never made anybody
		// pass through level geometry, and a boss walled into a pocket
		// with no exit is the level's own doing rather than a knot it
		// tied in itself.
		if  PlaySnakes[SNAKE_SLOT_BOSS].Floating then
			Break;						// already floating and still stuck

		PlaySnakes[SNAKE_SLOT_BOSS].Floating:= True;

		AddLogMessage(slkDebug, 'Boss boxed in at ' + IntToStr(PlaySnakes[SNAKE_SLOT_BOSS].Len)
				+ ' segments - floating clear');
		end;

	// Genuinely nowhere to go, even floating - walled in. Stall and try
	// again next step; the board moves around it, so this resolves
	// itself.
	if  chosen = bsBlocked then
		begin
		if  repaint then
			RepaintBoss;

		Exit;
		end;

	// RAN INTO SOMEBODY. Nobody moves, nobody is hurt, and NOBODY IS
	// SHIELDED - see Verdict for why the boss's own move can never hurt
	// it, and read on for why it must not help the player either.
	//
	// It DID hand the player a shield at first, on the strength of "the
	// same both players run into each other logic". That was the wrong
	// reading of it, and dengland caught it in play: "does the player go
	// shielded when the boss hits them? That's not right."
	//
	// He is right, and the reason is that THIS IS NOT THE SYMMETRIC
	// EXCHANGE the player-versus-player rule describes. The boss
	// initiates nearly all of these, because chasing is the whole of
	// what it does - so a shield here is not a fair draw between equals,
	// it is a free power-up handed out several times a minute by the one
	// thing on the board you are meant to be afraid of. It left players
	// near-immortal while near the boss, which is precisely backwards.
	//
	// It also polluted things well away from the boss, which is worth
	// keeping in mind: a shield acquired this way silently turns the
	// NEXT bee contact from a death into a kill. That is very probably
	// what he was seeing when he added "when I hit a bee, I thought I
	// went shielded".
	//
	// A genuine mutual collision - the player driving into the boss's
	// HEAD - still pays out exactly as it always did, in TickPlaySnakes.
	// That one the player chose.
	if  chosen = bsDraw then
		begin
		if  repaint then
			RepaintBoss;

		Exit;
		end;

	nr:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Row;
	nc:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0].Col;

	case PlaySnakes[SNAKE_SLOT_BOSS].Look of
		sdUp:    Dec(nr);
		sdDown:  Inc(nr);
		sdLeft:  Dec(nc);
	else
		Inc(nc);
		end;

	// Whatever else was in the cell is destroyed on the way in - NOW,
	// once the cell is definitely being entered, so a candidate that
	// lost the search cannot have quietly eaten anything. A bee taken
	// this way is not a player's kill and must not anger the swarm
	// (LevelBeesEaten is only ever moved by a player); food is simply
	// gone, unscored.
	// Logged because growth has been the hardest thing here to get right,
	// and it is almost impossible to measure from outside: a board dump
	// only says how long the boss was at the instant you happened to
	// look, and only if the board was still in play then. Two attempts
	// at measuring it that way told me nothing at all.
	//
	// ON THE FEED ITSELF, not on "still owed segments" - the first
	// version tested BossGrow and so fired every step of the growth,
	// which read as the boss eating eight times in a row when it had
	// eaten once. A diagnostic that overstates the thing it is measuring
	// is worse than none.
	fed:= False;

	f:= BeeAt(nr, nc);

	if  f >= 0 then
		begin
		PlayBees[f].Active:= False;
		Inc(BossGrow, PLAY_BOSS_GROW_BEE);
		fed:= True;
		end;

	if  FoodAt(nr, nc) >= 0 then
		begin
		ClearFoodAt(nr, nc);
		Inc(BossGrow, PLAY_BOSS_GROW_FOOD);
		fed:= True;
		end;

	if  fed then
		AddLogMessage(slkDebug, 'Boss fed at ' + IntToStr(nr) + ','
				+ IntToStr(nc) + ' - len '
				+ IntToStr(PlaySnakes[SNAKE_SLOT_BOSS].Len)
				+ ', ' + IntToStr(BossGrow) + ' owed');

	// --- move, exactly as a player snake moves ---
	prevDir:= PlaySnakes[SNAKE_SLOT_BOSS].Dir;
	PlaySnakes[SNAKE_SLOT_BOSS].Dir:= PlaySnakes[SNAKE_SLOT_BOSS].Look;

	head:= PlaySnakes[SNAKE_SLOT_BOSS].Body[0];
	head.Row:= nr;
	head.Col:= nc;

	// GROWING IS SIMPLY NOT VACATING THE TAIL, the same trick the player
	// step uses: make room and let the shift below duplicate the last
	// segment into it, which leaves the new tail on a cell that is
	// already painted and so costs no delta either.
	if  (BossGrow > 0)
	and (PlaySnakes[SNAKE_SLOT_BOSS].Len < PLAY_BOSS_LEN_MAX) then
		begin
		Dec(BossGrow);
		Inc(PlaySnakes[SNAKE_SLOT_BOSS].Len);
		end
	else
		begin
		// THE TAIL MAY BE LEAVING A CELL THE BOSS IS STILL IN.
		//
		// VacateCell takes AExclude to mean "ignore this whole snake",
		// which is right for everybody else, because no ordinary snake
		// can occupy one cell twice - it would have died on itself. A
		// FLOATING BOSS CAN: passing through its own body is the entire
		// point of the escape, and while it is doing so two of its
		// segments share a cell.
		//
		// So the tail leaving such a cell had VacateCell find nothing
		// there worth keeping and emit bare floor - straight through the
		// middle of the boss's own body. That is dengland's report,
		// exactly: "the boss tail is breaking up on occasion... I wonder
		// if its to do with floating".
		//
		// Look for one of our OWN remaining segments first, and repaint
		// that instead. Only then is it really empty and VacateCell's
		// question - is somebody ELSE still standing here - the right
		// one to ask.
		j:= -1;

		for i:= 0 to PlaySnakes[SNAKE_SLOT_BOSS].Len - 2 do
			if  (PlaySnakes[SNAKE_SLOT_BOSS].Body[i].Row
					= PlaySnakes[SNAKE_SLOT_BOSS].Body[PlaySnakes[SNAKE_SLOT_BOSS].Len - 1].Row)
			and (PlaySnakes[SNAKE_SLOT_BOSS].Body[i].Col
					= PlaySnakes[SNAKE_SLOT_BOSS].Body[PlaySnakes[SNAKE_SLOT_BOSS].Len - 1].Col) then
				begin
				j:= i;

				Break;
				end;

		if  j >= 0 then
			with PlaySnakes[SNAKE_SLOT_BOSS].Body[j] do
				begin
				if  j = 0 then
					EmitCell(Row, Col,
							SnakeTile(PlaySnakes[SNAKE_SLOT_BOSS].Player,
								SNAKE_ROLE_HEAD, Shape),
							ADeltas, ADeltaCount)
				else
					EmitCell(Row, Col,
							SnakeBodyTile(PlaySnakes[SNAKE_SLOT_BOSS].Player,
								Shape, PlaySnakes[SNAKE_SLOT_BOSS].FlashOn),
							ADeltas, ADeltaCount);
				end
		else
			// Nobody of ours left here - so now ask whether anybody
			// ELSE is, which is what VacateCell is for. A floating
			// player may still be lying in it.
			with PlaySnakes[SNAKE_SLOT_BOSS].Body[PlaySnakes[SNAKE_SLOT_BOSS].Len - 1] do
				VacateCell(Row, Col, SNAKE_SLOT_BOSS, ADeltas, ADeltaCount);

		// Owed segments the length cap will never pay are dropped rather
		// than banked, or a boss that fed early would keep growing for
		// the rest of the level the moment anything shortened it.
		if  BossGrow > 0 then
			BossGrow:= 0;
		end;

	for i:= PlaySnakes[SNAKE_SLOT_BOSS].Len - 1 downto 1 do
		PlaySnakes[SNAKE_SLOT_BOSS].Body[i]:=
				PlaySnakes[SNAKE_SLOT_BOSS].Body[i - 1];

	PlaySnakes[SNAKE_SLOT_BOSS].Body[1].Shape:=
			SegShape(prevDir, PlaySnakes[SNAKE_SLOT_BOSS].Dir);

	with PlaySnakes[SNAKE_SLOT_BOSS].Body[1] do
		EmitCell(Row, Col,
				SnakeBodyTile(PlaySnakes[SNAKE_SLOT_BOSS].Player, Shape,
					PlaySnakes[SNAKE_SLOT_BOSS].FlashOn),
				ADeltas, ADeltaCount);

	// NO TURN TELEGRAPH, unlike a player's head. The boss chooses its
	// direction fresh at the start of each step, so at this moment there
	// is nothing yet decided to telegraph - and a tell that only
	// appeared one step ahead would be worse than none at all, since
	// players would learn to read it and it would be lying half the
	// time.
	head.Shape:= SegShape(PlaySnakes[SNAKE_SLOT_BOSS].Dir,
			PlaySnakes[SNAKE_SLOT_BOSS].Dir);
	PlaySnakes[SNAKE_SLOT_BOSS].Body[0]:= head;

	EmitCell(head.Row, head.Col,
			SnakeTile(PlaySnakes[SNAKE_SLOT_BOSS].Player, SNAKE_ROLE_HEAD,
				head.Shape),
			ADeltas, ADeltaCount);

	// STOP FLOATING once the head is somewhere nobody is - its own body
	// included. The player rule is the same one and for the same reason:
	// the head is what has to be able to collide again, and a tail still
	// trailing through something is harmless because VacateCell keeps it
	// from erasing whatever it leaves behind.
	//
	// Testing from segment 1 rather than 0, since the head is obviously
	// standing on its own head.
	if  PlaySnakes[SNAKE_SLOT_BOSS].Floating then
		begin
		grabbed:= False;			// reused: "still inside something"

		for i:= 1 to PlaySnakes[SNAKE_SLOT_BOSS].Len - 1 do
			if  (PlaySnakes[SNAKE_SLOT_BOSS].Body[i].Row = head.Row)
			and (PlaySnakes[SNAKE_SLOT_BOSS].Body[i].Col = head.Col) then
				begin
				grabbed:= True;

				Break;
				end;

		if  (not grabbed)
		and (SolidSnakeAt(head.Row, head.Col, SNAKE_SLOT_BOSS) < 0) then
			PlaySnakes[SNAKE_SLOT_BOSS].Floating:= False;
		end;

	// A FLOATING BOSS PAINTS LAST, so it is on top of anything that
	// moved through or under it - head included, which RepaintBoss does
	// not cover. The players' own floaters get this at the end of
	// TickPlaySnakes; the boss cannot use that pass because it moves
	// after it.
	if  repaint or PlaySnakes[SNAKE_SLOT_BOSS].Floating then
		begin
		RepaintBoss;

		with PlaySnakes[SNAKE_SLOT_BOSS].Body[0] do
			EmitCell(Row, Col,
					SnakeTile(PlaySnakes[SNAKE_SLOT_BOSS].Player,
						SNAKE_ROLE_HEAD, Shape),
					ADeltas, ADeltaCount);
		end;
	end;

// TickPlaySnakes - advance every live player snake one tick. Caller
// holds Lock.
//
// The movement is deliberately the same shape as TickDemoSnakes: tail
// vacates first, body shifts, Body[1] becomes the corner piece, the
// head telegraphs its next turn. The differences are only the two the
// demo does not need - the direction comes from the player rather than
// DemoLookFrom, and the target cell is TESTED before it is entered.
procedure TSnakeGame.TickPlaySnakes(var ADeltas: array of TTileDelta;
		var ADeltaCount: Integer);
	var
	i, s, t, f, blocker: Integer;
	head: TSnakeSeg;
	prevDir: TSnakeDir;
	tile: Byte;
	wantFlash, repaint, growing, eat, blocked: Boolean;

	// Resolved in a PRE-PASS, before anything moves. Stepping[] is who
	// is due a step this tick, TgtRow/TgtCol where their head would
	// land, and Mutual[] is set on every snake sharing a target with
	// another.
	//
	// The pre-pass exists to remove a slot-order bias a single loop
	// cannot avoid: whoever is processed first enters the disputed cell
	// and paints it, and everyone after reads a snake there and dies.
	// Corner 0 would win every head-on on the board. The original
	// resolves it the same way and for the same reason - objectsTick
	// computes tPos1 and tPos2 up front, then tests them against each
	// other before either moves.
	Stepping, Mutual: array[0..SNAKE_PLAYER_COUNT - 1] of Boolean;
	TgtRow, TgtCol: array[0..SNAKE_PLAYER_COUNT - 1] of Byte;

	// The direction each stepping snake ARRIVED at its current cell
	// with, captured in the pre-pass because committing the turn
	// (Dir := Look) destroys it, and the resolve pass still needs it to
	// shape the corner the head leaves behind.
	ArrivedDir: array[0..SNAKE_PLAYER_COUNT - 1] of TSnakeDir;

	// Whether this snake's flash phase flipped this tick, and so owes a
	// whole-body repaint. Per-snake for the same reason PrevDir is: the
	// phase is decided in the pre-pass but acted on after the move, and
	// a single shared variable would hand every snake the LAST one's
	// answer.
	NeedRepaint: array[0..SNAKE_PLAYER_COUNT - 1] of Boolean;

	procedure Emit(ARow, ACol, ATile: Byte);
		begin
		EmitCell(ARow, ACol, ATile, ADeltas, ADeltaCount);
		end;

	procedure RepaintBody(ASnake: Integer);
		var
		j: Integer;

		begin
		for j:= 1 to PlaySnakes[ASnake].Len - 1 do
			with PlaySnakes[ASnake].Body[j] do
				Emit(Row, Col, SnakeBodyTile(PlaySnakes[ASnake].Player,
						Shape, PlaySnakes[ASnake].FlashOn));
		end;

	// Re-shape and re-emit the head from the CURRENT Dir/Look, moving
	// nothing.
	//
	// THE TURN TELEGRAPH ONLY EVER EXISTED FOR SNAKES THAT WERE MOVING.
	// The head is shaped SegShape(Dir, Look) and drawn as part of the
	// step, so a snake that did not step never repainted it, and a turn
	// pressed meanwhile was invisible until it moved again.
	//
	// In open board that is one tick and nobody could see it. For a
	// snake held STILL it is indefinite, and dengland hit exactly that
	// (2026-08-26): "I turned from going left to right upwards into a
	// wall while shielded. It should show the turn on the head but it
	// doesn't." A shielded snake against a wall never moves, so the head
	// went on pointing the old way while the player waited for any
	// evidence the input had registered at all.
	//
	// Called from all three did-not-move paths below. The head is the
	// ONLY feedback that a turn has been accepted, and it matters most
	// precisely when nothing else is happening.
	procedure ShowHead(ASnake: Integer);
		begin
		PlaySnakes[ASnake].Body[0].Shape:=
				SegShape(PlaySnakes[ASnake].Dir, PlaySnakes[ASnake].Look);

		with PlaySnakes[ASnake].Body[0] do
			Emit(Row, Col, SnakeTile(PlaySnakes[ASnake].Player,
					SNAKE_ROLE_HEAD, Shape));
		end;

	begin
	for s:= 0 to SNAKE_PLAYER_COUNT - 1 do
		begin
		Stepping[s]:= False;
		Mutual[s]:= False;
		end;

	for s:= 0 to SNAKE_PLAYER_COUNT - 1 do
		begin
		// An unclaimed corner has no snake and no respawn pending.
		if  not Assigned(Slots[s].Player) then
			Continue;

		if  not PlaySnakes[s].Alive then
			begin
			if  PlayRespawn[s] > 0 then
				begin
				Dec(PlayRespawn[s]);

				if  PlayRespawn[s] = 0 then
					begin
					SpawnPlayerSnake(s, ADeltas, ADeltaCount);

					// Tell the corner's owner it is back, so the client
					// can forget the direction it last sent. The snake
					// respawns on a heading WE chose, and a player who
					// held a direction through the respawn would
					// otherwise have it deduped away client-side and
					// never actually turn (dengland, 2026-08-25).
					SlotStatusToAll(s);
					end;
				end;

			Continue;
			end;

		// Invulnerability runs on the TICK, not the step - same reason
		// as the demo's: it has to flash even on ticks where this snake
		// is standing still waiting for its next move.
		if  PlaySnakes[s].InvunTicks > 0 then
			Dec(PlaySnakes[s].InvunTicks);

		// The food effects age on the tick too, and for the same reason -
		// the original runs the lot from one effectsTick (server.lua:1700)
		// independently of whether anything moved. That matters for
		// MoveFast in particular: it is what decides the step interval, so
		// deciding it on the step would make a fast snake burn its own
		// boost quicker than a slow one.
		if  PlaySnakes[s].MoveFast > 0 then
			Dec(PlaySnakes[s].MoveFast)
		else if PlaySnakes[s].MoveFast < 0 then
			Inc(PlaySnakes[s].MoveFast);

		if  PlaySnakes[s].GrowNone > 0 then
			Dec(PlaySnakes[s].GrowNone);

		if  PlaySnakes[s].GrowEx > 0 then
			begin
			Dec(PlaySnakes[s].GrowEx);

			// Running out is what ENDS continuous growth, not the next
			// step - otherwise a snake that happened to be between steps
			// when the timer expired would get one more segment out of it.
			if  PlaySnakes[s].GrowEx = 0 then
				PlaySnakes[s].Grow:= False;
			end;

		wantFlash:= InvunFlashOn(PlaySnakes[s].InvunTicks);

		repaint:= wantFlash <> PlaySnakes[s].FlashOn;
		PlaySnakes[s].FlashOn:= wantFlash;
		NeedRepaint[s]:= repaint;

		// THE TURN TELEGRAPH, drained BEFORE the step is even considered
		// - see SetPlayerLook. This is the whole point: the head shows
		// the new heading whether or not the snake is due to move, and
		// whether or not the move will turn out to be legal.
		if  PlayHeadDirty[s] then
			begin
			PlayHeadDirty[s]:= False;
			ShowHead(s);
			end;

		if  PlaySnakes[s].MoveTick > 0 then
			begin
			Dec(PlaySnakes[s].MoveTick);

			if  repaint then
				RepaintBody(s);

			Continue;
			end;

		PlaySnakes[s].MoveTick:= PlayStepTicks(s) - 1;

		// Due a step. Work out WHERE, but move nothing yet - see the
		// pre-pass note on the declarations above.
		ArrivedDir[s]:= PlaySnakes[s].Dir;
		PlaySnakes[s].Dir:= PlaySnakes[s].Look;

		head:= PlaySnakes[s].Body[0];
		StepCell(head.Row, head.Col, PlaySnakes[s].Dir);

		Stepping[s]:= True;
		TgtRow[s]:= head.Row;
		TgtCol[s]:= head.Col;
		end;

	// Two snakes stepping into the SAME cell is a head-on, and neither
	// of them is at fault for it. Mark both (or all of them) so the
	// resolve pass below treats it as a draw rather than letting
	// whichever slot happens to be lower take the cell and kill the
	// rest.
	for s:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  Stepping[s] then
			for t:= s + 1 to SNAKE_PLAYER_COUNT - 1 do
				if  Stepping[t]
				and (TgtRow[s] = TgtRow[t]) and (TgtCol[s] = TgtCol[t]) then
					begin
					Mutual[s]:= True;
					Mutual[t]:= True;
					end;

	// --- resolve and move ---
	for s:= 0 to SNAKE_PLAYER_COUNT - 1 do
		begin
		if  not Stepping[s] then
			Continue;

		// A head-on costs nobody anything except their momentum and
		// their power-ups, and buys both parties a shield to get clear
		// with. This is the original's own rule (snakeApplyCollide,
		// server.lua:1064): in battle mode a snake only loses a life
		// "if not tSnake2P.collide", so when both collide neither is
		// penalised and no loser is announced - they are just reset and
		// made invulnerable for a while.
		//
		// dengland asked whether a head-on should kill both instead
		// (2026-08-25). His own game says no, and it is the better
		// rule for four players: with everyone circulating a shared
		// board, head-ons are frequent and often nobody's mistake.
		// To make it lethal instead, replace this branch with
		// KillPlayerSnake.
		//
		// THIS IS ALSO THE TWO-SNAKES-ONE-FOOD CASE (dengland asked,
		// 2026-08-25). Two heads can only reach the same piece of food by
		// targeting the same cell, which is a head-on by definition and
		// lands here - so neither moves, neither eats, and the food is
		// still sitting there when they untangle. No double-scoring is
		// possible, and no special case is needed to prevent it.
		//
		// The alternative dengland floated - both get the EFFECT but
		// neither the points - would mean consuming the food while both
		// snakes stand still, and would make a contested pickup better
		// value than an uncontested one. Leaving it on the board says
		// "neither of you earned that yet", which reads better and is
		// what the head-on rule already says about everything else.
		if  Mutual[s] then
			begin
			// DID NOT MOVE, so it did not travel in the direction the
			// pre-pass optimistically committed to. Put Dir back to the
			// heading it actually arrived on - see the note on the
			// shielded branch below for what goes wrong otherwise.
			PlaySnakes[s].Dir:= ArrivedDir[s];

			PlaySnakes[s].InvunTicks:= PLAY_SPAWN_INVUN_TICKS;

			if  not PlaySnakes[s].FlashOn then
				begin
				PlaySnakes[s].FlashOn:= True;
				RepaintBody(s);
				end;

			ShowHead(s);

			Continue;
			end;

		prevDir:= ArrivedDir[s];
		repaint:= NeedRepaint[s];

		head:= PlaySnakes[s].Body[0];
		head.Row:= TgtRow[s];
		head.Col:= TgtCol[s];

		// Will this step LENGTHEN the snake? Decided before the collision
		// test, because the answer is also what says whether the tail is
		// about to vacate - see the exemption below.
		//
		// Food at the target cell cannot change it: the tail is a snake
		// tile, so the cell being landed on is never both.
		growing:= PlaySnakes[s].Grow and (PlaySnakes[s].GrowNone = 0)
				and (PlaySnakes[s].Len < MAX_SNAKE_LEN);

		tile:= Board[head.Row][head.Col];

		// FOOD IS THE ONE non-floor tile a head may enter. The original
		// gets this for free - snakeCheckCollide only blocks on tile
		// sheets below 3, and food is sheet 3 - but QUADRO's collision is
		// deliberately "anything not floor", so food has to be named.
		eat:= (tile >= TILE_FOOD_BASE)
				and (tile < TILE_FOOD_BASE + FOOD_TYPE_COUNT);

		// THE COLLISION TEST. Anything that is not bare floor or food
		// stops the snake dead - wall, another snake, its own body, a
		// hazard. One test covers the lot, exactly as lava spreading and
		// bees stepping already only accept TILE_FLOOR, so no case
		// analysis and nothing to forget when a new tile type is added.
		//
		// The border ring means there is no bounds check to write: a
		// head cannot leave the board without hitting the wall first.
		// (The original, having no border, relies on a range test that
		// is commented out - see the LEVEL_* notes.)
		// The snake's OWN TAIL is exempt WHEN IT IS ABOUT TO VACATE. It
		// is still painted on the board here but leaves below in the same
		// step, so the cell is genuinely free by the time the head lands
		// on it. Without this a snake dies for turning tightly enough to
		// follow itself - which is legal, common, and takes more skill
		// than a loose turn, so it would punish exactly the wrong thing.
		//
		// A GROWING snake keeps its tail this step, so the exemption is
		// off and following yourself that closely really does kill you.
		// That is the honest price of the extra-growth food, and it is
		// why it is the cheapest thing on the board.
		blocked:= (tile <> TILE_FLOOR) and not eat;

		// Z ORDER. Once anything is floating, Board reports only what is
		// on TOP of a cell, so a snake tile there no longer means a snake
		// is really in the way. Re-ask the models whenever the cell reads
		// as a snake - and only then, so walls, lava and bees keep the
		// cheap single-byte test they have always had.
		//
		// Both halves of dengland's rule live here:
		//   - a FLOATING snake is not blocked by snakes at all, which is
		//     what guarantees it can always move clear again rather than
		//     being stuck inside whatever it spawned on
		//   - nobody is blocked BY a floating snake, which is the same
		//     thing said from the other side and is what stops the
		//     newcomer killing the snake it materialised in
		blocker:= -1;

		if  blocked and IsSnakeTile(tile) then
			if  PlaySnakes[s].Floating then
				blocked:= False
			else
				begin
				blocker:= SolidSnakeAt(head.Row, head.Col, -1);
				blocked:= blocker >= 0;
				end;

		// THE BOSS, MET HEAD ON. Since 2026-08-26 this is the only thing
		// that hurts it, and the rule it runs on is the one two players
		// already get: nobody moves, nobody loses a life, both come away
		// shielded (dengland: "the same both players run into each other
		// logic for snakes should apply... let's use the both collide to
		// kill the boss").
		//
		// THE HEAD, SPECIFICALLY. Reaching any other part of the boss is
		// an ordinary collision and kills you, exactly as running into
		// any other snake does - so the weapon is the one manoeuvre
		// every instinct says not to attempt.
		//
		// THIS IS THE ONLY PLACE THE BOSS CAN BE DAMAGED. TickBoss
		// deliberately has no mirror of it: the boss homing on heads is
		// its entire chase, so letting its own move count as a mutual
		// collision made it suicidal - see Verdict, where the first test
		// run is written up.
		//
		// Nothing is lost by putting it all here, and that is exact
		// rather than lucky: PLAYERS MOVE FIRST each tick, so a player
		// driving into the boss is always resolved on this pass. By the
		// time the boss moves, the only players left for it to meet are
		// ones that did not move into it.
		// NO SIMULTANEITY GATE HERE, and the reason is worth keeping.
		//
		// dengland raised the right principle - "snakes only both
		// collide when they are going the same speed otherwise one
		// reaches the other first and should win" - and it was briefly
		// implemented as "only if the boss is also due a step this
		// tick" (MoveTick = 0). Then he reported the consequence from
		// the other side: "I was shielded and didn't hit the boss."
		//
		// THAT TEST CANNOT SURVIVE THE BOSS RUNNING AT PLAYER SPEED,
		// which is the change he asked for in the same breath. Both
		// counters then have the SAME PERIOD, so their phase relative
		// to one another is fixed until something resets it - a death,
		// a respawn, a speed food. Two snakes one tick out of step
		// would never once hit zero together, and the head-on would be
		// silently impossible for that pairing for minutes at a time.
		// A mechanic that works or does not work on invisible phase is
		// worse than one that is merely generous.
		//
		// With the boss at player speed the principle is satisfied
		// anyway: neither party is quicker, so nobody "gets there
		// first", and driving head-first into it IS the mutual
		// collision. Body contact still kills you exactly as it always
		// did - the head is the only part of it that is a weapon rather
		// than a wall.
		//
		// If this ever needs to be genuinely simultaneous, the way to
		// do it is to have the boss choose and PUBLISH its target cell
		// before the player pass runs, not to guess from a counter.
		if  blocked and (blocker = SNAKE_SLOT_BOSS)
		and (SnakeSegAt(SNAKE_SLOT_BOSS, head.Row, head.Col) = 0) then
			begin
			// Did not move - so put Dir back to the heading actually
			// travelled, for the reason set out on the shielded branch
			// below.
			PlaySnakes[s].Dir:= ArrivedDir[s];

			PlaySnakes[s].InvunTicks:= PLAY_SPAWN_INVUN_TICKS;

			if  not PlaySnakes[s].FlashOn then
				begin
				PlaySnakes[s].FlashOn:= True;
				RepaintBody(s);
				end;

			// Declines while the boss is dormant or already reeling, and
			// the draw above still stands in that case - see HitBoss.
			HitBoss(s, ADeltas, ADeltaCount);

			ShowHead(s);

			Continue;
			end;

		if  blocked
		and (growing
			or not ((head.Row = PlaySnakes[s].Body[PlaySnakes[s].Len - 1].Row)
				 and (head.Col = PlaySnakes[s].Body[PlaySnakes[s].Len - 1].Col))) then
			begin
			// A BEE IS DESTROYED BY THE CONTACT either way, shield or
			// no shield - the original clears the tile unconditionally
			// and only the SCORING depends on being invulnerable
			// (snakeCheckCollide, server.lua:930).
			//
			// So an unshielded snake still takes the bee down with it,
			// which is worth keeping: a bee can never become a
			// permanent blockade, however badly the board is going.
			if  tile = TILE_BEE then
				begin
				f:= BeeAt(head.Row, head.Col);

				if  f >= 0 then
					PlayBees[f].Active:= False;

				Emit(head.Row, head.Col, TILE_FLOOR);

				// Shielded, so this was a KILL rather than a death. The
				// one thing on the board worth going out of your way
				// for, and it only exists while a burst is running -
				// which turns the heart food into a timed hunting
				// licence rather than just a safety net.
				if  PlaySnakes[s].InvunTicks > 0 then
					begin
					AddScore(s, PLAY_BEE_PTS);
					SlotStatusToAll(s);

					// And the swarm notices. Only shielded kills count -
					// see PLAY_BEE_ANGER_PER.
					Inc(LevelBeesEaten);
					end;
				end;

			// A shielded snake shrugs it off and simply does not move,
			// rather than passing through. Passing through would let a
			// spawn shield be used to cut corners across walls, which
			// is a different game. Same rule covers the bee above - you
			// swat it from where you are, you do not step onto it.
			if  PlaySnakes[s].InvunTicks > 0 then
				begin
				// DID NOT MOVE - so put Dir back to the heading actually
				// travelled, undoing the pre-pass's optimistic
				// `Dir := Look`.
				//
				// Without this, Dir records a step that never happened,
				// and the NEXT step shapes its corner piece from a
				// phantom heading - the segment left behind bends the
				// wrong way. dengland caught it 2026-08-25: eat a bee
				// while shielded, turn immediately, and "the tile
				// displayed for the tail was wrong". Shielded contact is
				// the common way to hit this, but the head-on draw above
				// had exactly the same hole.
				//
				// It also keeps SetPlayerLook's reversal test honest,
				// since that tests Dir precisely because it is meant to
				// be the direction genuinely travelled.
				PlaySnakes[s].Dir:= ArrivedDir[s];

				if  repaint then
					RepaintBody(s);

				ShowHead(s);

				Continue;
				end;

			KillPlayerSnake(s, ADeltas, ADeltaCount);
			Continue;
			end;

		// Survived the step, so anything edible here is eaten now - after
		// the collision test and before the move, exactly the order the
		// original uses (snakeCheckCollide, snakeCheckEat, snakeMove).
		if  eat then
			begin
			f:= FoodAt(head.Row, head.Col);

			if  f >= 0 then
				begin
				EatFood(s, f);

				// Points changed, and possibly lives - the HUD reads both
				// off SlotStatus, so it has to go out now. Rare enough to
				// cost nothing: a message per pickup, not per tick.
				SlotStatusToAll(s);

				// Eating sets Grow, so re-ask - this is what makes the
				// segment arrive on the SAME step as the food, rather
				// than one step late.
				growing:= PlaySnakes[s].Grow and (PlaySnakes[s].GrowNone = 0)
						and (PlaySnakes[s].Len < MAX_SNAKE_LEN);
				end;

			// No floor emit for the eaten cell: the head is painted over
			// it below, which is the same write.
			end;

		// GROWING is simply not vacating the tail. Making room first and
		// letting the shift below duplicate the last segment into it
		// leaves the new tail sitting on the cell the old one already
		// occupies - already painted, so it costs no delta either.
		if  growing then
			Inc(PlaySnakes[s].Len)
		else
			with PlaySnakes[s].Body[PlaySnakes[s].Len - 1] do
				// NOT a plain floor emit - see VacateCell. While anything
				// is overlapping, the cell this tail is leaving may still
				// have somebody else in it, and clearing it would delete
				// them from the board while they carried on living.
				VacateCell(Row, Col, s, ADeltas, ADeltaCount);

		for i:= PlaySnakes[s].Len - 1 downto 1 do
			PlaySnakes[s].Body[i]:= PlaySnakes[s].Body[i - 1];

		// One segment per food, unless GrowEx is holding the flag on -
		// which is the whole difference between the two growth foods.
		if  PlaySnakes[s].GrowEx = 0 then
			PlaySnakes[s].Grow:= False;

		PlaySnakes[s].Body[1].Shape:= SegShape(prevDir, PlaySnakes[s].Dir);
		with PlaySnakes[s].Body[1] do
			Emit(Row, Col, SnakeBodyTile(PlaySnakes[s].Player, Shape,
					PlaySnakes[s].FlashOn));

		// No telegraph decision here, unlike the demo - a player's next
		// turn is whatever they press, and Look already holds it. The
		// head is still shaped from Dir toward Look for exactly the
		// same reason though, so a turn already pressed shows on the
		// head a step before the body follows it.
		head.Shape:= SegShape(PlaySnakes[s].Dir, PlaySnakes[s].Look);
		PlaySnakes[s].Body[0]:= head;
		Emit(head.Row, head.Col, SnakeTile(PlaySnakes[s].Player,
				SNAKE_ROLE_HEAD, head.Shape));

		// STOP FLOATING once the head is on a cell nobody else is in -
		// dengland's rule, and the reason it is the head rather than the
		// whole body is that the head is what has to be able to collide
		// again. A tail still trailing through somebody is harmless: it
		// kills nothing, and VacateCell already keeps it from erasing
		// them as it leaves.
		if  PlaySnakes[s].Floating
		and (SolidSnakeAt(head.Row, head.Col, s) < 0) then
			PlaySnakes[s].Floating:= False;

		if  repaint then
			RepaintBody(s);
		end;

	// FLOATERS PAINT LAST, so they are on top of anything that moved
	// through or under them this tick - including their heads, which
	// RepaintBody does not cover.
	//
	// A whole-body repaint per floating snake per tick is not free, but
	// floating is a transient state lasting a handful of steps after a
	// spawn, and doing it here rather than at every individual write is
	// what keeps the Z order out of the movement code entirely.
	for s:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  PlaySnakes[s].Alive and PlaySnakes[s].Floating then
			begin
			RepaintBody(s);

			with PlaySnakes[s].Body[0] do
				Emit(Row, Col, SnakeTile(PlaySnakes[s].Player,
						SNAKE_ROLE_HEAD, Shape));
			end;

	// Anyone's gear moved? A speed food changes it the moment it is
	// eaten and again as the effect decays out, and the HUD's speed bar
	// is driven off SlotStatus, so the change has to be noticed and
	// announced.
	//
	// A separate pass at the end rather than inline above, because a gear
	// can move on a tick where the snake did NOT step - MoveFast decays
	// every tick - and because the dead/respawning branch would otherwise
	// need its own copy of the same check.
	for s:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  PlayGearFor(s) <> PlayGear[s] then
			SlotStatusToAll(s);
	end;

// PushBoardToWatchers - resend the WHOLE board to everyone watching,
// row-pair at a time. Caller holds Lock.
//
// For a wholesale change - a level appearing, the attract reel being
// swept away - where deltas would be both enormous and pointless. The
// client's BoardRowsData handler is address-driven, not request-driven:
// it uses the row number in the message and does not check that it
// asked for it, so an unsolicited push lands correctly.
procedure TSnakeGame.PushBoardToWatchers;
	var
	i, r: Integer;

	begin
	for i:= 0 to Watchers.Count - 1 do
		try
		r:= 0;
		while r <= BOARD_ROWS - 2 do
			begin
			SendBoardRows(Watchers[i], r);
			Inc(r, 2);
			end;

		except
		on E: Exception do
			AddLogMessage(slkError,
					'PushBoardToWatchers: failed for watcher - ' + E.Message);
		end;
	end;

// StartPlay - the board stops attracting and starts playing. Caller
// holds Lock.
//
// Builds a real level and pushes the whole board rather than trying to
// delta the attract reel away: the demo leaves snakes, lava, bees and
// food scattered over the board, and every one of those cells would
// need clearing individually. A level change is exactly the case whole-
// board resend exists for.
procedure TSnakeGame.StartPlay;
	var
	i, deltaCount: Integer;
	deltas: array of TTileDelta;

	begin
	Playing:= True;

	// LevelProgress seeds from the board's difficulty, as the original
	// does (iLevelProgress = iGameDifficulty).
	LevelProgress:= Ord(Difficulty);

	LevelVariant:= 0;
	LevelNumber:= 1;

	// DEBUG START LEVEL (-l on the command line). Reaching stage 8 takes
	// eight two-minute levels, which is not a reasonable price for
	// looking at the boss or at a lava stage (dengland, 2026-08-26,
	// "it's past midnight!").
	//
	// Everything downstream is derived from these two, so setting them
	// here and letting the normal path run is enough - no separate
	// "debug board" to keep in step with the real one, and the stage
	// starts genuinely identical to one arrived at by playing.
	//
	// Progress is advanced to match, so the speed and swarm are the ones
	// that level would really have rather than an easy board wearing a
	// hard level's number.
	if  (DebugStartLevel > 1) and (LevelNumber < DebugStartLevel) then
		begin
		Inc(LevelProgress, DebugStartLevel - LevelNumber);

		// Same ceiling as the normal per-level climb, or -l would hand
		// a training board a difficulty it can never reach by playing.
		if  LevelProgress > MaxProgress then
			LevelProgress:= MaxProgress;

		LevelNumber:= DebugStartLevel;
		LevelVariant:= (LevelNumber - 1) mod LEVEL_VARIANTS;

		AddLogMessage(slkInfo, 'Debug: starting at level '
				+ IntToStr(LevelNumber) + ' (stage ' + IntToStr(LevelStage)
				+ ', progress ' + IntToStr(LevelProgress)
				+ '/' + IntToStr(MaxProgress)
				+ ', speed ' + IntToStr(SpeedProgress)
				+ ' = ' + IntToStr(BoardStepTicks) + ' ticks/step'
				+ ', bees ' + IntToStr(PlayBeeMax) + ')');
		end;

	LevelTicks:= PLAY_LEVEL_TICKS;
	LevelRamped:= False;
	LevelBeesEaten:= 0;
	LevelSecsSent:= -1;

	// Same ordering rule as NextLevel: after LevelNumber is final, since
	// the debug start level above may just have moved it. Both of these
	// read LevelStage, which is derived from it.
	ResetLevelKeys;
	ResetPlayLava;

	BuildLevel(LevelVariant, LevelProgress);

	// SNAKE_RENDER_SLOTS, so the boss goes down with everybody else. It
	// is re-laid below if this stage wants one, and a stale Alive on
	// that slot would otherwise leave an invisible boss in the models
	// for every collision test to find.
	for i:= 0 to SNAKE_RENDER_SLOTS - 1 do
		PlaySnakes[i].Alive:= False;

	for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
		PlayRespawn[i]:= 0;

	for i:= 0 to PLAY_BEE_CAP - 1 do
		PlayBees[i].Active:= False;

	// The attract reel's own food is painted over by BuildLevel above and
	// was never in this table anyway (TickDemoFood writes tiles straight
	// to the board - it is a display, not a simulation). Clearing it here
	// is about the PREVIOUS game's food, on a board that has just been
	// rebuilt underneath it.
	for i:= 0 to PLAY_FOOD_MAX - 1 do
		PlayFood[i].Active:= False;

	// Spawns are written straight into Board here and go out with the
	// board push below, so the deltas they generate are thrown away
	// rather than sent - EmitCell writes both, and the push carries the
	// result.
	SetLength(deltas, 64);
	deltaCount:= 0;

	// THE BOSS FIRST, onto the empty centre, before anybody's corner is
	// occupied - see SpawnBoss for why being laid with the level rather
	// than arriving later is the whole reason it needs no sweep and no
	// Floating state.
	if  StageHasBoss then
		SpawnBoss(deltas, deltaCount);

	for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
		if  Assigned(Slots[i].Player) then
			SpawnPlayerSnake(i, deltas, deltaCount);

	PushBoardToWatchers;
	end;

// StopPlay - the last corner was given up; back to the attract reel.
// Caller holds Lock.
procedure TSnakeGame.StopPlay;
	var
	i: Integer;

	begin
	Playing:= False;

	// BACK TO THE BOARD'S OWN DIFFICULTY. The attract reel is not
	// difficulty-free - TickDemoBees scales its chase weights and its
	// move cadence off LevelProgress, and TickDemoLava sizes its pools
	// off it too - and nothing here used to put it back, so the demo
	// went on running at whatever the last game had climbed to
	// (dengland spotted it 2026-08-26: "the demo wave bees are being
	// affected by the last game's bee progress").
	//
	// Restored to the value Create seeded, so an idle board looks the
	// same whether it has just finished a long game or has never been
	// played. LevelNumber goes back with it because SpeedProgress is
	// derived from it, and StartPlay sets both again regardless.
	LevelProgress:= Ord(Difficulty);
	LevelNumber:= 1;

	// SNAKE_RENDER_SLOTS - the boss must not survive into attract mode.
	// Nothing there would move it or draw it, but it would still be in
	// the models, and BuildLevelBase below is about to paint over the
	// cells it thinks it holds.
	for i:= 0 to SNAKE_RENDER_SLOTS - 1 do
		PlaySnakes[i].Alive:= False;

	for i:= 0 to SNAKE_PLAYER_COUNT - 1 do
		PlayRespawn[i]:= 0;

	for i:= 0 to PLAY_FOOD_MAX - 1 do
		PlayFood[i].Active:= False;

	for i:= 0 to PLAY_BEE_CAP - 1 do
		PlayBees[i].Active:= False;

	// The play-side pools, not the reel's - the attract lava that runs
	// after this has its own state and its own wave machine.
	ResetPlayLava;

	// Back to the demo's own board - its bar, and its snakes laid out
	// on the circuit. InitDemoSnakes writes them into Board, so the
	// push below carries them out with everything else.
	BuildLevelBase;

	for i:= DEMO_WALL_LEFT to DEMO_WALL_RIGHT do
		Board[DEMO_WALL_ROW][i]:= TILE_WALL;

	InitDemoSnakes;

	PushBoardToWatchers;
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
	pass, row, c, idx, mid: Integer;

	begin
	// THE KEY GOES IN THE MIDDLE of each row (dengland, 2026-08-26), one
	// per row so the display stays symmetrical.
	//
	// Placed rather than cycled. The type cycle below runs over
	// FOOD_RANDOM_KINDS, not FOOD_TYPE_COUNT, precisely so that adding
	// the key to the food table did NOT quietly sprinkle it through the
	// attract wave at every fifth cell - the reel is a showcase, and the
	// key is meant to read as the rare one.
	mid:= DEMO_LEFT + 1
			+ ((((DEMO_RIGHT - 1) - (DEMO_LEFT + 1)) div DEMO_FOOD_STRIDE)
				div 2) * DEMO_FOOD_STRIDE;

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
					if  c = mid then
						EmitCell(row, c, TILE_FOOD_BASE + FOOD_KIND_KEY,
								ADeltas, ADeltaCount)
					else
						// FOOD_RANDOM_KINDS, not FOOD_TYPE_COUNT - see the
						// note at the top. The key is placed, never cycled.
						EmitCell(row, c,
								TILE_FOOD_BASE + (idx mod FOOD_RANDOM_KINDS),
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
	//
	// Real play adds a lot on top of that. Up to PLAY_FOOD_MAX expiries
	// plus one spawn (TickPlayFood); BEES ARE THE BIG ONE - every moving
	// bee costs TWO cells, the one it left and the one it entered, so a
	// full board of them at PLAY_BEE_CAP is 20 on its own. A spawning
	// snake also sweeps its start area, a (2 * PLAY_SPAWN_CLEAR + 1)
	// square, though only the non-floor cells there emit.
	//
	// 78 USED TO BE A HARD CEILING, because that is exactly one message:
	// the stack caps a payload at 235 bytes and a delta is 3, so
	// 1 + 78 x 3 = 235. Everything past it was silently dropped.
	//
	// IT IS NO LONGER A CEILING, only a chunk size - SendTileDeltas
	// splits across as many messages as the tick needs (2026-08-26). The
	// gather buffer is sized for the genuine worst case instead, which
	// is what it should always have been:
	//
	//   four players repainting a full-length flashing body   4 x 63
	//   the boss doing the same                                     27
	//   a full swarm moving, two cells each                         32
	//   food expiring and spawning                                   6
	//
	// That is comfortably over 300, and it is not a hypothetical: the
	// flash phase flips EVERY tick, so any long snake with a shield is
	// already paying its whole length per tick.
	//
	// EmitCell still drops anything past the end rather than overrunning,
	// and Board stays authoritative either way, so even exceeding this
	// costs a stale cell until the next sync rather than a desync.
	SetLength(deltas, PLAY_DELTAS_MAX);
	Lock.Acquire;
		try
		claimed:= False;
		for i:= 0 to 3 do
			if Assigned(Slots[i].Player) then
				claimed:= True;

		// Attract/demo mode is "0 corners claimed", not a separate
		// TGameState value (see the project's own design-decision
		// notes). The EDGE is what matters here: the changeover in
		// either direction rebuilds the board wholesale and pushes it,
		// so it must happen exactly once, not every tick.
		if  claimed <> Playing then
			begin
			if  claimed then
				StartPlay
			else
				StopPlay;
			end;

		if  claimed then
			begin
			deltaCount:= 0;

			TickPlaySnakes(deltas, deltaCount);

			// AFTER THE PLAYERS, so the boss chases where they ARE
			// rather than where they were - which is also what makes its
			// head-on test meaningful. See TickBoss for why it is not
			// folded into the routine above despite sharing its array.
			TickBoss(deltas, deltaCount);

			// AFTER the snakes, so a piece of food that rots on the same
			// tick as a head arrives on it has already been eaten - the
			// snake gets it, rather than losing it by a tick.
			TickPlayFood(deltas, deltaCount);
			TickPlayBees(deltas, deltaCount);

			// Gated here rather than inside, so a level with no lava
			// costs one boolean rather than a call and a phase machine.
			// Bees and lava never share a level (PlayBeeMax returns 0 on
			// a lava stage), so the two above and this one are never
			// both doing anything.
			if  StageHasLava then
				TickPlayLava(deltas, deltaCount);

			// After the ordinary food, so a key and a food cannot both
			// try to claim the last free table slot in the same tick with
			// the key winning by running first.
			TickLevelKey(deltas, deltaCount);

			// A CUED SHAKE, drained here rather than at the bottom.
			//
			// Real play only cues one from the boss - a hit, and the
			// kill - and both arrive on a tick that is very likely to be
			// the level's LAST, because the kill is what ends it. The
			// NextLevel branch below exits early and would swallow the
			// message entirely, which is exactly what the attract reel's
			// own drain had to be moved above its empty-broadcast check
			// to avoid.
			if  DemoShakePending > 0 then
				begin
				for i:= 0 to Watchers.Count - 1 do
					try
					SendShake(Watchers[i], DemoShakePending);

					except
					on E: Exception do
						AddLogMessage(slkError,
								'Tick: SendShake failed for watcher - ' + E.Message);
					end;

				DemoShakePending:= 0;
				end;

			// --- the level clock ---
			//
			// Run AFTER everything that moves, so a level that ends this
			// tick rebuilds on top of a finished board rather than
			// halfway through one.
			// A BOSS LEVEL'S CLOCK DOES NOT RUN (dengland, 2026-08-26:
			// "instead of time going down normally on this level, you
			// have to clear it with killing the boss"). The level ends
			// when the boss dies and by no other route - KillBoss
			// releases the freeze by setting a short victory beat, and
			// the ordinary path below then fires with no special case.
			//
			// BossOnBoard, not StageHasBoss, is what holds the freeze:
			// the difference between them is precisely the beat after
			// the kill.
			//
			// If NOBODY can kill it, the level does not end - and that
			// is the intended consequence, not an oversight. The board
			// still empties the usual way as players run out of lives,
			// and the last one leaving drops it back to attract mode.
			if  (LevelTicks > 0) and not BossOnBoard then
				begin
				Dec(LevelTicks);

				// The last-30-seconds ramp: one more bee, one gear
				// quicker. Fires ONCE - LevelRamped is what both
				// PlayBeeMax and BoardStepTicks read, so it has to latch
				// rather than be re-tested.
				//
				// NOT ON A BOSS STAGE. There is no thirty-seconds-left
				// to be in: the only time that clock moves there is the
				// couple of seconds after the boss is already dead, and
				// taking a gear off the board for the victory lap would
				// be a speed jump out of nowhere.
				if  (not LevelRamped) and not StageHasBoss
				and (LevelTicks <= PLAY_LEVEL_RAMP_TICKS) then
					LevelRamped:= True;
				end;

			// Only on the wire when the DISPLAYED value changes - one
			// message a second, not one a tick.
			if  LevelSecsLeft <> LevelSecsSent then
				begin
				LevelSecsSent:= LevelSecsLeft;
				GameStatusToAll;
				end;

			if  LevelTicks <= 0 then
				begin
				// Rebuilds and pushes the whole board itself, so the
				// deltas gathered above are stale the moment it runs -
				// drop them rather than sending a description of a board
				// that no longer exists.
				NextLevel;
				Exit;
				end;

			if  deltaCount = 0 then
				Exit;

			for i:= 0 to Watchers.Count - 1 do
				try
				SendTileDeltas(Watchers[i], Copy(deltas, 0, deltaCount));

				except
				on E: Exception do
					AddLogMessage(slkError,
							'Tick: SendTileDeltas failed for watcher - ' + E.Message);
				end;

			Exit;
			end;

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
		else if  AMessage.Method = $0E then
			begin
			// Direction - the player wants to turn. Payload is [dir],
			// one TSnakeDir ordinal.
			//
			// The highest-frequency message in the protocol, so it is
			// deliberately the smallest thing that works: no sequence
			// number, no acknowledgement, no coordinates. A lost or
			// stale turn is self-correcting, because the next one
			// replaces it entirely - there is no state to resynchronise.
			//
			// Silently ignored if malformed or if this player holds no
			// live snake: direction spam from a spectator is not worth
			// an error round-trip, unlike a slot claim which is a
			// deliberate one-off action.
			AHandled:= True;

			if  (Length(AMessage.Data) >= 1)
			and (AMessage.Data[0] <= Ord(High(TSnakeDir))) then
				SetPlayerLook(APlayer, TSnakeDir(AMessage.Data[0]));
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
	t: AnsiString;
	secs, c: Integer;

	begin
	m:= TBaseMessage.Create;
	m.Category:= mcPlay;
	m.Method:= $06;

	// [state, secsLo, secsHi]. The seconds are new (2026-08-25) and are
	// what drives the client's level clock.
	//
	// ON GameStatus RATHER THAN A NEW MESSAGE, deliberately. Method
	// numbers are FOUR BITS - 16 per category, total - and $0F is the
	// only one left; a clock is not what to spend it on. This message
	// already carries board-wide state, the payload had 253 spare bytes,
	// and the client reads fixed offsets and ignores trailing data.
	//
	// The consequence is that GameStatus is no longer sent only once, on
	// join - it now arrives every second. The client had been treating
	// its arrival AS the join confirmation, so it now has to latch that
	// (see gameProcGameStatusMsg).
	secs:= LevelSecsLeft;

	SetLength(m.Data, 3 + PLAY_STATUS_LEN);
	m.Data[0]:= Ord(State);
	m.Data[1]:= secs and $FF;
	m.Data[2]:= (secs shr 8) and $FF;

	// The display text, already formatted. The raw seconds above are NOT
	// redundant with it - the client needs a number to test against
	// PLAY_STATUS_WARN_SECS, and parsing digits back out of its own
	// display string to get one would be daft.
	//
	// BOSS MODE. On a boss stage the clock is frozen and means nothing,
	// so the line carries the boss's remaining lives instead - dengland
	// asked for exactly this ("go into 'boss mode' on the level display
	// above the board").
	//
	// It needs NO PROTOCOL CHANGE and no client work, which is worth
	// saying out loud because the alternative he floated was to add more
	// data to the message. This text is formatted server-side and the
	// client just prints it, so a new display mode costs one branch
	// here. The seconds field goes out unchanged and simply sits at the
	// frozen value, which is also what keeps the client's low-time warn
	// from firing on a level that has no low time.
	//
	// The pips are '*', deliberately: the framework's label text cannot
	// reach screen codes above $3F, so anything prettier would need the
	// tile path rather than the status line.
	if  BossOnBoard then
		t:= 'LEVEL ' + Format('%2d', [LevelNumber])
				+ '   BOSS ' + StringOfChar('*', BossLives)
	else
		t:= 'LEVEL ' + Format('%2d', [LevelNumber])
				+ '   TIME ' + IntToStr(secs div 60)
				+ ':' + Format('%.2d', [secs mod 60]);

	while Length(t) < PLAY_STATUS_LEN do
		t:= t + ' ';

	for c:= 1 to PLAY_STATUS_LEN do
		m.Data[2 + c]:= Ord(t[c]);

    APlayer.AddSendMessage(m);
	end;

procedure TSnakeGame.SendSlotStatus(APlayer: TPlayer; ASlot: Integer);
	var
	m: TBaseMessage;
	s: AnsiString;
	c: Integer;

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
	SetLength(m.Data, 4);
	m.Data[0]:= ASlot;
	m.Data[1]:= Ord(Slots[ASlot].State);

	if  Slots[ASlot].Player = APlayer then
		m.Data[2]:= 1
	else
		m.Data[2]:= 0;

	// Lives, appended 2026-08-25 for the same reason isyou was: the
	// payload had room and the client reads fixed offsets, so growing
	// this message costs nothing and spends no method number.
	m.Data[3]:= Slots[ASlot].Lives;

	// Score, appended 2026-08-25, as PLAY_SCORE_DIGITS ASCII DIGITS
	// rather than a binary number.
	//
	// Deliberate: the client's score row is a label, and a label wants
	// text. Sending binary would buy four bytes on the wire and cost a
	// 24-bit-to-decimal conversion on the client for a number the server
	// has already got in a form it can print.
	//
	// The MEGA65 could do that conversion cheaply - the 45GS02 has a
	// hardware divider at $D768 (dengland, 2026-08-25) - but leaning on
	// it would put a 45GS02-only dependency in the client for no gain,
	// and this codebase would rather stay portable to a plain 6502 where
	// the choice is free. Which it is here: the server is the one machine
	// in this system that formatting a number costs nothing on.
	//
	// Zero-padded to a FIXED WIDTH, which is what lets the client copy it
	// into a fixed buffer with no length byte and no terminator handling.
	// AddScore's clamp at PLAY_SCORE_MAX is what guarantees it never
	// needs more digits than the label has room for.
	s:= IntToStr(Slots[ASlot].Score);

	while Length(s) < PLAY_SCORE_DIGITS do
		s:= '0' + s;

	SetLength(m.Data, 4 + PLAY_SCORE_DIGITS + 1);

	for c:= 1 to PLAY_SCORE_DIGITS do
		m.Data[3 + c]:= Ord(s[c]);

	// Speed gear, appended 2026-08-25 - TICKS PER STEP, so SMALLER IS
	// FASTER, the same convention the SNAKE_SPEED_* constants use. 0
	// means nobody is playing this corner.
	//
	// Sent as the gear rather than as a bar length: how many cells a gear
	// lights up is a display decision (dengland's own 1/1/1/2/2/3
	// progression), and it belongs on the side that does the drawing.
	m.Data[3 + PLAY_SCORE_DIGITS + 1]:= PlayGearFor(ASlot);

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

		g.Desc:= ARR_SNAKE_BOARDS[i].Name;
		g.Play:= Self;

		// BOTH, and in this order. Create seeds LevelProgress from the
		// difficulty it was built with, so overriding the difficulty
		// afterwards would leave the attract reel running on the old
		// one until the first StartPlay re-seeded it - the demo's own
		// bee and lava scaling read LevelProgress too.
		g.Difficulty:= ARR_SNAKE_BOARDS[i].Difficulty;
		g.MaxProgress:= ARR_SNAKE_BOARDS[i].MaxProgress;
		g.LevelProgress:= Ord(g.Difficulty);

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
