// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "./Elo.sol";

// TODO: Add admin function to cancel games if they're too old, or never start
// TODO: Consider requiring someone to join a game before they show up on leaderboard

error ContractPaused();
error NotEnoughFunds();
error NotEnoughTorpedoes();
error NotEnoughMines();
error NotYourTurn();
error NotYourGame();
error GameNotActive();
error AlreadyRegistered();
error NotRegistered(address _playerAddress);
error NotInvited(uint _gameId);
error NotEnoughTimePassed();

int constant QUADRANT_SIZE = 20;
int constant START_DISTANCE = 15;
uint constant ASTEROID_SIZE = 10; // Manhattan distance

int constant K = 1; // K factor

enum LeftOrRight {
    None,
    Left,
    Right
}

enum UpOrDown {
    None,
    Up,
    Down
}

enum Action {
    None,
    FireTorpedo,
    DropMine
}

enum Status {
    NotStarted,
    Player1Destroyed,
    Player2Destroyed,
    Player1Fled,
    Player2Fled,
    Draw,
    Active,
    Over
}

contract TheThirdLaw is Ownable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // I expect this to break if it gets big enough
    EnumerableMap.AddressToUintMap private addressToELO;

    uint public gameCost = 0.001 ether;
    uint public feePercent = 10;
    uint public feeBalance = 0;

    uint public maxTorpedoes = 5;
    uint public maxMines = 5;
    uint public torpedoFuel = 10;
    uint public mineRange = 2;
    int public torpedoAccel = 1; // TODO: CRITICAL -> This may need to be locked to 1 now
    int public torpedoRange = 1; // TODO: Decide to make this adjustable or constant

    // 5 minutes in milliseconds
    uint public turnTimeout = 5 * 60 * 1000;

    bool public active = true;

    // Super savvy players can find this and use it to decide whether or not
    // to join an open game
    uint openGameId = 0;

    mapping(address => Player) public players;

    Game[] public games;

    event InviteToGame(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );
    event JoinGame(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    event OpenGameCreated(
        address indexed _player1Address,
        uint indexed _gameId
    );
    event OpenGameJoined(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    event GameStarted(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    event GameOver(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    struct Game {
        uint id;
        address player1Address;
        address player2Address;
        Ship player1Ship;
        Ship player2Ship;
        Status status;
        uint value; // Amount to be paid to victor, or split if there is a tie
        address currentPlayer; // Set to None if game not started or is over
        uint lastTurnTimestamp;
        // TODO: CRITICAL -> Add the torpedo and mine stats here and use them so old games stay as expected if changes are made
    }

    struct Player {
        address ownerAddress;
        uint[] gameIds;
        uint[] inviteIds;
        uint victories; // Enemy was destroyed
        uint defaultVictories; // Enemy was forced to flee
        uint defaultLosses; // Player was forced to flee
        uint draws; // Both players ran out of weapons
        uint losses; // Player was destroyed
        uint eloRating;
        uint currentShipId;
    }

    struct Ship {
        address ownerAddress;
        Position position;
        Velocity velocity;
        uint remainingTorpedoes;
        uint remainingMines;
        Torpedo[] torpedoes; // Added this line
        Mine[] mines; // Added this line
    }

    struct Torpedo {
        Position position;
        Velocity velocity;
        uint remainingFuel;
    }

    struct Mine {
        Position position;
    }

    struct Position {
        int row;
        int col;
    }

    struct Velocity {
        int row;
        int col;
    }

    constructor() {
        games.push();
    }

    // PUBLIC
    function createOrJoinRandomGame() public payable isActive {
        if (msg.value != gameCost) revert NotEnoughFunds();

        if (players[msg.sender].ownerAddress == address(0)) {
            _registerPlayer(msg.sender);
        }

        if (openGameId == 0) {
            openGameId = games.length;
            games.push();
            games[openGameId].id = openGameId;
            games[openGameId].player1Address = msg.sender;
            games[openGameId].value = msg.value;
            players[msg.sender].gameIds.push(openGameId);
            players[msg.sender].inviteIds.push(openGameId); // TODO: This is probably not the best way to handle this

            emit OpenGameCreated(msg.sender, openGameId);
        } else {
            games[openGameId].player2Address = msg.sender;
            games[openGameId].value += msg.value;
            players[msg.sender].gameIds.push(openGameId);
            players[msg.sender].inviteIds.push(openGameId); // TODO: This is probably not the best way to handle this

            _startGame(openGameId);

            emit OpenGameJoined(
                games[openGameId].player1Address,
                msg.sender,
                openGameId
            );

            openGameId = 0;
        }
    }

    function inviteToGame(address _player2Address) public payable isActive {
        if (msg.value != gameCost) revert NotEnoughFunds();

        if (players[msg.sender].ownerAddress == address(0)) {
            _registerPlayer(msg.sender);
        }

        if (players[_player2Address].ownerAddress == address(0)) {
            _registerPlayer(_player2Address);
        }

        uint gameId = games.length;
        games.push();
        games[gameId].id = gameId;
        games[gameId].player1Address = msg.sender;
        games[gameId].player2Address = _player2Address;
        games[gameId].value = msg.value;
        players[msg.sender].gameIds.push(gameId);
        players[_player2Address].gameIds.push(gameId);
        players[_player2Address].inviteIds.push(gameId); // TODO: This is probably not the best way to handle this

        emit InviteToGame(msg.sender, _player2Address, gameId);
    }

    function acceptInvite(uint _gameId) public payable {
        if (msg.value != gameCost) revert NotEnoughFunds();

        if (games[_gameId].player2Address != msg.sender)
            revert NotInvited(_gameId);

        games[_gameId].value += msg.value;

        _startGame(_gameId);

        emit JoinGame(games[_gameId].player1Address, msg.sender, _gameId);
    }

    // Prevent spam by refunding the inviter's fee to the game contract if
    // the invite is rejected.
    function rejectInvite(uint _gameId) public {
        if (games[_gameId].player2Address != msg.sender)
            revert NotInvited(_gameId);

        feeBalance += games[_gameId].value;
        games[_gameId].value = 0;

        games[_gameId].status = Status.Over;
    }

    function takeTurn(
        uint _gameId,
        LeftOrRight _leftOrRight,
        UpOrDown _upOrDown,
        Action _action
    ) public {
        Game storage game = games[_gameId];

        if (game.status != Status.Active) revert GameNotActive();
        if (game.currentPlayer != msg.sender) revert NotYourTurn();

        _processTurn(_gameId, _leftOrRight, _upOrDown, _action);
    }

    // If it's been 5 minutes since the last player's turn, then either player
    // can end the game in a draw
    // TODO: Audit priority
    function endGame(uint _gameId) public {
        // Only one of the players in the game can call this function
        if (
            games[_gameId].player1Address != msg.sender &&
            games[_gameId].player2Address != msg.sender
        ) revert NotYourGame();

        if (games[_gameId].status != Status.Active) revert GameNotActive();

        if (block.timestamp - games[_gameId].lastTurnTimestamp < turnTimeout)
            revert NotEnoughTimePassed();

        _endGame(_gameId, Status.Draw);
    }

    // If it's been 5 minutes since the last player's turn, the other player
    // can force their opponent to move with no input
    // TODO: Audit priority
    function forceMove(uint _gameId) public {
        Game storage game = games[_gameId];

        if (game.status != Status.Active) revert GameNotActive();

        if (
            game.player1Address != msg.sender &&
            game.player2Address != msg.sender
        ) revert NotYourGame();

        if (block.timestamp - game.lastTurnTimestamp < turnTimeout) {
            revert NotEnoughTimePassed();
        }

        _processTurn(_gameId, LeftOrRight.None, UpOrDown.None, Action.None);
    }

    // INTERNAL

    function _processTurn(
        uint _gameId,
        LeftOrRight _leftOrRight,
        UpOrDown _upOrDown,
        Action _action
    ) internal {
        Game storage game = games[_gameId];
        Ship storage ship;
        Ship storage enemyShip;

        if (game.currentPlayer == game.player1Address) {
            ship = game.player1Ship;
            enemyShip = game.player2Ship;
        } else {
            ship = game.player2Ship;
            enemyShip = game.player1Ship;
        }

        if (_leftOrRight == LeftOrRight.Left) {
            ship.velocity.col -= 1;
        } else if (_leftOrRight == LeftOrRight.Right) {
            ship.velocity.col += 1;
        }

        if (_upOrDown == UpOrDown.Up) {
            ship.velocity.row -= 1;
        } else if (_upOrDown == UpOrDown.Down) {
            ship.velocity.row += 1;
        }

        if (_action == Action.FireTorpedo) {
            if (ship.remainingTorpedoes == 0) revert NotEnoughTorpedoes();
            ship.remainingTorpedoes -= 1;
            ship.torpedoes.push(
                Torpedo(
                    Position(ship.position.row, ship.position.col),
                    Velocity(ship.velocity.row, ship.velocity.col),
                    torpedoFuel
                )
            );
        } else if (_action == Action.DropMine) {
            if (ship.remainingMines == 0) revert NotEnoughMines();
            ship.remainingMines -= 1;
            ship.mines.push(
                Mine(Position(ship.position.row, ship.position.col))
            );
        }

        _moveShip(ship);
        _checkForFleeingBoard(game, ship);
        _checkForAsteroidCollision(game, ship);
        _checkForMineCollision(game, ship, enemyShip.mines);
        _moveTorpedoesTowardsEnemy(game, enemyShip, ship.torpedoes);
        game.lastTurnTimestamp = block.timestamp;

        // Switch the current player
        if (game.currentPlayer == game.player1Address) {
            game.currentPlayer = game.player2Address;
        } else {
            game.currentPlayer = game.player1Address;
        }
    }

    function _moveShip(Ship storage _ship) internal {
        _ship.position.row += _ship.velocity.row;
        _ship.position.col += _ship.velocity.col;
    }

    function _moveTorpedoesTowardsEnemy(
        Game storage _game,
        Ship storage _enemyShip,
        Torpedo[] storage _torpedoes
    ) internal {
        for (uint i = 0; i < _torpedoes.length; i++) {
            if (_torpedoes[i].remainingFuel == 0) {
                continue;
            } else {
                _torpedoes[i].remainingFuel -= 1;

                // Calculate relative position
                int row_r = _enemyShip.position.row -
                    _torpedoes[i].position.row;
                int col_r = _enemyShip.position.col -
                    _torpedoes[i].position.col;

                // Adjust the torpedo's velocity based on relative position
                if (row_r > 0) {
                    _torpedoes[i].velocity.row += 1;
                } else if (row_r < 0) {
                    _torpedoes[i].velocity.row -= 1;
                }

                if (col_r > 0) {
                    _torpedoes[i].velocity.col += 1;
                } else if (col_r < 0) {
                    _torpedoes[i].velocity.col -= 1;
                }

                // Move the torpedo based on its velocity
                _torpedoes[i].position.row += _torpedoes[i].velocity.row;
                _torpedoes[i].position.col += _torpedoes[i].velocity.col;

                // If the torpedo is within 1 square of the enemy ship, it hits and the game is over
                // Use row and column, not manhattan distance
                if (
                    abs(_torpedoes[i].position.row - _enemyShip.position.row) <=
                    torpedoRange &&
                    abs(_torpedoes[i].position.col - _enemyShip.position.col) <=
                    torpedoRange
                ) {
                    if (_enemyShip.ownerAddress == _game.player1Address) {
                        _endGame(_game.id, Status.Player1Destroyed);
                    } else {
                        _endGame(_game.id, Status.Player2Destroyed);
                    }
                }

                // Check for collisions with asteroid
                if (
                    _manhattanDistance(
                        _torpedoes[i].position,
                        Position(0, 0)
                    ) <= ASTEROID_SIZE
                ) {
                    _torpedoes[i].remainingFuel = 0;
                }
            }
        }
    }

    function _checkForAsteroidCollision(
        Game storage _game,
        Ship storage _ship
    ) internal {
        if (
            _manhattanDistance(_ship.position, Position(0, 0)) <= ASTEROID_SIZE
        ) {
            // This player has hit an asteroid and lost
            if (_ship.ownerAddress == _game.player1Address) {
                _endGame(_game.id, Status.Player1Destroyed);
            } else {
                _endGame(_game.id, Status.Player2Destroyed);
            }
        }
    }

    function _checkForMineCollision(
        Game storage _game,
        Ship storage _ship,
        Mine[] storage _enemyMines
    ) internal {
        for (uint i = 0; i < _enemyMines.length; i++) {
            if (
                _manhattanDistance(_ship.position, _enemyMines[i].position) <=
                mineRange
            ) {
                // This player has hit a mine and lost
                if (_ship.ownerAddress == _game.player1Address) {
                    _endGame(_game.id, Status.Player1Destroyed);
                } else {
                    _endGame(_game.id, Status.Player2Destroyed);
                }
            }
        }
    }

    function _checkForFleeingBoard(
        Game storage _game,
        Ship storage _ship
    ) internal {
        if (
            abs(_ship.position.row) > QUADRANT_SIZE ||
            abs(_ship.position.col) > QUADRANT_SIZE
        ) {
            // This player has fled the board and lost
            if (_ship.ownerAddress == _game.player1Address) {
                _endGame(_game.id, Status.Player1Fled);
            } else {
                _endGame(_game.id, Status.Player2Fled);
            }
        }
    }

    // THIS MUST BE AUDITED!!!
    function _endGame(uint _gameId, Status _status) internal {
        Game storage game = games[_gameId];
        game.status = _status;
        game.currentPlayer = address(0);

        if (_status == Status.Player1Destroyed) {
            players[game.player2Address].victories += 1;
            players[game.player1Address].losses += 1;

            // Pay the victor
            uint payout = game.value;
            game.value = 0;
            payable(game.player2Address).transfer(payout);
        } else if (_status == Status.Player2Destroyed) {
            players[game.player1Address].victories += 1;
            players[game.player2Address].losses += 1;

            // Pay the victor
            uint payout = game.value;
            game.value = 0;
            payable(game.player1Address).transfer(payout);
            game.value = 0;
        } else if (_status == Status.Player1Fled) {
            players[game.player2Address].defaultVictories += 1;
            players[game.player1Address].defaultLosses += 1;

            uint balance = game.value;
            game.value = 0;
            // Pay the victor 75% of the game value
            uint payout = (balance * 75) / 100;
            payable(game.player2Address).transfer(payout);
            balance -= payout;

            // Add the remaining 25% to the contract's fee balance
            feeBalance += balance;
        } else if (_status == Status.Player2Fled) {
            players[game.player1Address].defaultVictories += 1;
            players[game.player2Address].defaultLosses += 1;

            uint balance = game.value;
            game.value = 0;
            // Pay the victor 75% of the game value
            uint payout = (balance * 75) / 100;
            payable(game.player1Address).transfer(payout);
            balance -= payout;

            // Add the remaining 25% to the contract's fee balance
            feeBalance += balance;
        } else if (_status == Status.Draw) {
            players[game.player1Address].draws += 1;
            players[game.player2Address].draws += 1;

            // Split the game value between the players
            uint balance = game.value;
            game.value = 0;
            // Pay each player 50% of the game value
            uint payout = balance / 2;
            payable(game.player1Address).transfer(payout);
            balance -= payout;
            payable(game.player2Address).transfer(balance);
        }

        (uint newRating1, uint newRating2) = calculateElo(
            int(players[game.player1Address].eloRating),
            int(players[game.player2Address].eloRating),
            _status
        );

        players[game.player1Address].eloRating = newRating1;
        players[game.player2Address].eloRating = newRating2;

        addressToELO.set(game.player1Address, newRating1);
        addressToELO.set(game.player2Address, newRating2);

        emit GameOver(game.player1Address, game.player2Address, _gameId);
    }

    // TODO: I don't understand how K factor works.  Recommended was 32 or 20, but that gave drastic results
    // 1 seems to work well initially, don't know what will happen later
    // TODO: CRITICAL -> Understand and validate max rating differences!
    // TODO: Find a more elegant way to handle than blocking games
    // TODO: This may be expensive
    // TODO: Investigate consequenses of gaming this with multiple games and choosing when to end/lose
    // TODO: Decide to only do 50 or 75% ELO change if one player flees
    // Calculate the new ELO ratings of two players
    // TODO: This is probably abusable since we allow players to play themselves
    function calculateElo(
        int _ratingA,
        int _ratingB,
        Status _result
    ) public pure returns (uint, uint) {
        // DEBUG IGNORE EDGE CASE

        // If the ratings are too far apart, don't change them
        if (abs(_ratingA - _ratingB) > 800) {
            return (uint(_ratingA), uint(_ratingB));
        }

        // END DEBUG IGNORE EDGE CASE

        uint resultValue;

        if (
            _result == Status.Player2Destroyed || _result == Status.Player2Fled
        ) {
            resultValue = 100;
        } else if (
            _result == Status.Player1Destroyed || _result == Status.Player1Fled
        ) {
            resultValue = 0;
        } else if (_result == Status.Draw) {
            resultValue = 50;
        } else {
            revert("Invalid result");
        }

        (uint256 change, bool negative) = Elo.ratingChange(
            uint(_ratingA),
            uint(_ratingB),
            resultValue,
            uint(K)
        );

        int newRatingA;
        int newRatingB;

        if (negative) {
            newRatingA = _ratingA - int(change);
            newRatingB = _ratingB + int(change);
        } else {
            newRatingA = _ratingA + int(change);
            newRatingB = _ratingB - int(change);
        }

        if (newRatingA < 0) {
            newRatingA = 0;
        }

        if (newRatingB < 0) {
            newRatingB = 0;
        }
        // It shouldn't be possible for ELO to get above maxIint without me being so rich I don't care :D

        return (uint(newRatingA), uint(newRatingB));
    }

    function _registerPlayer(address _player) internal {
        if (players[_player].ownerAddress != address(0))
            revert AlreadyRegistered();
        players[_player] = Player(
            _player,
            new uint[](0),
            new uint[](0),
            0,
            0,
            0,
            0,
            0,
            1200,
            0
        );

        addressToELO.set(_player, 1200);
    }

    function _startGame(uint _gameId) internal {
        Ship storage player1Ship = games[_gameId].player1Ship;
        Ship storage player2Ship = games[_gameId].player2Ship;

        // Player 1 starts on left side, can be top or bottom
        // They start on the top if the block number is even and on the bottom if it's odd
        int player1Row = int(block.number) % 2 == 0 ? int(1) : -1;

        player1Ship.ownerAddress = games[_gameId].player1Address;
        player1Ship.position = Position(
            START_DISTANCE * player1Row,
            -START_DISTANCE
        );
        player1Ship.velocity = Velocity(0, 0);
        player1Ship.remainingTorpedoes = maxTorpedoes;
        player1Ship.remainingMines = maxMines;

        // Player 2 starts on right side, can be top or bottom, based on timestamp
        int player2Row = int(block.timestamp) % 2 == 0 ? int(1) : -1;

        player2Ship.ownerAddress = games[_gameId].player2Address;
        player2Ship.position = Position(
            START_DISTANCE * player2Row,
            START_DISTANCE
        );
        player2Ship.velocity = Velocity(0, 0);
        player2Ship.remainingTorpedoes = maxTorpedoes;
        player2Ship.remainingMines = maxMines;

        // Assuming torpedoes and mines arrays start empty, there's no need to initialize them

        // Flip a coin and set the starting player
        if (block.prevrandao % 2 == 0) {
            games[_gameId].currentPlayer = games[_gameId].player1Address;
        } else {
            games[_gameId].currentPlayer = games[_gameId].player2Address;
        }

        games[_gameId].status = Status.Active;

        // Take the fee from the game value and add it to the contract's fee balance
        uint fee = (games[_gameId].value * feePercent) / 100;
        feeBalance += fee;
        games[_gameId].value -= fee;

        emit GameStarted(
            games[_gameId].player1Address,
            games[_gameId].player2Address,
            _gameId
        );
    }

    // UTILS

    function _manhattanDistance(
        Position memory _position1,
        Position memory _position2
    ) internal pure returns (uint) {
        return
            uint(
                abs(_position1.row - _position2.row) +
                    abs(_position1.col - _position2.col)
            );
    }

    function abs(int _x) internal pure returns (int) {
        if (_x < 0) {
            return -_x;
        } else {
            return _x;
        }
    }

    // VIEWS

    // TODO: Do these need some kind of pagination?
    // function getGames() public view returns (Game[] memory) {
    //     return games;
    // }

    function getGamesForPlayer(
        address _playerAddress
    ) public view returns (Game[] memory) {
        uint[] memory gameIds = players[_playerAddress].gameIds;
        Game[] memory playerGames = new Game[](gameIds.length);
        for (uint i = 0; i < gameIds.length; i++) {
            playerGames[i] = games[gameIds[i]];
        }
        return playerGames;
    }

    function getPlayer(
        address _playerAddress
    ) public view returns (Player memory) {
        return players[_playerAddress];
    }

    function getGame(uint _gameId) public view returns (Game memory) {
        return games[_gameId];
    }

    struct PlayerELO {
        address playerAddress;
        uint eloRating;
    }

    function getAllELO() external view returns (PlayerELO[] memory) {
        PlayerELO[] memory playerELOs = new PlayerELO[](addressToELO.length());
        for (uint i = 0; i < addressToELO.length(); i++) {
            (address playerAddress, uint elo) = addressToELO.at(i);
            playerELOs[i] = PlayerELO(playerAddress, elo);
        }
        return playerELOs;
    }

    // MODIFIERS

    modifier isActive() {
        if (!active) revert ContractPaused();
        _;
    }

    // ADMIN

    function setGameCost(uint _gameCost) public onlyOwner {
        gameCost = _gameCost;
    }

    function setFeePercent(uint _feePercent) public onlyOwner {
        feePercent = _feePercent;
    }

    function setNumberTorpedoes(uint _maxTorpedoes) public onlyOwner {
        maxTorpedoes = _maxTorpedoes;
    }

    function setNumberMines(uint _maxMines) public onlyOwner {
        maxMines = _maxMines;
    }

    function setTorpedoFuel(uint _torpedoFuel) public onlyOwner {
        torpedoFuel = _torpedoFuel;
    }

    function setMineRange(uint _mineRange) public onlyOwner {
        mineRange = _mineRange;
    }

    function setTorpedoAccel(int _torpedoAccel) public onlyOwner {
        torpedoAccel = _torpedoAccel;
    }

    function pause() public onlyOwner {
        active = false;
    }

    function withdrawFee() public onlyOwner {
        payable(msg.sender).transfer(feeBalance);
        feeBalance = 0;
    }
}
